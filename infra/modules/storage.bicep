@description('Nome da storage account (globalmente unico, 3-24 caracteres, minusculas/numeros)')
param storageAccountName string

@description('Regiao de deploy')
param location string

@description('Nome do container onde o ADF pousa os arquivos brutos, antes da ponte para o Databricks')
param landingContainerName string = 'landing'

@description('Nome do container que simula o sistema de origem, ate uma fonte real (Postgres/SQL Server/API) ser decidida')
param sourceContainerName string = 'source'

@description('Principal ID da Managed Identity do ADF, para conceder acesso de leitura/escrita no container. Vazio = nenhum acesso concedido.')
param dataFactoryPrincipalId string = ''

@description('Principal ID da Managed Identity da Function de ponte pro Databricks, para conceder leitura no container landing. Vazio = nenhum acesso concedido.')
param bridgeFunctionPrincipalId string = ''

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled: true // habilita hierarchical namespace = ADLS Gen2
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource landingContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: landingContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource sourceContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: sourceContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource adfRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(dataFactoryPrincipalId)) {
  name: guid(storageAccount.id, dataFactoryPrincipalId, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: dataFactoryPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource bridgeFunctionRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(bridgeFunctionPrincipalId)) {
  name: guid(storageAccount.id, bridgeFunctionPrincipalId, storageBlobDataReaderRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
    principalId: bridgeFunctionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output primaryEndpoint string = storageAccount.properties.primaryEndpoints.dfs
