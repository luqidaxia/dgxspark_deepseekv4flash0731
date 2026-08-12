#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

# 配置双节点 RoCE 网络（Head + Worker）
# 用法：./setup-roce.sh [WORKER_SSH]
# 默认 Worker：root@192.168.22.161

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER_SSH="${1:-root@192.168.22.161}"
WORKER_PASS="${WORKER_PASS:-YOUR_WORKER_PASSWORD}"

HEAD_ROCE_IP="${HEAD_ROCE_IP:-10.10.12.11}"
WORKER_ROCE_IP="${WORKER_ROCE_IP:-10.10.12.21}"
ROCE_IFACE="${ROCE_IFACE:-enp1s0f0np0}"
ROCE_PREFIX="${ROCE_PREFIX:-24}"
ROCE_MTU="${ROCE_MTU:-9000}"

# 在 Worker 上执行命令
worker_exec() {
  sshpass -p "$WORKER_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$WORKER_SSH" "$@"
}

log() { echo "===> $*"; }
info() { echo "     $*"; }
warn() { echo "⚠️  $*"; }

configure_iface() {
  local node_name="$1"
  local target_ip="$2"
  local exec_cmd="$3"   # function name to execute commands on the node

  log "配置 $node_name 的 $ROCE_IFACE -> $target_ip/$ROCE_PREFIX"

  # 检查当前 IP
  local current_ip
  current_ip=$($exec_cmd "ip -4 addr show $ROCE_IFACE 2>/dev/null | grep inet | awk '{print \$2}' | head -1" 2>/dev/null) || current_ip=""

  if [[ -n "$current_ip" ]]; then
    if [[ "$current_ip" == "$target_ip/$ROCE_PREFIX" ]]; then
      info "$node_name $ROCE_IFACE 已经是 $target_ip/$ROCE_PREFIX"
    else
      info "$node_name $ROCE_IFACE 当前为 $current_ip，先移除旧地址"
      $exec_cmd "sudo ip addr del $current_ip dev $ROCE_IFACE 2>/dev/null || true"
      $exec_cmd "sudo ip addr add $target_ip/$ROCE_PREFIX dev $ROCE_IFACE"
      info "$node_name $ROCE_IFACE 已设为 $target_ip/$ROCE_PREFIX"
    fi
  else
    $exec_cmd "sudo ip addr add $target_ip/$ROCE_PREFIX dev $ROCE_IFACE"
    info "$node_name $ROCE_IFACE 已设为 $target_ip/$ROCE_PREFIX"
  fi

  # 设置 MTU
  local current_mtu
  current_mtu=$($exec_cmd "ip link show $ROCE_IFACE 2>/dev/null | grep -oP 'mtu \\K\\d+'" 2>/dev/null) || current_mtu=""
  if [[ "$current_mtu" != "$ROCE_MTU" ]]; then
    $exec_cmd "sudo ip link set mtu $ROCE_MTU dev $ROCE_IFACE"
    info "$node_name $ROCE_IFACE MTU 已设为 $ROCE_MTU"
  else
    info "$node_name $ROCE_IFACE MTU 已是 $ROCE_MTU"
  fi

  # NetworkManager 不管理 RoCE 口，避免地址被清
  $exec_cmd "sudo nmcli dev set $ROCE_IFACE managed no 2>/dev/null || true"
  info "$node_name $ROCE_IFACE 已设为 NetworkManager unmanaged"
}

persist_netplan() {
  local node_name="$1"
  local target_ip="$2"
  local exec_cmd="$3"

  log "持久化 $node_name 的 $ROCE_IFACE 配置（netplan）"

  local netplan_file="/etc/netplan/99-roce-${ROCE_IFACE}.yaml"
  local yaml_content
  yaml_content=$(cat <<EOF
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    ${ROCE_IFACE}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${target_ip}/${ROCE_PREFIX}
      mtu: ${ROCE_MTU}
EOF
)

  # 写入 netplan 配置文件
  $exec_cmd "cat > /tmp/roce-netplan.yaml <<'EOF'
$yaml_content
EOF
  sudo mv /tmp/roce-netplan.yaml $netplan_file
  sudo chmod 600 $netplan_file
  sudo netplan apply 2>/dev/null || true
  "

  info "$node_name $netplan_file 已写入并尝试 netplan apply"
}

persist_nmcli() {
  local node_name="$1"
  local target_ip="$2"
  local exec_cmd="$3"

  log "尝试用 nmcli 持久化 $node_name 的 $ROCE_IFACE"

  if ! $exec_cmd "command -v nmcli >/dev/null 2>&1" ; then
    warn "$node_name 没有 nmcli"
    return 1
  fi

  local conn_name
  conn_name=$($exec_cmd "nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":${ROCE_IFACE}$" | head -1 | cut -d: -f1" 2>/dev/null) || conn_name=""

  if [[ -z "$conn_name" ]]; then
    # 没有活跃连接，可能是网卡未被 NM 管理。尝试创建一个
    conn_name="roce-${ROCE_IFACE}"
    $exec_cmd "sudo nmcli connection add type ethernet ifname $ROCE_IFACE con-name \"$conn_name\" 2>/dev/null || true" || true
  fi

  if [[ -n "$conn_name" ]]; then
    $exec_cmd "sudo nmcli connection modify \"$conn_name\" \
      ipv4.addresses ${target_ip}/${ROCE_PREFIX} \
      ipv4.method manual \
      802-3-ethernet.mtu ${ROCE_MTU} \
      connection.autoconnect yes 2>/dev/null" || true
    $exec_cmd "sudo nmcli connection up \"$conn_name\" 2>/dev/null || true"
    info "$node_name $ROCE_IFACE 已通过 nmcli 持久化"
    return 0
  fi

  return 1
}

persist_iface() {
  local node_name="$1"
  local target_ip="$2"
  local exec_cmd="$3"

  # 优先 nmcli，失败则回退 netplan
  if persist_nmcli "$node_name" "$target_ip" "$exec_cmd"; then
    return 0
  fi

  if $exec_cmd "command -v netplan >/dev/null 2>&1" ; then
    persist_netplan "$node_name" "$target_ip" "$exec_cmd"
    return 0
  fi

  warn "$node_name 没有 nmcli/netplan，RoCE 配置仅临时生效，重启后会丢失"
  warn "请手动将以下配置写入网络配置文件："
  warn "  iface: $ROCE_IFACE"
  warn "  address: $target_ip/$ROCE_PREFIX"
  warn "  mtu: $ROCE_MTU"
}

# 1. 检查本地工具
for tool in sshpass sudo ip nmcli; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    warn "本机缺少 $tool"
  fi
done

# 2. 检查 Worker SSH
if ! worker_exec "echo hello" >/dev/null 2>&1; then
  echo "❌ SSH 到 Worker ($WORKER_SSH) 失败，请检查密码/网络"
  exit 1
fi
info "Worker SSH 正常"

# 3. 配置 Head
configure_iface "Head" "$HEAD_ROCE_IP" "bash -c"
persist_iface "Head" "$HEAD_ROCE_IP" "bash -c"

# 4. 配置 Worker
configure_iface "Worker" "$WORKER_ROCE_IP" "worker_exec"
persist_iface "Worker" "$WORKER_ROCE_IP" "worker_exec"

# 5. 验证双向连通
log "验证 RoCE 双向连通性"
if ping -c 3 -W 3 "$WORKER_ROCE_IP" >/dev/null 2>&1; then
  info "Head 能 ping 通 Worker ($WORKER_ROCE_IP)"
else
  warn "Head 无法 ping 通 Worker ($WORKER_ROCE_IP)"
fi

if worker_exec "ping -c 3 -W 3 $HEAD_ROCE_IP >/dev/null 2>&1" ; then
  info "Worker 能 ping 通 Head ($HEAD_ROCE_IP)"
else
  warn "Worker 无法 ping 通 Head ($HEAD_ROCE_IP)"
fi

# 6. 显示 GID 表
log "当前两端 GID 表（用于核对 NCCL_IB_GID_INDEX）："
info "Head:"
show_gids 2>/dev/null | grep "$HEAD_ROCE_IP" || true
info "Worker:"
worker_exec "show_gids 2>/dev/null | grep $WORKER_ROCE_IP" || true

log "RoCE 配置完成"
