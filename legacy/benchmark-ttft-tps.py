#!/usr/bin/env python3
"""Benchmark TTFT and TPS for the deployed DeepSeek V4 Flash vLLM endpoint.

Supports single-stream and concurrent streaming requests. Outputs latency
percentiles, per-request TPS, and aggregate throughput to console and JSON.

Usage examples:
    # Single request, short prompt, 256 output tokens
    python3 benchmark-ttft-tps.py -n 1 -c 1 --max-tokens 256

    # 10 requests, concurrency 4, 1024-token prompt, 512 output tokens
    python3 benchmark-ttft-tps.py -n 10 -c 4 --prompt-len 1024 --max-tokens 512

    # Save results to JSON
    python3 benchmark-ttft-tps.py -n 20 -c 8 --output results.json
"""

import argparse
import json
import re
import statistics
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List, Optional

import requests


DEFAULT_API_BASE = "http://10.10.12.11:8888"
DEFAULT_MODEL = "deepseek-v4-flash"

# A pool of Chinese characters/phrases where each character is roughly one token.
# Used to build prompts of approximate target length.
PROMPT_TOKEN_POOL = (
    "深度学习模型神经网络自然语言处理技术不断发展人工智能系统变得更加智能高效"
    "大规模预训练语言模型能够理解和生成人类语言并完成多种复杂任务"
    "分布式推理系统采用张量并行数据并行提升吞吐降低延迟"
    "DeepSeekV4Flash针对推理优化支持FP8量化NVFP4KVCache加速"
)


def build_prompt(target_len: int) -> str:
    """Build a prompt of approximately target_len tokens.

    For Chinese-dominant text, each character is approximately one token,
    so we repeat the pool and take `target_len` characters. Punctuation and
    whitespace are kept minimal so the character count closely tracks tokens.
    """
    if target_len <= 0:
        return "你好，请简单介绍一下自己。"
    pool = PROMPT_TOKEN_POOL
    repeats = (target_len // len(pool)) + 1
    prompt = (pool * repeats)[:target_len]
    return prompt


def parse_sse_chunk(chunk: bytes) -> List[Dict[str, Any]]:
    """Parse one SSE chunk that may contain multiple data lines."""
    events: List[Dict[str, Any]] = []
    text = chunk.decode("utf-8", errors="replace")
    for line in text.split("\n"):
        line = line.strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            events.append({"done": True})
            continue
        try:
            events.append(json.loads(data))
        except json.JSONDecodeError:
            # Malformed chunk, ignore
            continue
    return events


def count_tokens_in_delta(event: Dict[str, Any]) -> int:
    """Count tokens in a chat.completion chunk."""
    delta = (
        event.get("choices", [{}])[0]
        .get("delta", {})
    )
    content = delta.get("content", "") or ""
    reasoning = delta.get("reasoning_content", "") or ""
    # Approximate token count by characters. For CJK, 1 char ≈ 1 token;
    # for whitespace-separated English, split into words.
    # This is a heuristic, not an exact tokenizer count.
    text = content + reasoning
    if not text:
        return 0
    cjk_chars = len(re.findall(r"[\u4e00-\u9fff]", text))
    other = text
    for c in text:
        if "\u4e00" <= c <= "\u9fff":
            other = other.replace(c, " ")
    words = len(other.split())
    return max(cjk_chars + words, 1)


def benchmark_request(
    api_base: str,
    model: str,
    prompt: str,
    max_tokens: int,
    temperature: float,
    top_p: float,
    request_id: int,
) -> Dict[str, Any]:
    """Run a single streaming request and record timing metrics."""
    url = f"{api_base}/v1/chat/completions"
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "top_p": top_p,
        "stream": True,
    }
    headers = {"Content-Type": "application/json"}

    start_time = time.perf_counter()
    first_byte_time: Optional[float] = None
    first_token_time: Optional[float] = None
    last_token_time: Optional[float] = None
    token_count = 0
    total_chunk_bytes = 0
    chunks = 0
    response_text = ""

    try:
        with requests.post(
            url,
            json=payload,
            headers=headers,
            stream=True,
            timeout=300,
        ) as resp:
            resp.raise_for_status()
            for chunk in resp.iter_content(chunk_size=None):
                chunks += 1
                total_chunk_bytes += len(chunk)
                now = time.perf_counter()
                if first_byte_time is None:
                    first_byte_time = now
                events = parse_sse_chunk(chunk)
                for event in events:
                    if event.get("done"):
                        continue
                    n = count_tokens_in_delta(event)
                    if n > 0:
                        if first_token_time is None:
                            first_token_time = now
                        token_count += n
                        last_token_time = now
                        # Collect a sample of generated text for sanity
                        d = event.get("choices", [{}])[0].get("delta", {})
                        response_text += d.get("content", "") or ""
    except Exception as e:
        return {
            "request_id": request_id,
            "error": str(e),
        }

    end_time = time.perf_counter()
    total_latency = end_time - start_time

    metrics = {
        "request_id": request_id,
        "prompt_text_len": len(prompt),
        "max_tokens": max_tokens,
        "first_byte_latency_ms": (
            (first_byte_time - start_time) * 1000
            if first_byte_time else None
        ),
        "ttft_ms": (
            (first_token_time - start_time) * 1000
            if first_token_time else None
        ),
        "total_latency_ms": total_latency * 1000,
        "generation_time_ms": (
            (last_token_time - first_token_time) * 1000
            if first_token_time and last_token_time else None
        ),
        "tokens_generated": token_count,
        "tps": (
            token_count / (last_token_time - first_token_time)
            if first_token_time and last_token_time and (last_token_time > first_token_time)
            else 0.0
        ),
        "chunks": chunks,
        "total_chunk_bytes": total_chunk_bytes,
        "output_preview": response_text[:200],
    }
    return metrics


def percentile(values: List[float], p: float) -> float:
    """Compute percentile of a sorted list."""
    if not values:
        return 0.0
    sorted_vals = sorted(values)
    k = (len(sorted_vals) - 1) * p
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    if f == c:
        return sorted_vals[f]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def summarize(name: str, values: List[float]) -> Dict[str, float]:
    if not values:
        return {}
    return {
        "count": len(values),
        "min": min(values),
        "max": max(values),
        "mean": statistics.mean(values),
        "median": statistics.median(values),
        "p90": percentile(values, 0.90),
        "p99": percentile(values, 0.99),
        "std": statistics.stdev(values) if len(values) > 1 else 0.0,
    }


def run_benchmark(args) -> Dict[str, Any]:
    prompt = build_prompt(args.prompt_len)
    actual_prompt_len = len(prompt)
    print(f"Prompt approximate length: {actual_prompt_len} chars (target: {args.prompt_len})")
    print(f"API base: {args.api_base}")
    print(f"Model: {args.model}")
    print(f"Requests: {args.num_requests}, concurrency: {args.concurrency}")
    print(f"Max tokens: {args.max_tokens}, temperature: {args.temperature}")
    print("-" * 60)

    results: List[Dict[str, Any]] = []
    lock = threading.Lock()
    completed = 0

    def submit(i: int) -> Dict[str, Any]:
        return benchmark_request(
            args.api_base,
            args.model,
            prompt,
            args.max_tokens,
            args.temperature,
            args.top_p,
            i,
        )

    def wrapped(i: int) -> Dict[str, Any]:
        nonlocal completed
        res = submit(i)
        with lock:
            completed += 1
            print(f"  [{completed}/{args.num_requests}] request {i} done", end="\r")
        return res

    overall_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = [executor.submit(wrapped, i) for i in range(args.num_requests)]
        for future in as_completed(futures):
            results.append(future.result())
    overall_end = time.perf_counter()

    print()

    # Split successes and failures
    successes = [r for r in results if "error" not in r]
    failures = [r for r in results if "error" in r]

    if failures:
        print(f"WARNING: {len(failures)} requests failed")
        for f in failures[:5]:
            print(f"  request {f['request_id']}: {f['error']}")

    if not successes:
        print("No successful requests. Aborting.")
        sys.exit(1)

    ttft = [r["ttft_ms"] for r in successes if r["ttft_ms"] is not None]
    tps = [r["tps"] for r in successes if r["tps"] is not None]
    total_latency = [r["total_latency_ms"] for r in successes]
    gen_time = [r["generation_time_ms"] for r in successes if r["generation_time_ms"] is not None]
    tokens = [r["tokens_generated"] for r in successes]

    total_tokens = sum(tokens)
    throughput = total_tokens / (overall_end - overall_start)

    report = {
        "config": {
            "api_base": args.api_base,
            "model": args.model,
            "num_requests": args.num_requests,
            "concurrency": args.concurrency,
            "prompt_len_chars": actual_prompt_len,
            "prompt_target_tokens": args.prompt_len,
            "max_tokens": args.max_tokens,
            "temperature": args.temperature,
            "top_p": args.top_p,
        },
        "summary": {
            "successful_requests": len(successes),
            "failed_requests": len(failures),
            "total_tokens_generated": total_tokens,
            "overall_duration_sec": overall_end - overall_start,
            "aggregate_output_tokens_per_sec": throughput,
            "ttft_ms": summarize("TTFT", ttft),
            "tps": summarize("TPS", tps),
            "total_latency_ms": summarize("Total latency", total_latency),
            "generation_time_ms": summarize("Generation time", gen_time),
            "tokens_per_request": summarize("Tokens per request", tokens),
        },
        "requests": successes + failures,
    }
    return report


def print_report(report: Dict[str, Any]) -> None:
    print("=" * 60)
    print("BENCHMARK RESULTS")
    print("=" * 60)
    cfg = report["config"]
    print(f"API base:      {cfg['api_base']}")
    print(f"Model:         {cfg['model']}")
    print(f"Requests:      {cfg['num_requests']} (concurrency {cfg['concurrency']})")
    print(f"Prompt len:    {cfg['prompt_len_chars']} chars (approx {cfg['prompt_target_tokens']} tokens)")
    print(f"Max tokens:    {cfg['max_tokens']}")
    print()

    sm = report["summary"]
    print(f"Successful:    {sm['successful_requests']}")
    print(f"Failed:        {sm['failed_requests']}")
    print(f"Overall time:  {sm['overall_duration_sec']:.2f} s")
    print(f"Total tokens:  {sm['total_tokens_generated']}")
    print(f"Throughput:    {sm['aggregate_output_tokens_per_sec']:.2f} tok/s (aggregate)")
    print()

    def print_metric(label: str, data: Dict[str, float]) -> None:
        if not data:
            return
        print(f"{label}:")
        print(
            f"  mean={data['mean']:.2f} median={data['median']:.2f} "
            f"p90={data['p90']:.2f} p99={data['p99']:.2f} "
            f"min={data['min']:.2f} max={data['max']:.2f}"
        )

    print_metric("TTFT (ms)", sm["ttft_ms"])
    print_metric("TPS (tok/s)", sm["tps"])
    print_metric("Generation time (ms)", sm["generation_time_ms"])
    print_metric("Total latency (ms)", sm["total_latency_ms"])


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Benchmark TTFT and TPS for DeepSeek V4 Flash vLLM endpoint.",
    )
    parser.add_argument(
        "--api-base",
        default=DEFAULT_API_BASE,
        help=f"vLLM API base URL (default: {DEFAULT_API_BASE})",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Model name (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "-n", "--num-requests",
        type=int,
        default=10,
        help="Total number of requests to send (default: 10)",
    )
    parser.add_argument(
        "-c", "--concurrency",
        type=int,
        default=1,
        help="Number of concurrent requests (default: 1)",
    )
    parser.add_argument(
        "--prompt-len",
        type=int,
        default=64,
        help="Approximate prompt length in tokens (default: 64)",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=512,
        help="Max tokens to generate per request (default: 512)",
    )
    parser.add_argument(
        "--temperature",
        type=float,
        default=0.6,
        help="Sampling temperature (default: 0.6)",
    )
    parser.add_argument(
        "--top-p",
        type=float,
        default=0.95,
        help="Top-p sampling (default: 0.95)",
    )
    parser.add_argument(
        "-o", "--output",
        default=None,
        help="Write JSON report to this file",
    )
    args = parser.parse_args()

    report = run_benchmark(args)
    print_report(report)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        print(f"\nReport saved to: {args.output}")


if __name__ == "__main__":
    main()
