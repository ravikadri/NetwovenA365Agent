// Parameters for the project module
param accountName string
param projectName string

param containerRegistryName string
param location string = resourceGroup().location
param tags object = {}

param cognitiveServicesSku string = 'S0'

// Container Registry SKU
@allowed(['Basic', 'Standard', 'Premium'])
param containerRegistrySku string = 'Basic'

// Cognitive Services account properties
param publicNetworkAccess string = 'Enabled'

param modelName string
param modelVersion string

@description('Object id of the identity that runs the post-provision scripts. It is granted Azure AI User on the account. Empty skips the assignment.')
param deployerPrincipalId string = ''

@description('Principal type of deployerPrincipalId (User, ServicePrincipal, Group). Empty lets ARM resolve it.')
param deployerPrincipalType string = ''

// Cognitive Services Account
resource account 'Microsoft.CognitiveServices/accounts@2025-09-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: cognitiveServicesSku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: accountName
    publicNetworkAccess: publicNetworkAccess
    allowProjectManagement: true
  }
}

// Cognitive Services Project (child resource)
resource project 'Microsoft.CognitiveServices/accounts/projects@2026-03-01' = {
  parent: account
  name: projectName
  location: location
  kind: 'AIServices'
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: cognitiveServicesSku
  }
  properties: {
    displayName: projectName
  }
}

// Azure Container Registry
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: containerRegistryName
  location: location
  tags: tags
  sku: {
    name: containerRegistrySku
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}


// Built-in AcrPull role definition ID
var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

// Role assignment: Grant AcrPull role to the project's system managed identity
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, project.id, acrPullRoleDefinitionId)
  scope: containerRegistry
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

var cognitiveServicesUserRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24c7-4388-baec-2e87135dc908')

// Role assignment: Grant AcrPull role to the project's system managed identity
resource cogServicesUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, project.id, cognitiveServicesUserRoleDefinitionId)
  scope: account
  properties: {
    roleDefinitionId: cognitiveServicesUserRoleDefinitionId
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}


// Azure AI User: data-plane access to the Foundry account and its projects
// (Microsoft.CognitiveServices/accounts/AIServices/agents/* and the other data actions).
var azureAIUserRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')

// Role assignment: grant Azure AI User to the identity that runs the deployment. The post-provision
// scripts use that identity's `az` token to create the hosted agent version and publish it. Without this
// role the agents API returns 403 "does not have permissions for .../agents/read actions".
resource deployerAzureAIUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  name: guid(account.id, deployerPrincipalId, azureAIUserRoleDefinitionId)
  scope: account
  properties: {
    roleDefinitionId: azureAIUserRoleDefinitionId
    principalId: deployerPrincipalId
    principalType: empty(deployerPrincipalType) ? null : deployerPrincipalType
  }
}

resource modelDeployment'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  name: modelName
  parent: account
  tags: tags
  sku: {
    name: 'GlobalStandard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}


output acrloginServer string = containerRegistry.properties.loginServer

output foundryProjectEndpoint string = project.properties.endpoints['AI Foundry API']

output foundryProjectPrincipalId string = project.identity.principalId
