# Implementation Plan — apolo-infra

## Contexto

Este projeto simula, com infraestrutura real e 100% Azure, o pipeline de dados de uma empresa fictícia ("Apolo"). Uma auditoria inicial do ambiente Databricks revelou que ele já estava configurado como **Databricks Free Edition** (e não Community Edition, premissa considerada de início): serverless-only (SQL Warehouse), com Unity Catalog nativo, mas **sem suporte a ADLS Gen2 como external location/volume externo** — só storage gerenciado pelo metastore. Este plano trata essa restrição como dado de arquitetura fixo e resolve a conectividade ADLS↔Databricks via um spike de validação, não por suposição.

## Repositórios

Por governança, o projeto é dividido em 3 repositórios (cada ferramenta com ciclo de release e "time dono" próprio, como em uma empresa real):

- **[apolo-infra](https://github.com/papolonio/apolo-infra)** (este repo) — infraestrutura como código (Bicep) e setup do Databricks
- **[apolo-adf](https://github.com/papolonio/apolo-adf)** — pipelines do ADF, populados via Git integration nativa do ADF Studio (não escrito à mão)
- **[apolo-dbt](https://github.com/papolonio/apolo-dbt)** — projeto dbt (empresa fictícia "Apolo")

## Diagnóstico de gaps (priorizado)

| # | Camada | Alvo Azure | Peso portfólio | Prioridade |
|---|--------|------------|-----------------|------------|
| 1 | Ingestão | ADF com pipeline parametrizado (dataset genérico + linked service por ambiente), versionado via Git integration do ADF Studio no repo `apolo-adf` | Alto | **P1** |
| 2 | Armazenamento | ADLS Gen2, container `landing` (pouso do dado bruto vindo do ADF). Prata/ouro continuam vivendo nos catalogs Unity Catalog do Databricks | Médio-alto | **P1** |
| 3 | Ponte ADLS→Databricks | Ver "Lacuna técnica" abaixo — resolvida via spike, não assumida | Muito alto (diferencial técnico real) | **P1 (como spike)** |
| 4 | Processamento | Databricks Free Edition serverless + Unity Catalog (já existe do lado Databricks) | Alto, baixo esforço | P2 |
| 5 | Orquestração | ADF disparando dbt no Free Edition via SQL Warehouse | Alto | P2 |
| 6 | CI/CD | GitHub Actions com OIDC (Service Principal Azure sem secret estático) para deploy; `dbt build` em PR contra Free Edition | Alto | P2 |
| 7 | IaC | Bicep para ADF, ADLS, Key Vault, Monitor (`infra/`). Databricks Free Edition documentado à parte em `databricks/` (não é recurso ARM) | Alto | P2 |
| 8 | Segurança/Governança | Managed Identity ADF↔ADLS e ADF↔Key Vault; token Databricks só no Key Vault | Médio-alto | P3 |
| 9 | Observabilidade | Azure Monitor + Log Analytics, diagnostic settings do ADF, alerta de falha | Médio | P3 |

### Lacuna técnica: ponte ADLS Gen2 → Databricks Free Edition

Databricks Free Edition restringe rede de saída do compute por padrão a poucos domínios confiáveis, e configurações Spark arbitrárias (SAS via `fs.azure.sas.*`) confirmadamente falham em serverless. `COPY INTO ... WITH (CREDENTIAL (AZURE_SAS_TOKEN=...))` é sintaticamente suportado mas sem confirmação de que atravesse essa restrição no Free Edition.

Hipótese de maior confiança, por inverter a direção do tráfego: **ADF empurra arquivos via Databricks Files API** (`PUT /api/2.0/fs/files{path}`) para um **Volume gerenciado do Unity Catalog** — tráfego sempre "para dentro" do Databricks, mesma direção que `host`+`token` já usam hoje. Ver `spikes/README.md` para o detalhamento e o resultado do teste.

## Arquitetura alvo

```
[Fontes fictícias/CSV]
      │  ADF Copy Activity (parametrizado)
      ▼
[ADLS Gen2 — container "landing"]        (Azure)
      │
      │  PONTE — decidida no spike (Fase 1):
      │   A) ADF Web Activity → Databricks Files API → Volume gerenciado UC (catalog bronze)
      │   B) ADF → Databricks SQL Statement API → COPY INTO com credencial SAS inline
      │   (fallback: landing manual via Databricks CLI, documentado como gap conhecido)
      ▼
[Databricks Free Edition — Unity Catalog]
  catalog bronze  → dbt (SQL Warehouse, disparado por ADF)
  catalog prata   → staging/prata (ref/source, testes, incremental)
  catalog ouro    → dims/facts (fct_pedido_venda incremental)
      │
      ▼
[Consumo: dbt docs / Databricks SQL]

Transversal: Key Vault ← Managed Identity ← ADF
             Azure Monitor/Log Analytics ← diagnostic settings ADF
             GitHub Actions (OIDC) → Bicep deploy + dbt build/test
```

## Recursos Azure (SKU mínimo, Free Trial + always-free)

| Recurso | SKU/Tier | Nota de custo |
|---|---|---|
| Resource Group | — | grátis |
| Storage Account (ADLS Gen2) | Standard_LRS, hierarchical namespace | pay-as-you-go, volume de portfólio ~centavos/mês |
| Data Factory | V2, Azure IR auto-resolve | cobra por activity run — manter execuções pouco frequentes em dev |
| Key Vault | Standard | 10k operações/mês grátis |
| Log Analytics Workspace | Pay-as-you-go per GB | 5GB/mês sempre grátis; retenção 30 dias |
| Managed Identity | System-assigned no ADF | grátis |
| Databricks Free Edition | fora da conta de billing Azure | grátis, já configurado |

Configurar Budget + alerta em 80%/100% do crédito no Cost Management antes de provisionar (Fase 1).

## Roadmap faseado

1. **IaC básica + ADLS + spike de conectividade** (bloqueante). ✅ Concluída — `infra/main.bicep` provisionou RG/ADLS/Key Vault; Hipótese A validada no workspace real; documentado em `spikes/README.md`.
   *Pronto quando:* existe um caminho comprovado de arquivo indo do ADLS até uma tabela Delta em `bronze`. ✅
2. **ADF parametrizado**. ✅ Concluída — ADF provisionado via Bicep com Managed Identity (`Storage Blob Data Contributor` no ADLS, `Key Vault Secrets User` no Key Vault); segredos do Databricks guardados no Key Vault; Git integration conectada ao repo `apolo-adf`; `ls_adls_apolo` (linked service via Managed Identity), `ds_source`/`ds_landing` (datasets Binary parametrizados por `folderPath`/`fileName`) e `pl_copy_source_to_landing` (pipeline com ForEach) criados na UI do ADF Studio. Container `source` populado com 6 arquivos fictícios (3 tabelas × CSV/Parquet) para simular a fonte até a decisão de Postgres/SQL Server/API.
   *Pronto quando:* um pipeline processa múltiplos arquivos fictícios só variando parâmetro. ✅ (rodada real via API, `status: Succeeded`, 6 arquivos copiados de `source/` para `landing/`)
3. **Ponte ADF→Databricks em produção**. ✅ Concluída — Azure Function (`func-dbtazure-dev-cshdut3x`, Flex Consumption, `functions/bridge_to_databricks/`) provisionada e implantada, chamada pelo ADF (`ls_function_bridge`, chave via `ls_keyvault_apolo`) dentro do próprio ForEach, logo após o Copy data1.
   *Pronto quando:* rodar o pipeline do ADF deixa dado novo em `bronze` sem passo manual. ✅ (6 arquivos confirmados no Volume `bronze.landing.raw_files` via `LIST`, tamanhos batendo com os originais)
4. **Transformação disparada pelo Databricks, não pelo ADF**. ✅ Concluída — decisão revista em conversa: em vez de ADF acionar o SQL Warehouse, dois **Databricks Jobs agendados e independentes** (padrão real de "Transform Job"), separados por tag de tier no dbt (`tier_padrao`/`tier_frequente`), cada um com uma `dbt_task` que primeiro materializa `bronze.erp_ficticio.*` a partir do Volume (`dbt run-operation materialize_bronze_*`, ver `apolo-dbt/macros/ingestion/`) e depois roda `dbt build --select tag:*`. Definições versionadas em `databricks/jobs/*.json` (aplicadas via `apply_jobs.py`, já que não há tooling de Asset Bundles instalado). CI do `apolo-dbt` valida que todo model tem exatamente uma tag de tier (`scripts/validate_tiers.py`).
   - `transform_job_geral`: cron a cada 3h, `tier_padrao` (clientes/produtos → dims).
   - `transform_job_frequente`: cron a cada 30min (offset 15), `tier_frequente` (pedidos → fato de vendas).
   *Pronto quando:* o pipeline ponta-a-ponta atualiza prata/ouro a partir de bronze. ✅ (`run-now` real nos dois Jobs, `result_state: SUCCESS`, 25 checks no geral + 16 checks no frequente, todos passando)
5. **CI/CD**. ✅ Concluída — App Registration (`apolo-infra-github-oidc`) + Federated Credential (OIDC, sem secret estático) com `Contributor` + `User Access Administrator` escopados só ao `apolo-rg`; variáveis `AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID`/`AZURE_RESOURCE_GROUP` configuradas no `apolo-infra`; secrets `DATABRICKS_HOST`/`DATABRICKS_HTTP_PATH`/`DATABRICKS_TOKEN` configurados no `apolo-dbt`.
   *Pronto quando:* PR que quebra teste dbt falha o CI antes do merge. ✅ (`deploy-infra.yml` rodou via `workflow_dispatch` com sucesso; `ci-dbt.yml` validado via PR de teste, também com sucesso — ver achado do subject OIDC em `spikes/README.md`)
6. **Observabilidade**. Diagnostic settings do ADF → Log Analytics, alerta de falha de pipeline.
   *Pronto quando:* falha proposital de pipeline gera alerta visível.

## Estado de execução

- [x] Os 3 repositórios criados (`apolo-infra`, `apolo-adf`, `apolo-dbt`)
- [x] Projeto dbt migrado para o repo `apolo-dbt` (sem `seeds/`, renomeado de `pratica_dbt`)
- [x] Bicep da Fase 1 escrito (`infra/main.bicep`, `modules/storage.bicep`, `modules/key-vault.bicep`)
- [x] Workflows de CI/CD escritos (pendente configurar secrets/vars no GitHub)
- [x] Deploy do Bicep aplicado (Resource Group `apolo-rg`, Storage Account + Key Vault criados via `az login` local)
- [x] Budget de US$200 com alerta em 80%/100% configurado na subscription (`apolo-trial-budget`)
- [x] Spike de conectividade ADLS↔Databricks executado e documentado (Hipótese A confirmada — ver `spikes/README.md`)
- [x] Fase 2 concluída: ADF parametrizado com ForEach, rodando de verdade contra `source`/`landing` (ver nota sobre bug de Publish do ADF Studio no `apolo-adf/README.md`)
- [x] Fase 3 concluída: Azure Function (Flex Consumption) fazendo a ponte real `landing` → Volume do Databricks, chamada pelo ADF dentro do ForEach
- [x] Fase 4 concluída: `transform_job_geral` + `transform_job_frequente` (Databricks Jobs agendados, separados por tier) rodando de verdade via `run-now`, ambos `SUCCESS`
- [x] Fase 5 concluída: CI/CD com OIDC (sem secret estático) validado via `workflow_dispatch`, e `ci-dbt.yml` validado via PR real
- [ ] Fase 6 do roadmap (Observabilidade)
