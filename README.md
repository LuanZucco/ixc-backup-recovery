# IXC Backup Recovery Tool

Ferramenta de linha de comando para automatizar a restauração manual de
backups do Elasticsearch do IXC Provedor em Debian/Linux - bash puro,
modular (nada de script gigante), sem dependências além de utilitários
padrão do sistema.

## O que faz

- Menu principal ("ELASTIC - Diagnósticos e Restauração"), com cabeçalho
  fixo (servidor/SO/status do Elasticsearch).
- **Senha do Elasticsearch pedida uma única vez, logo na abertura**: localiza
  `ELASTICS_HASHPASS`, mostra o valor cifrado e coleta a senha já
  descriptografada (entrada visível) antes mesmo de mostrar o menu
  principal - fica em memória para o resto desta execução, então nenhuma
  tela mais adiante (diagnóstico ou restauração) pergunta de novo. Não
  informar nesse momento não trava nada: quem realmente precisar dela pede
  na hora. Dura só a execução atual do `.sh` - fechou e abriu de novo, pede
  outra vez.
- Fluxo completo de restauração do Elasticsearch, sempre com um checklist
  de progresso (3x3, ✓ concluída / » atual / pendente) redesenhado no topo
  a cada etapa - a tela é limpa antes de cada etapa nova em vez de ir só
  empilhando título atrás de título pra baixo (ver `wizard_render_progress`
  em `lib/wizard.sh`):
  - localizar backup `.ixc` (busca automática ou caminho manual) - toda
    tabela de backups vem ordenada do mais recente pro mais antigo (pela
    data/hora embutida no nome do arquivo, não pelo mtime), destacando em
    verde (`✓ contém Elastic`) os que realmente têm dados do Elasticsearch
    dentro, e a **linha inteira** do mais recente DESSES vem em verde,
    marcada "MAIS RECENTE" - um `BKP_B`/`BKP_C` mais novo que todos os
    backups do Elasticsearch não conta, não é "o mais recente" pra quem tá
    restaurando Elasticsearch. O mesmo destaque (linha/opção inteira em
    verde) aparece em todo lugar que lista backups ou snapshots: na tabela
    e no menu numerado de escolher o backup, na tela de retomada, na
    tabela e no menu de escolher o snapshot, e no diagnóstico de
    snapshots. Os que **não** têm dados do Elasticsearch (`BKP_B_`,
    `BKP_C_`, e qualquer outro código) vêm em **vermelho**, tanto na
    tabela quanto no menu numerado de escolher o backup - pra não
    confundir na hora de selecionar. Convenção de nome do backup IXC: `BKP_E_...` = só
    Elasticsearch, `BKP_CS_...` = completo/todo o sistema; `BKP_B_...`
    banco de dados e `BKP_C_...` configurações não têm - ver
    `backup_contains_elastic` em `lib/backup.sh`);
  - obter a senha do backup - deriva automaticamente a partir do nome do
    arquivo (`ixcsoft` + data/hora embutida) quando o padrão é reconhecido,
    senão pede ao operador (entrada visível);
  - descriptografar e extrair **só** o componente do Elasticsearch, numa
    única passada pelo stream, com progresso real (throughput via `dd`);
  - preparar o repository (com confirmação apenas se já houver conteúdo
    antigo, e barra de progresso real na limpeza);
  - extrair os dados pro repository e corrigir permissões, com barra de
    progresso real (contagem de arquivos);
  - validar o Elasticsearch, com correção simplificada de single-node
    quando seguro (bloqueada automaticamente se houver indício de
    ambiente multi-node);
  - registrar o repository, listar e selecionar snapshot - a tela deixa
    explícito de qual backup `.ixc` aquele repository (e os snapshots
    dentro dele) veio, tanto aqui quanto no resumo final; a informação
    sobrevive a fechar e abrir a ferramenta de novo (marcador em
    `${ES_REPOSITORY_PATH}/.ixc-backup-source`, ver
    `wizard_backup_source_name` em `lib/wizard.sh`);
  - **escolher quais índices restaurar** - por padrão todos os do
    snapshot, mas dá pra restringir a um índice específico ou a alguns (ex:
    recuperar só um índice corrompido, sem tocar no resto); a pergunta só
    aparece quando o snapshot tem mais de um índice - ver
    `_wizard_select_indices_to_restore` em `lib/wizard.sh`. Toda etapa
    seguinte (checagem de índices já existentes, o corpo da chamada de
    restauração pro Elasticsearch, o monitoramento em tempo real e o
    resumo final) passa a considerar só os índices escolhidos aqui, nunca
    o snapshot inteiro;
  - substituir índices existentes (com confirmação) - a checagem é só
    sobre os índices escolhidos no passo acima, não sobre todo o
    snapshot;
  - restaurar e **monitorar em tempo real** com dados reais do
    `_cat/recovery` - inclusive recuperando sozinho de falhas temporárias
    de rede/autenticação durante o monitoramento, sem derrubar a
    ferramenta.
  - **retomada inteligente**: se qualquer etapa *depois* da extração falhar
    (senha do Elasticsearch errada, cluster indisponível), tentar de novo
    não repete a extração do backup - a ferramenta detecta o que já foi
    preparado (em disco, sobrevive até a um reinício da ferramenta) e
    pula direto pra frente. Antes de pular, mostra de qual backup os dados
    já prontos vieram (quando esse dado existe) e lista **todos** os
    backups `.ixc` com dados do Elasticsearch disponíveis (`E` e `CS`, do
    mais recente pro mais antigo - ver `backup_print_elastic_table` em
    `lib/backup.sh`), não só o mais recente - a decisão de qual usar é do
    operador. As opções nessa tela são continuar com o que já está pronto,
    selecionar um backup (o mesmo ou outro) e extrair do zero, ou
    cancelar.
- Diagnóstico (somente leitura), 4 telas: status geral (serviço + cluster
  health), índices atuais, snapshots, e repository (junta o que está
  registrado via API, o diretório em disco e a configuração do
  Elasticsearch numa única tela).
- Listagem de backups `.ixc` encontrados.
- Log por execução em `/var/log/ixc-backup-recovery/` (`cat`/`tail` direto
  no servidor pra consultar - sem tela própria no menu), com redação
  automática de qualquer segredo registrado durante a execução.

## Segurança

- A senha do backup `.ixc` nunca vira argumento de linha de comando do
  `openssl` (apareceria em `ps aux`) - é entregue via herestring (`-pass
  stdin <<<"$senha"`).
- A senha do Elasticsearch nunca vira argumento do `curl` - é entregue via
  `curl -K -` (arquivo de configuração pelo stdin).
- Ambas as senhas são mostradas na tela ao digitar (a pedido do time, para
  conferência visual), mas nunca gravadas em log - qualquer valor
  registrado como segredo é redigido (substituído por `***`) antes de
  qualquer linha ir pro arquivo.
- Limpeza do repository (`security_safe_clean_directory`) valida o
  caminho contra uma lista de diretórios proibidos e um prefixo permitido
  antes de apagar qualquer coisa - nunca um `rm -rf` montado direto de
  variável.
- Extração de tar verifica ausência de `../` nos nomes dos membros antes de
  extrair.
- Remoção de índices é sempre restrita à lista explícita de índices do
  snapshot selecionado - nunca um curinga.
- Ajuste automático de single-node só é oferecido quando não há indícios
  de ambiente multi-node (`discovery.seed_hosts`,
  `cluster.initial_master_nodes` com múltiplos nós).
- A senha do backup pode ser derivada automaticamente do nome do arquivo
  quando ele segue o padrão conhecido - regra confirmada pela equipe, não
  inventada (ver `backup_derive_password_from_filename` em `lib/backup.sh`).

## Como rodar

```bash
cd ~/Área\ de\ Trabalho/IXC\ Backup\ Recovery/elastic
ALLOW_NON_ROOT=1 ./ixc-recovery.sh   # teste local, sem precisar ser root
sudo ./ixc-recovery.sh                # uso normal (root)
```

## Enviar para um servidor

```bash
./scripts/deploy.sh usuario@servidor          # porta 22
./scripts/deploy.sh usuario@servidor 2222     # porta customizada
```

Sem SSH disponível (só console/copiar-colar)? Gere um arquivo único:

```bash
./scripts/build_standalone.sh
```

Copie `dist/ixc-recovery-standalone.sh` inteiro para um arquivo no
servidor e rode com `bash ixc-recovery-standalone.sh` - sem dependências
externas além de `bash`, `openssl`, `tar`, `curl`, `jq` e `systemctl`
(todos padrão em qualquer Debian/Ubuntu, exceto o `jq`, que a própria
ferramenta oferece instalar).

## Estrutura

```
ixc-recovery.sh       menu principal, checagem de root/dependências
lib/
  ui.sh                cores, painéis, tabelas, barra de progresso, menus
  config.sh              valores padrão (sobrescrevíveis por
                          /etc/ixc-backup-recovery/config.sh)
  logger.sh                log por execução + redação de segredos
  security.sh                limpeza segura de diretório
  backup.sh                    localizar, senha, extrair o .ixc
  elasticsearch.sh                cliente curl autenticado, health, restore
  repository.sh                     checagem do diretório do repository
  credentials.sh                      localizar ELASTICS_HASHPASS
  singlenode.sh                         detecção e fix de single-node
  monitor.sh                              painel de progresso em tempo real
  wizard.sh                                 orquestra o fluxo completo
  diagnostics.sh                              menu de diagnóstico
scripts/
  deploy.sh              envia por scp/ssh e instala no servidor
  build_standalone.sh      gera dist/ixc-recovery-standalone.sh (arquivo único)
```

## Testado

Todo o fluxo foi validado de ponta a ponta com backups `.ixc` sintéticos
reais (criptografados de verdade com `openssl`, inclusive com dados de
outros componentes posicionados antes do componente do Elasticsearch, para
validar que só o necessário é extraído) e um Elasticsearch simulado: senha
correta e incorreta, senha vazia, backup sem componente do Elasticsearch,
repository com conteúdo antigo (limpeza), índices existentes colidindo com
o snapshot (substituição), falha de autenticação/rede durante o
monitoramento, retomada após falha em qualquer etapa pós-extração, e o
ciclo completo restore → monitoramento → validação final. Nenhuma senha
aparece no log gerado.

## Peculiaridades do bash que valeram a pena registrar

Encontradas ao vivo, em produção, e corrigidas na raiz (não contornadas):

1. `systemctl is-active` e `curl` retornam código de saída diferente de
   zero em situações esperadas (serviço parado, sem conexão) mesmo
   produzindo saída válida. Sob `set -e`, deixar isso "vazar" mataria a
   ferramenta inteira só por o Elasticsearch estar offline - por isso
   várias chamadas usam `|| true` de propósito, com o motivo documentado
   no comentário ao lado.
2. Dentro de `"$(...)"`, um laço `while` com `read` que atinge fim de
   entrada **não é interrompido por `set -e`**. Isso faria um menu girar
   para sempre em vez de encerrar se a entrada acabasse inesperadamente.
   Corrigido checando o código de saída do `read` explicitamente em
   `ui_menu` (`lib/ui.sh`), em vez de depender do `set -e`.
3. Uma resposta JSON de erro da API do Elasticsearch (ex: 401 de
   autenticação) tem seu próprio campo `"status"` (o código HTTP) que
   pode ser confundido com o campo `"status"` do cluster health
   (green/yellow/red) se não for checado antes - resultava em telas tipo
   "Status: 401" sem explicação. Corrigido com `es_response_error_message`
   (`lib/elasticsearch.sh`), checado antes de qualquer parsing de campo.
4. Todo `jq` que processa uma resposta potencialmente vazia/malformada da
   API (rede instável, timeout) precisa de `|| true` no ponto de
   atribuição - sem isso, uma falha pontual de rede durante o
   monitoramento em tempo real derrubava a ferramenta inteira em silêncio.
5. Chamar uma função em segundo plano (`&`) para mostrar progresso ao vivo
   funciona bem para o *resultado* (arquivo em disco, código de saída via
   `wait`), mas variáveis globais setadas dentro dela **não sobrevivem** de
   volta pro processo pai - só o que for gravado em arquivo. Por isso as
   funções que rodam em segundo plano (extração, limpeza) comunicam
   estado via arquivo de status, nunca via variável.
