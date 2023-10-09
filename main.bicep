@description('A unique string to ensure that most global names are unique')
param salt string = uniqueString(resourceGroup().id)

@description('The name of the project. This will be used to generate names for resources')
param projectName string = 'phpipam'

@description('this decides if the apps are deployed')
param deployApps bool = true

@description('The location of the resources')
param location string = resourceGroup().location

@description('This decides if the images are imported to the acr (should only be set to true when you want the latest versions)')
param importImagesToAcr bool = false

// Default resource name templates
param containerAppName string = 'ca-${projectName}-${salt}'
param containerRegistryName string = 'acr${salt}'
param dbCredential string = '${projectName}-db-pass-${salt}'
param containerAppEnvName string = 'caenv-${projectName}-${salt}'
param containerAppLogAnalyticsName string = 'calog-${projectName}-${salt}'
param storageAccountName string = 'castrg${salt}'
param privateEndpointACRName string = 'cape-${projectName}-${salt}'
param privateEndpointStorageName string = 'cast-${projectName}-${salt}'
param privateEndpointDBName string = 'capedb-${projectName}-${salt}'
param vnetName string = 'cavnet-${projectName}-${salt}'

param dbUser string = 'dbadmin${salt}'

var privateDnsGroupNameAzureContainerRegistry = 'acrdns'
var privateDnsGroupNameForDatabase = 'dbdns'

@description('Storage File Shares to setup')
param fileShareNames object = {
  db: '${projectName}-db-data'
  logo: '${projectName}-logo'
  ca: '${projectName}-ca'
}

@description('You can allows internet temporarly for debugging purposes (should be true in general)')
param denyInternet bool = true

@description('This makes sure the environment is only accessible from within the vnet (required for UDR to work)')
param internalOnly bool = true

@description('The address space for the vnet')
param vnetAddressSpace string = '10.144.0.0/20'

param containerAppSubnetName string = 'containerapp'
param databaseSubnetName string = 'dbsubnet'
param privateLinkSubnetName string = 'privatelinks'
param appGatewaySubnetName string = 'appgwsubnet'

var acrPrivateDnsZoneName = 'privatelink${environment().suffixes.acrLoginServer}'
var storagePrivateDnsZoneName = 'privatelink.file.${environment().suffixes.storage}'
var mariadbPrivateDnsZoneName = 'privatelink.mariadb.database.azure.com'

// take the first available /23 subnet
var appEnvSubnetCidr = cidrSubnet(vnetAddressSpace, 23, 0)

// TODO: Optimize the subnetting
var firewallSubnetCidr = cidrSubnet(vnetAddressSpace, 24, 12)
var dbSubnetCidr = cidrSubnet(vnetAddressSpace, 24, 13)
var privateLinkSubnetCidr = cidrSubnet(vnetAddressSpace, 24, 14)
var appEnvSubnetAppGw = cidrSubnet(vnetAddressSpace, 24, 15)

var acrPullRole = resourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var microsoftAppEnvironmentName = 'Microsoft.App/environments'
var azureFirewallSubnetName = 'AzureFirewallSubnet'

// Chapter 000: The identity
resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${containerAppName}'
  location: location
}

// Chapter 001: VNET and Subnets
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
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
        name: containerAppSubnetName
        properties: {
          addressPrefix: appEnvSubnetCidr
          networkSecurityGroup: (denyInternet) ? {
            id: nsgDenyInternet.id
          } : null
          delegations: [ {
              name: microsoftAppEnvironmentName
              properties: {
                serviceName: microsoftAppEnvironmentName
              }
            }
          ]
        }
      }
      {
        name: azureFirewallSubnetName
        properties: {
          addressPrefix: firewallSubnetCidr
          delegations: []
          serviceEndpoints: []
        }
      }
      {
        name: databaseSubnetName
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
        name: privateLinkSubnetName
        properties: {
          addressPrefix: privateLinkSubnetCidr
          privateEndpointNetworkPolicies: 'Disabled'
          delegations: []
        }
      }
      {
        name: appGatewaySubnetName
        properties: {
          addressPrefix: appEnvSubnetAppGw
          delegations: []
        }
      }
    ]
  }
  resource containerappSubnet 'subnets' existing = {
    name: containerAppSubnetName
  }
  resource firewallSubnet 'subnets' existing = {
    name: azureFirewallSubnetName
  }
  resource dbSubnet 'subnets' existing = {
    name: databaseSubnetName
  }
  resource privateLinkSubnet 'subnets' existing = {
    name: privateLinkSubnetName
  }
  resource appGwSubnet 'subnets' existing = {
    name: appGatewaySubnetName
  }
}
// Chapter 002: Private Endpoints

// Maria DB Private Endpoint + DNS Zone
var mariaDbPrivateEndpointGroupId = 'mariadbServer'
resource mariaDbPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: privateEndpointDBName
  location: location
  properties: {
    subnet: {
      id: vnet::privateLinkSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: privateEndpointDBName
        properties: {
          privateLinkServiceId: mariaDbServer.id
          groupIds: [
            mariaDbPrivateEndpointGroupId
          ]
        }
      }
    ]
  }
  dependsOn: [
    mariadbPrivateDnsZone
    mariadbPrivateDnsZone::mariaDbPrivateDnsZoneLink
  ]

  resource mariaDbPrivateDnsGroup 'privateDnsZoneGroups' = {
    name: privateDnsGroupNameForDatabase
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

resource mariadbPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: mariadbPrivateDnsZoneName
  location: 'global'
  properties: {}
  dependsOn: [
    vnet
    acr
  ]
  resource mariaDbPrivateDnsZoneLink 'virtualNetworkLinks' = {
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

// ACR Private Endpoint + DNS Zone
resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: privateEndpointACRName
  location: location
  properties: {
    subnet: {
      id: vnet::privateLinkSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: privateEndpointACRName
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
    acrPrivateDnsZone::acrPrivateDnsZoneLink
  ]

  resource acrPrivateEndpointDnsGroup 'privateDnsZoneGroups' = {
    name: privateDnsGroupNameAzureContainerRegistry
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

resource acrPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: acrPrivateDnsZoneName
  location: 'global'
  properties: {}
  dependsOn: [
    vnet
    acr
  ]
  resource acrPrivateDnsZoneLink 'virtualNetworkLinks' = {
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

// Storage Private Endpoint and Dns Grop
resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: privateEndpointStorageName
  location: location
  properties: {
    subnet: {
      id: vnet::privateLinkSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: privateEndpointStorageName
        properties: {
          privateLinkServiceId: caenv.outputs.storageAccountId
          groupIds: [
            'storage'
          ]
        }
      }
    ]
  }
  dependsOn: [
    storagePrivateDnsZone
    storagePrivateDnsZone::storatePrivateDnsZoneLink
  ]

  resource pvtEndpointDnsGroup 'privateDnsZoneGroups' = {
    name: privateDnsGroupNameAzureContainerRegistry
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

resource storagePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: storagePrivateDnsZoneName
  location: 'global'
  properties: {}
  dependsOn: [
    vnet
    acr
  ]
  resource storatePrivateDnsZoneLink 'virtualNetworkLinks' = {
    name: '${storagePrivateDnsZoneName}-link'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnet.id
      }
    }
  }
}

// Chapter 003: The container app environment
module caenv './modules/containerAppEnvironment.bicep' = {
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
  dependsOn: [
    firewall
  ]
}

// to be able to use properties as name, this is on a separate module
module privatedns './modules/containerAppPrivateDns.bicep' = {
  name: 'privatedns'
  params: {
    defaultDomain: caenv.outputs.defaultDomain
    staticIp: caenv.outputs.staticIp
    vnetId: vnet.id
  }
}

// Chapter 004: Azure Container Registry
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

resource uaiRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, uai.id, acrPullRole)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRole
    principalId: uai.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Chapter 005: Import Docker Containers
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


// Chapter 006: THE CONTAINER APPS
resource containerAppIpam 'Microsoft.App/containerApps@2023-05-01' = if (deployApps) {
  dependsOn: importImagesToAcr ? [
    acrImport
    routeToSubnet
  ] : [
    routeToSubnet
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
            // {
            //   mountPath: '/phpipam/css/images/logo'
            //   volumeName: 'phpipam-logo'
            // }
            // {
            //   mountPath: '/usr/local/share/ca-certificates'
            //   volumeName: 'phpipam-ca'
            // }
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
        // {
        //   name: 'phpipam-logo'
        //   storageName: 'logo'
        //   storageType: 'AzureFile'
        // }
        // {
        //   name: 'phpipam-ca'
        //   storageName: 'ca'
        //   storageType: 'AzureFile'
        // }
      ]
    }
  }
}

resource containerAppIpamCron 'Microsoft.App/containerApps@2023-05-01' = if (deployApps) {
  dependsOn: importImagesToAcr ? [
    acrImport
    routeToSubnet
  ] : [
    routeToSubnet
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
            // {
            //   mountPath: '/usr/local/share/ca-certificates'
            //   volumeName: 'phpipam-ca'
            // }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
        rules: []
      }
      volumes: [
        // {
        //   name: 'phpipam-ca'
        //   storageName: 'ca'
        //   storageType: 'AzureFile'
        // }
      ]
    }
  }
}


resource containerAppDebug 'Microsoft.App/containerApps@2023-05-01' = if (deployApps) {
  dependsOn: importImagesToAcr ? [
    acrImport
    routeToSubnet
  ] : [
    routeToSubnet
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
          env: [
            {
              name: 'ITWORKS'
              value: 'YES'
            }
          ]
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

// Chapter 007: Supporting Resources
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

// Chapter 008: Making it available from the INTERNET

resource publicIPAddress 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
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

resource applicationGateway 'Microsoft.Network/applicationGateways@2023-05-01' = if (deployApps) {
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
              fqdn: deployApps ? containerAppIpam.properties.configuration.ingress.fqdn : 'https://google.com'
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

// Chapter 009: Locking down the rest
resource nsgDenyInternet 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'nsg-${projectName}-${salt}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow_VNet_Outbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
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

resource firewallPublicIPAddress 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: 'MyFirewall-PIP'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: 'azfw${salt}'
    }
  }
}

resource ruleCollectionGroup2 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-05-01' = {
  parent: firewallPolicy
  name: 'DefaultNetworkRuleCollectionGroup'
  properties: {
    priority: 100
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AzureManagement'
        action: {
          type: 'Allow'
        }
        priority: 1000
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AzureManagement'
            sourceAddresses: [
              vnetAddressSpace
            ]
            destinationPorts: [
              '1194'
              '9000'
            ]
            ipProtocols: [
              'Any'
            ]
            destinationAddresses: [
              'AzureCloud.${location}'
            ]
          }

          {
            ruleType: 'NetworkRule'
            name: 'ContainerApps'
            sourceAddresses: [
              vnetAddressSpace
            ]
            destinationPorts: [
              '80'
              '443'
            ]
            destinationAddresses: [
              'MicrosoftContainerRegistry'
              'AzureFrontDoorFirstParty'
              'AzureContainerRegistry'
              'AzureActiveDirectory'
              'AzureKeyVault'
              'AzureMonitor'
            ]
            ipProtocols: [
              'Any'
            ]
          }
        ]
      }
    ]
  }
  dependsOn: [
    ruleCollectionGroup
  ]
}

var loginEndpointWithoutProtocolAndWithoutSlashes = replace(replace(environment().authentication.loginEndpoint, 'https://', ''), '/', '')
resource ruleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-05-01' = {
  parent: firewallPolicy
  name: 'DefaultApplicationRuleCollectionGroup'
  properties: {
    priority: 110
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AzureContainerAppsEgress'
        action: {
          type: 'Allow'
        }
        priority: 1000
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'AzureManagement'
            protocols: [
              {
                protocolType: 'Http'
                port: 80
              }
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              '*.azure.com'
            ]
            sourceAddresses: [
              '*'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'DockerImages'
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              '*.docker.io'
              '*.mcr.microsoft.com'
              '*.azurecr.io'
              'hub.docker.com'
              '*.data.mcr.microsoft.com'
              'registry-1.docker.io'
              'production.cloudflare.docker.com'
            ]
            sourceAddresses: [
              '*'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'AzureContainerRegistry'
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              '*.azurecr.io'
              '*.blob.windows.net'
            ]
            sourceAddresses: [
              '*'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'AzureActiveDirectory'
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              loginEndpointWithoutProtocolAndWithoutSlashes
              '*.identity.azure.net'
              '*.${loginEndpointWithoutProtocolAndWithoutSlashes}'
              '*.login.microsoft.com'
              'login.microsoft.com'
            ]
            sourceAddresses: [
              '*'
            ]
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-05-01' = {
  name: 'myAzureFirewall'
  location: location
  properties: {

    ipConfigurations: [
      {
        name: 'config1'
        properties: {
          subnet: {
            id: vnet::firewallSubnet.id
          }
          publicIPAddress: {
            id: firewallPublicIPAddress.id
          }
        }
      }
    ]
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    threatIntelMode: 'Alert'
    firewallPolicy: {
      id: firewallPolicy.id
    }
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-05-01' = {
  name: 'myFirewallPolicy'
  location: location
  properties: {
    threatIntelMode: 'Alert'
    sku: {
      tier: 'Standard'
    }
  }
}

var firewallPrivateIp = cidrHost(firewallSubnetCidr, 3)

resource routeTable 'Microsoft.Network/routeTables@2023-05-01' = {
  name: 'myRouteTable'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'routeToFirewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

module routeToSubnet './modules/addRouteTable.bicep' = {
  name: 'addRouteToSubnet'
  params: {
    routeTableName: routeTable.name
    vnetName: vnetName
    subnetProp: vnet::containerappSubnet.properties
  }
}
