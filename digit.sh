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
  if [[ -z "${URL}" ]]; then
    echo
    echo "  $(color256 82 '┌─') $(bold 'Target URL')"
    echo "  $(color256 82 '│')  Enter the website to scrape:"
    echo -n "  $(color256 82 '└─') $(color256 220 '➜') "
    read -r URL
  fi
  if [[ -z "${URL}" ]]; then
    echo
    echo "  $(red '✖ Error:') URL is required"
    exit 1
  fi
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
  echo "  $(color256 82 'Mode:')        $(color256 220 'Batch File')"
  echo "  $(color256 82 'File:')       $(color256 220 "$BATCH_FILE")"
else
  echo "  $(color256 82 'Mode:')        $(color256 220 'Single URL')"
  echo "  $(color256 82 'URL:')         $(color256 220 "$URL")"
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
case "${USE_SM^^}" in
Y | YES) EXTRA_ARGS+=("--sitemap-only") ;;
*) ;;
esac
case "${USE_DIFF^^}" in
Y | YES) EXTRA_ARGS+=("--diff") ;;
*) ;;
esac

SUMMARY_FILE=$(mktemp)
export WEB2SCRAP_SUMMARY_PATH="$SUMMARY_FILE"
(
  PYTHONPATH="$PYDEPS_DIR" \
    "$PYTHON" "$PROJECT_DIR/digit.py" "${EXTRA_ARGS[@]}"
) &
PID=$!
# Determine process group id of scraper
PGID=$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d ' ' || echo "")
spinner $PID "$(green 'Running scraper')"
wait $PID

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
