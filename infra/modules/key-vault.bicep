@description('Nome do Key Vault (globalmente unico, 3-24 caracteres)')
param keyVaultName string

@description('Regiao de deploy')
param location string

@description('Tenant ID do Azure AD')
param tenantId string = subscription().tenantId

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

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
