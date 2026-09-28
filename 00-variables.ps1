# ============================================================
# Shared environment variables for the NAP (Karpenter) demo
# Dot-source this file before running any other script:
#   . .\00-variables.ps1
# ============================================================

# Azure
$SUBSCRIPTION_ID   = "ab021129-9bf3-4ee3-bbc6-3da839fb88a1"
$RESOURCE_GROUP    = "rg-sre-aks"
$LOCATION          = "swedencentral"
$CLUSTER_NAME      = "aks-sre-agent-demo"
$KUBERNETES_VERSION = "1.35.7"
$NODE_VM_SIZE      = "Standard_D4s_v5"
$NODE_COUNT        = 1
