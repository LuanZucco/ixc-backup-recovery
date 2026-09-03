#!/usr/bin/env bash
#
# Menu de diagnóstico (somente leitura). Toda consulta autenticada ao
# Elasticsearch passa por es_query() (lib/elasticsearch.sh), que já garante
# a senha, confere jq e trata resposta vazia/erro - as funções abaixo só
# decidem o que fazer com o JSON.

diag_status_geral() {
    ui_title "STATUS GERAL"
    local state
    state="$(es_service_status)"
    if [[ "$state" == "active" ]]; then
        ui_success "Serviço ativo"
    else
        ui_warning "Serviço não ativo - systemctl: ${state}"
        journalctl -u "${ES_SERVICE_NAME}" -n 20 --no-pager 2>/dev/null | sed 's/^/  /'
        return 0
    fi

    local response
    response="$(es_query '/_cluster/health')" || return 1

    local status cluster nodes shards
    status="$(jq -r '.status // "desconhecido"' <<<"$response")"
    cluster="$(jq -r '.cluster_name // "?"' <<<"$response")"
    nodes="$(jq -r '.number_of_nodes // "?"' <<<"$response")"
    shards="$(jq -r '.active_shards // "?"' <<<"$response")"

    local color="$C_RESET"
    case "$status" in
        green)  color="$C_GREEN" ;;
        yellow) color="$C_YELLOW" ;;
        red)    color="$C_RED" ;;
    esac

    echo
    echo "Cluster: ${cluster}"
    echo "Status: ${color}${status^^}${C_RESET}"
    echo "Nós: ${nodes}"
    echo "Shards ativos: ${shards}"
}

diag_current_indices() {
    ui_title "ÍNDICES ATUAIS"
    local response
    response="$(es_query '/_cat/indices?format=json')" || return 1

    local count
    count="$(jq 'length' <<<"$response" 2>/dev/null || echo 0)"
    if [[ "$count" -eq 0 ]]; then
        ui_warning "Nenhum índice encontrado."
        return 0
    fi

    printf "${C_CYAN}%-28s %-8s %-10s %10s %10s${C_RESET}\n" "ÍNDICE" "HEALTH" "STATUS" "DOCS" "TAMANHO"
    ui_muted "----------------------------------------------------------------------"
    while IFS=$'\t' read -r idx health status docs size; do
        printf "%-28s %-8s %-10s %10s %10s\n" "$idx" "$health" "$status" "${docs:-0}" "${size:-0}"
    done < <(jq -r '.[] | [.index, .health, .status, (."docs.count" // "0"), (."store.size" // "0")] | @tsv' <<<"$response")
}

diag_snapshots() {
    ui_title "SNAPSHOTS"
    # `ignore_unavailable=true`: sem isso, UM snapshot com dados
    # incompletos/corrompidos no repository (ex: backup capturado bem no
    # meio do Elasticsearch escrever um snapshot novo) faz a API recusar
    # listar TODOS os snapshots, mesmo os que estão completos e bons -
    # visto ao vivo com um snapshot_missing_exception numa restauração
    # real. Com essa opção, o Elasticsearch pula só o(s) quebrado(s) e
    # mostra o resto normalmente.
    local response
    response="$(es_query "/_snapshot/${ES_REPOSITORY}/_all?format=json&ignore_unavailable=true")" || return 1

    local count
    count="$(jq '.snapshots | length' <<<"$response" 2>/dev/null || echo 0)"
    if [[ "$count" -eq 0 ]]; then
        ui_warning "Nenhum snapshot encontrado em '${ES_REPOSITORY}'."
        return 0
    fi

    printf "${C_CYAN}%-3s %-34s %-12s %-10s${C_RESET}\n" "#" "SNAPSHOT" "DATA" "STATUS"
    ui_muted "----------------------------------------------------------------------"
    local i=1
    while IFS=$'\t' read -r name state start_ms; do
        local date_str="?"
        if [[ -n "$start_ms" && "$start_ms" != "null" ]]; then
            date_str="$(date -d "@$((start_ms / 1000))" '+%d/%m/%Y' 2>/dev/null || echo "?")"
        fi
        local line
        line="$(printf "%-3s %-34s %-12s %-10s" "$i" "$name" "$date_str" "$state")"
        if [[ "$i" -eq 1 ]]; then
            printf '%b\n' "${C_GREEN}${line}  - MAIS RECENTE${C_RESET}"
        else
            printf '%s\n' "$line"
        fi
        i=$((i + 1))
    done < <(jq -r '.snapshots | sort_by(.start_time_in_millis) | reverse | .[] | [.snapshot, .state, (.start_time_in_millis // "null")] | @tsv' <<<"$response")
}

# Junta num só lugar tudo que envolve o repository: o que o Elasticsearch
# enxerga via API, o que existe de fato em disco, e a configuração que
# decide se o cluster é seguro pra ajuste single-node (discovery.seed_hosts,
# ELASTICS_HASHPASS) - antes eram 3 telas separadas (Repositories, Verificar
# repository, Verificar configuração) cobrindo o mesmo assunto.
diag_repository() {
    ui_title "REPOSITORY"

    echo "${C_BOLD}Registrado no Elasticsearch:${C_RESET}"
    local response
    if response="$(es_query '/_snapshot')"; then
        if [[ "$response" == "{}" ]]; then
            ui_warning "Nenhum repository registrado."
        else
            printf "${C_CYAN}%-28s %-8s %s${C_RESET}\n" "REPOSITORY" "TIPO" "LOCAL"
            while IFS=$'\t' read -r name type location; do
                printf "%-28s %-8s %s\n" "$name" "$type" "$location"
            done < <(jq -r 'to_entries[] | [.key, .value.type, (.value.settings.location // "?")] | @tsv' <<<"$response")
        fi
    fi

    echo
    echo "${C_BOLD}Diretório em disco: ${ES_REPOSITORY_PATH}${C_RESET}"
    local exists=0 has_content=0 path_repo_ok=0 free_space="?"
    while IFS='=' read -r key value; do
        case "$key" in
            diretorio_existe) exists="$value" ;;
            possui_conteudo) has_content="$value" ;;
            path_repo_configurado) path_repo_ok="$value" ;;
            espaco_livre) free_space="$value" ;;
        esac
    done < <(repo_precheck)

    [[ "$exists" -eq 1 ]] && echo "Diretório existe: Sim" || echo "Diretório existe: Não"
    [[ "$has_content" -eq 1 ]] && echo "Possui conteúdo: Sim" || echo "Possui conteúdo: Não"
    [[ "$path_repo_ok" -eq 1 ]] && echo "path.repo aponta para cá: Sim" || echo "path.repo aponta para cá: Não"
    echo "Espaço livre: ${free_space}"
    if [[ "$exists" -eq 1 ]]; then
        if repo_looks_valid; then
            ui_success "Aparenta ser um repository válido"
        else
            ui_warning "Não aparenta ser um repository Elasticsearch válido"
        fi
    fi

    echo
    echo "${C_BOLD}Configuração:${C_RESET}"
    if [[ ! -f "$ES_CONFIG_FILE" ]]; then
        ui_warning "Arquivo de configuração não encontrado: ${ES_CONFIG_FILE}"
    else
        local reasons=()
        if grep -Eq '^[[:space:]]*discovery\.seed_hosts[[:space:]]*:' "$ES_CONFIG_FILE"; then
            reasons+=("discovery.seed_hosts está definido")
        fi
        if grep -Eq '^[[:space:]]*cluster\.initial_master_nodes[[:space:]]*:.*,' "$ES_CONFIG_FILE"; then
            reasons+=("cluster.initial_master_nodes parece ter múltiplos nós")
        fi
        if [[ ${#reasons[@]} -gt 0 ]]; then
            ui_warning "Indícios de ambiente multi-node encontrados:"
            for r in "${reasons[@]}"; do
                ui_muted "  - ${r}"
            done
        else
            ui_success "Nenhum indício de ambiente multi-node encontrado."
        fi
    fi
    if [[ -f "$IXC_PARAMETER_FILE" ]]; then
        if grep -q "ELASTICS_HASHPASS" "$IXC_PARAMETER_FILE"; then
            ui_success "ELASTICS_HASHPASS localizado em: ${IXC_PARAMETER_FILE}"
        else
            ui_warning "ELASTICS_HASHPASS não encontrado em ${IXC_PARAMETER_FILE}"
        fi
    else
        ui_warning "Arquivo de parâmetros do IXC não encontrado: ${IXC_PARAMETER_FILE}"
    fi
}

diagnostics_menu() {
    while true; do
        ui_clear
        ui_title "DIAGNÓSTICO"
        local choice
        choice="$(ui_menu "" \
            "1" "Status geral - serviço e cluster" \
            "2" "Índices atuais" \
            "3" "Snapshots" \
            "4" "Repository - API, disco e configuração" \
            "0" "Voltar")"

        # `|| true` em cada chamada: várias dessas funções retornam 1 em
        # condições esperadas (Elasticsearch offline, jq ausente, sem
        # resposta) - já tratadas com uma mensagem própria. Sem o `|| true`,
        # `set -e` encerraria a ferramenta inteira nesse ponto.
        case "$choice" in
            1) diag_status_geral || true; ui_pause ;;
            2) diag_current_indices || true; ui_pause ;;
            3) diag_snapshots || true; ui_pause ;;
            4) diag_repository || true; ui_pause ;;
            0) return 0 ;;
        esac
    done
}
