#!/usr/bin/env bash
#
# Fix simplificado de single-node. Só age quando NÃO há indícios claros de
# ambiente multi-node.

# Preenche SINGLENODE_MULTI_NODE (0/1) e SINGLENODE_REASONS (array) direto
# nas variáveis globais - de propósito NÃO usa "echo" pra devolver o
# resultado, porque o chamador precisaria capturar via $(...), o que roda
# a função numa subshell e faria o array de motivos se perder (só a saída
# padrão sobrevive a uma subshell, efeitos colaterais em variáveis não).
SINGLENODE_MULTI_NODE=0
declare -a SINGLENODE_REASONS=()

singlenode_check_multi_node() {
    SINGLENODE_MULTI_NODE=0
    SINGLENODE_REASONS=()
    local yml="$ES_CONFIG_FILE"

    [[ -f "$yml" ]] || return 0

    if grep -Eq '^[[:space:]]*discovery\.seed_hosts[[:space:]]*:[[:space:]]*\[.+\]' "$yml"; then
        SINGLENODE_REASONS+=("discovery.seed_hosts está definido")
    fi

    # cluster.initial_master_nodes com mais de um item na lista (mais de
    # uma vírgula fora de espaços) sugere múltiplos nós.
    local line
    line="$(grep -E '^[[:space:]]*cluster\.initial_master_nodes[[:space:]]*:' "$yml" | head -n1)"
    if [[ -n "$line" ]] && [[ "$(grep -o ',' <<<"$line" | wc -l)" -ge 1 ]]; then
        SINGLENODE_REASONS+=("cluster.initial_master_nodes com múltiplos nós: ${line}")
    fi

    [[ ${#SINGLENODE_REASONS[@]} -gt 0 ]] && SINGLENODE_MULTI_NODE=1
    return 0
}

# Cria um backup com timestamp do elasticsearch.yml. Ecoa o caminho do backup.
singlenode_backup_config() {
    local yml="$ES_CONFIG_FILE"
    local backup="${yml}.backup-$(date '+%Y%m%d-%H%M%S')"
    cp -p "$yml" "$backup"
    printf '%s' "$backup"
}

# Ajusta discovery.type: single-node no elasticsearch.yml, sem duplicar.
# Já deve ter sido confirmado por singlenode_check_multi_node que é seguro.
singlenode_apply_config() {
    local yml="$ES_CONFIG_FILE"
    local tmp
    tmp="$(mktemp)"

    if grep -Eq '^[[:space:]]*discovery\.type[[:space:]]*:' "$yml"; then
        sed -E 's/^([[:space:]]*)discovery\.type[[:space:]]*:.*/\1discovery.type: single-node/' \
            "$yml" > "$tmp"
    else
        cp "$yml" "$tmp"
        {
            echo ""
            echo "# Adicionado automaticamente pelo IXC Backup Recovery Tool ($(date '+%Y-%m-%dT%H:%M:%S'))"
            echo "discovery.type: single-node"
        } >> "$tmp"
    fi

    cat "$tmp" > "$yml"
    rm -f "$tmp"
}

singlenode_restart_elasticsearch() {
    local wait_seconds="${1:-20}"
    systemctl restart "${ES_SERVICE_NAME}" || {
        ui_error "Falha ao reiniciar o Elasticsearch."
        return 1
    }
    sleep "$wait_seconds"
    return 0
}
