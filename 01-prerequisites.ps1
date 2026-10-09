# ============================================================
# Step 1 - Prerequisites
#   Register providers and the public-IP feature; install the CLI extension
# ============================================================
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\00-variables.ps1"

function Assert-AzCliSucceeded {
    param([Parameter(Mandatory)][string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with Azure CLI exit code $LASTEXITCODE."
    }
}

function Register-AzProvider {
    param([Parameter(Mandatory)][string]$Namespace)

    az provider register --namespace $Namespace
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

# Select the target subscription
az account set -s $SUBSCRIPTION_ID
Assert-AzCliSucceeded "Selecting subscription '$SUBSCRIPTION_ID'"

az account show -o table
Assert-AzCliSucceeded "Reading the active Azure subscription"

# Some enterprise policies append a FirstPartyUsage tag to every public IP.
# Azure rejects those addresses unless this subscription feature is registered.
$networkFeature = "AllowBringYourOwnPublicIpAddress"
$networkFeatureState = az feature show `
  --namespace "Microsoft.Network" `
  --name $networkFeature `
  --query "properties.state" `
  --output tsv
Assert-AzCliSucceeded "Reading Microsoft.Network/$networkFeature registration state"

if ($networkFeatureState -ne "Registered") {
    Write-Host "Registering Microsoft.Network/$networkFeature..." -ForegroundColor Yellow
    az deployment sub create `
      --name "sre-agent-subscription-prerequisites" `
      --location $LOCATION `
      --template-file "$PSScriptRoot\infra\subscription-prerequisites.bicep" `
      --only-show-errors
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

Register-AzProvider "Microsoft.Network"
Register-AzProvider "Microsoft.ManagedIdentity"
Register-AzProvider "Microsoft.ContainerService"
Register-AzProvider "Microsoft.OperationalInsights"
Register-AzProvider "Microsoft.Insights"
Register-AzProvider "Microsoft.Monitor"
Register-AzProvider "Microsoft.AlertsManagement"
Register-AzProvider "Microsoft.App"

# Install the preview extension that contains the GA az aks bastion command group.
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

Write-Host "Prerequisites complete." -ForegroundColor Green
