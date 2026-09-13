@description('Nome da Function App (globalmente unico)')
param functionAppName string

@description('Regiao de deploy (Flex Consumption nao esta disponivel em todas as regioes)')
param location string

@description('Nome da storage account dedicada ao runtime do Functions - separada da storage account de dados, para nao criar dependencia circular de permissoes')
param functionStorageAccountName string

@description('URI do Key Vault onde ficam os segredos do Databricks')
param keyVaultUri string

@description('Endpoint DFS (ADLS Gen2) da storage account de dados, onde fica o container landing')
param dataStorageDfsEndpoint string

var deploymentContainerName = 'deploymentpackage'
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'

resource functionStorageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: functionStorageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource functionBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: functionStorageAccount
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: functionBlobService
  name: deploymentContainerName
}

var functionStorageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${functionStorageAccountName};AccountKey=${functionStorageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${functionAppName}-plan'
  location: location
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp,linux'
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${functionStorageAccount.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage', value: functionStorageConnectionString }
        { name: 'KEY_VAULT_URL', value: keyVaultUri }
        { name: 'STORAGE_DFS_ENDPOINT', value: dataStorageDfsEndpoint }
      ]
    }
  }
}

// Necessario para a autenticacao SystemAssignedIdentity do deployment storage funcionar
resource deploymentStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionStorageAccount.id, functionApp.id, storageBlobDataOwnerRoleId)
  scope: functionStorageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output functionAppName string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
output principalId string = functionApp.identity.principalId
