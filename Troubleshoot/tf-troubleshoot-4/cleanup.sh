#!/usr/bin/env bash
set -euo pipefail

echo ">> Cleaning up iac-troubleshoot-1 processes and temporary files..."
pkill -f "chronopay_backend_lab1.py" 2>/dev/null || true
pkill -f "chronopay_proxy_lab1.py" 2>/dev/null || true
rm -rf /tmp/chronopay-lab1
echo "✅ Cleanup complete."
