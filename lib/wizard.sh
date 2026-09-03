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
WIZARD_RESTORE_INDICES_CSV=""

WIZARD_STEP_LABELS=("Escolher Backup" "Senha do Backup" "Extrair Elastic" "Gravar no Disco" "Checar Cluster" "Registrar Repo" "Escolher Snapshot" "Conferir Índices" "Restaurar Dados")

# wizard_render_progress <etapa 1-9, ou 10 para "tudo concluído">
# Limpa a tela e desenha um checklist 3x3 das etapas da restauração antes
# do conteúdo de cada etapa (✓ concluída, » atual, resto em cinza) - troca
# o comportamento anterior de só empilhar título atrás de título pra baixo,
# sem nunca limpar a tela, o que fazia a restauração inteira virar uma
# rolagem só crescendo. O histórico completo continua no log e no
# scrollback do terminal, só não fica mais tudo empilhado na tela ao vivo.
wizard_render_progress() {
    local current="$1"
    ui_clear
    ui_title "RESTAURAR ELASTICSEARCH"

    local width=18
    local row col i label padded cell line
    for row in 0 1 2; do
        line=""
        for col in 0 1 2; do
            i=$(( row * 3 + col ))
            label="${WIZARD_STEP_LABELS[$i]}"
            padded="$(printf '%-*s' "$width" "$label")"
            if [[ "$i" -lt $((current - 1)) ]]; then
                cell="${C_GREEN}✓ ${padded}${C_RESET}"
            elif [[ "$i" -eq $((current - 1)) ]]; then
                cell="${C_CYAN}${C_BOLD}» ${padded}${C_RESET}"
            else
                cell="${C_GREY}  ${padded}${C_RESET}"
            fi
            line+="$cell"
        done
        echo "$line"
    done
    ui_hr
}

# Ecoa o nome do backup .ixc de onde veio o repository atual: o
# selecionado nesta execução, ou (se for uma restauração retomada) o
# marcador gravado por uma tentativa anterior - ver
# _wizard_extract_into_repo_and_fix_perms. Vazio se nenhum dos dois existir.
wizard_backup_source_name() {
    if [[ -n "$WIZARD_SELECTED_BACKUP_NAME" ]]; then
        printf '%s' "$WIZARD_SELECTED_BACKUP_NAME"
    elif [[ -f "${ES_REPOSITORY_PATH}/.ixc-backup-source" ]]; then
        head -n1 "${ES_REPOSITORY_PATH}/.ixc-backup-source" 2>/dev/null
    fi
}

_wizard_select_backup() {
    WIZARD_SELECTED_BACKUP_PATH=""
    WIZARD_SELECTED_BACKUP_NAME=""

    wizard_render_progress 1
    ui_subtitle "BACKUPS ENCONTRADOS"
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
            local num_options=() i marked_newest=0
            for i in "${!BACKUP_FOUND_FILES[@]}"; do
                local bname opt_label
                bname="$(basename "${BACKUP_FOUND_FILES[$i]}")"
                if backup_contains_elastic "$bname"; then
                    if [[ "$marked_newest" -eq 0 ]]; then
                        opt_label="${C_GREEN}${bname}  - MAIS RECENTE${C_RESET}"
                        marked_newest=1
                    else
                        opt_label="${C_GREEN}${bname}${C_RESET}"
                    fi
                else
                    opt_label="${C_RED}${bname}${C_RESET}"
                fi
                num_options+=("$((i + 1))" "$opt_label")
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
    wizard_render_progress 2
    ui_subtitle "SENHA DO BACKUP"
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
    wizard_render_progress 3
    ui_subtitle "EXTRAÇÃO DO ELASTICSEARCH"

    local work_dir="${WORK_DIR}/extract"
    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    local dest="${work_dir}/elastic_backup.tar.gz"
    local progress_file="${work_dir}/.progress"

    local total_size total_human
    total_size="$(stat -c%s "$WIZARD_SELECTED_BACKUP_PATH" 2>/dev/null || echo 0)"
    total_human="$(backup_size_human "$total_size")"

    ui_step "Descriptografando e localizando elastic_backup.tar.gz - ${total_human} no total..."
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
            ui_error "Não foi possível descriptografar o backup - senha incorreta ou arquivo corrompido."
        else
            ui_error "O componente do Elasticsearch não foi encontrado no backup, ou a senha está incorreta."
        fi
        ui_muted "Senha usada nesta tentativa: ${WIZARD_BACKUP_PASSWORD}"
        if [[ -s "${work_dir}/.stderr" ]]; then
            ui_muted "Detalhes técnicos:"
            ui_muted "$(cat "${work_dir}/.stderr")"
        fi
        return 1
    fi

    WIZARD_ELASTIC_TARGZ="$dest"
    ui_success "Arquivo extraído com sucesso - $(backup_size_human "$(stat -c%s "$dest")")"
    return 0
}

_wizard_prepare_repository() {
    wizard_render_progress 4
    ui_subtitle "PREPARAÇÃO DO REPOSITÓRIO ELASTICSEARCH"
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
        # `grep -c` já imprime "0" (não nada) quando não há match - um
        # "|| echo 0" aqui duplicaria a saída ("0\n0") bem na janela entre o
        # "total:N" ser escrito e o primeiro "item:" aparecer, quebrando a
        # conta do percentual logo abaixo.
        done_count="$(grep -c '^item:' "$status_file" 2>/dev/null)"
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

    # Registra de qual .ixc este repository veio - sobrevive a fechar e
    # abrir a ferramenta de novo (ao contrário de WIZARD_SELECTED_BACKUP_NAME,
    # que só existe na memória desta execução), então uma restauração
    # retomada de uma tentativa anterior ("REPOSITÓRIO JÁ PREPARADO") ainda
    # consegue mostrar de qual backup os snapshots vieram.
    if [[ -n "$WIZARD_SELECTED_BACKUP_NAME" ]]; then
        printf '%s\n' "$WIZARD_SELECTED_BACKUP_NAME" > "${ES_REPOSITORY_PATH}/.ixc-backup-source" 2>/dev/null || true
    fi
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
    ui_error "O Elasticsearch não conseguiu formar o cluster, ou não respondeu."

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
    ui_success "Configuração ajustada - backup em ${backup_path}"
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
    wizard_render_progress 5
    ui_subtitle "ELASTICSEARCH"
    local state
    state="$(es_service_status)"
    if [[ "$state" != "active" ]]; then
        ui_error "O serviço Elasticsearch não está operacional."
        journalctl -u "${ES_SERVICE_NAME}" -n 20 --no-pager 2>/dev/null | sed 's/^/  /'
        return 1
    fi
    ui_success "Serviço: ONLINE"

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
    wizard_render_progress 6
    ui_subtitle "REPOSITORY DO ELASTICSEARCH"
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

    wizard_render_progress 7
    ui_subtitle "SNAPSHOTS DISPONÍVEIS"

    # Deixa explícito de qual backup .ixc esses snapshots vieram - eles não
    # foram "tirados agora", são o que já existia dentro do repository do
    # Elasticsearch no momento em que aquele .ixc foi gerado (ver
    # comentário grande em backup_extract_into_repo).
    local source_name
    source_name="$(wizard_backup_source_name)"
    if [[ -n "$source_name" ]]; then
        ui_muted "Repository restaurado a partir do backup: ${source_name}"
        echo
    fi

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
        # Colunas de largura fixa (#, SNAPSHOT, DATA, STATUS) sempre
        # alinhadas - "MAIS RECENTE" vai só no final da linha, nunca dentro
        # de uma coluna (senão desalinha só aquela linha da tabela).
        local line menu_label="${names[$i]}"
        if [[ "$i" -eq 0 ]]; then
            line="$(printf "%-3s %-34s %-18s %-10s" "$((i + 1))" "${names[$i]}" "${dates[$i]}" "${states[$i]}")"
            printf '%b\n' "${C_GREEN}${line}  - MAIS RECENTE${C_RESET}"
            menu_label="${C_GREEN}${names[$i]}  - MAIS RECENTE${C_RESET}"
        else
            printf "%-3s %-34s %-18s %-10s\n" "$((i + 1))" "${names[$i]}" "${dates[$i]}" "${states[$i]}"
        fi
        options+=("$((i + 1))" "$menu_label")
    done

    local idx
    idx="$(ui_menu 'Selecione o snapshot' "${options[@]}")"
    WIZARD_SELECTED_SNAPSHOT="${names[$((idx - 1))]}"

    WIZARD_SNAPSHOT_INDICES_CSV="$(jq -r --arg name "$WIZARD_SELECTED_SNAPSHOT" \
        '.snapshots[] | select(.snapshot == $name) | .indices | join(",")' <<<"$response")"

    echo
    ui_muted "Índices no snapshot: ${WIZARD_SNAPSHOT_INDICES_CSV//,/, }"

    _wizard_select_indices_to_restore
    return 0
}

# Decide quais índices do snapshot escolhido vão ser restaurados de fato -
# por padrão todos, mas o operador pode restringir a um ou alguns (ex:
# recuperar só um índice específico sem mexer nos outros). Preenche
# WIZARD_RESTORE_INDICES_CSV (subconjunto de WIZARD_SNAPSHOT_INDICES_CSV,
# nunca um curinga - a lista final sempre vem de nomes explícitos, os
# mesmos já retornados pelo próprio snapshot). Não pergunta nada se o
# snapshot só tem um índice - não há o que escolher.
_wizard_select_indices_to_restore() {
    WIZARD_RESTORE_INDICES_CSV="$WIZARD_SNAPSHOT_INDICES_CSV"

    local idx_array=()
    IFS=',' read -ra idx_array <<< "$WIZARD_SNAPSHOT_INDICES_CSV"
    [[ ${#idx_array[@]} -le 1 ]] && return 0

    echo
    local choice
    choice="$(ui_menu "Restaurar quais índices?" \
        "1" "Todos os índices deste snapshot" \
        "2" "Selecionar índices específicos")"
    [[ "$choice" == "1" ]] && return 0

    echo
    ui_muted "Índices disponíveis neste snapshot:"
    local i
    for i in "${!idx_array[@]}"; do
        echo "  [$((i + 1))] ${idx_array[$i]}"
    done
    echo

    local raw
    raw="$(ui_prompt 'Números dos índices, separados por vírgula (ex: 1,3) - deixe em branco pra restaurar todos')"

    if [[ -z "$raw" ]]; then
        ui_muted "Restaurando todos os índices do snapshot."
        return 0
    fi

    local selected=() pieces piece pos
    IFS=',' read -ra pieces <<< "$raw"
    for piece in "${pieces[@]}"; do
        piece="$(tr -d '[:space:]' <<<"$piece")"
        [[ "$piece" =~ ^[0-9]+$ ]] || continue
        pos=$((piece - 1))
        [[ "$pos" -ge 0 && "$pos" -lt ${#idx_array[@]} ]] && selected+=("${idx_array[$pos]}")
    done

    if [[ ${#selected[@]} -eq 0 ]]; then
        ui_warning "Nenhum índice válido reconhecido no que foi digitado - restaurando todos os índices do snapshot."
        return 0
    fi

    WIZARD_RESTORE_INDICES_CSV="$(IFS=,; echo "${selected[*]}")"
    ui_success "Restaurando somente: ${WIZARD_RESTORE_INDICES_CSV//,/, }"
    return 0
}

_wizard_handle_existing_indices() {
    wizard_render_progress 8
    ui_subtitle "ÍNDICES EXISTENTES"
    local current_json
    current_json="$(es_current_indices)"

    local existing=() idx_array=() idx
    IFS=',' read -ra idx_array <<< "$WIZARD_RESTORE_INDICES_CSV"
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
    wizard_render_progress 9
    ui_subtitle "RESTAURAÇÃO DO SNAPSHOT"
    local resp
    resp="$(es_start_restore "$WIZARD_SELECTED_SNAPSHOT" "$WIZARD_RESTORE_INDICES_CSV")"

    if [[ -z "$resp" ]] || jq -e '.error' <<<"$resp" >/dev/null 2>&1; then
        ui_error "Não foi possível iniciar a restauração do snapshot '${WIZARD_SELECTED_SNAPSHOT}'."
        [[ -n "$resp" ]] && ui_muted "$(jq -r '.error.reason // .error // empty' <<<"$resp" 2>/dev/null)"
        return 1
    fi

    ui_success "Restauração iniciada"
    sleep 1

    monitor_restore "$WIZARD_SELECTED_SNAPSHOT" "$WIZARD_RESTORE_INDICES_CSV"
    return 0
}

_wizard_final_validation() {
    local started_epoch="$1"
    wizard_render_progress 10
    ui_subtitle "RESTAURAÇÃO FINALIZADA"

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

    local source_name
    source_name="$(wizard_backup_source_name)"
    [[ -n "$source_name" ]] && echo "Backup de origem: ${source_name}"
    echo "Snapshot restaurado: ${WIZARD_SELECTED_SNAPSHOT}"
    echo "Cluster: ${color}${status^^}${C_RESET}"
    echo "Índices restaurados:"

    local idx_array=() idx
    IFS=',' read -ra idx_array <<< "$WIZARD_RESTORE_INDICES_CSV"
    for idx in "${idx_array[@]}"; do
        if jq -e --arg idx "$idx" '.[] | select(.index == $idx)' <<<"$current_json" >/dev/null 2>&1; then
            ui_success "$idx"
        else
            ui_error "Índice '${idx}' não foi encontrado após a restauração."
        fi
    done

    printf 'Tempo total: %02d:%02d\n' $((elapsed / 60)) $((elapsed % 60))
    echo "Repository: ${ES_REPOSITORY}"

    log_info "Restauração concluída. backup=${source_name:-desconhecido} snapshot=${WIZARD_SELECTED_SNAPSHOT} cluster=${status} indices=${WIZARD_RESTORE_INDICES_CSV}"
}

# Mostra de qual backup os dados já prontos (repository ou componente
# extraído) vieram, se soubermos (ver wizard_backup_source_name), e lista
# TODOS os backups com dados do Elasticsearch disponíveis (E e CS - ver
# backup_print_elastic_table), não só o mais recente - quem decide qual
# usar é o operador, a ferramenta só garante que a informação pra decidir
# está toda na tela.
_wizard_show_backup_context() {
    local prepared_source
    prepared_source="$(wizard_backup_source_name)"
    if [[ -n "$prepared_source" ]]; then
        ui_muted "Backup de origem: ${prepared_source}"
    else
        ui_warning "Backup de origem: não identificado - dados de antes deste recurso."
    fi

    echo
    backup_find
    backup_print_elastic_table "$prepared_source" || true
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
        wizard_render_progress 5
        ui_subtitle "REPOSITÓRIO JÁ PREPARADO"
        ui_success "O diretório do repository já contém dados extraídos de uma tentativa anterior."
        _wizard_show_backup_context
        echo
        local resume_choice
        resume_choice="$(ui_menu "" \
            "1" "Continuar com snapshots já extraídos" \
            "2" "Selecionar backup" \
            "0" "Cancelar")"
        case "$resume_choice" in
            1) return 0 ;;
            2) ui_muted "Ok, refazendo a extração do zero." ;;
            0) return 2 ;;
        esac
    elif [[ -s "${WORK_DIR}/extract/elastic_backup.tar.gz" ]]; then
        wizard_render_progress 4
        ui_subtitle "COMPONENTE JÁ EXTRAÍDO"
        ui_success "O componente do Elasticsearch já foi extraído do backup numa tentativa anterior."
        _wizard_show_backup_context
        echo
        local resume_choice
        resume_choice="$(ui_menu "" \
            "1" "Continuar com componente já extraído" \
            "2" "Selecionar backup" \
            "0" "Cancelar")"
        case "$resume_choice" in
            1)
                WIZARD_ELASTIC_TARGZ="${WORK_DIR}/extract/elastic_backup.tar.gz"
                _wizard_prepare_repository || return 1
                _wizard_extract_into_repo_and_fix_perms || return 1
                return 0
                ;;
            2) ui_muted "Ok, refazendo a extração do zero." ;;
            0) return 2 ;;
        esac
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
