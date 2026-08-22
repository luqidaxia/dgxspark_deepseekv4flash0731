# DeepSeek V4 Flash — 4 节点 TP=4 部署

在 **4 台 NVIDIA DGX Spark (GB10)** 上跨节点部署 **DeepSeek V4 Flash 0731**（FP8 量化，MoE 专家 FP4，1M 上下文），通过 **RoCE** 互联，张量并行 **TP=4**（每节点 1× GB10）。

> 本目录为 `4node` 分支，对应 4 台机器部署。双机（TP=2）部署见仓库 `master` 分支的 `deploy/` 目录。
> 4 节点有两种并行方案：**TP=4**（`4node/`，主方案）与 **两两 TP=2 分两组**（`tp2-groups/`，可并行、吞吐翻倍）。取舍见下文「TP=4 vs 两两 TP=2 方案对比」。

---

## 硬件拓扑

```
        node01 (head)                    node02 (rank1)
        10.10.10.101                     10.10.10.102
        ┌────────────────┐              ┌────────────────┐
        │    1× GB10     │              │    1× GB10     │
        └───────┬────────┘              └────────┬───────┘
                │ RoCE 200G                      │ RoCE 200G
                │ enp1s0f0np0, MTU 9000, GID=3   │
                ▼                                ▼
   ┌──────────────────────────────────────────────────────────────┐
   │      MikroTik CRS812-8DS-2DQ-2DDQ-RM 交换机（1 台，星型）      │
   │  DQ  口（QSFP56,  200G）：qsfp56-1-1 / qsfp56-2-1             │
   │  DDQ 口（QSFP-DD, 200G）：qsfp56-dd-1-1 / qsfp56-dd-2-1       │
   │  DS  口（50G × 8）：未使用                                    │
   └───────────────┬──────────────────────────────┬────────────────┘
                   │                              │
         RoCE 200G │                              │ RoCE 200G
                   ▼                              ▼
        ┌────────────────┐              ┌────────────────┐
        │    1× GB10     │              │    1× GB10     │
        └───────┬────────┘              └────────┬───────┘
        node03 (rank2)                    node04 (rank3)
        10.10.10.103                     10.10.10.104
```

| 节点 | 角色 | RoCE IP | NCCL Rank | 管理 IP |
|------|------|---------|-----------|---------|
| node01 | head | `10.10.10.101` | 0 | `192.168.22.141` |
| node02 | worker | `10.10.10.102` | 1 | `192.168.22.119` |
| node03 | worker | `10.10.10.103` | 2 | `192.168.22.139` |
| node04 | worker | `10.10.10.104` | 3 | `192.168.22.134` |

- **TP=4** 跨 4× GB10（每节点 1 卡），**PP=1**，**NNODES=4**
- **网络**：RoCE v2 over InfiniBand（`enp1s0f0np0`，GID_INDEX=3，MTU 9000），4 节点统一接入 1 台 **MikroTik CRS812-8DS-2DQ-2DDQ-RM 交换机**（星型互联，2× QSFP56 + 2× QSFP-DD，均 200G），RoCE 流量/PFC 统一对齐到 **priority 3**
- **模型**：DeepSeek V4 Flash 0731（156 GB，FP8 量化 + FP4 MoE 专家，1M token 上下文）

---

## 目录结构

```
├── 4node/                        # 4 节点 TP=4 方案（本分支主方案）
│   ├── config.sh                 # TP=4 配置（镜像 / 模型 / IP / vLLM 参数）
│   ├── node01.sh                 # head (rank 0) 启动脚本
│   ├── node02.sh                 # worker (rank 1) 启动脚本
│   ├── node03.sh                 # worker (rank 2) 启动脚本
│   ├── node04.sh                 # worker (rank 3) 启动脚本
│   ├── distribute-image.sh       # 镜像离线打包分发（不联网）
│   ├── roce-switch-networking.md # 交换机组网 PFC 优先级对齐（无损网络修复）
│   └── README.md
├── tp2-groups/                   # 4 节点拆两组 TP=2 方案（可并行，吞吐翻倍）
│   ├── config.sh                 # TP=2 公共配置
│   ├── groupA_node01.sh          # 组A head (node01)
│   ├── groupA_node02.sh          # 组A worker (node02)
│   ├── groupB_node03.sh          # 组B head (node03)
│   ├── groupB_node04.sh          # 组B worker (node04)
│   └── README.md
└── README.md                     # 本文件
```

---

## 推理速度基准（实测 2026-08-22）

模型：DeepSeek V4 Flash 0731（FP8 + FP4 专家），TP=4，4× GB10 跨节点

| 场景 | 速度 |
|------|------|
| 单请求（500 token 代码生成，warmup 后） | **~103 tok/s**（98~108） |
| 单请求（首次冷启动） | ~77 tok/s |
| 5 并发聚合吞吐 | **~157 tok/s** |

对比双机 TP=2 的 ~61 tok/s，**4 节点 TP=4 单请求提速约 69%**，每节点权重从 ~74 GB 降到 ~41 GB（实测 40.64 GiB），内存非常宽裕。

---

## TP=4 vs 两两 TP=2 方案对比（预热后公平基准）

> 实测 2026-08-22，20-cell 矩阵（并发 1/3/5/8/10 × 输入输出 50/500/1024/2048 tokens），
> 走 RoCE `10.10.10.101:8888`，**预热后**采集（消除 torch.compile JIT + CUDA graph 冷启动 artifact）。
> TP=4 = 4 节点一体；TP=2 = A 组（node01+node02）。

### ① 单请求生成速度（C=1 平均 TPS，tok/s）— TP=4 明显更快

| 输出长度 | TP=4 | TP=2 | TP=4 优势 |
|---------|------|------|----------|
| 50      | 106.8 | 66.1 | +62% |
| 500     | 80.4  | 54.5 | +48% |
| 1024    | 97.2  | 55.9 | +74% |
| 2048    | 83.0  | 63.9 | +30% |

### ② 低并发 TTFT（C=1，p90，ms）— 两者都健康，TP=4 略快

| 输入长度 | TP=4 | TP=2 |
|---------|------|------|
| 50      | 126  | 175  |
| 500     | 286  | 353  |
| 1024    | 284  | 339  |
| 2048    | 280  | 334  |

### ③ 高并发长 prompt TTFT（p90，ms）— 两方案共性的交换机瓶颈

| 场景 | TP=4 | TP=2 |
|------|------|------|
| C=8 × 500   | 15010 | 22736 |
| C=8 × 1024  | 19190 | 14863 |
| C=8 × 2048  | 9974  | 15458 |
| C=10 × 500  | 16782 | 27475 |
| C=10 × 1024 | 21327 | 32323 |
| C=10 × 2048 | 20175 | 20740 |

> ⚠️ **重要修正**：此前预期「两两 TP=2 高并发 TTFT 更好」（基于 2 节点**直连**旧数据 ~1.2s）。
> 经交换机后，高并发 prefill 的突发 all-reduce 流量在交换机 buffer 上拥塞排队，
> **TP=4 与 TP=2 都劣化到 10~32s**；TP=2 因每节点权重翻倍（79GB）prefill 计算更重，高并发下反而更差。

### ④ 聚合吞吐峰值（tok/s）

| 方案 | 峰值 |
|------|------|
| TP=4 单组 | ~212 |
| TP=2 单组 | ~154 |
| TP=2 ×2 组（理论叠加） | ~308 |

### 结论

- **要单条长文快、低并发** → **TP=4**：单请求 83~107 tok/s，低并发 TTFT ~280ms，聚合吞吐 ~212 tok/s。
- **要总吞吐翻倍** → **两两 TP=2 ×2 组 + 前置网关**：理论聚合 ~308 tok/s，但需双份权重显存（每节点 79GB）。
- **高并发长 prompt 的 prefill TTFT 是交换机组网的物理瓶颈**，两方案都受制；缓解方向 = 调大 `max_num_batched_tokens`、限制并发、或加大交换机 buffer / 调整 PFC 阈值。

---

## 前提条件

| 项目 | 详情 |
|------|------|
| Docker 镜像 | `anemll-dspark-vllm:latest`（18.8 GB，与 `ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1` 同一镜像） |
| 模型权重 | `DeepSeek-V4-Flash-0731` 完整目录（156 GB），4 台机放**相同路径** |
| 系统 | DGX Spark（NVIDIA GB10，128GB），Ubuntu 24.04+，带 NVIDIA 驱动 / Docker / nvidia-container-toolkit |
| 网络 | 4 台机统一接入 1 台 MikroTik CRS812-8DS-2DQ-2DDQ-RM 交换机（星型，`enp1s0f0np0`），MTU 9000，GID_INDEX=3，PFC 对齐 priority 3 |

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
| quantization | `deepseek_v4_fp8` | FP8 权重，FP4 MoE 专家 |
| `--kv-cache-dtype` | `nvfp4_ds_mla` | DeepSeek V4 MLA KV cache 格式 |
| `--moe-backend` | `flashinfer_b12x` | B12X MXFP4 MoE 后端 |
| `--speculative-config` | `dspark` num=5 | dspark 推测解码（5 token 前瞻） |
| `--max-model-len` | 1048576 | 1M 上下文 |
| `--gpu-memory-utilization` | 0.78 | 每节点权重 ~41 GB，内存宽裕 |
| `NCCL_IB_GID_INDEX` | 3 | 本集群 RoCE v2 固定 3（与 MTU 无关） |
| `NCCL_IB_TC` | 106 | RoCE 流量 DSCP 26 → priority 3，与 PFC 对齐（无损网络关键） |

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

**Q: 经交换机后 TTFT 崩了（生成 TPS 正常但首 token 慢 10 倍）？**
→ RoCE 流量 DSCP=0 与 PFC(priority 3) 错位导致 prefill 拥塞丢包。按 [`roce-switch-networking.md`](roce-switch-networking.md) 把「节点 `trust=dscp` + `NCCL_IB_TC=106` + 交换机 PFC `traffic-class=3`」三处对齐即可。

---

_Maintained by [@alexlu0912_admin](https://gitee.com/alexlu0912_admin) · 4node 分支_
