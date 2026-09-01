#!/usr/bin/env bash
#
# Fluxo guiado completo de restauração do Elasticsearch, com confirmação
# apenas nos pontos reais de decisão: limpar repository existente, senha
# do ES, substituir índices existentes e (condicional) configurar
# single-node. Tudo o resto é automático.

WIZARD_SELECTED_BACKUP_PATH=""
WIZARD_SELECTED_BACKUP_NAME=""
WIZARD_BACKUP_PASSWORD=""
WIZARD_ELASTIC_TARGZ=""
WIZARD_SELECTED_SNAPSHOT=""
WIZARD_SNAPSHOT_INDICES_CSV=""

_wizard_select_backup() {
    WIZARD_SELECTED_BACKUP_PATH=""
    WIZARD_SELECTED_BACKUP_NAME=""

    ui_title "BACKUPS ENCONTRADOS"
    backup_find

    if [[ ${#BACKUP_FOUND_FILES[@]} -gt 0 ]]; then
        backup_print_table || true
    else
        ui_warning "Nenhum backup .ixc encontrado nos diretórios configurados."
    fi

    local options=()
    [[ ${#BACKUP_FOUND_FILES[@]} -gt 0 ]] && options+=("1" "Selecionar backup pelo número acima")
    options+=("2" "Informar caminho manualmente")
    options+=("0" "Voltar")

    local choice
    choice="$(ui_menu "" "${options[@]}")"

    case "$choice" in
        0) return 1 ;;
        1)
            local num_options=() i
            for i in "${!BACKUP_FOUND_FILES[@]}"; do
                num_options+=("$((i + 1))" "$(basename "${BACKUP_FOUND_FILES[$i]}")")
            done
            local idx
            idx="$(ui_menu 'Número do backup' "${num_options[@]}")"
            WIZARD_SELECTED_BACKUP_PATH="${BACKUP_FOUND_FILES[$((idx - 1))]}"
            ;;
        2)
            local raw_path
            raw_path="$(ui_prompt 'Caminho completo do backup')"
            if ! backup_validate_manual_path "$raw_path"; then
                ui_pause
                return 1
            fi
            WIZARD_SELECTED_BACKUP_PATH="$raw_path"
            ;;
    esac

    WIZARD_SELECTED_BACKUP_NAME="$(basename "$WIZARD_SELECTED_BACKUP_PATH")"
    return 0
}

_wizard_obtain_password() {
    ui_title "SENHA DO BACKUP"
    if ! backup_obtain_password "$WIZARD_SELECTED_BACKUP_NAME"; then
        return 1
    fi
    WIZARD_BACKUP_PASSWORD="$BACKUP_PASSWORD_VALUE"
    return 0
}

# Descriptografa e extrai o componente do Elasticsearch em UMA passada só
# (ver comentário grande em backup_extract_elastic_component - antes eram
# duas passadas pelo stream, uma pra "analisar" e outra pra extrair, o que
# dobrava o tempo de leitura em backups grandes). Roda em segundo plano
# mostrando o throughput real (via dd status intermediário) e o total já
# processado do arquivo .ixc - não só o arquivo de saída crescendo, que só
# começa a crescer quando o tar finalmente alcança o componente do ES.
_wizard_extract_component() {
    ui_title "EXTRAÇÃO DO ELASTICSEARCH"

    local work_dir="${WORK_DIR}/extract"
    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    local dest="${work_dir}/elastic_backup.tar.gz"
    local progress_file="${work_dir}/.progress"

    local total_size total_human
    total_size="$(stat -c%s "$WIZARD_SELECTED_BACKUP_PATH" 2>/dev/null || echo 0)"
    total_human="$(backup_size_human "$total_size")"

    ui_step "Descriptografando e localizando elastic_backup.tar.gz (${total_human} no total)..."
    ui_muted "O componente do Elasticsearch pode estar em qualquer ponto do arquivo -"
    ui_muted "o progresso abaixo é do backup inteiro sendo lido, não só do resultado."

    backup_extract_elastic_component "$WIZARD_SELECTED_BACKUP_PATH" "$WIZARD_BACKUP_PASSWORD" \
        "$work_dir" "$progress_file" >/dev/null 2>&1 &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        local last
        last="$(tail -c 400 "$progress_file" 2>/dev/null | tr '\r' '\n' | grep -v '^$' | tail -n1)"
        if [[ -n "$last" ]]; then
            printf '\r  %s   ' "$last"
        fi
        sleep 1
    done
    wait "$pid" 2>/dev/null || true
    printf '\r%100s\r' " "

    if [[ ! -s "$dest" ]]; then
        local kind="desconhecido"
        [[ -f "${work_dir}/.error_kind" ]] && kind="$(cat "${work_dir}/.error_kind")"
        if [[ "$kind" == "senha" ]]; then
            ui_error "Não foi possível descriptografar o backup (senha incorreta ou arquivo corrompido)."
        else
            ui_error "O componente do Elasticsearch não foi encontrado no backup (ou a senha está incorreta)."
        fi
        ui_muted "Senha usada nesta tentativa: ${WIZARD_BACKUP_PASSWORD}"
        if [[ -s "${work_dir}/.stderr" ]]; then
            ui_muted "Detalhes técnicos:"
            ui_muted "$(cat "${work_dir}/.stderr")"
        fi
        return 1
    fi

    WIZARD_ELASTIC_TARGZ="$dest"
    ui_success "Arquivo extraído com sucesso ($(backup_size_human "$(stat -c%s "$dest")"))"
    return 0
}

_wizard_prepare_repository() {
    ui_title "PREPARAÇÃO DO REPOSITÓRIO ELASTICSEARCH"
    ui_muted "Diretório: ${ES_REPOSITORY_PATH}"

    local exists=0 has_content=0
    while IFS='=' read -r key value; do
        case "$key" in
            diretorio_existe) exists="$value" ;;
            possui_conteudo) has_content="$value" ;;
            espaco_livre) ui_muted "Espaço livre: ${value}" ;;
        esac
    done < <(repo_precheck)

    if [[ "$has_content" -eq 1 ]]; then
        ui_warning "Foi encontrado conteúdo existente no repositório Elasticsearch."
        if ! ui_confirm_or_cancel "Limpar e preparar para esta restauração?"; then
            return 1
        fi
        if ! _wizard_clean_repository_with_feedback; then
            return 1
        fi
        ui_success "Repositório limpo"
    fi
    return 0
}

# Um repository do Elasticsearch pode ter muitos arquivos pequenos - "rm -rf"
# nisso pode levar um bom tempo sem dar sinal nenhum de vida. Roda em
# segundo plano mostrando o item atual sendo removido e o tempo decorrido.
_wizard_clean_repository_with_feedback() {
    local status_file
    status_file="$(mktemp)"
    local start_epoch
    start_epoch=$(date +%s)

    security_safe_clean_directory "$ES_REPOSITORY_PATH" "$ES_REPOSITORY_PATH" "$status_file" &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        local elapsed total done_count last bar
        elapsed=$(( $(date +%s) - start_epoch ))
        total="$(grep -m1 '^total:' "$status_file" 2>/dev/null | cut -d: -f2)"
        done_count="$(grep -c '^item:' "$status_file" 2>/dev/null || echo 0)"
        last="$(grep '^item:' "$status_file" 2>/dev/null | tail -n1 | cut -d: -f2-)"

        if [[ -n "$total" && "$total" -gt 0 ]]; then
            local percent=$(( done_count * 100 / total ))
            bar="$(ui_progress_bar "$percent")"
            printf '\r  %s %d%% (%d/%s) removendo: %.30s (%ds)   ' \
                "$bar" "$percent" "$done_count" "$total" "${last:-...}" "$elapsed"
        else
            printf '\r  Removendo... (%ds)   ' "$elapsed"
        fi
        sleep 1
    done
    wait "$pid" 2>/dev/null || true
    printf '\r%100s\r' " "

    local ok=0
    grep -q '^concluido$' "$status_file" 2>/dev/null && ok=1
    rm -f "$status_file"

    if [[ "$ok" -ne 1 ]]; then
        ui_error "Não foi possível limpar o diretório do repositório com segurança."
        return 1
    fi
    return 0
}

# Roda backup_extract_into_repo em segundo plano mostrando o arquivo atual
# sendo extraído, a contagem de arquivos já extraídos e o tempo decorrido -
# mesmo princípio da extração do .ixc e da limpeza do repository: nunca
# ficar em silêncio numa operação que pode levar minutos.
_wizard_extract_into_repo_with_feedback() {
    local status_file
    status_file="$(mktemp)"
    local start_epoch
    start_epoch=$(date +%s)

    backup_extract_into_repo "$WIZARD_ELASTIC_TARGZ" "$ES_REPOSITORY_PATH" "$status_file" &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        local elapsed total done_count last bar
        elapsed=$(( $(date +%s) - start_epoch ))
        total="$(grep -m1 '^total:' "$status_file" 2>/dev/null | cut -d: -f2)"
        # A 1ª linha do arquivo é "total:N" (ver backup_extract_into_repo) -
        # as demais são o nome de cada arquivo já extraído pelo `tar -v`.
        done_count=$(( $(wc -l < "$status_file" 2>/dev/null | tr -d ' ') - 1 ))
        [[ "$done_count" -lt 0 ]] && done_count=0
        last="$(tail -n1 "$status_file" 2>/dev/null)"

        if [[ -n "$total" && "$total" -gt 0 ]]; then
            local percent=$(( done_count * 100 / total ))
            [[ "$percent" -gt 100 ]] && percent=100
            bar="$(ui_progress_bar "$percent")"
            printf '\r  %s %d%% (%d/%s arquivos) - atual: %.30s (%ds)   ' \
                "$bar" "$percent" "$done_count" "$total" "${last:-...}" "$elapsed"
        else
            printf '\r  Extraindo... (%ds)   ' "$elapsed"
        fi
        sleep 1
    done

    local rc=0
    wait "$pid" || rc=$?
    printf '\r%100s\r' " "
    rm -f "$status_file"

    if [[ "$rc" -ne 0 ]]; then
        return 1
    fi
    return 0
}

_wizard_extract_into_repo_and_fix_perms() {
    ui_step "Extraindo conteúdo para o repositório do Elasticsearch..."
    ui_muted "Escrita real em disco - normal ser a etapa mais demorada."
    if ! _wizard_extract_into_repo_with_feedback; then
        return 1
    fi
    ui_success "Conteúdo extraído para o repositório"

    if ! repo_looks_valid; then
        ui_warning "O conteúdo extraído não aparenta ser um repository Elasticsearch válido."
    fi

    if ! chown -R "${ES_SYSTEM_USER}:${ES_SYSTEM_GROUP}" "$ES_REPOSITORY_PATH" 2>/dev/null; then
        ui_error "Falha ao corrigir as permissões do repositório."
        return 1
    fi
    ui_success "Permissões do repository corrigidas"
    return 0
}

_wizard_print_health() {
    local health_json="$1"
    local status cluster nodes shards
    status="$(jq -r '.status // "?"' <<<"$health_json" 2>/dev/null)"
    cluster="$(jq -r '.cluster_name // "?"' <<<"$health_json" 2>/dev/null)"
    nodes="$(jq -r '.number_of_nodes // "?"' <<<"$health_json" 2>/dev/null)"
    shards="$(jq -r '.active_shards // "?"' <<<"$health_json" 2>/dev/null)"

    local color="$C_RESET"
    case "$status" in
        green) color="$C_GREEN" ;;
        yellow) color="$C_YELLOW" ;;
        red) color="$C_RED" ;;
    esac

    echo "Cluster: ${cluster}"
    echo "Status: ${color}${status^^}${C_RESET}"
    echo "Nós: ${nodes}"
    echo "Shards ativos: ${shards}"
    [[ "$status" == "yellow" ]] && ui_warning "Cluster em estado YELLOW - prosseguindo com atenção."
}

_wizard_handle_cluster_problem() {
    ui_error "O Elasticsearch não conseguiu formar o cluster (ou não respondeu)."

    if [[ ! -f "$ES_CONFIG_FILE" ]]; then
        ui_warning "Arquivo de configuração não encontrado: ${ES_CONFIG_FILE}"
        return 1
    fi

    singlenode_check_multi_node
    if [[ "$SINGLENODE_MULTI_NODE" -eq 1 ]]; then
        ui_warning "Existem configurações que podem indicar um ambiente multi-node."
        ui_warning "A configuração automática como single-node foi bloqueada."
        local r
        for r in "${SINGLENODE_REASONS[@]}"; do
            ui_muted "  - ${r}"
        done
        return 1
    fi

    ui_title "PROBLEMA DE CLUSTER DETECTADO"
    echo "O Elasticsearch não conseguiu formar o cluster."
    if ! ui_confirm_or_cancel "Deseja configurar o Elasticsearch como single-node e reiniciar?"; then
        return 1
    fi

    local backup_path
    backup_path="$(singlenode_backup_config)"
    ui_success "Configuração ajustada (backup em ${backup_path})"
    singlenode_apply_config
    ui_step "Reiniciando o Elasticsearch..."
    singlenode_restart_elasticsearch 20 || return 1

    local health_json status
    health_json="$(es_curl GET "/_cluster/health")"
    status="$(jq -r '.status // ""' <<<"$health_json" 2>/dev/null)"
    if [[ -z "$status" ]]; then
        ui_error "Não foi possível confirmar a saúde do cluster após o reinício."
        return 1
    fi
    _wizard_print_health "$health_json"
    [[ "$status" == "red" ]] && return 1
    return 0
}

_wizard_validate_elasticsearch() {
    ui_title "ELASTICSEARCH"
    local state
    state="$(es_service_status)"
    if [[ "$state" != "active" ]]; then
        ui_error "O serviço Elasticsearch não está operacional."
        journalctl -u "${ES_SERVICE_NAME}" -n 20 --no-pager 2>/dev/null | sed 's/^/  /'
        return 1
    fi
    ui_success "Serviço: ONLINE (${state})"

    local health_json
    health_json="$(es_curl GET "/_cluster/health")"

    local err_msg
    if err_msg="$(es_response_error_message "$health_json")"; then
        ui_error "Não foi possível consultar o cluster: ${err_msg}"
        return 1
    fi

    local status
    status="$(jq -r '.status // ""' <<<"$health_json" 2>/dev/null)"

    # "cmd || rc=$?; return $rc" (nunca "cmd" solta seguida de "return $?")
    # é obrigatório: sob `set -e`, uma chamada solta que retorna != 0 mata
    # o script antes da linha seguinte rodar, mesmo que essa linha seja só
    # "return $?" (mesma peculiaridade documentada em wizard_run_restore).
    local cluster_rc

    if [[ -z "$health_json" || -z "$status" ]]; then
        cluster_rc=0
        _wizard_handle_cluster_problem || cluster_rc=$?
        return "$cluster_rc"
    fi

    _wizard_print_health "$health_json"

    if [[ "$status" == "red" ]]; then
        cluster_rc=0
        _wizard_handle_cluster_problem || cluster_rc=$?
        return "$cluster_rc"
    fi
    return 0
}

_wizard_register_repository() {
    ui_title "REPOSITORY DO ELASTICSEARCH"
    local repos_json
    repos_json="$(es_repositories)"

    local err_msg
    if err_msg="$(es_response_error_message "$repos_json")"; then
        ui_error "Não foi possível consultar os repositories: ${err_msg}"
        return 1
    fi

    if jq -e --arg name "$ES_REPOSITORY" 'has($name)' <<<"$repos_json" >/dev/null 2>&1; then
        ui_success "Repository configurado com sucesso"
        return 0
    fi

    local resp
    resp="$(es_register_repository)"
    if err_msg="$(es_response_error_message "$resp")"; then
        ui_error "O Elasticsearch não conseguiu registrar o repository '${ES_REPOSITORY}': ${err_msg}"
        return 1
    fi
    if ! jq -e '.acknowledged == true' <<<"$resp" >/dev/null 2>&1; then
        ui_error "O Elasticsearch não conseguiu registrar o repository '${ES_REPOSITORY}'."
        [[ -n "$resp" ]] && ui_muted "$resp"
        return 1
    fi
    ui_success "Repository configurado com sucesso"
    return 0
}

_wizard_select_snapshot() {
    WIZARD_SELECTED_SNAPSHOT=""
    WIZARD_SNAPSHOT_INDICES_CSV=""

    ui_title "SNAPSHOTS DISPONÍVEIS"
    local response
    response="$(es_snapshots)"
    local count
    count="$(jq '.snapshots | length' <<<"$response" 2>/dev/null || echo 0)"
    if [[ "$count" -eq 0 ]]; then
        ui_warning "Nenhum snapshot disponível neste repository."
        return 1
    fi

    local names=() dates=() states=()
    while IFS=$'\t' read -r name state start_ms; do
        names+=("$name")
        states+=("$state")
        if [[ -n "$start_ms" && "$start_ms" != "null" ]]; then
            dates+=("$(date -d "@$((start_ms / 1000))" '+%d/%m/%Y %H:%M' 2>/dev/null || echo '?')")
        else
            dates+=("?")
        fi
    done < <(jq -r '.snapshots | sort_by(.start_time_in_millis) | reverse | .[] | [.snapshot, .state, (.start_time_in_millis // "null")] | @tsv' <<<"$response")

    printf "${C_CYAN}%-3s %-34s %-18s %-10s${C_RESET}\n" "#" "SNAPSHOT" "DATA" "STATUS"
    ui_hr
    local i options=()
    for i in "${!names[@]}"; do
        local label="${names[$i]}"
        [[ "$i" -eq 0 ]] && label="${label}  (MAIS RECENTE)"
        printf "%-3s %-34s %-18s %-10s\n" "$((i + 1))" "$label" "${dates[$i]}" "${states[$i]}"
        options+=("$((i + 1))" "${names[$i]}")
    done

    local idx
    idx="$(ui_menu 'Selecione o snapshot' "${options[@]}")"
    WIZARD_SELECTED_SNAPSHOT="${names[$((idx - 1))]}"

    WIZARD_SNAPSHOT_INDICES_CSV="$(jq -r --arg name "$WIZARD_SELECTED_SNAPSHOT" \
        '.snapshots[] | select(.snapshot == $name) | .indices | join(",")' <<<"$response")"

    echo
    ui_muted "Índices no snapshot: ${WIZARD_SNAPSHOT_INDICES_CSV//,/, }"
    return 0
}

_wizard_handle_existing_indices() {
    ui_title "ÍNDICES EXISTENTES"
    local current_json
    current_json="$(es_current_indices)"

    local existing=() idx_array=() idx
    IFS=',' read -ra idx_array <<< "$WIZARD_SNAPSHOT_INDICES_CSV"
    for idx in "${idx_array[@]}"; do
        if jq -e --arg idx "$idx" '.[] | select(.index == $idx)' <<<"$current_json" >/dev/null 2>&1; then
            existing+=("$idx")
        fi
    done

    [[ ${#existing[@]} -eq 0 ]] && return 0

    echo "Foram encontrados índices que serão substituídos:"
    echo
    local e
    for e in "${existing[@]}"; do
        echo "  - $e"
    done

    if ! ui_confirm_or_cancel "Remover índices atuais e restaurar backup?"; then
        return 1
    fi

    local joined
    joined="$(IFS=,; echo "${existing[*]}")"
    local resp
    resp="$(es_delete_indices "$joined")"
    if ! jq -e '.acknowledged == true' <<<"$resp" >/dev/null 2>&1; then
        ui_error "O Elasticsearch não conseguiu confirmar a remoção dos índices."
        [[ -n "$resp" ]] && ui_muted "$resp"
        return 1
    fi

    local health_json status
    health_json="$(es_curl GET "/_cluster/health")"
    status="$(jq -r '.status // ""' <<<"$health_json" 2>/dev/null)"
    if [[ "$status" == "red" ]]; then
        ui_error "O cluster ficou em estado RED após a remoção dos índices."
        return 1
    fi
    return 0
}

_wizard_start_and_monitor() {
    ui_title "RESTAURAÇÃO DO SNAPSHOT"
    local resp
    resp="$(es_start_restore "$WIZARD_SELECTED_SNAPSHOT")"

    if [[ -z "$resp" ]] || jq -e '.error' <<<"$resp" >/dev/null 2>&1; then
        ui_error "Não foi possível iniciar a restauração do snapshot '${WIZARD_SELECTED_SNAPSHOT}'."
        [[ -n "$resp" ]] && ui_muted "$(jq -r '.error.reason // .error // empty' <<<"$resp" 2>/dev/null)"
        return 1
    fi

    ui_success "Restauração iniciada"
    sleep 1

    monitor_restore "$WIZARD_SELECTED_SNAPSHOT" "$WIZARD_SNAPSHOT_INDICES_CSV"
    return 0
}

_wizard_final_validation() {
    local started_epoch="$1"
    ui_title "RESTAURAÇÃO FINALIZADA"

    local health_json status current_json
    health_json="$(es_curl GET "/_cluster/health")"
    status="$(jq -r '.status // "?"' <<<"$health_json" 2>/dev/null)"
    current_json="$(es_current_indices)"

    local color="$C_RESET"
    case "$status" in
        green) color="$C_GREEN" ;;
        yellow) color="$C_YELLOW" ;;
        red) color="$C_RED" ;;
    esac

    local now elapsed
    now=$(date +%s)
    elapsed=$(( now - started_epoch ))

    echo "Snapshot restaurado: ${WIZARD_SELECTED_SNAPSHOT}"
    echo "Cluster: ${color}${status^^}${C_RESET}"
    echo "Índices restaurados:"

    local idx_array=() idx
    IFS=',' read -ra idx_array <<< "$WIZARD_SNAPSHOT_INDICES_CSV"
    for idx in "${idx_array[@]}"; do
        if jq -e --arg idx "$idx" '.[] | select(.index == $idx)' <<<"$current_json" >/dev/null 2>&1; then
            ui_success "$idx"
        else
            ui_error "Índice '${idx}' não foi encontrado após a restauração."
        fi
    done

    printf 'Tempo total: %02d:%02d\n' $((elapsed / 60)) $((elapsed % 60))
    echo "Repository: ${ES_REPOSITORY}"

    log_info "Restauração concluída. snapshot=${WIZARD_SELECTED_SNAPSHOT} cluster=${status} indices=${WIZARD_SNAPSHOT_INDICES_CSV}"
}

# Fases caras (decifrar+ler o .ixc inteiro, escrever os dados do ES em
# disco) não devem ser refeitas só porque uma etapa BARATA mais adiante
# falhou (senha do Elasticsearch errada, cluster indisponível, etc.) - em
# um backup de 40GB isso pode significar refazer 10+ minutos de trabalho
# por causa de um typo na senha do ES. Por isso, antes de começar do zero,
# verifica se já existe trabalho reaproveitável de uma tentativa anterior -
# a checagem é sobre arquivos reais em disco (o diretório do repository e
# /var/tmp), então funciona mesmo fechando e abrindo a ferramenta de novo,
# não só dentro da mesma sessão.
_wizard_prepare_backup_data() {
    if repo_looks_valid; then
        ui_title "REPOSITÓRIO JÁ PREPARADO"
        ui_success "O diretório do repository já contém dados extraídos de uma tentativa anterior."
        if ui_confirm_or_cancel "Pular a extração do backup e continuar direto da senha do Elasticsearch?"; then
            return 0
        fi
        ui_muted "Ok, refazendo a extração do zero."
    elif [[ -s "${WORK_DIR}/extract/elastic_backup.tar.gz" ]]; then
        ui_title "COMPONENTE JÁ EXTRAÍDO"
        ui_success "O componente do Elasticsearch já foi extraído do backup numa tentativa anterior."
        if ui_confirm_or_cancel "Pular a descriptografia do backup e continuar direto da preparação do repositório?"; then
            WIZARD_ELASTIC_TARGZ="${WORK_DIR}/extract/elastic_backup.tar.gz"
            _wizard_prepare_repository || return 1
            _wizard_extract_into_repo_and_fix_perms || return 1
            return 0
        fi
        ui_muted "Ok, refazendo a extração do zero."
    fi

    local rc=0
    _wizard_select_backup || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        return 2  # "Voltar" deliberado - sem mensagem de erro pra pausar
    fi
    log_info "Backup selecionado: ${WIZARD_SELECTED_BACKUP_PATH}"

    _wizard_obtain_password || return 1
    _wizard_extract_component || return 1
    _wizard_prepare_repository || return 1
    _wizard_extract_into_repo_and_fix_perms || return 1
    return 0
}

wizard_run_restore() {
    local started_epoch
    started_epoch=$(date +%s)

    # "_wizard_prepare_backup_data || prepare_rc=$?" (não uma chamada nua
    # seguida de "local rc=$?") é obrigatório aqui: sob `set -e`, uma
    # função chamada como instrução solta que retorna != 0 mata o script
    # ANTES da linha seguinte rodar, mesmo que essa linha seja só "rc=$?".
    # Confirmado testando - é a mesma peculiaridade de sempre, só que
    # dessa vez em uma chamada direta (nem precisa de "$(...)" pra
    # acontecer).
    local prepare_rc=0
    _wizard_prepare_backup_data || prepare_rc=$?
    if [[ "$prepare_rc" -eq 2 ]]; then
        return 0
    elif [[ "$prepare_rc" -ne 0 ]]; then
        ui_pause
        return 0
    fi

    # IMPORTANTE: as etapas abaixo usam "|| { ui_pause; return 0; }" - sem
    # isso, ao abortar aqui o controle volta pro main_menu, que limpa a
    # tela (ui_clear) na PRÓXIMA linha antes do operador conseguir ler a
    # última mensagem de erro, dando a falsa impressão de que "simplesmente
    # voltou pro menu" sem motivo.
    credentials_ensure_es_password || { ui_pause; return 0; }

    _wizard_validate_elasticsearch || { ui_pause; return 0; }
    _wizard_register_repository || { ui_pause; return 0; }
    _wizard_select_snapshot || { ui_pause; return 0; }
    log_info "Snapshot selecionado: ${WIZARD_SELECTED_SNAPSHOT}"
    _wizard_handle_existing_indices || { ui_pause; return 0; }

    # `|| true` nas duas chamadas abaixo: a restauração já foi disparada no
    # Elasticsearch nesse ponto - uma falha ao MOSTRAR o progresso ou o
    # resumo final (rede instável, resposta malformada) não pode derrubar
    # a ferramenta nem esconder que a restauração está rodando.
    _wizard_start_and_monitor || true
    if [[ "$MONITOR_RESULT" != "done" ]]; then
        ui_warning "A restauração ainda pode estar em andamento no Elasticsearch;"
        ui_warning "verifique novamente em Diagnóstico > Cluster Health / Índices atuais."
    fi

    _wizard_final_validation "$started_epoch" || true

    rm -rf "${WORK_DIR}/extract" 2>/dev/null || true

    ui_pause
    return 0
}
