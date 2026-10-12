#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [options]

Infrastructure options:
  --subscription-id ID
  --resource-group-name NAME
  --location LOCATION
  --aks-cluster-name NAME
  --ssh-public-key-path PATH
  --enable-container-network-logs
  --skip-role-assignments

Kubernetes-only options:
  --kubernetes-only
  --deploy-store-demo
  --configure-keda-scaler
  --arm-nodepool-profile PROFILE  (None, Arm64, Arm64AzureLinux)

  -h, --help
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required."
}

run_az() {
  local operation="$1"
  shift
  if "$@"; then
    return 0
  else
    local exit_code=$?
    die "$operation failed with Azure CLI exit code $exit_code."
  fi
}

run_kubectl() {
  local operation="$1"
  shift
  if "$@"; then
    return 0
  else
    local exit_code=$?
    die "$operation failed with kubectl exit code $exit_code."
  fi
}

register_provider() {
  local namespace="$1"
  run_az "Registering the $namespace provider" \
    az provider register --namespace "$namespace" --only-show-errors

  local deadline=$((SECONDS + 600))
  local state
  while :; do
    state="$(az provider show --namespace "$namespace" --query registrationState --output tsv)" ||
      die "Checking the $namespace provider registration state failed."
    [[ "$state" == "Registered" ]] && return
    echo "  $namespace registration state: $state"
    if (( SECONDS >= deadline )); then
      die "$namespace did not reach Registered within 10 minutes."
    fi
    sleep 15
  done
}

assert_aks_configuration() {
  local system_nodepool keda_enabled
  system_nodepool="$(az aks nodepool list \
    --resource-group "$resource_group" \
    --cluster-name "$cluster_name" \
    --query "[?mode=='System'] | [0]" --output json)" ||
    die "Reading the AKS system node pool failed."
  if ! jq -e '(.nodeTaints // []) | index("CriticalAddonsOnly=true:NoExecute")' \
      >/dev/null <<<"$system_nodepool"; then
    die "The AKS system pool is missing its Bicep-managed CriticalAddonsOnly taint."
  fi

  keda_enabled="$(az aks show --resource-group "$resource_group" --name "$cluster_name" \
    --query "workloadAutoScalerProfile.keda.enabled" --output tsv)" ||
    die "Reading the AKS KEDA add-on state failed."
  [[ "$keda_enabled" == "true" ]] || die "KEDA is not enabled on AKS."
  echo "Verified AKS system-pool taint and KEDA configuration."
}

invoke_store_demo_deployment() {
  local app_manifests_dir="$script_dir/../manifests/aks-store"
  run_kubectl "Creating the pets namespace" \
    bash -c "kubectl create namespace pets --dry-run=client --output yaml | kubectl apply --filename -"

  local manifest
  while IFS= read -r manifest; do
    run_kubectl "Applying $(basename "$manifest")" \
      kubectl apply --filename "$manifest" --namespace pets
  done < <(find "$app_manifests_dir" -maxdepth 1 -type f -name '*.yaml' ! -name '*-changed.yaml' -print | sort)

  echo "Waiting for AKS Store workloads to finish rolling out..."
  local workloads workload
  workloads="$(kubectl get deployments,statefulsets --namespace pets --output name)" ||
    die "Listing pets namespace workloads failed."
  while IFS= read -r workload; do
    [[ -z "$workload" ]] && continue
    run_kubectl "Waiting for rollout of $workload" \
      kubectl rollout status "$workload" --namespace pets --timeout=300s
  done <<<"$workloads"

  run_kubectl "Listing pets namespace resources" kubectl get all --namespace pets

  local deadline=$((SECONDS + 300))
  local store_ip="" admin_ip=""
  while :; do
    store_ip="$(kubectl get service store-front --namespace pets \
      -o 'jsonpath={.status.loadBalancer.ingress[0].ip}')" || die "Reading store-front failed."
    admin_ip="$(kubectl get service store-admin --namespace pets \
      -o 'jsonpath={.status.loadBalancer.ingress[0].ip}')" || die "Reading store-admin failed."
    [[ -n "$store_ip" && -n "$admin_ip" ]] && break
    if (( SECONDS >= deadline )); then
      die "The internal load balancers did not receive addresses within 5 minutes."
    fi
    sleep 10
  done

  local service_name internal
  for service_name in store-front store-admin; do
    internal="$(kubectl get service "$service_name" --namespace pets \
      -o 'jsonpath={.metadata.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-internal}')" ||
      die "Reading the $service_name internal load balancer annotation failed."
    [[ "$internal" == "true" ]] ||
      die "Expected an internal load balancer for '$service_name'; received '$internal'."
  done

  echo "Internal Store Front address: http://$store_ip"
  echo "Internal Store Admin address: http://$admin_ip"
  echo "Use 'kubectl port-forward --namespace pets service/store-front 8080:80' to open Store Front."
}

invoke_keda_scaler_configuration() {
  echo "Waiting for KEDA CRDs to become available..."
  local retries=0
  while (( retries < 30 )); do
    if kubectl get crd scaledobjects.keda.sh --ignore-not-found --output name >/dev/null 2>&1; then
      break
    fi
    sleep 10
    (( ++retries ))
  done
  (( retries < 30 )) || die "Timed out waiting for KEDA CRDs."

  run_kubectl "Applying the virtual-worker KEDA scaler" \
    kubectl apply --filename "$script_dir/../manifests/virtual-worker-scaler.yaml"
  run_kubectl "Verifying the virtual-worker KEDA scaler" \
    kubectl get scaledobject,hpa --namespace pets
}

invoke_kubernetes_setup() {
  require_command kubectl
  assert_aks_configuration
  run_kubectl "Checking AKS connectivity" kubectl get nodes ||
    die "AKS is not reachable through the current kubectl context. Connect with scripts/Connect-AksViaBastion.ps1 first."

  [[ "$deploy_store_demo" == true ]] && invoke_store_demo_deployment

  if [[ "$arm_nodepool_profile" != "None" ]]; then
    local profile_manifest="$script_dir/../manifests/arm-nodepool-profile.yaml"
    [[ "$arm_nodepool_profile" == "Arm64AzureLinux" ]] &&
      profile_manifest="$script_dir/../manifests/arm-nodepool-profile-v2.yaml"
    run_kubectl "Applying the $arm_nodepool_profile NodePool profile" \
      kubectl apply --filename "$profile_manifest"
    echo "Applied the $arm_nodepool_profile NodePool profile."
  fi

  if [[ "$configure_keda_scaler" == true ]]; then
    invoke_keda_scaler_configuration
    echo "Configured the virtual-worker KEDA scaler."
  fi
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
resource_group="Azure-SRE-Agent-Demo_RG"
location="canadacentral"
cluster_name="Azure-SRE-Agent-Demo-Cluster"
ssh_public_key_path="$HOME/.ssh/id_rsa.pub"
subscription_id=""
enable_container_network_logs=false
skip_role_assignments=false
kubernetes_only=false
deploy_store_demo=false
configure_keda_scaler=false
arm_nodepool_profile="None"

while (($#)); do
  case "$1" in
    --subscription-id) subscription_id="${2:?Missing value for --subscription-id}"; shift 2 ;;
    --resource-group-name) resource_group="${2:?Missing value for --resource-group-name}"; shift 2 ;;
    --location) location="${2:?Missing value for --location}"; shift 2 ;;
    --aks-cluster-name) cluster_name="${2:?Missing value for --aks-cluster-name}"; shift 2 ;;
    --ssh-public-key-path) ssh_public_key_path="${2:?Missing value for --ssh-public-key-path}"; shift 2 ;;
    --enable-container-network-logs) enable_container_network_logs=true; shift ;;
    --skip-role-assignments) skip_role_assignments=true; shift ;;
    --kubernetes-only) kubernetes_only=true; shift ;;
    --deploy-store-demo) deploy_store_demo=true; shift ;;
    --configure-keda-scaler) configure_keda_scaler=true; shift ;;
    --arm-nodepool-profile)
      arm_nodepool_profile="${2:?Missing value for --arm-nodepool-profile}"
      [[ "$arm_nodepool_profile" == "None" || "$arm_nodepool_profile" == "Arm64" ||
        "$arm_nodepool_profile" == "Arm64AzureLinux" ]] ||
        die "Invalid --arm-nodepool-profile: $arm_nodepool_profile"
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option '$1'. Use --help for usage." ;;
  esac
done

require_command az
require_command jq
require_command ssh-keygen

az_version="$(az version --output json | jq -r '."azure-cli"')" ||
  die "Reading the Azure CLI version failed."
if [[ "$(printf '%s\n' '2.85.0' "$az_version" | sort -V | head -n1)" != "2.85.0" ]]; then
  die "Azure CLI 2.85.0 or later is required for Azure Bastion AKS tunneling. Installed version: $az_version."
fi

if [[ -n "$subscription_id" ]]; then
  run_az "Selecting subscription '$subscription_id'" az account set --subscription "$subscription_id"
fi
az account show --output json >/dev/null ||
  die "Log in to Azure before deploying (az login)."

if [[ "$kubernetes_only" == true ]]; then
  if [[ "$deploy_store_demo" == true || "$configure_keda_scaler" == true ||
    "$arm_nodepool_profile" != "None" ]]; then
    invoke_kubernetes_setup
  else
    assert_aks_configuration
  fi
  exit 0
fi

if [[ "$deploy_store_demo" == true || "$configure_keda_scaler" == true ||
  "$arm_nodepool_profile" != "None" ]]; then
  die "Kubernetes setup options require --kubernetes-only after connecting with scripts/Connect-AksViaBastion.ps1."
fi

network_feature="AllowBringYourOwnPublicIpAddress"
network_feature_state="$(az feature show --namespace Microsoft.Network --name "$network_feature" \
  --query properties.state --output tsv)" ||
  die "Reading Microsoft.Network/$network_feature registration state failed."
if [[ "$network_feature_state" != "Registered" ]]; then
  echo "Registering Microsoft.Network/$network_feature..."
  run_az "Registering Microsoft.Network/$network_feature" \
    az feature register --namespace Microsoft.Network --name "$network_feature" --only-show-errors
  deadline=$((SECONDS + 1800))
  while :; do
    sleep 30
    network_feature_state="$(az feature show --namespace Microsoft.Network --name "$network_feature" \
      --query properties.state --output tsv)" ||
      die "Checking Microsoft.Network/$network_feature registration state failed."
    echo "  RegistrationState: $network_feature_state"
    [[ "$network_feature_state" == "Registered" ]] && break
    if (( SECONDS >= deadline )); then
      die "Microsoft.Network/$network_feature did not reach Registered within 30 minutes."
    fi
  done
fi

for provider in Microsoft.Network Microsoft.ManagedIdentity Microsoft.ContainerService \
  Microsoft.OperationalInsights Microsoft.Insights Microsoft.Monitor \
  Microsoft.AlertsManagement Microsoft.App; do
  register_provider "$provider"
done

if az extension show --name aks-preview --only-show-errors >/dev/null 2>&1; then
  if az aks bastion tunnel --help >/dev/null 2>&1; then
    echo "Using the installed aks-preview Azure CLI extension."
  else
    run_az "Updating the aks-preview Azure CLI extension" \
      az extension update --name aks-preview --allow-preview true
  fi
else
  run_az "Installing the aks-preview Azure CLI extension" \
    az extension add --name aks-preview --allow-preview true
fi

if [[ ! -f "$ssh_public_key_path" ]]; then
  [[ "$ssh_public_key_path" == *.pub ]] ||
    die "The SSH public key path must end in '.pub'."
  private_key_path="${ssh_public_key_path%.pub}"
  [[ ! -e "$private_key_path" ]] ||
    die "Private key '$private_key_path' exists but its public key is missing. Restore the public key rather than overwriting the private key."
  mkdir -p "$(dirname "$ssh_public_key_path")"
  ssh-keygen -t rsa -b 4096 -f "$private_key_path" -N "" >/dev/null ||
    die "Generating the local SSH key failed."
fi
ssh_public_key="$(tr -d '\r\n' < "$ssh_public_key_path")"
[[ "$ssh_public_key" =~ ^ssh-(rsa|ed25519)[[:space:]]+[^[:space:]]+ ]] ||
  die "'$ssh_public_key_path' must contain an SSH public key, not a private key."

policy_managed_nsg_names=(
  "vnet-sre-agent-aks-demo-snet-sre-agent-nsg-$location"
  "vnet-sre-agent-aks-demo-AzureBastionSubnet-nsg-$location"
  "vnet-aks-sre-agent-demo-snet-aks-nodes-nsg-$location"
  "vnet-aks-sre-agent-demo-snet-aks-api-server-nsg-$location"
)
existing_policy_managed_nsg_count=0
for nsg_name in "${policy_managed_nsg_names[@]}"; do
  if az network nsg show --resource-group "$resource_group" --name "$nsg_name" \
      --only-show-errors --output none >/dev/null 2>&1; then
    (( ++existing_policy_managed_nsg_count ))
  fi
done
case "$existing_policy_managed_nsg_count" in
  0) associate_existing_policy_managed_nsgs=false ;;
  4) associate_existing_policy_managed_nsgs=true ;;
  *) die "Only $existing_policy_managed_nsg_count of 4 expected policy-managed NSGs exist. Resolve the partial policy deployment before updating the VNets." ;;
esac

echo "Deploying private AKS, networking, telemetry, Bastion, and SRE Agent... this takes several minutes."
deployment_args=()
[[ "$skip_role_assignments" == true ]] && deployment_args+=(deployRoleAssignments=false)
export AKS_SSH_PUBLIC_KEY="$ssh_public_key"
deployment_outputs="$(az deployment sub create \
  --name sre-agent-infrastructure \
  --location "$location" \
  --template-file "$script_dir/../infra/bicep/main.bicep" \
  --parameters "$script_dir/../infra/bicep/main.bicepparam" \
  --parameters "resourceGroupName=$resource_group" "location=$location" \
    "aksClusterName=$cluster_name" \
    "associateExistingPolicyManagedNsgs=$associate_existing_policy_managed_nsgs" \
    "enableContainerNetworkLogs=$enable_container_network_logs" \
    "${deployment_args[@]}" \
  --query properties.outputs --output json)" ||
  die "Deploying the complete demo infrastructure failed with Azure CLI exit code $?."

assert_aks_configuration
azure_monitor_workspace_id="$(jq -r '.azureMonitorWorkspaceId.value' <<<"$deployment_outputs")"
recommendations="$(az rest --method get \
  --url "$azure_monitor_workspace_id/providers/Microsoft.AlertsManagement/alertRuleRecommendations?api-version=2023-01-01-preview" \
  --output json)" || die "Reading Azure Monitor recording-rule recommendations failed."

rule_groups="$(jq -c '[.value[] | select(.properties.alertRuleType == "Microsoft.AlertsManagement/prometheusRuleGroups")
  | . as $recommendation
  | $recommendation.properties.rulesArmTemplate.resources[]
  | select(.type == "Microsoft.AlertsManagement/prometheusRuleGroups")
  | {name: $recommendation.name, rules: .properties.rules}
  | select((.rules | length) > 0 and ([.rules[] | select((.record // null) == null or (.expression // null) == null)] | length) == 0)]' \
  <<<"$recommendations")"
if [[ "$rule_groups" != "[]" ]]; then
  recording_rules_parameters="$(mktemp)"
  trap 'rm -f "$recording_rules_parameters"' EXIT
  jq -n --argjson rule_groups "$rule_groups" \
    '{parameters: {ruleGroups: {value: $rule_groups}}}' >"$recording_rules_parameters"
  aks_cluster_id="$(jq -r '.aksClusterId.value' <<<"$deployment_outputs")"
  run_az "Deploying Azure Monitor recording rules" az deployment group create \
    --name private-aks-recording-rules \
    --resource-group "$resource_group" \
    --template-file "$script_dir/../infra/bicep/modules/prometheus-recording-rules.bicep" \
    --parameters "@$recording_rules_parameters" \
    --parameters "location=$location" "aksClusterName=$cluster_name" \
      "aksClusterId=$aks_cluster_id" "azureMonitorWorkspaceId=$azure_monitor_workspace_id" \
    --only-show-errors
else
  echo "Warning: Azure Monitor returned no recording-rule recommendations. Metrics ingestion is enabled; rerun scripts/deploy.sh to retry recommendation discovery." >&2
fi

echo "Private cluster, Azure Bastion, and SRE Agent are ready."
echo "Bastion resource: $(jq -r '.bastionId.value' <<<"$deployment_outputs")"
echo "SRE Agent endpoint: $(jq -r '.agentEndpoint.value' <<<"$deployment_outputs")"
echo "Run scripts/Connect-AksViaBastion.ps1 to open a kubectl-enabled subshell."
echo "After connecting, optional AKS workloads can be configured with scripts/deploy.sh --kubernetes-only and its Kubernetes setup options."
