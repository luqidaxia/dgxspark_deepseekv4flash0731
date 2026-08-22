#!/bin/bash
# ============================================================
# DeepSeek V4 Flash — TP=2 分两组 — 组B: node03 (head, rank 0)
# 组B = node03 + node04 (TP=2, nnodes=2)
# 启动顺序: 先启动 node04 (worker)，再启动本 head 脚本
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

NODE_RANK=0
VLLM_HOST_IP="$GROUP_B_MASTER_ADDR"
MASTER_ADDR="$GROUP_B_MASTER_ADDR"
MASTER_PORT="$GROUP_B_MASTER_PORT"
API_PORT="$GROUP_B_API_PORT"
HEADLESS=""

echo "========================================"
echo " DeepSeek V4 Flash - 组B node03 (head, rank 0, TP=2)"
echo "========================================"

# --- 预检查 ---
if [ ! -d "$MODEL_PATH" ]; then
    echo "❌ 模型路径不存在: $MODEL_PATH"; exit 1
fi
if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "❌ Docker 镜像不存在: $IMAGE"; exit 1
fi
if ! ip link show "$NCCL_INTF" &>/dev/null; then
    echo "❌ RoCE 网卡 $NCCL_INTF 不存在"; exit 1
fi
echo "✅ 预检查通过"

# --- 缓存目录 ---
mkdir -p "$HF_CACHE" "$TMP_DIR"

# --- 停止旧容器 ---
docker rm -f vllm_anemll 2>/dev/null || true

# --- 启动 head 容器 ---
echo "🚀 启动 组B node03 (head, rank 0, TP=2)..."
echo "   MASTER=$MASTER_ADDR:$MASTER_PORT  API_PORT=$API_PORT"

docker run -d --name vllm_anemll \
    --privileged --network host --ipc host --gpus all \
    --device /dev/infiniband --ulimit memlock=-1 \
    -v "$MODEL_PATH:$MODEL_MOUNT:ro" \
    -v "$HF_CACHE:/cache/huggingface" \
    -v "$TMP_DIR:/tmp" \
    -e MASTER_ADDR="$MASTER_ADDR" -e MASTER_PORT="$MASTER_PORT" -e NODE_RANK="$NODE_RANK" \
    -e VLLM_HOST_IP="$VLLM_HOST_IP" \
    -e NCCL_IB_GID_INDEX="$NCCL_IB_GID_INDEX" -e NCCL_IB_HCA="$NCCL_IB_HCA" -e NCCL_NET=IB \
    -e NCCL_IB_ROCE_VERSION_NUM=2 -e NCCL_CROSS_NIC=1 -e NCCL_IB_TC="$NCCL_IB_TC" \
    -e NCCL_DEBUG=WARN -e NCCL_SOCKET_IFNAME="$NCCL_INTF" \
    -e GLOO_SOCKET_IFNAME="$NCCL_INTF" -e TP_SOCKET_IFNAME="$NCCL_INTF" \
    -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 -e VLLM_SKIP_INIT_MEMORY_CHECK=1 \
    -e VLLM_USE_B12X_MOE=1 -e VLLM_TRITON_MLA_SPARSE=1 \
    -e VLLM_USE_FLASHINFER_SAMPLER=1 -e VLLM_SPARSE_INDEXER_MAX_LOGITS_MB=256 \
    -e VLLM_DSPARK_GPU_REJECTED_CONTEXT_MASK=1 \
    -e VLLM_DSPARK_HARDWARE_SCHEDULER_EARLY_STOP=1 \
    -e VLLM_DSPARK_LOCAL_ARGMAX=1 -e VLLM_DSPARK_REPLICATE_MARKOV_W1=1 \
    -e DG_JIT_NVCC_COMPILER=/usr/local/cuda/bin/nvcc -e DG_JIT_USE_NVRTC=0 \
    -e DSPARK_SLOT_CLAMP=1 -e TILELANG_CLEANUP_TEMP_FILES=1 \
    -e FLASHINFER_CUDA_ARCH_LIST=12.1a -e FLASHINFER_DISABLE_VERSION_CHECK=1 \
    -e FLASHINFER_WORKSPACE_BASE=/cache/huggingface/flashinfer \
    -e HF_HUB_DISABLE_XET=1 -e VLLM_CACHE_ROOT=/cache/huggingface/vllm-cache \
    -e NVARCH=sbsa \
    "$IMAGE" \
    "$MODEL_MOUNT" \
        --served-model-name "$SERVED_NAME" --host 0.0.0.0 --port "$API_PORT" \
        --trust-remote-code --tensor-parallel-size "$TP_SIZE" --pipeline-parallel-size "$PP_SIZE" \
        --kv-cache-dtype nvfp4_ds_mla --block-size "$BLOCK_SIZE" --max-model-len "$MAX_MODEL_LEN" \
        --max-num-seqs "$MAX_NUM_SEQS" --max-num-batched-tokens "$MAX_BATCHED_TOKENS" \
        --max-cudagraph-capture-size "$MAX_CUDAGRAPH" --gpu-memory-utilization "$GPU_MEM" \
        --enable-prefix-caching --async-scheduling --enable-chunked-prefill \
        --speculative-config '{"method":"dspark","num_speculative_tokens":5,"draft_sample_method":"probabilistic"}' \
        --tokenizer-mode deepseek_v4 --distributed-executor-backend mp \
        --moe-backend flashinfer_b12x --tool-call-parser deepseek_v4 \
        --enable-auto-tool-choice --reasoning-parser deepseek_v4 \
        --reasoning-config '{"reasoning_parser":"deepseek_v4","reasoning_start_str":"","reasoning_end_str":""}' \
        --default-chat-template-kwargs '{"thinking":false}' \
        --generation-config vllm --enable-flashinfer-autotune \
        --nnodes "$NNODES" --node-rank "$NODE_RANK" --master-addr "$MASTER_ADDR" --master-port "$MASTER_PORT" \
        $HEADLESS --jit-monitor-mode warn

echo ""
echo "✅ 组B node03 (head, rank 0, TP=2) 已启动 (容器 vllm_anemll)"
echo "📊 日志: docker logs -f vllm_anemll"
echo "🔌 API: http://${MASTER_ADDR}:${API_PORT}/v1"
echo "   就绪标志: docker logs vllm_anemll 2>&1 | grep 'Application startup complete'"
