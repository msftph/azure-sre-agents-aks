$ErrorActionPreference = "Stop"

kubectl delete containernetworklog cilium-policy-demo --ignore-not-found
kubectl delete namespace cilium-policy-demo cilium-policy-observer --ignore-not-found

Write-Host "Cilium network policy scenario removed." -ForegroundColor Green
