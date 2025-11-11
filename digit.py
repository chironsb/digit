#!/usr/bin/env python3
"""
digit CLI
---------
A lightweight utility to extract website content (preferably documentation)
into Markdown, JSON, plain text, or HTML files, ready for use with LLMs. Accepts URL and output directory,
tries the sitemap first, then does limited crawling within the domain as fallback.
"""

import argparse
import sys
import time
import re
import hashlib
import os
from pathlib import Path
from collections import deque
from urllib.parse import urlparse, urljoin, urldefrag
import xml.etree.ElementTree as ET

import httpx
from bs4 import BeautifulSoup
import html2text
from urllib import robotparser


# TUI helpers (works on Windows 10/11 PowerShell, Linux, macOS)
def color256(code: int, text: str) -> str:
    """256-color ANSI code"""
    return f"\033[38;5;{code}m{text}\033[0m"


def bold(text: str) -> str:
    """Bold text"""
    return f"\033[1m{text}\033[0m"


def green(text: str) -> str:
    return f"\033[32m{text}\033[0m"


def yellow(text: str) -> str:
    return f"\033[33m{text}\033[0m"


def red(text: str) -> str:
    return f"\033[31m{text}\033[0m"


def box_line(text: str, width: int = 63) -> str:
    """Create a box line"""
    inner = width - 2
    if len(text) > inner:
        text = text[:inner]
    return f"  {color256(82, '│')}  {text:<{inner}} {color256(82, '│')}"


def hr_line(width: int = 63) -> str:
    """Horizontal line"""
    return "─" * width


def wave_line(width: int = 63) -> str:
    """Rainbow wave line"""
    palette = [196, 202, 208, 214, 220, 226, 190, 154, 118, 82, 46, 47, 48, 49, 51, 39, 27, 21, 57, 93, 129, 165, 201]
    result = ""
    for i in range(width):
        result += color256(palette[i % len(palette)], "─")
    return result


def rainbow_banner() -> str:
    """Print rainbow banner"""
    palette = [196, 202, 208, 214, 220, 226, 190, 154, 118, 82, 46, 47, 48, 49, 51, 39, 27, 21, 57, 93, 129, 165, 201]
    lines = [
        "",
        r"     _/\/\/\/\/\____/\/\/\/\____/\/\/\/\/\__/\/\/\/\__/\/\/\/\/\/\_",
        r"    _/\/\____/\/\____/\/\____/\/\____________/\/\________/\/\_____ ",
        r"   _/\/\____/\/\____/\/\____/\/\__/\/\/\____/\/\________/\/\_____  ",
        r"  _/\/\____/\/\____/\/\____/\/\____/\/\____/\/\________/\/\_____   ",
        r" _/\/\/\/\/\____/\/\/\/\____/\/\/\/\/\__/\/\/\/\______/\/\_____    ",
        "______________________________________________________________     ",
        "",
    ]
    result = ""
    for idx, line in enumerate(lines):
        code = palette[(idx * 2) % len(palette)]
        result += color256(code, line) + "\n"
    return result


def interactive_mode() -> argparse.Namespace:
    """Interactive TUI mode (similar to digit.sh)"""
    print(rainbow_banner())
    print(wave_line())
    print()
    print(color256(34, "═══════════════════════════════════════════════════════════════"))
    print(f"  {bold('🌐 Configuration Setup')}")
    print(color256(34, "═══════════════════════════════════════════════════════════════"))
    print()

    # Output directory
    print()
    # Get current directory name for display
    current_dir = os.path.basename(os.getcwd())
    default_out = "sites"
    default_display = f"{current_dir}/{default_out}" if current_dir else default_out
    print(f"  {color256(82, '┌─')} {bold('Output Directory')}")
    print(f"  {color256(82, '│')}  Default: {color256(246, default_display)}")
    print(f"  {color256(82, '└─')} {color256(220, '➜')} ", end="", flush=True)
    out_dir = input().strip() or default_out

    # Input mode
    print()
    print(f"  {color256(82, '┌─')} {bold('📋 Input Mode')}")
    print(f"  {color256(82, '│')}  How do you want to provide URLs?")
    print(f"  {color256(82, '│')}")
    print(f"  {color256(82, '│')}  {color256(220, '1')} {color256(46, '✓')} Single URL")
    print(f"  {color256(82, '│')}  {color256(220, '2')}   Batch File  {color256(246, '(file with URLs, one per line)')}")
    print(f"  {color256(82, '└─')} {color256(220, '➜')} Choice [1-2]: ", end="", flush=True)
    choice = input().strip()
    batch_mode = choice == "2"

    # URL or batch file
    url = None
    urls_file = None
    if batch_mode:
        print()
        print(f"  {color256(82, '┌─')} {bold('📋 Batch File')}")
        print(f"  {color256(82, '│')}  Enter path to file with URLs (one per line):")
        print(f"  {color256(82, '└─')} {color256(220, '➜')} ", end="", flush=True)
        urls_file = input().strip()
        if not urls_file or not os.path.exists(urls_file):
            print(f"\n  {red('✖ Error:')} File not found: {urls_file}")
            sys.exit(1)
    else:
        print()
        print(f"  {color256(82, '┌─')} {bold('Target URL')}")
        print(f"  {color256(82, '│')}  Enter the website to scrape:")
        print(f"  {color256(82, '└─')} {color256(220, '➜')} ", end="", flush=True)
        url = input().strip()
        if not url:
            print(f"\n  {red('✖ Error:')} URL is required")
            sys.exit(1)

    # Sitemap mode
    print()
    print(f"  {color256(82, '┌─')} {bold('🗺️  Sitemap Mode')}")
    print(f"  {color256(82, '│')}  Use sitemap.xml if available?")
    print(f"  {color256(82, '│')}")
    print(f"  {color256(82, '│')}  {color256(220, '1')} {color256(46, '✓')} Yes {color256(246, '(faster, recommended)')}")
    print(f"  {color256(82, '│')}  {color256(220, '2')}   No  {color256(246, '(crawl manually)')}")
    print(f"  {color256(82, '└─')} {color256(220, '➜')} Choice [1-2]: ", end="", flush=True)
    choice = input().strip()
    sitemap_only = choice != "2"

    # Format
    print()
    print(f"  {color256(82, '┌─')} {bold('📄 Output Format')}")
    print(f"  {color256(82, '│')}  Choose export format:")
    print(f"  {color256(82, '│')}")
    print(f"  {color256(82, '│')}  {color256(220, '1')} {color256(46, '✓')} Markdown  {color256(246, '(.md with frontmatter)')}")
    print(f"  {color256(82, '│')}  {color256(220, '2')}   JSON       {color256(246, '(structured data)')}")
    print(f"  {color256(82, '│')}  {color256(220, '3')}   Plain Text {color256(246, '(no markup)')}")
    print(f"  {color256(82, '│')}  {color256(220, '4')}   HTML       {color256(246, '(cleaned)')}")
    print(f"  {color256(82, '└─')} {color256(220, '➜')} Choice [1-4]: ", end="", flush=True)
    choice = input().strip()
    format_map = {"1": "md", "2": "json", "3": "txt", "4": "html"}
    fmt = format_map.get(choice, "md")

    # Diff mode
    print()
    print(f"  {color256(82, '┌─')} {bold('🔄 Diff Mode')}")
    print(f"  {color256(82, '│')}  Only update changed pages?")
    print(f"  {color256(82, '│')}")
    print(f"  {color256(82, '│')}  {color256(220, '1')}   Yes {color256(246, '(skip unchanged)')}")
    print(f"  {color256(82, '│')}  {color256(220, '2')} {color256(46, '✓')} No  {color256(246, '(update all)')}")
    print(f"  {color256(82, '└─')} {color256(220, '➜')} Choice [1-2]: ", end="", flush=True)
    choice = input().strip()
    diff = choice == "1"

    # Summary
    print()
    print(wave_line())
    print()
    print(color256(34, "═══════════════════════════════════════════════════════════════"))
    print(f"  {bold('📋 Configuration Summary')}")
    print(color256(34, "═══════════════════════════════════════════════════════════════"))
    print()
    if urls_file:
        print(f"  {color256(82, 'Mode:')}        {color256(220, 'Batch File')}")
        print(f"  {color256(82, 'File:')}       {color256(220, urls_file)}")
    else:
        print(f"  {color256(82, 'Mode:')}        {color256(220, 'Single URL')}")
        print(f"  {color256(82, 'URL:')}         {color256(220, url)}")
    out_display = out_dir.replace(os.path.expanduser("~"), "~")
    print(f"  {color256(82, 'Output:')}     {color256(220, out_display)}")
    print(f"  {color256(82, 'Sitemap:')}    {color256(220, 'Y' if sitemap_only else 'N')}")
    fmt_display = {"md": "Markdown (.md)", "json": "JSON", "txt": "Plain text (.txt)", "html": "Cleaned HTML"}.get(fmt, fmt)
    print(f"  {color256(82, 'Format:')}     {color256(220, fmt_display)}")
    print(f"  {color256(82, 'Diff mode:')}  {color256(220, 'Y' if diff else 'N')}")
    print()
    print(color256(34, "═══════════════════════════════════════════════════════════════"))
    print()
    print()
    print(f"{color256(46, '  ▶')} {bold('Ready to start scraping!')} Press {color256(220, 'Enter')} to proceed or {color256(196, 'Ctrl+C')} to cancel...", end="", flush=True)
    input()

    # Create args object
    class Args:
        pass

    args = Args()
    args.url = url
    args.urls_file = urls_file
    args.out = out_dir
    args.format = fmt
    args.sitemap_only = sitemap_only
    args.diff = diff
    args.max_pages = 10000
    args.depth = 0
    args.rate = 1.5
    args.include = None
    args.exclude = None
    args.save_html = False
    args.lang = ""
    return args


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="digit",
        description="Scrape docs from a website and export",
    )
    parser.add_argument(
        "--url", "-u", help="Seed URL (e.g., https://example.com/docs/)"
    )
    parser.add_argument(
        "--out", "-o", default="sites", help="Output folder (default: sites)"
    )
    parser.add_argument(
        "--max-pages",
        type=int,
        default=10000,
        help="Max pages to fetch (default: 10000)",
    )
    parser.add_argument(
        "--depth", type=int, default=0, help="Max depth (0 = unlimited)"
    )
    parser.add_argument(
        "--rate", type=float, default=1.5, help="Requests per second (default: 1.5)"
    )
    parser.add_argument("--include", help="Regex for URLs to include (optional)")
    parser.add_argument("--exclude", help="Regex for URLs to exclude (optional)")
    parser.add_argument(
        "--sitemap-only", action="store_true", help="Use only sitemap if available"
    )
    parser.add_argument(
        "--save-html", action="store_true", help="Save raw HTML alongside Markdown"
    )
    parser.add_argument(
        "--lang", default="", help="Preferred language code to keep (optional)"
    )
    parser.add_argument(
        "--format",
        choices=["md", "json", "txt", "html"],
        default="md",
        help="Output format: md (Markdown), json, txt (plain text), html (cleaned HTML)",
    )
    parser.add_argument(
        "--urls-file", help="File with list of URLs to scrape (one per line)"
    )
    parser.add_argument(
        "--diff",
        action="store_true",
        help="Only scrape pages that have changed (diff mode)",
    )
    args = parser.parse_args()

    # If no arguments provided, use interactive mode
    if len(sys.argv) == 1:
        return interactive_mode()

    # Otherwise, use simple prompts for missing required args
    if not args.url and not args.urls_file:
        try:
            args.url = input(
                "URL (e.g., https://nixos-and-flakes.thiscute.world/): "
            ).strip()
        except KeyboardInterrupt:
            sys.exit(1)
    if not args.out:
        try:
            args.out = input("Output folder (e.g., ./docs): ").strip() or "docs"
        except KeyboardInterrupt:
            sys.exit(1)
    return args


def normalize_url(base: str, href: str) -> str | None:
    if not href:
        return None
    abs_url = urljoin(base, href)
    abs_url, _frag = urldefrag(abs_url)
    parsed = urlparse(abs_url)
    if parsed.scheme not in {"http", "https"}:
        return None
    # Normalize host lowercase
    normalized = parsed._replace(netloc=parsed.netloc.lower()).geturl()
    return normalized


def same_scope(seed: str, candidate: str) -> bool:
    a = urlparse(seed)
    b = urlparse(candidate)
    return (a.scheme, a.netloc) == (b.scheme, b.netloc) and b.path.startswith(a.path)


def load_robots(seed: str) -> robotparser.RobotFileParser:
    rp = robotparser.RobotFileParser()
    robots_url = urljoin(seed, "/robots.txt")
    try:
        rp.set_url(robots_url)
        rp.read()
    except Exception:
        # If robots fails, default to permissive but we still keep rate limiting
        pass
    return rp


def iter_sitemap_urls(seed: str):
    # Try common sitemap locations
    candidates = [urljoin(seed, "/sitemap.xml"), urljoin(seed, "sitemap.xml")]
    with httpx.Client(follow_redirects=True, timeout=15.0) as client:
        for sm_url in candidates:
            try:
                resp = client.get(sm_url)
                if resp.status_code != 200 or "xml" not in resp.headers.get(
                    "content-type", ""
                ):
                    continue
                root = ET.fromstring(resp.text)
                # sitemapindex or urlset
                if root.tag.endswith("sitemapindex"):
                    for sm in root.findall("{*}sitemap/{*}loc"):
                        loc = sm.text.strip() if sm is not None and sm.text else ""
                        if not loc:
                            continue
                        try:
                            r = client.get(loc)
                            if r.status_code == 200:
                                rroot = ET.fromstring(r.text)
                                for u in rroot.findall("{*}url/{*}loc"):
                                    if u.text:
                                        yield u.text.strip()
                        except Exception:
                            continue
                elif root.tag.endswith("urlset"):
                    for u in root.findall("{*}url/{*}loc"):
                        if u.text:
                            yield u.text.strip()
            except Exception:
                continue


def extract_main_content(html: str, page_url: str) -> tuple[str, dict, str]:
    soup = BeautifulSoup(html, "html.parser")
    # Remove clutter
    for tag in soup.find_all(
        ["nav", "aside", "script", "style", "header", "footer", "form", "img"]
    ):
        tag.decompose()

    # Try common containers for docs frameworks
    main = (
        soup.find("main")
        or soup.find("article")
        or soup.find("div", class_="content")
        or soup.find("div", class_="document")
        or soup.find("div", class_="theme-default-content")
        or soup.find("div", id=re.compile(r"^content|^main", re.I))
        or soup.body
    )

    # Convert code blocks (<pre><code>) to fenced Markdown before html2text
    container = main or soup
    fence_map: dict[str, str] = {}
    fence_idx = 0
    for pre in list(container.find_all("pre")):
        code = pre.find("code")
        classes = []
        if code and code.has_attr("class"):
            classes = [c for c in code.get("class", []) if isinstance(c, str)]
        elif pre.has_attr("class"):
            classes = [c for c in pre.get("class", []) if isinstance(c, str)]
        lang = ""
        for c in classes:
            if c.startswith("language-"):
                lang = c.split("language-", 1)[1]
                break
            if c in {
                "bash",
                "shell",
                "sh",
                "nix",
                "json",
                "yaml",
                "toml",
                "python",
                "js",
                "ts",
            }:
                lang = c
        # Extract raw text of code, attempting to drop visual line numbers if any
        text_src = code if code else pre
        # Use space separator to avoid breaking tokens wrapped by spans, then normalize newlines later
        code_text = text_src.get_text(" ")
        # Heuristic: remove standalone lines that are just small integers (likely line numbers)
        raw_lines = code_text.splitlines()
        cleaned_lines = []
        i = 0
        while i < len(raw_lines):
            line = raw_lines[i].rstrip()
            if re.fullmatch(r"\s*\d{1,3}\s*", line):
                i += 1
                continue
            # Merge tree-drawing symbol-only lines with the next line
            if re.fullmatch(r"[\s│└├┬─›>•·`~\\/|:_-]+", line) and i + 1 < len(
                raw_lines
            ):
                merged = (line.strip() + " " + raw_lines[i + 1].lstrip()).rstrip()
                cleaned_lines.append(merged)
                i += 2
                continue
            cleaned_lines.append(line)
            i += 1
        code_text = "\n".join(cleaned_lines).strip("\n")
        fenced = f"\n\n```{lang}\n{code_text}\n```\n\n"
        placeholder = f"WEB2SCRAP_FENCE_{fence_idx}"
        fence_idx += 1
        fence_map[placeholder] = fenced
        pre.replace_with(soup.new_string(placeholder))

    h = html2text.HTML2Text()
    h.ignore_links = False
    h.ignore_images = False
    h.body_width = 0
    h.unicode_snob = True
    markdown = h.handle(str(main or soup))
    # Remove HTML entities for icons (e.g., &#xf123;)
    markdown = re.sub(r"&#x[0-9a-fA-F]+;", "", markdown)
    # Make bold text into headers
    markdown = re.sub(r"\*\*(.*?)\*\*", r"## \1", markdown)
    # Add newlines before code blocks
    markdown = re.sub(r"(^|\n)(note\(|s\()", r"\1\n\n\2", markdown)
    # Restore fenced code blocks placeholders verbatim
    for key, fenced in fence_map.items():
        markdown = markdown.replace(key, fenced)
    # Merge language label lines (e.g., "bash" on its own) into fenced code header
    markdown = re.sub(r"\n([a-zA-Z0-9_+-]{2,})\n\n```", r"\n```\1\n", markdown)

    # Remove long runs of standalone line-number lines that some doc themes render next to code blocks
    markdown = re.sub(
        r"(?:^|\n)(?:\s*\d+\s*\n){3,}", "\n", markdown, flags=re.MULTILINE
    )

    # html2text may escape backticks inside, ensure fenced blocks remain on their own lines
    # Also collapse excessive blank lines
    markdown = re.sub(r"\n{3,}", "\n\n", markdown)

    # Title
    title = soup.title.string.strip() if soup.title and soup.title.string else ""
    meta = {
        "title": title,
        "url": page_url,
    }
    html_cleaned = str(main) if main else ""
    return markdown, meta, html_cleaned


def slugify_path(
    base: Path, root_url: str, page_url: str, lang_hint: str = "", format: str = "md"
) -> Path:
    a = urlparse(root_url)
    b = urlparse(page_url)
    path = b.path
    if lang_hint:
        # crude: keep paths that contain language hint early in path
        parts = [p for p in path.split("/") if p]
        if parts and parts[0].lower() != lang_hint.lower():
            # keep structure; we don't drop non-matching automatically here
            pass
    if path.endswith("/"):
        path = path + "index"
    if not path:
        path = "index"
    # Ensure correct extension
    if path.endswith(".html"):
        path = path[:-5]
    
    # Flatten structure: if path ends with /index, replace with just the folder name
    # e.g., /toolkit/index -> /toolkit, /catalog/index -> /catalog
    # BUT: if the path after removing /index matches the root_url path, keep it as index
    # (this is the root page of the section)
    if path.endswith("/index"):
        root_path = a.path.rstrip("/")
        path_without_index = path[:-6]  # Remove "/index"
        # If removing /index would make it match the root path, keep it as index
        # (e.g., /ai/mcp-catalog-and-toolkit/index should stay as index, not become the folder name)
        if path_without_index == root_path or path_without_index == root_path + "/":
            # This is the root page, keep it as index
            pass  # path stays as .../index
        else:
            # This is a subfolder's index, flatten it
            path = path_without_index
            # If path is now empty or just "/", make it "index"
            if not path or path == "/":
                path = "index"
    
    # sanitize
    safe = re.sub(r"[^a-zA-Z0-9/_\-]", "-", path).strip("/")
    ext = ".md" if format == "md" else f".{format}"
    return base / (safe + ext)


def write_output(
    out_path: Path, content: str, meta: dict, format: str, html_cleaned: str, diff: bool
):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if format == "md":
        fm_lines = [
            "---",
            f"title: {meta.get('title', '').replace(':', '-')}",
            f"url: {meta.get('url', '')}",
            f"date_scraped: {int(time.time())}",
            "---",
            "",
        ]
        final_content = "\n".join(fm_lines) + content
    elif format == "json":
        import json

        data = {
            "title": meta.get("title", ""),
            "url": meta.get("url", ""),
            "date_scraped": int(time.time()),
            "content": content,
        }
        final_content = json.dumps(data, indent=2, ensure_ascii=False)
    elif format == "txt":
        final_content = content
    elif format == "html":
        final_content = html_cleaned
    else:
        final_content = content

    if diff and out_path.exists():
        try:
            with open(out_path, "r", encoding="utf-8") as f:
                existing = f.read()
            if hash_content(existing) == hash_content(final_content):
                return  # Skip writing if unchanged
        except Exception:
            pass  # If error reading, write anyway

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(final_content)


def hash_content(content: str) -> str:
    return hashlib.sha1(content.encode("utf-8")).hexdigest()


def crawl_with_frontier(
    seed: str,
    out_dir: Path,
    max_pages: int,
    depth_limit: int,
    rps: float,
    include_rx: re.Pattern | None,
    exclude_rx: re.Pattern | None,
    save_html: bool,
    lang_hint: str,
    format: str,
    diff: bool,
) -> int:
    parsed_seed = urlparse(seed)
    base = f"{parsed_seed.scheme}://{parsed_seed.netloc}{parsed_seed.path if parsed_seed.path.endswith('/') else parsed_seed.path + '/'}"
    rp = load_robots(base)
    delay = max(0.0, 1.0 / rps)

    queue = deque([(base, 0)])
    seen: set[str] = set()
    saved_hashes: set[str] = set()

    with httpx.Client(
        follow_redirects=True, timeout=20.0, headers={"User-Agent": "digit/0.1"}
    ) as client:
        pages = 0
        while queue and pages < max_pages:
            url, depth = queue.popleft()
            if url in seen:
                continue
            seen.add(url)

            if not rp.can_fetch("digit", url):
                continue
            if include_rx and not include_rx.search(url):
                continue
            if exclude_rx and exclude_rx.search(url):
                continue
            try:
                resp = client.get(url)
            except Exception:
                continue

            if resp.status_code != 200 or "html" not in resp.headers.get(
                "content-type", ""
            ):
                continue

            html = resp.text
            content_hash = hash_content(html)
            if content_hash in saved_hashes:
                continue

            md, meta, html_cleaned = extract_main_content(html, url)
            out_path = slugify_path(out_dir, base, url, lang_hint, format)
            write_output(out_path, md, meta, format, html_cleaned, diff)
            saved_hashes.add(content_hash)
            pages += 1
            try:
                rel = out_path.relative_to(out_dir)
            except Exception:
                rel = out_path
            print(f"[\033[32m{pages}\033[0m] {rel}", flush=True)

            if depth_limit == 0 or depth < depth_limit:
                soup = BeautifulSoup(html, "html.parser")
                for a in soup.find_all("a"):
                    nxt = normalize_url(url, a.get("href"))
                    if not nxt:
                        continue
                    if same_scope(base, nxt):
                        queue.append((nxt, depth + 1))

            time.sleep(delay)
    return pages


def crawl_sitemap_first(
    seed: str,
    out_dir: Path,
    rps: float,
    save_html: bool,
    lang_hint: str,
    format: str,
    diff: bool,
) -> int:
    delay = max(0.0, 1.0 / rps)
    count = 0
    all_urls = list(iter_sitemap_urls(seed))
    if not all_urls:
        return 0
    # Filter URLs to only include those in the same scope (subdirectory) as seed
    # If seed is just the domain, it will include all URLs
    # If seed has a specific path, it will only include URLs under that path
    urls = [url for url in all_urls if same_scope(seed, url)]
    if not urls:
        return 0
    # Print on a fresh line and in green; highlight page count in green
    print(
        f"\n\033[33mSitemap found!\033[0m Filtered to \033[32m{len(urls)}\033[0m pages in scope (from {len(all_urls)} total)...",
        flush=True,
    )
    total = len(urls)
    with httpx.Client(
        follow_redirects=True, timeout=20.0, headers={"User-Agent": "digit/0.1"}
    ) as client:
        for idx, url in enumerate(urls, start=1):
            try:
                resp = client.get(url)
            except Exception:
                continue
            if resp.status_code != 200 or "html" not in resp.headers.get(
                "content-type", ""
            ):
                continue
            html = resp.text
            md, meta, html_cleaned = extract_main_content(html, url)
            out_path = slugify_path(out_dir, seed, url, lang_hint, format)
            write_output(out_path, md, meta, format, html_cleaned, diff)
            count += 1
            try:
                rel = out_path.relative_to(out_dir)
            except Exception:
                rel = out_path
            print(f"[\033[32m{idx}\033[0m/\033[32m{total}\033[0m] {rel}", flush=True)
            time.sleep(delay)
    return count


def main():
    args = parse_args()
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.urls_file:
        with open(args.urls_file, "r", encoding="utf-8") as f:
            urls = [line.strip() for line in f if line.strip()]
    else:
        urls = [args.url]

    total_written = 0
    for seed in urls:
        parsed = urlparse(seed)
        domain = parsed.netloc or "unknown"
        out_subdir = out_dir / domain
        out_subdir.mkdir(parents=True, exist_ok=True)

        include_rx = re.compile(args.include) if args.include else None
        exclude_rx = re.compile(args.exclude) if args.exclude else None

        # Wrapper handles UI; keep CLI quiet except for essential lines

        used_sitemap = False
        written_count = 0
        if args.sitemap_only and not args.include and not args.exclude:
            # Try sitemap only if --sitemap-only flag is set
            print(f"[{domain}] Trying sitemap.xml ...", flush=True)
            cnt = crawl_sitemap_first(
                seed,
                out_subdir,
                args.rate,
                args.save_html,
                args.lang,
                args.format,
                args.diff,
            )
            if cnt > 0:
                used_sitemap = True
                written_count = cnt
            else:
                print(
                    f"\n\033[31m[{domain}] No sitemap or empty sitemap. Exiting due to --sitemap-only.\033[0m",
                    flush=True,
                )
                continue

        if not used_sitemap:
            print(
                f"\n\033[33m[{domain}] Falling back to scoped crawl ...\033[0m",
                flush=True,
            )
            # crawl_with_frontier already limits to same scope (subdirectory) via same_scope() check
            # So it will scrape the seed URL and all pages in its subdirectory tree
            written_count = crawl_with_frontier(
                seed=seed,
                out_dir=out_subdir,
                max_pages=args.max_pages,
                depth_limit=args.depth,
                rps=args.rate,
                include_rx=include_rx,
                exclude_rx=exclude_rx,
                save_html=args.save_html,
                lang_hint=args.lang,
                format=args.format,
                diff=args.diff,
            )
        total_written += written_count

    # Write summary for wrapper if requested
    import os

    summary_path = os.environ.get("WEB2SCRAP_SUMMARY_PATH")
    if summary_path:
        try:
            with open(summary_path, "w", encoding="utf-8") as f:
                f.write(f"count: {total_written}\n")
                f.write(f"out: {out_dir}\n")
        except Exception:
            pass


if __name__ == "__main__":
    main()
