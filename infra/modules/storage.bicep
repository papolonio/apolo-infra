@description('Nome da storage account (globalmente unico, 3-24 caracteres, minusculas/numeros)')
param storageAccountName string

@description('Regiao de deploy')
param location string

@description('Nome do container que recebe o landing raw vindo do ADF (camada bronze do lado Azure)')
param bronzeContainerName string = 'bronze-raw'

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

resource bronzeContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: bronzeContainerName
  properties: {
    publicAccess: 'None'
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output primaryEndpoint string = storageAccount.properties.primaryEndpoints.dfs
