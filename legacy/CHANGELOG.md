# DeepSeek V4 Flash 双 DGX Spark 部署包 — 改动记录

> 本次会话：2026-08-09 / 2026-08-10  
> 操作人：Agent / kimi-for-coding

## 背景

用户要求：停止所有 AI 任务，阅读 `/root/dsv4dspark` 使用说明，在两台 DGX Spark 上运行 DeepSeek V4 Flash。

执行结果：部署成功，API 可推理，同时发现并修复了原部署包中的多个问题。

---

## 修复 1：启动脚本必须覆盖镜像 Entrypoint

### 现象

直接运行 `./start-all.sh` 后，Head / Worker 容器**秒退**，Exit code 2，且 `/tmp/vllm-*.log` 为空。

### 根因

镜像 `ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1` 的 `ENTRYPOINT` 是 `vllm serve`：

```bash
sudo docker inspect ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1 \
  --format 'Entrypoint: {{.Config.Entrypoint}}'
# Entrypoint: [vllm serve]
```

原脚本写法：

```bash
sudo docker run ... "$IMAGE" bash -lc '... vllm serve ...'
```

Docker 会把 `bash -lc '...'` 当作 `CMD` 追加到 `ENTRYPOINT` 后面，实际执行的是：

```bash
vllm serve bash -lc '...'
```

vLLM 把 `bash` 当模型路径解析，立刻报错退出。

### 修复

在 `start-head.sh` 和 `start-worker.sh` 的 `docker run` 中增加：

```bash
--entrypoint bash \
```

并同时去掉命令中多余的 `bash`：

```bash
sudo docker run -d --name "$CONTAINER_NAME" \
  --entrypoint bash \
  --gpus all --ipc host --net host --privileged \
  ... \
  "$IMAGE" \
  -lc '
    export PATH="/usr/local/cuda/bin:${PATH:-}";
    ...
    exec vllm serve /models/dsv4-abliterated ...
  '
```

### 验证

修复后容器不再秒退，开始正常初始化。

---

## 修复 2：Worker 的 RoCE 网口没有 IP

### 现象

容器不再秒退，但 Head 卡在：

```
(Worker pid=220) INFO ... distributed_init_method=tcp://10.10.12.11:25000 backend=nccl
```

Worker 日志反复出现：

```
[c10d] The server socket on [::ffff:10.10.12.11]:25000 has timed out, will retry.
```

最终 Worker 报错：

```
torch.distributed.DistNetworkError: The client socket has timed out after 600000ms
while trying to connect to (10.10.12.11, 25000).
```

### 根因

Worker 的 RoCE 网口 `enp1s0f0np0` 没有 IPv4 地址：

```bash
# Worker 上执行
ip -4 addr show enp1s0f0np0
# （无 inet 输出）
```

Head 上有 `10.10.12.11/24`，但 Worker 没有 `10.10.12.21/24`，两机 RoCE 子网不互通，PyTorch TCPStore 自然连不上。

### 修复

新增 `setup-roce.sh` 脚本，自动在 Head / Worker 上：
- 检查并设置 `enp1s0f0np0` 的 RoCE IP（默认 Head=10.10.12.11/24，Worker=10.10.12.21/24）
- 设置 MTU 9000
- 设置 NetworkManager `managed no`
- 尝试用 `nmcli` 持久化；`nmcli` 不可用时回退写入 `netplan` 配置
- 验证双向 RoCE ping
- 打印两端 GID 表供核对

用法：

```bash
./setup-roce.sh [root@worker-ip]
```

`start-all.sh` 启动前会先调用 `preflight.sh`；若发现 RoCE 配置缺失，会自动调用 `setup-roce.sh` 修复。

`preflight.sh` 也支持 `--auto-fix` 参数：

```bash
./preflight.sh root@192.168.22.161 --auto-fix
```

### 验证

```bash
ping -c 3 10.10.12.21   # Head ping Worker
ping -c 3 10.10.12.11   # Worker ping Head
# 0% packet loss
```

---

## 修复 3：`NCCL_IB_GID_INDEX` 写死导致 NCCL QP 失败

### 现象

TCPStore 通了，但 NCCL 在 RoCE QP 初始化时报错：

```
NCCL WARN Call to ibv_modify_qp failed with 61 No data available,
on dev rocep1s0f0:1, curr state INIT, next state RTR,
local GID index 5, local GID ::, remote GID ::ffff:10.10.12.11
```

最终 Worker 的 MultiprocExecutor 初始化失败，Head 也随之中断。

### 根因

原 `worker.env` 写死 `NCCL_IB_GID_INDEX=5`，但 `show_gids` 显示 Worker 上有效的 IPv4 GID 实际在 index 3；index 5 是空的 `::`，NCCL 无法建立 RoCE QP。

更深层问题：**GID 表顺序会随网络配置变化而改变**。例如，在通过 `setup-roce.sh` 用 `nmcli` 创建并激活 RoCE 连接后，v2 GID 可能从 index 3 变成 index 6。

### 修复

1. **启动脚本动态计算 GID index**：

   `start-head.sh` / `start-worker.sh` 在 source env 文件后，自动执行：

   ```bash
   if command -v show_gids >/dev/null 2>&1; then
     DYNAMIC_GID=$(show_gids 2>/dev/null | awk \
       -v dev="${NCCL_IB_HCA:-rocep1s0f0}" \
       -v ip="${VLLM_HOST_IP}" \
       '$1==dev && $5==ip && $6=="v2" {print $3}')
     if [[ -n "$DYNAMIC_GID" ]]; then
       NCCL_IB_GID_INDEX="$DYNAMIC_GID"
     fi
   fi
   ```

   这样无论 GID 表怎么变，都会用当前正确的 v2 index。

2. **env 文件只保留 fallback 值**：

   `head.env` / `worker.env` 里的 `NCCL_IB_GID_INDEX` 改为 fallback（当前为 6），并加注释说明由脚本动态计算。

### 重要原则

**不要迷信文档里的固定 GID index**。每次 RoCE 地址/连接变化后，GID 表顺序可能变化。现在启动脚本已经自动处理，无需手动改 env。

---

## 修复 4：端口 8888 被旧进程占用

### 现象

手动测试镜像时，容器报错：

```
OSError: [Errno 98] Address already in use
```

### 根因

之前失败的 vLLM 进程或容器残留占用了 8888。

### 修复

`start-head.sh` / `start-worker.sh` 已包含清理：

```bash
sudo docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
sudo pkill -9 -f "vllm serve" 2>/dev/null || true
```

`start-all.sh` 运行前也会清掉对端容器。

---

## 新增：启动前预检脚本 `preflight.sh`

新增 `preflight.sh`，在启动前检查：

- 本地工具（docker、sshpass、ping、curl、sudo）
- Worker SSH 连通性
- Head / Worker 的 RoCE 接口是否有 IP、MTU 是否为 9000
- 双向 RoCE ping
- 两端 `show_gids` 中 RoCE IP 对应的 v2 GID index 是否有效
- 端口 8888 / 25000 是否被占用
- Docker 镜像、模型路径是否存在
- 启动脚本是否可执行

支持 `--auto-fix` 参数：发现 RoCE 配置缺失时自动调用 `setup-roce.sh`。

---

## 部署结果

```bash
cd /root/dsv4dspark
./start-all.sh root@192.168.22.161
# ... 约 5 分 30 秒后 ...
# ✅ API ready after ~330s
```

`/v1/models` 返回：

```json
{
    "object": "list",
    "data": [
        {
            "id": "deepseek-v4-flash",
            "object": "model",
            "max_model_len": 350000
        }
    ]
}
```

`./test-api.sh` 通过：
- Python 快速排序代码生成正常
- Tool call（get_weather 北京）正常

---

## 文件改动列表

- `start-head.sh`：增加 `--entrypoint bash`、去掉多余 `bash`、动态计算 `NCCL_IB_GID_INDEX`
- `start-worker.sh`：同上
- `head.env` / `worker.env`：`NCCL_IB_GID_INDEX` 改为 fallback 值 6，加注释说明动态计算
- `start-all.sh`：启动前先调用 `preflight.sh`，失败则自动调用 `setup-roce.sh`
- `setup-roce.sh`（新增）：自动配置并持久化 Head/Worker 的 RoCE IP、MTU
- `preflight.sh`（新增）：启动前预检；支持 `--auto-fix` 自动修复 RoCE
- `README.md`：更新关键成功点、新增修复清单
- `部署实施文档.md`：修正 GID index 说明、新增启动脚本注意事项、补充排障条目、加入 setup-roce/preflight 说明
- `部署实施文档.pdf`：已重新生成
- `CHANGELOG.md`（新增）：本文档
