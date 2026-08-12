targetScope = 'resourceGroup'

param outputStorageName string
param workloadIdentityId string
param workloadPrincipalId string

resource outputStorage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: outputStorageName
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2025-01-01' = {
  parent: outputStorage
  name: 'default'
}

resource submittedQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2025-01-01' = {
  parent: queueService
  name: 'video-submitted'
}

resource videoResultsQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2025-01-01' = {
  parent: queueService
  name: 'video-results'
}

resource queueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(outputStorage.id, workloadIdentityId, 'queue-contributor')
  scope: outputStorage
  properties: {
    principalId: workloadPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  }
}

output queueServiceUri string = 'https://${outputStorage.name}.queue.${environment().suffixes.storage}'
