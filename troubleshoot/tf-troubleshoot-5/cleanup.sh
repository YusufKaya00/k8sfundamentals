#!/usr/bin/env bash
set -euo pipefail

echo ">> Cleaning up tf-troubleshoot-5 processes and temporary files..."
pkill -f "nexusvault_daemon_lab5.py" 2>/dev/null || true
rm -rf /tmp/nexusvault-lab5
echo "✅ Cleanup complete."
