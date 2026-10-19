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

// Sufijo único determinista para recursos que exigen nombre único mundial
var uniqueSuffix = uniqueString(resourceGroup().id)
var baseName = '${projectName}-${environment}'

var commonTags = {
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
    allowSharedKeyAccess: false // Bloquea Access Keys; obliga a usar Entra ID RBAC
    supportsHttpsTrafficOnly: true
    defaultToOAuthAuthentication: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      virtualNetworkRules: [
        {
          id: vnet.properties.subnets[0].id
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
    disableLocalAuth: true // Bloquea Connection Strings SAS; obliga a usar RBAC
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
    maxDeliveryCount: 5 // Si falla 5 veces, va a la cola de Dead-Letter
  }
}

// ============================================================================
// 6. LA CAJA FUERTE (Azure Key Vault gobernado por RBAC)
// ============================================================================
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${projectName}-${uniqueSuffix}'
  location: location
  tags: commonTags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true // Usa Azure RBAC en lugar de Access Policies antiguas
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      virtualNetworkRules: [
        {
          id: vnet.properties.subnets[0].id
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
    adminUserEnabled: false // Cero contraseñas estáticas
    publicNetworkAccess: 'Enabled'
    networkRuleBypassOptions: 'AzureServices'
  }
}

// ============================================================================
// 8. OUTPUTS
// ============================================================================
output vnetName string = vnet.name
output aksSubnetId string = vnet.properties.subnets[0].id
output workloadIdentityId string = workloadIdentity.id
output workloadIdentityClientId string = workloadIdentity.properties.clientId
output acrLoginServer string = acr.properties.loginServer
output keyVaultUri string = keyVault.properties.vaultUri
output serviceBusEndpoint string = serviceBusNamespace.properties.serviceBusEndpoint
output storageBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob
