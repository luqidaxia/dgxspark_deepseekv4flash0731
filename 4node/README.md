# DeepSeek V4 Flash — 4 节点 TP=4 部署

在 **4 台 NVIDIA DGX Spark (GB10)** 上跨节点部署 **DeepSeek V4 Flash 0731**（NVFP4 量化，1M 上下文），通过 **RoCE** 互联，张量并行 **TP=4**（每节点 1× GB10）。

> 本目录为 `4node` 分支，对应 4 台机器部署。双机（TP=2）部署见仓库 `master` 分支的 `deploy/` 目录。

---

## 硬件拓扑

```
┌───────────────┐      RoCE (enp1s0f0np0, MTU 1500, GID=3)      ┌───────────────┐
│ node01 (head) │◄─────────────────────────────────────────────►│ node02 (rank1)│
│ 10.10.10.101  │                                               │ 10.10.10.102  │
│  1× GB10      │                                               │  1× GB10      │
└───────┬───────┘                                               └───────┬───────┘
        │ RoCE 全互联                                                   │
┌───────┴───────┐                                               ┌───────┴───────┐
│ node03 (rank2)│◄─────────────────────────────────────────────►│ node04 (rank3)│
│ 10.10.10.103  │                                               │ 10.10.10.104  │
│  1× GB10      │                                               │  1× GB10      │
└───────────────┘                                               └───────────────┘
```

| 节点 | 角色 | RoCE IP | NCCL Rank | 管理 IP |
|------|------|---------|-----------|---------|
| node01 | head | `10.10.10.101` | 0 | `192.168.22.141` |
| node02 | worker | `10.10.10.102` | 1 | `192.168.22.119` |
| node03 | worker | `10.10.10.103` | 2 | `192.168.22.139` |
| node04 | worker | `10.10.10.104` | 3 | `192.168.22.134` |

- **TP=4** 跨 4× GB10（每节点 1 卡），**PP=1**，**NNODES=4**
- **网络**：RoCE v2 over InfiniBand（`enp1s0f0np0`，GID_INDEX=3，MTU 1500）
- **模型**：DeepSeek V4 Flash 0731（NVFP4 量化，156 GB，1M token 上下文）

---

## 目录结构

```
4node/
├── config.sh             # 4 节点配置（镜像 / 模型 / IP / vLLM 参数）
├── node01.sh             # head (rank 0) 启动脚本
├── node02.sh             # worker (rank 1) 启动脚本
├── node03.sh             # worker (rank 2) 启动脚本
├── node04.sh             # worker (rank 3) 启动脚本
├── distribute-image.sh   # 镜像离线打包分发（不联网）
└── README.md             # 本文件
```

---

## 推理速度基准（实测 2026-08-22）

模型：DeepSeek V4 Flash 0731（NVFP4），TP=4，4× GB10 跨节点

| 场景 | 速度 |
|------|------|
| 单请求（500 token 代码生成，warmup 后） | **~103 tok/s**（98~108） |
| 单请求（首次冷启动） | ~77 tok/s |
| 5 并发聚合吞吐 | **~157 tok/s** |

对比双机 TP=2 的 ~61 tok/s，**4 节点 TP=4 单请求提速约 69%**，每节点权重从 ~78 GB 降到 ~41 GB，内存非常宽裕。

---

## 前提条件

| 项目 | 详情 |
|------|------|
| Docker 镜像 | `anemll-dspark-vllm:latest`（18.8 GB，与 `ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1` 同一镜像） |
| 模型权重 | `DeepSeek-V4-Flash-0731` 完整目录（156 GB），4 台机放**相同路径** |
| 系统 | DGX Spark（NVIDIA GB10，128GB），Ubuntu 24.04+，带 NVIDIA 驱动 / Docker / nvidia-container-toolkit |
| 网络 | 4 台机 RoCE 互联（`enp1s0f0np0`），MTU 1500，GID_INDEX=3 |

---

## 快速开始

### 1. 准备镜像（二选一）

**A. 离线打包分发（推荐，不联网）** — 在有镜像的机器上执行：

```bash
bash distribute-image.sh
```

脚本流程：`docker save` → CX7 直连发到 node02 → node02 走 RoCE 并行分发到其余 3 节点 → 各节点 `docker load`。

**B. 联网拉取** — 在每台节点执行：

```bash
docker pull ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1
docker tag ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1 anemll-dspark-vllm:latest
```

### 2. 准备模型权重

确保 4 台机的 `/data/models/deepseek-ai/DeepSeek-V4-Flash-0731` 目录完整（156 GB，48 个 safetensors 分片）。可通过 RoCE `rsync` 从已有节点同步。

### 3. 配置

编辑 `config.sh`，确认 `MASTER_ADDR`、节点 IP、`IMAGE`、`MODEL_PATH` 正确。将整个 `4node/` 目录复制到 4 台机（或至少复制 `config.sh` + 对应节点的脚本）。

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

### 5. 验证

```bash
# 确认服务就绪
docker logs vllm_anemll 2>&1 | grep "Application startup complete"

# 模型列表
curl http://10.10.10.101:8888/v1/models

# 基础对话
curl http://10.10.10.101:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"你好"}],"max_tokens":128}'
```

---

## 关键参数说明

| 参数 | 值 | 说明 |
|------|-----|------|
| `--tensor-parallel-size` | 4 | 4 节点张量并行 |
| `--nnodes` / `--node-rank` | 4 / 0~3 | 分布式规模与角色 |
| `--kv-cache-dtype` | `nvfp4_ds_mla` | DeepSeek V4 MLA KV cache 格式 |
| `--moe-backend` | `flashinfer_b12x` | B12X MXFP4 MoE 后端 |
| `--speculative-config` | `dspark` num=5 | dspark 推测解码（5 token 前瞻） |
| `--max-model-len` | 1048576 | 1M 上下文 |
| `--gpu-memory-utilization` | 0.78 | 每节点权重 ~41 GB，内存宽裕 |
| `NCCL_IB_GID_INDEX` | 3 | MTU 1500 → 3（脚本自动检测） |

---

## 常见问题

**Q: node03 偶发卡死在权重加载早期（10+ 分钟无进展、磁盘 IO 为 0）？**
→ 偶发初始化卡死，重启该节点容器即可恢复（正常加载约 81 秒）。不是模型文件问题（48 shard 完整、md5 一致）。

**Q: NCCL 建连失败？**
→ 确认 4 台机 RoCE IP 可达（`ping 10.10.10.x`），`NCCL_INTF` 网卡名正确，GID_INDEX 与 MTU 匹配。

**Q: 内存不足 / 容器被 Kill？**
→ GB10 统一内存下，确保启动前没有其他推理容器占用内存（如 GLM）。可用 `free -h` 确认可用内存 > 60 GB。

**Q: 端口占用？**
→ 默认 API 端口 8888，NCCL 端口 25000。`docker rm -f vllm_anemll` 后重启。

---

_Maintained by [@alexlu0912_admin](https://gitee.com/alexlu0912_admin) · 4node 分支_
