# Cilium Network Policy Misconfiguration Scenario

This standalone lab reproduces three Kubernetes connectivity failures caused by incorrect assumptions about `CiliumNetworkPolicy` behavior. It contains only Kubernetes, Cilium, and Azure-native observability components.

Azure-native observability is used instead:

- **AKS Advanced Container Networking Services (ACNS)** supplies Cilium/Hubble network telemetry.
- **Azure Monitor managed Prometheus** stores Cilium and Hubble metrics.
- **Azure Managed Grafana** provides the AKS networking dashboards when connected.
- **Container Insights** can persist ACNS flow logs in the `ContainerNetworkLogs` Log Analytics table.
- `kubectl`, Cilium policy status, Cilium agent logs, and Hubble provide immediate cluster-side diagnostics.

## Scope

| Case | Fault | Expected symptom | Correction |
|---|---|---|---|
| Cross-namespace ingress | `fromEndpoints` matches an app label but omits `k8s:io.kubernetes.pod.namespace` | A same-namespace client connects, but an identically labeled client in another namespace is denied | Add the source namespace label |
| CIDR-based ingress | `fromCIDR: 0.0.0.0/0` is expected to include pod traffic | A Cilium-managed client pod is denied because managed endpoints are selected by identity, not CIDR | Use `fromEntities: cluster` for local cluster endpoints and reserve CIDRs for external sources |
| Service and port egress | `toServices` and `toPorts` are combined in one rule | Cilium rejects the policy or it fails to provide the intended service-only restriction; an unrelated service remains reachable | Replace `toServices` with `toEndpoints` and retain `toPorts` |

The source article's Cluster Mesh identity case is not automated here because this repository provisions one AKS cluster. Reproducing it correctly requires two clusters and managed cross-cluster networking or Cilium Cluster Mesh.

## Prerequisites

- An AKS cluster using Azure CNI powered by Cilium
- `kubectl` access to the cluster
- Cilium `CiliumNetworkPolicy` CRDs installed by AKS
- PowerShell 7+
- Kubernetes 1.33+ for optional ACNS container network logs

The repository's `Deploy-Demo.ps1` deploys Cilium, ACNS, and Azure Monitor
managed Prometheus through Bicep. Create the demo cluster using the root
[setup instructions](../../README.md#step-2--deploy-the-complete-azure-infrastructure), then open its
private API tunnel before running this scenario:

```powershell
..\..\Connect-AksViaBastion.ps1
```

For an unrelated existing cluster, configure ACNS and monitoring in that
cluster's owning infrastructure template; do not apply this repository's
complete private-cluster template to it as an add-on-only update.

## Run the scenario

Run these commands from this directory:

```powershell
.\setup.ps1
.\inject.ps1
.\test.ps1 -ExpectedState Broken
.\fix.ps1
.\test.ps1 -ExpectedState Fixed
```

Remove the lab resources when finished:

```powershell
.\cleanup.ps1
```

`inject.ps1` treats API or Cilium rejection of the unsupported service/port policy as an expected failure mode and continues with the other cases.

## Immediate diagnostics

Inspect policy status and recent Cilium agent messages:

```powershell
kubectl get ciliumnetworkpolicy -n cilium-policy-demo
kubectl describe ciliumnetworkpolicy -n cilium-policy-demo
kubectl logs -n kube-system -l k8s-app=cilium --since=10m --prefix |
  Select-String "policy|denied|drop|ToServices|ToPorts"
```

If the Cilium CLI is available:

```powershell
cilium status
cilium connectivity test
```

If Hubble is enabled for the cluster:

```powershell
hubble observe --namespace cilium-policy-demo --verdict DROPPED --follow
hubble observe --namespace cilium-policy-observer --verdict DROPPED --follow
```

## Azure Monitor diagnostics

ACNS exposes the packet drop counter used by Azure Monitor managed Prometheus:

```promql
sum by (reason, direction) (
  rate(cilium_drop_count_total[5m])
)
```

For workload-level analysis, query the Azure Monitor workspace output by the
private-cluster deployment. If you separately configure Azure Managed Grafana,
its **Azure Managed Prometheus > Kubernetes >
Networking** dashboards can also show **Drops (Workload)** and **Pod Flows
(Namespace)**. Step 2 deploys Azure Monitor's recommended recording-rule groups;
Grafana itself is not deployed by this repository.

The included `manifests/observability.yaml` creates a `ContainerNetworkLog` filter
when the ACNS logging CRD is available. To persist those flows in Azure Monitor,
run Step 2 from the repository root with the network-log option before connecting:

```powershell
.\Deploy-Demo.ps1 -EnableContainerNetworkLogs
```

This sets Bicep's `enableContainerNetworkLogs=true`, configures the monitoring
add-on, and deploys the high-scale collection endpoint/rule, including the
`Microsoft-ContainerNetworkLogs` stream. On repeat deployments use the same
option and SSH key; review a what-if first as described in the root README.

Then query denied flows in the cluster's Log Analytics workspace:

```kusto
ContainerNetworkLogs
| where TimeGenerated > ago(30m)
| where Verdict == "DROPPED"
| where SourceNamespace in ("cilium-policy-demo", "cilium-policy-observer")
    or DestinationNamespace == "cilium-policy-demo"
| project TimeGenerated, TrafficDirection, SourceNamespace, SourcePodName,
    DestinationNamespace, DestinationPodName, Verdict
| order by TimeGenerated desc
```

Column names can vary as the ACNS flow-log schema evolves. Use `ContainerNetworkLogs | getschema` in Log Analytics if a projected field is unavailable.

## Manifest layout

```text
manifests/
├── 00-base.yaml
├── bad/
│   ├── 01-cross-namespace.yaml
│   ├── 02-cidr.yaml
│   └── 03-service-port.yaml
├── good/
│   ├── 01-cross-namespace.yaml
│   ├── 02-cidr.yaml
│   └── 03-service-port.yaml
└── observability.yaml
```
