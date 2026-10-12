#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$Location,
    [string]$AksClusterName,
    [string]$SshPublicKeyPath = "$HOME/.ssh/id_rsa.pub",
    [switch]$EnableContainerNetworkLogs,
    [switch]$SkipRoleAssignments,
    [switch]$KubernetesOnly,
    [switch]$DeployStoreDemo,
    [switch]$ConfigureKedaScaler,
    [ValidateSet("None", "Arm64", "Arm64AzureLinux")]
    [string]$ArmNodePoolProfile = "None"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "variables.ps1")

if ($ResourceGroupName) { $RESOURCE_GROUP = $ResourceGroupName }
if ($Location) { $LOCATION = $Location }
if ($AksClusterName) { $CLUSTER_NAME = $AksClusterName }

function Assert-AzCliSucceeded {
    param([Parameter(Mandatory)][string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with Azure CLI exit code $LASTEXITCODE."
    }
}

function Register-AzProvider {
    param([Parameter(Mandatory)][string]$Namespace)

    az provider register --namespace $Namespace --only-show-errors
    Assert-AzCliSucceeded "Registering the $Namespace provider"

    $registrationDeadline = (Get-Date).AddMinutes(10)
    do {
        $providerState = az provider show `
          --namespace $Namespace `
          --query "registrationState" `
          --output tsv
        Assert-AzCliSucceeded "Checking the $Namespace provider registration state"

        if ($providerState -eq "Registered") {
            return
        }

        Write-Host "  $Namespace registration state: $providerState"
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $registrationDeadline)

    throw "$Namespace did not reach Registered within 10 minutes."
}

function Assert-AksConfiguration {
    $systemNodepool = az aks nodepool list `
      --resource-group $RESOURCE_GROUP `
      --cluster-name $CLUSTER_NAME `
      --query "[?mode=='System'] | [0]" `
      --output json | ConvertFrom-Json
    Assert-AzCliSucceeded "Reading the AKS system node pool"

    if (
        $null -eq $systemNodepool -or
        $systemNodepool.nodeTaints -notcontains "CriticalAddonsOnly=true:NoExecute"
    ) {
        throw "The AKS system pool is missing its Bicep-managed CriticalAddonsOnly taint."
    }

    $kedaEnabled = az aks show `
      --resource-group $RESOURCE_GROUP `
      --name $CLUSTER_NAME `
      --query "workloadAutoScalerProfile.keda.enabled" `
      --output tsv
    Assert-AzCliSucceeded "Reading the AKS KEDA add-on state"

    if ($kedaEnabled -ne "true") {
        throw "KEDA is not enabled on AKS."
    }

    Write-Host "Verified AKS system-pool taint and KEDA configuration." -ForegroundColor Green
}

function Invoke-StoreDemoDeployment {
    $appManifestsDir = Join-Path $PSScriptRoot "../manifests/aks-store"
    kubectl create namespace pets --dry-run=client --output yaml | kubectl apply --filename -
    if ($LASTEXITCODE -ne 0) {
        throw "Creating the pets namespace failed with kubectl exit code $LASTEXITCODE."
    }

    $baselineManifests = Get-ChildItem `
      -Path $appManifestsDir `
      -Filter "*.yaml" `
      -File |
      Where-Object { $_.BaseName -notlike "*-changed" } |
      Sort-Object Name

    foreach ($manifest in $baselineManifests) {
        kubectl apply --filename $manifest.FullName --namespace pets
        if ($LASTEXITCODE -ne 0) {
            throw "Applying '$($manifest.Name)' failed with kubectl exit code $LASTEXITCODE."
        }
    }

    Write-Host "Waiting for AKS Store workloads to finish rolling out..." -ForegroundColor Yellow
    $workloads = kubectl get deployments,statefulsets --namespace pets --output name
    if ($LASTEXITCODE -ne 0) {
        throw "Listing pets namespace workloads failed with kubectl exit code $LASTEXITCODE."
    }

    foreach ($workload in $workloads) {
        kubectl rollout status $workload --namespace pets --timeout=300s
        if ($LASTEXITCODE -ne 0) {
            throw "Rollout for '$workload' did not complete within 300 seconds."
        }
    }

    kubectl get all --namespace pets
    if ($LASTEXITCODE -ne 0) {
        throw "Listing pets namespace resources failed with kubectl exit code $LASTEXITCODE."
    }

    $loadBalancerDeadline = (Get-Date).AddMinutes(5)
    do {
        $storeIp = kubectl get service store-front --namespace pets -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
        $adminIp = kubectl get service store-admin --namespace pets -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
        if ([string]::IsNullOrWhiteSpace($storeIp) -or [string]::IsNullOrWhiteSpace($adminIp)) {
            Start-Sleep -Seconds 10
        }
    } while (
        ([string]::IsNullOrWhiteSpace($storeIp) -or [string]::IsNullOrWhiteSpace($adminIp)) -and
        (Get-Date) -lt $loadBalancerDeadline
    )

    if ([string]::IsNullOrWhiteSpace($storeIp) -or [string]::IsNullOrWhiteSpace($adminIp)) {
        throw "The internal load balancers did not receive addresses within 5 minutes."
    }

    foreach ($serviceName in @("store-front", "store-admin")) {
        $internal = kubectl get service $serviceName --namespace pets `
          -o 'jsonpath={.metadata.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-internal}'
        if ($LASTEXITCODE -ne 0) {
            throw "Reading the $serviceName internal load balancer annotation failed."
        }
        if ($internal -ne "true") {
            throw "Expected an internal load balancer for '$serviceName'; received '$internal'."
        }
    }

    Write-Host "Internal Store Front address: http://$storeIp" -ForegroundColor Cyan
    Write-Host "Internal Store Admin address: http://$adminIp" -ForegroundColor Cyan
    Write-Host "Use 'kubectl port-forward --namespace pets service/store-front 8080:80' to open Store Front." -ForegroundColor Cyan
}

function Invoke-KedaScalerConfiguration {
    Write-Host "Waiting for KEDA CRDs to become available..."
    $retries = 0
    while ($retries -lt 30) {
        $crd = kubectl get crd scaledobjects.keda.sh --ignore-not-found --output name 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Checking for KEDA CRDs failed with kubectl exit code $LASTEXITCODE."
        }
        if ($crd) { break }
        Start-Sleep -Seconds 10
        $retries++
    }
    if (-not $crd) {
        throw "Timed out waiting for KEDA CRDs."
    }

    $scalerManifest = Join-Path $PSScriptRoot "../manifests/virtual-worker-scaler.yaml"
    kubectl apply --filename $scalerManifest
    if ($LASTEXITCODE -ne 0) {
        throw "Applying the virtual-worker KEDA scaler failed with kubectl exit code $LASTEXITCODE."
    }
    kubectl get scaledobject,hpa --namespace pets
    if ($LASTEXITCODE -ne 0) {
        throw "Verifying the virtual-worker KEDA scaler failed with kubectl exit code $LASTEXITCODE."
    }
}

function Invoke-KubernetesSetup {
    Assert-AksConfiguration

    kubectl get nodes
    if ($LASTEXITCODE -ne 0) {
        throw "AKS is not reachable through the current kubectl context. Connect with scripts/Connect-AksViaBastion.ps1 first."
    }

    if ($DeployStoreDemo) {
        Invoke-StoreDemoDeployment
    }

    if ($ArmNodePoolProfile -ne "None") {
        $profileManifest = if ($ArmNodePoolProfile -eq "Arm64AzureLinux") {
            "../manifests/arm-nodepool-profile-v2.yaml"
        } else {
            "../manifests/arm-nodepool-profile.yaml"
        }
        kubectl apply --filename (Join-Path $PSScriptRoot $profileManifest)
        if ($LASTEXITCODE -ne 0) {
            throw "Applying the $ArmNodePoolProfile NodePool profile failed with kubectl exit code $LASTEXITCODE."
        }
        Write-Host "Applied the $ArmNodePoolProfile NodePool profile." -ForegroundColor Green
    }

    if ($ConfigureKedaScaler) {
        Invoke-KedaScalerConfiguration
        Write-Host "Configured the virtual-worker KEDA scaler." -ForegroundColor Green
    }
}

$azVersion = [version]((az version --output json | ConvertFrom-Json).'azure-cli')
Assert-AzCliSucceeded "Reading the Azure CLI version"
if ($azVersion -lt [version]"2.85.0") {
    throw "Azure CLI 2.85.0 or later is required for Azure Bastion AKS tunneling. Installed version: $azVersion."
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
    Assert-AzCliSucceeded "Selecting subscription '$SubscriptionId'"
}

$subscription = az account show --output json | ConvertFrom-Json
Assert-AzCliSucceeded "Reading the active Azure subscription"
if (-not $subscription) {
    throw "Log in to Azure before deploying (az login)."
}

if ($KubernetesOnly) {
    if ($DeployStoreDemo -or $ConfigureKedaScaler -or $ArmNodePoolProfile -ne "None") {
        Invoke-KubernetesSetup
    } else {
        Assert-AksConfiguration
    }
    return
}

if ($DeployStoreDemo -or $ConfigureKedaScaler -or $ArmNodePoolProfile -ne "None") {
    throw "Kubernetes setup options require -KubernetesOnly after connecting with scripts/Connect-AksViaBastion.ps1."
}

$networkFeature = "AllowBringYourOwnPublicIpAddress"
$networkFeatureState = az feature show `
  --namespace "Microsoft.Network" `
  --name $networkFeature `
  --query "properties.state" `
  --output tsv
Assert-AzCliSucceeded "Reading Microsoft.Network/$networkFeature registration state"

if ($networkFeatureState -ne "Registered") {
    Write-Host "Registering Microsoft.Network/$networkFeature..." -ForegroundColor Yellow
    az feature register --namespace "Microsoft.Network" --name $networkFeature --only-show-errors
    Assert-AzCliSucceeded "Registering Microsoft.Network/$networkFeature"

    $registrationDeadline = (Get-Date).AddMinutes(30)
    do {
        Start-Sleep -Seconds 30
        $networkFeatureState = az feature show `
          --namespace "Microsoft.Network" `
          --name $networkFeature `
          --query "properties.state" `
          --output tsv
        Assert-AzCliSucceeded "Checking Microsoft.Network/$networkFeature registration state"
        Write-Host "  RegistrationState: $networkFeatureState"
    } while (
        $networkFeatureState -ne "Registered" -and
        (Get-Date) -lt $registrationDeadline
    )

    if ($networkFeatureState -ne "Registered") {
        throw "Microsoft.Network/$networkFeature did not reach Registered within 30 minutes."
    }
}

@(
    "Microsoft.Network"
    "Microsoft.ManagedIdentity"
    "Microsoft.ContainerService"
    "Microsoft.OperationalInsights"
    "Microsoft.Insights"
    "Microsoft.Monitor"
    "Microsoft.AlertsManagement"
    "Microsoft.App"
) | ForEach-Object { Register-AzProvider $_ }

az extension show --name aks-preview --only-show-errors 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    az aks bastion tunnel --help 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        az extension update --name aks-preview --allow-preview true
        Assert-AzCliSucceeded "Updating the aks-preview Azure CLI extension"
    } else {
        Write-Host "Using the installed aks-preview Azure CLI extension."
    }
} else {
    az extension add --name aks-preview --allow-preview true
    Assert-AzCliSucceeded "Installing the aks-preview Azure CLI extension"
}

if (-not (Test-Path $SshPublicKeyPath)) {
    if (-not $SshPublicKeyPath.EndsWith(".pub")) {
        throw "The SSH public key path must end in '.pub'."
    }
    $privateKeyPath = $SshPublicKeyPath.Substring(0, $SshPublicKeyPath.Length - 4)
    if (Test-Path $privateKeyPath) {
        throw "Private key '$privateKeyPath' exists but its public key is missing. Restore the public key rather than overwriting the private key."
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $SshPublicKeyPath -Parent) | Out-Null
    ssh-keygen -t rsa -b 4096 -f $privateKeyPath -N "" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Generating the local SSH key failed with exit code $LASTEXITCODE."
    }
}
$sshPublicKey = (Get-Content -Raw $SshPublicKeyPath).Trim()
if ($sshPublicKey -notmatch '^ssh-(rsa|ed25519)\s+\S+') {
    throw "'$SshPublicKeyPath' must contain an SSH public key, not a private key."
}

$policyManagedNsgNames = @(
    "vnet-sre-agent-aks-demo-snet-sre-agent-nsg-$LOCATION"
    "vnet-sre-agent-aks-demo-AzureBastionSubnet-nsg-$LOCATION"
    "vnet-aks-sre-agent-demo-snet-aks-nodes-nsg-$LOCATION"
    "vnet-aks-sre-agent-demo-snet-aks-api-server-nsg-$LOCATION"
)
$existingPolicyManagedNsgCount = 0
foreach ($networkSecurityGroupName in $policyManagedNsgNames) {
    az network nsg show `
      --resource-group $RESOURCE_GROUP `
      --name $networkSecurityGroupName `
      --only-show-errors `
      --output none 2>$null

    if ($LASTEXITCODE -eq 0) {
        $existingPolicyManagedNsgCount++
    }
}

if ($existingPolicyManagedNsgCount -eq $policyManagedNsgNames.Count) {
    $associateExistingPolicyManagedNsgs = "true"
} elseif ($existingPolicyManagedNsgCount -eq 0) {
    $associateExistingPolicyManagedNsgs = "false"
} else {
    throw "Only $existingPolicyManagedNsgCount of $($policyManagedNsgNames.Count) expected policy-managed NSGs exist. Resolve the partial policy deployment before updating the VNets."
}

Write-Host "Deploying private AKS, networking, telemetry, Bastion, and SRE Agent... this takes several minutes." -ForegroundColor Yellow
$roleAssignmentParameters = @()
if ($SkipRoleAssignments) {
    $roleAssignmentParameters = @("deployRoleAssignments=false")
}
$previousSshPublicKey = $env:AKS_SSH_PUBLIC_KEY
$bicepRoot = Join-Path $PSScriptRoot "../infra/bicep"
$mainTemplatePath = Join-Path $bicepRoot "main.bicep"
$mainParametersPath = Join-Path $bicepRoot "main.bicepparam"
$recordingRulesTemplatePath = Join-Path $bicepRoot "modules/prometheus-recording-rules.bicep"
try {
    $env:AKS_SSH_PUBLIC_KEY = $sshPublicKey
    $deploymentOutputs = az deployment sub create `
      --name "sre-agent-infrastructure" `
      --location $LOCATION `
      --template-file $mainTemplatePath `
      --parameters $mainParametersPath `
      --parameters resourceGroupName=$RESOURCE_GROUP location=$LOCATION aksClusterName=$CLUSTER_NAME associateExistingPolicyManagedNsgs=$associateExistingPolicyManagedNsgs `
      enableContainerNetworkLogs=$($EnableContainerNetworkLogs.IsPresent.ToString().ToLowerInvariant()) @roleAssignmentParameters `
      --query "properties.outputs" `
      --output json | ConvertFrom-Json
    Assert-AzCliSucceeded "Deploying the complete demo infrastructure"
} finally {
    $env:AKS_SSH_PUBLIC_KEY = $previousSshPublicKey
}

Assert-AksConfiguration

$azureMonitorWorkspaceId = $deploymentOutputs.azureMonitorWorkspaceId.value
$recommendations = az rest `
  --method get `
  --url "$azureMonitorWorkspaceId/providers/Microsoft.AlertsManagement/alertRuleRecommendations?api-version=2023-01-01-preview" `
  --output json | ConvertFrom-Json
Assert-AzCliSucceeded "Reading Azure Monitor recording-rule recommendations"

$ruleGroups = @(
    foreach ($recommendation in $recommendations.value) {
        if ($recommendation.properties.alertRuleType -ne "Microsoft.AlertsManagement/prometheusRuleGroups") {
            continue
        }
        foreach ($resource in $recommendation.properties.rulesArmTemplate.resources) {
            if ($resource.type -ne "Microsoft.AlertsManagement/prometheusRuleGroups") {
                continue
            }
            $rules = @($resource.properties.rules)
            $alertRules = @($rules | Where-Object { -not $_.record -or -not $_.expression })
            if ($rules.Count -gt 0 -and $alertRules.Count -eq 0) {
                @{
                    name = $recommendation.name
                    rules = $rules
                }
            }
        }
    }
)

if ($ruleGroups.Count -gt 0) {
    $recordingRuleParameters = New-TemporaryFile
    try {
        @{
            parameters = @{
                ruleGroups = @{ value = $ruleGroups }
            }
        } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $recordingRuleParameters.FullName

        az deployment group create `
          --name "private-aks-recording-rules" `
          --resource-group $RESOURCE_GROUP `
          --template-file $recordingRulesTemplatePath `
          --parameters "@$($recordingRuleParameters.FullName)" `
          --parameters location=$LOCATION aksClusterName=$CLUSTER_NAME `
          aksClusterId=$($deploymentOutputs.aksClusterId.value) azureMonitorWorkspaceId=$azureMonitorWorkspaceId `
          --only-show-errors
        Assert-AzCliSucceeded "Deploying Azure Monitor recording rules"
    } finally {
        Remove-Item -LiteralPath $recordingRuleParameters.FullName -Force
    }
} else {
    Write-Warning "Azure Monitor returned no recording-rule recommendations. Metrics ingestion is enabled; rerun scripts/deploy.ps1 to retry recommendation discovery."
}

Write-Host "Private cluster, Azure Bastion, and SRE Agent are ready." -ForegroundColor Green
Write-Host "Bastion resource: $($deploymentOutputs.bastionId.value)" -ForegroundColor Cyan
Write-Host "SRE Agent endpoint: $($deploymentOutputs.agentEndpoint.value)" -ForegroundColor Cyan
Write-Host "Run .\scripts\Connect-AksViaBastion.ps1 to open a kubectl-enabled subshell." -ForegroundColor Cyan
Write-Host "After connecting, optional AKS workloads can be configured with scripts/deploy.ps1 -KubernetesOnly and its Kubernetes setup options." -ForegroundColor Cyan
