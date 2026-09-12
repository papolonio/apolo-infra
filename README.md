# apolo-infra

Repositório de infraestrutura do projeto de portfólio: pipeline de dados 100% Azure (ADF + ADLS Gen2 + Key Vault + Bicep + GitHub Actions) alimentando um projeto dbt que roda contra um workspace **Databricks Free Edition** (Unity Catalog nativo, serverless-only).

O projeto é dividido em três repositórios, por governança — cada ferramenta com ciclo de release e time dono próprios, como em uma empresa real:

- **apolo-infra** (este repo) — infraestrutura como código (Bicep: ADLS, Key Vault, ADF, Monitor) e setup manual do Databricks
- [apolo-adf](https://github.com/papolonio/apolo-adf) — pipelines do Azure Data Factory (populado via Git integration nativa do ADF Studio, não escrito à mão)
- [apolo-dbt](https://github.com/papolonio/apolo-dbt) — projeto dbt (empresa fictícia "Apolo")

Ver `IMPLEMENTATION_PLAN.md` neste repo para o diagnóstico completo e o roadmap faseado.

## Estado atual

Auditoria e diagnóstico completos; conteúdo dbt migrado para o repo `apolo-dbt`. IaC da Fase 1 (Bicep de ADLS Gen2 + Key Vault) escrita, ainda não aplicada no Azure.

**Em aberto:** spike de conectividade ADLS↔Databricks (ver `spikes/README.md`) — o Free Edition não permite registrar a storage account como external location/volume externo, então essa ponte precisa ser validada experimentalmente antes da Fase 3 do roadmap.

## Restrição de arquitetura conhecida: Databricks Free Edition

- Serverless-only (SQL Warehouse) — sem cluster all-purpose, sem Databricks Workflows/Jobs clássicos.
- Unity Catalog nativo — catalogs `bronze`/`prata`/`ouro` reais (ganho vs. a premissa original de Community Edition).
- Sem storage account própria configurável — só storage gerenciado do metastore.
- Rede de saída do compute restrita por padrão a domínios confiáveis.

Essas restrições são tratadas como dado de arquitetura fixo, não como algo a "otimizar" — o valor de portfólio está em desenhar em volta delas de forma deliberada e documentada.

## Estrutura deste repositório

```
apolo-infra/
├── infra/                   # Bicep: ADLS Gen2, Key Vault (Fase 1); ADF, Monitor (fases seguintes)
├── databricks/               # setup manual do lado Databricks Free Edition
├── spikes/                   # validações técnicas documentadas antes de decisões de arquitetura
└── .github/workflows/         # deploy de infra (Bicep via OIDC)
```

## Roadmap

Ver `IMPLEMENTATION_PLAN.md`.
