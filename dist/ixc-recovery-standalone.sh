#!/usr/bin/env bash
set -euo pipefail
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_CYAN=$'\033[1;36m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_RED=$'\033[1;31m'
C_GREY=$'\033[2m'
ui_clear() {
    printf '\033[H\033[2J'
}
ui_title() {
    local text="$1"
    local padded=" $text "
    local width=${#padded}
    local border
    border=$(printf '─%.0s' $(seq 1 "$width"))
    echo
    echo "${C_CYAN}╭${border}╮${C_RESET}"
    echo "${C_CYAN}│${C_BOLD}${padded}${C_RESET}${C_CYAN}│${C_RESET}"
    echo "${C_CYAN}╰${border}╯${C_RESET}"
}
ui_subtitle() { echo; echo "${C_BOLD}$1${C_RESET}"; }
ui_success() { echo "${C_GREEN}[OK]${C_RESET} $1"; }
ui_warning() { echo "${C_YELLOW}[ATENÇÃO]${C_RESET} $1"; }
ui_error()   { echo "${C_RED}[ERRO]${C_RESET} $1" >&2; }
ui_step()    { echo "${C_GREY}→${C_RESET} $1"; }
ui_muted()   { echo "${C_GREY}$1${C_RESET}"; }
ui_menu() {
    local title="$1"; shift
    [[ -n "$title" ]] && { echo >&2; echo "${C_BOLD}${title}${C_RESET}" >&2; }
    local keys=()
    local i=1
    local n=$#
    local args=("$@")
    while [[ $i -le $n ]]; do
        local key="${args[$((i-1))]}"
        local label="${args[$i]}"
        echo "  ${C_CYAN}[${key}]${C_RESET} ${label}" >&2
        keys+=("$key")
        i=$((i+2))
    done
    local choice
    while true; do
        if ! read -r -p "Selecione uma opção: " choice; then
            ui_error "Entrada encerrada inesperadamente." >&2
            return 1
        fi
        for k in "${keys[@]}"; do
            if [[ "$choice" == "$k" ]]; then
                echo "$choice"
                return 0
            fi
        done
        ui_warning "Opção inválida." >&2
    done
}
ui_confirm_or_cancel() {
    local question="$1"
    local choice
    choice="$(ui_menu "$question" "1" "Sim, continuar" "2" "Cancelar")"
    [[ "$choice" == "1" ]]
}
ui_pause() {
    read -r -p "$(ui_muted 'Pressione ENTER para continuar')" _ || true
}
ui_prompt() {
    local label="$1"
    local value
    if ! read -r -p "${label}: " value; then
        ui_error "Não foi possível ler a entrada - stdin fechado ou indisponível." >&2
        return 1
    fi
    printf '%s' "$value"
}
ui_password() {
    local prompt="$1"
    local value
    if ! read -r -s -p "${prompt}" value; then
        echo >&2
        ui_error "Não foi possível ler a senha - stdin fechado ou indisponível." >&2
        return 1
    fi
    echo >&2
    printf '%s' "$value"
}
ui_progress_bar() {
    local percent="$1"
    local width=20
    local filled=$(( (percent * width) / 100 ))
    [[ $filled -lt 0 ]] && filled=0
    [[ $filled -gt $width ]] && filled=$width
    local bar="" i
    for ((i = 0; i < width; i++)); do
        if [[ $i -lt $filled ]]; then bar+="█"; else bar+="░"; fi
    done
    printf '%s' "$bar"
}
ui_pad() {
    local text="$1" width="$2"
    local pad=$(( width - ${#text} ))
    [[ "$pad" -lt 0 ]] && pad=0
    printf '%s%*s' "$text" "$pad" ''
}
ui_hr() {
    ui_muted "------------------------------------------------------------"
}
: "${BACKUP_DIRS:="/var/www/bkp /root /backup"}"
: "${ES_URL:="https://127.0.0.1:9200"}"
: "${ES_USER:="ixcsoft"}"
: "${ES_REPOSITORY:="backup_ixcprovedor"}"
: "${ES_REPOSITORY_PATH:="/var/lib/elasticsearch_backup/"}"
: "${ES_CONFIG_FILE:="/etc/elasticsearch/elasticsearch.yml"}"
: "${ES_SERVICE_NAME:="elasticsearch"}"
: "${ES_SYSTEM_USER:="elasticsearch"}"
: "${ES_SYSTEM_GROUP:="elasticsearch"}"
: "${IXC_PARAMETER_FILE:="/var/www/includes/ixc_parametros.php"}"
: "${LOG_DIR:="/var/log/ixc-backup-recovery"}"
: "${WORK_DIR:="/var/tmp/ixc-backup-recovery"}"
: "${MONITOR_INTERVAL_SECONDS:="2"}"
config_load() {
    local override="/etc/ixc-backup-recovery/config.sh"
    if [[ -f "$override" ]]; then
        source "$override"
    fi
}
LOG_FILE=""
declare -a _LOG_SECRETS=()
log_register_secret() {
    local value="$1"
    [[ -n "$value" ]] && _LOG_SECRETS+=("$value")
}
_log_redact() {
    local text="$1"
    local secret
    for secret in "${_LOG_SECRETS[@]:-}"; do
        [[ -n "$secret" ]] && text="${text//$secret/***}"
    done
    printf '%s' "$text"
}
log_init() {
    local dir="$LOG_DIR"
    if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w "$dir" ]]; then
        dir="${HOME:-/root}/.local/state/ixc-backup-recovery/logs"
        mkdir -p "$dir"
    fi
    LOG_FILE="${dir}/restore_$(date '+%Y-%m-%d_%H-%M-%S').log"
    : > "$LOG_FILE"
    chmod 640 "$LOG_FILE" 2>/dev/null || true
}
log_write() {
    [[ -n "$LOG_FILE" ]] || return 0
    local level="$1"; shift
    local message="$*"
    message="$(_log_redact "$message")"
    printf '%s | %-5s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "$LOG_FILE"
}
log_info()  { log_write "INFO" "$@"; }
log_warn()  { log_write "WARN" "$@"; }
log_error() { log_write "ERROR" "$@"; }
_SECURITY_DENYLIST=(
    "/" "/root" "/home" "/etc" "/var" "/var/lib" "/var/log"
    "/usr" "/bin" "/sbin" "/boot" "/dev" "/proc" "/sys"
)
security_resolve() {
    local path="$1"
    case "$path" in
        "" | "." | "/") ui_error "Caminho recusado por segurança: '${path}'"; return 1 ;;
    esac
    realpath -m -- "$path"
}
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
backup_find() {
    BACKUP_FOUND_FILES=()
    BACKUP_FOUND_SIZES=()
    local dir f size key
    local -a keyed=()
    for dir in $BACKUP_DIRS; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*.ixc; do
            [[ -f "$f" ]] || continue
            size=$(stat -c%s "$f" 2>/dev/null || echo 0)
            key="$(grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}' <<<"$(basename "$f")")"
            [[ -z "$key" ]] && key="0000_00_00-00.00.00"
            keyed+=("${key}"$'\t'"${f}"$'\t'"${size}")
        done
    done
    [[ ${#keyed[@]} -eq 0 ]] && return 0
    local f_only size_only
    while IFS=$'\t' read -r key f_only size_only; do
        BACKUP_FOUND_FILES+=("$f_only")
        BACKUP_FOUND_SIZES+=("$size_only")
    done < <(printf '%s\n' "${keyed[@]}" | sort -r -t $'\t' -k1,1)
}
backup_size_human() {
    local bytes="$1"
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB", units, " ")
        u = 1
        while (b >= 1024 && u < 5) { b /= 1024; u++ }
        printf "%.1f %s", b, units[u]
    }'
}
backup_contains_elastic() {
    local filename="$1"
    local code
    if [[ "$filename" =~ ^BKP_([A-Za-z]+)_ ]]; then
        code="${BASH_REMATCH[1]}"
    else
        return 1
    fi
    case "$code" in
        E|CS) return 0 ;;
        *) return 1 ;;
    esac
}
backup_list_elastic() {
    BACKUP_ELASTIC_FILES=()
    local f
    for f in "${BACKUP_FOUND_FILES[@]}"; do
        backup_contains_elastic "$(basename "$f")" && BACKUP_ELASTIC_FILES+=("$f")
    done
    [[ ${#BACKUP_ELASTIC_FILES[@]} -eq 0 ]] && return 1
    return 0
}
backup_find_newest_elastic() {
    backup_list_elastic || return 1
    printf '%s' "${BACKUP_ELASTIC_FILES[0]}"
}
backup_print_elastic_table() {
    local highlight="${1:-}"
    if ! backup_list_elastic; then
        ui_warning "Nenhum backup com dados do Elasticsearch encontrado nos diretórios configurados."
        return 1
    fi
    printf "${C_CYAN}%-3s %-45s %10s${C_RESET}\n" "#" "ARQUIVO" "TAMANHO"
    ui_muted "------------------------------------------------------------------"
    local i f name size
    for i in "${!BACKUP_ELASTIC_FILES[@]}"; do
        f="${BACKUP_ELASTIC_FILES[$i]}"
        name="$(basename "$f")"
        local is_newest=0 is_current=0
        [[ "$i" -eq 0 ]] && is_newest=1
        [[ -n "$highlight" && "$name" == "$highlight" ]] && is_current=1
        size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
        local line
        line="$(printf "%-3s %-45s %10s" "$((i + 1))" "$name" "$(backup_size_human "$size")")"
        if [[ "$is_newest" -eq 1 && "$is_current" -eq 1 ]]; then
            line="${line}  - MAIS RECENTE, já preparado"
        elif [[ "$is_newest" -eq 1 ]]; then
            line="${line}  - MAIS RECENTE"
        elif [[ "$is_current" -eq 1 ]]; then
            line="${line}  - já preparado"
        fi
        if [[ "$is_newest" -eq 1 ]]; then
            printf '%b\n' "${C_GREEN}${line}${C_RESET}"
        else
            printf '%s\n' "$line"
        fi
    done
    return 0
}
backup_print_table() {
    if [[ ${#BACKUP_FOUND_FILES[@]} -eq 0 ]]; then
        ui_warning "Nenhum backup .ixc encontrado nos diretórios configurados."
        ui_muted "Diretórios pesquisados: ${BACKUP_DIRS}"
        return 1
    fi
    printf "${C_CYAN}%-3s %-45s %10s  %-18s${C_RESET}\n" "#" "ARQUIVO" "TAMANHO" "ELASTIC"
    ui_muted "------------------------------------------------------------------------"
    local i marked_newest=0
    for i in "${!BACKUP_FOUND_FILES[@]}"; do
        local name is_elastic=0 is_newest=0
        name="$(basename "${BACKUP_FOUND_FILES[$i]}")"
        if backup_contains_elastic "$name"; then
            is_elastic=1
            if [[ "$marked_newest" -eq 0 ]]; then
                is_newest=1
                marked_newest=1
            fi
        fi
        local elastic_cell="—"
        [[ "$is_elastic" -eq 1 ]] && elastic_cell="✓ contém Elastic"
        local row
        row="$(printf "%-3s %-45s %10s  " "$((i + 1))" "$name" "$(backup_size_human "${BACKUP_FOUND_SIZES[$i]}")")$(ui_pad "$elastic_cell" 18)"
        [[ "$is_newest" -eq 1 ]] && row="${row}- MAIS RECENTE"
        if [[ "$is_newest" -eq 1 ]]; then
            printf '%b\n' "${C_GREEN}${row}${C_RESET}"
        elif [[ "$is_elastic" -eq 1 ]]; then
            printf '%b\n' "${C_GREEN}${row}${C_RESET}"
        else
            printf '%b\n' "${C_RED}${row}${C_RESET}"
        fi
    done
    return 0
}
backup_validate_manual_path() {
    local path="$1"
    if [[ ! -e "$path" ]]; then
        ui_error "Arquivo não encontrado: ${path}"
        return 1
    fi
    if [[ ! -f "$path" ]]; then
        ui_error "O caminho informado não é um arquivo: ${path}"
        return 1
    fi
    if [[ ! -s "$path" ]]; then
        ui_error "O arquivo está vazio: ${path}"
        return 1
    fi
    if [[ ! -r "$path" ]]; then
        ui_error "Sem permissão de leitura em: ${path}"
        return 1
    fi
    return 0
}
backup_derive_password_from_filename() {
    local filename="$1"
    local datetime
    datetime="$(grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}' <<<"$filename")"
    [[ -z "$datetime" ]] && return 1
    printf 'ixcsoft%s' "${datetime//[_.-]/}"
}
BACKUP_PASSWORD_VALUE=""
backup_obtain_password() {
    local backup_filename="$1"
    BACKUP_PASSWORD_VALUE=""
    if [[ -n "${IXC_BACKUP_PASSWORD:-}" ]]; then
        log_register_secret "$IXC_BACKUP_PASSWORD"
        BACKUP_PASSWORD_VALUE="$IXC_BACKUP_PASSWORD"
        return 0
    fi
    local derived
    if derived="$(backup_derive_password_from_filename "$backup_filename")"; then
        log_register_secret "$derived"
        ui_success "Senha derivada do nome do arquivo: ${derived}"
        BACKUP_PASSWORD_VALUE="$derived"
        return 0
    fi
    ui_warning "Não foi possível derivar a senha a partir do nome do arquivo."
    local value
    if ! read -r -p 'Senha do backup .ixc, visível: ' value; then
        ui_error "Não foi possível ler a senha do backup - stdin fechado ou indisponível."
        ui_muted "Alternativa: rode com IXC_BACKUP_PASSWORD='sua_senha' na frente do comando."
        return 1
    fi
    if [[ -z "$value" ]]; then
        ui_error "O campo de senha veio vazio - nenhuma senha foi informada."
        ui_muted "Alternativa: rode com IXC_BACKUP_PASSWORD='sua_senha' na frente do comando."
        return 1
    fi
    log_register_secret "$value"
    BACKUP_PASSWORD_VALUE="$value"
    return 0
}
backup_extract_elastic_component() {
    local backup_path="$1" password="$2" work_dir="$3" progress_file="$4"
    mkdir -p "$work_dir"
    local dest="${work_dir}/elastic_backup.tar.gz"
    local err_file="${work_dir}/.stderr"
    rm -f "$dest" "$err_file" "${work_dir}/.error_kind"
    : > "$progress_file"
    openssl aes-256-cbc -d -salt -in "$backup_path" -pass stdin <<<"$password" 2>>"$err_file" \
        | dd bs=4M status=progress 2>"$progress_file" \
        | tar -xzf - -O --wildcards -- '*elastic_backup.tar.gz' \
              > "$dest" 2>>"$err_file"
    if [[ -s "$dest" ]]; then
        printf '%s' "$dest"
        return 0
    fi
    rm -f "$dest"
    if grep -qiE 'bad decrypt|error.*decrypt|wrong final block' "$err_file" 2>/dev/null; then
        echo "senha" > "${work_dir}/.error_kind"
    else
        echo "nao_encontrado" > "${work_dir}/.error_kind"
    fi
    return 1
}
backup_extract_into_repo() {
    local tar_gz="$1" repo_path="$2" status_file="${3:-}"
    local listing
    listing="$(mktemp)"
    tar -tzf "$tar_gz" > "$listing" 2>/dev/null
    if grep -qE '(^|/)\.\.(/|$)' "$listing"; then
        ui_error "O arquivo extraído contém caminhos suspeitos do tipo ../ - abortando por segurança."
        rm -f "$listing"
        return 1
    fi
    if [[ -n "$status_file" ]]; then
        printf 'total:%s\n' "$(wc -l < "$listing" | tr -d ' ')" > "$status_file"
    fi
    rm -f "$listing"
    mkdir -p "$repo_path"
    local rc=0
    if [[ -n "$status_file" ]]; then
        tar -xzvf "$tar_gz" -C "$repo_path" >> "$status_file" 2>&1 || rc=$?
    else
        tar -xzf "$tar_gz" -C "$repo_path" || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
        ui_error "Falha ao extrair o conteúdo para o repositório do Elasticsearch."
        [[ -n "$status_file" && -s "$status_file" ]] && ui_muted "$(tail -n5 "$status_file")"
        return 1
    fi
    return 0
}
es_service_status() {
    systemctl is-active "${ES_SERVICE_NAME}" 2>/dev/null || true
}
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
es_response_error_message() {
    local response="$1"
    local error_type
    error_type="$(jq -r '.error.type // empty' <<<"$response" 2>/dev/null)"
    [[ -z "$error_type" ]] && return 1
    local reason http_status
    reason="$(jq -r '.error.reason // empty' <<<"$response" 2>/dev/null)"
    http_status="$(jq -r '.status // empty' <<<"$response" 2>/dev/null)"
    if [[ "$error_type" == "security_exception" ]]; then
        printf 'Falha de autenticação no Elasticsearch - usuário ou senha incorretos - %s' "$reason"
    else
        printf '%s - %s - HTTP %s' "$error_type" "$reason" "${http_status:-?}"
    fi
    return 0
}
es_current_indices() {
    es_curl GET "/_cat/indices?format=json"
}
es_repositories() {
    es_curl GET "/_snapshot"
}
es_register_repository() {
    local body
    body="$(printf '{"type":"fs","settings":{"location":"%s"}}' "$ES_REPOSITORY_PATH")"
    es_curl PUT "/_snapshot/${ES_REPOSITORY}" "$body"
}
es_delete_indices() {
    local index_csv="$1"
    es_curl DELETE "/${index_csv}"
}
es_start_restore() {
    local snapshot="$1" indices_csv="$2"
    local body
    body="$(printf '{"indices":"%s"}' "$indices_csv")"
    es_curl POST "/_snapshot/${ES_REPOSITORY}/${snapshot}/_restore?wait_for_completion=false" "$body"
}
es_cat_recovery() {
    local index_csv="$1"
    es_curl GET "/_cat/recovery?format=json&index=${index_csv}"
}
es_query() {
    local path="$1"
    credentials_ensure_es_password || return 1
    if ! command -v jq >/dev/null 2>&1; then
        ui_error "jq não está instalado - necessário para interpretar a resposta do Elasticsearch."
        return 1
    fi
    local response
    response="$(es_curl GET "$path")"
    if [[ -z "$response" ]]; then
        ui_error "Sem resposta do Elasticsearch em ${ES_URL}."
        return 1
    fi
    local err_msg
    if err_msg="$(es_response_error_message "$response")"; then
        ui_error "Não foi possível consultar o Elasticsearch: ${err_msg}"
        return 1
    fi
    printf '%s' "$response"
}
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
repo_looks_valid() {
    local dir="$ES_REPOSITORY_PATH"
    [[ -d "$dir" ]] || return 1
    [[ -e "${dir}/index.latest" ]] && return 0
    [[ -d "${dir}/indices" ]] && return 0
    local match
    match="$(find "$dir" -maxdepth 1 \( -name 'index-*' -o -name 'snap-*' -o -name 'meta-*' \) -print -quit 2>/dev/null)"
    [[ -n "$match" ]]
}
credentials_locate_hashpass() {
    [[ -f "$IXC_PARAMETER_FILE" ]] || return 1
    grep -oP "define\s*\(\s*['\"]ELASTICS_HASHPASS['\"]\s*,\s*['\"]\K[^'\"]*" \
        "$IXC_PARAMETER_FILE" 2>/dev/null | head -n1
}
credentials_ensure_es_password() {
    [[ -n "${ES_PASSWORD:-}" ]] && return 0
    ui_muted "Usuário Elasticsearch configurado: ${ES_USER}"
    local hashpass
    hashpass="$(credentials_locate_hashpass || true)"
    if [[ -n "$hashpass" ]]; then
        echo
        echo "Senha criptografada encontrada em ${IXC_PARAMETER_FILE}:"
        echo
        echo "  ${C_BOLD}${hashpass}${C_RESET}"
        echo
        ui_muted "Descriptografe esse valor com o procedimento já usado pela equipe"
        ui_muted "e informe abaixo a senha descriptografada."
    else
        ui_warning "ELASTICS_HASHPASS não localizado em ${IXC_PARAMETER_FILE} - informe a senha manualmente."
    fi
    local value
    if ! value="$(ui_prompt 'Senha descriptografada, visível')"; then
        ui_muted "Alternativa: rode com ES_PASSWORD='sua_senha' na frente do comando."
        return 1
    fi
    if [[ -z "$value" ]]; then
        ui_error "O campo de senha veio vazio - a autenticação vai falhar com senha em branco."
        ui_muted "Alternativa: rode com ES_PASSWORD='sua_senha' na frente do comando."
        return 1
    fi
    ES_PASSWORD="$value"
    log_register_secret "$ES_PASSWORD"
    export ES_PASSWORD
}
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
    local line
    line="$(grep -E '^[[:space:]]*cluster\.initial_master_nodes[[:space:]]*:' "$yml" | head -n1)"
    if [[ -n "$line" ]] && [[ "$(grep -o ',' <<<"$line" | wc -l)" -ge 1 ]]; then
        SINGLENODE_REASONS+=("cluster.initial_master_nodes com múltiplos nós: ${line}")
    fi
    [[ ${#SINGLENODE_REASONS[@]} -gt 0 ]] && SINGLENODE_MULTI_NODE=1
    return 0
}
singlenode_backup_config() {
    local yml="$ES_CONFIG_FILE"
    local backup="${yml}.backup-$(date '+%Y%m%d-%H%M%S')"
    cp -p "$yml" "$backup"
    printf '%s' "$backup"
}
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
WIZARD_SELECTED_BACKUP_PATH=""
WIZARD_SELECTED_BACKUP_NAME=""
WIZARD_BACKUP_PASSWORD=""
WIZARD_ELASTIC_TARGZ=""
WIZARD_SELECTED_SNAPSHOT=""
WIZARD_SNAPSHOT_INDICES_CSV=""
WIZARD_RESTORE_INDICES_CSV=""
WIZARD_STEP_LABELS=("Escolher Backup" "Senha do Backup" "Extrair Elastic" "Gravar no Disco" "Checar Cluster" "Registrar Repo" "Escolher Snapshot" "Conferir Índices" "Restaurar Dados")
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
    local source_name
    source_name="$(wizard_backup_source_name)"
    if [[ -n "$source_name" ]]; then
        ui_muted "Repository restaurado a partir do backup: ${source_name}"
        echo
    fi
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
    local prepare_rc=0
    _wizard_prepare_backup_data || prepare_rc=$?
    if [[ "$prepare_rc" -eq 2 ]]; then
        return 0
    elif [[ "$prepare_rc" -ne 0 ]]; then
        ui_pause
        return 0
    fi
    credentials_ensure_es_password || { ui_pause; return 0; }
    _wizard_validate_elasticsearch || { ui_pause; return 0; }
    _wizard_register_repository || { ui_pause; return 0; }
    _wizard_select_snapshot || { ui_pause; return 0; }
    log_info "Snapshot selecionado: ${WIZARD_SELECTED_SNAPSHOT}"
    _wizard_handle_existing_indices || { ui_pause; return 0; }
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
        case "$choice" in
            1) diag_status_geral || true; ui_pause ;;
            2) diag_current_indices || true; ui_pause ;;
            3) diag_snapshots || true; ui_pause ;;
            4) diag_repository || true; ui_pause ;;
            0) return 0 ;;
        esac
    done
}
config_load
log_init
log_info "Execução iniciada. host=$(hostname)"
check_root() {
    if [[ "${EUID}" -ne 0 && "${ALLOW_NON_ROOT:-0}" != "1" ]]; then
        ui_error "Esta ferramenta precisa ser executada como root."
        ui_muted "Use ALLOW_NON_ROOT=1 apenas para desenvolvimento/testes."
        exit 1
    fi
}
check_dependencies() {
    local missing=()
    for bin in openssl tar curl jq systemctl; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        ui_warning "Dependências ausentes: ${missing[*]}"
        local choice
        choice="$(ui_menu "" "1" "Instalar automaticamente via apt" "2" "Cancelar")"
        if [[ "$choice" != "1" ]]; then
            exit 1
        fi
        apt-get update -qq
        apt-get install -y --no-install-recommends "${missing[@]}"
    fi
}
render_header() {
    ui_clear
    ui_title "ELASTIC"
    ui_muted "Diagnósticos e Restauração"
    echo
    echo "Servidor:       $(hostname)"
    echo "Sistema:        $( . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)"
    local es_state
    es_state="$(es_service_status)"
    if [[ "$es_state" == "active" ]]; then
        echo "Elasticsearch:  ${C_GREEN}ONLINE${C_RESET}"
    else
        echo "Elasticsearch:  ${C_RED}${es_state^^}${C_RESET}"
    fi
    ui_hr
}
action_view_backups() {
    ui_title "BACKUPS DISPONÍVEIS"
    backup_find
    backup_print_table || true
    ui_pause
}
ensure_startup_password() {
    render_header
    credentials_ensure_es_password || true
    ui_pause
}
main_menu() {
    while true; do
        render_header
        local choice
        choice="$(ui_menu "" \
            "1" "Restaurar Elasticsearch" \
            "2" "Diagnóstico Elasticsearch" \
            "3" "Ver backups disponíveis" \
            "0" "Sair")"
        case "$choice" in
            1) wizard_run_restore || true ;;
            2) diagnostics_menu || true ;;
            3) action_view_backups || true ;;
            0) echo; ui_muted "Até logo."; log_info "Execução finalizada."; exit 0 ;;
        esac
    done
}
check_root
check_dependencies
ensure_startup_password
main_menu
