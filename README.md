# Private AKS and Azure SRE Agent demo

This repository deploys a private Azure Kubernetes Service (AKS) cluster with
Node Auto-Provisioning (NAP/Karpenter), Azure Monitor, Azure Bastion, and Azure
SRE Agent. It includes optional AKS Store workloads and a standalone Cilium
network-policy scenario.

## Requirements

- Azure CLI and Bicep support (`az bicep install` if needed)
- PowerShell 7+ (for `scripts/deploy.ps1`)
- `jq` (for `scripts/deploy.sh`)
- OpenSSH `ssh-keygen` (only needed when no SSH key exists)
- `kubectl` (for optional Kubernetes configuration)
- Bash (only for `scripts/deploy.sh`)
- An Azure subscription with permission to create the resources, role
  assignments, and subscription-scope deployments

Azure CLI 2.85.0 or later is required for the Bastion AKS tunnel. The deployment
script installs or updates the `aks-preview` extension as needed.

## Deploy the Azure infrastructure

Log in to Azure, then run either entry point from the repository root:

```bash
az login
./scripts/deploy.sh
```

Or use PowerShell:

```powershell
az login
.\scripts\deploy.ps1
```

The Bash entry point performs the same deployment operations natively. To
choose a subscription and enable ACNS network-log forwarding:

```bash
./scripts/deploy.sh --subscription-id "<subscription-id>" --enable-container-network-logs
```

Use `--skip-role-assignments` if equivalent SRE Agent role assignments already
exist. The deployment uses `~/.ssh/id_rsa.pub`, generating an RSA key pair if
needed; use `--ssh-public-key-path` to select a different public key. Only the
public key is passed to Bicep.

`infra/bicep/main.bicep` is the sole subscription-scope entry point, with
defaults in `infra/bicep/main.bicepparam`. It deploys the resource group,
networking and Bastion, private AKS, monitoring, the AKS-managed private DNS
link, and Azure SRE Agent. AKS is configured with NAP, API Server VNet
Integration, Azure CNI Overlay, Cilium, ACNS, KEDA, and a tainted system pool.
The deployment verifies the Bicep-managed KEDA and system-pool settings.

The launcher registers required Azure providers and the public-IP feature,
then submits the single Bicep deployment. It also reads Azure Monitor's
recording-rule recommendations after deployment and deploys the recommended
recording rules through Bicep.

This configuration targets a new or matching demo environment; it does not
convert an existing public cluster. Review a `what-if` before redeploying to
an existing environment. Keep the same SSH key and network-log setting across
repeat deployments. Bastion, telemetry, and ACNS may incur Azure charges.

## Optional AKS workloads

Connect to the private cluster:

```powershell
.\scripts\Connect-AksViaBastion.ps1
```

The helper opens a Bastion-backed shell with a usable `kubectl` context. From
the repository root in that shell, run `deploy.sh` in Kubernetes-only mode to
verify cluster settings and select optional workload configuration:

```bash
./scripts/deploy.sh --kubernetes-only --deploy-store-demo --configure-keda-scaler
```

These options are independent:

- `--deploy-store-demo` applies the healthy AKS Store manifests and waits for the
  workloads and internal service addresses.
- `--configure-keda-scaler` applies the virtual-worker RabbitMQ scaler after
  verifying KEDA's CRDs are available.
- `--arm-nodepool-profile Arm64` applies the ARM64 D-family NodePool profile.
- `--arm-nodepool-profile Arm64AzureLinux` applies the Azure Linux AKSNodeClass
  and ARM64 NodePool profile.

For example, configure the Store app, scaler, and Azure Linux profile in one
invocation:

```bash
./scripts/deploy.sh --kubernetes-only --deploy-store-demo --configure-keda-scaler --arm-nodepool-profile Arm64AzureLinux
```

Kubernetes-only mode requires an active Azure login and a working `kubectl`
context for the private cluster. It does not redeploy Azure infrastructure.
The ARM NodePool profiles are optional alternatives; choose one or leave the
default `None`.

To access the Store Front from the Bastion-connected shell:

```powershell
kubectl port-forward --namespace pets service/store-front 8080:80
```

Then open `http://localhost:8080` on the workstation.

## Azure SRE Agent and incident scenarios

The Bicep deployment creates the SRE Agent, identities, connectors, and demo
RBAC. Verify its scope and permissions in the Azure SRE Agent portal. Optional
GitHub and Teams connectors, alert rules, and CPU-starvation/OOMKilled incident
exercises are configured separately in Azure and are not required to deploy the
infrastructure.

For GitHub issue automation, add the GitHub MCP connector in the SRE Agent
portal, enable `create_issue`, then create a subagent that uses this tool and
configure the incident response plan to invoke it. Use a fine-grained token
with Issues read/write access to this repository (or a classic token with
`repo` scope). Teams notifications and alert rules are also configured in the
portal.

The standalone [Cilium network-policy scenario](./scenarios/cilium-network-policy/README.md)
documents its own manifests and workflow. It uses the deployed private AKS
cluster and can optionally send ACNS flow logs to Container Insights.

## Validation

From the repository root:

```powershell
$env:AKS_SSH_PUBLIC_KEY = (Get-Content -Raw "$HOME/.ssh/id_rsa.pub").Trim()
Get-ChildItem .\infra\bicep -Recurse -Filter *.bicep | ForEach-Object {
    bicep build $_.FullName --stdout | Out-Null
    bicep lint $_.FullName
}
bicep build-params .\infra\bicep\main.bicepparam --stdout | Out-Null
```

With Azure login and registered providers, use `az deployment sub validate`
and `az deployment sub what-if` with `infra/bicep/main.bicep` and
`infra/bicep/main.bicepparam` before deployment. Azure validation is needed to
verify regional availability, quotas, policy, and telemetry delivery.

## Cleanup

To delete the demo resource group:

```powershell
. .\scripts\variables.ps1
az group delete --name $RESOURCE_GROUP --yes --no-wait
```
