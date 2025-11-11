## digit — Website Documentation Scraper

digit scrapes documentation websites and exports to **Markdown**, **JSON**, **plain text**, or **HTML**. Optimized for LLM ingestion and Obsidian. Prefers sitemaps, falls back to smart crawling.

### 📦 Installation

1. Clone the repository:
```bash
git clone https://github.com/chironsb/digit.git
cd digit
```

2. Install dependencies:
```bash
python -m pip install -r requirements.txt --target .pydeps
```

### 🚀 Usage

**Run interactively:**
   - **Linux/macOS**: `bash digit.sh`
   - **Windows**: `python digit.py`

**Run directly with arguments:**
```bash
python digit.py --url https://website.com --out ./sites --sitemap-only
```

### 📁 Project structure

- `.pydeps/` — project-local Python dependencies (installed automatically by the script if missing)
- `sites/` — all scraped sites (default output location)
- `digit.py` — main CLI (Python)
- `digit.sh` — interactive wrapper (Bash)
- `requirements.txt` — dependency list for reproducible installs

### CLI options (highlights)

- `--url` / `-u` — seed URL
- `--out` / `-o` — output directory (default: `sites`)
- `--sitemap-only` — fetch only URLs listed in sitemap(s); exits if no sitemap
- `--depth` — max crawl depth for fallback crawler (`0` = unlimited)
- `--rate` — requests per second (default: `1.5`)
- `--include` / `--exclude` — regex filters for URLs
- `--save-html` — also save raw HTML alongside the output file (off by default)

### Output

- **Markdown**: Files with YAML frontmatter (`title`, `url`, `date_scraped`), fenced code blocks preserved
- **JSON**: Structured data with metadata and content
- **Plain text**: Clean text without markup
- **HTML**: Cleaned HTML without boilerplate
- Directory structure mirrors the URL path (e.g., `/guide/intro` → `sites/guide/intro.[format]`)

### How it works (short version)

1. Tries to read `sitemap.xml` (and sitemap indexes) to get the full list of pages.
2. If `--sitemap-only` is set and no sitemap is found, it exits.
3. Otherwise falls back to scoped crawling (same host and subpath) with rate limiting.
4. Cleans HTML boilerplate and converts the main content to the selected format.

### Notes on environments

- `.pydeps` is used to keep dependencies local to the project without requiring a full virtualenv.
- A traditional `.venv` is optional; the wrapper works fine with `.pydeps` alone.

### Examples

```bash
# Sitemap-only (fast and complete when sitemap exists)
python digit.py --url https://react.dev/ --out ./sites --sitemap-only

# Fallback crawler with unlimited depth and polite rate
python digit.py --url https://docs.python.org/3/ --out ./sites --depth 0 --rate 1.5

# Include/exclude filters
python digit.py --url https://example.com/docs/ --out ./sites \
  --include '^https://example.com/docs/' --exclude '(/(zh|ja|pt)/|\?utm_)'
```

### License

MIT License - feel free to use this tool for your documentation scraping needs.

