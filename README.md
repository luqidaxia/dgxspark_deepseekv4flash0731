# Dual DGX Spark Deployment: DeepSeek V4 Flash 0731

Run **DeepSeek V4 Flash 0731** (NVFP4 quantized, 1M context) across **two NVIDIA DGX Spark** (GB10, 288GB) workstations interconnected via **RoCE** (RDMA over Converged Ethernet).

> 🇨🇳 **中文版 / Chinese version:** [Gitee Mirror](https://gitee.com/alexlu0912_admin/dgxspark_deepseekv4flash0731)

---

## Hardware Topology

```
┌──────────────────────────┐    RoCE (enp1s0f0np0, MTU 9000)     ┌──────────────────────────┐
│   DGX Spark #1 (Head)    │◄───────────────────────────────────►│   DGX Spark #2 (Worker)  │
│   Mgmt: 192.168.21.234   │                                     │   Mgmt: 192.168.22.161   │
│   RoCE: 10.10.12.11      │                                     │   RoCE: 10.10.12.21      │
│   GPU: 1× GB10 (288 GB)  │                                     │   GPU: 1× GB10 (288 GB)  │
└──────────────────────────┘                                     └──────────────────────────┘
```

- **TP=2** across 2 GB10 GPUs (1 per node), **PP=1**, **NNODES=2**
- **Network**: RoCE v2 over InfiniBand (`enp1s0f0np0`, GID_INDEX=5, MTU 9000)
- **Model**: DeepSeek V4 Flash 0731 (NVFP4 quantized, 1M token context)

---

## Directory Structure

```
dgxspark_deepseekv4flash0731/
├── README.md                # This file (English)
├── README.zh-CN.md          # Chinese version
├── deploy/                  # ✅ Recommended — latest dual-node deploy scripts
│   ├── config.sh            #    Configuration (image, model path, IPs)
│   ├── prepare.sh           #    Environment setup (interactive menu)
│   ├── start-head.sh        #    Head node startup script
│   ├── start-worker.sh      #    Worker node startup script
│   └── README.md            #    Detailed deployment guide
├── legacy/                  # Legacy reference files from dsv4dspark
│   ├── setup-roce.sh        #    RoCE network auto-config
│   ├── preflight.sh         #    Pre-deployment checks
│   ├── start-all.sh         #    One-click orchestration
│   ├── docker-compose.yml   #    Docker Compose config
│   ├── benchmark-matrix.py  #    Performance benchmark tool
│   ├── *.env                #    Environment variable templates
│   └── *.md                 #    Legacy docs
├── vllm-args.md             # vLLM parameter reference
└── troubleshooting.md       # Troubleshooting guide
```

---

## Quick Start

### Prerequisites

| Item | Details |
|------|---------|
| Docker Image | `ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1` |
| Model Weights | `DeepSeek-V4-Flash-0731` full directory, same path on both nodes |
| OS | DGX Spark (NVIDIA GB10, 288GB), Ubuntu 24.04+, with NVIDIA drivers/docker/nvidia-container-toolkit |

### 1. Environment Setup (Interactive Menu)

```bash
cd deploy && bash prepare.sh
```

Menu options:
```
1) Pull Docker image      (~20 GB)
2) Download model weights  (~156 GB, ModelScope)
3) Configure RoCE network  (IP + MTU)
9) Run all
```

### 2. Configuration

Edit `deploy/config.sh`:

```bash
IMAGE="ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1"
MODEL_PATH="/data/models/deepseek-ai/DeepSeek-V4-Flash-0731"
HEAD_IP="10.10.12.11"          # Head RoCE IP
```

### 3. Configure RoCE Network

On both nodes, configure the QSFP port (`enp1s0f0np0`):

```bash
# Head (spark-3e35)
ip addr add 10.10.12.11/24 dev enp1s0f0np0
ip link set enp1s0f0np0 mtu 9000

# Worker (spark-cefb)
ip addr add 10.10.12.21/24 dev enp1s0f0np0
ip link set enp1s0f0np0 mtu 9000

# Verify bidirectional connectivity
ping 10.10.12.21   # from Head
ping 10.10.12.11   # from Worker
```

### 4. Launch

```bash
# Start Worker first
cd deploy && bash start-worker.sh

# Then start Head
cd deploy && bash start-head.sh
```

### 5. Verify Deployment

#### 5.1 Health Check — Model List

```bash
curl -s http://${HEAD_IP}:8888/v1/models | python3 -m json.tool
```

Expected:
```json
{
  "object": "list",
  "data": [{ "id": "deepseek-v4-flash", "object": "model", "owned_by": "vllm" }]
}
```

> ❌ If `Connection refused`: wait for Head to finish loading (~5-10 min), check `docker logs -f vllm_anemll | grep "Ulysses"`.

#### 5.2 Basic Chat Test

```bash
curl -s http://${HEAD_IP}:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "Explain quantum computing in one sentence."}],
    "max_tokens": 128,
    "temperature": 0.6
  }' | python3 -m json.tool
```

#### 5.3 Streaming Test

```bash
curl -s http://${HEAD_IP}:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "Write a haiku about AI."}],
    "max_tokens": 200,
    "stream": true
  }'
```

#### 5.4 Throughput Benchmark

```bash
# Single request latency
curl -s -o /dev/null -w "TTFT: %{time_starttransfer}s | Total: %{time_total}s\n" \
  http://${HEAD_IP}:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "Explain quantum entanglement in detail."}],
    "max_tokens": 500
  }'

# Concurrent load test (requires vllm benchmark tools)
pip install vllm 2>/dev/null
vllm bench serve \
  --host ${HEAD_IP} --port 8888 \
  --model deepseek-v4-flash \
  --num-prompts 20 --request-rate 2 \
  --tokenizer deepseek-ai/DeepSeek-V4-Flash-0731
```

Expected benchmarks (TP=2 dual-node):

| Metric | Value |
|--------|-------|
| Time to First Token (TTFT) | ~1s |
| Throughput (single 500-token request) | **40-60 tok/s** |
| End-to-end latency (500 tokens) | ~10-15s |

#### 5.5 Verify NCCL Communication

```bash
docker logs vllm_anemll 2>&1 | grep -E "NCCL.*comm|NCCL.*rank|NCCL.*Channel"
# Expected: rank 0 nranks 2 (two nodes connected)
```

> If only `rank 0 nranks 1` appears, Worker failed to join — check Worker logs and RoCE connectivity.

#### 5.6 Monitoring Quick Reference

```bash
docker exec vllm_anemll nvidia-smi           # GPU utilization
docker logs -f vllm_anemll                    # Real-time logs
docker stats vllm_anemll                      # Container resource usage
docker logs vllm_anemll 2>&1 | grep -i "worker\|node_rank.*1"  # Worker status
```

#### 5.7 Common Verification Failures

| Symptom | Cause | Solution |
|---------|-------|----------|
| `curl` no response | Head still loading | Wait 5-10 min, check for `Ulysses model is ready` in logs |
| `model not found` | Wrong served-model-name | Use `deepseek-v4-flash` |
| Garbled output | tokenizer not loaded | Check `--tokenizer-mode deepseek_v4` |
| Very low speed (<10 tok/s) | Worker offline or NCCL degraded | Check Worker logs + RoCE |
| `context length exceeds` | Input exceeds limit | Default 1M context, check input size |

---

## Lessons Learned

| Issue | Symptom | Root Cause | Fix |
|-------|---------|------------|-----|
| **NODE_RANK conflict** | Worker times out after 5 min | Both set to `--node-rank 0` | Worker must be `--node-rank 1` |
| **Missing `/cache/huggingface` mount** | JIT recompiles every restart | flashinfer autotune cache lost | Mount host directory for persistence |
| **Missing `--gpus all`** | `Failed to infer device type` | No GPU visible in container | Always add `--gpus all` |
| **`-p` + `--network host` conflict** | Port mapping ignored | Docker ignores `-p` in host mode | Use iptables REDIRECT |
| **RoCE IP cleared by NetworkManager** | IP lost after reboot | NM not set to unmanaged | `nmcli dev set enp1s0f0np0 managed no` |
| **Wrong GID_INDEX** | NCCL GID error | MTU not 9000 | Script auto-detects; MTU=1500 → GID=3 |

### Performance (Measured)

GPU memory: 288 GB/card, actual usage ~79 GB (~27%), 200 GB+ remaining for KV Cache and 1M context.

| Scenario | Throughput | TTFT | Memory |
|----------|-----------|------|--------|
| Code generation (500 tokens) | **~61 tok/s** | ~960ms | 79 GB/GPU |
| Long text generation (500 tokens) | ~45 tok/s | ~1s | 79 GB/GPU |

---

## Key vLLM Parameters

### Context Length: `--max-model-len 1048576`

Model natively supports 1M token context (`max_position_embeddings: 1048576` in `config.json`, extended 16× from 65536 via YaRN). No sliding window or extrapolation tricks needed.

### GPU Memory: `--gpu-memory-utilization 0.78`

**This is the safety ceiling, not actual usage.** vLLM won't pre-allocate full memory below 0.78; actual usage is ~79 GB (27%). Remaining space goes to KV Cache for 1M context + 6 concurrent requests.

| Value | Effect |
|-------|--------|
| 0.78 (current) | Ceiling ~224 GB, actual 79 GB, safe |
| 0.75 | Minimum viable; lower may be rejected |
| 0.85 | More aggressive; may OOM at peak concurrency |

### Concurrency: `--max-num-seqs 6`

Maximum 6 concurrent requests. Current memory usage is only 79 GB with 200 GB+ headroom:

| Value | Use Case | Memory Pressure |
|-------|----------|-----------------|
| 6 (current) | Low concurrency, stable long context | Very low |
| 8-10 | Medium concurrency | Safe, 100 GB+ headroom |
| 12+ | High concurrency | Needs testing; KV Cache grows significantly at 1M context |

### Full Parameter Reference

```bash
--tensor-parallel-size 2          # TP=2 across 2 GPUs (1 per node)
--pipeline-parallel-size 1        # PP=1
--nnodes 2                        # 2 nodes
--kv-cache-dtype nvfp4_ds_mla     # NVFP4 4-bit MLA KV Cache (memory saving)
--block-size 256                  # KV Cache block size
--max-model-len 1048576           # 1M token context (native YaRN)
--max-num-seqs 6                  # Max concurrent (safe to 8-10)
--max-num-batched-tokens 8192     # Prefill batch (small chunks save memory)
--gpu-memory-utilization 0.78     # Memory safety ceiling (~79GB/288GB)
--enable-chunked-prefill          # Chunk long prompts to avoid prefill OOM
--enable-prefix-caching           # Reuse KV Cache for shared prefixes
--speculative-config dspark       # DGX Spark hardware speculative decode
--moe-backend flashinfer_b12x     # B300 GB10-specific MoE backend
```

---

## NCCL Configuration

Dual-node inference depends on **NCCL** over RoCE for cross-node GPU communication.

### Why `--network host` is Mandatory

```
Container net stack  ──NCCL RDMA──►  Physical NIC (enp1s0f0np0)
     ↑                                    ↑
  Bridge mode:                         RoCE requires direct
  RDMA cannot NAT                      physical HCA access
```

NCCL's RDMA data path needs direct physical NIC access. Docker bridge/NAT virtual IPs cause `mlx5` HCA binding failures. `--network host` is the only reliable approach.

### NCCL Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `NCCL_IB_GID_INDEX` | `5` (MTU=9000) / `3` (MTU=1500) | RoCE GID routing table index |
| `NCCL_IB_HCA` | `rocep1s0f0` | HCA device to use |
| `NCCL_NET` | `IB` | Force IB/RoCE transport |
| `NCCL_IB_ROCE_VERSION_NUM` | `2` | RoCE v2 (UDP encapsulation) |
| `NCCL_CROSS_NIC` | `1` | Allow cross-NIC (single-card compat) |
| `NCCL_CUMEM_ENABLE` | `0` | Disable CUDA mempool (GB10 compat) |
| `NCCL_NVLS_ENABLE` | `0` | Disable NVLink Sharp (GB10 unsupported) |
| `NCCL_IGNORE_CPU_AFFINITY` | `1` | Ignore CPU affinity (container required) |
| `NCCL_DEBUG` | `WARN` | Log level (use `INFO` for debugging) |
| `NCCL_IB_ADDR_FAMILY` | `AF_INET` | Force IPv4 |
| `NCCL_SOCKET_IFNAME` | `enp1s0f0np0` | NCCL communication interface |
| `GLOO_SOCKET_IFNAME` | `enp1s0f0np0` | Gloo communication interface |
| `TP_SOCKET_IFNAME` | `enp1s0f0np0` | PyTorch TP communication interface |

### GID_INDEX Selection Logic

```
       ┌── MTU == 9000? ──► GID_INDEX=5  (RoCE v2, jumbo frames)
Check ─┤
       └── MTU != 9000? ──► GID_INDEX=3  (RoCE v1 fallback)
```

### NCCL Initialization Flow

```
1. Head starts → vLLM loads model weights (~150s)
2. Worker starts → vLLM loads weights, waits for Head
3. Head finishes → NCCL init handshake (Head ↔ Worker)
   ├─ TCP handshake (MASTER_ADDR:MASTER_PORT)
   ├─ GLOO topology discovery (GLOO_SOCKET_IFNAME)
   └─ NCCL IB connection (NCCL_SOCKET_IFNAME + IB_GID_INDEX)
4. Both nodes assigned NCCL rank → sync complete → inference begins
```

> ⚠️ **Critical**: Head `NODE_RANK=0`, Worker `NODE_RANK=1`. Both must be unique.

### NCCL Debugging

```bash
# Check RoCE devices
ibv_devinfo
ibv_devinfo -d rocep1s0f0 -v | grep GID

# View GID table
show_gids | grep -A3 "rocep1s0f0"

# Verbose NCCL logging
docker run ... -e NCCL_DEBUG=INFO -e NCCL_DEBUG_SUBSYS=NET,INIT ...
```

### Common NCCL Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `Got completion with error` | RoCE link down / loose cable | Check physical + bidirectional ping |
| `GID index not found` | Wrong GID_INDEX | Use `show_gids`; MTU 1500 → 3 |
| `NCCL timeout` | Worker NODE_RANK=0 | Change Worker to `--node-rank 1` |
| `Socket connection refused` | Worker connecting before Head ready | Wait for Head to finish loading |
| `mlx5_0:1 got error from peer` | One-way connectivity | Check firewall, bidirectional ping |

---

## Obtaining Model Weights

### Option 1: HuggingFace (Recommended)

```bash
pip install huggingface_hub
huggingface-cli download deepseek-ai/DeepSeek-V4-Flash-0731 \
  --local-dir /data/models/deepseek-ai/DeepSeek-V4-Flash-0731
```

> **Note**: Model is NVFP4 quantized, ~**156 GB**. Reserve 200 GB+ disk space. Both nodes need the same path.

### Option 2: ModelScope (Faster in China)

```bash
pip install modelscope
modelscope download --model deepseek-ai/DeepSeek-V4-Flash-0731 \
  --local_dir /data/models/deepseek-ai/DeepSeek-V4-Flash-0731
```

### Sync to Worker Node

```bash
# From Head, transfer over RoCE
rsync -avz --progress \
  /data/models/deepseek-ai/DeepSeek-V4-Flash-0731/ \
  root@10.10.12.21:/data/models/deepseek-ai/DeepSeek-V4-Flash-0731/
```

---

## Author

[@alexlu0912_admin](https://gitee.com/alexlu0912_admin)

---

## License

MIT
