"""Aplica as definicoes de Job deste diretorio no workspace Databricks,
de forma idempotente (cria se nao existe, atualiza via reset se ja existe).

Uso:
    DBT_DATABRICKS_HOST=... DBT_DATABRICKS_TOKEN=... python3 apply_jobs.py
"""

import glob
import json
import os
import urllib.request

HOST = os.environ["DBT_DATABRICKS_HOST"]
TOKEN = os.environ["DBT_DATABRICKS_TOKEN"]


def _request(method: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"https://{HOST}{path}",
        data=data,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp) if resp.status != 204 else {}


def _find_job_id(name: str) -> int | None:
    result = _request("GET", "/api/2.1/jobs/list?limit=100")
    for job in result.get("jobs", []):
        if job["settings"]["name"] == name:
            return job["job_id"]
    return None


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    for path in sorted(glob.glob(os.path.join(here, "*.json"))):
        with open(path) as f:
            settings = json.load(f)

        name = settings["name"]
        job_id = _find_job_id(name)

        if job_id is None:
            result = _request("POST", "/api/2.1/jobs/create", settings)
            print(f"{name}: criado (job_id={result['job_id']})")
        else:
            _request("POST", "/api/2.1/jobs/reset", {"job_id": job_id, "new_settings": settings})
            print(f"{name}: atualizado (job_id={job_id})")


if __name__ == "__main__":
    main()
