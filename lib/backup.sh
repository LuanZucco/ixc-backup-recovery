#!/usr/bin/env bash
#
# Localizar, analisar e extrair arquivos de backup .ixc.
#
# A senha do backup nunca é passada como argumento de linha de comando pro
# openssl (isso apareceria em `ps aux`). Usamos "openssl ... -pass stdin"
# e entregamos a senha via herestring (<<<), que o bash implementa sem
# jamais colocá-la em argv.

# Preenche os arrays globais BACKUP_FOUND_FILES / BACKUP_FOUND_SIZES a
# partir de $BACKUP_DIRS (lista separada por espaço).
backup_find() {
    BACKUP_FOUND_FILES=()
    BACKUP_FOUND_SIZES=()

    local dir f size
    for dir in $BACKUP_DIRS; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*.ixc; do
            [[ -f "$f" ]] || continue
            size=$(stat -c%s "$f" 2>/dev/null || echo 0)
            BACKUP_FOUND_FILES+=("$f")
            BACKUP_FOUND_SIZES+=("$size")
        done
    done
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

# Imprime a tabela de backups encontrados (chama backup_find antes).
backup_print_table() {
    if [[ ${#BACKUP_FOUND_FILES[@]} -eq 0 ]]; then
        ui_warning "Nenhum backup .ixc encontrado nos diretórios configurados."
        ui_muted "Diretórios pesquisados: ${BACKUP_DIRS}"
        return 1
    fi

    printf "${C_CYAN}%-3s %-45s %10s${C_RESET}\n" "#" "ARQUIVO" "TAMANHO"
    ui_muted "------------------------------------------------------------------"
    local i
    for i in "${!BACKUP_FOUND_FILES[@]}"; do
        local name
        name="$(basename "${BACKUP_FOUND_FILES[$i]}")"
        printf "%-3s %-45s %10s\n" \
            "$((i + 1))" \
            "$name" \
            "$(backup_size_human "${BACKUP_FOUND_SIZES[$i]}")"
    done
    return 0
}

# Valida um caminho informado manualmente: existe, é arquivo, não vazio, legível.
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

# Senha do backup .ixc. Regra confirmada pela equipe: "ixcsoft" seguido da
# data/hora embutida no nome do arquivo, sem separadores. Exemplo:
# BKP_E_2025_08_21-02.33.32.ixc -> ixcsoft20250821023332
#
# Ecoa a senha derivada em stdout, ou nada (e retorno 1) se o nome do
# arquivo não seguir o padrão esperado - nesse caso o chamador cai para
# pedir a senha manualmente, em vez de travar tentando usar algo errado.
backup_derive_password_from_filename() {
    local filename="$1"
    local datetime
    datetime="$(grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}' <<<"$filename")"
    [[ -z "$datetime" ]] && return 1
    printf 'ixcsoft%s' "${datetime//[_.-]/}"
}

# Preenche BACKUP_PASSWORD_VALUE direto (variável global) em vez de devolver
# via stdout - propositalmente para NÃO ser chamada dentro de "$(...)" pelo
# wizard. Duas camadas de "$(...)" empilhadas (aqui dentro + no chamador)
# já causaram uma leitura de senha falhar sem explicação em produção;
# eliminar essa camada extra reduz o risco de repetir o problema.
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
    # Entrada VISÍVEL de propósito (sem -s) - a pedido explícito do
    # operador, para poder conferir visualmente o que está sendo digitado.
    # Ainda assim nunca é salva em log (log_register_secret redige
    # qualquer ocorrência do valor nas linhas gravadas em disco).
    local value
    if ! read -r -p 'Senha do backup .ixc (visível): ' value; then
        ui_error "Não foi possível ler a senha do backup (stdin fechado ou indisponível)."
        ui_muted "Alternativa: rode com IXC_BACKUP_PASSWORD='sua_senha' na frente do comando."
        return 1
    fi
    if [[ -z "$value" ]]; then
        ui_error "Nenhuma senha foi informada (campo veio vazio)."
        ui_muted "Alternativa: rode com IXC_BACKUP_PASSWORD='sua_senha' na frente do comando."
        return 1
    fi

    log_register_secret "$value"
    BACKUP_PASSWORD_VALUE="$value"
    return 0
}

# backup_extract_elastic_component <arquivo.ixc> <senha> <work_dir> <arquivo_de_progresso>
#
# UMA ÚNICA passada pelo stream descriptografado: descobre e já extrai o
# componente do Elasticsearch, sem uma etapa separada de "listar o
# conteúdo" antes. Ter duas etapas (analisar + extrair) significava ler o
# backup inteiro DUAS vezes até chegar no componente do ES sempre que ele
# não está bem no início do arquivo - em um backup de 40GB isso dobra o
# tempo (e parece, incorretamente, que a ferramenta está "descompactando
# o backup inteiro"). Também é exatamente por isso que não dá pra saber o
# progresso apenas olhando o arquivo de destino: ele só começa a crescer
# quando o `tar` finalmente alcança o componente do ES lá dentro do
# stream, o que pode estar em qualquer ponto do arquivo. Por isso o `dd`
# no meio do pipe: ele reporta throughput real (bytes já processados do
# .ixc) em <arquivo_de_progresso>, independente de onde o componente do
# ES está.
#
# Ecoa o caminho extraído em stdout se der certo. Em caso de falha, grava
# "senha" (indício de senha incorreta) ou "nao_encontrado" (indício de
# backup sem o componente, ou senha errada não detectada pelo padrão de
# erro) em <work_dir>/.error_kind, para o chamador ler depois (isto roda
# em segundo plano no wizard - variáveis globais setadas aqui não
# sobrevivem de volta pro processo pai, só o que for gravado em disco).
#
# Parar de ler antes do fim do arquivo (assim que o membro é encontrado)
# faz o openssl - do lado de escrita do pipe - receber SIGPIPE. Isso é
# esperado e não é tratado como falha, desde que o arquivo de destino
# tenha sido escrito com conteúdo.
backup_extract_elastic_component() {
    local backup_path="$1" password="$2" work_dir="$3" progress_file="$4"
    mkdir -p "$work_dir"
    local dest="${work_dir}/elastic_backup.tar.gz"
    local err_file="${work_dir}/.stderr"
    rm -f "$dest" "$err_file" "${work_dir}/.error_kind"
    : > "$progress_file"

    openssl aes-256-cbc -d -salt -in "$backup_path" -pass stdin <<<"$password" 2>>"$err_file" \
        | dd bs=4M status=progress 2>"$progress_file" \
        | tar -xzf - -O -- "./bkp/elastic_backup.tar.gz" "bkp/elastic_backup.tar.gz" \
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

# backup_extract_into_repo <elastic_backup.tar.gz> <diretorio_repository> [arquivo_de_status]
#
# Esta etapa grava os dados reais do Elasticsearch em disco - é normal ser
# a mais demorada depois da própria extração do .ixc (mesmo volume de
# dados, sem a criptografia). Se <arquivo_de_status> for informado, cada
# arquivo extraído é registrado nele (via `tar -v`), para um chamador em
# segundo plano conseguir mostrar o que está acontecendo.
backup_extract_into_repo() {
    local tar_gz="$1" repo_path="$2" status_file="${3:-}"

    local listing
    listing="$(mktemp)"
    tar -tzf "$tar_gz" > "$listing" 2>/dev/null

    if grep -qE '(^|/)\.\.(/|$)' "$listing"; then
        ui_error "O arquivo extraído contém caminhos suspeitos (../) - abortando por segurança."
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
