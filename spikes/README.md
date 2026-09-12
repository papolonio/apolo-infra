# Spikes técnicos

Registro dos experimentos de validação feitos antes de comprometer a arquitetura a uma decisão irreversível.

## Pendente: ponte ADLS Gen2 → Databricks Free Edition

**Pergunta a responder:** como dados aterrissados no ADLS Gen2 (container `landing`) chegam a uma tabela Delta no catalog `bronze` do Databricks Free Edition, já que o Free Edition não permite registrar a storage account como external location/volume externo?

**Hipóteses a testar** (ver `IMPLEMENTATION_PLAN.md` na raiz do repo para o racional completo):

- **A — Files API push** (maior confiança): ADF chama `PUT /api/2.0/fs/files/Volumes/bronze/landing/raw_files/<arquivo>` no Databricks, empurrando o arquivo para um Volume gerenciado do Unity Catalog. Tráfego sai do ADF em direção ao Databricks — não depende de o compute do Databricks acessar a internet.
- **B — COPY INTO com credencial inline:** `COPY INTO bronze.<schema>.<tabela> FROM 'abfss://...' WITH (CREDENTIAL (AZURE_SAS_TOKEN = '...'))`, disparado via ADF chamando a Databricks SQL Statement Execution API. Depende do compute serverless conseguir alcançar `*.dfs.core.windows.net`, o que a documentação não confirma para o Free Edition.
- **Fallback:** landing manual via Databricks CLI (`databricks fs cp`), documentado como gap de plataforma conhecido, caso nenhuma das duas funcione de forma automatizável.

**Resultado:** _(preencher depois de rodar o teste manual — ver checklist da Fase 1 no `IMPLEMENTATION_PLAN.md`)_
