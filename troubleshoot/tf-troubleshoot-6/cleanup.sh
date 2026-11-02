#!/usr/bin/env bash
set -euo pipefail

echo ">> Cleaning up tf-troubleshoot-6 processes and temporary files..."
pkill -f "aegis_worker_lab6.py" 2>/dev/null || true
pkill -f "aegis_lb_lab6.py" 2>/dev/null || true
rm -rf /tmp/aegiscloud-lab6
echo "✅ Cleanup complete."
