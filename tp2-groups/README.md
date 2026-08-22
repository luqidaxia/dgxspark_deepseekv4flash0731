# DeepSeek V4 Flash — TP=2 分两组部署

把 4 台节点拆成 **两组独立 TP=2 服务**，可同时并行跑，总吞吐翻倍。

## 拓扑

| 组  | 节点            | head (rank0) | worker (rank1) | API 端口 | master 端口 |
|-----|-----------------|--------------|----------------|----------|-------------|
| 组A | node01 + node02 | node01       | node02         | 8888     | 25001       |
| 组B | node03 + node04 | node03       | node04         | 8889     | 25002       |

两组 master 地址 / master 端口 / API 端口完全隔离，**可同时并行**，互不干扰。

## 脚本-节点映射

| 脚本               | 节点    | 组  | 角色   | rank |
|--------------------|---------|-----|--------|------|
| groupA_node01.sh   | node01  | 组A | head   | 0    |
| groupA_node02.sh   | node02  | 组A | worker | 1    |
| groupB_node03.sh   | node03  | 组B | head   | 0    |
| groupB_node04.sh   | node04  | 组B | worker | 1    |

## 启动顺序（每组 worker 先，head 后）

```bash
# 组A（node02 worker 先，node01 head 后）
bash groupA_node02.sh     # 在 node02 上
bash groupA_node01.sh     # 在 node01 上

# 组B（node04 worker 先，node03 head 后），可与组A 并行
bash groupB_node04.sh     # 在 node04 上
bash groupB_node03.sh     # 在 node03 上
```

> ⚠️ 与 TP=4 一样，worker 先启、head 后启（5~10 秒间隔）。

## 就绪检查

```bash
# 组A head (node01)
docker logs vllm_anemll 2>&1 | grep "Application startup complete"
# 组B head (node03)
docker logs vllm_anemll 2>&1 | grep "Application startup complete"
```

## API

- 组A: `http://10.10.10.101:8888/v1`（模型名 `deepseek-v4-flash`）
- 组B: `http://10.10.10.103:8889/v1`（模型名 `deepseek-v4-flash`）

## 关键参数

- `--tensor-parallel-size 2 --nnodes 2`（与 TP=4 仅差 TP/NNODES/端口）
- 组A: `MASTER_ADDR=10.10.10.101  MASTER_PORT=25001  API=8888`
- 组B: `MASTER_ADDR=10.10.10.103  MASTER_PORT=25002  API=8889`
- 其余参数与 TP=4 完全一致：`--max-model-len 1048576`、`nvfp4_ds_mla`、`flashinfer_b12x`、dspark 投机解码 num=5、`NCCL_IB_TC=106` 等

## 与 TP=4 的取舍（实测结论）

见仓库根 `README.md` 的「TP=4 vs 两两 TP=2 方案对比」章节。要点：

- **TP=4**：单请求快 1.3~1.7 倍，适合低并发长文。
- **两两 TP=2 ×2 组**：总吞吐可翻倍（理论 ~308 vs ~212 tok/s），但需网关分流 + 双份权重显存（每节点 ~79GB）。
- **高并发长 prompt 的 prefill TTFT 是交换机组网的共性瓶颈**，两方案都受制。
