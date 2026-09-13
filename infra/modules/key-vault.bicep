@description('Nome do Key Vault (globalmente unico, 3-24 caracteres)')
param keyVaultName string

@description('Regiao de deploy')
param location string

@description('Tenant ID do Azure AD')
param tenantId string = subscription().tenantId

@description('Principal ID da Managed Identity do ADF, para conceder leitura de segredos. Vazio = nenhum acesso concedido.')
param dataFactoryPrincipalId string = ''

@description('Principal ID da Managed Identity da Function de ponte pro Databricks, para conceder leitura de segredos. Vazio = nenhum acesso concedido.')
param bridgeFunctionPrincipalId string = ''

var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enableRbacAuthorization: true // acesso via role assignment (Key Vault Secrets User), nao access policy
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
  }
}

resource adfRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(dataFactoryPrincipalId)) {
  name: guid(keyVault.id, dataFactoryPrincipalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: dataFactoryPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource bridgeFunctionRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(bridgeFunctionPrincipalId)) {
  name: guid(keyVault.id, bridgeFunctionPrincipalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: bridgeFunctionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
