#!/usr/bin/env bash
#
# Verificação (somente leitura) do diretório de repository do Elasticsearch.
# Não precisa de senha nem de chamada à API - é checagem de filesystem.

# Ecoa "chave=valor" por linha: diretorio_existe, possui_conteudo,
# path_repo_configurado (0/1) e espaco_livre (texto legível, ex: "220G").
repo_precheck() {
    local dir="$ES_REPOSITORY_PATH"
    local exists=0 has_content=0 path_repo_ok=0

    [[ -d "$dir" ]] && exists=1
    if [[ "$exists" -eq 1 ]] && [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
        has_content=1
    fi

    if [[ -f "$ES_CONFIG_FILE" ]]; then
        local trimmed="${dir%/}"
        if grep -Eq "^[[:space:]]*path\.repo[[:space:]]*:.*${trimmed}" "$ES_CONFIG_FILE" 2>/dev/null; then
            path_repo_ok=1
        fi
    fi

    local check_dir="$dir"
    [[ "$exists" -eq 1 ]] || check_dir="$(dirname "$dir")"
    local free_space
    free_space="$(df -h "$check_dir" 2>/dev/null | awk 'NR==2{print $4}')"

    echo "diretorio_existe=${exists}"
    echo "possui_conteudo=${has_content}"
    echo "path_repo_configurado=${path_repo_ok}"
    echo "espaco_livre=${free_space:-?}"
}

# Heurística: o diretório aparenta conter um repository fs do Elasticsearch?
# Não assume que todo arquivo precisa existir (varia por versão do ES).
repo_looks_valid() {
    local dir="$ES_REPOSITORY_PATH"
    [[ -d "$dir" ]] || return 1

    [[ -e "${dir}/index.latest" ]] && return 0
    [[ -d "${dir}/indices" ]] && return 0

    local match
    match="$(find "$dir" -maxdepth 1 \( -name 'index-*' -o -name 'snap-*' -o -name 'meta-*' \) -print -quit 2>/dev/null)"
    [[ -n "$match" ]]
}
