#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

# Stop and clean up vLLM containers on both nodes.
# Usage: ./stop.sh [WORKER_SSH]

WORKER_SSH="${1:-root@192.168.22.161}"
WORKER_PASS="${WORKER_PASS:-YOUR_WORKER_PASSWORD}"

echo "=== Stopping worker container ==="
sshpass -p "$WORKER_PASS" ssh -o StrictHostKeyChecking=no "$WORKER_SSH" "
  sudo docker rm -f vllm_anemll 2>/dev/null || true
  sudo pkill -9 -f 'vllm serve' 2>/dev/null || true
" || true

echo "=== Stopping head container ==="
sudo docker rm -f vllm_anemll 2>/dev/null || true
sudo pkill -9 -f "vllm serve" 2>/dev/null || true

echo "=== Done ==="
