#!/bin/bash
# ============================================================
# DeepSeek V4 Flash 4 节点 TP=4 — node02 (worker, rank 1)
# 用法: bash node02.sh
# 前提: 1) 镜像已就位  2) 模型权重已就位  3) config.sh 已配置
# ⚠️ Worker 应先于 Head 启动，等待 Head 加入
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

NODE_RANK=1
NODE_NAME="node02"

echo "========================================"
echo " DeepSeek V4 Flash - $NODE_NAME (worker, rank $NODE_RANK)"
echo "========================================"

# --- 1. 预检查 ---
if [ ! -d "$MODEL_PATH" ]; then
    echo "❌ 模型路径不存在: $MODEL_PATH"
    echo "   请修改 config.sh 中的 MODEL_PATH"
    exit 1
fi
echo "✅ 模型路径: $MODEL_PATH"

if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "❌ Docker 镜像不存在: $IMAGE"
    echo "   请先 docker load 或 docker pull $IMAGE"
    exit 1
fi
echo "✅ Docker 镜像: $IMAGE"

# --- 2. 检测 NCCL_IB_GID_INDEX ---
if ip link show "$NCCL_INTF" &>/dev/null; then
    MTU=$(ip link show "$NCCL_INTF" | grep -oP 'mtu \K[0-9]+')
    if [ "$MTU" = "9000" ]; then
        GID_INDEX=5
    else
        GID_INDEX=3
    fi
    echo "✅ RoCE 网卡: $NCCL_INTF (MTU=$MTU → GID_INDEX=$GID_INDEX)"
else
    echo "❌ RoCE 网卡 $NCCL_INTF 不存在，请修改 config.sh 中的 NCCL_INTF"
    exit 1
fi

# --- 3. 创建缓存目录 ---
mkdir -p "$HF_CACHE" "$TMP_DIR"
echo "✅ 缓存目录已就绪"

# --- 4. 停止旧容器 ---
if docker ps -a --format '{{.Names}}' | grep -q "^vllm_anemll$"; then
    echo "⏳ 停止旧容器..."
    docker rm -f vllm_anemll 2>/dev/null || true
    echo "✅ 旧容器已清理"
fi

# --- 5. 启动 worker 容器 ---
echo "🚀 启动 $NODE_NAME (worker, rank $NODE_RANK)..."
echo "   VLLM_HOST_IP=$NODE02_IP  →  Head: ${MASTER_ADDR}:${MASTER_PORT}"
echo ""

docker run -d --name vllm_anemll \
    --privileged --network host --ipc host --gpus all \
    --device /dev/infiniband --ulimit memlock=-1 \
    -v "$MODEL_PATH:$MODEL_MOUNT:ro" \
    -v "$HF_CACHE:/cache/huggingface" \
    -v "$TMP_DIR:/tmp" \
    -e MASTER_ADDR="$MASTER_ADDR" -e MASTER_PORT="$MASTER_PORT" -e NODE_RANK="$NODE_RANK" \
    -e VLLM_HOST_IP="$NODE02_IP" \
    -e NCCL_IB_GID_INDEX="$GID_INDEX" -e NCCL_IB_HCA="$NCCL_IB_HCA" -e NCCL_NET=IB \
    -e NCCL_IB_ROCE_VERSION_NUM=2 -e NCCL_CROSS_NIC=1 \
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
        --served-model-name "$SERVED_NAME" --host 0.0.0.0 --port "$PORT" \
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
        --nnodes 4 --node-rank "$NODE_RANK" --master-addr "$MASTER_ADDR" --master-port "$MASTER_PORT" \
        --headless --jit-monitor-mode warn

echo ""
echo "✅ $NODE_NAME (worker) 已启动 (容器: vllm_anemll)"
echo ""
echo "📊 查看日志: docker logs -f vllm_anemll"
echo ""
echo "⏳ Worker 将等待 Head 节点启动后完成 NCCL 建连..."
echo "   查看状态: docker logs vllm_anemll 2>&1 | grep -E 'NCCL|world_size|rank'"
