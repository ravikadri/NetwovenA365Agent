$ErrorActionPreference = "Stop"

$AzureAIProjectEndpoint = $env:AZURE_AI_PROJECT_ENDPOINT
$AgentName = $env:AGENT_NAME
$AzureContainerRegistryEndpoint = $env:AZURE_CONTAINER_REGISTRY_ENDPOINT

# Runtime settings injected into the hosted agent container (moved out of the Dockerfile).
$authorityEndpoint = "https://login.microsoftonline.com/$($env:TENANT_ID)"
$azureOpenAIEndpoint = "https://$($env:ACCOUNT_NAME).openai.azure.com/"
$modelDeployment = $env:MODEL_NAME


$agentUrl = "$($AzureAIProjectEndpoint)/agents/$($AgentName)/versions?api-version=2025-11-15-preview"

$agentCreationBody = @{
    definition = @{
        kind = "hosted"
        image = "$($AzureContainerRegistryEndpoint)/hello-world-a365-agent:latest"
        cpu = "2"
        memory = "4Gi"
        environment_variables = @{
            "Connections__ServiceConnection__Settings__AuthorityEndpoint" = $authorityEndpoint
            "AzureOpenAIEndpoint"                                         = $azureOpenAIEndpoint
            "ModelDeployment"                                             = $modelDeployment
        }
        container_protocol_versions = @(
            @{
                protocol = "activity_protocol"
                version  = "2.0.0"
            }
        )
    }
    metadata = @{
        enableVnextExperience = "true"
    }
    description = "Foundry autopilot."
    agent_endpoint = @{
        protocols = @("activity")
    }
}

$jsonBody = $agentCreationBody | ConvertTo-Json -Depth 5

Write-Host "Getting access token for https://ai.azure.com ..."

$aiAzureToken = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv


Write-Host "Token length: $($aiAzureToken.Length)"

$headers = @{
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
    "Authorization" = "Bearer $aiAzureToken"
}

if (-not $AzureAIProjectEndpoint) {
    throw "AZURE_AI_PROJECT_ENDPOINT is empty. Run 'azd env get-values' and check that provisioning produced the project endpoint output."
}

# A freshly provisioned Foundry project can take several minutes to become visible on the data plane.
# Until then every call returns 404 {"code":"NotFound","message":"Project not found"}, which made the
# postprovision hook fail right after `azd provision`. Wait for the project to answer before creating the agent.
$projectReadyUrl = "$($AzureAIProjectEndpoint)/agents?api-version=2025-11-15-preview"
$projectReadyMaxRetries = 30
$projectReadyDelaySeconds = 20

Write-Host "Waiting for Foundry project to become available at: $AzureAIProjectEndpoint"
for ($i = 1; $i -le $projectReadyMaxRetries; $i++) {
    try {
        Invoke-RestMethod -Uri $projectReadyUrl -Method Get -Headers $headers -ErrorAction Stop | Out-Null
        Write-Host "Foundry project is available."
        break
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }

        if ($statusCode -eq 404 -and $i -lt $projectReadyMaxRetries) {
            Write-Host "Project not available yet (attempt $i/$projectReadyMaxRetries), waiting ${projectReadyDelaySeconds}s..."
            Start-Sleep -Seconds $projectReadyDelaySeconds
            # The token is valid for ~1h, but refresh it in case the wait is long.
            if ($i % 10 -eq 0) {
                $aiAzureToken = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
                $headers["Authorization"] = "Bearer $aiAzureToken"
            }
        } elseif ($statusCode -eq 404) {
            throw "Foundry project at '$AzureAIProjectEndpoint' is still not found after $projectReadyMaxRetries attempts. Check that 'az account show' is on tenant $($env:TENANT_ID) / subscription $($env:SUBSCRIPTION_ID), and that the project exists in the portal. Last error: $details"
        } else {
            throw "Failed to reach Foundry project at '$AzureAIProjectEndpoint' (HTTP $statusCode): $details"
        }
    }
}

Write-Host "Creating agent version at: $agentUrl"
Write-Host "JSON Body:"
Write-Host $jsonBody

$response = Invoke-RestMethod -Uri $agentUrl `
    -Method Post `
    -Headers $headers `
    -Body $jsonBody `
    -ErrorAction Stop

Write-Host ""
Write-Host "Response:"
$response | ConvertTo-Json -Depth 100 | Write-Host

# Output the agent version
$agentVersion = $response.version
$agentGuid = $response.agent_guid
$agentDefaultInstanceClientId = $response.instance_identity.client_id
$agentDefaultInstancePrincipalId = $response.instance_identity.principal_id
$blueprintClientId = $response.blueprint.client_id
Write-Host "Agent GUID: $agentGuid"
Write-Host "Agent Version: $agentVersion"
Write-Host "Blueprint Client Id: $blueprintClientId"

# Poll for agent version provisioning status
$maxRetries = 30
$delaySeconds = 10
$provisioningStatus = $response.status
if (-not $provisioningStatus) { $provisioningStatus = "Unknown" }

Write-Host "Initial provisioning status: $provisioningStatus"

$pollUrl = "$($AzureAIProjectEndpoint)/agents/$($AgentName)/versions/$($agentVersion)?api-version=2025-11-15-preview"

if ($provisioningStatus -ne "active" -and $provisioningStatus -ne "failed") {
    for ($i = 1; $i -lt $maxRetries; $i++) {
        Write-Host "Waiting ${delaySeconds}s before poll $($i + 1)/${maxRetries}..."
        Start-Sleep -Seconds $delaySeconds

        try {
            $pollResponse = Invoke-RestMethod -Uri $pollUrl `
                -Method Get `
                -Headers $headers `
                -ErrorAction Stop

            $provisioningStatus = $pollResponse.status
            if (-not $provisioningStatus) { $provisioningStatus = "Unknown" }

            # Refresh identity client ids once they are populated by provisioning.
            if ($pollResponse.instance_identity.client_id) { $agentDefaultInstanceClientId = $pollResponse.instance_identity.client_id }
            if ($pollResponse.instance_identity.principal_id) { $agentDefaultInstancePrincipalId = $pollResponse.instance_identity.principal_id }
            if ($pollResponse.blueprint.client_id) { $blueprintClientId = $pollResponse.blueprint.client_id }
        } catch {
            Write-Host "Poll failed: $($_.Exception.Message)"
        }

        Write-Host "Provisioning status: $provisioningStatus"

        if ($provisioningStatus -eq "active" -or $provisioningStatus -eq "failed") {
            break
        }
    }
}

Write-Host "Agent version provisioned: $provisioningStatus"

if ($provisioningStatus -ne "active") {
    throw "Agent version provisioning status is '$provisioningStatus', expected 'active'."
}

# Grant Cognitive Services User role on the foundry account to the agent's default instance identity.
$accountScope = "/subscriptions/$($env:SUBSCRIPTION_ID)/resourceGroups/$($env:RESOURCE_GROUP)/providers/Microsoft.CognitiveServices/accounts/$($env:ACCOUNT_NAME)"
$cognitiveServicesUserRoleId = "a97b65f3-24c7-4388-baec-2e87135dc908"

if (-not $agentDefaultInstanceClientId -and -not $agentDefaultInstancePrincipalId) {
    throw "Agent version response did not include an instance identity (instance_identity.client_id / principal_id)."
}

# The instance identity is created by agent provisioning moments before this point, so it may not have
# replicated in Microsoft Graph yet. `az role assignment create --assignee <appId>` does a Graph lookup and
# fails with "Cannot find user or service principal in graph database". Assigning by object id with an explicit
# principal type skips that lookup; we retry to ride out replication delay.
$roleMaxRetries = 12
$roleDelaySeconds = 15

if (-not $agentDefaultInstancePrincipalId) {
    Write-Host "Resolving object id for instance identity client id $agentDefaultInstanceClientId ..."
    for ($i = 1; $i -le $roleMaxRetries; $i++) {
        $agentDefaultInstancePrincipalId = az ad sp list --filter "appId eq '$agentDefaultInstanceClientId'" --query "[0].id" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $agentDefaultInstancePrincipalId) { break }
        $agentDefaultInstancePrincipalId = $null
        Write-Host "Service principal not visible in Graph yet (attempt $i/$roleMaxRetries), waiting ${roleDelaySeconds}s..."
        Start-Sleep -Seconds $roleDelaySeconds
    }
    if (-not $agentDefaultInstancePrincipalId) {
        throw "Could not resolve the object id of the agent instance identity (client id $agentDefaultInstanceClientId) in Microsoft Graph."
    }
}

Write-Host "Granting Cognitive Services User role to principal $agentDefaultInstancePrincipalId (client id $agentDefaultInstanceClientId) on scope $accountScope"

for ($i = 1; $i -le $roleMaxRetries; $i++) {
    $roleAssignmentOutput = az role assignment create `
        --assignee-object-id $agentDefaultInstancePrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role $cognitiveServicesUserRoleId `
        --scope $accountScope 2>&1 | Out-String

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Cognitive Services User role assignment created."
        break
    } elseif ($roleAssignmentOutput -match "RoleAssignmentExists") {
        Write-Host "Cognitive Services User role assignment already exists, skipping."
        break
    } elseif ($i -lt $roleMaxRetries -and $roleAssignmentOutput -match "PrincipalNotFound|does not exist in the directory|Cannot find user or service principal") {
        Write-Host "Principal not replicated yet (attempt $i/$roleMaxRetries), waiting ${roleDelaySeconds}s..."
        Start-Sleep -Seconds $roleDelaySeconds
    } else {
        throw "Failed to create Cognitive Services User role assignment: $roleAssignmentOutput"
    }
}

# Patch agent endpoint with activity protocol
$patchUrl = "$($AzureAIProjectEndpoint)/agents/$($AgentName)?api-version=2025-11-15-preview"
$patchBody = @{
    agent_endpoint = @{
        protocols = @("activity")
        authorization_schemes = @(
        @{ "type" = "BotServiceRbac" }
    )
    }
} | ConvertTo-Json -Depth 5

Write-Host "Patching agent endpoint at: $patchUrl"
Write-Host "Patch Body:"
Write-Host $patchBody

$patchResponse = Invoke-RestMethod -Uri $patchUrl `
    -Method Patch `
    -Headers $headers `
    -Body $patchBody `
    -ErrorAction Stop

Write-Host ""
Write-Host "Patch Response:"
$patchResponse | ConvertTo-Json -Depth 100 | Write-Host

# Return agent GUID and blueprint client id for downstream scripts
return [pscustomobject]@{
    AgentGuid         = $agentGuid
    BlueprintClientId = $blueprintClientId
}
