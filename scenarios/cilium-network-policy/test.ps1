param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Broken", "Fixed")]
    [string]$ExpectedState
)

$ErrorActionPreference = "Stop"
$script:Failures = 0

function Test-HttpConnection {
    param(
        [string]$Namespace,
        [string]$Deployment,
        [string]$Url,
        [bool]$ShouldSucceed,
        [string]$Description
    )

    kubectl exec -n $Namespace "deployment/$Deployment" -- `
        curl -fsS --connect-timeout 3 --max-time 5 $Url *> $null
    $succeeded = $LASTEXITCODE -eq 0
    $matchesExpectation = $succeeded -eq $ShouldSucceed
    $status = if ($succeeded) { "ALLOWED" } else { "DENIED" }
    $color = if ($matchesExpectation) { "Green" } else { "Red" }

    Write-Host ("[{0}] {1}" -f $status, $Description) -ForegroundColor $color
    if (-not $matchesExpectation) {
        $script:Failures++
    }
}

$servicePortIp = kubectl get service service-port-server -n cilium-policy-demo -o jsonpath='{.spec.clusterIP}'
$decoyIp = kubectl get service service-port-decoy -n cilium-policy-demo -o jsonpath='{.spec.clusterIP}'
if (-not $servicePortIp -or -not $decoyIp) {
    throw "Scenario services were not found. Run .\setup.ps1 first."
}

$isFixed = $ExpectedState -eq "Fixed"
Write-Host "Expected state: $ExpectedState" -ForegroundColor Cyan
Write-Host ""

Test-HttpConnection `
    -Namespace "cilium-policy-demo" `
    -Deployment "cross-namespace-local-client" `
    -Url "http://cross-namespace-server.cilium-policy-demo.svc.cluster.local" `
    -ShouldSucceed $true `
    -Description "Same-namespace client to cross-namespace test server"

Test-HttpConnection `
    -Namespace "cilium-policy-observer" `
    -Deployment "cross-namespace-client" `
    -Url "http://cross-namespace-server.cilium-policy-demo.svc.cluster.local" `
    -ShouldSucceed $isFixed `
    -Description "Remote-namespace client to cross-namespace test server"

Test-HttpConnection `
    -Namespace "cilium-policy-demo" `
    -Deployment "cidr-client" `
    -Url "http://cidr-server" `
    -ShouldSucceed $isFixed `
    -Description "Cilium-managed pod through a CIDR-based ingress rule"

Test-HttpConnection `
    -Namespace "cilium-policy-demo" `
    -Deployment "service-port-client" `
    -Url "http://${servicePortIp}" `
    -ShouldSucceed $true `
    -Description "Service-restricted client to intended service"

Test-HttpConnection `
    -Namespace "cilium-policy-demo" `
    -Deployment "service-port-client" `
    -Url "http://${decoyIp}" `
    -ShouldSucceed (-not $isFixed) `
    -Description "Service-restricted client to unrelated decoy service"

Write-Host ""
kubectl get ciliumnetworkpolicy -n cilium-policy-demo

if ($script:Failures -gt 0) {
    throw "$($script:Failures) connectivity check(s) did not match the expected '$ExpectedState' state."
}

Write-Host ""
Write-Host "All connectivity checks matched the expected '$ExpectedState' state." -ForegroundColor Green
