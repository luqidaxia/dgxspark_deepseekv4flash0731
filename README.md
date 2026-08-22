# Dual DGX Spark Deployment: DeepSeek V4 Flash 0731

> 🌿 **分支导航**
> - **`master`（本分支）**：双机 TP=2 部署 —— 见 `deploy/`
> - **`4node`**：4 台机器 TP=4 部署 —— 见 [`4node/`](https://gitee.com/alexlu0912_admin/dgxspark_deepseekv4flash0731/tree/4node/4node)（单请求 ~103 tok/s，5 并发 ~157 tok/s）

Run **DeepSeek V4 Flash 0731** (NVFP4 quantized, 1M context) across **two NVIDIA DGX Spark** (GB10, 128GB unified memory each) workstations interconnected via **RoCE** (RDMA over Converged Ethernet).

> 🇨🇳 中文版见下方 | Gitee 镜像：[gitee.com/alexlu0912_admin/dgxspark_deepseekv4flash0731](https://gitee.com/alexlu0912_admin/dgxspark_deepseekv4flash0731)

---

## Hardware Topology

```
┌──────────────────────────┐    RoCE (enp1s0f0np0, MTU 9000)     ┌──────────────────────────┐
│   DGX Spark #1 (Head)    │◄───────────────────────────────────►│   DGX Spark #2 (Worker)  │
│   Mgmt: 192.168.21.234   │                                     │   Mgmt: 192.168.22.161   │
│   RoCE: 10.10.12.11      │                                     │   RoCE: 10.10.12.21      │
│   GPU: 1× GB10 (128 GB)  │                                     │   GPU: 1× GB10 (128 GB)  │
└──────────────────────────┘                                     └──────────────────────────┘
```

- **TP=2** across 2 GB10 GPUs (1 per node), **PP=1**, **NNODES=2**
- **Network**: RoCE v2 over InfiniBand (`enp1s0f0np0`, GID_INDEX=5, MTU 9000)
- **Model**: DeepSeek V4 Flash 0731 (NVFP4 quantized, 1M token context)

---

## Directory Structure

```
dgxspark_deepseekv4flash0731/
├── README.md                # This file (English + 中文)
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
| OS | DGX Spark (NVIDIA GB10, 128GB), Ubuntu 24.04+, with NVIDIA drivers/docker/nvidia-container-toolkit |

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
# Head
ip addr add 10.10.12.11/24 dev enp1s0f0np0
ip link set enp1s0f0np0 mtu 9000

# Worker
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

GB10 128 GB unified memory per node, actual model weight usage ~79 GB (~62%), ~49 GB remaining for KV Cache and 1M context.

| Scenario | Throughput | TTFT | Memory |
|----------|-----------|------|--------|
| Code generation (500 tokens) | **~61 tok/s** | ~960ms | 79 GB/node |
| Long text generation (500 tokens) | ~45 tok/s | ~1s | 79 GB/node |

---

## Key vLLM Parameters

### Context Length: `--max-model-len 1048576`

Model natively supports 1M token context (`max_position_embeddings: 1048576` in `config.json`, extended 16× from 65536 via YaRN). No sliding window or extrapolation tricks needed.

### GPU Memory: `--gpu-memory-utilization 0.78`

**This is the safety ceiling, not actual usage.** vLLM won't pre-allocate full memory below 0.78; actual model weight usage is ~79 GB (~62% of 128 GB). Remaining ~49 GB goes to KV Cache for 1M context + 6 concurrent requests.

| Value | Effect |
|-------|--------|
| 0.78 (current) | Ceiling ~100 GB, actual ~79 GB, safe |
| 0.75 | Minimum viable; lower may be rejected |
| 0.85 | More aggressive; may OOM at peak concurrency |

### Concurrency: `--max-num-seqs 6`

Maximum 6 concurrent requests. Current model weight usage is ~79 GB with ~49 GB headroom:

| Value | Use Case | Memory Pressure |
|-------|----------|-----------------|
| 6 (current) | Low concurrency, stable long context | Very low |
| 8-10 | Medium concurrency | Safe, ~49 GB headroom |
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
--gpu-memory-utilization 0.78     # Memory safety ceiling (~79GB / 128GB unified)
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

---

---

# DGX Spark 双机部署 DeepSeek V4 Flash 0731

两台 NVIDIA DGX Spark (GB10，每节点 128 GB 统一内存) 通过 RoCE (RDMA over Converged Ethernet) 互联，运行 **DeepSeek V4 Flash 0731** (NVFP4 量化，1M 上下文)。

> 🇬🇧 English version above | GitHub 镜像：[github.com/luqidaxia/dgxspark_deepseekv4flash0731](https://github.com/luqidaxia/dgxspark_deepseekv4flash0731)

---

## 硬件拓扑

```
┌──────────────────────────┐    RoCE (enp1s0f0np0, MTU 9000)     ┌──────────────────────────┐
│   DGX Spark #1 (Head)    │◄───────────────────────────────────►│   DGX Spark #2 (Worker)  │
│   管理: 192.168.21.234   │                                     │   管理: 192.168.22.161   │
│   RoCE: 10.10.12.11      │                                     │   RoCE: 10.10.12.21      │
│   GPU: 1× GB10 (128 GB)  │                                     │   GPU: 1× GB10 (128 GB)  │
└──────────────────────────┘                                     └──────────────────────────┘
```

- **TP=2** 跨两块 GB10 GPU（每节点 1 块），**PP=1**，**NNODES=2**
- **网络**: RoCE v2 over InfiniBand (`enp1s0f0np0`, GID_INDEX=5, MTU 9000)
- **模型**: DeepSeek V4 Flash 0731 (NVFP4 量化, 1M token 上下文)

---

## 目录结构

```
dgxspark_deepseekv4flash0731/
├── README.md                # 本文件（中英双语）
├── deploy/                  # ✅ 推荐使用 — 最新双机部署脚本
│   ├── config.sh            #    配置文件 (镜像、模型路径、IP)
│   ├── prepare.sh           #    环境准备脚本 (交互式菜单)
│   ├── start-head.sh        #    Head 节点启动脚本
│   ├── start-worker.sh      #    Worker 节点启动脚本
│   └── README.md            #    详细部署说明书
├── legacy/                  # 旧版 dsv4dspark 参考文件
│   ├── setup-roce.sh        #    RoCE 网络自动配置
│   ├── preflight.sh         #    部署前预检
│   ├── start-all.sh         #    一键编排
│   ├── docker-compose.yml   #    Docker Compose 配置
│   ├── benchmark-matrix.py  #    性能测试
│   ├── *.env                #    环境变量模板
│   └── *.md                 #    旧版文档
├── vllm-args.md             # vLLM 参数详解
└── troubleshooting.md       # 故障排查指南
```

---

## 快速开始

### 前置条件

| 项目 | 说明 |
|------|------|
| Docker 镜像 | `ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1` |
| 模型权重 | `DeepSeek-V4-Flash-0731` 完整目录，两台节点同一路径 |
| 系统 | DGX Spark (NVIDIA GB10, 128GB 统一内存), Ubuntu 24.04+, 自带驱动/docker/nvidia-container-toolkit |

### 1. 环境准备（交互式菜单）

```bash
cd deploy && bash prepare.sh
```

菜单：
```
1) 拉取 Docker 镜像   (~20 GB)
2) 下载模型权重       (~156 GB, ModelScope)
3) 配置 RoCE 网络     (IP + MTU)
9) 一键全部执行
```

### 2. 配置

编辑 `deploy/config.sh`：

```bash
IMAGE="ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1"
MODEL_PATH="/data/models/deepseek-ai/DeepSeek-V4-Flash-0731"
HEAD_IP="10.10.12.11"          # Head 的 RoCE IP
```

### 3. 配置 RoCE 网络

两台节点配置 QSFP 口 (`enp1s0f0np0`)：

```bash
# Head
ip addr add 10.10.12.11/24 dev enp1s0f0np0
ip link set enp1s0f0np0 mtu 9000

# Worker
ip addr add 10.10.12.21/24 dev enp1s0f0np0
ip link set enp1s0f0np0 mtu 9000

# 验证互通
ping 10.10.12.21   # 从 Head
ping 10.10.12.11   # 从 Worker
```

### 4. 启动

```bash
# Worker 先启动
cd deploy && bash start-worker.sh

# Head 随后
cd deploy && bash start-head.sh
```

### 5. 验证部署

#### 5.1 模型列表

```bash
curl -s http://${HEAD_IP}:8888/v1/models | python3 -m json.tool
```

> ❌ 返回 `Connection refused`：等 Head 加载完成（约 5-10 分钟），`docker logs -f vllm_anemll | grep "Ulysses"` 出现即就绪。

#### 5.2 基础对话

```bash
curl -s http://${HEAD_IP}:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "你好，请用一句话介绍你自己"}],
    "max_tokens": 128,
    "temperature": 0.6
  }' | python3 -m json.tool
```

#### 5.3 流式输出

```bash
curl -s http://${HEAD_IP}:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "写一首五言绝句"}],
    "max_tokens": 200,
    "stream": true
  }'
```

#### 5.4 吞吐基准

```bash
# 单请求延迟
curl -s -o /dev/null -w "TTFT: %{time_starttransfer}s | Total: %{time_total}s\n" \
  http://${HEAD_IP}:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "解释量子纠缠"}],
    "max_tokens": 500
  }'
```

参考值：TTFT ~1s，吞吐 40-60 tok/s（500 token 输出）。

#### 5.5 验证 NCCL

```bash
docker logs vllm_anemll 2>&1 | grep -E "NCCL.*comm|NCCL.*rank|NCCL.*Channel"
# 预期：rank 0 nranks 2（两节点连接成功）
```

#### 5.6 监控速查

```bash
docker exec vllm_anemll nvidia-smi           # GPU 使用率
docker logs -f vllm_anemll                    # 实时日志
docker stats vllm_anemll                      # 容器资源占用
docker logs vllm_anemll 2>&1 | grep -i "worker\|node_rank.*1"  # Worker 在线状态
```

#### 5.7 常见验证失败

| 现象 | 原因 | 排查 |
|------|------|------|
| `curl` 无响应 | Head 尚未加载完 | 等 5-10 分钟，看日志是否出现 `Ulysses model is ready` |
| `model not found` | 模型名不匹配 | 使用 `deepseek-v4-flash` |
| 乱码/空白 | tokenizer 未加载 | 检查 `--tokenizer-mode deepseek_v4` |
| 速度 <10 tok/s | Worker 离线或 NCCL 降级 | 检查 Worker 日志 + RoCE |
| `context length exceeds` | 输入超限 | 默认 1M context，检查输入长度 |

---

## 踩坑经验

| 问题 | 现象 | 根因 | 解决 |
|------|------|------|------|
| **NODE_RANK 冲突** | Worker 5 分钟后超时退出 | Head 和 Worker 的 `--node-rank` 都设成 0 | Worker 必须 `--node-rank 1` |
| **缺少 `/cache/huggingface` 挂载** | 每次重启 JIT 编译超慢 | flashinfer autotune 缓存丢失 | 挂载 host 目录持久化 |
| **缺少 `--gpus all`** | `Failed to infer device type` | 容器内无 GPU 可见 | `docker run` 必须加 `--gpus all` |
| **`-p` + `--network host` 互斥** | 端口映射不生效 | Docker 在 host 网络模式下忽略 `-p` | 用 iptables REDIRECT |
| **RoCE IP 被 NetworkManager 清理** | 重启后 IP 丢失 | NM 未配置为 unmanaged | `nmcli dev set enp1s0f0np0 managed no` |
| **GID_INDEX 不对** | NCCL 报 GID 错误 | MTU 不是 9000 | 脚本自动检测，MTU=1500 时用 GID=3 |

### 实测性能

GB10 统一内存 128 GB/节点，实际模型权重占用 ~79 GB (~62%)，~49 GB 余量用于 KV Cache 和 1M 上下文。

| 场景 | 吞吐 | TTFT | 显存 |
|------|------|------|------|
| 代码生成 (500 tokens) | **~61 tok/s** | ~960ms | 79 GB/节点 |
| 长文本生成 (500 tokens) | ~45 tok/s | ~1s | 79 GB/节点 |

---

## vLLM 关键参数

### 上下文长度：`--max-model-len 1048576`

模型原生支持 1M token 上下文（`config.json` 中 `max_position_embeddings: 1048576`，通过 YaRN 从 65536 扩展 16 倍）。无需滑动窗口或外推技巧。

### 显存管理：`--gpu-memory-utilization 0.78`

**这是安全上限，不是实际占用。** vLLM 在 0.78 以下不会预分配全部显存；实际模型权重占用约 79 GB（128 GB 的 62%）。剩余 ~49 GB 全部用于 KV Cache，支撑 1M 上下文 + 6 并发。

| 值 | 效果 |
|------|------|
| 0.78（当前） | 上限 ~100 GB，实际 79 GB，安全 |
| 0.75 | 最低可用值，再低 vLLM 可能拒绝启动 |
| 0.85 | 更激进，极限并发可能 OOM |

### 并发控制：`--max-num-seqs 6`

最大同时处理 6 个请求。当前模型权重占用 79 GB，约 49 GB 余量：

| 值 | 适用场景 | 显存压力 |
|------|----------|---------|
| 6（当前） | 低并发、长上下文稳定 | 极低 |
| 8-10 | 中等并发 | 安全，~49 GB 余量 |
| 12+ | 高并发 | 需测试，1M 上下文时 KV Cache 增长明显 |

### 完整参数速查

```bash
--tensor-parallel-size 2          # TP=2 跨 2 张 GPU（两节点各一）
--pipeline-parallel-size 1        # PP=1
--nnodes 2                        # 2 个节点
--kv-cache-dtype nvfp4_ds_mla     # NVFP4 4-bit MLA KV Cache（省显存关键）
--block-size 256                  # KV Cache block 大小
--max-model-len 1048576           # 1M token 上下文（YaRN 原生）
--max-num-seqs 6                  # 最大并发（可调至 8-10）
--max-num-batched-tokens 8192     # prefill 批次（小块省显存）
--gpu-memory-utilization 0.78     # 显存安全上限（~79GB / 128GB 统一内存）
--enable-chunked-prefill          # 长 prompt 分块防 OOM
--enable-prefix-caching           # 共享前缀复用 KV Cache
--speculative-config dspark       # DGX Spark 硬件推测解码
--moe-backend flashinfer_b12x     # B300 GB10 专用 MoE
```

---

## NCCL 配置详解

双机推理依赖 **NCCL** 通过 RoCE 实现跨节点 GPU 通信。

### 为什么必须用 `--network host`

```
容器网络栈  ──NCCL RDMA──►  物理网卡 (enp1s0f0np0)
     ↑                            ↑
  docker bridge 模式时            RoCE 必须直通
  RDMA 无法穿透 NAT              物理 HCA 设备
```

NCCL RDMA 数据路径必须直通物理网卡，Docker bridge/NAT 虚拟 IP 会导致 `mlx5` HCA 绑定失败。`--network host` 是唯一可靠方式。

### NCCL 环境变量

| 变量 | 值 | 说明 |
|------|-----|------|
| `NCCL_IB_GID_INDEX` | `5` (MTU=9000) / `3` (MTU=1500) | RoCE GID 路由表索引 |
| `NCCL_IB_HCA` | `rocep1s0f0` | 指定 RoCE 设备 |
| `NCCL_NET` | `IB` | 强制 IB/RoCE 传输层 |
| `NCCL_IB_ROCE_VERSION_NUM` | `2` | RoCE v2 (UDP 封装) |
| `NCCL_CROSS_NIC` | `1` | 允许跨 NIC 通信 |
| `NCCL_CUMEM_ENABLE` | `0` | 禁用 CUDA 内存池直通 (GB10 兼容) |
| `NCCL_NVLS_ENABLE` | `0` | 禁用 NVLink Sharp (GB10 不支持) |
| `NCCL_IGNORE_CPU_AFFINITY` | `1` | 忽略 CPU 亲和性 (容器内必需) |
| `NCCL_SOCKET_IFNAME` | `enp1s0f0np0` | NCCL 通信绑定网卡 |
| `GLOO_SOCKET_IFNAME` | `enp1s0f0np0` | Gloo 通信网卡 |
| `TP_SOCKET_IFNAME` | `enp1s0f0np0` | TP 通信网卡 |

### GID_INDEX 选择逻辑

```
       ┌── MTU == 9000? ──► GID_INDEX=5  (RoCE v2, jumbo frames)
检测 ──┤
       └── MTU != 9000? ──► GID_INDEX=3  (RoCE v1 兼容)
```

### NCCL 初始化流程

```
1. Head 启动 → vLLM 加载模型权重 (~150s)
2. Worker 启动 → vLLM 加载权重，等待 Head 建连
3. Head 完成 → NCCL init 握手 (Head ↔ Worker)
   ├─ TCP 握手 (MASTER_ADDR:MASTER_PORT)
   ├─ GLOO 拓扑发现 (GLOO_SOCKET_IFNAME)
   └─ NCCL IB 建连 (NCCL_SOCKET_IFNAME + IB_GID_INDEX)
4. 两节点各分配 NCCL rank → 同步完成 → 开始推理
```

> ⚠️ **关键**：Head `NODE_RANK=0`，Worker `NODE_RANK=1`，必须唯一。

### NCCL 排查

```bash
# 查看 RoCE 设备
ibv_devinfo
ibv_devinfo -d rocep1s0f0 -v | grep GID

# 查看 GID 表
show_gids | grep -A3 "rocep1s0f0"

# 开启详细 NCCL 日志
docker run ... -e NCCL_DEBUG=INFO -e NCCL_DEBUG_SUBSYS=NET,INIT ...
```

### 常见 NCCL 错误

| 错误 | 原因 | 解决 |
|------|------|------|
| `Got completion with error` | RoCE 不通/网线松 | 检查物理连接 + 双向 ping |
| `GID index not found` | GID_INDEX 选错 | `show_gids` 确认，MTU 1500 用 3 |
| `NCCL timeout` | Worker NODE_RANK=0 | Worker 改为 `--node-rank 1` |
| `Socket connection refused` | Head 未就绪 Worker 先连 | 等 Head 加载完再启 Worker |
| `mlx5_0:1 got error from peer` | 单向通另一向不通 | 防火墙检查，双向 ping |

---

## 模型权重获取

### 方式一：HuggingFace（推荐）

```bash
pip install huggingface_hub
huggingface-cli download deepseek-ai/DeepSeek-V4-Flash-0731 \
  --local-dir /data/models/deepseek-ai/DeepSeek-V4-Flash-0731
```

> NVFP4 量化蒸馏版，实际约 **156 GB**，建议预留 200 GB+。两台节点都需下载。

### 方式二：ModelScope（国内镜像，更快）

```bash
pip install modelscope
modelscope download --model deepseek-ai/DeepSeek-V4-Flash-0731 \
  --local_dir /data/models/deepseek-ai/DeepSeek-V4-Flash-0731
```

### 同步到 Worker

```bash
# 从 Head 通过 RoCE 直传
rsync -avz --progress \
  /data/models/deepseek-ai/DeepSeek-V4-Flash-0731/ \
  root@10.10.12.21:/data/models/deepseek-ai/DeepSeek-V4-Flash-0731/
```

---

## 作者

[@alexlu0912_admin](https://gitee.com/alexlu0912_admin)

---

## 许可证

MIT
