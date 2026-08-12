#!/usr/bin/env python3
"""Convert the deployment markdown document to PDF using WeasyPrint."""
import markdown
from weasyprint import HTML, CSS
from pathlib import Path

src = Path("/root/dsv4dspark/部署实施文档.md")
dst = Path("/root/dsv4dspark/部署实施文档.pdf")

md_text = src.read_text(encoding="utf-8")

html_body = markdown.markdown(
    md_text,
    extensions=[
        "toc",
        "tables",
        "fenced_code",
        "nl2br",
    ],
)

html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>DeepSeek V4 Flash 双 DGX Spark 部署实施文档</title>
<style>
@page {{
  size: A4;
  margin: 2cm 1.8cm;
  @bottom-center {{
    content: counter(page);
    font-size: 9pt;
    color: #666;
  }}
}}
body {{
  font-family: "Noto Serif CJK SC", "AR PL UMing TW", "AR PL UKai CN", serif;
  font-size: 10.5pt;
  line-height: 1.6;
  color: #222;
}}
h1, h2, h3, h4 {{
  font-family: "Noto Sans CJK SC", "Noto Serif CJK SC", sans-serif;
  color: #1a1a1a;
  margin-top: 1.2em;
  margin-bottom: 0.5em;
}}
h1 {{ font-size: 18pt; border-bottom: 2px solid #333; padding-bottom: 0.2em; }}
h2 {{ font-size: 14pt; border-bottom: 1px solid #ccc; padding-bottom: 0.15em; }}
h3 {{ font-size: 12pt; }}
h4 {{ font-size: 11pt; }}
pre {{
  background: #f5f5f5;
  border: 1px solid #ddd;
  border-radius: 4px;
  padding: 0.6em;
  overflow-x: auto;
  font-family: "DejaVu Sans Mono", "Consolas", monospace;
  font-size: 8.5pt;
  line-height: 1.4;
  white-space: pre-wrap;
  word-break: break-word;
}}
code {{
  font-family: "DejaVu Sans Mono", "Consolas", monospace;
  font-size: 8.5pt;
  background: #f0f0f0;
  padding: 0.1em 0.3em;
  border-radius: 3px;
}}
pre code {{
  background: transparent;
  padding: 0;
}}
table {{
  border-collapse: collapse;
  width: 100%;
  margin: 1em 0;
  font-size: 9.5pt;
}}
th, td {{
  border: 1px solid #bbb;
  padding: 0.4em 0.6em;
  text-align: left;
  vertical-align: top;
}}
th {{
  background: #eee;
  font-weight: bold;
}}
tr:nth-child(even) {{ background: #fafafa; }}
ul, ol {{ margin: 0.5em 0; padding-left: 1.5em; }}
li {{ margin: 0.2em 0; }}
blockquote {{
  border-left: 4px solid #ccc;
  margin: 0.8em 0;
  padding-left: 1em;
  color: #555;
}}
.toc > ul {{ font-size: 10pt; }}
.toc a {{ text-decoration: none; color: #333; }}
</style>
</head>
<body>
{html_body}
</body>
</html>
"""

HTML(string=html, base_url=str(src.parent)).write_pdf(str(dst))
print(f"PDF generated: {dst}")
