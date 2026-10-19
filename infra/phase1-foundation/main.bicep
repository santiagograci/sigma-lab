targetScope = 'resourceGroup'

// ============================================================================
// 0. PARÁMETROS Y VARIABLES (Los planos generales)
// ============================================================================
@description('Prefijo del proyecto para estandarización de nombres')
param projectName string = 'sigmalab'

@description('Entorno de despliegue')
param environment string = 'prod'

@description('Región de los recursos (toma automáticamente la del Resource Group)')
param location string = resourceGroup().location

@description('Object ID de tu usuario en Azure para poder crear secretos en Key Vault')
param adminPrincipalId string

var uniqueSuffix = uniqueString(resourceGroup().id)
var baseName = '${projectName}-${environment}'

var commonTags = {
  Owner: 'Santiago-Graciano'
  CostCenter: 'CC-DevSecOps-088'
  Project: 'Sigma-Lab'
  Environment: environment
  ManagedBy: 'Bicep-IaC'
  SecurityTier: 'ZeroTrust-RBAC'
  Phase: 'Phase-1-Foundation'
}

// ============================================================================
// 1. EL GAFETE INTELIGENTE (User-Assigned Managed Identity)
// ============================================================================
resource workloadIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${baseName}-workload'
  location: location
  tags: commonTags
}

// ============================================================================
// 2. LOS CELADORES DE LOS BARRIOS (Network Security Groups - NSGs)
// ============================================================================
resource nsgAks 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-${baseName}-aks'
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      {
        name: 'Allow-Internal-VNet-Traffic'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
    ]
  }
}

resource nsgCicd 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-${baseName}-cicd'
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      {
        name: 'Deny-Direct-Internet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ============================================================================
// 3. EL TERRENO AMURALLADO Y SUS 4 BARRIOS (Azure VNET & Subnets)
// ============================================================================
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-${baseName}'
  location: location
  tags: commonTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-aks-nodes'
        properties: {
          addressPrefix: '10.20.0.0/22'
          networkSecurityGroup: {
            id: nsgAks.id
          }
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
            { service: 'Microsoft.KeyVault' }
            { service: 'Microsoft.ServiceBus' }
            { service: 'Microsoft.ContainerRegistry' }
          ]
        }
      }
      {
        name: 'snet-privatelink'
        properties: {
          addressPrefix: '10.20.4.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-cicd-runners'
        properties: {
          addressPrefix: '10.20.5.0/24'
          networkSecurityGroup: {
            id: nsgCicd.id
          }
          serviceEndpoints: [
            { service: 'Microsoft.KeyVault' }
            { service: 'Microsoft.ContainerRegistry' }
          ]
        }
      }
      {
        name: 'snet-ingress'
        properties: {
          addressPrefix: '10.20.6.0/24'
        }
      }
    ]
  }

  // Referencia simbólica directa a la subred de AKS para evitar fallos de Preflight Validation
  resource aksSubnet 'subnets' existing = {
    name: 'snet-aks-nodes'
  }
}

// ============================================================================
// 4. LA BODEGA (Storage Account sin llaves compartidas)
// ============================================================================
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'st${projectName}${uniqueSuffix}'
  location: location
  tags: commonTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    defaultToOAuthAuthentication: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      virtualNetworkRules: [
        {
          id: vnet::aksSubnet.id
          action: 'Allow'
        }
      ]
    }
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource artifactsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobServices
  name: 'sigmalab-artifacts'
  properties: {
    publicAccess: 'None'
  }
}

// ============================================================================
// 5. EL CARTERO (Azure Service Bus + Cola con Dead-Lettering)
// ============================================================================
resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: 'sb-${baseName}-${uniqueSuffix}'
  location: location
  tags: commonTags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    minimumTlsVersion: '1.2'
    disableLocalAuth: true
    zoneRedundant: false
  }
}

resource eventsQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBusNamespace
  name: 'q-sigmalab-events'
  properties: {
    lockDuration: 'PT1M'
    maxSizeInMegabytes: 1024
    deadLetteringOnMessageExpiration: true
    maxDeliveryCount: 5
  }
}

// ============================================================================
// 6. LA CAJA FUERTE (Azure Key Vault gobernado por RBAC)
// ============================================================================
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${projectName}-${take(uniqueSuffix, 10)}'
  location: location
  tags: commonTags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      virtualNetworkRules: [
        {
          id: vnet::aksSubnet.id
        }
      ]
    }
  }
}

// ============================================================================
// 7. EL GARAJE DE CONTENEDORES (ACR sin usuario Admin)
// ============================================================================
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acr${projectName}${uniqueSuffix}'
  location: location
  tags: commonTags
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    networkRuleBypassOptions: 'AzureServices'
  }
}

// ============================================================================
// 8. EL LIBRO DE GUARDIAS: ASIGNACIONES AZURE RBAC (Least Privilege)
// ============================================================================
var roles = {
  acrPull: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  kvSecretsUser: subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    '4633458b-17de-408a-b874-0445c86b69e6'
  )
  kvSecretsOfficer: subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  )
  sbDataOwner: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '090c5cfd-751d-490a-894a-3ce6f1109419')
  storageBlobContributor: subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  )
}

resource rbacAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, workloadIdentity.id, roles.acrPull)
  scope: acr
  properties: {
    roleDefinitionId: roles.acrPull
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource rbacKvWorkload 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, workloadIdentity.id, roles.kvSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: roles.kvSecretsUser
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource rbacKvAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, adminPrincipalId, roles.kvSecretsOfficer)
  scope: keyVault
  properties: {
    roleDefinitionId: roles.kvSecretsOfficer
    principalId: adminPrincipalId
    principalType: 'User'
  }
}

resource rbacSbWorkload 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBusNamespace.id, workloadIdentity.id, roles.sbDataOwner)
  scope: serviceBusNamespace
  properties: {
    roleDefinitionId: roles.sbDataOwner
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource rbacStorageWorkload 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, workloadIdentity.id, roles.storageBlobContributor)
  scope: storageAccount
  properties: {
    roleDefinitionId: roles.storageBlobContributor
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// 9. OUTPUTS
// ============================================================================
output vnetName string = vnet.name
output aksSubnetId string = vnet::aksSubnet.id
output workloadIdentityId string = workloadIdentity.id
output workloadIdentityClientId string = workloadIdentity.properties.clientId
output acrLoginServer string = acr.properties.loginServer
output keyVaultUri string = keyVault.properties.vaultUri
output serviceBusEndpoint string = serviceBusNamespace.properties.serviceBusEndpoint
output storageBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob
