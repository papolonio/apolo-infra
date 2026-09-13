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

**Solução adotada:** uma pequena **Azure Function** (Python, plano Consumption) como a peça executora — o ADF a aciona (passando qual arquivo processar), a Function lê o blob do `landing` com a própria Managed Identity e faz o `PUT` na Files API do Databricks, replicando exatamente o teste manual validado nesta seção. Do ponto de vista de quem usa o pipeline, a experiência final é a mesma de um ambiente pago (carga cai no ADF, aparece pouco depois no `bronze`) — a diferença fica só na camada de execução, contornando a limitação real do tier gratuito.
