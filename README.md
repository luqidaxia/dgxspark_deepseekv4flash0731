# DeepSeek V4 Flash 0731 — 4-Node TP=4 Deployment

Run **DeepSeek V4 Flash 0731** (FP8 quantized, MoE experts in FP4, 1M context) across **four NVIDIA DGX Spark** (GB10, 128GB unified memory each) workstations interconnected via **RoCE** (RDMA over Converged Ethernet), with tensor parallelism **TP=4** (one GB10 GPU per node).

> 🌿 **Branch navigation**
> - **`4node`（this branch）**：4-node TP=4 deployment —— see `4node/`
> - **`master`**：2-node TP=2 deployment —— see [`deploy/`](https://gitee.com/alexlu0912_admin/dgxspark_deepseekv4flash0731/tree/master/deploy)

> 🇨🇳 中文版见下方 | Gitee mirror：[gitee.com/alexlu0912_admin/dgxspark_deepseekv4flash0731](https://gitee.com/alexlu0912_admin/dgxspark_deepseekv4flash0731)

---

## Hardware Topology

```
┌────────────────┐       RoCE (enp1s0f0np0, MTU 1500, GID=3)       ┌────────────────┐
│  node01 (head) │◄──────────────────────────────────────────────►│ node02 (rank1) │
│  10.10.10.101  │                                                │  10.10.10.102  │
│   1× GB10      │                                                │   1× GB10      │
└───────┬────────┘                                                └───────┬────────┘
        │                     RoCE full mesh                             │
┌───────┴────────┐                                                ┌───────┴────────┐
│ node03 (rank2) │◄──────────────────────────────────────────────►│ node04 (rank3) │
│  10.10.10.103  │                                                │  10.10.10.104  │
│   1× GB10      │                                                │   1× GB10      │
└────────────────┘                                                └────────────────┘
```

| Node   | Role   | RoCE IP       | NCCL Rank | Mgmt IP        |
|--------|--------|---------------|-----------|----------------|
| node01 | head   | `10.10.10.101`| 0         | `192.168.22.141` |
| node02 | worker | `10.10.10.102`| 1         | `192.168.22.119` |
| node03 | worker | `10.10.10.103`| 2         | `192.168.22.139` |
| node04 | worker | `10.10.10.104`| 3         | `192.168.22.134` |

- **TP=4** across 4× GB10 (1 GPU per node), **PP=1**, **NNODES=4**
- **Network**: RoCE v2 over InfiniBand (`enp1s0f0np0`, HCA `rocep1s0f0`, GID_INDEX=3, MTU 1500)
- **Model**: DeepSeek V4 Flash 0731 (156 GB, FP8 quantized with FP4 MoE experts, 1M token context)

---

## Speed Benchmark (measured 2026-08-22)

Model: DeepSeek V4 Flash 0731, TP=4 across 4× GB10.

| Scenario | Speed |
|----------|-------|
| Single request (500-token code gen, after warmup) | **~103 tok/s** (98~108) |
| Single request (cold start) | ~77 tok/s |
| 5-way concurrent aggregate throughput | **~157 tok/s** |

Compared with the 2-node TP=2 baseline (~61 tok/s), **4-node TP=4 gives ~69% faster single-request throughput**, while per-node weights drop from ~74 GB to ~41 GB (40.64 GiB measured), leaving memory very comfortable.

---

## Directory Structure

```
dgxspark_deepseekv4flash0731/          (4node branch)
├── README.md                # This file (English + 中文)
├── 4node/                   # ✅ 4-node TP=4 deploy scripts
│   ├── config.sh            #    Configuration (image, model path, 4× IPs, vLLM args)
│   ├── node01.sh            #    head (rank 0) startup
│   ├── node02.sh            #    worker (rank 1) startup
│   ├── node03.sh            #    worker (rank 2) startup
│   ├── node04.sh            #    worker (rank 3) startup
│   ├── distribute-image.sh  #    Offline image packing & distribution (no internet)
│   └── README.md            #    Detailed 4-node deployment guide
├── deploy/                  # 2-node TP=2 scripts (master-branch reference)
├── legacy/                  # Legacy reference files from dsv4dspark
├── vllm-args.md             # vLLM parameter reference
├── troubleshooting.md       # Troubleshooting guide
└── LICENSE
```

---

## Quick Start

### Prerequisites

| Item | Details |
|------|---------|
| Docker image | `anemll-dspark-vllm:latest` (18.8 GB; identical to `ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1`) |
| Model weights | `DeepSeek-V4-Flash-0731` full directory (156 GB, 48 safetensors shards), same path on all 4 nodes |
| OS | DGX Spark (NVIDIA GB10, 128 GB), Ubuntu 24.04+, NVIDIA driver / Docker / nvidia-container-toolkit |
| Network | RoCE interconnect on all 4 nodes (`enp1s0f0np0`, MTU 1500, GID_INDEX=3) |

### 1. Prepare the Docker Image (pick one)

**A. Offline pack & distribute (recommended, no internet)** — run on a machine that already has the image:

```bash
bash 4node/distribute-image.sh
```

Flow: `docker save` → CX7 direct link to node02 → node02 fans out to the other 3 nodes over RoCE → `docker load` on each.

**B. Pull from registry** — run on every node:

```bash
docker pull ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1
docker tag ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1 anemll-dspark-vllm:latest
```

### 2. Prepare Model Weights

Make sure `/data/models/deepseek-ai/DeepSeek-V4-Flash-0731` is complete (156 GB, 48 safetensors shards) on all 4 nodes. Sync from an existing node with `rsync` over RoCE if needed.

### 3. Configure

Edit `4node/config.sh` and confirm `MASTER_ADDR`, the four node IPs, `IMAGE`, and `MODEL_PATH`. Copy the whole `4node/` directory to all 4 nodes (at minimum `config.sh` + the node's own script).

### 4. Launch (workers first, head last)

```bash
# 1) On the three worker nodes first
bash node02.sh      # on node02
bash node03.sh      # on node03
bash node04.sh      # on node04

# 2) Then on the head node
bash node01.sh      # on node01
```

> ⚠️ Launch order: **workers first, head last** (5–10 s apart). Once the head starts, NCCL builds the connection and every node loads 48 shards; the service is ready in ~5 minutes.

### 5. Verify Deployment

```bash
# Confirm readiness
docker logs vllm_anemll 2>&1 | grep "Application startup complete"

# List models
curl http://10.10.10.101:8888/v1/models

# Basic chat
curl http://10.10.10.101:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"你好"}],"max_tokens":128}'

# Verify NCCL world size
docker logs vllm_anemll 2>&1 | grep "world_size=4"
```

---

## Key vLLM Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| `--tensor-parallel-size` | 4 | 4-node tensor parallelism |
| `--nnodes` / `--node-rank` | 4 / 0~3 | Distribution size and role |
| quantization | `deepseek_v4_fp8` | FP8 weights, FP4 MoE experts |
| `--kv-cache-dtype` | `nvfp4_ds_mla` | DeepSeek V4 MLA KV cache format |
| `--moe-backend` | `flashinfer_b12x` | B12X MXFP4 MoE backend |
| `--speculative-config` | `dspark` num=5 | dspark speculative decoding (5-token lookahead) |
| `--max-model-len` | 1048576 | 1M context |
| `--gpu-memory-utilization` | 0.78 | per-node weights ~41 GB, memory comfortable |
| `NCCL_IB_GID_INDEX` | 3 | MTU 1500 → 3 (auto-detected by script) |

---

## NCCL Configuration

- **Why `--network host` is mandatory**: RDMA data path must bind the physical HCA (`rocep1s0f0`); a Docker bridge IP would prevent RDMA from reaching the NIC and NCCL would fail its control-plane/data-plane IP validation.
- **GID_INDEX selection**: the startup scripts auto-detect the interface MTU — MTU 9000 → GID_INDEX=5, otherwise (MTU 1500) → GID_INDEX=3. This cluster uses MTU 1500 → GID 3.
- **NCCL env vars** are set in `node*.sh`: `NCCL_IB_HCA`, `NCCL_NET=IB`, `NCCL_IB_ROCE_VERSION_NUM=2`, `NCCL_SOCKET_IFNAME`/`GLOO_SOCKET_IFNAME`/`TP_SOCKET_IFNAME`.

---

## Troubleshooting

**Q: node03 occasionally stalls early in weight loading (10+ min no progress, disk IO 0)?**
→ An occasional init stall; restart that node's container. Normal load takes ~81 s. It is not a model file issue (48 shards intact, md5 verified).

**Q: NCCL connection fails?**
→ Verify the 4 nodes' RoCE IPs are reachable (`ping 10.10.10.x`), `NCCL_INTF` matches the real interface, and GID_INDEX matches the MTU.

**Q: OOM / container killed?**
→ On GB10 unified memory, make sure no other inference container (e.g. GLM) holds memory before starting. `free -h` should show > 60 GB available.

**Q: Port in use?**
→ Default API port 8888, NCCL port 25000. `docker rm -f vllm_anemll` then restart.

---

## Author

Maintained by [@alexlu0912_admin](https://gitee.com/alexlu0912_admin) · `4node` branch

## License

MIT License — see [LICENSE](./LICENSE).

---

---

# DeepSeek V4 Flash 0731 — 4 节点 TP=4 部署

在 **4 台 NVIDIA DGX Spark (GB10，每台 128GB 统一内存)** 上跨节点部署 **DeepSeek V4 Flash 0731**（FP8 量化，MoE 专家层 FP4，1M 上下文），通过 **RoCE** 互联，张量并行 **TP=4**（每节点 1 张 GB10）。

> 🌿 **分支导航**
> - **`4node`（本分支）**：4 节点 TP=4 部署 —— 见 `4node/`
> - **`master`**：双机 TP=2 部署 —— 见 [`deploy/`](https://gitee.com/alexlu0912_admin/dgxspark_deepseekv4flash0731/tree/master/deploy)

> [English version](#) | Gitee 镜像：[gitee.com/alexlu0912_admin/dgxspark_deepseekv4flash0731](https://gitee.com/alexlu0912_admin/dgxspark_deepseekv4flash0731)

---

## 硬件拓扑

```
┌────────────────┐       RoCE (enp1s0f0np0, MTU 1500, GID=3)       ┌────────────────┐
│  node01 (head) │◄──────────────────────────────────────────────►│ node02 (rank1) │
│  10.10.10.101  │                                                │  10.10.10.102  │
│   1× GB10      │                                                │   1× GB10      │
└───────┬────────┘                                                └───────┬────────┘
        │                     RoCE 全互联                                 │
┌───────┴────────┐                                                ┌───────┴────────┐
│ node03 (rank2) │◄──────────────────────────────────────────────►│ node04 (rank3) │
│  10.10.10.103  │                                                │  10.10.10.104  │
│   1× GB10      │                                                │   1× GB10      │
└────────────────┘                                                └────────────────┘
```

| 节点 | 角色 | RoCE IP       | NCCL Rank | 管理 IP        |
|------|------|---------------|-----------|----------------|
| node01 | head   | `10.10.10.101` | 0         | `192.168.22.141` |
| node02 | worker | `10.10.10.102` | 1         | `192.168.22.119` |
| node03 | worker | `10.10.10.103` | 2         | `192.168.22.139` |
| node04 | worker | `10.10.10.104` | 3         | `192.168.22.134` |

- **TP=4** 跨 4× GB10（每节点 1 卡），**PP=1**，**NNODES=4**
- **网络**：RoCE v2 over InfiniBand（`enp1s0f0np0`，HCA `rocep1s0f0`，GID_INDEX=3，MTU 1500）
- **模型**：DeepSeek V4 Flash 0731（156 GB，FP8 量化 + FP4 MoE 专家，1M token 上下文）

---

## 推理速度基准（实测 2026-08-22）

模型：DeepSeek V4 Flash 0731，TP=4，4× GB10 跨节点。

| 场景 | 速度 |
|------|------|
| 单请求（500 token 代码生成，warmup 后） | **~103 tok/s**（98~108） |
| 单请求（首次冷启动） | ~77 tok/s |
| 5 并发聚合吞吐 | **~157 tok/s** |

对比双机 TP=2 的 ~61 tok/s，**4 节点 TP=4 单请求提速约 69%**，每节点权重从 ~74 GB 降到 ~41 GB（实测 40.64 GiB），内存非常宽裕。

---

## 目录结构

```
dgxspark_deepseekv4flash0731/          (4node 分支)
├── README.md                # 本文件（英文 + 中文）
├── 4node/                   # ✅ 4 节点 TP=4 部署脚本
│   ├── config.sh            #    配置（镜像 / 模型路径 / 4 个 IP / vLLM 参数）
│   ├── node01.sh            #    head (rank 0) 启动
│   ├── node02.sh            #    worker (rank 1) 启动
│   ├── node03.sh            #    worker (rank 2) 启动
│   ├── node04.sh            #    worker (rank 3) 启动
│   ├── distribute-image.sh  #    镜像离线打包分发（不联网）
│   └── README.md            #    4 节点详细部署指南
├── deploy/                  # 双机 TP=2 脚本（master 分支参考）
├── legacy/                  # dsv4dspark 旧版参考文件
├── vllm-args.md             # vLLM 参数参考
├── troubleshooting.md       # 排查指南
└── LICENSE
```

---

## 快速开始

### 前置条件

| 项目 | 详情 |
|------|------|
| Docker 镜像 | `anemll-dspark-vllm:latest`（18.8 GB，与 `ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1` 同一镜像） |
| 模型权重 | `DeepSeek-V4-Flash-0731` 完整目录（156 GB，48 个 safetensors 分片），4 台机相同路径 |
| 系统 | DGX Spark（NVIDIA GB10，128 GB），Ubuntu 24.04+，带 NVIDIA 驱动 / Docker / nvidia-container-toolkit |
| 网络 | 4 台机 RoCE 互联（`enp1s0f0np0`，MTU 1500，GID_INDEX=3） |

### 1. 准备镜像（二选一）

**A. 离线打包分发（推荐，不联网）** — 在已有镜像的机器上执行：

```bash
bash 4node/distribute-image.sh
```

流程：`docker save` → CX7 直连发到 node02 → node02 走 RoCE 并行分发到其余 3 节点 → 各节点 `docker load`。

**B. 联网拉取** — 在每台节点执行：

```bash
docker pull ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1
docker tag ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1 anemll-dspark-vllm:latest
```

### 2. 准备模型权重

确保 4 台机的 `/data/models/deepseek-ai/DeepSeek-V4-Flash-0731` 目录完整（156 GB，48 个 safetensors 分片）。可通过 RoCE `rsync` 从已有节点同步。

### 3. 配置

编辑 `4node/config.sh`，确认 `MASTER_ADDR`、4 个节点 IP、`IMAGE`、`MODEL_PATH` 正确。将整个 `4node/` 目录复制到 4 台机（至少 `config.sh` + 对应节点的脚本）。

### 4. 启动（注意顺序：worker 先，head 后）

```bash
# 1) 先在 3 个 worker 节点分别执行
bash node02.sh      # node02 上
bash node03.sh      # node03 上
bash node04.sh      # node04 上

# 2) 最后在 head 节点执行
bash node01.sh      # node01 上
```

> ⚠️ 启动顺序：**worker 先启，head 后启**（5~10 秒间隔）。head 启动后 NCCL 建连，双方各自加载 48 个 shard，约 5 分钟后服务就绪。

### 5. 验证部署

```bash
# 确认服务就绪
docker logs vllm_anemll 2>&1 | grep "Application startup complete"

# 模型列表
curl http://10.10.10.101:8888/v1/models

# 基础对话
curl http://10.10.10.101:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"你好"}],"max_tokens":128}'

# 验证 NCCL world size
docker logs vllm_anemll 2>&1 | grep "world_size=4"
```

---

## 关键 vLLM 参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `--tensor-parallel-size` | 4 | 4 节点张量并行 |
| `--nnodes` / `--node-rank` | 4 / 0~3 | 分布式规模与角色 |
| quantization | `deepseek_v4_fp8` | FP8 权重，FP4 MoE 专家 |
| `--kv-cache-dtype` | `nvfp4_ds_mla` | DeepSeek V4 MLA KV cache 格式 |
| `--moe-backend` | `flashinfer_b12x` | B12X MXFP4 MoE 后端 |
| `--speculative-config` | `dspark` num=5 | dspark 推测解码（5 token 前瞻） |
| `--max-model-len` | 1048576 | 1M 上下文 |
| `--gpu-memory-utilization` | 0.78 | 每节点权重 ~41 GB，内存宽裕 |
| `NCCL_IB_GID_INDEX` | 3 | MTU 1500 → 3（脚本自动检测） |

---

## NCCL 配置

- **为什么必须 `--network host`**：RDMA 数据路径必须绑定物理 HCA（`rocep1s0f0`），Docker 桥接 IP 会让 RDMA 找不到网卡，NCCL 控制面/数据面 IP 校验也会失败。
- **GID_INDEX 选择**：启动脚本自动检测网卡 MTU——MTU 9000 → GID_INDEX=5，否则（MTU 1500）→ GID_INDEX=3。本集群为 MTU 1500 → GID 3。
- **NCCL 环境变量**在 `node*.sh` 中设置：`NCCL_IB_HCA`、`NCCL_NET=IB`、`NCCL_IB_ROCE_VERSION_NUM=2`、`NCCL_SOCKET_IFNAME`/`GLOO_SOCKET_IFNAME`/`TP_SOCKET_IFNAME`。

---

## 常见问题

**Q: node03 偶发卡死在权重加载早期（10+ 分钟无进展、磁盘 IO 为 0）？**
→ 偶发初始化卡死，重启该节点容器即可恢复（正常加载约 81 秒）。不是模型文件问题（48 shard 完整、md5 一致）。

**Q: NCCL 建连失败？**
→ 确认 4 台机 RoCE IP 可达（`ping 10.10.10.x`），`NCCL_INTF` 网卡名正确，GID_INDEX 与 MTU 匹配。

**Q: 内存不足 / 容器被 Kill？**
→ GB10 统一内存下，确保启动前没有其他推理容器占用内存（如 GLM）。`free -h` 应显示可用内存 > 60 GB。

**Q: 端口占用？**
→ 默认 API 端口 8888，NCCL 端口 25000。`docker rm -f vllm_anemll` 后重启。

---

## 作者

维护者 [@alexlu0912_admin](https://gitee.com/alexlu0912_admin) · `4node` 分支

## License

MIT License — 见 [LICENSE](./LICENSE)。
