#!/bin/bash
# ============================================================
# DeepSeek V4 Flash 双机部署 - 环境准备脚本
# 用法: bash prepare.sh
# 功能: 交互式菜单，逐步完成 Docker 镜像下载、模型权重下载、RoCE 网络配置
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; }
step()  { echo -e "\n${BLUE}▶ $*${NC}"; }
ask()   { echo -e "${CYAN}[?]${NC} $*"; }

# ============================================================
# 步骤 1: 拉取 Docker 镜像
# ============================================================
do_pull_image() {
    step "1/3 拉取 Docker 镜像: ${IMAGE}"

    if docker image inspect "$IMAGE" &>/dev/null; then
        warn "镜像已存在，跳过下载"
        docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}" | grep "dspark-vllm"
        return 0
    fi

    echo "开始下载 Docker 镜像 (约 20 GB，请耐心等待)..."
    if docker pull "$IMAGE"; then
        info "镜像下载完成"
    else
        error "镜像下载失败，请检查网络或镜像地址"
        return 1
    fi
}

# ============================================================
# 步骤 2: 下载模型权重 (ModelScope)
# ============================================================
do_download_model() {
    step "2/3 下载模型权重: deepseek-ai/DeepSeek-V4-Flash-0731"

    if [ -d "$MODEL_PATH" ] && [ "$(ls -A "$MODEL_PATH" 2>/dev/null)" ]; then
        MODEL_SIZE=$(du -sh "$MODEL_PATH" 2>/dev/null | cut -f1)
        warn "模型目录已存在: $MODEL_PATH ($MODEL_SIZE)"
        read -r -p "     已存在，是否重新下载? [y/N] " yn
        if [[ ! "$yn" =~ ^[Yy] ]]; then
            info "跳过下载"
            return 0
        fi
        rm -rf "$MODEL_PATH"
    fi

    # 安装 ModelScope CLI
    if ! command -v modelscope &>/dev/null; then
        echo "安装 modelscope..."
        pip install modelscope -q
    fi
    info "modelscope 已就绪"

    # 创建目标目录
    mkdir -p "$MODEL_PATH"

    echo "开始从 ModelScope 下载模型 (约 156 GB，预计 30-90 分钟)..."
    echo "目标路径: $MODEL_PATH"
    echo ""

    if modelscope download --model deepseek-ai/DeepSeek-V4-Flash-0731 --local_dir "$MODEL_PATH"; then
        MODEL_SIZE=$(du -sh "$MODEL_PATH" | cut -f1)
        info "模型下载完成 ($MODEL_SIZE)"
    else
        error "模型下载失败"
        return 1
    fi
}

# ============================================================
# 步骤 3: 配置 RoCE 网络
# ============================================================
do_setup_roce() {
    step "3/3 配置 RoCE 网络"

    # --- 检测本机角色 ---
    if [ -z "$NODE_ROLE" ] || [ "$NODE_ROLE" != "head" ] && [ "$NODE_ROLE" != "worker" ]; then
        echo ""
        echo "  本机是 Head 还是 Worker?"
        echo "    1) Head  (Master, RoCE IP: $HEAD_IP)"
        echo "    2) Worker (RoCE IP: $WORKER_IP)"
        read -r -p "  请选择 [1/2]: " role_choice
        case $role_choice in
            1) NODE_ROLE="head" ;;
            2) NODE_ROLE="worker" ;;
            *) error "无效选择"; return 1 ;;
        esac
    fi

    if [ "$NODE_ROLE" = "head" ]; then
        ROCE_IP="$HEAD_IP"
    else
        ROCE_IP="$WORKER_IP"
    fi
    info "本机角色: $NODE_ROLE → RoCE IP: $ROCE_IP"

    # --- 检查网卡是否存在 ---
    if ! ip link show "$NCCL_INTF" &>/dev/null; then
        error "RoCE 网卡 $NCCL_INTF 不存在"
        echo "  可用网卡:"
        ip -br link show | grep -v lo | awk '{print "    " $1}'
        return 1
    fi
    info "网卡 $NCCL_INTF 已检测到"

    # --- 配置 IP ---
    CURRENT_IP=$(ip -4 addr show "$NCCL_INTF" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ "$CURRENT_IP" = "$ROCE_IP" ]; then
        warn "IP $ROCE_IP 已配置，跳过"
    else
        if [ -n "$CURRENT_IP" ]; then
            warn "当前 IP: $CURRENT_IP，将替换为 $ROCE_IP"
            ip addr del "$CURRENT_IP/24" dev "$NCCL_INTF" 2>/dev/null || true
        fi
        ip addr add "${ROCE_IP}/24" dev "$NCCL_INTF"
        info "IP 已配置: $ROCE_IP/24"
    fi

    # --- 启用网卡 ---
    ip link set "$NCCL_INTF" up
    info "网卡已启用"

    # --- 配置 MTU ---
    CURRENT_MTU=$(ip link show "$NCCL_INTF" | grep -oP 'mtu \K[0-9]+')
    if [ "$CURRENT_MTU" = "9000" ]; then
        warn "MTU 已是 9000，跳过"
    else
        ip link set "$NCCL_INTF" mtu 9000
        info "MTU 已设为 9000 (原: $CURRENT_MTU)"
    fi

    # --- 防止 NetworkManager 覆盖 ---
    if command -v nmcli &>/dev/null; then
        nmcli dev set "$NCCL_INTF" managed no 2>/dev/null || true
        info "NetworkManager 已禁用对此网卡的管理"
    fi

    # --- 验证 ---
    CURRENT_MTU=$(ip link show "$NCCL_INTF" | grep -oP 'mtu \K[0-9]+')
    echo ""
    info "RoCE 配置验证:"
    ip -br addr show "$NCCL_INTF"
    echo "  MTU: $CURRENT_MTU"
    echo "  GID_INDEX: $([ "$CURRENT_MTU" = "9000" ] && echo 5 || echo 3)"
}

# ============================================================
# 一键全部执行
# ============================================================
do_all() {
    echo ""
    echo "========================================"
    echo " 一键执行全部环境准备"
    echo "========================================"
    echo ""

    do_pull_image        || { error "镜像下载失败，中止"; return 1; }
    do_setup_roce        || { error "RoCE 配置失败，中止"; return 1; }
    do_download_model    || { error "模型下载失败，中止"; return 1; }

    echo ""
    echo "========================================"
    info "全部环境准备完成！"
    echo "========================================"
    echo ""
    echo "下一步:"
    echo "  本机是 Head:   bash start-head.sh"
    echo "  本机是 Worker: bash start-worker.sh"
}

# ============================================================
# 主菜单
# ============================================================
show_menu() {
    clear 2>/dev/null || true
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║   DeepSeek V4 Flash 双机部署 - 环境准备       ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  镜像: ${IMAGE}                              ║"
    echo "║  模型: ${MODEL_PATH}                          ║"
    echo "║  网卡: ${NCCL_INTF}                              ║"
    echo "║  Head: ${HEAD_IP}  Worker: ${WORKER_IP}          ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║                                               ║"
    echo "║  1) 拉取 Docker 镜像   (约 20 GB)              ║"
    echo "║  2) 下载模型权重       (约 156 GB, ModelScope)  ║"
    echo "║  3) 配置 RoCE 网络     (IP + MTU)              ║"
    echo "║                                               ║"
    echo "║  9) 一键全部执行       (1 → 3 → 2)             ║"
    echo "║                                               ║"
    echo "║  q) 退出                                       ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
}

# --- 主循环 ---
while true; do
    show_menu
    read -r -p "  请选择 > " choice
    case $choice in
        1) do_pull_image ;;
        2) do_download_model ;;
        3) do_setup_roce ;;
        9) do_all ;;
        q|Q) echo "退出"; exit 0 ;;
        *)  echo "无效选择" ;;
    esac

    # 非一键模式，执行完一项后暂停
    if [ "$choice" != "9" ] && [ "$choice" != "q" ] && [ "$choice" != "Q" ]; then
        echo ""
        read -r -p "按 Enter 返回菜单..."
    fi
done
