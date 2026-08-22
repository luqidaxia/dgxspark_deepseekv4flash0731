#!/bin/bash
# ============================================================
# DeepSeek V4 Flash 4 节点 TP=4 部署 - 配置文件
# 4 台 NVIDIA DGX Spark (GB10, 128GB 统一内存) 通过 RoCE 互联
# 4 份启动脚本 (node01.sh ~ node04.sh) 共用本配置
# ============================================================

# --- Docker 镜像 -------------------------------------------------
# 推荐：本机 docker save 打包分发后的本地镜像（未联网）
IMAGE="anemll-dspark-vllm:latest"
# 或者从 registry 拉取（与上面是同一镜像，image ID 3430d6614a8e）：
#   IMAGE="ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1"

# --- 模型权重路径（4 台机必须放在相同路径）--------------------------
MODEL_PATH="/data/models/deepseek-ai/DeepSeek-V4-Flash-0731"
# 容器内挂载路径（无需修改）
MODEL_MOUNT="/models/dsv4"

# --- 网络配置（RoCE）-----------------------------------------------
MASTER_ADDR="10.10.10.101"       # head (node01) 的 RoCE IP
MASTER_PORT=25000                 # vLLM 分布式通信端口
NCCL_INTF="enp1s0f0np0"          # RoCE 网卡名（DGX Spark 默认）
NCCL_IB_HCA="rocep1s0f0"         # InfiniBand HCA 设备名
# GID_INDEX: MTU=1500 → 3（本集群实际值），MTU=9000 → 5
# 启动脚本会自动检测 MTU 并覆盖该值
NCCL_IB_GID_INDEX=3

# --- 4 节点 RoCE IP 映射 -------------------------------------------
NODE01_IP="10.10.10.101"         # head,  rank 0
NODE02_IP="10.10.10.102"         # worker rank 1
NODE03_IP="10.10.10.103"         # worker rank 2
NODE04_IP="10.10.10.104"         # worker rank 3

# --- 缓存与临时目录 ------------------------------------------------
HF_CACHE="/root/.cache/huggingface"   # HF 缓存（含 flashinfer workspace）
TMP_DIR="/var/lib/dspark-tmp"         # dspark 推测解码临时 buffer

# --- vLLM 参数（无需修改）--------------------------------------------
SERVED_NAME="deepseek-v4-flash"
PORT=8888
TP_SIZE=4                         # 4 节点张量并行
PP_SIZE=1
MAX_MODEL_LEN=1048576             # 1M 上下文
MAX_NUM_SEQS=6
MAX_BATCHED_TOKENS=8192
MAX_CUDAGRAPH=72
GPU_MEM=0.78
BLOCK_SIZE=256
