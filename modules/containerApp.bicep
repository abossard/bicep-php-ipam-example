param containerAppName string
param location string = resourceGroup().location
param userAssignedIdentityId string
param managedEnvrionmenName string
param acrName string
param targetPort int = 80
param image string
param env array = []
param volumeMounts array = []

resource managedEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' existing = {
  name: managedEnvrionmenName 
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// create volumes from volumeMounts
var volumes = [for (volumeMount, i) in volumeMounts: {
  name: volumeMount.volumeName
  storageName: volumeMount.volumeName
  storageType: 'AzureFile'
}]

resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    workloadProfileName: managedEnvironment.properties.workloadProfiles[0].name
    configuration: {
      registries: [
        {
          identity: userAssignedIdentityId
          server: acr.properties.loginServer
        }
      ]
      ingress: {
        external: true
        targetPort: targetPort
        allowInsecure: true
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: containerAppName
          image: '${acr.properties.loginServer}/${image}'
          env: env
          resources: {
            cpu: json('1')
            memory: '2Gi'
          }
          volumeMounts: volumeMounts
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
        rules: [
          {
            name: 'http-requests'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
      volumes: volumes
    }
  }
}

output containerAppUrl string = containerApp.properties.configuration.ingress.fqdn
