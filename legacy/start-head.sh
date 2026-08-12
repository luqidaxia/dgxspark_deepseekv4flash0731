#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

# Start the vLLM Head node on spark-3e35.
# This script is meant to be run directly on the head node.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/head.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# 动态计算 NCCL_IB_GID_INDEX：用 show_gids 找到 RoCE IP 对应的 v2 GID index。
# 这比在 env 里写死更稳，因为 NetworkManager 连接变化后 GID 表顺序会变。
if command -v show_gids >/dev/null 2>&1; then
  DYNAMIC_GID=$(show_gids 2>/dev/null | awk -v dev="${NCCL_IB_HCA:-rocep1s0f0}" -v ip="${VLLM_HOST_IP}" '$1==dev && $5==ip && $6=="v2" {print $3}')
  if [[ -n "$DYNAMIC_GID" ]]; then
    NCCL_IB_GID_INDEX="$DYNAMIC_GID"
  fi
fi

echo "=== Using NCCL_IB_GID_INDEX=$NCCL_IB_GID_INDEX ==="

CONTAINER_NAME="vllm_anemll"
IMAGE="${DSPARK_VLLM_IMAGE:-ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1}"
MODEL_HOST="${DSPARK_MODEL_HOST:-/data/models/deepseek-ai/DeepSeek-V4-Flash-0731}"
HF_CACHE="${HF_CACHE:-/root/.cache/huggingface}"
TMP_HOST="${DSPARK_TMP_HOST:-/var/lib/dspark-tmp}"

echo "=== Cleaning up stale container/processes ==="
sudo docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
sudo pkill -9 -f "vllm serve" 2>/dev/null || true

echo "=== Ensuring network prerequisites ==="
sudo ip link set mtu 9000 dev "${NCCL_SOCKET_IFNAME}" || true
sudo nmcli dev set "${NCCL_SOCKET_IFNAME}" managed no 2>/dev/null || true

echo "=== Preparing directories ==="
mkdir -p "$HF_CACHE" "$TMP_HOST"

echo "=== Starting vLLM Head container ==="
# shellcheck disable=SC2086
sudo docker run -d --name "$CONTAINER_NAME" \
  --entrypoint bash \
  --gpus all --ipc host --net host --privileged \
  --shm-size=64gb \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  --device /dev/infiniband:/dev/infiniband \
  -v "${MODEL_HOST}:/models/dsv4-abliterated:ro" \
  -v "${HF_CACHE}:/cache/huggingface" \
  -v "${TMP_HOST}:/tmp" \
  -e NODE_RANK=0 \
  -e HEADLESS= \
  -e MASTER_ADDR="${MASTER_ADDR}" \
  -e MASTER_PORT="${MASTER_PORT:-25000}" \
  -e VLLM_HOST_IP="${VLLM_HOST_IP}" \
  -e NCCL_IB_HCA="${NCCL_IB_HCA}" \
  -e NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME}" \
  -e TP_SOCKET_IFNAME="${TP_SOCKET_IFNAME}" \
  -e GLOO_SOCKET_IFNAME="${GLOO_SOCKET_IFNAME}" \
  -e NCCL_IB_GID_INDEX="${NCCL_IB_GID_INDEX}" \
  -e NCCL_IB_ADDR_FAMILY="${NCCL_IB_ADDR_FAMILY:-AF_INET}" \
  -e NCCL_IB_ROCE_VERSION_NUM="${NCCL_IB_ROCE_VERSION_NUM:-2}" \
  -e NCCL_CROSS_NIC="${NCCL_CROSS_NIC:-1}" \
  -e NCCL_CUMEM_ENABLE=0 \
  -e NCCL_IGNORE_CPU_AFFINITY=1 \
  -e NCCL_NVLS_ENABLE=0 \
  -e NCCL_NET=IB \
  -e NCCL_DEBUG=WARN \
  -e HF_HOME=/cache/huggingface \
  -e HF_HUB_DISABLE_XET=1 \
  -e VLLM_CACHE_ROOT=/cache/huggingface/vllm-cache \
  -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \
  -e VLLM_TRITON_MLA_SPARSE=1 \
  -e VLLM_USE_FLASHINFER_SAMPLER=1 \
  -e VLLM_USE_B12X_MOE=1 \
  -e VLLM_USE_B12X_WO_PROJECTION=1 \
  -e VLLM_DSPARK_LOCAL_ARGMAX=1 \
  -e VLLM_DSPARK_REPLICATE_MARKOV_W1=1 \
  -e VLLM_DSPARK_GPU_REJECTED_CONTEXT_MASK=1 \
  -e VLLM_DSPARK_HARDWARE_SCHEDULER_EARLY_STOP=1 \
  -e DSPARK_SLOT_CLAMP=1 \
  -e DG_JIT_USE_NVRTC=0 \
  -e DG_JIT_NVCC_COMPILER=/usr/local/cuda/bin/nvcc \
  -e TORCH_CUDA_ARCH_LIST=12.1a \
  -e FLASHINFER_CUDA_ARCH_LIST=12.1a \
  -e FLASHINFER_DISABLE_VERSION_CHECK=1 \
  -e FLASHINFER_WORKSPACE_BASE=/cache/huggingface/flashinfer \
  -e TILELANG_CLEANUP_TEMP_FILES=1 \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  -e VLLM_SKIP_INIT_MEMORY_CHECK=1 \
  -e VLLM_SPARSE_INDEXER_MAX_LOGITS_MB=256 \
  -e VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0 \
  "$IMAGE" \
  -lc '
    export PATH="/usr/local/cuda/bin:${PATH:-}";
    export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}";
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}";
    SPECULATIVE_CONFIG="{\"method\":\"dspark\",\"num_speculative_tokens\":5,\"draft_sample_method\":\"probabilistic\"}";
    exec vllm serve /models/dsv4-abliterated \
      --served-model-name deepseek-v4-flash \
      --host 0.0.0.0 --port 8888 \
      --trust-remote-code \
      --tensor-parallel-size 2 --pipeline-parallel-size 1 \
      --kv-cache-dtype nvfp4_ds_mla \
      --block-size 256 \
      --max-model-len 350000 \
      --max-num-seqs 12 \
      --max-num-batched-tokens 8192 \
      --max-cudagraph-capture-size 72 \
      --gpu-memory-utilization 0.78 \
      --enable-prefix-caching \
      --async-scheduling \
      --enable-chunked-prefill \
      --speculative-config "$SPECULATIVE_CONFIG" \
      --tokenizer-mode deepseek_v4 \
      --distributed-executor-backend mp \
      --moe-backend flashinfer_b12x \
      --tool-call-parser deepseek_v4 \
      --enable-auto-tool-choice \
      --reasoning-parser deepseek_v4 \
      --reasoning-config '\''{"reasoning_parser":"deepseek_v4","reasoning_start_str":"","reasoning_end_str":""}'\'' \
      --default-chat-template-kwargs '\''{"thinking":false}'\'' \
      --generation-config vllm \
      --enable-flashinfer-autotune \
      --nnodes 2 --node-rank 0 \
      --master-addr "${MASTER_ADDR}" --master-port "${MASTER_PORT}" \
      --jit-monitor-mode warn \
      > /tmp/vllm-head.log 2>&1
  '

echo "=== Head container started: $CONTAINER_NAME ==="
sudo docker ps --filter name="$CONTAINER_NAME" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
