param salt string = uniqueString(resourceGroup().id)

param projectName string = 'phpipam'

param containerAppName string = 'ca-${projectName}-${salt}'
param containerRegistryName string = 'acr${salt}'

param dbCredential string = '${projectName}-db-pass-${salt}'
param dbUser string = 'andre'
param containerAppEnvName string = 'caenv-${projectName}-${salt}'

param location string = resourceGroup().location
param importImagesToAcr bool = false
var pvtEndpointDnsGroupName = 'mydnsgroupname'
var pvtEndpointDnsGroupNameDB = 'mydnsgroupnamedb'
param containerAppLogAnalyticsName string = 'calog-${projectName}-${salt}'
param storageAccountName string = 'castrg${salt}'
param fileShareNames object = {
  db: '${projectName}-db-data'
  logo: '${projectName}-logo'
  ca: '${projectName}-ca'
}

param privateEndpointName string = 'cape-${projectName}-${salt}'
param privateEndpointNameDB string = 'capedb-${projectName}-${salt}'
param acrPrivateDnsZoneName string = 'privatelink${environment().suffixes.acrLoginServer}'
param mariadbPrivateDnsZoneName string = 'privatelink.mariadb.database.azure.com'
// privatelink.mariadb.database.windows.net
// mariadb-phpipam-4445dycckcnae.mariadb.database.azure.com
param vnetName string = 'cavnet-${projectName}-${salt}'
param internalOnly bool = true
param vnetAddressSpace string = '10.144.0.0/20'

var appEnvSubnetCidr = cidrSubnet(vnetAddressSpace, 23, 0)
var dbSubnetCidr = cidrSubnet(vnetAddressSpace, 24, 13)
var privateLinkSubnetCidr = cidrSubnet(vnetAddressSpace, 24, 14)
var appEnvSubnetAppGw = cidrSubnet(vnetAddressSpace, 24, 15)

var acrPullRole = resourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')


resource privateEndpointDb 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: privateEndpointNameDB
  location: location
  properties: {
    subnet: {
      id: vnet::privateLinkSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: privateEndpointNameDB
        properties: {
          privateLinkServiceId: mariaDbServer.id
          groupIds: [
            'mariadbServer'
          ]
        }
      }
    ]
  }
  dependsOn: [
    mariadbPrivateDnsZone
    mariadbPrivateDnsZone::privateDnsZoneLink
  ]

  resource pvtEndpointDnsGroup 'privateDnsZoneGroups' = {
    name: pvtEndpointDnsGroupNameDB
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'config1'
          properties: {
            privateDnsZoneId: mariadbPrivateDnsZone.id
          }
        }
      ]
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: vnet::privateLinkSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: acr.id
          groupIds: [
            'registry'
          ]
        }
      }
    ]
  }
  dependsOn: [
    acrPrivateDnsZone
    acrPrivateDnsZone::privateDnsZoneLink
  ]

  resource pvtEndpointDnsGroup 'privateDnsZoneGroups' = {
    name: pvtEndpointDnsGroupName
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'config1'
          properties: {
            privateDnsZoneId: acrPrivateDnsZone.id
          }
        }
      ]
    }
  }
}
module caenv 'caenv.bicep' = {
  name: 'caenv'
  params: {
    fileShareNames: fileShareNames
    storageAccountName: storageAccountName
    userAssignedIdentityId: uai.properties.principalId
    containerAppEnvName: containerAppEnvName
    location: location
    containerAppLogAnalyticsName: containerAppLogAnalyticsName
    internalOnly: internalOnly
    vnetSubnetId: vnet::containerappSubnet.id
  }
}

module privatedns 'privatedns.bicep' = {
  name: 'privatedns'
  params: {
    defaultDomain: caenv.outputs.defaultDomain
    staticIp: caenv.outputs.staticIp
    vnetId: vnet.id
  }
}

resource mariadbPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: mariadbPrivateDnsZoneName
  location: 'global'
  properties: {}
  dependsOn: [
    vnet
    acr
  ]
  resource privateDnsZoneLink 'virtualNetworkLinks' = {
    name: '${mariadbPrivateDnsZoneName}-link'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnet.id
      }
    }
  }
}

resource acrPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: acrPrivateDnsZoneName
  location: 'global'
  properties: {}
  dependsOn: [
    vnet
    acr
  ]
  resource privateDnsZoneLink 'virtualNetworkLinks' = {
    name: '${acrPrivateDnsZoneName}-link'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnet.id
      }
    }
  }
}
// network security group to deny internet
resource nsgDenyInternet 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: 'nsg-${projectName}-${salt}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'deny-internet'
        properties: {
          priority: 2000
          access: 'Deny'
          direction: 'Outbound'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
          protocol: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressSpace
      ]
    }
    subnets: [
      {
        name: 'containerapp'
        properties: {
          addressPrefix: appEnvSubnetCidr
          networkSecurityGroup: {
            id: nsgDenyInternet.id
          }
          delegations: [ {
              name: 'Microsoft.App/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            } ]
        }
      }
      {
        name: 'dbsubnet'
        properties: {
          addressPrefix: dbSubnetCidr
          delegations: []
          serviceEndpoints: [
            {
              service: 'Microsoft.Sql'
              locations: [
                location
              ]
            }
          ]
        }
      }
      {
        name: 'privatelinks'
        properties: {
          addressPrefix: privateLinkSubnetCidr
          privateEndpointNetworkPolicies: 'Disabled'
          delegations: []
        }
      }
      {
        name: 'appgwsubnet'
        properties: {
          addressPrefix: appEnvSubnetAppGw
          delegations: []
        }
      }
    ]
  }
  resource containerappSubnet 'subnets' existing = {
    name: 'containerapp'
  }
  resource dbSubnet 'subnets' existing = {
    name: 'dbsubnet'
  }
  resource privateLinkSubnet 'subnets' existing = {
    name: 'privatelinks'
  }
  resource appGwSubnet 'subnets' existing = {
    name: 'appgwsubnet'
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2022-12-01' = {
  name: containerRegistryName
  location: location
  sku: {
    name: 'Premium'
  }
  properties: {
    publicNetworkAccess: 'Disabled'
    adminUserEnabled: true
  }
}

resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${containerAppName}'
  location: location
}

resource uaiRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, uai.id, acrPullRole)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRole
    principalId: uai.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('An array of fully qualified images names to import')
param images array = [
  'docker.io/phpipam/phpipam-www:latest'
  'docker.io/phpipam/phpipam-cron:latest'
  'docker.io/library/mariadb:latest'
  'docker.io/library/debian:latest'
  'mcr.microsoft.com/k8se/quickstart:latest'
  'gcr.io/google_containers/echoserver:1.10'
]

module acrImport 'br/public:deployment-scripts/import-acr:1.0.1' = if (importImagesToAcr) {
  name: 'ImportAcrImages'
  params: {
    acrName: acr.name
    location: location
    images: images
    cleanupPreference: 'OnSuccess'
    useExistingManagedIdentity: true
    managedIdentityName: uai.name
  }
}

resource containerAppIpam 'Microsoft.App/containerApps@2023-05-01' = {
  dependsOn: importImagesToAcr ? [
    acrImport
  ] : [

  ]
  name: containerAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uai.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: caenv.outputs.containerAppEnvId
    workloadProfileName: caenv.outputs.workloadProfileName
    configuration: {
      registries: [
        {
          identity: uai.id
          server: acr.properties.loginServer
        }
      ]
      ingress: {
        external: true
        targetPort: 80
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
          name: 'phpipam-www'
          image: '${acr.properties.loginServer}/phpipam/phpipam-www:latest'
          env: [
            {
              name: 'TZ'
              value: 'Europe/London'
            }
            {
              name: 'IPAM_DATABASE_HOST'
              value: mariaDbServer.properties.fullyQualifiedDomainName
            }
            {
              name: 'IPAM_DATABASE_PASS'
              value: dbCredential
            }
            {
              name: 'IPAM_DATABASE_USER'
              value: dbUser
            }
            {
              name: 'IPAM_DEBUG'
              value: 'true'
            }
            {
              name: 'IPAM_DATABASE_NAME'
              value: 'phpipam'
            }
            {
              name: 'IPAM_DATABASE_PORT'
              value: '3306'
            }
          ]
          resources: {
            cpu: json('1')
            memory: '2Gi'
          }
          volumeMounts: [
            {
              mountPath: '/phpipam/css/images/logo'
              volumeName: 'phpipam-logo'
            }
            {
              mountPath: '/usr/local/share/ca-certificates'
              volumeName: 'phpipam-ca'
            }
          ]
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
      volumes: [
        {
          name: 'phpipam-logo'
          storageName: 'logo'
          storageType: 'AzureFile'
        }
        {
          name: 'phpipam-ca'
          storageName: 'ca'
          storageType: 'AzureFile'
        }
      ]
    }
  }
}

resource containerAppIpamCron 'Microsoft.App/containerApps@2023-05-01' = {
  dependsOn: importImagesToAcr ? [
    acrImport
  ] : [
    
  ]
  name: '${containerAppName}-cron'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uai.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: caenv.outputs.containerAppEnvId
    workloadProfileName: caenv.outputs.workloadProfileName
    configuration: {
      registries: [
        {
          identity: uai.id
          server: acr.properties.loginServer
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'phpipam-cron'
          image: '${acr.properties.loginServer}/phpipam/phpipam-cron:latest'
          env: [
            {
              name: 'TZ'
              value: 'Europe/London'
            }
            {
              name: 'IPAM_DATABASE_HOST'
              value: mariaDbServer.properties.fullyQualifiedDomainName
            }
            {
              name: 'IPAM_DATABASE_PASS'
              value: dbCredential
            }
            {
              name: 'IPAM_DATABASE_USER'
              value: dbUser
            }
            {
              name: 'IPAM_DEBUG'
              value: 'true'
            }
            {
              name: 'IPAM_DATABASE_NAME'
              value: 'phpipam'
            }
            {
              name: 'IPAM_DATABASE_PORT'
              value: '3306'
            }
            {
              name: 'SCAN_INTERVAL'
              value: '5m'
            }
          ]
          resources: {
            cpu: json('1')
            memory: '2Gi'
          }
          volumeMounts: [
            {
              mountPath: '/usr/local/share/ca-certificates'
              volumeName: 'phpipam-ca'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
        rules: [
         
        ]
      }
      volumes: [
        {
          name: 'phpipam-ca'
          storageName: 'ca'
          storageType: 'AzureFile'
        }
      ]
    }
  }
}

param mariaDbServerName string = 'mariadb-${projectName}-${salt}'

resource mariaDbServer 'Microsoft.DBforMariaDB/servers@2018-06-01' = {
  name: mariaDbServerName
  location: location
  sku: {
    name: 'GP_Gen5_2'
    tier: 'GeneralPurpose'
    capacity: 2
    size: '51200' //a string is expected here but a int for the storageProfile...
    family: 'Gen5'
  }
  properties: {
    sslEnforcement: 'Disabled'
    createMode: 'Default'
    version: '10.3'
    administratorLogin: dbUser
    administratorLoginPassword: dbCredential
    storageProfile: {
      storageMB: 51200
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    publicNetworkAccess: 'Disabled'
  }
  // resource allowAllAzure 'firewallRules' = {
  //   name: 'AllowAllWindowsAzureIps'
  //   properties: {
  //     startIpAddress: '0.0.0.0'
  //     endIpAddress: '0.0.0.0'
  //   }
  // }

// resource virtualNetworkRule 'virtualNetworkRules@2018-06-01' = {
//   name: 'myrule'
//   properties: {
//     virtualNetworkSubnetId: vnet::dbSubnet.id
//   }
// }

}

resource containerAppDebug 'Microsoft.App/containerApps@2023-05-01' = {
  dependsOn: importImagesToAcr ? [
    acrImport
  ] : [

  ]
  name: 'debugcontainerapp'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uai.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: caenv.outputs.containerAppEnvId
    workloadProfileName: caenv.outputs.workloadProfileName
    configuration: {
      registries: [
        {
          identity: uai.id
          server: acr.properties.loginServer
        }
      ]
      ingress: {
        external: true
        targetPort: 8080
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
          name: 'debugcontainer'
          image: '${acr.properties.loginServer}/google_containers/echoserver:1.10'
          env: []
          resources: {
            cpu: json('1')
            memory: '2Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
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
      volumes: []
    }
  }
}

resource publicIPAddress 'Microsoft.Network/publicIPAddresses@2020-06-01' = {
  name: 'MyApplicationGateway-PIP'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: 'appgw${salt}'
    }
  }
}
param applicationGatewayName string = 'appgw-${containerAppName}'

resource applicationGateway 'Microsoft.Network/applicationGateways@2021-05-01' = {
  name: applicationGatewayName
  location: location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
    }
    autoscaleConfiguration: {
      minCapacity: 1
      maxCapacity: 3
    }
    enableHttp2: true
    gatewayIPConfigurations: [
      {
        name: 'MyGatewayIPConfiguration'
        properties: {
          subnet: {
            id: vnet::appGwSubnet.id
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'MyFrontendIPConfiguration'
        properties: {
          publicIPAddress: {
            id: publicIPAddress.id
          }
        }
      }
    ]
    rewriteRuleSets: [
      {
        name: 'HTTP_X_FORWARDED_HOST'
        properties: {
          rewriteRules: [
            {
              ruleSequence: 100
              conditions: []
              name: 'HTTP_X_FORWARDED_HOST'
              actionSet: {
                requestHeaderConfigurations: [
                  {
                    headerName: 'HTTP-X-FORWARDED-HOST'
                    headerValue: '{var_host}'
                  }
                  {
                    headerName: 'X-FORWARDED-HOST'
                    headerValue: '{var_host}'
                  }
                ]
              }
            }
          ]
        }
      }
    ]
    frontendPorts: [
      {
        name: 'MyFrontendPort'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'MyBackendAddressPool'
        properties: {
          backendAddresses: [
            {
              //fqdn: containerAppDebug.properties.configuration.ingress.fqdn
              fqdn: containerAppIpam.properties.configuration.ingress.fqdn
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'MyBackendHttpSetting'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
        }
      }
    ]
    httpListeners: [
      {
        name: 'MyHttpListener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', applicationGatewayName, 'MyFrontendIPConfiguration')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', applicationGatewayName, 'MyFrontendPort')
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'MyRequestRoutingRule'
        properties: {
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', applicationGatewayName, 'MyHttpListener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', applicationGatewayName, 'MyBackendAddressPool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', applicationGatewayName, 'MyBackendHttpSetting')
          }
          rewriteRuleSet: {
            id: resourceId('Microsoft.Network/applicationGateways/rewriteRuleSets', applicationGatewayName, 'HTTP_X_FORWARDED_HOST')
          }
        }
      }
    ]
  }
}

output containerAppFQDN string = containerAppIpam.properties.configuration.ingress.fqdn
