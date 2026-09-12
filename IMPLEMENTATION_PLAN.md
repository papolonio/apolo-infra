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

1. **IaC básica + ADLS + spike de conectividade** (bloqueante). `infra/main.bicep` provisiona RG/ADLS/Key Vault; testar hipótese A e B no workspace real; documentar em `spikes/README.md`.
   *Pronto quando:* existe um caminho comprovado de arquivo indo do ADLS até uma tabela Delta em `bronze`.
2. **ADF parametrizado**. Pipeline genérico com dataset parametrizado, linked services via Key Vault + Managed Identity.
   *Pronto quando:* um pipeline processa múltiplos arquivos fictícios só variando parâmetro.
3. **Ponte ADF→Databricks em produção**. Implementa a hipótese vencedora da Fase 1 como Activity real no pipeline.
   *Pronto quando:* rodar o pipeline do ADF deixa dado novo em `bronze` sem passo manual.
4. **dbt disparado pelo ADF**. ADF aciona o SQL Warehouse para rodar `dbt build`.
   *Pronto quando:* o pipeline ponta-a-ponta atualiza prata/ouro a partir de bronze.
5. **CI/CD**. `.github/workflows/deploy-infra.yml` (OIDC, neste repo) e `ci-dbt.yml` (dbt build em PR, no repo `apolo-dbt`) — já escritos, faltando os secrets/vars reais no GitHub.
   *Pronto quando:* PR que quebra teste dbt falha o CI antes do merge.
6. **Observabilidade**. Diagnostic settings do ADF → Log Analytics, alerta de falha de pipeline.
   *Pronto quando:* falha proposital de pipeline gera alerta visível.

## Estado de execução

- [x] Os 3 repositórios criados (`apolo-infra`, `apolo-adf`, `apolo-dbt`)
- [x] Projeto dbt migrado para o repo `apolo-dbt` (sem `seeds/`, renomeado de `pratica_dbt`)
- [x] Bicep da Fase 1 escrito (`infra/main.bicep`, `modules/storage.bicep`, `modules/key-vault.bicep`)
- [x] Workflows de CI/CD escritos (pendente configurar secrets/vars no GitHub)
- [x] Deploy do Bicep aplicado (Resource Group `apolo-rg`, Storage Account + Key Vault criados via `az login` local)
- [ ] Spike de conectividade ADLS↔Databricks executado e documentado
- [ ] Fases 2-6 do roadmap
