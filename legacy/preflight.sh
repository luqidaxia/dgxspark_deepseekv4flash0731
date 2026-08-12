#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -uo pipefail

# 双 DGX Spark DeepSeek V4 Flash 启动前预检脚本
# 用法：./preflight.sh [WORKER_SSH] [--auto-fix]
# --auto-fix：如果 RoCE 口缺少 IP，自动调用 setup-roce.sh 配置

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER_SSH="${1:-root@192.168.22.161}"
AUTO_FIX=0
shift 2>/dev/null || true

for arg in "$@"; do
  case "$arg" in
    --auto-fix) AUTO_FIX=1 ;;
    *) ;;
  esac
done

WORKER_PASS="${WORKER_PASS:-YOUR_WORKER_PASSWORD}"

HEAD_ROCE_IP="${HEAD_ROCE_IP:-10.10.12.11}"
WORKER_ROCE_IP="${WORKER_ROCE_IP:-10.10.12.21}"
ROCE_IFACE="${ROCE_IFACE:-enp1s0f0np0}"
ROCE_IB_DEV="${ROCE_IB_DEV:-rocep1s0f0}"

ERR=0
NEED_ROCE_FIX=0

warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*"; ERR=1; }
ok()   { echo "✅ $*"; }
info() { echo "ℹ️  $*"; }

# 在 Worker 上执行命令
worker_exec() {
  sshpass -p "$WORKER_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$WORKER_SSH" "$@"
}

worker_exec_silent() {
  worker_exec "$@" 2>/dev/null
}

info "=== Preflight check for DeepSeek V4 Flash dual-node vLLM ==="

# 1. 本地工具
info "--- 本地工具检查 ---"
for tool in docker sshpass ping curl sudo; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool 已安装"
  else
    fail "$tool 未安装"
  fi
done

# 2. Worker SSH
info "--- Worker SSH 连通性 ($WORKER_SSH) ---"
if worker_exec_silent "echo hello" | grep -q hello; then
  ok "SSH 到 Worker 正常"
else
  fail "SSH 到 Worker 失败，请检查密码/网络"
fi

# 3. Head RoCE 配置
info "--- Head RoCE 接口 ($ROCE_IFACE) ---"
HEAD_IP_OUT=$(ip -4 addr show "$ROCE_IFACE" 2>/dev/null | grep inet | awk '{print $2}')
if [[ -n "$HEAD_IP_OUT" ]]; then
  ok "Head $ROCE_IFACE IP: $HEAD_IP_OUT"
else
  fail "Head $ROCE_IFACE 没有 IPv4 地址"
  NEED_ROCE_FIX=1
fi

HEAD_MTU=$(ip link show "$ROCE_IFACE" 2>/dev/null | grep -oP 'mtu \K\d+')
if [[ "$HEAD_MTU" == "9000" ]]; then
  ok "Head $ROCE_IFACE MTU = 9000"
else
  warn "Head $ROCE_IFACE MTU = ${HEAD_MTU:-unknown}，建议设为 9000"
  NEED_ROCE_FIX=1
fi

# 4. Worker RoCE 配置
info "--- Worker RoCE 接口 ($ROCE_IFACE) ---"
WORKER_IP_OUT=$(worker_exec_silent "ip -4 addr show $ROCE_IFACE 2>/dev/null | grep inet | awk '{print \$2}'")
if [[ -n "$WORKER_IP_OUT" ]]; then
  ok "Worker $ROCE_IFACE IP: $WORKER_IP_OUT"
else
  fail "Worker $ROCE_IFACE 没有 IPv4 地址"
  NEED_ROCE_FIX=1
fi

WORKER_MTU=$(worker_exec_silent "ip link show $ROCE_IFACE 2>/dev/null | grep -oP 'mtu \\K\\d+'")
if [[ "$WORKER_MTU" == "9000" ]]; then
  ok "Worker $ROCE_IFACE MTU = 9000"
else
  warn "Worker $ROCE_IFACE MTU = ${WORKER_MTU:-unknown}，建议设为 9000"
  NEED_ROCE_FIX=1
fi

# 自动修复 RoCE
if [[ "$NEED_ROCE_FIX" -eq 1 ]]; then
  if [[ "$AUTO_FIX" -eq 1 ]]; then
    info "检测到 RoCE 配置缺失，自动调用 setup-roce.sh ..."
    if [[ -x "$SCRIPT_DIR/setup-roce.sh" ]]; then
      bash "$SCRIPT_DIR/setup-roce.sh" "$WORKER_SSH"
      # 重新检查
      NEED_ROCE_FIX=0
      HEAD_IP_OUT=$(ip -4 addr show "$ROCE_IFACE" 2>/dev/null | grep inet | awk '{print $2}')
      WORKER_IP_OUT=$(worker_exec_silent "ip -4 addr show $ROCE_IFACE 2>/dev/null | grep inet | awk '{print \$2}'")
      [[ -z "$HEAD_IP_OUT" || -z "$WORKER_IP_OUT" ]] && NEED_ROCE_FIX=1
    else
      fail "setup-roce.sh 不存在或不可执行"
    fi
  else
    info "可执行 ./setup-roce.sh $WORKER_SSH 自动配置，或 ./preflight.sh $WORKER_SSH --auto-fix"
  fi
fi

# 5. 双向 RoCE ping
info "--- RoCE 双向连通性 ---"
if ping -c 2 -W 3 "$WORKER_ROCE_IP" >/dev/null 2>&1; then
  ok "Head 能 ping 通 Worker RoCE ($WORKER_ROCE_IP)"
else
  fail "Head 无法 ping 通 Worker RoCE ($WORKER_ROCE_IP)"
fi

if worker_exec_silent "ping -c 2 -W 3 $HEAD_ROCE_IP >/dev/null 2>&1" ; then
  ok "Worker 能 ping 通 Head RoCE ($HEAD_ROCE_IP)"
else
  fail "Worker 无法 ping 通 Head RoCE ($HEAD_ROCE_IP)"
fi

# 6. GID 检查
info "--- RoCE GID 表检查 ---"
if command -v show_gids >/dev/null 2>&1; then
  ok "Head show_gids 可用"
  HEAD_GID=$(show_gids 2>/dev/null | awk -v dev="$ROCE_IB_DEV" -v ip="$HEAD_ROCE_IP" '$1==dev && $5==ip && $6=="v2" {print $3}')
  if [[ -n "$HEAD_GID" ]]; then
    ok "Head $HEAD_ROCE_IP 对应的 v2 GID index: $HEAD_GID"
  else
    fail "Head $HEAD_ROCE_IP 在 show_gids 中未找到有效 GID"
  fi
else
  warn "Head 上没有 show_gids，使用 /sys 接口回退检查"
fi

if worker_exec_silent "command -v show_gids >/dev/null 2>&1" ; then
  ok "Worker show_gids 可用"
  WORKER_GID=$(worker_exec_silent "show_gids 2>/dev/null | awk -v dev=$ROCE_IB_DEV -v ip=$WORKER_ROCE_IP '\$1==dev && \$5==ip && \$6==\"v2\" {print \$3}'")
  if [[ -n "$WORKER_GID" ]]; then
    ok "Worker $WORKER_ROCE_IP 对应的 v2 GID index: $WORKER_GID"
  else
    fail "Worker $WORKER_ROCE_IP 在 show_gids 中未找到有效 GID"
  fi
else
  warn "Worker 上没有 show_gids，使用 /sys 接口回退检查"
fi

# 7. 端口占用
info "--- 端口占用检查 ---"
for port in 8888 25000; do
  if ss -tlnp 2>/dev/null | grep -q ":$port "; then
    warn "Head 端口 $port 已被占用，启动前会被 stop 脚本清理"
  else
    ok "Head 端口 $port 空闲"
  fi
  if worker_exec_silent "ss -tlnp 2>/dev/null | grep -q ':$port '" ; then
    warn "Worker 端口 $port 已被占用，启动前会被 stop 脚本清理"
  else
    ok "Worker 端口 $port 空闲"
  fi
done

# 8. Docker 镜像
info "--- Docker 镜像 ---"
if sudo docker image inspect ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1 >/dev/null 2>&1; then
  ok "Head 镜像已存在"
else
  fail "Head 缺少镜像 ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1"
fi

if worker_exec_silent "sudo docker image inspect ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1 >/dev/null 2>&1" ; then
  ok "Worker 镜像已存在"
else
  fail "Worker 缺少镜像 ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1"
fi

# 9. 模型路径
info "--- 模型路径 ---"
MODEL_HOST=/data/models/deepseek-ai/DeepSeek-V4-Flash-0731
if [[ -d "$MODEL_HOST" && -f "$MODEL_HOST/config.json" ]]; then
  ok "Head 模型路径存在"
else
  fail "Head 模型路径不存在或缺少 config.json: $MODEL_HOST"
fi

if worker_exec_silent "[[ -d $MODEL_HOST && -f $MODEL_HOST/config.json ]]" ; then
  ok "Worker 模型路径存在"
else
  fail "Worker 模型路径不存在或缺少 config.json: $MODEL_HOST"
fi

# 10. 脚本可执行性
info "--- 启动脚本 ---"
for f in start-all.sh start-head.sh start-worker.sh stop.sh test-api.sh setup-roce.sh; do
  if [[ -x "$SCRIPT_DIR/$f" ]]; then
    ok "$f 可执行"
  else
    warn "$f 不可执行，正在 chmod +x"
    chmod +x "$SCRIPT_DIR/$f"
  fi
done

echo
if [[ "$ERR" -eq 0 ]]; then
  echo "🎉 预检通过，可以执行 ./start-all.sh $WORKER_SSH"
  exit 0
else
  echo "🔧 预检发现上述问题，修复后再启动"
  [[ "$NEED_ROCE_FIX" -eq 1 ]] && echo "    提示：RoCE 配置缺失，可执行 ./setup-roce.sh $WORKER_SSH 或 ./preflight.sh $WORKER_SSH --auto-fix"
  exit 1
fi
