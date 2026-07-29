targetScope = 'resourceGroup'

@minLength(3)
@maxLength(12)
param prefix string = 'spotvideo'
param location string = resourceGroup().location
param systemVmSize string = 'Standard_D2s_v5'
param spotVmSize string = 'Standard_D8s_v5'
param spotMinCount int = 0
param spotMaxCount int = 20
param kubernetesVersion string = ''
param inputContainerName string = 'input'
param outputContainerName string = 'videos'

var suffix = uniqueString(subscription().subscriptionId, resourceGroup().id)
var compactPrefix = replace(toLower(prefix), '-', '')
var aksName = '${prefix}-aks-${suffix}'
var inputStorageName = take('${compactPrefix}in${suffix}', 24)
var outputStorageName = take('${compactPrefix}out${suffix}', 24)
var acrName = take('${compactPrefix}acr${suffix}', 50)
var serviceBusName = take('${prefix}-sb-${suffix}', 50)
var workloadIdentityName = '${prefix}-workload-${suffix}'
var serviceAccountSubject = 'system:serviceaccount:spotvideo:spotvideo-worker'

resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: acrName
  location: location
  sku: { name: 'Standard' }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource inputStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: inputStorageName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_ZRS' }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource outputStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: outputStorageName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_ZRS' }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource inputBlobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: inputStorage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource outputBlobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: outputStorage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource inputContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: inputBlobService
  name: inputContainerName
  properties: { publicAccess: 'None' }
}

resource outputContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: outputBlobService
  name: outputContainerName
  properties: { publicAccess: 'None' }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2025-01-01' = {
  parent: outputStorage
  name: 'default'
}

resource stateTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2025-01-01' = {
  parent: tableService
  name: 'encodingstate'
}

resource serviceBus 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: serviceBusName
  location: location
  sku: { name: 'Standard', tier: 'Standard' }
  properties: {
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource submittedQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: serviceBus
  name: 'video-submitted'
  properties: {
    deadLetteringOnMessageExpiration: true
    defaultMessageTimeToLive: 'P7D'
    duplicateDetectionHistoryTimeWindow: 'PT10M'
    enableBatchedOperations: true
    lockDuration: 'PT5M'
    maxDeliveryCount: 10
    requiresDuplicateDetection: true
  }
}

resource completedQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: serviceBus
  name: 'segment-completed'
  properties: {
    deadLetteringOnMessageExpiration: true
    defaultMessageTimeToLive: 'P7D'
    duplicateDetectionHistoryTimeWindow: 'PT10M'
    enableBatchedOperations: true
    lockDuration: 'PT5M'
    maxDeliveryCount: 20
    requiresDuplicateDetection: true
  }
}

resource stitchedQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: serviceBus
  name: 'video-stitched'
  properties: {
    deadLetteringOnMessageExpiration: true
    defaultMessageTimeToLive: 'P14D'
    duplicateDetectionHistoryTimeWindow: 'PT10M'
    enableBatchedOperations: true
    lockDuration: 'PT5M'
    maxDeliveryCount: 10
    requiresDuplicateDetection: true
  }
}

resource workloadIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: workloadIdentityName
  location: location
}

resource aks 'Microsoft.ContainerService/managedClusters@2025-05-01' = {
  name: aksName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    dnsPrefix: aksName
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    oidcIssuerProfile: { enabled: true }
    securityProfile: { workloadIdentity: { enabled: true } }
    workloadAutoScalerProfile: { keda: { enabled: true } }
    storageProfile: { blobCSIDriver: { enabled: true } }
    agentPoolProfiles: [
      {
        name: 'systempool'
        count: 2
        vmSize: systemVmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: true
        minCount: 2
        maxCount: 5
        maxPods: 50
      }
      {
        name: 'spot'
        count: spotMinCount
        vmSize: spotVmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        mode: 'User'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: true
        minCount: spotMinCount
        maxCount: spotMaxCount
        maxPods: 30
        scaleSetPriority: 'Spot'
        scaleSetEvictionPolicy: 'Delete'
        spotMaxPrice: -1
        nodeTaints: [ 'kubernetes.azure.com/scalesetpriority=spot:NoSchedule' ]
        nodeLabels: { workload: 'video-encoding' }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
    }
  }
}

resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: workloadIdentity
  name: 'spotvideo-worker'
  properties: {
    audiences: [ 'api://AzureADTokenExchange' ]
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: serviceAccountSubject
  }
}

resource inputBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(inputStorage.id, workloadIdentity.id, 'blob-contributor')
  scope: inputStorage
  properties: {
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

resource outputBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(outputStorage.id, workloadIdentity.id, 'blob-contributor')
  scope: outputStorage
  properties: {
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

resource tableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(outputStorage.id, workloadIdentity.id, 'table-contributor')
  scope: outputStorage
  properties: {
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  }
}

resource busReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBus.id, workloadIdentity.id, 'receiver')
  scope: serviceBus
  properties: {
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0')
  }
}

resource busSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBus.id, workloadIdentity.id, 'sender')
  scope: serviceBus
  properties: {
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39')
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, 'acr-pull')
  scope: acr
  properties: {
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

output aksName string = aks.name
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output inputStorageName string = inputStorage.name
output inputContainerName string = inputContainer.name
output inputStorageServiceUri string = 'https://${inputStorage.name}.blob.${environment().suffixes.storage}'
output outputStorageName string = outputStorage.name
output outputContainerName string = outputContainer.name
output outputStorageServiceUri string = 'https://${outputStorage.name}.blob.${environment().suffixes.storage}'
output tableServiceUri string = 'https://${outputStorage.name}.table.${environment().suffixes.storage}'
output serviceBusNamespace string = replace(replace(serviceBus.properties.serviceBusEndpoint, 'https://', ''), ':443/', '')
output workloadClientId string = workloadIdentity.properties.clientId