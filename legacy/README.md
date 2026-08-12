# DeepSeek V4 Flash 双 DGX Spark 部署包

本目录包含在 **两台 NVIDIA DGX Spark / ASUS GX10** 上部署 **DeepSeek V4 Flash (DSpark)** 的可用方案、脚本与文档。

## 快速开始

1. **编辑环境变量**（必须按你的实际网络/模型路径修改）：
   - `head.env` —— Head 节点（spark-3e35）
   - `worker.env` —— Worker 节点（spark-cefb）

2. **（推荐）先跑一遍预检**：
   ```bash
   cd /root/dsv4dspark
   ./preflight.sh [root@worker-ip]
   ```
   会检查 Worker RoCE 地址、两端 GID index、端口占用等。

3. **在 Head 节点执行一键启动**：
   ```bash
   cd /root/dsv4dspark
   ./start-all.sh [root@worker-ip]
   ```
   默认 Worker 为 `root@<WORKER_IP>`（密码通过环境变量 `WORKER_PASS` 设置）。

4. **等待约 5–20 分钟**（首次冷启动包含 NCCL init、模型加载、TileLang 编译、DeepGEMM warmup、FlashInfer autotune、CUDA Graph capture）。

5. **验证**：
   ```bash
   ./test-api.sh
   ```

6. **停止**：
   ```bash
   ./stop.sh [root@worker-ip]
   ```

## 文件清单

| 文件 | 说明 |
|------|------|
| `head.env` | Head 节点环境变量 |
| `worker.env` | Worker 节点环境变量 |
| `start-head.sh` | 单独启动 Head 容器 |
| `start-worker.sh` | 单独启动 Worker 容器 |
| `start-all.sh` | 从 Head 一键启动双节点 |
| `stop.sh` | 双节点清理容器/进程 |
| `test-api.sh` | API 连通性与推理测试 |
| `preflight.sh` | 启动前网络/环境预检 |
| `setup-roce.sh` | 自动配置 Head/Worker 的 RoCE IP、MTU、持久化 |
| `docker-compose.yml` | 官方等价的 Docker Compose 配置（可选） |
| `gen_pdf.py` | 将 Markdown 文档转成 PDF 的辅助脚本 |
| `部署实施文档.md` | 详细实施文档（Markdown） |
| `部署实施文档.pdf` | 详细实施文档（PDF） |
| `CHANGELOG.md` | 本目录后续改动记录 |

## 关键成功点

- **镜像**：`ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1`（国内 NJU 镜像代理）。
- **镜像 Entrypoint 是 `vllm serve`**：启动脚本必须覆盖 `--entrypoint bash`，否则会把 shell 命令当参数传给 vLLM，秒退 Exit(2)。
- **Worker 必须加 `--headless`**：这是避免 `collective_rpc should not be called on follower node` 的关键。
- **vLLM_HOST_IP 必须指向 RoCE IP**：Head=10.10.12.11，Worker=10.10.12.21。
- **Worker 的 RoCE 网口必须有 IP**：如果 `enp1s0f0np0` 没有 `10.10.12.21/24`，NCCL TCPStore 会连不上 Head。
- **NCCL_IB_GID_INDEX 必须以 `show_gids` 为准**：不要用固定值。实测两端都是 index 3（v2 IPv4 GID）。
- **不要 bond**：RoCE CM 会被 bond 的虚拟 MAC 搞乱。

## 本次部署修复清单（2026-08-09）

详见 `CHANGELOG.md`，核心改动：

1. `start-head.sh` / `start-worker.sh` 增加 `--entrypoint bash`。
2. `worker.env` 中 `NCCL_IB_GID_INDEX` 从固定值 5 改为 3（与 `show_gids` 实际输出一致）。
3. 新增 `preflight.sh`：检查 Worker RoCE IP、两端 GID、端口占用、镜像/模型路径。
4. 新增 `CHANGELOG.md` 记录问题与修复。

## 详细文档

见 `部署实施文档.md` 或 `部署实施文档.pdf`。
