#!/usr/bin/env bash
#
# IXC Backup Recovery Tool - versão em shell
#
# Fluxo completo de restauração do Elasticsearch (localizar backup,
# descriptografar, extrair, preparar repository, registrar, restaurar,
# monitorar em tempo real) mais o menu de diagnóstico. Arquitetura modular
# (main + lib/*.sh) - nunca um único script bash gigante.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/ui.sh
source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/logger.sh
source "${SCRIPT_DIR}/lib/logger.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/lib/backup.sh"
# shellcheck source=lib/elasticsearch.sh
source "${SCRIPT_DIR}/lib/elasticsearch.sh"
# shellcheck source=lib/repository.sh
source "${SCRIPT_DIR}/lib/repository.sh"
# shellcheck source=lib/credentials.sh
source "${SCRIPT_DIR}/lib/credentials.sh"
# shellcheck source=lib/singlenode.sh
source "${SCRIPT_DIR}/lib/singlenode.sh"
# shellcheck source=lib/monitor.sh
source "${SCRIPT_DIR}/lib/monitor.sh"
# shellcheck source=lib/wizard.sh
source "${SCRIPT_DIR}/lib/wizard.sh"
# shellcheck source=lib/diagnostics.sh
source "${SCRIPT_DIR}/lib/diagnostics.sh"

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
    # `|| true`: backup_print_table retorna 1 quando não há backups (uma
    # condição esperada, já tratada com uma mensagem própria) - sem isso,
    # `set -e` encerraria a ferramenta inteira só por a lista estar vazia.
    backup_print_table || true
    ui_pause
}

# Pede a senha do Elasticsearch uma única vez, logo na abertura da
# ferramenta, e deixa em ES_PASSWORD pro resto desta execução -
# credentials_ensure_es_password (lib/credentials.sh) é idempotente, então
# nenhuma tela mais adiante (diagnóstico ou restauração) pergunta de novo.
# Só dura esta execução do .sh - fechou e abriu de novo, pede outra vez.
# `|| true`: se o operador não informar a senha agora (ex: só quer ver
# backups disponíveis), a ferramenta segue pro menu normalmente - cada tela
# que realmente precisar da senha pede na hora, como já fazia antes.
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

        # `|| true`: nenhuma ação de menu deve poder derrubar a ferramenta
        # inteira por retornar código de saída != 0 - ver comentário
        # equivalente em diagnostics_menu.
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
