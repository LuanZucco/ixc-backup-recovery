#!/usr/bin/env bash
#
# Painel de monitoramento em tempo real da restauração.
#
# Só usa dados reais retornados pelo Elasticsearch (_cat/recovery,
# _cluster/health, _cat/indices) - nunca inventa percentual; quando
# bytes_total não está disponível, mostra só o stage.

# monitor_restore <snapshot> <índice1,índice2,...> [max_wait_segundos]
#
# Preenche MONITOR_RESULT ("done" ou "timeout") direto na variável global -
# não usa stdout pra isso (evita o problema de subshell de $(...), já visto
# em singlenode_check_multi_node).
MONITOR_RESULT=""

monitor_restore() {
    local snapshot="$1"
    local index_csv="$2"
    local max_wait_seconds="${3:-21600}"

    local start_epoch
    start_epoch=$(date +%s)
    MONITOR_RESULT="timeout"

    local idx_array=()
    IFS=',' read -ra idx_array <<< "$index_csv"

    while true; do
        local now elapsed
        now=$(date +%s)
        elapsed=$(( now - start_epoch ))

        local recovery_json health_json indices_json
        recovery_json="$(es_cat_recovery "$index_csv")"
        health_json="$(es_curl GET "/_cluster/health")"
        indices_json="$(es_current_indices)"

        # `|| true` em toda chamada a jq aqui dentro é proposital: se
        # alguma resposta vier vazia/malformada (rede instável, timeout,
        # reinício do ES no meio da restauração), jq retorna erro - e sem
        # o `|| true`, isso mataria a ferramenta INTEIRA em silêncio bem no
        # meio do monitoramento (mesmo motivo do `|| true` em es_curl e
        # es_service_status, ver comentários lá). Uma leitura ruim aqui não
        # pode custar a visão de uma restauração em andamento.
        local err_msg=""
        err_msg="$(es_response_error_message "$health_json" 2>/dev/null || true)"

        local cluster_status
        if [[ -n "$err_msg" ]]; then
            cluster_status="erro"
        else
            cluster_status="$(jq -r '.status // "?"' <<<"$health_json" 2>/dev/null || true)"
            [[ -z "$cluster_status" ]] && cluster_status="?"
        fi

        ui_clear
        ui_title "RESTAURAÇÃO EM ANDAMENTO"
        echo "Snapshot: ${snapshot}"

        local color="$C_RESET"
        case "$cluster_status" in
            green) color="$C_GREEN" ;;
            yellow) color="$C_YELLOW" ;;
            red) color="$C_RED" ;;
        esac
        echo "Cluster: ${color}${cluster_status^^}${C_RESET}"
        printf 'Tempo decorrido: %02d:%02d:%02d\n' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60))
        echo "Atualização automática: ${MONITOR_INTERVAL_SECONDS}s"
        ui_hr

        if [[ -n "$err_msg" ]]; then
            ui_error "Falha temporária ao consultar o Elasticsearch: ${err_msg}"
            ui_muted "Tentando de novo na próxima atualização - a restauração no Elasticsearch"
            ui_muted "continua em segundo plano independente desta tela."
            if [[ "$elapsed" -ge "$max_wait_seconds" ]]; then
                MONITOR_RESULT="timeout"
                return 0
            fi
            sleep "$MONITOR_INTERVAL_SECONDS"
            continue
        fi

        printf "${C_CYAN}%-25s %-12s %-24s${C_RESET}\n" "ÍNDICE" "STAGE" "PROGRESSO"

        local all_done=1
        local idx
        for idx in "${idx_array[@]}"; do
            local stage="DONE" bytes_recovered=0 bytes_total=0

            local shard_data
            shard_data="$(jq -r --arg idx "$idx" '
                [.[] | select(.index == $idx and .type == "snapshot")]
                | if length == 0 then empty
                  else
                    ( [.[] | select(.stage != "DONE")] | length ) as $active
                    | ( [.[].bytes_recovered // "0" | tonumber] | add ) as $rec
                    | ( [.[].bytes_total // "0" | tonumber] | add ) as $tot
                    | "\($active)\t\($rec)\t\($tot)"
                  end
            ' <<<"$recovery_json" 2>/dev/null || true)"

            if [[ -n "$shard_data" ]]; then
                local active
                IFS=$'\t' read -r active bytes_recovered bytes_total <<<"$shard_data"
                if [[ "${active:-0}" -gt 0 ]]; then
                    stage="RESTORING"
                    all_done=0
                fi
            else
                if ! jq -e --arg idx "$idx" '.[] | select(.index == $idx)' <<<"$indices_json" >/dev/null 2>&1; then
                    stage="AGUARDANDO"
                    all_done=0
                fi
            fi

            local progress_cell
            if [[ "$stage" == "DONE" ]]; then
                progress_cell="${C_GREEN}$(ui_progress_bar 100) 100%${C_RESET}"
            elif [[ "${bytes_total:-0}" -gt 0 ]]; then
                local percent=$(( bytes_recovered * 100 / bytes_total ))
                progress_cell="$(ui_progress_bar "$percent") ${percent}%"
            else
                progress_cell="-"
            fi

            printf "%-25s %-12s %-34b\n" "$idx" "$stage" "$progress_cell"
        done

        if [[ "$all_done" -eq 1 ]]; then
            MONITOR_RESULT="done"
            return 0
        fi
        if [[ "$elapsed" -ge "$max_wait_seconds" ]]; then
            MONITOR_RESULT="timeout"
            return 0
        fi

        sleep "$MONITOR_INTERVAL_SECONDS"
    done
}
