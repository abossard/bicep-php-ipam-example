@description('Creates a container app environment with a storage account and file shares')
param containerAppEnvName string

@description('The location of the container app environment')
param location string

@description('Whether the container app environment should be internal only')
param internalOnly bool

@description('The subnet ID of the VNet to deploy the container app environment into')
param vnetSubnetId string

@description('The name of the log analytics workspace to use for app logs')
param containerAppLogAnalyticsName string

@description('The names of the file shares to create')
param fileShareNames object

@description('The name of the storage account to create')
param storageAccountName string

@description('The ID of the user assigned identity to use for the storage account')
param userAssignedIdentityId string

var storageRole = resourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

/*
Log Analyutics workspace
*/
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: containerAppLogAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

/*
Storage Account and storage file shares
*/
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

/* 
The Container App Environment including the storage mounts
*/
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

// Assign the storage account role to the user assigned identity
resource uaiRbacStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userAssignedIdentityId, storageRole)
  scope: sa
  properties: {
    roleDefinitionId: storageRole
    principalId: userAssignedIdentityId
    principalType: 'ServicePrincipal'
  }
}

@description('The ID of the container app environment')
output containerAppEnvId string = containerAppEnv.id

@description('The static IP of the container app environment (internal)')
output staticIp string = containerAppEnv.properties.staticIp

@description('The default domain for the container app environment')
output defaultDomain string = containerAppEnv.properties.defaultDomain

@description('The name of the workload profile for the container app environment')
output workloadProfileName string = containerAppEnv.properties.workloadProfiles[0].name

@description('Storage Account ID')
output storageAccountId string = sa.id
