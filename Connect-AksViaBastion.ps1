#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$BastionName = "bas-sre-agent-aks-demo",
    [ValidateRange(1024, 65535)]
    [int]$Port = 50001,
    [bool]$UseAdminCredentials = $true
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\00-variables.ps1"

function Assert-AzCliSucceeded {
    param([Parameter(Mandatory)][string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with Azure CLI exit code $LASTEXITCODE."
    }
}

$azVersion = [version]((az version --output json | ConvertFrom-Json).'azure-cli')
Assert-AzCliSucceeded "Reading the Azure CLI version"

if ($azVersion -lt [version]"2.85.0") {
    throw "Azure CLI 2.85.0 or later is required for 'az aks bastion tunnel'. Installed version: $azVersion."
}

az extension show --name aks-preview --only-show-errors 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "The aks-preview extension is required. Run .\01-prerequisites.ps1 first."
}

$privateFqdn = az aks show `
  --resource-group $RESOURCE_GROUP `
  --name $CLUSTER_NAME `
  --query privateFqdn `
  --output tsv
Assert-AzCliSucceeded "Reading the AKS private FQDN"

if ([string]::IsNullOrWhiteSpace($privateFqdn)) {
    throw "AKS cluster '$CLUSTER_NAME' is not configured as a private cluster."
}

$bastionId = az network bastion show `
  --resource-group $RESOURCE_GROUP `
  --name $BastionName `
  --query id `
  --output tsv
Assert-AzCliSucceeded "Reading Azure Bastion '$BastionName'"

$arguments = @(
    "aks", "bastion", "tunnel",
    "--resource-group", $RESOURCE_GROUP,
    "--name", $CLUSTER_NAME,
    "--bastion", $bastionId,
    "--port", $Port,
    "--yes"
)

if ($UseAdminCredentials) {
    $arguments += "--admin"
}

Write-Host "Opening an AKS shell through Azure Bastion on local port $Port." -ForegroundColor Cyan
Write-Host "Run kubectl commands in the subshell. Type 'exit' to close the tunnel." -ForegroundColor Cyan
az @arguments
Assert-AzCliSucceeded "Opening the Azure Bastion AKS tunnel"
