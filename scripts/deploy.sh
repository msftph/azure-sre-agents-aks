#!/usr/bin/env bash
set -euo pipefail

if ! command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell 7 (pwsh) is required to run the deployment." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec pwsh -NoLogo -NoProfile -File "$script_dir/deploy.ps1" "$@"
