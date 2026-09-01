#!/usr/bin/env bash
#
# Primitivas de segurança: nunca montar um `rm -rf` perigoso a partir de
# variável sem validar antes. Todo caminho destrutivo passa por aqui.

# Diretórios que NUNCA podem ser alvo de limpeza automática, não importa a
# configuração ou entrada do operador.
_SECURITY_DENYLIST=(
    "/" "/root" "/home" "/etc" "/var" "/var/lib" "/var/log"
    "/usr" "/bin" "/sbin" "/boot" "/dev" "/proc" "/sys"
)

# Resolve um caminho e recusa valores obviamente perigosos (vazio, "." ou "/").
security_resolve() {
    local path="$1"
    case "$path" in
        "" | "." | "/") ui_error "Caminho recusado por segurança: '${path}'"; return 1 ;;
    esac
    realpath -m -- "$path"
}

# security_ensure_within <caminho> <prefixo_permitido>
# Confirma que <caminho> resolvido fica dentro de <prefixo_permitido> resolvido.
security_ensure_within() {
    local path resolved allowed
    path="$(security_resolve "$1")" || return 1
    allowed="$(security_resolve "$2")" || return 1

    case "${path}/" in
        "${allowed}/"*) ;;
        *)
            ui_error "'${path}' não está dentro do diretório permitido '${allowed}'"
            return 1
            ;;
    esac
    printf '%s' "$path"
}

# security_safe_clean_directory <caminho> <deve_estar_dentro_de> [arquivo_de_status]
# Remove só o CONTEÚDO de <caminho> (não o diretório em si). Recusa
# qualquer caminho fora do prefixo permitido ou na denylist.
#
# Um repository do Elasticsearch pode ter muitos arquivos pequenos
# (segmentos do Lucene, um por shard) - "rm -rf" nisso pode demorar sem
# dar sinal nenhum de vida. Se <arquivo_de_status> for informado, cada
# item de topo removido é registrado nele (uma linha por item), para um
# chamador em segundo plano conseguir mostrar o que está acontecendo.
security_safe_clean_directory() {
    local target must_be_under status_file resolved
    target="$1"
    must_be_under="$2"
    status_file="${3:-}"

    resolved="$(security_ensure_within "$target" "$must_be_under")" || return 1

    local entry
    for entry in "${_SECURITY_DENYLIST[@]}"; do
        if [[ "$resolved" == "$entry" ]]; then
            ui_error "Recusando limpar diretório protegido: ${resolved}"
            return 1
        fi
    done

    # Guarda extra contra caminhos rasos demais (ex: "/var", "/opt").
    local depth
    depth="$(awk -F'/' '{print NF-1}' <<<"$resolved")"
    if [[ "$depth" -le 2 ]]; then
        ui_error "Caminho considerado perigoso demais: ${resolved}"
        return 1
    fi

    [[ -d "$resolved" ]] || return 0

    local item
    local -a items=()
    for item in "$resolved"/* "$resolved"/.[!.]* "$resolved"/..?*; do
        [[ -e "$item" || -L "$item" ]] || continue
        items+=("$item")
    done

    if [[ -n "$status_file" ]]; then
        printf 'total:%s\n' "${#items[@]}" >> "$status_file"
    fi

    for item in "${items[@]}"; do
        if [[ -n "$status_file" ]]; then
            printf 'item:%s\n' "$(basename "$item")" >> "$status_file"
        fi
        rm -rf -- "$item"
    done
    if [[ -n "$status_file" ]]; then
        printf 'concluido\n' >> "$status_file"
    fi
    return 0
}
