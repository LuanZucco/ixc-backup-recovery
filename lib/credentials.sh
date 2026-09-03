#!/usr/bin/env bash
#
# Localizar a senha criptografada do Elasticsearch configurada pelo
# instalador do IXC.
#
# Esta ferramenta faz só três coisas: localizar ELASTICS_HASHPASS em
# ixc_parametros.php, mostrar o valor cifrado, e receber a senha já
# descriptografada pelo operador. Ela NÃO tenta adivinhar nem implementar
# o algoritmo de descriptografia - isso continua sendo um procedimento
# externo, já conhecido pela equipe.

# Ecoa o valor de ELASTICS_HASHPASS em stdout, ou nada se não encontrar.
credentials_locate_hashpass() {
    [[ -f "$IXC_PARAMETER_FILE" ]] || return 1
    grep -oP "define\s*\(\s*['\"]ELASTICS_HASHPASS['\"]\s*,\s*['\"]\K[^'\"]*" \
        "$IXC_PARAMETER_FILE" 2>/dev/null | head -n1
}

# Garante que ES_PASSWORD está preenchida para o resto da execução: mostra
# a senha cifrada (se localizável) e pede a senha descriptografada UMA
# única vez por execução - chamadas seguintes só retornam, sem perguntar
# de novo, tanto no fluxo de diagnóstico quanto no de restauração.
credentials_ensure_es_password() {
    [[ -n "${ES_PASSWORD:-}" ]] && return 0

    ui_muted "Usuário Elasticsearch configurado: ${ES_USER}"

    # `|| true`: condição esperada quando o arquivo/valor não existe nesta
    # máquina - não deve derrubar o script (ver comentário em es_curl).
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

    # Entrada VISÍVEL de propósito (mesmo motivo da senha do backup - poder
    # conferir visualmente o que foi digitado). Nunca vai pro log
    # (log_register_secret redige qualquer ocorrência nas linhas gravadas).
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
