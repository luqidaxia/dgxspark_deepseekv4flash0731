# DeepSeek V4 Flash 双机部署包

两台 DGX Spark 通过 RoCE 互联运行 DeepSeek V4 Flash (NVFP4, 1M context, TP=2 跨节点)。

---

## 1. 硬件拓扑

```
┌──────────────────────────┐    RoCE (enp1s0f0np0, MTU 9000)     ┌──────────────────────────┐
│   DGX Spark #1 (Head)    │◄───────────────────────────────────►│   DGX Spark #2 (Worker)  │
│   IP: 10.10.12.11        │                                     │   IP: 10.10.12.21        │
│   GPU: 1× GB10 (288 GB)  │                                     │   GPU: 1× GB10 (288 GB)  │
└──────────────────────────┘                                     └──────────────────────────┘
```

- **TP=2 跨两个节点的 2 张 GPU**，PP=1，NNODES=2
- **网络**: RoCE v2 over IB (`enp1s0f0np0`, GID_INDEX=5, MTU 9000)

---

## 2. 你需要预先准备好的

| 项目 | 说明 |
|------|------|
| **Docker 镜像** | `ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1` |
| **模型权重** | `DeepSeek-V4-Flash-0731` 目录，两台节点放在**同一路径** (获取方式见下方) |

---

## 3. 部署前准备

### 3.0 一键环境准备 (推荐)

```bash
bash prepare.sh
```

交互式菜单，按需选择执行：

```
╔══════════════════════════════════════════════╗
║   DeepSeek V4 Flash 双机部署 - 环境准备       ║
╠══════════════════════════════════════════════╣
║  1) 拉取 Docker 镜像   (约 20 GB)              ║
║  2) 下载模型权重       (约 156 GB, ModelScope)  ║
║  3) 配置 RoCE 网络     (IP + MTU)              ║
║  9) 一键全部执行       (1 → 3 → 2)             ║
╚══════════════════════════════════════════════╝
```

> 两台 DGX Spark 都需要运行 `prepare.sh` — Head 和 Worker 各执行一次。

### 3.1 手动方式 (备选)

两台节点分别执行：

```bash
docker pull ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1
```

### 3.2 配置 RoCE IP

在两台节点的 `enp1s0f0np0` 网卡上配置 IP（如未配置）：

```bash
# Head 节点
ip addr add 10.10.12.11/24 dev enp1s0f0np0

# Worker 节点 (IP 与 config.sh 中 WORKER_IP 保持一致)
ip addr add 10.10.12.21/24 dev enp1s0f0np0
```

> ⚠️ 需持久化写入 netplan/NetworkManager，否则重启后丢失。

### 3.3 修改配置文件

编辑 `config.sh`：

```bash
IMAGE="ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1"          # Docker 镜像
MODEL_PATH="/data/models/deepseek-ai/DeepSeek-V4-Flash-0731"    # 模型路径 (两台一致)
HEAD_IP="10.10.12.11"                                           # Head 的 RoCE IP
NCCL_INTF="enp1s0f0np0"                                        # RoCE 网卡名
```

其余参数无需修改。

### 3.4 同步部署包到两台节点

```bash
# 将整个 deploy 目录复制到 Worker
scp -r ./ root@${WORKER_IP}:/root/deploy/
```

---

## 4. 部署步骤

### Step 1 — 启动 Worker

在 **Worker 节点** 上**先启动**：

```bash
cd /root/deploy
bash start-worker.sh
```

### Step 2 — 启动 Head

Worker 就绪后，在 **Head 节点** 上启动：

```bash
cd /root/deploy
bash start-head.sh
```

> 💡 监控加载进度：`docker logs -f vllm_anemll | grep -E "Ulysses|Loading model|E2E|est.|GPU"`

### Step 3 — 验证部署

#### ① 确认服务就绪

```bash
# 监控日志，出现 "Ulysses model is ready" 即就绪
docker logs -f vllm_anemll 2>&1 | grep -E "Ulysses|Loading model|E2E|est."
```

#### ② 模型列表

```bash
curl -s http://${HEAD_IP}:8888/v1/models | python3 -m json.tool
```

#### ③ 基础对话

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

#### ④ 流式输出

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

#### ⑤ 吞吐基准

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

#### ⑥ 验证 NCCL 跨节点通信

```bash
docker logs vllm_anemll 2>&1 | grep -E "NCCL.*rank.*nranks"
# 预期: rank 0 nranks 2 — 确认双节点已互联
```

#### 验证失败速查

| 现象 | 排查 |
|------|------|
| Connection refused | Head 未加载完，等 5-10 分钟 |
| model not found | 模型名是 `deepseek-v4-flash` |
| 速度 < 10 tok/s | Worker 离线，`docker logs` 查 Worker |
| 乱码/空白 | tokenizer 不正确 |

---

## 5. 文件清单

```
deploy/
├── config.sh          # 配置文件 (修改 IP / 模型路径 / 镜像)
├── prepare.sh         # 环境准备脚本 (交互式菜单)
├── start-head.sh      # Head 节点一键启动
├── start-worker.sh    # Worker 节点一键启动
└── README.md          # 本文件
```

---

## 6. 常用操作

```bash
# 查看日志
docker logs -f vllm_anemll

# 停止服务
docker stop vllm_anemll && docker rm vllm_anemll

# 进入容器调试
docker exec -it vllm_anemll bash

# 查看 GPU
docker exec vllm_anemll nvidia-smi
```

---

## 7. 关键参数

### 上下文长度 — 1M token 原生支持

模型 `config.json` 中 `max_position_embeddings: 1048576`，通过 **YaRN**（factor=16）从 65536 扩展到 1M，无需滑动窗口或外推技巧。对应启动参数 `--max-model-len 1048576`。

### 显存管理 — 安全上限 0.78，实际仅 79 GB

`--gpu-memory-utilization 0.78` 是 vLLM 的显存池上限（~224 GB），不是实际占用。实测仅 **79 GB/GPU**（27%），剩余 200 GB+ 用于 KV Cache，1M 上下文 + 6 并发绰绰有余。

| 值 | 效果 |
|------|------|
| 0.78（当前） | 安全，1M 上下文不 OOM |
| 0.75 | 最低可用，再低 vLLM 可能拒启动 |
| 0.85+ | 激进，极限并发可能 OOM |

### 并发 — max-num-seqs=6，有余量

当前 6 并发，显存仅用 27%。可安全上调到 8-10，仍有 100 GB+ 余量。

### 完整参数表

| 参数 | 值 | 说明 |
|------|-----|------|
| `--max-model-len` | `1048576` | 1M token 上下文（YaRN 原生） |
| `--gpu-memory-utilization` | `0.78` | 显存池上限（实际仅 79GB/288GB） |
| `--max-num-seqs` | `6` | 最大并发（有余量可调到 8-10） |
| `--max-num-batched-tokens` | `8192` | prefill 小块处理（省显存） |
| `--kv-cache-dtype` | `nvfp4_ds_mla` | 4-bit 量化 KV Cache |
| `--block-size` | `256` | KV Cache block 大小 |
| `--enable-chunked-prefill` | ✅ | 长 prompt 分块防 OOM |
| `--enable-prefix-caching` | ✅ | 共享前缀复用 |
| `--speculative-config` | `dspark` | DGX Spark 硬件推测解码 |
| `--moe-backend` | `flashinfer_b12x` | B300 GB10 专用 MoE |
| `--headless` | Worker 专用 | Worker 无 API 服务 |

---

## 8. NCCL 配置

双节点推理依赖 NCCL 通过 RoCE 跨节点通信。脚本自动处理以下配置，无需手动干预。

### 自动检测 GID_INDEX

```bash
MTU==9000 → GID_INDEX=5   # RoCE v2 jumbo frame
MTU!=9000 → GID_INDEX=3   # RoCE v1 兼容
```

### 核心 NCCL 环境变量

| 变量 | 值 | 作用 |
|------|-----|------|
| `NCCL_IB_HCA` | `rocep1s0f0` | 指定 RoCE 设备 |
| `NCCL_NET` | `IB` | 强制 IB/RoCE 传输 |
| `NCCL_CROSS_NIC` | `1` | 允许跨 NIC |
| `NCCL_IGNORE_CPU_AFFINITY` | `1` | 容器内必需 |
| `NCCL_SOCKET_IFNAME` | `enp1s0f0np0` | 通信绑定网卡 |

### 为什么必须 `--network host`

NCCL RDMA 数据路径 → 物理 HCA (`mlx5`) → 物理网卡。Docker bridge/NAT 模式会创建虚拟 IP，导致 RDMA 绑定失败。

---

## 9. 故障排查

| 现象 | 原因 | 解决 |
|------|------|------|
| 模型加载卡住不动 | 等待 Worker 加入 | 正常现象 — 确认 Worker 已启动 |
| Worker 报 NCCL timeout | RoCE 不通 | 检查网线、`ping <head_ip>` |
| `NCCL_IB_GID_INDEX` 报错 | MTU ≠ 9000 | 脚本自动检测；手动覆盖 `GID_INDEX=3` |
| OOM | 显存不够 | 降低 `GPU_MEM` 或 `MAX_NUM_SEQS` |
| Container 启动即退出 | 镜像/模型路径不对 | `docker logs vllm_anemll` 查看错误 |

---

## 10. 模型权重获取

```bash
# HuggingFace（推荐）
pip install huggingface_hub
huggingface-cli download deepseek-ai/DeepSeek-V4-Flash-0731 --local-dir /data/models/deepseek-ai/DeepSeek-V4-Flash-0731

# ModelScope（国内镜像，速度更快）
pip install modelscope
modelscope download --model deepseek-ai/DeepSeek-V4-Flash-0731 --local_dir /data/models/deepseek-ai/DeepSeek-V4-Flash-0731
```

> NVFP4 量化蒸馏版，实际约 **156 GB**，建议预留 200 GB+ 磁盘。两台节点都需下载。

---

## 作者

[@alexlu0912_admin](https://gitee.com/alexlu0912_admin)
