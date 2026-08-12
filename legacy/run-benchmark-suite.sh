#!/usr/bin/env bash
# Convenience wrapper to run common TTFT/TPS benchmark scenarios.
# Adjust --api-base / --model if your endpoint differs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="${SCRIPT_DIR}/benchmark-ttft-tps.py"
OUT_DIR="${SCRIPT_DIR}/benchmark-results"
mkdir -p "${OUT_DIR}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

run() {
  local name=$1
  shift
  echo "=============================================="
  echo "Scenario: ${name}"
  echo "=============================================="
  python3 "${BENCH}" "$@" -o "${OUT_DIR}/${TIMESTAMP}-${name}.json"
  echo
}

# Light smoke test
run "smoke-n1-c1-short" -n 1 -c 1 --prompt-len 64 --max-tokens 64

# TTFT focused: vary prompt length, single stream
run "ttft-prompt-256" -n 5 -c 1 --prompt-len 256 --max-tokens 128
run "ttft-prompt-1024" -n 5 -c 1 --prompt-len 1024 --max-tokens 128
run "ttft-prompt-4096" -n 5 -c 1 --prompt-len 4096 --max-tokens 128

# TPS focused: long output, single stream
run "tps-output-512" -n 5 -c 1 --prompt-len 512 --max-tokens 512
run "tps-output-1024" -n 5 -c 1 --prompt-len 512 --max-tokens 1024

# Concurrency sweep
run "conc-2" -n 10 -c 2 --prompt-len 512 --max-tokens 512
run "conc-4" -n 16 -c 4 --prompt-len 512 --max-tokens 512
run "conc-8" -n 24 -c 8 --prompt-len 512 --max-tokens 512

echo "All benchmark results saved to: ${OUT_DIR}"
ls -l "${OUT_DIR}/${TIMESTAMP}"-*
