# 4 节点 RoCE 交换机组网：PFC 优先级对齐（无损网络修复）

> 适用场景：DGX Spark（NVIDIA GB10 + ConnectX-7）4 台经 **交换机** 互联跑跨节点 TP。
> 结论先行：跨机 TP 一旦从「直连」改为「经交换机」，必须让 RoCE 流量、节点 PFC、交换机 PFC 三者的**优先级对齐**，否则 prefill 阶段 all-reduce 拥塞丢包，TTFT 会恶化 10 倍以上。

---

## 1. 问题现象

4 台机从「两两 200G 直连」改为「经交换机全互联」后：

| 指标 | 直连（正常） | 经交换机（PFC 未对齐） |
|------|-------------|----------------------|
| 单请求 TTFT（500 token 输入） | ~357 ms | **~4279 ms（10 倍恶化）** |
| 单请求 TTFT（1024 token 输入） | ~420 ms | **~6192 ms（15 倍恶化）** |
| 生成 TPS | ~55 tok/s | ~55 tok/s（基本不变） |

典型特征：**生成 TPS 不受影响，只有 TTFT（prefill 阶段）崩了**。因为 prefill 是短时间高并发 all-reduce 流量，最容易触发交换机拥塞丢包；decode 阶段流量小、平稳，不受影响。

> ⚠️ 单条 `ib_write_lat` 延迟测试（如 2.5 us）**看不出问题**——它是单 QP、单消息、无拥塞场景。真实 prefill 的多 QP 大流量才会暴露交换机 buffer 拥塞。

---

## 2. 根因：RoCE 流量 DSCP=0，与 PFC(priority 3) 错位

### 2.1 关键事实：这台 CX7 的 RoCE v2 默认 DSCP 是 0，不是 26

RoCE v2 的优先级由 IP 头的 **DSCP** 字段决定。NVIDIA 网卡**默认 DSCP = 0**（不是很多人默认以为的 26）。

验证方法——看网卡按 priority 分类的收发计数：

```bash
ethtool -S enp1s0f0np0 | grep -E 'tx_prio[03]_packets|rx_prio[03]_packets'
```

跑一段 RDMA 流量后，`tx_prio0_packets` 涨、`tx_prio3_packets` 不动，说明流量全走 priority 0。

### 2.2 三要素错位

| 要素 | 实际值 | 应值 |
|------|--------|------|
| RoCE 流量优先级 | **priority 0**（DSCP=0） | priority 3 |
| 节点 PFC | priority 3 | priority 3 ✅ |
| 交换机 PFC | traffic-class 3 | traffic-class 3 ✅ |

节点和交换机都把 PFC 开在 priority 3，但 RoCE 流量（DSCP=0）走的是 priority 0，**根本没被 PFC 保护**。交换机 buffer 一拥塞就丢包 → Go-Back-N 重传 → prefill 变慢。

> 直连时代为什么没事？直连两端直接收发，无中间 buffer，不存在拥塞丢包，所以之前 `setup-roce.sh` 连 PFC 都没配也能跑满。

---

## 3. 修复方案：三要素对齐到 priority 3

### 3.1 节点侧：网卡信任 DSCP（trust=dscp）

让网卡按 DSCP 归类流量（而不是按 VLAN PCP，因为 RoCE v2 是 untagged 帧，没有 PCP 字段）：

```bash
# 每台节点都执行（两个 Socket Direct 视图）
mlnx_qos -i enp1s0f0np0  --trust=dscp
mlnx_qos -i enP2p1s0f0np0 --trust=dscp
```

改完后 `mlnx_qos -i enp1s0f0np0` 应显示 `Priority trust state: dscp`，且 `dscp2prio` 里 `prio:3 dscp:31,30,29,28,27,26,25,24`（DSCP 26 落在 priority 3）。

**持久化**（节点重启后仍生效，否则会退回 pcp）：

```bash
# 写一个开机执行的 systemd 单元或 rc.local 片段，内容：
#   mlnx_qos -i enp1s0f0np0  --trust=dscp
#   mlnx_qos -i enP2p1s0f0np0 --trust=dscp
#   mlnx_qos -i enp1s0f0np0  -p 0,0,0,1,0,0,0,0   # PFC 开在 priority 3
```

### 3.2 NCCL：让 RoCE 流量标记 DSCP 26（NCCL_IB_TC=106）

`NCCL_IB_TC` 设置 RoCE v2 的 8-bit traffic class（= IP ToS 字节）。**106 = DSCP 26（`106>>2`）+ ECN**，映射到 priority 3。

```bash
NCCL_IB_TC=106
```

本仓库启动脚本已内置（`config.sh` 的 `NCCL_IB_TC=106`，`node01.sh~node04.sh` 通过 `-e NCCL_IB_TC="$NCCL_IB_TC"` 注入容器）。

> 注意：`NCCL_IB_TC` 的值是 **ToS 字节（106）**，不是 DSCP 值（26）。NCCL 2.17+ 支持，实测 NCCL 2.28/2.30 均生效。

### 3.3 交换机侧：PFC 开 traffic-class 3 + 信任 L3/DSCP + ECN

以 MikroTik **CRS812-DDQ** 交换机（RouterOS）为例（4 个 RoCE 接口：`qsfp56-1-1` / `qsfp56-2-1` / `qsfp56-dd-1-1` / `qsfp56-dd-2-1`）：

```routeros
# 1. 创建专用的 PFC 配置（定义 RoCE 流量类 3，并开启收发暂停帧）
/interface ethernet switch qos priority-flow-control
add name=pfc-tc3 rx=yes tx=yes traffic-class=3

# 2. 逐个接口绑定 PFC 配置、信任 L3/DSCP、解除队列 3 限速
/interface ethernet switch qos port
set qsfp56-1-1    pfc=pfc-tc3 trust-l3=keep egress-rate-queue3=0
set qsfp56-2-1    pfc=pfc-tc3 trust-l3=keep egress-rate-queue3=0
set qsfp56-dd-1-1 pfc=pfc-tc3 trust-l3=keep egress-rate-queue3=0
set qsfp56-dd-2-1 pfc=pfc-tc3 trust-l3=keep egress-rate-queue3=0

# 3. 队列 3 开启 ECN（配合节点 DSCP 26 的 ECN 位，缓解拥塞）
/interface ethernet switch qos tx-manager queue
set 3 ecn=yes
```

> 巨型帧另需在接口上单独配置：`/interface ethernet set <port> mtu=9000 l2mtu=9`（本集群 4 口已统一 200G + MTU 9000）。

要点：交换机的 PFC `traffic-class` 必须与节点侧 `priority`（3）一致；`trust-l3=keep` 让交换机按 IP DSCP 归类，而不是按 L2 PCP；队列 3 的 `ecn=yes` 让拥塞时打 ECN 标记，配合 RoCE 的 CNP（拥塞通知）机制实现无损。

---

## 4. 验证方法

### 4.1 流量是否落到 priority 3

```bash
# 跑推理/rdma 流量前记录基线，跑完后对比
ethtool -S enp1s0f0np0 | grep -E 'tx_prio3_packets|rx_prio3_packets'
```

修复后跑一次推理，`tx_prio3_packets` / `rx_prio3_packets` 应显著增长（之前一直是 0）。

### 4.2 PFC 是否实际工作

```bash
ethtool -S enp1s0f0np0 | grep -E 'pause_ctrl_phy'
```

修复前 `tx_pause_ctrl_phy`/`rx_pause_ctrl_phy` 恒为 0（从不发 PAUSE 帧）；修复后加载大流量时会出现非零计数（PFC 真正参与流控）。

### 4.3 端到端验证

跑 benchmark 看 TTFT 是否回落。实测（C=1 单请求，p90）：

| 输入长度 | 修复前 | 修复后 | 改善 |
|---------|--------|--------|------|
| 500 | 4279 ms | **414 ms** | 10.3× |
| 1024 | 6192 ms | **375 ms** | 16.5× |
| 2048 | 4872 ms | **356 ms** | 13.7× |

> 首次请求偶发高 TTFT 是 JIT 编译 / cudagraph 预热，跑第二遍即稳定。

---

## 5. 一句话总结

**直连 → 交换机后，必须把「RoCE 流量 DSCP / 节点 PFC priority / 交换机 PFC traffic-class」三处统一到 priority 3：节点 `trust=dscp` + `NCCL_IB_TC=106` + 交换机 PFC `traffic-class=3`。** 缺任何一个，prefill 阶段就会拥塞丢包、TTFT 崩掉。

---

_Maintained by [@alexlu0912_admin](https://gitee.com/alexlu0912_admin) · 4node 分支_
