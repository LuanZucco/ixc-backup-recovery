#!/usr/bin/env bash
#
# Empacota a ferramenta em um único arquivo (sem dependências externas) e
# envia para um servidor remoto via scp/ssh, instalando lá - tudo a partir
# do seu próprio terminal, sem nenhum passo manual de copiar/colar.
#
# Uso:
#   ./scripts/deploy.sh usuario@servidor [porta_ssh]
#
# Requisitos no servidor: bash, openssl, tar, curl, jq, systemctl (todos
# padrão em Debian/Ubuntu, exceto jq - a própria ferramenta oferece
# instalar se faltar). Sem instalação de pacotes adicionais.
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Uso: $0 usuario@servidor [porta_ssh]" >&2
    exit 1
fi

TARGET="$1"
PORT="${2:-22}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_NAME="ixc-recovery.sh"
INSTALL_DIR="/opt/ixc-backup-recovery"
BIN_LINK="/usr/local/bin/ixc-backup-recovery"
LOG_DIR="/var/log/ixc-backup-recovery"

echo "[*] Empacotando em um único arquivo..."
"${PROJECT_DIR}/scripts/build_standalone.sh" "${PROJECT_DIR}/dist/${PACKAGE_NAME}"

echo
echo "[*] Enviando para ${TARGET} (porta ${PORT})..."
ssh -p "${PORT}" "${TARGET}" "mkdir -p ~/ixc-backup-recovery-deploy"
scp -P "${PORT}" -q "${PROJECT_DIR}/dist/${PACKAGE_NAME}" "${TARGET}:~/ixc-backup-recovery-deploy/"

echo
echo "[*] Instalando remotamente..."
echo

REMOTE_CMD=$(cat <<EOF
set -e
SRC="\$HOME/ixc-backup-recovery-deploy/${PACKAGE_NAME}"
chmod +x "\$SRC"

install_it() {
    mkdir -p "${INSTALL_DIR}"
    install -m 750 "\$SRC" "${INSTALL_DIR}/${PACKAGE_NAME}"
    mkdir -p "${LOG_DIR}"
    chmod 750 "${LOG_DIR}"
    cat > "${BIN_LINK}" <<WRAPPER
#!/usr/bin/env bash
exec "${INSTALL_DIR}/${PACKAGE_NAME}" "\\\$@"
WRAPPER
    chmod 755 "${BIN_LINK}"
    echo "[OK] Instalado. Rode: ixc-backup-recovery"
}

if [ "\$(id -u)" -eq 0 ]; then
    install_it
elif command -v sudo >/dev/null 2>&1; then
    sudo bash -c "\$(declare -f install_it); install_it"
else
    echo "[ERRO] Sessão não é root e 'sudo' não está disponível." >&2
    echo "Conecte como root e rode: bash \$SRC" >&2
    exit 1
fi
EOF
)

ssh -p "${PORT}" -t "${TARGET}" "${REMOTE_CMD}"

echo
echo "[OK] Instalação concluída em ${TARGET}."
echo
echo "Para usar agora:"
echo "  ssh -p ${PORT} ${TARGET} -t 'ixc-backup-recovery'"
