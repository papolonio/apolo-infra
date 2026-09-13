// Fase 1 (IMPLEMENTATION_PLAN.md): ADLS Gen2 + Key Vault.
// Fase 2: Data Factory com Managed Identity + acesso a Storage/Key Vault.
// Log Analytics/Monitor (Fase 6) entra em modulo separado quando essa fase chegar.

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
var factoryName = toLower('adf-${namePrefix}-${environment}-${take(suffix, 8)}')

module dataFactory 'modules/data-factory.bicep' = {
  name: 'dataFactoryDeploy'
  params: {
    factoryName: factoryName
    location: location
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storageDeploy'
  params: {
    storageAccountName: storageAccountName
    location: location
    dataFactoryPrincipalId: dataFactory.outputs.principalId
  }
}

module keyVault 'modules/key-vault.bicep' = {
  name: 'keyVaultDeploy'
  params: {
    keyVaultName: keyVaultName
    location: location
    dataFactoryPrincipalId: dataFactory.outputs.principalId
  }
}

output storageAccountName string = storage.outputs.storageAccountName
output storageDfsEndpoint string = storage.outputs.primaryEndpoint
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultUri string = keyVault.outputs.keyVaultUri
output dataFactoryName string = dataFactory.outputs.factoryName
