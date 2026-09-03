#!/usr/bin/env bash
#
# Localizar, analisar e extrair arquivos de backup .ixc.
#
# A senha do backup nunca é passada como argumento de linha de comando pro
# openssl (isso apareceria em `ps aux`). Usamos "openssl ... -pass stdin"
# e entregamos a senha via herestring (<<<), que o bash implementa sem
# jamais colocá-la em argv.

# Preenche os arrays globais BACKUP_FOUND_FILES / BACKUP_FOUND_SIZES a
# partir de $BACKUP_DIRS (lista separada por espaço), do mais recente pro
# mais antigo - pela data/hora embutida no nome do arquivo, não pelo mtime
# (que pode não refletir a ordem real se os backups foram copiados fora de
# ordem). Backups sem essa data no nome ficam por último. Todo consumidor
# (tabela, menu numerado de seleção) usa esta mesma ordem, então o "#1" é
# sempre o mais recente.
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

# backup_contains_elastic <nome_do_arquivo>
# Convenção de nomes do backup IXC (confirmada pela equipe): "BKP_<CÓDIGO>_"
# antes da data. B = banco de dados, C = configurações, CS = completo (todo
# o sistema), E = só Elasticsearch. Só "CS" e "E" têm dados do Elasticsearch
# dentro - é só o que interessa pra restauração feita por esta ferramenta.
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

# backup_list_elastic
# Preenche o array global BACKUP_ELASTIC_FILES com os backups já
# encontrados (por backup_find) que contêm dados do Elasticsearch (ver
# backup_contains_elastic) - a ordem já vem do mais recente pro mais antigo
# porque backup_find já entrega os arquivos nessa ordem, então aqui é só
# filtrar. Retorna 1 se não achar nenhum.
backup_list_elastic() {
    BACKUP_ELASTIC_FILES=()
    local f
    for f in "${BACKUP_FOUND_FILES[@]}"; do
        backup_contains_elastic "$(basename "$f")" && BACKUP_ELASTIC_FILES+=("$f")
    done
    [[ ${#BACKUP_ELASTIC_FILES[@]} -eq 0 ]] && return 1
    return 0
}

# backup_find_newest_elastic
# Ecoa o caminho do backup .ixc mais recente entre os que contêm dados do
# Elasticsearch. Retorna 1 (sem nada em stdout) se não achar nenhum.
backup_find_newest_elastic() {
    backup_list_elastic || return 1
    printf '%s' "${BACKUP_ELASTIC_FILES[0]}"
}

# backup_print_elastic_table [nome_pra_destacar]
# Como backup_print_table, mas lista só os backups com dados do
# Elasticsearch (backup_list_elastic), do mais recente pro mais antigo -
# útil quando a decisão em jogo é especificamente sobre qual backup do
# Elasticsearch usar (ex: retomada de uma extração anterior, onde mostrar
# banco de dados/configurações só atrapalharia). Marca a linha igual a
# [nome_pra_destacar], se informado.
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

        # Colunas de largura fixa (#, ARQUIVO, TAMANHO) sempre alinhadas -
        # as marcas vão só no final da linha, nunca dentro de uma coluna.
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

# Imprime a tabela de backups encontrados (chama backup_find antes, que já
# entrega do mais recente pro mais antigo). Destaca em verde os que contêm
# dados do Elasticsearch (ver backup_contains_elastic) - só esses servem
# pra restauração feita aqui - e marca "MAIS RECENTE" no primeiro DESSES,
# não no primeiro da lista inteira: um BKP_B ou BKP_C mais novo que todos
# os backups do Elasticsearch não é "o mais recente" pra quem tá aqui pra
# restaurar Elasticsearch.
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

        # Todas as colunas de largura fixa (#, ARQUIVO, TAMANHO, ELASTIC)
        # ficam sempre alinhadas entre as linhas - a marca "MAIS RECENTE"
        # vai só no final, depois de tudo, nunca dentro de uma coluna (senão
        # empurra as colunas seguintes só naquela linha e desalinha a tabela
        # inteira). ELASTIC usa ui_pad, não "%-18s", porque "✓"/"—" tem mais
        # bytes do que colunas na tela - ver comentário em ui_pad (lib/ui.sh).
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

    # `--wildcards` + padrão "*elastic_backup.tar.gz" (em vez de caminhos
    # fixos tipo "./bkp/elastic_backup.tar.gz"): o caminho interno do
    # componente varia conforme o tipo de backup - num backup completo
    # (BKP_CS) fica dentro de "bkp/", mas um backup só do Elasticsearch
    # (BKP_E) pode guardar o mesmo arquivo direto na raiz do tar, ou em
    # outra pasta. O nome do arquivo em si ("elastic_backup.tar.gz") é o
    # que se mantém - casar só por ele, ignorando o caminho, cobre os dois
    # casos sem precisar de uma segunda passada pra descobrir o layout.
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
