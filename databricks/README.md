# Setup manual do Databricks Free Edition

O Databricks Free Edition não é um recurso ARM/Azure — não é provisionável via Bicep. Esta pasta documenta os passos manuais feitos direto no workspace.

## Pré-requisitos já existentes

- Workspace Databricks Free Edition ativo, com Unity Catalog habilitado por padrão.
- Catalogs `bronze`, `prata`, `ouro` já criados (usados pelo `dbt_project.yml` do repo [apolo-dbt](https://github.com/papolonio/apolo-dbt)).
- Um SQL Warehouse serverless configurado (usado via `host`/`http_path` no `profiles.yml`).

## Passos para este repositório

1. **Personal Access Token (PAT):** User Settings → Developer → Access tokens → Generate new token. Guardar como secret `DATABRICKS_TOKEN` no GitHub (Settings → Secrets and variables → Actions) e, quando o Key Vault estiver provisionado, também como um secret lá (para o ADF ler em runtime).
2. **Volume gerenciado para o spike de conectividade** (ver `spikes/`): criar, dentro do catalog `bronze`, um schema e volume gerenciado para receber os arquivos empurrados pelo ADF via Files API:
   ```sql
   CREATE SCHEMA IF NOT EXISTS bronze.landing;
   CREATE VOLUME IF NOT EXISTS bronze.landing.raw_files;
   ```
3. **Variáveis de ambiente locais** (`.exemplo.env` no repo [apolo-dbt](https://github.com/papolonio/apolo-dbt) como referência): copiar para `.env` (gitignored) com os valores reais de `DBT_DATABRICKS_HOST`, `DBT_DATABRICKS_HTTP_PATH`, `DBT_DATABRICKS_TOKEN`.

## Limitações conhecidas

- Serverless-only: sem cluster all-purpose, sem Databricks Workflows/Jobs clássicos.
- Sem external location/volume externo apontando para ADLS Gen2 — só storage gerenciado do metastore.
- Rede de saída do compute restrita por padrão a poucos domínios confiáveis (não teria por que valer para a Files API, que é tráfego de entrada — ver `spikes/`).
