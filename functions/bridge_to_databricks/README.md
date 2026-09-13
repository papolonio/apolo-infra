# bridge_to_databricks

Azure Function (Python, Flex Consumption) que executa a ponte ADLS → Databricks Free Edition validada no spike (ver `../../spikes/README.md`). Orquestrada pelo ADF, não disparada diretamente por usuários.

## O que faz

1. Recebe `{"folderPath": "...", "fileName": "..."}` via POST.
2. Lê o blob correspondente do container `landing` (Managed Identity, `Storage Blob Data Reader`).
3. Busca `DatabricksHost`/`DatabricksToken` no Key Vault (Managed Identity, `Key Vault Secrets User`).
4. Faz `PUT` do conteúdo do arquivo em `/Volumes/bronze/landing/raw_files/<fileName>` via Databricks Files API.

## Rodando localmente

```
cd functions/bridge_to_databricks
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pip install azure-functions-core-tools  # ou instalar via brew/npm

# local.settings.json (gitignored) com KEY_VAULT_URL, STORAGE_DFS_ENDPOINT
# e AzureWebJobsStorage="UseDevelopmentStorage=true" ou uma connection string real

func start
```

Localmente, `DefaultAzureCredential` cai para `az login` (sua sessão da Azure CLI) em vez da Managed Identity — funciona igual desde que sua conta tenha as mesmas permissões (Storage Blob Data Reader no `landing`, Key Vault Secrets User no Key Vault).

## Deploy

```
func azure functionapp publish func-dbtazure-dev-cshdut3x
```

(nome exato da Function App: ver output `functionAppName` do Bicep, `infra/main.bicep`)
