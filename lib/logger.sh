#!/usr/bin/env bash
#
# Log por execução, com redação de segredos.
#
# Nunca escrevemos senhas de propósito, e além disso qualquer valor
# registrado como segredo (via log_register_secret) é substituído por ***
# antes de qualquer linha ir pro arquivo - mesmo que um valor acabe
# entrando por engano numa mensagem futura.

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
