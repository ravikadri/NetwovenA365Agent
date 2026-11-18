targetScope = 'resourceGroup'

// =================================================================================================
// Main parameters
// =================================================================================================

@minLength(1)
@maxLength(64)
@description('Name of the application. Used to ensure resource names are unique.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

// =================================================================================================
// Project module parameters
// =================================================================================================

@description('Name of the Cognitive Services account')
param accountName string = '${environmentName}acct'

@description('Name of the Cognitive Services project')
param projectName string = '${environmentName}proj'

@description('Name of the Container Registry')
param containerRegistryName string = '${environmentName}acr'

@description('SKU of Cognitive Services account')
param cognitiveServicesSku string = 'S0'

@description('SKU of Container Registry')
@allowed(['Basic', 'Standard', 'Premium'])
param containerRegistrySku string = 'Basic'

param agentName string = '${environmentName}-autopilot-agent'

// =================================================================================================
// Bot Service module parameters
// =================================================================================================

@description('Model name')
param modelName string = 'gpt-5-mini'

@description('Model version')
param modelVersion string = '2025-08-07'

// =================================================================================================
// Common parameters
// =================================================================================================

@description('Extra tags to apply to all resources. These override the required governance tags below if keys collide.')
param tags object = {}

// Governance tags required by Azure Policy on this subscription
@description('Value for the "Created By" tag. Defaults to the UPN of the identity running the deployment.')
param createdBy string = ''

@description('Value for the "Project Name" tag')
param projectNameTag string = 'Netwoven A365 Agent'

@description('Value for the "Estimated Monthly Cost (USD)" tag')
param estimatedMonthlyCostUsd string = '100'

@description('Value for the "Required Till" tag (yyyy-MM-dd). Defaults to 90 days from the deployment date.')
param requiredTill string = ''

@description('Deployment timestamp. Do not set; used for the "Created On" tag.')
param deploymentTime string = utcNow('u')

var resolvedCreatedBy = !empty(createdBy) ? createdBy : (!empty(deployer().userPrincipalName) ? deployer().userPrincipalName : deployer().objectId)

var requiredTags = {
  'Created By': resolvedCreatedBy
  'Created On': dateTimeAdd(deploymentTime, 'PT0S', 'yyyy-MM-dd')
  'Project Name': projectNameTag
  'Estimated Monthly Cost (USD)': estimatedMonthlyCostUsd
  'Required Till': !empty(requiredTill) ? requiredTill : dateTimeAdd(deploymentTime, 'P90D', 'yyyy-MM-dd')
}

var allTags = union(requiredTags, tags)

// =================================================================================================
// Module deployments
// =================================================================================================

// 1. Deploy the project module (Cognitive Services account, project, and Container Registry)
module project 'modules/project.bicep' = {
  name: 'project-deployment'
  params: {
    accountName: accountName
    projectName: projectName
    containerRegistryName: containerRegistryName
    location: location
    tags: allTags
    cognitiveServicesSku: cognitiveServicesSku
    containerRegistrySku: containerRegistrySku
    modelName: modelName
    modelVersion: modelVersion
  }
}

// =================================================================================================
// Outputs - These become environment variables in post-provision.sh
// =================================================================================================

@description('ACR login server endpoint')
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = project.outputs.acrloginServer

output AZURE_AI_PROJECT_ENDPOINT string = project.outputs.foundryProjectEndpoint

output SUBSCRIPTION_ID string = subscription().subscriptionId

output RESOURCE_GROUP string = resourceGroup().name

output LOCATION string = location

output ACCOUNT_NAME string = accountName

output PROJECT_NAME string = projectName

output AGENT_NAME string = agentName

output TENANT_ID string = tenant().tenantId

output PROJECT_PRINCIPAL_ID string = project.outputs.foundryProjectPrincipalId

output MODEL_NAME string = modelName

