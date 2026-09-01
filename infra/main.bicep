targetScope = 'resourceGroup'

@minLength(3)
@maxLength(12)
param prefix string = 'video'
param location string = resourceGroup().location
param systemVmSize string = 'Standard_D2ds_v5'
param spotVmSize string = 'Standard_D8ds_v5'
param spotMinCount int = 0
param spotMaxCount int = 10
param armSpotVmSize string = 'Standard_D8pds_v5'
param armSpotMinCount int = 0
param armSpotMaxCount int = 10
param regularVmSize string = 'Standard_D8ds_v5'
param regularMinCount int = 0
param regularMaxCount int = 10
param kubernetesVersion string = ''
param inputContainerName string = 'input'
param outputContainerName string = 'videos'
param kubernetesNamespace string = 'video-${messageTransport}'
@allowed([
  'storagequeue'
  'servicebus'
])
param messageTransport string = 'storagequeue'

var suffix = uniqueString(subscription().subscriptionId, resourceGroup().id)
var compactPrefix = replace(toLower(prefix), '-', '')
var aksName = '${prefix}-aks-${suffix}'
var inputStorageName = take('${compactPrefix}in${suffix}', 24)
var outputStorageName = take('${compactPrefix}out${suffix}', 24)
var acrName = take('${compactPrefix}acr${suffix}', 50)
var serviceBusName = take('${prefix}-sb-${suffix}', 50)
var logAnalyticsName = take('${prefix}-logs-${suffix}', 63)
var workloadIdentityName = '${prefix}-workload-${suffix}'
var serviceAccountSubject = 'system:serviceaccount:${kubernetesNamespace}:video-worker'
var kedaOperatorSubject = 'system:serviceaccount:kube-system:keda-operator'

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

resource workloadIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: workloadIdentityName
  location: location
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
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
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalytics.id
          useAADAuth: 'true'
        }
      }
    }
    agentPoolProfiles: [
      {
        name: 'systempool'
        count: 2
        vmSize: systemVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        osDiskType: 'Ephemeral'
        osDiskSizeGB: 64
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
        osSKU: 'AzureLinux'
        osDiskType: 'Ephemeral'
        osDiskSizeGB: 64
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
        nodeLabels: {
          workload: 'video-encoding'
          'video.fastvideo/capacity-class': 'interruptible'
        }
      }
      {
        name: 'regular'
        count: regularMinCount
        vmSize: regularVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        osDiskType: 'Ephemeral'
        osDiskSizeGB: 64
        mode: 'User'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: true
        minCount: regularMinCount
        maxCount: regularMaxCount
        maxPods: 30
        nodeLabels: {
          workload: 'video-encoding'
          'video.fastvideo/capacity-class': 'regular'
        }
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

resource armSpotPool 'Microsoft.ContainerService/managedClusters/agentPools@2025-05-01' = {
  parent: aks
  name: 'armspot'
  properties: {
    count: armSpotMinCount
    vmSize: armSpotVmSize
    osType: 'Linux'
    osSKU: 'AzureLinux'
    osDiskType: 'Ephemeral'
    osDiskSizeGB: 64
    mode: 'User'
    type: 'VirtualMachineScaleSets'
    enableAutoScaling: true
    minCount: armSpotMinCount
    maxCount: armSpotMaxCount
    maxPods: 30
    scaleSetPriority: 'Spot'
    scaleSetEvictionPolicy: 'Delete'
    spotMaxPrice: -1
    nodeTaints: [ 'kubernetes.azure.com/scalesetpriority=spot:NoSchedule' ]
    nodeLabels: {
      workload: 'video-encoding'
      'video.fastvideo/capacity-class': 'interruptible'
    }
  }
}

resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: workloadIdentity
  name: '${messageTransport}-video-worker'
  properties: {
    audiences: [ 'api://AzureADTokenExchange' ]
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: serviceAccountSubject
  }
}

resource kedaOperatorFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: workloadIdentity
  name: 'keda-operator'
  dependsOn: [ federation ]
  properties: {
    audiences: [ 'api://AzureADTokenExchange' ]
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: kedaOperatorSubject
  }
}

module storageQueue './modules/storagequeue.bicep' = if (messageTransport == 'storagequeue') {
  params: {
    outputStorageName: outputStorage.name
    workloadIdentityId: workloadIdentity.id
    workloadPrincipalId: workloadIdentity.properties.principalId
  }
}

module serviceBus './modules/servicebus.bicep' = if (messageTransport == 'servicebus') {
  params: {
    serviceBusName: serviceBusName
    location: location
    workloadIdentityId: workloadIdentity.id
    workloadPrincipalId: workloadIdentity.properties.principalId
  }
}

resource inputBlobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(inputStorage.id, workloadIdentity.id, 'blob-reader')
  scope: inputStorage
  properties: {
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
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
output logAnalyticsName string = logAnalytics.name
output logAnalyticsResourceId string = logAnalytics.id
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output inputStorageId string = inputStorage.id
output inputStorageName string = inputStorage.name
output inputContainerName string = inputContainer.name
output inputStorageServiceUri string = 'https://${inputStorage.name}.blob.${environment().suffixes.storage}'
output outputStorageName string = outputStorage.name
output outputStorageId string = outputStorage.id
output outputContainerName string = outputContainer.name
output outputStorageServiceUri string = 'https://${outputStorage.name}.blob.${environment().suffixes.storage}'
output messageTransport string = messageTransport
output kubernetesNamespace string = kubernetesNamespace
output outputQueueServiceUri string = storageQueue.?outputs.queueServiceUri ?? ''
output serviceBusNamespace string = serviceBus.?outputs.fullyQualifiedNamespace ?? ''
output workloadClientId string = workloadIdentity.properties.clientId
output workloadPrincipalId string = workloadIdentity.properties.principalId
