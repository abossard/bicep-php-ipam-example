param containerAppEnvName string
param location string
param internalOnly bool
param vnetSubnetId string
param containerAppLogAnalyticsName string
param fileShareNames object
param storageAccountName string
param userAssignedIdentityId string

var storageRole = resourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: containerAppLogAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}


resource sa 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: sa
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = [for share in items(fileShareNames): {
  parent: fileServices
  name: share.value
}]

resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: containerAppEnvName
  location: location
  properties: {
    vnetConfiguration: {
      internal: internalOnly
      infrastructureSubnetId: vnetSubnetId
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        maximumCount: 3
        minimumCount: 0
        name: 'D4'
        workloadProfileType: 'D4'
      }
    ]
  }
  
  resource caenvStorages 'storages' = [for share in items(fileShareNames): {
    name: toLower(share.key)
    properties: {
      azureFile: {
        accountName: sa.name
        shareName: share.value
        accessMode: 'ReadWrite'
        accountKey: sa.listKeys().keys[0].value
      }
    }
  }]
}

resource uaiRbacStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userAssignedIdentityId, storageRole)
  scope: sa
  properties: {
    roleDefinitionId: storageRole
    principalId: userAssignedIdentityId
    principalType: 'ServicePrincipal'
  }
}

output containerAppEnvId string = containerAppEnv.id
output staticIp string = containerAppEnv.properties.staticIp
output defaultDomain string = containerAppEnv.properties.defaultDomain
output workloadProfileName string = containerAppEnv.properties.workloadProfiles[0].name
