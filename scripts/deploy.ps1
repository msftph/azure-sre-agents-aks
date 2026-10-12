#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$Location,
    [string]$AksClusterName,
    [string]$SshPublicKeyPath = "$HOME/.ssh/id_rsa.pub",
    [switch]$EnableContainerNetworkLogs,
    [switch]$SkipRoleAssignments
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
