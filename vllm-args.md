# vLLM 参数详解 — DeepSeek V4 Flash 双机部署

## 模型参数

### `--tensor-parallel-size 2`
张量并行度。DeepSeek V4 Flash 0731 NVFP4 蒸馏版约需 150GB 显存，
单 DGX Spark GB10 有 288GB，但跨两片 GB10 (TP=2) 可提供更快的推理速度。

### `--pipeline-parallel-size 1`
流水线并行度。模型只用一层 PP，因为 0731 蒸馏版已足够放入两卡。

### `--nnodes 2`
节点数。Head + Worker 两台 DGX Spark。

## KV Cache 参数

### `--kv-cache-dtype nvfp4_ds_mla`
**核心参数。** 使用 NVFP4 格式的 DeepSeek MLA (Multi-head Latent Attention) KV Cache。
这是 B300/GB10 专用优化，将 KV Cache 量化为 4-bit，显著降低显存占用。

### `--block-size 256`
KV Cache 的 block 大小。影响内存碎片和吞吐。256 是 1M context 下的推荐值。

## 显存 / 并发控制

### `--gpu-memory-utilization 0.78`
GPU 显存利用率上限。设 78% 留出余量给：
- FlashInfer autotune JIT 编译
- NCCL 通信 buffer
- 操作系统开销

如果 OOM，降到 0.75 或 0.72。

### `--max-model-len 1048576`
最大序列长度 = 1M tokens。DeepSeek V4 Flash 原生支持。

### `--max-num-seqs 6`
最大并发序列数。越多越吃显存，6 是 288GB 的平衡点。

## DGX Spark 专有参数

### `--speculative-config dspark`
DGX Spark 专用硬件推测解码配置，利用 GB10 的硬件特性加速。

### `--moe-backend flashinfer_b12x`
MoE 层的计算后端。`flashinfer_b12x` 是 B300/GB10 的专用实现。

## NCCL / 网络参数

### `--trust-remote-code`
允许加载模型仓库中的自定义代码（HuggingFace transformer 模型必需）。

### `VLLM_HOST_IP`
vLLM 分布式通信的 IP。两节点必须设为各自的 RoCE IP (`enp1s0f0np0`)。

### NCCL 环境变量 (自动设)
```bash
NCCL_IB_GID_INDEX=5          # RoCE GID 索引 (MTU=9000 时用 5, MTU=1500 时用 3)
NCCL_IB_HCA=mlx5_0           # InfiniBand HCA 设备
NCCL_IB_TIMEOUT=120          # IB 超时 (秒)
NCCL_DEBUG=INFO              # 调试日志级别
NCCL_IB_QPS_PER_CONNECTION=4 # 每连接 QP 数
NCCL_SOCKET_IFNAME=enp1s0f0np0
NCCL_IB_TC=136               # 流量类别
```

---

## 调优建议

| 问题 | 调整项 |
|------|--------|
| OOM | 降低 `gpu-memory-utilization` 至 0.72 |
| NCCL 初始化超时 | 增大 `NCCL_IB_TIMEOUT` 到 180 |
| 吞吐偏低 | 增大 `max-num-seqs`，但要确认不 OOM |
| 首 Token 延迟高 | 已启用 `dspark` 推测解码，无需额外调整 |
