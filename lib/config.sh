#!/usr/bin/env bash
#
# Configuração: valores padrão, sobrescritos por /etc/ixc-backup-recovery/config.sh
# se existir.

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
        # shellcheck disable=SC1090
        source "$override"
    fi
}
