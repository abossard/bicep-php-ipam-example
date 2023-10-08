param vnetName string = 'cavnet-${projectName}-${salt}'
param salt string = uniqueString(resourceGroup().id)

param projectName string = 'phpipam'

resource existingVnet 'Microsoft.Network/virtualNetworks@2023-05-01' existing =  {
  name: vnetName
  resource containerappSubnet 'subnets' existing = {
    name: 'containerapp'
  }
}

module routeToSubnet 'addRouteTable.bicep' = {
  name: 'addRouteToSubnet'
  params: {
    routeTableName: 'myRouteTable'
    vnetName: vnetName
    subnetProp: existingVnet::containerappSubnet.properties
  }
}
