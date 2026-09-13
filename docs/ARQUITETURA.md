# Arquitetura do projeto `apolo` — documento de referência

> Este documento existe pra duas coisas: (1) ser o material de estudo sobre como o projeto funciona de ponta a ponta, e (2) servir de especificação completa pra desenhar o diagrama no Excalidraw numa sessão futura — a seção final ("Especificação do diagrama") descreve exatamente que caixas, agrupamentos e setas desenhar.

## Visão geral em uma frase

Dados fictícios de um ERP (clientes, produtos, pedidos) nascem num container de "fonte" no Azure, são copiados por um pipeline do ADF pra uma zona de pouso, empurrados por uma Azure Function pra dentro do Databricks (porque o tier gratuito do Databricks não pode simplesmente "ler" o Azure), e ali viram tabelas Delta que o dbt transforma em camadas bronze → prata → ouro, disparado por dois Jobs do Databricks agendados com frequências diferentes.

## Os 3 repositórios — "quem é dono de quê"

| Repositório | Responsabilidade | Analogia |
|---|---|---|
| **`apolo-infra`** | Tudo que é infraestrutura Azure (Bicep) + a "cola" que conecta Azure ao Databricks (a Function) + as definições dos Jobs do Databricks | O time de plataforma/infra |
| **`apolo-adf`** | Só os pipelines do ADF — mas o conteúdo não é escrito à mão aqui, é sincronizado automaticamente pela Git integration nativa do ADF Studio | O "espelho" do que existe dentro do Data Factory |
| **`apolo-dbt`** | O projeto dbt: models, macros, testes, e as definições de qual model roda em qual cadência (tags de tier) | O time de analytics engineering |

Por que 3 repos e não 1: cada um tem ciclo de vida e "dono" diferente — infraestrutura muda raramente, pipelines do ADF mudam quando a fonte de dados muda, e o dbt muda toda vez que a regra de negócio muda. Misturar tudo num repo só dificultaria saber "quem mexeu em quê" e daria permissão de acesso excessiva pra quem só devia mexer numa parte.

## Os componentes, um por um

### Do lado Azure (todos em `apolo-infra`, definidos em Bicep)

- **Resource Group (`apolo-rg`)**: a "pasta" que agrupa todos os recursos Azure do projeto.
- **Storage Account / ADLS Gen2 (`dbtazuredevcshdut3x2ydxc`)**: é um Blob Storage comum com um flag ligado (hierarchical namespace) que dá pastas de verdade e melhor desempenho pra ferramentas de dados. Tem dois containers:
  - **`source`**: simula o "sistema de origem" — hoje só arquivos fictícios (CSV e Parquet) subidos manualmente, no lugar de um banco de dados real (decisão que ficou em aberto: Postgres/SQL Server/API).
  - **`landing`**: pra onde o ADF copia os arquivos do `source`. É o "pouso" real antes da ponte pro Databricks.
- **Key Vault (`kv-dbtazure-dev-cshdut3x`)**: guarda os segredos que cruzam a fronteira Azure↔Databricks — token/host do Databricks, e a chave da Azure Function. Ninguém tem segredo hardcoded em lugar nenhum; tudo é lido daqui em runtime, via Managed Identity.
- **Azure Data Factory (`adf-dbtazure-dev-cshdut3x`)**: o orquestrador de ingestão. Tem uma Managed Identity própria, com permissão de leitura/escrita no Storage e leitura de segredos no Key Vault. Roda um pipeline (`pl_copy_source_to_landing`) com um `ForEach` que, pra cada um dos 6 arquivos fictícios, faz duas coisas em sequência:
  1. **Copy data1**: copia o arquivo de `source/` pra `landing/`.
  2. **Bridge to Databricks**: chama a Azure Function, passando qual arquivo processar.
- **Azure Function (`func-dbtazure-dev-cshdut3x`, código em `apolo-infra/functions/bridge_to_databricks/`)**: a peça que resolve o problema central do projeto (ver seção "A decisão mais importante" abaixo). Recebe do ADF o nome do arquivo, lê o blob do `landing` (com a própria Managed Identity), pega o token do Databricks no Key Vault, e faz um `PUT` HTTP puro empurrando o conteúdo do arquivo pra dentro de um Volume do Databricks. Roda em plano **Flex Consumption** (serverless, praticamente grátis).
- **Databricks Jobs, definidos como código (`apolo-infra/databricks/jobs/*.json`)**: não são um "recurso Azure" (o Databricks Free Edition não é provisionável via Bicep), mas as definições dos Jobs ficam versionadas aqui, aplicadas ao workspace via script Python (`apply_jobs.py`) chamando a API REST do Databricks.

### Do lado Databricks (Free Edition, fora da conta de billing Azure)

- **Unity Catalog**: já vem com 3 catalogs de nível superior — `bronze`, `prata`, `ouro` (essa é a "arquitetura medallion" clássica, só que aqui cada camada é um catalog inteiro, não um schema).
- **Volume gerenciado (`bronze.landing.raw_files`)**: uma pasta dentro do Unity Catalog pra onde a Azure Function empurra os arquivos brutos. É o ponto de entrada dos dados dentro do mundo Databricks.
- **SQL Warehouse (serverless)**: o compute que executa toda consulta SQL — tanto as chamadas de teste diretas quanto os `dbt build` dos Jobs.
- **Tabelas Delta `bronze.erp_ficticio.*`**: criadas a partir dos arquivos do Volume, via uma macro do dbt (`dbt run-operation materialize_bronze_*`) que faz `read_files()` + `CREATE OR REPLACE TABLE`. Esse é o "último passo de ingestão" antes do dbt assumir de vez.
- **Camadas `prata`/`ouro`**: construídas pelo `dbt build` — a transformação de negócio de verdade (limpeza, chaves substitutas, quarentena de registros inválidos, dimensões e fatos).
- **`transform_job_geral`** (cron a cada 3h): materializa e transforma tudo que é tag `tier_padrao` (clientes/produtos — muda devagar).
- **`transform_job_frequente`** (cron a cada 30min): materializa e transforma tudo que é tag `tier_frequente` (pedidos — muda rápido). Os dois Jobs são completamente independentes; um não bloqueia o outro se falhar.

### Do lado dbt (`apolo-dbt`)

- **`models/01_staging`**: normalização 1:1 com a fonte (`source()`), lendo das tabelas `bronze.erp_ficticio.*`.
- **`models/02_prata`**: limpeza de negócio — chaves substitutas (`xxhash64`), tratamento de CPF/CNPJ, e o padrão de "quarentena" (registros com chave estrangeira nula são sinalizados, nunca descartados).
- **`models/03_ouro`**: dimensões (`dim_cliente`, `dim_produto`, com uma versão PII separada) e fato (`fct_pedido_venda`, incremental, mais uma tabela de quarentena separada).
- **`macros/ingestion/materialize_bronze.sql`**: as macros que fazem a ponte final Volume→Delta, chamadas pelos Jobs antes do `dbt build`.
- **Tags de tier** (`tier_padrao`/`tier_frequente`) em cada model: é o que permite os dois Jobs selecionarem só a fatia do projeto que lhes cabe (`dbt build --select tag:X`).
- **`scripts/validate_tiers.py`**: rodado no CI, garante que todo model tem exatamente uma tag de tier (nunca zero, nunca duas) — evita ambiguidade sobre qual Job é dono de qual tabela.

## A decisão mais importante do projeto: por que existe uma Azure Function no meio do caminho

Numa empresa com Azure Databricks pago, o Databricks teria acesso direto e irrestrito à storage account (via Unity Catalog External Location) — o ADF deixaria o arquivo no ADLS e o Databricks já enxergaria, sem ponte nenhuma. O **Databricks Free Edition** (gratuito, usado neste projeto) não permite isso: o compute dele tem rede de saída restrita e não pode registrar uma storage account externa. Testamos isso experimentalmente (documentado em `spikes/README.md`) e confirmamos que só um caminho funciona: alguém de **fora** do Databricks precisa empurrar o dado pra dentro, ativamente — daí a Azure Function.

## Fluxo de dados, passo a passo

1. Arquivos fictícios existem em `source/csv/` e `source/parquet/` (3 tabelas × 2 formatos = 6 arquivos).
2. ADF roda `pl_copy_source_to_landing`. Pra cada um dos 6 arquivos: copia `source/` → `landing/`, depois chama a Azure Function.
3. A Function lê o arquivo do `landing` e faz `PUT` na Files API do Databricks, gravando em `/Volumes/bronze/landing/raw_files/<arquivo>`.
4. Duas vezes por dia (em cadências diferentes): um Databricks Job acorda, roda `dbt run-operation materialize_bronze_*` (lê o Volume, cria/substitui as tabelas Delta em `bronze.erp_ficticio.*`), e depois `dbt build --select tag:*` (constrói prata e ouro a partir do bronze).
5. Resultado final: tabelas `ouro.vendas_ficticio.dim_cliente`, `dim_produto`, `fct_pedido_venda` etc., prontas pra consumo.

## Achados técnicos reais ao longo do caminho (bons pra explicar em entrevista)

- Databricks Free Edition suspende o SQL Warehouse por inatividade — precisa reativar manualmente pela UI antes da API voltar a responder.
- ADF não tem um jeito nativo de fazer PUT binário pra um endpoint HTTP arbitrário (Web Activity só aceita texto pequeno; Copy Activity com destino HTTP não existe) — daí a necessidade da Function.
- Function App em plano Consumption clássico (Y1) bate numa cota zero em contas Free Trial novas — resolvido trocando pro plano Flex Consumption (SKU mais nova, cota separada).
- O botão "Publish" do ADF Studio tem um bug conhecido (`__LAST_PUBLISHED_COMMIT_ID___`) e, mesmo quando "funciona", pode aplicar mudanças na factory sem gerar commit no Git — sempre vale conferir a sincronização.
- O `dbt_task` dos Databricks Jobs **ignora** o `profiles.yml` do repositório e gera seu próprio profile temporário, com catalog default `hive_metastore` (desabilitado nesta conta) — resolvido passando `catalog`/`schema` explicitamente na definição da task.

---

## Especificação do diagrama (pra desenhar no Excalidraw)

### Agrupamentos (retângulos grandes, um por "swim lane")

1. **"Fonte / ADLS Gen2 (Azure)"** — contém os containers `source` e `landing`.
2. **"Azure Data Factory"** — contém o pipeline `pl_copy_source_to_landing` com o `ForEach` (mostrar como um retângulo dentro do retângulo do ADF, contendo as duas activities em sequência: `Copy data1` → `Bridge to Databricks`).
3. **"Azure Function (Flex Consumption)"** — uma caixa só, rotulada `bridge_to_databricks`.
4. **"Key Vault"** — uma caixa pequena, com setas tracejadas (de leitura de segredo) saindo em direção ao ADF e à Function.
5. **"Databricks Free Edition — Unity Catalog"** — o maior agrupamento, contendo:
   - Caixa **"Volume: bronze.landing.raw_files"**
   - Caixa **"catalog bronze"** (schema `erp_ficticio`, 3 tabelas)
   - Caixa **"catalog prata"** (schema `erp_ficticio`, 3 tabelas)
   - Caixa **"catalog ouro"** (schema `vendas_ficticio`, 5 tabelas: dims + fatos)
   - Duas caixas de **Job**: `transform_job_geral` (cron 3h) e `transform_job_frequente` (cron 30min), cada uma com uma seta apontando pro bronze (materializa) e depois pra prata/ouro (dbt build).

### Setas principais (nessa ordem, numeradas 1-6 no diagrama)

1. `source` → `landing` (rotulada "Copy data1 (ADF)")
2. `landing` → Azure Function (rotulada "aciona, passa nome do arquivo")
3. Azure Function → Volume bronze.landing.raw_files (rotulada "PUT Files API")
4. Volume → catalog bronze (rotulada "dbt run-operation materialize_bronze_* (read_files)")
5. catalog bronze → catalog prata → catalog ouro (rotulada "dbt build --select tag:X")
6. Setas tracejadas de Key Vault pro ADF e pra Function (rotuladas "lê segredo via Managed Identity")

### Legenda / rodapé do diagrama

Uma caixa de texto simples relacionando cor/agrupamento a repositório:
- Tudo em Azure (grupos 1-4) → repo `apolo-infra` (Bicep + Function) e `apolo-adf` (conteúdo do pipeline)
- Tudo em Databricks (grupo 5) → definições de Job em `apolo-infra/databricks/jobs/`, lógica de transformação em `apolo-dbt`

### Estilo sugerido

Cores por swim lane (ex: azul pro Azure, laranja pro Databricks), ícones simples (retângulo com cantos arredondados pra serviços gerenciados, cilindro pra armazenamento/tabelas). Layout da esquerda pra direita, seguindo a ordem do fluxo de dados (fonte → landing → function → volume → bronze → prata → ouro).
