#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Auto-detect Python (works on Linux, macOS, Windows with Git Bash/WSL)
if command -v python3 &> /dev/null; then
  PYTHON="python3"
elif command -v python &> /dev/null; then
  PYTHON="python"
else
  echo "Error: Python not found. Please install Python 3."
  exit 1
fi
PYDEPS_DIR="$PROJECT_DIR/.pydeps"
DEFAULT_OUT="$PROJECT_DIR/sites"

bold() { printf "\033[1m%s\033[0m" "$1"; }
green() { printf "\033[32m%s\033[0m" "$1"; }
yellow() { printf "\033[33m%s\033[0m" "$1"; }
red() { printf "\033[31m%s\033[0m" "$1"; }

WIDTH=63
is_utf8() { [[ "${LC_ALL:-${LANG:-}}" =~ [Uu][Tt][Ff]-?8 ]]; }
set_box_chars() {
  if is_utf8; then
    LINE_CHAR='─'
    VERT_CHAR='│'
    TL_CHAR='┌'
    TR_CHAR='┐'
    BL_CHAR='└'
    BR_CHAR='┘'
  else
    LINE_CHAR='-'
    VERT_CHAR='|'
    TL_CHAR='+'
    TR_CHAR='+'
    BL_CHAR='+'
    BR_CHAR='+'
  fi
}
set_box_chars
hr_line() {
  local line
  printf -v line '%*s' "$WIDTH" ''
  echo "${line// /$LINE_CHAR}"
}
# 256-color helpers for rainbow waves
palette=(196 202 208 214 220 226 190 154 118 82 46 47 48 49 51 39 27 21 57 93 129 165 201)
palette_len=${#palette[@]}
color256() { # $1 code, $2 text
  printf "\033[38;5;%sm%s\033[0m" "$1" "$2"
}
wave_line() {
  local w=${1:-$WIDTH}
  local out=""
  local i code idx
  for ((i = 0; i < w; i++)); do
    idx=$((i % palette_len))
    code=${palette[$idx]}
    out+=$(color256 "$code" "$LINE_CHAR")
  done
  echo -e "$out"
}
rainbow_banner() {
  local idx=0
  local code
  while IFS= read -r line; do
    code=${palette[$((idx % palette_len))]}
    echo -e "\033[38;5;${code}m${line}\033[0m"
    idx=$((idx + 2))
  done <<'BANNER'


     _/\/\/\/\/\____/\/\/\/\____/\/\/\/\/\__/\/\/\/\__/\/\/\/\/\/\_
    _/\/\____/\/\____/\/\____/\/\____________/\/\________/\/\_____ 
   _/\/\____/\/\____/\/\____/\/\__/\/\/\____/\/\________/\/\_____  
  _/\/\____/\/\____/\/\____/\/\____/\/\____/\/\________/\/\_____   
 _/\/\/\/\/\____/\/\/\/\____/\/\/\/\/\__/\/\/\/\______/\/\_____    
______________________________________________________________     


BANNER
}
box_line() { # $1 text
  local text="$1"
  local plain=$(echo -e "$text" | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')
  local inner=$((WIDTH - 2))
  # truncate if necessary
  if ((${#plain} > inner)); then
    text="$(echo -e "$text" | sed -E "s/^(.{0,$inner}).*$/\1/")"
  fi
  printf '%s %-*s %s\n' "$VERT_CHAR" "$inner" "$text" "$VERT_CHAR"
}

# Graceful abort on Ctrl-C
abort() {
  echo
  echo "$(red 'Aborted by user (Ctrl-C).')"
  # Restore cursor if spinner hid it
  tput cnorm 2>/dev/null || true
  # Kill background scraper process group if running
  if [[ -n "${PGID-}" ]]; then
    kill -TERM -"$PGID" 2>/dev/null || true
    sleep 0.2
    kill -KILL -"$PGID" 2>/dev/null || true
  fi
  exit 130
}
trap abort INT

spinner() {
  local pid=$1
  shift
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local i=0
  tput civis || true
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r%s %s" "${frames[$((i % 10))]}" "$*"
    i=$((i + 1))
    sleep 0.1
  done
  # clear the line
  printf "\r\033[K"
  tput cnorm || true
}

rainbow_banner
wave_line

echo
echo "$(color256 34 '═══════════════════════════════════════════════════════════════')"
echo "  $(bold '🌐 Configuration Setup')"
echo "$(color256 34 '═══════════════════════════════════════════════════════════════')"
echo

# Prompt output directory
echo
echo "  $(color256 82 '┌─') $(bold 'Output Directory')"
echo "  $(color256 82 '│')  Default: $(color256 246 "$DEFAULT_OUT")"
echo -n "  $(color256 82 '└─') $(color256 220 '➜') "
read -r OUT_DIR_INPUT || true
OUT_DIR="${OUT_DIR_INPUT:-$DEFAULT_OUT}"
mkdir -p "$OUT_DIR"

# Single URL or Batch mode?
echo
echo "  $(color256 82 '┌─') $(bold '📋 Input Mode')"
echo "  $(color256 82 '│')  How do you want to provide URLs?"
echo "  $(color256 82 '│')"
echo "  $(color256 82 '│')  $(color256 220 '1') $(color256 46 '✓') Single URL"
echo "  $(color256 82 '│')  $(color256 220 '2')   Batch File  $(color256 246 '(file with URLs, one per line)')"
echo -n "  $(color256 82 '└─') $(color256 220 '➜') Choice [1-2]: "
read -rp "" choice || true
case "$choice" in
1) BATCH_MODE=N ;;
2) BATCH_MODE=Y ;;
*) BATCH_MODE=N ;; # default to single URL
esac

# Prompt URL or Batch file based on choice
if [[ "$BATCH_MODE" == "Y" ]]; then
  echo
  echo "  $(color256 82 '┌─') $(bold '📋 Batch File')"
  echo "  $(color256 82 '│')  Enter path to file with URLs (one per line):"
  echo -n "  $(color256 82 '└─') $(color256 220 '➜') "
  read -r BATCH_FILE || true
  if [[ -z "$BATCH_FILE" ]]; then
    echo
    echo "  $(red '✖ Error:') Batch file path is required"
    exit 1
  fi
  if [[ ! -f "$BATCH_FILE" ]]; then
    echo
    echo "  $(red '✖ Error:') File not found: $BATCH_FILE"
    exit 1
  fi
  URL=""  # Clear URL when using batch mode
else
  URL="${1-}"
  while [[ -z "${URL}" ]]; do
    echo
    echo "  $(color256 82 '┌─') $(bold 'Target URL')"
    echo "  $(color256 82 '│')  Enter the website to scrape:"
    echo -n "  $(color256 82 '└─') $(color256 220 '➜') "
    read -r URL
    if [[ -z "${URL}" ]]; then
      echo
      echo "  $(red '✖ Error:') URL is required. Please try again."
    fi
  done
  BATCH_FILE=""  # Clear batch file when using single URL
fi

# Preferi sitemap-only?
echo
echo "  $(color256 82 '┌─') $(bold '🗺️  Sitemap Mode')"
echo "  $(color256 82 '│')  Use sitemap.xml if available?"
echo "  $(color256 82 '│')"
echo "  $(color256 82 '│')  $(color256 220 '1') $(color256 46 '✓') Yes $(color256 246 '(faster, recommended)')"
echo "  $(color256 82 '│')  $(color256 220 '2')   No  $(color256 246 '(crawl manually)')"
echo -n "  $(color256 82 '└─') $(color256 220 '➜') Choice [1-2]: "
read -rp "" choice || true
case "$choice" in
1) USE_SM=Y ;;
2) USE_SM=N ;;
*) USE_SM=Y ;; # default
esac

# Output format
echo
echo "  $(color256 82 '┌─') $(bold '📄 Output Format')"
echo "  $(color256 82 '│')  Choose export format:"
echo "  $(color256 82 '│')"
echo "  $(color256 82 '│')  $(color256 220 '1') $(color256 46 '✓') Markdown  $(color256 246 '(.md with frontmatter)')"
echo "  $(color256 82 '│')  $(color256 220 '2')   JSON       $(color256 246 '(structured data)')"
echo "  $(color256 82 '│')  $(color256 220 '3')   Plain Text $(color256 246 '(no markup)')"
echo "  $(color256 82 '│')  $(color256 220 '4')   HTML       $(color256 246 '(cleaned)')"
echo -n "  $(color256 82 '└─') $(color256 220 '➜') Choice [1-4]: "
read -rp "" choice || true
case "$choice" in
1) FMT=md ;;
2) FMT=json ;;
3) FMT=txt ;;
4) FMT=html ;;
*) FMT=md ;; # default
esac

# Diff mode
echo
echo "  $(color256 82 '┌─') $(bold '🔄 Diff Mode')"
echo "  $(color256 82 '│')  Only update changed pages?"
echo "  $(color256 82 '│')"
echo "  $(color256 82 '│')  $(color256 220 '1')   Yes $(color256 246 '(skip unchanged)')"
echo "  $(color256 82 '│')  $(color256 220 '2') $(color256 46 '✓') No  $(color256 246 '(update all)')"
echo -n "  $(color256 82 '└─') $(color256 220 '➜') Choice [1-2]: "
read -rp "" choice || true
case "$choice" in
1) USE_DIFF=Y ;;
2) USE_DIFF=N ;;
*) USE_DIFF=N ;; # default
esac

echo
wave_line
echo
echo "$(color256 34 '═══════════════════════════════════════════════════════════════')"
echo "  $(bold '📋 Configuration Summary')"
echo "$(color256 34 '═══════════════════════════════════════════════════════════════')"
echo

if [[ -n "$BATCH_FILE" ]]; then
  echo "  $(color256 82 'Mode:')       $(color256 220 'Batch File')"
  echo "  $(color256 82 'File:')       $(color256 220 "$BATCH_FILE")"
else
  echo "  $(color256 82 'Mode:')       $(color256 220 'Single URL')"
  echo "  $(color256 82 'URL:')        $(color256 220 "$URL")"
fi

OUT_DISPLAY="${OUT_DIR/#$HOME/\~}"
echo "  $(color256 82 'Output:')     $(color256 220 "$OUT_DISPLAY")"
echo "  $(color256 82 'Sitemap:')    $(color256 220 "$USE_SM")"

case "$FMT" in
md) FMT_DISPLAY="Markdown (.md)" ;;
json) FMT_DISPLAY="JSON" ;;
txt) FMT_DISPLAY="Plain text (.txt)" ;;
html) FMT_DISPLAY="Cleaned HTML" ;;
*) FMT_DISPLAY="$FMT" ;;
esac
echo "  $(color256 82 'Format:')     $(color256 220 "$FMT_DISPLAY")"
echo "  $(color256 82 'Diff mode:')  $(color256 220 "$USE_DIFF")"

echo
echo "$(color256 34 '═══════════════════════════════════════════════════════════════')"
echo
echo
echo -n "$(color256 46 '  ▶') $(bold 'Ready to start scraping!') Press $(color256 220 'Enter') to proceed or $(color256 196 'Ctrl+C') to cancel..."
read -r _

# Ensure local deps
if [[ ! -d "$PYDEPS_DIR" || -z "$(ls -A "$PYDEPS_DIR" 2>/dev/null)" ]]; then
  echo
  echo "$(color256 220 '  ⚙️  Installing dependencies...')"
  (
    cd "$PROJECT_DIR"
    "$PYTHON" -m pip install --upgrade --no-input --target "$PYDEPS_DIR" -r requirements.txt
  ) &
  spinner $! "$(color256 82 'Setting up environment')"
  echo "$(color256 46 '  ✓ Dependencies ready')"
  echo
fi

# Run scraper
echo
echo "$(color256 34 '═══════════════════════════════════════════════════════════════')"
echo "  $(color256 220 '⚡') $(bold 'Scraping in progress...')"
echo "$(color256 34 '═══════════════════════════════════════════════════════════════')"
echo
EXTRA_ARGS=("--out" "$OUT_DIR" "--format" "$FMT")
if [[ -n "$BATCH_FILE" ]]; then
  EXTRA_ARGS+=("--urls-file" "$BATCH_FILE")
else
  EXTRA_ARGS+=("--url" "$URL")
fi

# Check sitemap if sitemap mode is enabled
USE_SITEMAP_ONLY=false
if [[ "${USE_SM^^}" == "Y" ]] || [[ "${USE_SM^^}" == "YES" ]]; then
  if [[ -n "$BATCH_FILE" ]]; then
    # For batch mode, check first URL
    FIRST_URL=$(head -n 1 "$BATCH_FILE" | tr -d '\r\n' || echo "")
    DOMAIN=$(echo "$FIRST_URL" | sed -E 's|^https?://([^/]+).*|\1|')
  else
    DOMAIN=$(echo "$URL" | sed -E 's|^https?://([^/]+).*|\1|')
  fi
  SITEMAP_URL="https://${DOMAIN}/sitemap.xml"
  if ! curl -s --head --max-time 5 "$SITEMAP_URL" 2>/dev/null | grep -q "200 OK"; then
    echo
    echo
    echo "  $(red '✖') $(yellow 'No sitemap found.')"
    echo
    echo -n "  $(color256 220 '➜') Continue with manual crawl? (Y/n): "
    read -r response || true
    if [[ "${response,,}" == "n" ]] || [[ "${response,,}" == "no" ]]; then
      echo
      echo "  $(red 'Aborted.')"
      exit 0
    fi
    # Will use manual crawl
  else
    USE_SITEMAP_ONLY=true
  fi
fi

# Create Python scraper script inline
SCRAPER_SCRIPT=$(mktemp)
cat > "$SCRAPER_SCRIPT" << 'PYEOF'
import sys
import os
sys.path.insert(0, os.environ.get('PYDEPS_DIR', ''))

import time
import re
import hashlib
from pathlib import Path
from collections import deque
from urllib.parse import urlparse, urljoin, urldefrag
import xml.etree.ElementTree as ET

import httpx
from bs4 import BeautifulSoup
import html2text
from urllib import robotparser

def normalize_url(base, href):
    if not href:
        return None
    abs_url = urljoin(base, href)
    abs_url, _ = urldefrag(abs_url)
    parsed = urlparse(abs_url)
    if parsed.scheme not in {"http", "https"}:
        return None
    normalized = parsed._replace(netloc=parsed.netloc.lower()).geturl()
    return normalized

def same_scope(seed, candidate):
    a = urlparse(seed)
    b = urlparse(candidate)
    return (a.scheme, a.netloc) == (b.scheme, b.netloc) and b.path.startswith(a.path)

def load_robots(seed):
    rp = robotparser.RobotFileParser()
    robots_url = urljoin(seed, "/robots.txt")
    try:
        rp.set_url(robots_url)
        rp.read()
    except Exception:
        pass
    return rp

def iter_sitemap_urls(seed):
    candidates = [urljoin(seed, "/sitemap.xml"), urljoin(seed, "sitemap.xml")]
    with httpx.Client(follow_redirects=True, timeout=15.0) as client:
        for sm_url in candidates:
            try:
                resp = client.get(sm_url)
                if resp.status_code != 200 or "xml" not in resp.headers.get("content-type", ""):
                    continue
                root = ET.fromstring(resp.text)
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

def extract_main_content(html, page_url):
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup.find_all(["nav", "aside", "script", "style", "header", "footer", "form", "img"]):
        tag.decompose()
    main = (soup.find("main") or soup.find("article") or soup.find("div", class_="content") or
            soup.find("div", class_="document") or soup.find("div", class_="theme-default-content") or
            soup.find("div", id=re.compile(r"^content|^main", re.I)) or soup.body)
    container = main or soup
    fence_map = {}
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
            if c in {"bash", "shell", "sh", "nix", "json", "yaml", "toml", "python", "js", "ts"}:
                lang = c
        text_src = code if code else pre
        code_text = text_src.get_text(" ")
        raw_lines = code_text.splitlines()
        cleaned_lines = []
        i = 0
        while i < len(raw_lines):
            line = raw_lines[i].rstrip()
            if re.fullmatch(r"\s*\d{1,3}\s*", line):
                i += 1
                continue
            if re.fullmatch(r"[\s│└├┬─›>•·`~\\/|:_-]+", line) and i + 1 < len(raw_lines):
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
    markdown = re.sub(r"&#x[0-9a-fA-F]+;", "", markdown)
    markdown = re.sub(r"\*\*(.*?)\*\*", r"## \1", markdown)
    markdown = re.sub(r"(^|\n)(note\(|s\()", r"\1\n\n\2", markdown)
    for key, fenced in fence_map.items():
        markdown = markdown.replace(key, fenced)
    markdown = re.sub(r"\n([a-zA-Z0-9_+-]{2,})\n\n```", r"\n```\1\n", markdown)
    markdown = re.sub(r"(?:^|\n)(?:\s*\d+\s*\n){3,}", "\n", markdown, flags=re.MULTILINE)
    markdown = re.sub(r"\n{3,}", "\n\n", markdown)
    title = soup.title.string.strip() if soup.title and soup.title.string else ""
    meta = {"title": title, "url": page_url}
    html_cleaned = str(main) if main else ""
    return markdown, meta, html_cleaned

def slugify_path(base, root_url, page_url, lang_hint="", format="md"):
    a = urlparse(root_url)
    b = urlparse(page_url)
    path = b.path
    if path.endswith("/"):
        path = path + "index"
    if not path:
        path = "index"
    if path.endswith(".html"):
        path = path[:-5]
    if path.endswith("/index"):
        root_path = a.path.rstrip("/")
        path_without_index = path[:-6]
        if path_without_index == root_path or path_without_index == root_path + "/":
            pass
        else:
            path = path_without_index
            if not path or path == "/":
                path = "index"
    safe = re.sub(r"[^a-zA-Z0-9/_\-]", "-", path).strip("/")
    ext = ".md" if format == "md" else f".{format}"
    return base / (safe + ext)

def write_output(out_path, content, meta, format, html_cleaned, diff):
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
            if hashlib.sha1(existing.encode("utf-8")).hexdigest() == hashlib.sha1(final_content.encode("utf-8")).hexdigest():
                return
        except Exception:
            pass
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(final_content)

def normalize_seed(seed):
    """Ensure seed URL ends with / if it has a path"""
    parsed = urlparse(seed)
    if parsed.path and not parsed.path.endswith('/'):
        return seed + '/'
    return seed

def crawl_sitemap_first(seed, out_dir, rps, save_html, lang_hint, format, diff):
    seed = normalize_seed(seed)
    delay = max(0.0, 1.0 / rps)
    count = 0
    all_urls = list(iter_sitemap_urls(seed))
    if not all_urls:
        return 0
    urls = [url for url in all_urls if same_scope(seed, url)]
    if not urls:
        return 0
    print(f"\n\033[33mSitemap found!\033[0m Filtered to \033[32m{len(urls)}\033[0m pages in scope (from {len(all_urls)} total)...", flush=True)
    total = len(urls)
    with httpx.Client(follow_redirects=True, timeout=20.0, headers={"User-Agent": "digit/0.1"}) as client:
        for idx, url in enumerate(urls, start=1):
            try:
                resp = client.get(url)
            except Exception:
                continue
            if resp.status_code != 200 or "html" not in resp.headers.get("content-type", ""):
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

def crawl_with_frontier(seed, out_dir, max_pages, depth_limit, rps, include_rx, exclude_rx, save_html, lang_hint, format, diff):
    seed = normalize_seed(seed)
    parsed_seed = urlparse(seed)
    base = f"{parsed_seed.scheme}://{parsed_seed.netloc}{parsed_seed.path if parsed_seed.path.endswith('/') else parsed_seed.path + '/'}"
    rp = load_robots(base)
    delay = max(0.0, 1.0 / rps)
    queue = deque([(base, 0)])
    seen = set()
    saved_hashes = set()
    with httpx.Client(follow_redirects=True, timeout=20.0, headers={"User-Agent": "digit/0.1"}) as client:
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
            if resp.status_code != 200 or "html" not in resp.headers.get("content-type", ""):
                continue
            html = resp.text
            content_hash = hashlib.sha1(html.encode("utf-8")).hexdigest()
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
            if depth < depth_limit or depth_limit == 0:
                soup = BeautifulSoup(html, "html.parser")
                # Check for meta refresh redirects
                meta_refresh = soup.find("meta", attrs={"http-equiv": re.compile(r"refresh", re.I)})
                if meta_refresh and meta_refresh.get("content"):
                    content = meta_refresh["content"]
                    match = re.search(r"url=([^;\"']+)", content, re.I)
                    if match:
                        href = match.group(1).strip()
                        next_url = normalize_url(url, href)
                        if next_url and same_scope(seed, next_url) and next_url not in seen:
                            queue.append((next_url, depth + 1))
                # Parse regular <a> tags
                for a in soup.find_all("a", href=True):
                    href = a["href"]
                    next_url = normalize_url(url, href)
                    if next_url and same_scope(seed, next_url) and next_url not in seen:
                        queue.append((next_url, depth + 1))
            time.sleep(delay)
    return pages

# Main execution
if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--url")
    parser.add_argument("--urls-file")
    parser.add_argument("--out", default="sites")
    parser.add_argument("--format", default="md")
    parser.add_argument("--sitemap-only", action="store_true")
    parser.add_argument("--diff", action="store_true")
    parser.add_argument("--max-pages", type=int, default=10000)
    parser.add_argument("--depth", type=int, default=0)
    parser.add_argument("--rate", type=float, default=1.5)
    parser.add_argument("--include")
    parser.add_argument("--exclude")
    parser.add_argument("--save-html", action="store_true")
    parser.add_argument("--lang", default="")
    args = parser.parse_args()
    
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
        used_sitemap = False
        written_count = 0
        if args.sitemap_only and not args.include and not args.exclude:
            print(f"[{domain}] Trying sitemap.xml ...", flush=True)
            cnt = crawl_sitemap_first(seed, out_subdir, args.rate, args.save_html, args.lang, args.format, args.diff)
            if cnt > 0:
                used_sitemap = True
                written_count = cnt
        if not used_sitemap:
            written_count = crawl_with_frontier(seed, out_subdir, args.max_pages, args.depth, args.rate, include_rx, exclude_rx, args.save_html, args.lang, args.format, args.diff)
        total_written += written_count
        summary_path = os.environ.get("WEB2SCRAP_SUMMARY_PATH")
        if summary_path:
            with open(summary_path, "w") as f:
                f.write(f"count: {total_written}\n")
PYEOF

# Run scraper
SUMMARY_FILE=$(mktemp)
export WEB2SCRAP_SUMMARY_PATH="$SUMMARY_FILE"
export PYDEPS_DIR="$PYDEPS_DIR"

SCRAPER_ARGS=("--out" "$OUT_DIR" "--format" "$FMT" "--max-pages" "10000" "--depth" "0" "--rate" "1.5")
if [[ -n "$BATCH_FILE" ]]; then
  SCRAPER_ARGS+=("--urls-file" "$BATCH_FILE")
else
  SCRAPER_ARGS+=("--url" "$URL")
fi
if [[ "$USE_SITEMAP_ONLY" == "true" ]]; then
  SCRAPER_ARGS+=("--sitemap-only")
fi
if [[ "${USE_DIFF^^}" == "Y" ]] || [[ "${USE_DIFF^^}" == "YES" ]]; then
  SCRAPER_ARGS+=("--diff")
fi

(
  PYTHONPATH="$PYDEPS_DIR" \
    "$PYTHON" "$SCRAPER_SCRIPT" "${SCRAPER_ARGS[@]}"
) &
PID=$!
# Determine process group id of scraper
PGID=$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d ' ' || echo "")
spinner $PID "$(green 'Running scraper')"
wait $PID
rm -f "$SCRAPER_SCRIPT"

# Summary (boxed)
COUNT=""
if [[ -f "$SUMMARY_FILE" ]]; then
  COUNT=$(grep -E '^count:' "$SUMMARY_FILE" | awk '{print $2}' | tr -d ' ')
fi
if [[ -z "$COUNT" ]]; then
  COUNT=$(find "$OUT_DIR" -type f \( -name "*.md" -o -name "*.json" -o -name "*.txt" -o -name "*.html" \) 2>/dev/null | wc -l | tr -d ' ')
fi
rm -f "$SUMMARY_FILE" 2>/dev/null || true
echo
wave_line
echo
echo "$(color256 34 '═══════════════════════════════════════════════════════════════')"
echo "  $(color256 46 '✓') $(bold 'Scraping Complete!')"
echo "$(color256 34 '═══════════════════════════════════════════════════════════════')"
echo

OUT_DISPLAY="${OUT_DIR/#$HOME/\~}"
echo "  $(color256 82 'Files scraped:') $(color256 220 "$COUNT")"
echo "  $(color256 82 'Location:')      $(color256 220 "$OUT_DISPLAY")"

echo
echo "$(color256 34 '═══════════════════════════════════════════════════════════════')"
echo
echo "$(color256 46 '  ✨ All done! Your documentation is ready to use.')"
wave_line
