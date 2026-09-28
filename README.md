# AKS NAP (Node Auto-Provisioning) Demo — PowerShell Scripts

This folder contains PowerShell scripts to deploy an AKS cluster with **Node Auto-Provisioning (NAP/Karpenter)**, run the [AKS Store Demo](https://github.com/Azure-Samples/aks-store-demo) application, and reproduce the two incident flows used in the blog post: **CPU starvation** and **OOMKilled** troubleshooting with Azure SRE Agent.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- An Azure subscription with permissions to create AKS clusters
- Permission to register subscription features, or a policy exemption if your
  organization appends `FirstPartyUsage` tags to public IP addresses
- PowerShell 7+ (recommended)

## Before You Start

1. Open `00-variables.ps1` and update the `$SUBSCRIPTION_ID` variable with your Azure subscription ID.
2. Make sure you are logged in to Azure:
   ```powershell
   az login
   ```

## Minimal Setup

If you are coming from the blog post and want the shortest path into the demo, start here.

> **Demo repository:** [github.com/hailugebru/azure-sre-agents-aks](https://github.com/hailugebru/azure-sre-agents-aks)

**Prerequisites**
- Azure subscription with AKS deployment permissions
- Azure CLI with `aks-preview`
- Access to Azure SRE Agent

```powershell
git clone https://github.com/hailugebru/azure-sre-agents-aks
cd azure-sre-agents-aks
notepad 00-variables.ps1
```

That is enough to get the environment variables in place and continue with the full setup steps below.

## Step-by-Step Instructions

Run each script **in order** from this folder. Each step depends on the previous one.

---

### Step 0 — Load Variables

```powershell
. .\00-variables.ps1
```

Loads shared environment variables (`$SUBSCRIPTION_ID`, `$RESOURCE_GROUP`, `$LOCATION`, `$CLUSTER_NAME`) into your session. **Dot-source this first** — other scripts do it automatically.

---

### Step 1 — Prerequisites

```powershell
.\01-prerequisites.ps1
```

- Sets the active Azure subscription
- Registers `Microsoft.Network/AllowBringYourOwnPublicIpAddress` when required
  by enterprise public-IP tagging policies
- Refreshes the `Microsoft.Network` and `Microsoft.ContainerService` providers
- Uses the installed `aks-preview` CLI extension, or installs it when missing

> **Note:** Network feature registration can take several minutes. If it does
> not complete within 30 minutes, request tenant approval for the feature or an
> exemption from the policy that appends `FirstPartyUsage` tags to public IPs.
> The script stops before AKS provisioning rather than leaving a partial
> cluster behind.

---

### Step 2 — Create AKS Cluster

```powershell
.\02-create-cluster.ps1
```

- Creates the resource group
- Creates an AKS cluster with:
  - **NAP enabled** (`--node-provisioning-mode Auto`)
  - Azure CNI Overlay networking
  - Cilium dataplane
  - **Managed Prometheus** (`--enable-azure-monitor-metrics`)
- Downloads cluster credentials to your kubeconfig

> **Note:** Cluster creation takes ~5-10 minutes.
> Azure CLI failures terminate the script, so it will not print a successful
> deployment message after a failed or partial cluster creation.

---

### Step 3 — Deploy the AKS Store Demo App

```powershell
.\03-deploy-app.ps1
```

- Creates the `pets` namespace
- Deploys the local manifests in `./manifests/aks-store` (MongoDB, RabbitMQ, order-service, product-service, makeline-service, store-front, store-admin, virtual-customer, virtual-worker)
- Waits for all pods to be Ready
- Prints the Store Front URL

---

### Step 4 — Enable NAP (Taint System Pool)

```powershell
.\04-setup-nap.ps1
```

- Discovers the default system nodepool
- Applies `CriticalAddonsOnly=true:NoExecute` taint to the system pool
- This evicts app pods → NAP/Karpenter provisions new user nodes automatically

**Monitor NAP activity:**
```powershell
kubectl get events -A --field-selector source=karpenter -w
kubectl get nodes,pods -n pets -o wide -w
```

**Inspect NAP nodepools:**
```powershell
kubectl get nodepool
kubectl describe nodepool default
```

---

### Step 5 — ARM64 NodePool Profile

```powershell
.\05-arm-nodepool.ps1
```

- Applies a Karpenter `NodePool` that prioritises **ARM64 D-family** VMs
- NAP will prefer ARM nodes for new workloads (cost-efficient)

---

### Step 6 — ARM64 NodePool v2 (Azure Linux)

```powershell
.\06-arm-nodepool-v2.ps1
```

- Applies an `AKSNodeClass` for **Azure Linux** (CBL-Mariner)
- Updates the ARM NodePool to use the Azure Linux node class

> **Advanced: ARM64 Node Pools**  
> Steps 5 and 6 bias NAP toward ARM64 Azure Linux nodes for cost-efficient scale-out. NAP and Azure SRE Agent are complementary but separate — NAP manages infrastructure capacity, the agent investigates and remediates incidents. To apply:
> ```powershell
> .\05-arm-nodepool.ps1    # apply ARM64 NodePool preference
> .\06-arm-nodepool-v2.ps1 # add Azure Linux AKSNodeClass
> kubectl get nodepool
> kubectl describe nodepool default
> ```

---

### Step 7 — Setup KEDA Scaler
               Teams notification + GitHub issue → GitHub Copilot agent → PR for review
```powershell
.\07-setup-keda-scaler.ps1
```

- Deploys a Secret, TriggerAuthentication, and ScaledObject for `virtual-worker`
- KEDA scales virtual-worker replicas based on RabbitMQ queue length

**Test scaling:**
```powershell
kubectl scale deployment virtual-customer -n pets --replicas=4
kubectl get deploy -n pets -w
kubectl exec rabbitmq-0 -n pets -- rabbitmqctl list_queues
```

---

### Step 8 — Configure Azure SRE Agent (Portal)

This step is performed in the Azure portal at **[sre.azure.com](https://sre.azure.com)**.

Azure SRE Agent configuration for this demo came down to four things: **scope**, **permissions**, **incident intake**, and **response mode**.

**A — Create the agent and scope it correctly**

1. Create an Azure SRE Agent resource and scope it to the demo resource group.
2. During deployment, Azure SRE Agent creates two managed identities:
    - a **user-assigned managed identity (UAMI)** used for RBAC and connector access
    - a system-assigned identity used internally by the service
3. Use the **UAMI** for the role assignments and connector setup below.
4. Add the demo resource group as a **managed resource** so the agent can investigate resources within that scope.

**B — Grant scenario-specific AKS access**

Core monitoring roles are assigned during setup. For this demo, I added AKS-specific rights so the agent could complete remediation end to end. Treat these as **scenario-specific**, not a default production baseline.

```bash
az role assignment create \
   --assignee "<uami-client-id>" \
   --role "Azure Kubernetes Service Cluster Admin Role" \
   --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"

az role assignment create \
   --assignee "<uami-client-id>" \
   --role "Azure Kubernetes Service Contributor Role" \
   --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"
```

**C — Connect Azure Monitor as the incident platform**

1. In Azure SRE Agent, configure **Azure Monitor** as the incident platform.
2. Copy the generated webhook URL.
3. Route the AKS alert to that webhook through an Azure Monitor **Action Group**.

This distinction matters: Azure Monitor handles how incidents **enter** the workflow, while connectors such as GitHub and Teams extend the workflow **outward** for tracking and communication.

**D — Choose permission level and run mode deliberately**

Use the safest rollout path:

```text
Start:   Reader + Review
Then:    Privileged + Review
Finally: Privileged + Autonomous for narrow, trusted incident paths
```

For this demo, I used broader permissions and `Autonomous` mode on a dedicated lab resource group so the workflow could run end to end without manual approval gates.

**E — Add custom instructions for AKS pod-health incidents**

These instructions shape the workflow, but they do not replace RBAC, telemetry quality, or tool availability:

```text
For AKS pod health alerts in the pets namespace:
1. Scan all namespaces for unhealthy pods first.
2. Prioritise OOMKilled and CrashLoopBackOff.
3. For OOMKilled: correlate NODE_OPTIONS / JVM flags against container memory limits before adjusting.
4. After any patch, wait for rollout, then verify cluster-wide pod health.
5. After successful resolution, create a GitHub issue with the incident ID, root cause, patch applied, and a recommendation to update the source manifest in Git.
```

---

### Step 9 — Configure GitHub Post-Incident Issue Automation (Portal)

This step is performed in the Azure portal at **[sre.azure.com](https://sre.azure.com)**.  
Run the helper script first to print the configuration checklist:

```powershell
.\08-setup-github-issues.ps1
```

**A — Add the GitHub MCP connector**

1. Go to **Builder > Connectors > + Add connector**
2. Select the **MCP** tab → **GitHub MCP server**
3. The portal pre-fills `https://api.githubcopilot.com/mcp/` and locks **Authentication method** to **Bearer token** — this is expected. MCP connectors use PAT/Bearer token, not OAuth.
   Generate a PAT at `github.com/settings/tokens` and paste it into the **PAT or API key** field.

   | PAT type | Required scope |
   |---|---|
   | Classic | `repo` |
   | Fine-grained *(recommended)* | `Issues: Read and write` scoped to `hailugebru/azure-sre-agents-aks` |

   > **Note:** The GitHub OAuth connector (Code Repository tab) is read-only. It cannot create issues — use the MCP connector here.

4. Select **Edit** on the new connector → **MCP Tools** → enable `create_issue` (and optionally `list_issues`)
5. Select **Save**

**B — Create the `github-issue-tracker` subagent**

1. Go to **Builder > Subagent builder > + Create subagent**
2. Name: `github-issue-tracker` | Autonomy: **Autonomous**
3. Add tool: `create_issue` from the `github-mcp` connection
4. Select **Save**

**C — Update the Incident Response Plan custom instructions**

Replace instruction 5 with:

```
5. After successful resolution, invoke the github-issue-tracker subagent to create
   a GitHub issue in hailugebru/azure-sre-agents-aks with the incident ID, root
   cause, patch applied, and a recommendation to update the source manifest in Git.
```

> **Verify:** After running the OOMKilled demo (Step 13), check  
> `https://github.com/hailugebru/azure-sre-agents-aks/issues` for the auto-created issue.

> **Optional handoff:** The generated GitHub issue can be assigned to a GitHub agent, which can use the issue body, comments, and an additional prompt to begin the engineering follow-up work.

**D — Optional: Continue from issue to pull request**

If you assign the generated GitHub issue to a GitHub agent, the workflow can continue beyond issue creation:

1. The GitHub agent reads the **issue description**, any **comments**, and any **additional prompt** you provide.
2. It analyzes the repository against the incident context and proposed remediation.
3. It can then open a **draft pull request** for your review so the source manifests reflect the approved hotfix.

In this demo, that handoff produced a draft PR to align the `order-service` manifests with the memory remediation identified during the incident, so the repo would not drift from the in-cluster fix.

That is the end-to-end loop this setup enables: Azure SRE Agent handles live-site detection and mitigation, GitHub captures the engineering artifact, and the GitHub agent can carry the work forward into a reviewable code change.

---

### Step 10 — Configure Teams Notifications (Portal)

Use the Teams connector when you want real-time visibility during an autonomous run.

1. Go to **Builder > Connectors > + Add connector**.
2. Select **Microsoft Teams** and complete the sign-in flow.
3. Choose the target team and channel for incident updates.
4. Enable the connector for the Azure SRE Agent workflow.

In this demo, Teams carried three milestone updates during the incident:

1. investigation started
2. root cause and remediation identified
3. incident resolved

Teams provided real-time coordination for the on-call team, while GitHub captured the durable engineering follow-up.

---

### Step 11 — Create the Azure Monitor Alert Rules Used in the Blog

The blog demonstrates two detection paths:

1. an **alert-driven** Azure Monitor incident for CPU starvation
2. a **chat-driven** investigation for OOMKilled, with optional Prometheus coverage for CrashLoopBackOff

Create both so your environment matches the blog flow.

**A — Alert rule for unhealthy pods (`pod-not-healthy`)**

Create a Prometheus rule or Azure Monitor managed Prometheus alert that targets the `pets` namespace and routes to the **Action Group** you connected to Azure SRE Agent in Step 8.

Use a rule that detects pods that are not healthy long enough for the agent to investigate, for example:

```promql
sum by (namespace, pod) (
   kube_pod_status_phase{namespace="pets", phase=~"Pending|Failed|Unknown"}
) > 0
```

Recommended settings for the demo:

- Severity: `Sev1`
- Evaluation frequency: `1 minute`
- Lookback window: `5 minutes`
- Action: the Azure Monitor **Action Group** webhook generated by Azure SRE Agent
- Alert name: `pod-not-healthy`

This is the alert path used in the blog's CPU-starvation incident.

**B — Optional CrashLoopBackOff coverage for the chat-driven scenario**

The blog starts Incident 2 from chat before a pod-phase alert fires. To add production-grade coverage for that class of failure, create a second Prometheus rule using the same Action Group:

```promql
sum by (namespace, pod) (
   (
      max_over_time(
         kube_pod_container_status_waiting_reason{
            namespace="pets",
            reason="CrashLoopBackOff"
         }[5m]
      ) == 1
   )
   and on (namespace, pod, container)
   (
      increase(
         kube_pod_container_status_restarts_total{
            namespace="pets"
         }[15m]
      ) > 0
   )
) > 0
```

This query fires when a container has been in `CrashLoopBackOff` within the last 5 minutes **and** its restart count increased during the last 15 minutes.

**C — Validate the incident path before injecting failures**

Before proceeding, confirm that:

- the alert rule targets the `pets` namespace
- the alert action is the Action Group wired to Azure SRE Agent
- Azure SRE Agent is in the intended mode for the demo (`Review` or `Autonomous`)
- the cluster is healthy before fault injection

Use these checks:

```powershell
kubectl get pods -n pets
kubectl top pods -n pets
```

---

### Step 12 — Reproduce Incident 1: CPU Starvation (Alert-Driven)

This reproduces the first blog scenario, where Azure Monitor raises a Sev1 incident and Azure SRE Agent investigates and remediates it.

**A — Inject the bad CPU and memory limits**

```powershell
kubectl patch deployment makeline-service -n pets --type='json' -p='[
   {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"1m"},
   {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"6Mi"},
   {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"5m"},
   {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"20Mi"}
]'
```

**B — Watch the failure develop**

```powershell
kubectl get pods -n pets -w
kubectl describe pod -n pets -l app=makeline-service
kubectl top pods -n pets
```

Expected behavior:

- `makeline-service` fails startup
- the `pod-not-healthy` alert fires in Azure Monitor
- the Action Group sends the incident to Azure SRE Agent

**C — Validate the blog outcome**

After the agent runs, verify:

```powershell
kubectl get pods -n pets
kubectl top pods -n pets
```

Expected outcome:

- Azure SRE Agent identifies startup failure rather than OOMKill
- the affected deployments recover to healthy state
- Teams receives milestone updates if Step 10 is configured
- GitHub issue creation occurs if Step 9 is configured

---

### Step 13 — Reproduce Incident 2: OOMKilled (Chat-Driven)

This reproduces the second blog scenario, where you ask Azure SRE Agent to investigate a workload before the pod-phase alert path catches it.

**A — Deploy the undersized `order-service` manifest**

```powershell
kubectl apply -f .\manifests\aks-store\order-service-changed.yaml -n pets
kubectl get pods -n pets -w
```

**B — Start the chat-driven investigation**

Use this prompt with Azure SRE Agent:

```text
The order-service pod in the pets namespace is not healthy.
Please investigate, identify the root cause, and fix it.
```

**C — Validate the blog outcome**

After the agent runs, verify:

```powershell
kubectl get pods -n pets
kubectl describe pod -n pets -l app=order-service
kubectl top pods -n pets
```

Expected outcome:

- the agent diagnoses `OOMKilled` from exit code `137`
- the memory request and limit are increased
- the new pod stabilizes without restart churn
- GitHub issue creation occurs if Step 9 is configured

If you also created the CrashLoopBackOff alert in Step 11, this gives you both the blog's chat-driven path and a production-style alert path for the same class of failure.

---

### Step 14 — Verify the Full Blog Workflow End to End

Once both incidents have been exercised, verify the full operational loop described in the blog.

**A — In Azure Monitor / Azure SRE Agent**

- confirm the incident appears in Azure Monitor
- confirm Azure SRE Agent shows the investigation and remediation history
- confirm the incident reaches `Resolved`

**B — In AKS**

```powershell
kubectl get pods -n pets
kubectl get events -n pets --sort-by=.lastTimestamp
```

Confirm the workloads are healthy and no failing pods remain in the `pets` namespace.

**C — In Teams**

Confirm the channel shows:

1. investigation started
2. root cause and remediation identified
3. incident resolved

**D — In GitHub**

Confirm a post-incident issue exists at:

`https://github.com/hailugebru/azure-sre-agents-aks/issues`

If you assign that issue to GitHub Copilot agent, the workflow can continue into a draft pull request so the repo reflects the approved hotfix.

---

## Try It Yourself

If you are coming from the blog post, this README is the full setup appendix.

1. Run Steps 0 through 7 to build the AKS environment.
2. Complete Steps 8 through 10 to wire Azure SRE Agent, GitHub, and Teams.
3. Complete Step 11 so Azure Monitor can actually trigger the alert-driven incident path from the blog.
4. Run Step 12 for the CPU-starvation incident and Step 13 for the OOMKilled incident.
5. Use Step 14 to verify the full Azure Monitor → Azure SRE Agent → Teams/GitHub loop.
6. Start with `Reader + Review` on a non-production resource group.
7. Expand to `Privileged + Autonomous` only after validating the agent's reasoning and remediation quality in your environment.

## Full Setup Details

This README contains the complete AKS deployment steps, connector configuration, and post-incident artifact setup used in the blog demo:

- AKS cluster + NAP setup
- KEDA scaler setup
- Azure SRE Agent role assignments
- Azure Monitor alert rules and Action Group routing
- CPU-starvation and OOMKilled reproduction steps
- End-to-end verification workflow
- GitHub connector and issue automation
- Teams connector configuration

### Resources

| Resource | Link |
|---|---|
| Demo repository | [github.com/hailugebru/azure-sre-agents-aks](https://github.com/hailugebru/azure-sre-agents-aks) |
| Azure SRE Agent docs | [learn.microsoft.com/azure/sre-agent](https://learn.microsoft.com/azure/sre-agent/) |
| AKS Store Demo | [github.com/Azure-Samples/aks-store-demo](https://github.com/Azure-Samples/aks-store-demo) |
| Node Auto-Provisioning | [learn.microsoft.com/azure/aks/node-autoprovision](https://learn.microsoft.com/azure/aks/node-autoprovision) |
| KEDA on AKS | [learn.microsoft.com/azure/aks/keda-about](https://learn.microsoft.com/azure/aks/keda-about) |

---

## Cleanup

To delete all Azure resources when done:

```powershell
. .\00-variables.ps1
az group delete -n $RESOURCE_GROUP --yes --no-wait
```

## Folder Structure

```
nap/
├── pwsh/               ← You are here (PowerShell scripts)
│   ├── 00-variables.ps1
│   ├── 01-prerequisites.ps1
│   ├── 02-create-cluster.ps1
│   ├── 03-deploy-app.ps1
│   ├── 04-setup-nap.ps1
│   ├── 05-arm-nodepool.ps1
│   ├── 06-arm-nodepool-v2.ps1
│   ├── 07-setup-keda-scaler.ps1
│   ├── 08-setup-github-issues.ps1
│   ├── README.md
│   └── manifests/
│       ├── aks-store/
│       │   ├── 00-mongodb.yaml
│       │   ├── 01-rabbitmq.yaml
│       │   ├── 02-order-service.yaml
│       │   ├── 03-makeline-service.yaml
│       │   ├── 04-product-service.yaml
│       │   ├── 05-store-front.yaml
│       │   ├── 06-store-admin.yaml
│       │   ├── 07-virtual-customer.yaml
│       │   └── 08-virtual-worker.yaml
│       ├── arm-nodepool-profile.yaml
│       ├── arm-nodepool-profile-v2.yaml
│       └── virtual-worker-scaler.yaml
├── cli/
├── README.md
└── workshop/
```
