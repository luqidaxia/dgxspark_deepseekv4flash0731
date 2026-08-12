#!/usr/bin/env python3
"""Run a benchmark matrix for DeepSeek V4 Flash and generate a PDF report.

Matrix:
  Concurrency : 1, 3, 5, 8, 10
  Input  len  : 50, 500, 1024, 2048 (approximate tokens)
  Output len  : same as input (symmetric pairs)

Outputs:
  - Raw JSON per cell under benchmark-results/matrix-<timestamp>/
  - Markdown report: benchmark-results/matrix-<timestamp>-report.md
  - PDF report:      benchmark-results/matrix-<timestamp>-report.pdf
"""

import argparse
import importlib.util
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime
from threading import Lock
from typing import Any, Dict, List, Optional

# Load the standalone benchmark script (its filename contains hyphens).
_bench_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "benchmark-ttft-tps.py")
_spec = importlib.util.spec_from_file_location("benchmark_ttft_tps", _bench_path)
_bench_mod = importlib.util.module_from_spec(_spec)
_sys = sys
_sys.modules["benchmark_ttft_tps"] = _bench_mod
_spec.loader.exec_module(_bench_mod)
benchmark_request = _bench_mod.benchmark_request
build_prompt = _bench_mod.build_prompt

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm
from reportlab.platypus import (
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
    PageBreak,
)


API_BASE = "http://10.10.12.11:8888"
MODEL = "deepseek-v4-flash"
CONCURRENCIES = [1, 3, 5, 8, 10]
TOKEN_LENS = [50, 500, 1024, 2048]


@dataclass
class CellResult:
    concurrency: int
    prompt_len: int
    max_tokens: int
    num_requests: int
    ttft_mean: float
    ttft_p50: float
    ttft_p90: float
    ttft_p99: float
    tps_mean: float
    tps_p50: float
    tps_p90: float
    throughput: float
    gen_time_mean: float
    total_latency_mean: float
    success: int
    failure: int


def percentile(values: List[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * p
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


def run_cell(concurrency: int, prompt_len: int, max_tokens: int) -> CellResult:
    num_requests = max(concurrency, 3)
    prompt = build_prompt(prompt_len)
    print(f"\n>>> Cell: concurrency={concurrency}, prompt={prompt_len}, max_tokens={max_tokens}, n={num_requests}")

    results: List[Dict[str, Any]] = []
    lock = Lock()
    completed = 0

    def task(i: int) -> Dict[str, Any]:
        return benchmark_request(
            api_base=API_BASE,
            model=MODEL,
            prompt=prompt,
            max_tokens=max_tokens,
            temperature=0.6,
            top_p=0.95,
            request_id=i,
        )

    def wrapped(i: int) -> Dict[str, Any]:
        nonlocal completed
        res = task(i)
        with lock:
            completed += 1
            print(f"  [{completed}/{num_requests}] done", end="\r")
        return res

    start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(wrapped, i) for i in range(num_requests)]
        for future in as_completed(futures):
            results.append(future.result())
    elapsed = time.perf_counter() - start
    print()

    successes = [r for r in results if "error" not in r]
    failures = [r for r in results if "error" in r]

    ttft = [r["ttft_ms"] for r in successes if r["ttft_ms"] is not None]
    tps = [r["tps"] for r in successes if r["tps"] is not None]
    gen_time = [r["generation_time_ms"] for r in successes if r["generation_time_ms"] is not None]
    total_latency = [r["total_latency_ms"] for r in successes]
    tokens = [r["tokens_generated"] for r in successes]

    total_tokens = sum(tokens)
    throughput = total_tokens / elapsed if elapsed > 0 else 0.0

    def stats(vals: List[float]) -> Dict[str, float]:
        return {
            "mean": sum(vals) / len(vals),
            "p50": percentile(vals, 0.50),
            "p90": percentile(vals, 0.90),
            "p99": percentile(vals, 0.99),
        }

    ttft_s = stats(ttft) if ttft else {"mean": 0, "p50": 0, "p90": 0, "p99": 0}
    tps_s = stats(tps) if tps else {"mean": 0, "p50": 0, "p90": 0, "p99": 0}
    gen_s = stats(gen_time) if gen_time else {"mean": 0, "p50": 0, "p90": 0, "p99": 0}
    total_s = stats(total_latency) if total_latency else {"mean": 0, "p50": 0, "p90": 0, "p99": 0}

    return CellResult(
        concurrency=concurrency,
        prompt_len=prompt_len,
        max_tokens=max_tokens,
        num_requests=num_requests,
        ttft_mean=ttft_s["mean"],
        ttft_p50=ttft_s["p50"],
        ttft_p90=ttft_s["p90"],
        ttft_p99=ttft_s["p99"],
        tps_mean=tps_s["mean"],
        tps_p50=tps_s["p50"],
        tps_p90=tps_s["p90"],
        throughput=throughput,
        gen_time_mean=gen_s["mean"],
        total_latency_mean=total_s["mean"],
        success=len(successes),
        failure=len(failures),
    )


def build_table_data(rows: List[List[Any]], header: List[str]) -> List[List[Any]]:
    return [header] + rows


def fmt(v: float, unit: str = "") -> str:
    if v is None:
        return "N/A"
    if unit == "ms":
        return f"{v:.1f}"
    if unit == "tps":
        return f"{v:.2f}"
    return f"{v:.2f}"


def generate_markdown(cells: List[CellResult], duration_sec: float) -> str:
    lines = []
    lines.append("# DeepSeek V4 Flash 推理性能测试报告")
    lines.append("")
    lines.append(f"- **测试时间**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"- **模型**: {MODEL}")
    lines.append(f"- **API 端点**: {API_BASE}")
    lines.append(f"- **测试总耗时**: {duration_sec:.1f} 秒")
    lines.append("")
    lines.append("## 测试矩阵")
    lines.append("")
    lines.append("分别测试并发度 1 / 3 / 5 / 8 / 10，输入长度与输出长度对称取 50 / 500 / 1024 / 2048 tokens。")
    lines.append("")

    # TTFT table
    lines.append("### TTFT (Time To First Token, ms)")
    lines.append("")
    lines.append("| 输入/输出长度 | C=1 | C=3 | C=5 | C=8 | C=10 |")
    lines.append("|--------------|-----|-----|-----|-----|------|")
    for plen in TOKEN_LENS:
        row = [f"{plen}"]
        for c in CONCURRENCIES:
            cell = next((x for x in cells if x.concurrency == c and x.prompt_len == plen), None)
            row.append(fmt(cell.ttft_p90 if cell else None, "ms"))
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")
    lines.append("*表中数值为 p90 TTFT（ms）。*")
    lines.append("")

    # TPS table
    lines.append("### TPS (Tokens Per Second)")
    lines.append("")
    lines.append("| 输入/输出长度 | C=1 | C=3 | C=5 | C=8 | C=10 |")
    lines.append("|--------------|-----|-----|-----|-----|------|")
    for plen in TOKEN_LENS:
        row = [f"{plen}"]
        for c in CONCURRENCIES:
            cell = next((x for x in cells if x.concurrency == c and x.prompt_len == plen), None)
            row.append(fmt(cell.tps_mean if cell else None, "tps"))
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")
    lines.append("*表中数值为平均 TPS（tok/s）。*")
    lines.append("")

    # Throughput table
    lines.append("### 聚合吞吐 (Aggregate Output Tokens/sec)")
    lines.append("")
    lines.append("| 输入/输出长度 | C=1 | C=3 | C=5 | C=8 | C=10 |")
    lines.append("|--------------|-----|-----|-----|-----|------|")
    for plen in TOKEN_LENS:
        row = [f"{plen}"]
        for c in CONCURRENCIES:
            cell = next((x for x in cells if x.concurrency == c and x.prompt_len == plen), None)
            row.append(fmt(cell.throughput if cell else None, "tps"))
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")

    # Total latency table
    lines.append("### 端到端平均延迟 (ms)")
    lines.append("")
    lines.append("| 输入/输出长度 | C=1 | C=3 | C=5 | C=8 | C=10 |")
    lines.append("|--------------|-----|-----|-----|-----|------|")
    for plen in TOKEN_LENS:
        row = [f"{plen}"]
        for c in CONCURRENCIES:
            cell = next((x for x in cells if x.concurrency == c and x.prompt_len == plen), None)
            row.append(fmt(cell.total_latency_mean if cell else None, "ms"))
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")

    # Full data table
    lines.append("## 详细数据")
    lines.append("")
    lines.append("| C | 输入 | 输出 | 成功 | 失败 | TTFT mean | TTFT p90 | TPS mean | 聚合吞吐 | 端到端延迟 |")
    lines.append("|---|------|------|------|------|-----------|----------|----------|----------|------------|")
    for cell in cells:
        lines.append(
            f"| {cell.concurrency} | {cell.prompt_len} | {cell.max_tokens} | {cell.success} | {cell.failure} | "
            f"{fmt(cell.ttft_mean, 'ms')} | {fmt(cell.ttft_p90, 'ms')} | {fmt(cell.tps_mean, 'tps')} | "
            f"{fmt(cell.throughput, 'tps')} | {fmt(cell.total_latency_mean, 'ms')} |"
        )
    lines.append("")

    # Notes
    lines.append("## 说明")
    lines.append("")
    lines.append("1. 输入长度使用字符数近似 token 数（中文每字符约 1 token）。")
    lines.append("2. TTFT 从请求发出到收到第一个内容 token 的 SSE 数据包计算。")
    lines.append("3. TPS 仅统计生成阶段：生成 token 数 / 首个内容 token 到最后一个 token 的时间。")
    lines.append("4. 聚合吞吐 = 该 cell 内所有请求成功生成 token 总数 / 该 cell 总耗时。")
    lines.append("5. 测试使用 streaming 模式，更贴近真实交互场景。")
    lines.append("")

    return "\n".join(lines)


def generate_pdf(cells: List[CellResult], out_path: str) -> None:
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont

    cjk_font = "WQYZenHei"
    pdfmetrics.registerFont(TTFont(cjk_font, "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc", subfontIndex=0))

    doc = SimpleDocTemplate(out_path, pagesize=A4,
                            rightMargin=1.5*cm, leftMargin=1.5*cm,
                            topMargin=2*cm, bottomMargin=2*cm)
    styles = getSampleStyleSheet()
    for style_name in ["Normal", "Heading1", "Heading2", "Heading3", "Title"]:
        styles[style_name].fontName = cjk_font
    small_style = ParagraphStyle(
        "Small",
        parent=styles["Normal"],
        fontName=cjk_font,
        fontSize=8,
        leading=10,
        alignment=TA_LEFT,
    )
    story = []

    title = Paragraph("<b>DeepSeek V4 Flash 推理性能测试报告</b>", styles["Title"])
    story.append(title)
    story.append(Spacer(1, 0.3*cm))

    meta = Paragraph(
        f"模型: <b>{MODEL}</b>&nbsp;&nbsp;端点: <b>{API_BASE}</b><br/>"
        f"测试时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}<br/>"
        "矩阵: 并发 1/3/5/8/10 × 输入输出 50/500/1024/2048 tokens",
        styles["Normal"],
    )
    story.append(meta)
    story.append(Spacer(1, 0.5*cm))

    headers = ["IO len", "C=1", "C=3", "C=5", "C=8", "C=10"]

    def make_table(caption: str, value_fn):
        story.append(Paragraph(f"<b>{caption}</b>", styles["Heading3"]))
        data = [headers]
        for plen in TOKEN_LENS:
            row = [str(plen)]
            for c in CONCURRENCIES:
                cell = next((x for x in cells if x.concurrency == c and x.prompt_len == plen), None)
                row.append(value_fn(cell))
            data.append(row)
        table = Table(data, colWidths=[2.2*cm] + [2.2*cm]*5)
        table.setStyle(TableStyle([
            ("FONTNAME", (0, 0), (-1, 0), cjk_font),
            ("FONTNAME", (0, 1), (-1, -1), cjk_font),
            ("FONTSIZE", (0, 0), (-1, -1), 8),
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#4F81BD")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.whitesmoke),
            ("ALIGN", (0, 0), (-1, -1), "CENTER"),
            ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
            ("BACKGROUND", (0, 1), (-1, -1), colors.HexColor("#F2F2F2")),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#E6F0FF")]),
        ]))
        story.append(table)
        story.append(Spacer(1, 0.4*cm))

    make_table("TTFT p90 (ms)", lambda c: fmt(c.ttft_p90, "ms") if c else "N/A")
    make_table("平均 TPS (tok/s)", lambda c: fmt(c.tps_mean, "tps") if c else "N/A")
    make_table("聚合吞吐 (tok/s)", lambda c: fmt(c.throughput, "tps") if c else "N/A")
    make_table("端到端平均延迟 (ms)", lambda c: fmt(c.total_latency_mean, "ms") if c else "N/A")

    story.append(PageBreak())
    story.append(Paragraph("<b>详细数据</b>", styles["Heading2"]))
    story.append(Spacer(1, 0.3*cm))

    detail_headers = ["C", "输入", "输出", "成功", "失败", "TTFT mean", "TTFT p90", "TPS mean", "聚合吞吐", "E2E mean"]
    detail_data = [detail_headers]
    for cell in cells:
        detail_data.append([
            str(cell.concurrency),
            str(cell.prompt_len),
            str(cell.max_tokens),
            str(cell.success),
            str(cell.failure),
            fmt(cell.ttft_mean, "ms"),
            fmt(cell.ttft_p90, "ms"),
            fmt(cell.tps_mean, "tps"),
            fmt(cell.throughput, "tps"),
            fmt(cell.total_latency_mean, "ms"),
        ])
    detail_table = Table(detail_data, colWidths=[1.3*cm, 1.3*cm, 1.3*cm, 1.2*cm, 1.2*cm,
                                                  1.8*cm, 1.8*cm, 1.6*cm, 1.8*cm, 1.8*cm])
    detail_table.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (-1, 0), cjk_font),
        ("FONTNAME", (0, 1), (-1, -1), cjk_font),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#4F81BD")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.whitesmoke),
        ("ALIGN", (0, 0), (-1, -1), "CENTER"),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#E6F0FF")]),
        ("FONTSIZE", (0, 0), (-1, -1), 7),
    ]))
    story.append(detail_table)
    story.append(Spacer(1, 0.5*cm))

    notes = Paragraph(
        "说明:<br/>"
        "1. 输入长度按中文字符数近似 token 数。<br/>"
        "2. TTFT = 请求发出到首个内容 token 到达的时间。<br/>"
        "3. TPS 仅统计生成阶段。<br/>"
        "4. 聚合吞吐 = 成功生成 token 总数 / cell 总耗时。<br/>"
        "5. 使用 streaming 模式测试。",
        small_style,
    )
    story.append(notes)

    doc.build(story)


def save_cell(out_dir: str, cell: CellResult) -> None:
    snap = {
        "config": {"api_base": API_BASE, "model": MODEL},
        "cell": {
            "concurrency": cell.concurrency,
            "prompt_len": cell.prompt_len,
            "max_tokens": cell.max_tokens,
            "num_requests": cell.num_requests,
            "success": cell.success,
            "failure": cell.failure,
        },
        "metrics": {
            "ttft_ms": {"mean": cell.ttft_mean, "p50": cell.ttft_p50,
                        "p90": cell.ttft_p90, "p99": cell.ttft_p99},
            "tps": {"mean": cell.tps_mean, "p50": cell.tps_p50, "p90": cell.tps_p90},
            "throughput": cell.throughput,
            "generation_time_ms": cell.gen_time_mean,
            "total_latency_ms": cell.total_latency_mean,
        },
    }
    with open(os.path.join(out_dir, f"c{cell.concurrency}-io{cell.prompt_len}.json"), "w", encoding="utf-8") as f:
        json.dump(snap, f, ensure_ascii=False, indent=2)


def load_cells(from_dir: str) -> List[CellResult]:
    cells = []
    for name in sorted(os.listdir(from_dir)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(from_dir, name), "r", encoding="utf-8") as f:
            data = json.load(f)
        c = data["cell"]
        m = data["metrics"]
        cells.append(CellResult(
            concurrency=c["concurrency"],
            prompt_len=c["prompt_len"],
            max_tokens=c["max_tokens"],
            num_requests=c["num_requests"],
            ttft_mean=m["ttft_ms"]["mean"],
            ttft_p50=m["ttft_ms"]["p50"],
            ttft_p90=m["ttft_ms"]["p90"],
            ttft_p99=m["ttft_ms"]["p99"],
            tps_mean=m["tps"]["mean"],
            tps_p50=m["tps"]["p50"],
            tps_p90=m["tps"]["p90"],
            throughput=m["throughput"],
            gen_time_mean=m["generation_time_ms"],
            total_latency_mean=m["total_latency_ms"],
            success=c["success"],
            failure=c["failure"],
        ))
    return sorted(cells, key=lambda x: (x.concurrency, x.prompt_len))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--from-dir", default=None, help="Regenerate report from existing JSON files")
    args = parser.parse_args()

    if args.from_dir:
        from_dir = args.from_dir
        if not os.path.isdir(from_dir):
            print(f"Directory not found: {from_dir}")
            sys.exit(1)
        cells = load_cells(from_dir)
        overall_duration = 0.0
        timestamp = os.path.basename(from_dir).replace("matrix-", "")
        out_dir = from_dir
    else:
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "benchmark-results", f"matrix-{timestamp}")
        os.makedirs(out_dir, exist_ok=True)

        cells: List[CellResult] = []
        overall_start = time.perf_counter()

        for c in CONCURRENCIES:
            for plen in TOKEN_LENS:
                cell = run_cell(c, plen, plen)
                cells.append(cell)
                save_cell(out_dir, cell)

        overall_duration = time.perf_counter() - overall_start

    md_path = os.path.join(out_dir, "..", f"matrix-{timestamp}-report.md")
    pdf_path = os.path.join(out_dir, "..", f"matrix-{timestamp}-report.pdf")

    md_content = generate_markdown(cells, overall_duration)
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(md_content)

    generate_pdf(cells, pdf_path)

    print("\n" + "=" * 60)
    print("BENCHMARK MATRIX COMPLETE")
    print("=" * 60)
    print(f"Total duration: {overall_duration:.1f} s")
    print(f"Raw results:    {out_dir}")
    print(f"Markdown:       {md_path}")
    print(f"PDF report:     {pdf_path}")


if __name__ == "__main__":
    main()
