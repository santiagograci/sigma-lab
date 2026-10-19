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
// 4. OUTPUTS
// ============================================================================
output vnetName string = vnet.name
output aksSubnetId string = vnet.properties.subnets[0].id
output workloadIdentityId string = workloadIdentity.id
output workloadIdentityClientId string = workloadIdentity.properties.clientId
