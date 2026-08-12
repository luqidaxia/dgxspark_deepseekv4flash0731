#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

# Test the vLLM API endpoint.
# Defaults to head RoCE IP: 10.10.12.11:8888

API_BASE="${API_BASE:-http://10.10.12.11:8888}"

echo "=== /v1/models ==="
curl -s "${API_BASE}/v1/models" | python3 -m json.tool

echo ""
echo "=== /v1/chat/completions (short) ==="
curl -s "${API_BASE}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "用Python写一个快速排序"}],
    "max_tokens": 256,
    "temperature": 0.6
  }' | python3 -m json.tool

echo ""
echo "=== /v1/chat/completions (tool call) ==="
curl -s "${API_BASE}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "北京今天天气怎么样"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get weather of a location",
        "parameters": {
          "type": "object",
          "properties": {"location": {"type": "string"}},
          "required": ["location"]
        }
      }
    }],
    "max_tokens": 256,
    "temperature": 0.6
  }' | python3 -m json.tool
