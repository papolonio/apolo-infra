// Fase 1 do roadmap (IMPLEMENTATION_PLAN.md): IaC basica - ADLS Gen2 + Key Vault.
// Data Factory (Fase 2) e Log Analytics/Monitor (Fase 6) entram em modulos
// separados quando essas fases forem implementadas.

targetScope = 'resourceGroup'

@description('Prefixo curto usado para nomear os recursos (ex: dbtazure)')
param namePrefix string = 'dbtazure'

@description('Ambiente (dev/prod) - usado para diferenciar nomes/parametros')
param environment string = 'dev'

@description('Regiao de deploy')
param location string = resourceGroup().location

var suffix = uniqueString(resourceGroup().id)
var storageAccountName = toLower('${namePrefix}${environment}${suffix}')
var keyVaultName = toLower('kv-${namePrefix}-${environment}-${take(suffix, 8)}')

module storage 'modules/storage.bicep' = {
  name: 'storageDeploy'
  params: {
    storageAccountName: storageAccountName
    location: location
  }
}

module keyVault 'modules/key-vault.bicep' = {
  name: 'keyVaultDeploy'
  params: {
    keyVaultName: keyVaultName
    location: location
  }
}

output storageAccountName string = storage.outputs.storageAccountName
output storageDfsEndpoint string = storage.outputs.primaryEndpoint
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultUri string = keyVault.outputs.keyVaultUri
