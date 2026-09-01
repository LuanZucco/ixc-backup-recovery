#!/usr/bin/env bash
#
# Helpers visuais: cores, painéis, tabelas e menus numerados.
# Sem "echo/read/clear" soltos - tudo passa por essas funções.

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_CYAN=$'\033[1;36m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_RED=$'\033[1;31m'
C_GREY=$'\033[2m'

ui_clear() {
    # Só move o cursor pro topo e apaga a tela visível (\033[H\033[2J).
    # Não usamos o comando `clear` porque em terminais modernos (xterm e
    # compatíveis) ele também manda \033[3J, que apaga o HISTÓRICO de
    # rolagem do terminal - depois disso não dá mais pra rolar pra cima
    # pra ver telas anteriores. Aqui a rolagem continua funcionando normal.
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

ui_success() { echo "${C_GREEN}[OK]${C_RESET} $1"; }
ui_warning() { echo "${C_YELLOW}[ATENÇÃO]${C_RESET} $1"; }
ui_error()   { echo "${C_RED}[ERRO]${C_RESET} $1" >&2; }
ui_step()    { echo "${C_GREY}→${C_RESET} $1"; }
ui_muted()   { echo "${C_GREY}$1${C_RESET}"; }

# ui_menu "Pergunta" "1" "Opção um" "2" "Opção dois" "0" "Voltar"
# Uso: escolha="$(ui_menu "..." "1" "Opção um" "2" "Opção dois" "0" "Voltar")"
#
# IMPORTANTE: como o valor escolhido é devolvido via stdout (para permitir
# `escolha=$(ui_menu ...)`), TODO o texto do menu em si (título, opções,
# aviso de opção inválida) é escrito em stderr - senão esse texto seria
# capturado junto com o valor de retorno em vez de aparecer na tela.
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
        # IMPORTANTE: checar o código de saída do `read` explicitamente
        # (em vez de confiar em `set -e`) é proposital. Dentro de um
        # "$(...)" que envolve um loop, `set -e` NÃO interrompe um `read`
        # que falha por fim de entrada (EOF) - é uma peculiaridade real do
        # bash, confirmada testando. Sem este `if`, entrada esgotada
        # inesperadamente (ex: sessão SSH caindo no meio de um menu) faria
        # este loop girar para sempre em vez de encerrar.
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

# ui_prompt "Rótulo" -> imprime em stdout (capturar com var=$(ui_prompt ...)).
# Entrada visível (não usar para senhas - ver ui_password).
ui_prompt() {
    local label="$1"
    local value
    if ! read -r -p "${label}: " value; then
        ui_error "Não foi possível ler a entrada (stdin fechado ou indisponível)." >&2
        return 1
    fi
    printf '%s' "$value"
}

# ui_password "Prompt: " -> imprime em stdout (capturar com var=$(ui_password ...))
#
# Checa o código de saída do `read` explicitamente (mesmo motivo do
# ui_menu) - sem isso, uma falha de leitura da senha mataria o processo
# inteiro em silêncio, sem explicar o porquê.
ui_password() {
    local prompt="$1"
    local value
    if ! read -r -s -p "${prompt}" value; then
        echo >&2
        ui_error "Não foi possível ler a senha (stdin fechado ou indisponível)." >&2
        return 1
    fi
    echo >&2
    printf '%s' "$value"
}

# ui_progress_bar <percentual 0-100> -> desenha uma barra tipo ████░░░░.
# Compartilhada entre o monitor de restauração e as barras de
# limpeza/extração do repository - nunca inventa o percentual, quem chama
# é responsável por calcular a partir de dados reais (contagem de itens,
# bytes, etc.).
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

# Desenha uma tabela simples de largura fixa por coluna.
# ui_table_row "col1" "col2" "col3" larguras=(10 30 10) -> usar diretamente com printf nos scripts.
ui_hr() {
    ui_muted "------------------------------------------------------------"
}
