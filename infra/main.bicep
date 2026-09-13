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

@description('Regiao da Function App - separada de "location" porque planos Consumption (Y1) podem ter cota zero em algumas regioes para subscriptions novas/Free Trial')
param functionLocation string = 'eastus2'

var suffix = uniqueString(resourceGroup().id)
var storageAccountName = toLower('${namePrefix}${environment}${suffix}')
var functionStorageAccountName = toLower('fn${namePrefix}${environment}${take(suffix, 8)}')
var keyVaultName = toLower('kv-${namePrefix}-${environment}-${take(suffix, 8)}')
var factoryName = toLower('adf-${namePrefix}-${environment}-${take(suffix, 8)}')
var functionAppName = toLower('func-${namePrefix}-${environment}-${take(suffix, 8)}')

// Nomes deterministicos (nao dependem de outputs de modulo) para quebrar a
// dependencia circular entre functionApp (precisa saber onde ficam os dados)
// e storage/keyVault (precisam do principalId da functionApp para dar acesso).
var keyVaultUri = 'https://${keyVaultName}${az.environment().suffixes.keyvaultDns}/'
var storageDfsEndpoint = 'https://${storageAccountName}.dfs.${az.environment().suffixes.storage}/'

module dataFactory 'modules/data-factory.bicep' = {
  name: 'dataFactoryDeploy'
  params: {
    factoryName: factoryName
    location: location
  }
}

module bridgeFunction 'modules/function-app.bicep' = {
  name: 'bridgeFunctionDeploy'
  params: {
    functionAppName: functionAppName
    location: functionLocation
    functionStorageAccountName: functionStorageAccountName
    keyVaultUri: keyVaultUri
    dataStorageDfsEndpoint: storageDfsEndpoint
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storageDeploy'
  params: {
    storageAccountName: storageAccountName
    location: location
    dataFactoryPrincipalId: dataFactory.outputs.principalId
    bridgeFunctionPrincipalId: bridgeFunction.outputs.principalId
  }
}

module keyVault 'modules/key-vault.bicep' = {
  name: 'keyVaultDeploy'
  params: {
    keyVaultName: keyVaultName
    location: location
    dataFactoryPrincipalId: dataFactory.outputs.principalId
    bridgeFunctionPrincipalId: bridgeFunction.outputs.principalId
  }
}

output storageAccountName string = storage.outputs.storageAccountName
output storageDfsEndpoint string = storage.outputs.primaryEndpoint
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultUri string = keyVault.outputs.keyVaultUri
output dataFactoryName string = dataFactory.outputs.factoryName
output functionAppName string = bridgeFunction.outputs.functionAppName
output functionAppHostname string = bridgeFunction.outputs.functionAppHostname
