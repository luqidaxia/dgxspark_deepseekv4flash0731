#!/bin/bash
# ============================================================
# DeepSeek V4 Flash 4 节点 - 镜像离线打包分发脚本（不联网）
# 从一台已有镜像的机器（镜像源），把 Docker 镜像打包并分发给 4 个节点。
#
# 实际拓扑（本集群）：
#   镜像源 spark-3e35 (10.10.15.11 CX7 直连)
#       │  scp 18GB tar（走 CX7 直连，~99 Gbps）
#       ▼
#   node02 (10.10.15.21 CX7 直连, 10.10.10.102 RoCE)
#       │  docker load + scp 18GB tar（走 10.10.10.x RoCE，并行）
#       ├──► node01 (10.10.10.101)
#       ├──► node03 (10.10.10.103)
#       └──► node04 (10.10.10.104)
#
# 用法（在镜像源机器上执行）:
#   bash distribute-image.sh
# 前提:
#   1) 镜像源机器已有目标镜像
#   2) 已配置到 node02 的免密 SSH（含 CX7 直连 IP）
#   3) node02 到 node01/03/04 已免密（走 RoCE IP）
# ============================================================
set -euo pipefail

# --- 可配置项 ------------------------------------------------------
IMAGE="anemll-dspark-vllm:latest"          # 要分发的镜像
TAR_FILE="/tmp/anemll-dspark-vllm.tar"     # 打包临时文件（分发后自动清理）

# node02 的 CX7 直连 IP（第一跳，镜像源 → node02）
NODE02_CX7_IP="10.10.15.21"
# 4 节点 RoCE IP（node02 分发的目标）
NODE01_ROCE_IP="10.10.10.101"
NODE02_ROCE_IP="10.10.10.102"
NODE03_ROCE_IP="10.10.10.103"
NODE04_ROCE_IP="10.10.10.104"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# --- 1. 打包镜像 ----------------------------------------------------
echo "📦 打包镜像 $IMAGE ..."
docker save "$IMAGE" -o "$TAR_FILE"
ls -lh "$TAR_FILE"

# --- 2. 校验 md5 ----------------------------------------------------
LOCAL_MD5=$(md5sum "$TAR_FILE" | awk '{print $1}')
echo "   本地 md5: $LOCAL_MD5"

# --- 3. CX7 直连发给 node02 ------------------------------------------
echo ""
echo "🚀 通过 CX7 直连发给 node02 ($NODE02_CX7_IP) ..."
scp $SSH_OPTS "$TAR_FILE" "root@${NODE02_CX7_IP}:$TAR_FILE"

REMOTE_MD5=$(ssh $SSH_OPTS "root@${NODE02_CX7_IP}" "md5sum $TAR_FILE | awk '{print \$1}'")
if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
    echo "❌ node02 md5 校验失败: $REMOTE_MD5 != $LOCAL_MD5"
    exit 1
fi
echo "✅ node02 md5 校验一致"

# --- 4. node02 docker load（后台）------------------------------------
echo ""
echo "⏳ node02 docker load（后台）..."
ssh $SSH_OPTS "root@${NODE02_CX7_IP}" "docker load -i $TAR_FILE" &
NODE02_LOAD_PID=$!

# --- 5. node02 走 RoCE 并行分发给 node01/03/04 -----------------------
echo "⏳ node02 走 RoCE 并行分发给 node01/03/04 ..."
ssh $SSH_OPTS "root@${NODE02_CX7_IP}" "
    for ip in $NODE01_ROCE_IP $NODE03_ROCE_IP $NODE04_ROCE_IP; do
        scp $SSH_OPTS $TAR_FILE root@\$ip:$TAR_FILE &
    done
    wait
"

# --- 6. 各节点 docker load -------------------------------------------
echo ""
echo "⏳ 各节点 docker load ..."
for ip in $NODE01_ROCE_IP $NODE03_ROCE_IP $NODE04_ROCE_IP; do
    ssh $SSH_OPTS "root@${NODE02_CX7_IP}" "ssh $SSH_OPTS root@$ip 'docker load -i $TAR_FILE'" &
done
wait

# 等待 node02 的 load 完成
wait $NODE02_LOAD_PID 2>/dev/null || true

# --- 7. 校验各节点镜像 -------------------------------------------------
echo ""
echo "✅ 校验各节点镜像:"
for ip in $NODE01_ROCE_IP $NODE02_ROCE_IP $NODE03_ROCE_IP $NODE04_ROCE_IP; do
    echo -n "   $ip: "
    ssh $SSH_OPTS "root@${NODE02_CX7_IP}" "ssh $SSH_OPTS root@$ip 'docker images --format \"{{.Repository}}:{{.Tag}} {{.ID}}\" | grep $IMAGE'" 2>/dev/null \
        || echo "⚠️  校验失败"
done

# --- 8. 清理临时文件 ---------------------------------------------------
echo ""
echo "🧹 清理临时 tar ..."
rm -f "$TAR_FILE"
ssh $SSH_OPTS "root@${NODE02_CX7_IP}" "rm -f $TAR_FILE; for ip in $NODE01_ROCE_IP $NODE03_ROCE_IP $NODE04_ROCE_IP; do ssh $SSH_OPTS root@\$ip rm -f $TAR_FILE; done"

echo ""
echo "🎉 镜像分发完成！4 个节点均已就位 $IMAGE"
