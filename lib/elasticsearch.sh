#!/usr/bin/env bash
#
# Integração com o Elasticsearch: status do serviço, autenticação segura
# e cluster health.
#
# A senha (ES_PASSWORD) nunca é passada como argumento de linha de comando
# para o curl (isso apareceria em `ps aux`). Em vez de "curl -u user:senha",
# usamos "curl -K -" e entregamos as credenciais via stdin, através de um
# arquivo de configuração do curl construído na hora.

es_service_status() {
    # `systemctl is-active` retorna código de saída != 0 sempre que o
    # serviço não está "active" - mesmo assim ele já imprime o estado real
    # ("inactive", "failed", "unknown"...) em stdout. Sob `set -e`, deixar
    # esse código de saída "vazar" mataria o script inteiro só por causa do
    # Elasticsearch estar parado - por isso o `|| true` aqui, sem eco
    # adicional (que duplicaria a saída).
    systemctl is-active "${ES_SERVICE_NAME}" 2>/dev/null || true
}

# es_curl <METODO> <PATH> [corpo_json]
# Ecoa o corpo da resposta em stdout (vazio se a conexão falhar).
#
# O `|| true` no final é proposital: assim como o systemctl is-active, o
# curl retorna código de saída != 0 sempre que não consegue conectar
# (Elasticsearch offline, host errado, etc.) - uma falha totalmente
# esperada nesta ferramenta, não um bug. Sem o `|| true`, isso mataria o
# script inteiro (via `set -e`) bem no meio de um diagnóstico. Cada função
# que chama es_curl já trata resposta vazia como "sem conexão".
es_curl() {
    local method="$1"
    local path="$2"
    local body="${3:-}"

    local curl_args=(-s -X "$method" -K - "${ES_URL}${path}")
    if [[ -n "$body" ]]; then
        curl_args+=(-H "Content-Type: application/json" --data-binary "$body")
    fi

    curl "${curl_args[@]}" <<EOF || true
user = "${ES_USER}:${ES_PASSWORD}"
insecure
EOF
}

es_cluster_health() {
    es_curl GET "/_cluster/health"
}

# es_response_error_message <corpo_json>
# Ecoa uma mensagem amigável se a resposta trouxer um campo "error" (ex:
# senha errada, índice inexistente) e retorna 0. Retorna 1 se a resposta
# não parecer um erro - o chamador só deve tratar como erro quando esta
# função retorna 0. Sem essa checagem, uma resposta de erro (como um 401
# de autenticação) acaba sendo lida como se fosse um _cluster/health válido
# - o campo "status" de um erro HTTP (401) é confundido com o campo
# "status" (green/yellow/red) do cluster health, mostrando algo sem
# sentido tipo "Status: 401" em vez de dizer claramente o que houve.
es_response_error_message() {
    local response="$1"
    local error_type
    error_type="$(jq -r '.error.type // empty' <<<"$response" 2>/dev/null)"
    [[ -z "$error_type" ]] && return 1

    local reason http_status
    reason="$(jq -r '.error.reason // empty' <<<"$response" 2>/dev/null)"
    http_status="$(jq -r '.status // empty' <<<"$response" 2>/dev/null)"

    if [[ "$error_type" == "security_exception" ]]; then
        printf 'Falha de autenticação no Elasticsearch (usuário/senha incorretos) - %s' "$reason"
    else
        printf '%s - %s (HTTP %s)' "$error_type" "$reason" "${http_status:-?}"
    fi
    return 0
}

es_current_indices() {
    es_curl GET "/_cat/indices?format=json"
}

es_snapshots() {
    es_curl GET "/_snapshot/${ES_REPOSITORY}/_all?format=json"
}

es_repositories() {
    es_curl GET "/_snapshot"
}

es_register_repository() {
    local body
    body="$(printf '{"type":"fs","settings":{"location":"%s"}}' "$ES_REPOSITORY_PATH")"
    es_curl PUT "/_snapshot/${ES_REPOSITORY}" "$body"
}

# es_delete_indices <lista,separada,por,virgula>
# O chamador é responsável por montar a lista só com nomes explícitos dos
# índices do snapshot em questão - nunca um curinga.
es_delete_indices() {
    local index_csv="$1"
    es_curl DELETE "/${index_csv}"
}

es_start_restore() {
    local snapshot="$1"
    es_curl POST "/_snapshot/${ES_REPOSITORY}/${snapshot}/_restore?wait_for_completion=false" "{}"
}

es_cat_recovery() {
    local index_csv="$1"
    es_curl GET "/_cat/recovery?format=json&index=${index_csv}"
}
