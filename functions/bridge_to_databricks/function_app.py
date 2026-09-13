import json
import logging
import os
from urllib.parse import urlparse

import azure.functions as func
import requests
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.storage.blob import BlobServiceClient

app = func.FunctionApp()

LANDING_CONTAINER = "landing"
DATABRICKS_VOLUME_PATH = "/api/2.0/fs/files/Volumes/bronze/landing/raw_files"

_credential = DefaultAzureCredential()


def _storage_account_blob_url() -> str:
    dfs_endpoint = os.environ["STORAGE_DFS_ENDPOINT"]
    account_name = urlparse(dfs_endpoint).hostname.split(".")[0]
    return f"https://{account_name}.blob.core.windows.net"


def _get_databricks_secrets() -> tuple[str, str]:
    vault_url = os.environ["KEY_VAULT_URL"]
    client = SecretClient(vault_url=vault_url, credential=_credential)
    host = client.get_secret("DatabricksHost").value
    token = client.get_secret("DatabricksToken").value
    return host, token


@app.function_name(name="bridge_to_databricks")
@app.route(route="bridge", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def bridge_to_databricks(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
        folder_path = body["folderPath"]
        file_name = body["fileName"]
    except (ValueError, KeyError) as exc:
        return func.HttpResponse(
            json.dumps({"error": f"Corpo invalido, esperado {{folderPath, fileName}}: {exc}"}),
            status_code=400,
            mimetype="application/json",
        )

    blob_path = f"{folder_path}/{file_name}"

    try:
        blob_service = BlobServiceClient(account_url=_storage_account_blob_url(), credential=_credential)
        blob_client = blob_service.get_blob_client(container=LANDING_CONTAINER, blob=blob_path)
        file_bytes = blob_client.download_blob().readall()
    except Exception as exc:
        logging.exception("Falha ao ler blob %s do container %s", blob_path, LANDING_CONTAINER)
        return func.HttpResponse(
            json.dumps({"error": f"Falha ao ler {blob_path} do landing: {exc}"}),
            status_code=502,
            mimetype="application/json",
        )

    try:
        databricks_host, databricks_token = _get_databricks_secrets()
        response = requests.put(
            f"https://{databricks_host}{DATABRICKS_VOLUME_PATH}/{file_name}",
            headers={"Authorization": f"Bearer {databricks_token}"},
            data=file_bytes,
            timeout=60,
        )
        response.raise_for_status()
    except Exception as exc:
        logging.exception("Falha ao empurrar %s para o Volume do Databricks", file_name)
        return func.HttpResponse(
            json.dumps({"error": f"Falha ao empurrar {file_name} para o Databricks: {exc}"}),
            status_code=502,
            mimetype="application/json",
        )

    logging.info("Arquivo %s empurrado com sucesso para %s", blob_path, DATABRICKS_VOLUME_PATH)
    return func.HttpResponse(
        json.dumps({"status": "ok", "file": file_name, "bytes": len(file_bytes)}),
        status_code=200,
        mimetype="application/json",
    )
