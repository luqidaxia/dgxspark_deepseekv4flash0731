#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

# Orchestrate the two-node vLLM deployment from the head node.
# Defaults are for: head=spark-3e35, worker=spark-cefb (192.168.22.161)
# Usage: ./start-all.sh [WORKER_SSH]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER_SSH="${1:-root@192.168.22.161}"
WORKER_PASS="${WORKER_PASS:-YOUR_WORKER_PASSWORD}"
HEAD_START_SCRIPT="${SCRIPT_DIR}/start-head.sh"
WORKER_START_SCRIPT="${SCRIPT_DIR}/start-worker.sh"
ENV_WORKER="${SCRIPT_DIR}/worker.env"
ENV_HEAD="${SCRIPT_DIR}/head.env"
PREFLIGHT_SCRIPT="${SCRIPT_DIR}/preflight.sh"
SETUP_ROCE_SCRIPT="${SCRIPT_DIR}/setup-roce.sh"

if [[ ! -f "$WORKER_START_SCRIPT" || ! -f "$HEAD_START_SCRIPT" ]]; then
  echo "Missing start-head.sh or start-worker.sh" >&2
  exit 1
fi

echo "=== Step 0: Preflight check ==="
if [[ -x "$PREFLIGHT_SCRIPT" ]]; then
  if ! bash "$PREFLIGHT_SCRIPT" "$WORKER_SSH"; then
    echo ""
    echo "预检未通过。尝试自动修复 RoCE 配置..."
    if [[ -x "$SETUP_ROCE_SCRIPT" ]]; then
      bash "$SETUP_ROCE_SCRIPT" "$WORKER_SSH"
      echo ""
      echo "重新运行预检..."
      if ! bash "$PREFLIGHT_SCRIPT" "$WORKER_SSH"; then
        echo "❌ 预检仍失败，请手动检查 RoCE 网络后重试。" >&2
        exit 1
      fi
    else
      echo "❌ setup-roce.sh 不存在，无法自动修复。" >&2
      exit 1
    fi
  fi
else
  echo "preflight.sh 不存在，跳过预检"
fi

echo ""

# Helper: run command on worker via sshpass+ssh
worker_exec() {
  sshpass -p "$WORKER_PASS" ssh -o StrictHostKeyChecking=no "$WORKER_SSH" "$@"
}

# Helper: copy local file/dir to worker
worker_scp() {
  local src="$1"
  local dst="$2"
  sshpass -p "$WORKER_PASS" scp -o StrictHostKeyChecking=no -r "$src" "$WORKER_SSH:$dst"
}

echo "=== Step 1: Push scripts/env to worker ==="
worker_exec "mkdir -p /root/dsv4dspark"
worker_scp "$WORKER_START_SCRIPT" /root/dsv4dspark/start-worker.sh
worker_scp "$ENV_WORKER" /root/dsv4dspark/worker.env

echo "=== Step 2: Start Worker (remote) ==="
worker_exec "chmod +x /root/dsv4dspark/start-worker.sh && bash /root/dsv4dspark/start-worker.sh" &
WORKER_PID=$!

echo "=== Step 3: Wait 5s then start Head ==="
sleep 5
bash "$HEAD_START_SCRIPT"

echo "=== Step 4: Wait for worker bootstrap ==="
wait "$WORKER_PID" || true

echo ""
echo "=== Both containers launched ==="
echo "Head:"
sudo docker ps --filter name=vllm_anemll --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
echo ""
echo "Worker:"
worker_exec "sudo docker ps --filter name=vllm_anemll --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"

echo ""
echo "=== Polling for 'Application startup complete' (timeout 25 min) ==="
for i in $(seq 1 150); do
  if sudo docker exec vllm_anemll grep -q "Application startup complete" /tmp/vllm-head.log 2>/dev/null; then
    echo "✅ API ready after ~$((i*10))s"
    break
  fi
  echo "  [$((i*10))s] still starting..."
  sleep 10
done

echo ""
echo "=== Quick check /v1/models ==="
curl -s "http://10.10.12.11:8888/v1/models" | python3 -m json.tool || true

echo ""
echo "Done. To test inference run: ./test-api.sh"
