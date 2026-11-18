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

// Tags required by the subscription's Azure Policy. Every resource in this template gets them.
// azd fills these from env vars through main.parameters.json (see the readme).

@minLength(1)
@description('Value of the "Created By" tag, e.g. your name or email')
param createdBy string

@description('Value of the "Created On" tag (e.g. 2026-11-18). Leave empty to use today\'s UTC date.')
param createdOn string = ''

@minLength(1)
@description('Value of the "Project Name" tag')
param projectNameTag string

@minLength(1)
@description('Value of the "Estimated Monthly Cost (USD)" tag, e.g. 50')
param estimatedMonthlyCost string

@minLength(1)
@description('Value of the "Required Till" tag, e.g. 2027-03-31')
param requiredTill string

@description('Used only as the "Created On" fallback when createdOn is empty. Do not set.')
param deploymentDate string = utcNow('yyyy-MM-dd')

@description('Extra tags to apply to all resources. These override the required tags on a name clash.')
param tags object = {}

var requiredTags = {
  'Created By': createdBy
  'Created On': empty(createdOn) ? deploymentDate : createdOn
  'Project Name': projectNameTag
  'Estimated Monthly Cost (USD)': estimatedMonthlyCost
  'Required Till': requiredTill
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

