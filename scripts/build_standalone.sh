#!/usr/bin/env bash
#
# Junta ixc-recovery.sh + lib/*.sh em um único arquivo sem dependências
# externas - pronto pra copiar e colar direto no servidor.
#
# O pacote final tem os comentários explicativos removidos (o "porquê" de
# cada peculiaridade do bash contornada continua documentado nos
# arquivos-fonte em lib/ - só o artefato final, feito pra ser colado num
# servidor, é enxuto). Passe --with-comments pra gerar sem essa etapa,
# útil na hora de depurar o próprio pacote gerado.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_PATH="${PROJECT_DIR}/dist/ixc-recovery-standalone.sh"
STRIP_COMMENTS=1

for arg in "$@"; do
    case "$arg" in
        --with-comments) STRIP_COMMENTS=0 ;;
        *) OUT_PATH="$arg" ;;
    esac
done

mkdir -p "$(dirname "${OUT_PATH}")"

RAW_PATH="$(mktemp)"
trap 'rm -f "${RAW_PATH}"' EXIT

{
    echo '#!/usr/bin/env bash'
    echo '#'
    echo '# IXC Backup Recovery Tool'
    echo '# Gerado automaticamente por scripts/build_standalone.sh - não editar direto.'
    echo '# Fonte completa (com comentários) em lib/*.sh.'
    echo '#'
    echo 'set -euo pipefail'
    echo

    for lib in ui config logger security backup elasticsearch repository credentials singlenode monitor wizard diagnostics; do
        grep -v '^#!/usr/bin/env bash' "${PROJECT_DIR}/lib/${lib}.sh"
        echo
    done

    sed \
        -e '/^#!\/usr\/bin\/env bash/d' \
        -e '/^set -euo pipefail/d' \
        -e '/^SCRIPT_DIR=/d' \
        -e '/^# shellcheck source=/d' \
        -e '/^source "\${SCRIPT_DIR}/d' \
        "${PROJECT_DIR}/ixc-recovery.sh"
} > "${RAW_PATH}"

if [[ "$STRIP_COMMENTS" -eq 1 ]]; then
    {
        head -n1 "${RAW_PATH}"
        tail -n +2 "${RAW_PATH}" | grep -vE '^[[:space:]]*(#.*)?$'
    } > "${OUT_PATH}"
else
    cp "${RAW_PATH}" "${OUT_PATH}"
fi

chmod +x "${OUT_PATH}"
bash -n "${OUT_PATH}"
echo "Gerado: ${OUT_PATH} ($(wc -l < "${OUT_PATH}") linhas, $(du -h "${OUT_PATH}" | cut -f1))"
