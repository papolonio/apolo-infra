# Spikes técnicos

Registro dos experimentos de validação feitos antes de comprometer a arquitetura a uma decisão irreversível.

## Resolvido: ponte ADLS Gen2 → Databricks Free Edition

**Pergunta a responder:** como dados aterrissados no ADLS Gen2 (container `landing`) chegam a uma tabela Delta no catalog `bronze` do Databricks Free Edition, já que o Free Edition não permite registrar a storage account como external location/volume externo?

**Hipóteses a testar** (ver `IMPLEMENTATION_PLAN.md` na raiz do repo para o racional completo):

- **A — Files API push** (maior confiança): ADF chama `PUT /api/2.0/fs/files/Volumes/bronze/landing/raw_files/<arquivo>` no Databricks, empurrando o arquivo para um Volume gerenciado do Unity Catalog. Tráfego sai do ADF em direção ao Databricks — não depende de o compute do Databricks acessar a internet.
- **B — COPY INTO com credencial inline:** `COPY INTO bronze.<schema>.<tabela> FROM 'abfss://...' WITH (CREDENTIAL (AZURE_SAS_TOKEN = '...'))`, disparado via ADF chamando a Databricks SQL Statement Execution API. Depende do compute serverless conseguir alcançar `*.dfs.core.windows.net`, o que a documentação não confirma para o Free Edition.
- **Fallback:** landing manual via Databricks CLI (`databricks fs cp`), documentado como gap de plataforma conhecido, caso nenhuma das duas funcione de forma automatizável.

**Resultado: Hipótese A confirmada (2026-09-12).**

Teste executado direto contra a SQL Statement API e a Files API do workspace (simulando o que o ADF vai fazer depois):

1. `CREATE SCHEMA IF NOT EXISTS bronze.landing` e `CREATE VOLUME IF NOT EXISTS bronze.landing.raw_files` — sucesso.
2. `PUT /api/2.0/fs/files/Volumes/bronze/landing/raw_files/spike_test.csv` com um CSV de teste — **HTTP 204**, sem erro de rede.
3. Confirmado por dois caminhos independentes: `LIST '/Volumes/bronze/landing/raw_files'` via SQL mostrou o arquivo, e `GET` na Files API devolveu o conteúdo exato.
4. Fechei o loop até o fim: `CREATE TABLE bronze.landing.spike_test AS SELECT * FROM read_files('/Volumes/bronze/landing/raw_files/spike_test.csv', format => 'csv', header => true)` — sucesso, e o `SELECT` na tabela resultante trouxe a linha certa.
5. Artefatos de teste removidos (`DROP TABLE`, `DELETE` do arquivo no volume) para não deixar lixo no ambiente.

**Achado extra relevante:** o SQL Warehouse do Free Edition estava **suspenso por inatividade** (`state: STOPPED`, e uma primeira tentativa de `POST /start` retornou `DENY_NEW_AND_EXISTING_RESOURCES` / `INACTIVE`). Precisou de um login manual na UI do workspace para reativar antes da API voltar a aceitar comandos. Isso é uma limitação de plataforma a considerar no roadmap: se o pipeline do ADF ficar muito tempo sem rodar, a primeira execução depois de um período de inatividade pode falhar até alguém reativar o workspace manualmente pela UI — vale monitorar isso na Fase 6 (Observabilidade).

**Decisão:** a Fase 3 do roadmap (ponte ADF→Databricks em produção) implementa a Hipótese A. A Hipótese B (COPY INTO direto do ADLS) não foi testada, já que A já resolveu o problema com confiança — não há necessidade de validar uma segunda rota.

## Por que isso não é assim tão simples no ADF nativo (e por que é diferente de um ambiente pago)

Ao desenhar a Activity real do pipeline pra Fase 3, descobri que os conectores nativos do ADF não resolvem essa ponte de forma direta:

- **Web Activity** aceita corpo de requisição só como texto pequeno (pensado pra chamadas de controle/JSON), não é adequado pra enviar o conteúdo binário de um arquivo CSV/Parquet inteiro.
- **Copy Activity** com destino HTTP **não existe** no ADF — o conector HTTP só é suportado como origem (leitura), nunca como destino (escrita/PUT).

Isso é diferente do que acontece num ambiente de **Azure Databricks pago com Unity Catalog External Location**: nesse caso, o Databricks tem uma conexão direta e de rede irrestrita com a storage account, então basta o ADF depositar o arquivo no ADLS que o Databricks já consegue lê-lo — a "ponte" nem existe como um problema, é automática (é assim que costuma funcionar em ambientes corporativos reais). No Free Edition isso não é possível (rede de saída restrita do compute + sem External Location), então é necessário empurrar o dado ativamente de fora pra dentro.

**Solução adotada:** uma pequena **Azure Function** (Python) como a peça executora — o ADF a aciona (passando qual arquivo processar), a Function lê o blob do `landing` com a própria Managed Identity e faz o `PUT` na Files API do Databricks, replicando exatamente o teste manual validado nesta seção. Do ponto de vista de quem usa o pipeline, a experiência final é a mesma de um ambiente pago (carga cai no ADF, aparece pouco depois no `bronze`) — a diferença fica só na camada de execução, contornando a limitação real do tier gratuito.

## Outro achado real: cota zero de plano Consumption (Y1) no Free Trial

Ao provisionar a Function App via Bicep, o plano **Consumption clássico (SKU `Y1`)** falhou com `SubscriptionIsOverQuotaForSku` — `Current Limit (Y1 VMs): 0`. Testei em duas regiões diferentes (`brazilsouth` e `eastus2`) e o erro se repetiu identicamente nas duas, confirmando que é uma **restrição no nível da subscription** (não da região): contas Free Trial novas nascem com cota zero de "Dynamic VMs" por proteção antifraude da Microsoft, e liberar isso normalmente exige um pedido formal de aumento de cota.

**Solução:** testei o plano **Flex Consumption (SKU `FC1`)** — a geração mais nova do hosting serverless de Functions — e ele **não compartilha essa cota**: provisionou de primeira, sem pedido de aumento. Trocamos o Bicep pra usar Flex Consumption em vez do Consumption clássico. Também tem cota sempre gratuita generosa, então não sai do escopo de custo do projeto — só exige uma configuração um pouco diferente (`functionAppConfig` com storage de deployment via Managed Identity, em vez do modelo clássico de `WEBSITE_RUN_FROM_PACKAGE`).

## Databricks Workflows/Jobs funciona no Free Edition (ao contrário do que o README original assumia)

O `README.md` herdado do projeto original afirmava "Sem Databricks Workflows — orquestração da 'Transform Job' é simulada rodando `dbt build` manualmente/local", assumindo que o Free Edition não suporta Jobs agendados. Testei diretamente via API (`POST /api/2.1/jobs/create`) e **funciona**:

1. Criei um job real com uma `dbt_task`, `git_source` apontando pro repositório `apolo-dbt` no GitHub, e `schedule` com cron `0 0 0/3 * * ?` (a cada 3 horas) — sucesso (`job_id` retornado).
2. A `dbt_task` roda em **compute serverless** (a própria API pediu só um `environment`/`environment_key`, nunca um cluster) — coerente com o resto do Free Edition ser serverless-only.
3. Testado só a criação (job ficou `PAUSED` e foi apagado logo depois) — a execução real ainda depende de existirem tabelas `bronze.erp_ficticio.*` de verdade (hoje só há arquivos brutos no Volume), que é o que falta resolver na Fase 4.

**Implicação pro roadmap:** a Fase 4 não precisa ser "ADF aciona o SQL Warehouse pra rodar dbt build" — pode ser um **Databricks Job agendado, independente do ADF**, replicando o padrão de "Transform Job" comum em ambientes reais (a orquestração de ingestão/pousada de dado fica com o ADF; a orquestração de transformação fica inteiramente do lado do Databricks, no seu próprio ritmo).

## Fase 4 em produção: dois achados reais ao rodar o Job de verdade (não só criar)

Depois de decidir por dois Jobs (ver `IMPLEMENTATION_PLAN.md` — `transform_job_geral` a cada 3h, `transform_job_frequente` a cada 30min, separados por tag de tier), a primeira execução real (`run-now`, não só criação) revelou dois problemas de configuração, nenhum deles bloqueio de plataforma:

1. **`environment.spec.client: "1"` não é suportado neste workspace** — erro `Invalid platform channel Client-1`. Troquei para `"client": "2"` e resolveu. A versão do "client" do ambiente serverless aparentemente varia por workspace/geração da conta.
2. **O `dbt_task` do Databricks Jobs ignora o `profiles.yml` do repositório e gera seu próprio profile temporário** — confirmado rodando `dbt debug` dentro do Job: `Using profiles dir at /tmp/tmp-dbt-run-.../profiles`, com `catalog: hive_metastore` e `schema: default` (nada a ver com o `catalog: "prata"` do nosso `profiles.yml`). Como o Hive Metastore está desabilitado por política nesta conta (`UC_HIVE_METASTORE_DISABLED_EXCEPTION`), qualquer conexão que tente usar esse catalog como default falha antes mesmo de rodar qualquer SQL — mesmo com todas as referências do nosso código totalmente qualificadas (`bronze.erp_ficticio.tabela`), a própria abertura da conexão já falhava.

**Solução:** o `dbt_task` aceita `catalog`/`schema` como campos próprios (fora do `profiles.yml`) — adicionei `"catalog": "prata", "schema": "dev_pedro"` na definição de cada Job (`databricks/jobs/*.json`), forçando o profile auto-gerado a nascer com um catalog válido do Unity Catalog em vez do Hive Metastore legado. Resolveu nas duas jobs.

**Por que isso importa:** é um lembrete de que orquestradores que "geram profile automaticamente" (comum em ferramentas gerenciadas) podem silenciosamente ignorar configuração que só existe no seu projeto — sempre validar com uma execução real (`run-now`/`dbt debug`), não só a criação do recurso.

## Fase 5: subject do token OIDC do GitHub não é o formato "padrão" documentado

Ao configurar a Federated Identity Credential do Azure AD pra login OIDC do `deploy-infra.yml` (sem secret estático), criei a credencial com o subject padrão documentado pela Microsoft: `repo:papolonio/apolo-infra:ref:refs/heads/main`. O primeiro `workflow_dispatch` falhou com `AADSTS700213: No matching federated identity record found`, e a mensagem de erro revelou o subject **real** que o GitHub enviou: `repo:papolonio@174207517/apolo-infra@1367451415:ref:refs/heads/main` — com IDs numéricos internos da conta/repositório embutidos, não presentes na documentação padrão.

**Solução:** adicionei uma segunda Federated Credential com o subject exato revelado pelo erro (`apolo-infra-main-exact`). Funcionou de primeira depois disso.

**Por que isso importa:** ao configurar OIDC do zero, não assuma o formato do subject só pela documentação — dispare uma vez esperando falhar, leia a mensagem de erro (ela mostra o subject real enviado), e crie a credencial com esse valor exato. Mais rápido que tentar adivinhar variações.
