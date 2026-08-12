#!/bin/bash
# ============================================================
# DeepSeek V4 Flash 双机部署 - 配置文件
# 在 Head 和 Worker 节点上使用相同的配置
# ============================================================

# --- Docker 镜像 (必须预先拉取) ---
# IMAGE: Docker 镜像 (registry 地址，新设备上 docker pull 即可获取)
IMAGE="ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1"
# 本地已有测试时可用: IMAGE="ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1"

# --- 模型权重路径 (host 上的绝对路径) ---
MODEL_PATH="/data/models/deepseek-ai/DeepSeek-V4-Flash-0731"
# 容器内挂载路径(无需修改)
MODEL_MOUNT="/models/dsv4"

# --- 网络配置 ---
HEAD_IP="10.10.12.11"             # Head 节点 RoCE IP
WORKER_IP="10.10.12.21"           # Worker 节点 RoCE IP
MASTER_PORT=25000                 # vLLM 分布式通信端口
NCCL_INTF="enp1s0f0np0"          # RoCE 网卡名称 (DGX Spark 默认)
ROCE_SUBNET="10.10.12.0/24"      # RoCE 子网

# 节点角色 (本机是 Head 还是 Worker — prepare.sh 会询问)
NODE_ROLE=""                      # "head" 或 "worker"

# --- 缓存与临时目录 ---
HF_CACHE="/root/.cache/huggingface"   # HF 缓存 (包含 flashinfer workspace)
TMP_DIR="/var/lib/dspark-tmp"         # dspark 临时目录

# --- vLLM 参数 (无需修改) ---
MAX_MODEL_LEN=1048576             # 1M 上下文
MAX_NUM_SEQS=6
TP_SIZE=2
PP_SIZE=1
GPU_MEM=0.78
BLOCK_SIZE=256
MAX_BATCHED_TOKENS=8192
MAX_CUDAGRAPH=72
SERVED_NAME="deepseek-v4-flash"
PORT=8888
