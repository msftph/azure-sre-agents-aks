# ============================================================
# Step 8 — GitHub Post-Incident Issue Automation
#
# This script prints the configuration checklist for wiring
# up GitHub Issues as the post-incident automation target for
# Azure SRE Agent.
#
# All steps below are performed in the portal at sre.azure.com.
# Nothing in this script modifies Azure resources — it is a
# guided reference you can run at any time.
# ============================================================

. (Join-Path $PSScriptRoot "variables.ps1")

$GITHUB_REPO = "hailugebru/azure-sre-agents-aks"
$SUBAGENT_NAME = "github-issue-tracker"
$CONNECTOR_NAME = "github-mcp"

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Step 8: GitHub Post-Incident Issue Automation"          -ForegroundColor Cyan
Write-Host "  Portal: https://sre.azure.com"                          -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# ── A. GitHub MCP Connector ──────────────────────────────────
Write-Host "A) Add the GitHub MCP connector" -ForegroundColor Yellow
Write-Host "   1. Go to: Builder > Connectors > + Add connector"
Write-Host "   2. Select the MCP tab -> GitHub MCP server"
Write-Host "   3. The portal pre-fills the URL and locks Authentication method to 'Bearer token'."
Write-Host "      This is expected -- GitHub MCP uses PAT/Bearer token, not OAuth."
Write-Host "      Generate a PAT at https://github.com/settings/tokens and paste it in the field."
Write-Host "      - Classic PAT     : 'repo' scope"
Write-Host "      - Fine-grained PAT: 'Issues: Read and write' scoped to $GITHUB_REPO"
Write-Host "      NOTE: The GitHub OAuth connector (Code Repository tab) is read-only."
Write-Host "            Only the MCP connector can create issues."
Write-Host "   4. After status shows Connected:"
Write-Host "      - Select Edit -> MCP Tools"
Write-Host "      - Enable: create_issue  (required)"
Write-Host "      - Enable: list_issues   (recommended — duplicate check)"
Write-Host "   5. Select Save"
Write-Host ""

# ── B. github-issue-tracker subagent ─────────────────────────
Write-Host "B) Create the '$SUBAGENT_NAME' subagent" -ForegroundColor Yellow
Write-Host "   1. Go to: Builder > Subagent builder > + Create subagent"
Write-Host "   2. Name     : $SUBAGENT_NAME"
Write-Host "   3. Autonomy : Autonomous"
Write-Host "   4. Tools    : create_issue  (from the '$CONNECTOR_NAME' connection)"
Write-Host "   5. Select Save"
Write-Host ""

# ── C. Incident Response Plan custom instructions ─────────────
Write-Host "C) Update Incident Response Plan custom instructions" -ForegroundColor Yellow
Write-Host "   Go to: Incident Response Plan -> Custom instructions"
Write-Host "   Replace instruction 5 with:"
Write-Host ""
Write-Host @"
   For AKS pod health alerts in the pets namespace:
   1. Scan all namespaces for unhealthy pods first.
   2. Prioritise OOMKilled and CrashLoopBackOff.
   3. For OOMKilled: correlate NODE_OPTIONS / JVM flags against container memory
      limits before adjusting. Apply the minimum necessary increase.
   4. After any patch, wait for rollout, then verify cluster-wide pod health.
   5. After successful resolution, invoke the $SUBAGENT_NAME subagent to create
      a GitHub issue in $GITHUB_REPO with the incident ID, root cause,
      patch applied, and a recommendation to update the source manifest in Git.
"@ -ForegroundColor Gray
Write-Host ""

# ── D. Verify ────────────────────────────────────────────────
Write-Host "D) Verify after running the OOMKilled demo (Step 4)" -ForegroundColor Yellow
Write-Host "   Expected: a new issue appears at:"
Write-Host "   https://github.com/$GITHUB_REPO/issues"
Write-Host ""
Write-Host "   Issue format:"
Write-Host "   Title  : [SRE-Auto] INC-<date>-<id> — <one-line root cause>"
Write-Host "   Labels : incident, auto-remediated"
Write-Host "   Body   : incident ID, alert severity, timestamp, root cause,"
Write-Host "            fix applied, post-state, source manifest recommendation"
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  PAT minimum permissions (fine-grained token):"           -ForegroundColor Cyan
Write-Host "    Repository access : Single repo ($GITHUB_REPO)"        -ForegroundColor Cyan
Write-Host "    Permissions       : Issues — Read and write"            -ForegroundColor Cyan
Write-Host "  Classic PAT scope: repo"                                  -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
