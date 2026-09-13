@description('Nome do Data Factory (globalmente unico)')
param factoryName string

@description('Regiao de deploy')
param location string

resource dataFactory 'Microsoft.DataFactory/factories@2018-06-01' = {
  name: factoryName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
}

output factoryName string = dataFactory.name
output factoryId string = dataFactory.id
output principalId string = dataFactory.identity.principalId
