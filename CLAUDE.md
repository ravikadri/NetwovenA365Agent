# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A sample that deploys a C# (.NET 9, ASP.NET Core) agent as a **Foundry hosted agent** and publishes it to Microsoft 365 as an **Autopilot / digital worker** (Agent 365). It uses Azure Developer CLI (`azd`) for infra and PowerShell scripts for the build, agent creation and publish steps. You must be enrolled in the Frontier preview program, and a tenant admin must approve the agent blueprint in the M365 admin center after deployment. There are no tests and no lint config.

## Commands

All scripts are `pwsh`. Run azd from the repo root.

```powershell
az login --tenant <tenant-id>; azd auth login --tenant-id <tenant-id>
azd provision                 # deploys infra/main.bicep, then runs the postprovision hook (scripts/post-provision.ps1)
azd env get-values            # env vars that the scripts read

# Local build/run (from src/hello_world_a365_agent)
dotnet build
dotnet run --launch-profile http          # http://localhost:6280 (ASPNETCORE_ENVIRONMENT=Development enables Swagger)

# Individual deployment steps (they read azd env vars, so load them into the session first)
./scripts/build-docker-image-acr.ps1      # dotnet publish -> ./publish, then `az acr build` with foundry-infra/Dockerfile
./scripts/agent-creation-script.ps1       # POST a hosted agent version to the Foundry project, poll it, assign roles, PATCH it
./scripts/publish-digital-worker.ps1 -BlueprintClientId <id>   # POST .../microsoft365/publish (publishAsAutopilot)
```

SDK is pinned by `src/hello_world_a365_agent/global.json` (9.0.305, rollForward latestFeature). The `publish/` folder is a build artifact. The ACR script deletes `publish/`, `.vs/`, `bin/` and `obj/` before building and removes `publish/` afterward. The Dockerfile only copies `./publish`, so the image has to be built from a fresh `dotnet publish`.

## Deployment pipeline (spans several files)

1. **Infra**: `infra/main.bicep` → `infra/modules/project.bicep`. Creates a Cognitive Services account, a Foundry project with a managed identity, ACR (with AcrPull for the project identity), a Cognitive Services User role assignment, and a model deployment (`modelName`/`modelVersion` params).
2. **Bicep outputs become azd env vars that the scripts depend on**: `AZURE_CONTAINER_REGISTRY_ENDPOINT`, `AZURE_AI_PROJECT_ENDPOINT`, `SUBSCRIPTION_ID`, `RESOURCE_GROUP`, `LOCATION`, `ACCOUNT_NAME`, `PROJECT_NAME`, `AGENT_NAME`, `TENANT_ID`, `PROJECT_PRINCIPAL_ID`, `MODEL_NAME`.
3. **Post-provision hook** (`azure.yaml`): build image → create agent version → publish digital worker. `agent-creation-script.ps1` returns `AgentGuid`/`BlueprintClientId`, and that value is passed to the publish script.
4. The agent version (`kind: hosted`, `activity_protocol` 2.0.0, port 8088) receives runtime config as container env vars: `Connections__ServiceConnection__Settings__AuthorityEndpoint`, `AzureOpenAIEndpoint` (`https://<ACCOUNT_NAME>.openai.azure.com/`), and `ModelDeployment`. Add new runtime settings in `agent-creation-script.ps1`, not the Dockerfile.

If you rename or remove a `main.bicep` output, update the scripts that read it. azd only puts outputs into `azd env`, so a missing output shows up as an empty env var in the scripts, not as a deploy error.

## Agent runtime architecture (`src/hello_world_a365_agent`)

- **`Program.cs`**: wires the Microsoft Agents SDK (`AddAgent<A365AgentApplication>`, `MemoryStorage`), adds optional Key Vault config (`KeyVaultName`), and maps the `FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID` env var to `Connections:ServiceConnection:Settings:ClientId`. It also sets up Application Insights (`APPLICATIONINSIGHTS_CONNECTION_STRING`, which Foundry injects) and `AgentRequestCorrelationMiddleware`. That middleware keeps the `/activity/messages` operation id when `CloudAdapter` moves work to its background queue. Endpoints: `POST /activity/messages`, `/liveness`, `/readiness`.
- **`AgentLogic/A365AgentApplication.cs`**: the activity router. It registers handlers for Agent 365 notifications (Email, Word/Excel/PowerPoint comments) and `Message` activities. It builds `AgentMetadata` from the activity recipient and gets an `IAgentLogicService` from the factory. Message replies go through `StreamingResponse`, and errors stream back the `FOUNDRY_AGENT_SESSION_ID` (the README describes how to fetch logs with it).
- **`ResponsesApi/ResponsesApiAgentLogicServiceFactory.cs`**: gets an agentic token (audience `ea9ffc3e-...`) through `AgentTokenCredential`/`AgentTokenHelper`. It finds MCP servers from `ToolingManifest.json` or the Agent365 API, depending on the `McpDiscoverySource` config (`Manifest` | `API`; appsettings uses `Manifest`).
- **`ResponsesApi/ResponsesApiAgentLogicService.cs`**: rewrites the incoming text for each channel (email / msteams / installationUpdate). It then calls Azure OpenAI `/openai/responses` with the MCP servers as `mcp` tools (bearer = the agentic token, `require_approval: never`). The Responses API call authenticates with `DefaultAzureCredential` using the managed identity in `FOUNDRY_AGENT_DEFAULT_INSTANCE_CLIENT_ID`. For conversation continuity it saves `previous_response_id` to `~/.a365agent/<sha256(conversationId)>.responseid`.
- Customize the agent through `AgentLogic/AgentInstructions.cs` (system prompt) and `ToolingManifest.json` (MCP servers; copied to output).

Running locally does not exercise the full flow, because the agentic auth and managed identity env vars (`FOUNDRY_AGENT_*`) are only present inside the Foundry hosted container.
