# Azure Deployment Plan

> **Status:** Validated

Updated: 2026-10-06

---

## Current Change: Bicep-managed VNet-integrated SRE Agent

### Objective

Add an additive Bicep deployment that provisions the Azure SRE Agent and its
supporting resources, including VNet integration, while preserving the existing
PowerShell/Azure CLI workflow that creates AKS and deploys the demo workload.

### Confirmed Azure Context

| Attribute | Value |
|-----------|-------|
| Classification | POC / demo |
| Scale | Small |
| Budget | Cost-optimized |
| Subscription | `ME-MngEnvMCAP335410-pahuber-1` (`ab021129-9bf3-4ee3-bbc6-3da839fb88a1`) |
| Tenant | `5cd15b26-2657-4947-96ac-a22a1b5ce635` |
| Location | Sweden Central (`swedencentral`) |
| Resource group | `rg-sre-aks` |
| AKS cluster | `aks-sre-agent-demo` |
| SRE Agent | `sre-agent-aks-demo` |

### Repository Analysis

- The repository currently contains no Bicep templates.
- AKS remains deployed by `01-prerequisites.ps1` through
  `04-setup-nap.ps1`; converting that workflow is outside this change.
- The existing SRE Agent, identity, Log Analytics workspace, and Application
  Insights names will be used so an incremental deployment updates them rather
  than creating duplicates.
- The new Bicep deployment will reference the existing AKS cluster for RBAC.

### Selected Recipe

**Standalone Bicep**, deployed at resource-group scope after the AKS cluster is
created. This is the smallest change that makes SRE Agent setup reproducible
without replacing the repository's established AKS scripts.

### Architecture

| Component | Resource | Planned configuration |
|-----------|----------|-----------------------|
| Agent network | `Microsoft.Network/virtualNetworks` | Dedicated `10.250.0.0/24` VNet |
| Agent subnet | VNet subnet | `10.250.0.0/27`, delegated to `Microsoft.App/environments` |
| Agent identity | `Microsoft.ManagedIdentity/userAssignedIdentities` | `id-sre-agent-aks-demo` |
| Agent telemetry | Log Analytics + Application Insights | `law-sre-agent-aks-demo` and `appi-sre-agent-aks-demo` |
| SRE Agent | `Microsoft.App/agents@2025-05-01-preview` | Autonomous, high access, RG managed-resource scope |
| VNet integration | Agent properties | `vnetConfiguration.subnetResourceId` points to the delegated subnet |
| Sandbox egress | Agent properties | `AzureVNet`; public Azure endpoints remain reachable through the subnet's default route |
| Incident intake | Agent connector | Azure Monitor connector |
| Diagnostics | Agent connectors | Log Analytics and Application Insights connectors |
| AKS access | Role assignments | Reader/monitoring/log roles plus AKS Cluster Admin and AKS Contributor |

The VNet integration provides network placement and a path to private resources.
This change does not add Azure Firewall, NAT Gateway, private AKS conversion, or
private endpoints; those would materially increase cost and scope.

### Provisioning Limit Checklist

The Azure quota CLI was used first after registering `Microsoft.Quota`.

| Resource Type | Number to Deploy | Total After Deployment | Limit/Quota | Notes |
|---------------|------------------|------------------------|-------------|-------|
| Virtual networks | 1 | 2 subscription-wide | 1,000 | `az quota list`, Microsoft.Network, Sweden Central |
| Subnets in the new VNet | 1 | 1 in this VNet | 3,000 per VNet | `az quota list`, Microsoft.Network |
| SRE Agent | 0 net-new in the target environment; update existing | 1 in Sweden Central | No separate agent-count quota exposed; Microsoft.App reports 20,000 sandbox cores | Existing agent proves regional service availability |
| User-assigned identity | 0 net-new when updating existing names | 3 in Sweden Central | Platform service limit applies; current use is low | Existing `id-sre-agent-aks-demo` is reused |
| Log Analytics workspace | 0 net-new when updating existing names | 3 in Sweden Central | Platform service limit applies; current use is low | Existing workspace is reused |
| Application Insights component | 0 net-new when updating existing names | 1 in Sweden Central | Platform service limit applies; current use is low | Existing component is reused |

**Capacity status:** All planned resources are within available limits.

### Files to Add or Modify

| File | Purpose |
|------|---------|
| `infra/main.bicep` | Orchestrate agent networking and SRE Agent modules |
| `infra/main.bicepparam` | Demo environment names and settings |
| `infra/modules/network.bicep` | VNet and delegated `/27` agent subnet |
| `infra/modules/monitoring.bicep` | Log Analytics and Application Insights |
| `infra/modules/sre-agent.bicep` | Identity, agent, VNet configuration, connectors, and RBAC |
| `README.md` | Document Bicep deployment order, parameters, and VNet behavior |
| `.azure/deployment-plan.md` | Track preparation and validation |

### Validation

- Run `az bicep build` for `infra/main.bicep`.
- Run Bicep lint/build for every module.
- Run `az deployment group validate` against `rg-sre-aks` without deploying.
- Confirm the generated ARM template contains the delegated subnet,
  `vnetConfiguration.subnetResourceId`, and `AzureVNet` egress mode.
- Confirm no secrets or generated credentials are committed.
- Invoke the `azure-validate` skill after setting this plan to
  `Ready for Validation`.

#### All validation checks pass

- [x] Core validation: Azure CLI, authentication, Bicep build, ARM validation, and targeted what-if
- [x] Bicep linting
- [x] Azure Policy validation
- [x] Role assignment verification
- [x] Secret scan

### Current Validation Proof

| Check | Command | Result |
|-------|---------|--------|
| Bicep compilation | `az bicep build` for `infra/main.bicep` and every module; `az bicep build-params` | Pass |
| Bicep linting | `az bicep lint` for the main template and every module | Pass with no diagnostics |
| Top-level ARM validation | `az deployment group validate` with `infra/main.bicepparam` | Pass |
| Agent ARM validation | Direct `az deployment group validate` of `modules/sre-agent.bicep` using existing telemetry values | Pass |
| Network what-if | Direct module what-if with `ResourceIdOnly` | Pass; creates only `vnet-sre-agent-aks-demo` |
| Monitoring what-if | Direct module what-if with `ResourceIdOnly` | Pass; incrementally deploys the existing workspace and Application Insights component |
| Full deployment what-if | `az deployment group what-if` with existing-environment overrides | Pass; creates the VNet and three connectors, incrementally deploys existing agent dependencies, and deletes nothing |
| Azure Policy | Listed assignments effective at `rg-sre-aks`; direct network and monitoring what-if completed under those assignments | Pass; no deny surfaced for planned resource types |
| RBAC static review | Reviewed every `Microsoft.Authorization/roleAssignments` resource | Pass; monitoring roles are RG-scoped and AKS roles are cluster-scoped |
| Secret scan | Scanned `infra/` for credentials, passwords, connection-string values, and instrumentation keys | Pass; no secret values committed |
| Git whitespace | `git diff --check` with CRLF-aware configuration | Pass |

**Validation timestamp:** 2026-10-06

### Current Role Assignment Verification

- **Identity:** `id-sre-agent-aks-demo`
- **Resource-group roles:** Reader, Monitoring Reader, Monitoring Contributor,
  and Log Analytics Reader
- **AKS roles:** Azure Kubernetes Service Cluster Admin Role and Azure
  Kubernetes Service Contributor Role, scoped to `aks-sre-agent-demo`
- **System identity:** Reader, Monitoring Reader, and Log Analytics Reader for
  connector queries
- **Deployer:** SRE Agent Administrator scoped to the agent resource
- **Status:** Verified for the autonomous AKS demo scenario

### Branch and Pull Request

- Create a new branch from the current `fix/aks-policy-prerequisites` branch so
  the PR includes the three already-pushed deployment reliability fixes.
- Push the new branch to the `fork` remote (`msftph/azure-sre-agents-aks`).
- Open a PR targeting `msftph/azure-sre-agents-aks:main`.

### Risks and Mitigations

- `Microsoft.App/agents` uses a preview API: pin the API version used by the
  official Microsoft SRE Agent templates and validate against ARM.
- Existing manual role assignments can conflict with deterministic Bicep role
  assignments: expose a parameter to disable RBAC creation for preconfigured
  environments.
- VNet integration alone does not make AKS private: document that this change
  adds agent network placement, not private-cluster conversion.
- The current environment already has the agent resources: use stable names and
  incremental deployment semantics to update rather than duplicate them.

### Execution Checklist

- [x] Analyze workspace
- [x] Confirm subscription and location from the active demo environment
- [x] Research official SRE Agent Bicep and VNet integration patterns
- [x] Validate network and Microsoft.App quota capacity
- [x] Finalize implementation plan
- [x] User approves this change plan
- [x] Create feature branch
- [x] Generate Bicep modules and documentation
- [x] Set plan status to `Ready for Validation`
- [x] Invoke `azure-validate`
- [x] Commit with Copilot trailers
- [x] Push to the `fork` remote
- [x] Open PR against `msftph:main`

---

## Prior Deployment Plan and Validation History

---

## 1. Project Overview

**Goal:** Deploy the Azure SRE Agent autonomous AKS incident-response demo from `hailugebru/azure-sre-agents-aks`.

**Path:** Modify an existing project only where required for current Azure CLI and subscription compatibility.

**Workspace:** `C:\Users\pahuber\source\github.com\hailugebru\azure-sre-agents-aks`

---

## 2. Requirements

| Attribute | Value |
|-----------|-------|
| Classification | POC |
| Scale | Small |
| Budget | Cost-Optimized |
| Subscription | ME-MngEnvMCAP335410-pahuber-1 (`ab021129-9bf3-4ee3-bbc6-3da839fb88a1`) |
| Tenant | `5cd15b26-2657-4947-96ac-a22a1b5ce635` |
| Location | Sweden Central (`swedencentral`) |
| Resource group | `rg-sre-aks` |
| AKS cluster | `aks-sre-agent-demo` |

---

## 3. Components Detected

| Component | Type | Technology | Path |
|-----------|------|------------|------|
| AKS environment | Infrastructure | AKS Automatic/NAP, Azure CNI Overlay, Cilium | `02-create-cluster.ps1` |
| Demo application | Kubernetes workload | AKS Store Demo manifests | `manifests/aks-store/` |
| NAP scenario | Cluster configuration | System-pool taint and Karpenter | `04-setup-nap.ps1` |
| ARM node profile | Optional advanced scenario | Karpenter ARM64/Azure Linux | `05-*`, `06-*` |
| KEDA scenario | Optional advanced scenario | AKS KEDA add-on | `07-setup-keda-scaler.ps1` |
| Azure SRE Agent | External managed service | Configured through `https://sre.azure.com` after AKS deployment | README Step 8 |

---

## 4. Recipe Selection

**Selected:** AZCLI

**Rationale:** The upstream demo is intentionally implemented as ordered PowerShell/Azure CLI and Kubernetes scripts. Preserve that workflow rather than replacing the demo with unrelated infrastructure scaffolding.

---

## 5. Architecture

**Stack:** AKS POC cluster with a public demo workload and managed Prometheus.

### Service Mapping

| Component | Azure Service | Configuration |
|-----------|---------------|---------------|
| Kubernetes control plane | Azure Kubernetes Service | Free tier, Kubernetes `1.35.7` |
| System node pool | AKS VMSS | 1 x `Standard_D4s_v5` |
| Workload capacity | AKS Node Auto-Provisioning | Automatic, expected to add capacity for the demo workloads |
| Networking | Azure CNI Overlay + Cilium | Public API server; Standard Load Balancer |
| Metrics | Azure Monitor managed service for Prometheus | Enabled during cluster creation |
| Demo ingress | Kubernetes `LoadBalancer` service | Public Store Front endpoint |
| Incident response | Azure SRE Agent | Resource-group scope, review mode initially |

### Day-0 Decisions

- Use Azure CNI Overlay and Cilium as required by the demo.
- Use one explicit `Standard_D4s_v5` system node to avoid the subscription's previously restricted legacy defaults.
- Use the current default supported Kubernetes patch (`1.35.7`).
- Keep the API server public because this is a short-lived POC and the demo does not supply private networking.

### Scope

Deploy the core incident-response environment:

1. Prerequisites and provider checks.
2. AKS cluster with NAP and managed Prometheus.
3. AKS Store Demo application.
4. System-pool taint to exercise NAP.

Do not deploy optional ARM64, KEDA, or GitHub issue-automation scenarios in the initial pass. They are not required for the CPU/OOM incident-response demo and would add capacity and credentials requirements.

Initial Azure SRE Agent resource creation/configuration may require the interactive `sre.azure.com` portal. Automation will continue only if an accessible SRE Agent resource already exists.

---

## 6. Provisioning Limit Checklist

Quota CLI was attempted first for Microsoft.Compute and Microsoft.Network. It returned no quota rows for this subscription, so Azure CLI usage endpoints were used as the documented fallback.

| Resource Type | Number to Deploy | Total After Deployment | Limit/Quota | Notes |
|---------------|------------------|------------------------|-------------|-------|
| AKS managed clusters | 1 | 1 | 5,000 per subscription/region | Existing AKS clusters: 0; Sweden Central advertises supported AKS versions |
| Total regional vCPUs | Up to 20 planned | Up to 20 | 100 | Current usage 0; includes 4 vCPUs for system pool plus NAP headroom |
| Standard DSv5 Family vCPUs | 4 | 4 | 100 | Current usage 0; `Standard_D4s_v5` is listed in Sweden Central |
| Virtual machines / VMSS instances | Up to 5 planned | Up to 5 | 25,000 | Current usage 0 |
| Virtual networks | 1 | 1 | 1,000 | Current usage 0 |
| Standard public IPv4 addresses | Up to 2 | Up to 2 | 1,000 | Current usage 0 |
| Standard Load Balancers | 1 | 1 | 1,000 | Current usage 0 |
| Azure Monitor workspace and collection resources | 1 set | 1 set | Not quota-constrained for this POC | Microsoft.Monitor and Microsoft.Insights are registered |

**Status:** All planned resources are within available limits.

---

## 7. Execution Checklist

### Phase 1: Planning
- [x] Analyze workspace
- [x] Gather requirements
- [x] Confirm subscription and location with user
- [x] Prepare resource inventory
- [x] Fetch quotas and validate capacity
- [x] Scan codebase
- [x] Select recipe
- [x] Plan architecture
- [x] User approved this plan and its Azure cost impact

### Phase 2: Execution
- [x] Update `00-variables.ps1` with confirmed Azure context
- [x] Remove obsolete NAP preview feature registration
- [x] Pin the AKS version, node count, and node VM size
- [x] Verify scripts parse and required tools are installed
- [x] Update status to `Ready for Validation`

### Phase 3: Validation
- [x] Invoke azure-validate
- [x] All validation checks pass
  - [x] Core validation (Azure CLI, authentication, and script syntax)
  - [x] Docker build (not applicable; deployment uses published images)
  - [x] Azure Policy validation
  - [x] PowerShell parses all deployment scripts
  - [x] Azure CLI authentication resolves to the approved subscription and tenant
  - [x] Required CLIs are available (`az`, `kubectl`)
  - [x] Sweden Central supports Kubernetes `1.35.7`
  - [x] `Standard_D4s_v5` and required regional/network quota are available
  - [x] Target resource group does not already exist
  - [x] Assigned Azure policies reviewed for AKS, region, and SKU conflicts
  - [x] No deployment-time secrets are stored in modified files
- [x] Record validation proof

### Phase 4: Deployment
- [ ] Invoke azure-deploy
- [ ] Create `rg-sre-aks`
- [ ] Deploy and verify AKS
- [ ] Deploy and verify the AKS Store Demo
- [ ] Apply and verify the NAP scenario
- [ ] Report the Store Front URL and Azure resource links

---

## 8. Validation Proof

| Check | Command Run | Result | Timestamp |
|-------|-------------|--------|-----------|
| PowerShell syntax | PowerShell parser over repository `*.ps1` files | Pass | 2026-09-22T19:26:00-04:00 |
| Required tools | `Get-Command az,kubectl,pwsh` | Pass | 2026-09-22T19:26:00-04:00 |
| Azure context | `az account show` | Pass: approved subscription and tenant | 2026-09-22T19:26:00-04:00 |
| AKS regional version | `az aks get-versions --location swedencentral` | Pass: `1.35.7` available | 2026-09-22T19:26:00-04:00 |
| System node SKU | `az vm list-sizes --location swedencentral` | Pass: `Standard_D4s_v5` available | 2026-09-22T19:26:00-04:00 |
| Compute quota | `az vm list-usage --location swedencentral` | Pass: 100 regional and DSv5 vCPUs, 0 used | 2026-09-22T19:26:00-04:00 |
| Network quota | `az network list-usages --location swedencentral` | Pass: VNet, Standard public IP, and Standard LB capacity available | 2026-09-22T19:26:00-04:00 |
| Resource-group collision | `az group exists --name rg-sre-aks` | Pass: absent | 2026-09-22T19:26:00-04:00 |
| Policy review | Azure Policy assignments plus `az policy definition show` | Pass: classic-resource deny policy does not cover AKS resources | 2026-09-22T19:26:00-04:00 |
| Secret scan | Pattern scan across non-git repository files | Pass: no deployment secrets in modified files | 2026-09-22T19:26:00-04:00 |
| Kubernetes manifests | Python/PyYAML parse of all manifest files | Pass: 30 YAML documents parsed | 2026-09-22T19:28:00-04:00 |
| Static RBAC review | Review of scripts and README role guidance | Pass for automated scope; SRE Agent UAMI roles deferred | 2026-09-22T19:29:00-04:00 |
| Redeployment script syntax | PowerShell parser over repository `*.ps1` files | Pass | 2026-09-28T09:44:47-04:00 |
| Redeployment Azure context | `az account show` | Pass: approved subscription and tenant | 2026-09-28T09:44:47-04:00 |
| Redeployment AKS version/SKU | `az aks get-versions`; `az vm list-sizes` | Pass: `1.35.7` and `Standard_D4s_v5` available | 2026-09-28T09:44:47-04:00 |
| Public-IP policy prerequisite | `01-prerequisites.ps1`; `az feature show` | Pass: `Microsoft.Network/AllowBringYourOwnPublicIpAddress` registered | 2026-09-28T09:47:00-04:00 |
| Resource providers | `az provider show` | Pass: Microsoft.Network and Microsoft.ContainerService registered | 2026-09-28T09:47:00-04:00 |
| Redeployment manifests | Python/PyYAML parse of all manifest files | Pass: 30 YAML documents parsed | 2026-09-28T09:44:47-04:00 |
| Redeployment static RBAC | Search deployment scripts and manifests for role assignments | Pass: no automated role assignments in deployment scope | 2026-09-28T09:44:47-04:00 |

**Validated by:** azure-validate skill

**Validation timestamp:** 2026-09-22T19:29:00-04:00

---

## 9. Role Assignment Verification

- **Status:** Verified for the automated deployment scope.
- **AKS identity:** Created and managed by AKS; the scripts do not add custom role assignments.
- **Azure SRE Agent identity:** README instructions require the agent UAMI to receive AKS Cluster Admin and AKS Contributor roles scoped to `rg-sre-aks`. These assignments are deferred until an SRE Agent resource exists.
- **Issues:** No static Bicep/Terraform role assignments exist to validate.

---

## 10. Files to Generate or Modify

| File | Purpose | Status |
|------|---------|--------|
| `.azure/deployment-plan.md` | Deployment source of truth | Complete |
| `00-variables.ps1` | Confirmed subscription, region, resource group, and cluster | Pending approval |
| `01-prerequisites.ps1` | Replace removed preview registration with current prerequisite checks | Pending approval |
| `02-create-cluster.ps1` | Pin cost-conscious node count, supported SKU, and Kubernetes version | Pending approval |

---

## 11. Next Steps

> Current: Awaiting plan approval

1. Approve the plan and Azure provisioning cost.
2. Prepare and validate the scripts.
3. Deploy and verify the core AKS/SRE Agent demo environment.
