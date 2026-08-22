#!/bin/bash
# ============================================================
# DeepSeek V4 Flash — TP=2 分两组部署 — 公共配置
# 4 台 DGX Spark 拆成 2 组独立 TP=2 服务并行跑：
#   组A = node01 + node02  (master 10.10.10.101:25001, API 8888)
#   组B = node03 + node04  (master 10.10.10.103:25002, API 8889)
# 4 份脚本 (groupA_node01/02.sh, groupB_node03/04.sh) 共用本配置
# ============================================================

# --- Docker 镜像 -------------------------------------------------
IMAGE="anemll-dspark-vllm:latest"
# 或从 registry 拉取（同一镜像，image ID 3430d6614a8e）：
#   IMAGE="ghcr.nju.edu.cn/anemll/dspark-vllm-gx10:0.1.1"

# --- 模型权重路径（4 台机必须相同路径）--------------------------
MODEL_PATH="/data/models/deepseek-ai/DeepSeek-V4-Flash-0731"
MODEL_MOUNT="/models/dsv4"

# --- 网络（RoCE）-----------------------------------------------
NCCL_INTF="enp1s0f0np0"          # RoCE 网卡名
NCCL_IB_HCA="rocep1s0f0"         # InfiniBand HCA 设备名
# GID_INDEX: 本集群 RoCE v2 固定 3（与 MTU 1500/9000 无关）
NCCL_IB_GID_INDEX=3
# NCCL_IB_TC: 106 = DSCP 26 + ECN → priority 3，与节点/交换机 PFC 对齐（无损 RoCE）
NCCL_IB_TC=106

# --- 缓存目录 ---------------------------------------------------
HF_CACHE="/root/.cache/huggingface"
TMP_DIR="/var/lib/dspark-tmp"

# --- vLLM 公共参数（两组一致，与 TP=4 仅差 TP/NNODES/端口）------
SERVED_NAME="deepseek-v4-flash"
TP_SIZE=2                         # 2 节点张量并行
PP_SIZE=1
NNODES=2
MAX_MODEL_LEN=1048576             # 1M 上下文
MAX_NUM_SEQS=6
MAX_BATCHED_TOKENS=8192
MAX_CUDAGRAPH=72
GPU_MEM=0.78
BLOCK_SIZE=256

# --- 组 A（node01 + node02）-------------------------------------
GROUP_A_MASTER_ADDR="10.10.10.101"
GROUP_A_MASTER_PORT=25001
GROUP_A_API_PORT=8888

# --- 组 B（node03 + node04）-------------------------------------
GROUP_B_MASTER_ADDR="10.10.10.103"
GROUP_B_MASTER_PORT=25002
GROUP_B_API_PORT=8889
