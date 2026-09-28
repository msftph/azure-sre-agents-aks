# ============================================================
# Step 1 - Prerequisites
#   Register the NAP preview feature and install the CLI extension
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
          -o tsv
        Assert-AzCliSucceeded "Checking the $Namespace provider registration state"

        if ($providerState -eq "Registered") {
            return
        }

        Write-Host "  $Namespace registration state: $providerState"
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $registrationDeadline)

    throw "$Namespace did not reach Registered within 10 minutes."
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
  -o tsv
Assert-AzCliSucceeded "Reading Microsoft.Network/$networkFeature registration state"

if ($networkFeatureState -ne "Registered") {
    Write-Host "Registering Microsoft.Network/$networkFeature..." -ForegroundColor Yellow
    az feature register `
      --namespace "Microsoft.Network" `
      --name $networkFeature `
      --only-show-errors
    Assert-AzCliSucceeded "Registering Microsoft.Network/$networkFeature"

    $registrationDeadline = (Get-Date).AddMinutes(30)
    do {
        Start-Sleep -Seconds 30
        $networkFeatureState = az feature show `
          --namespace "Microsoft.Network" `
          --name $networkFeature `
          --query "properties.state" `
          -o tsv
        Assert-AzCliSucceeded "Checking Microsoft.Network/$networkFeature registration state"
        Write-Host "  RegistrationState: $networkFeatureState"
    } while (
        $networkFeatureState -ne "Registered" -and
        (Get-Date) -lt $registrationDeadline
    )

    if ($networkFeatureState -ne "Registered") {
        throw @"
Microsoft.Network/$networkFeature did not reach Registered within 30 minutes.
If registration requires tenant approval, request an exemption from the policy
that appends FirstPartyUsage tags to public IP addresses before creating AKS.
"@
    }
}

Register-AzProvider "Microsoft.Network"

# NAP is generally available. Ensure the resource provider is registered.
Register-AzProvider "Microsoft.ContainerService"

# Install the aks-preview CLI extension when it is not already available.
# Avoid making a working deployment depend on extension-index availability.
az extension show --name aks-preview --only-show-errors 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Using the installed aks-preview Azure CLI extension."
} else {
    az extension add --name aks-preview
    Assert-AzCliSucceeded "Installing the aks-preview Azure CLI extension"
}

Write-Host "Prerequisites complete." -ForegroundColor Green
