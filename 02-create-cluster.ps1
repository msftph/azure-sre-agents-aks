# ============================================================
# Compatibility entry point - deploy the complete demo infrastructure
# ============================================================
param(
    [string]$SshPublicKeyPath = "$HOME/.ssh/id_rsa.pub",
    [switch]$EnableContainerNetworkLogs,
    [switch]$SkipRoleAssignments
)

$ErrorActionPreference = "Stop"
& "$PSScriptRoot\Deploy-Demo.ps1" @PSBoundParameters
