// Parameters
param vnetName string
param routeTableName string
param routeTableResourceGroupName string = resourceGroup().name
param subnetProp object
// Fetch existing Route Table
resource routeTable 'Microsoft.Network/routeTables@2023-05-01' existing = {
  name: routeTableName
  scope: resourceGroup(routeTableResourceGroupName)
}


resource existingVnet 'Microsoft.Network/virtualNetworks@2023-04-01' existing = {
  name: vnetName
  resource containerappSubnet 'subnets' = {
    name: 'containerapp'
    properties: {
      addressPrefix: subnetProp.addressPrefix
      networkSecurityGroup: contains(subnetProp, 'networkSecurityGroup') ? subnetProp.networkSecurityGroup : null
      delegations: subnetProp.delegations
      routeTable: {
        id: routeTable.id
      }
    }
  }
}
