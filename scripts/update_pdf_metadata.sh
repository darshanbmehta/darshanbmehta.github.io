#!/usr/bin/env zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PUB_HTML="publications.html"

if ! command -v exiftool >/dev/null 2>&1; then
  echo "exiftool not found. Install: brew install exiftool"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found. Install: brew install python"
  exit 1
fi

python3 - <<'PY'
import os, sys, json, subprocess, re
from urllib.parse import unquote
from datetime import datetime

repo_root = os.getcwd()
pub_html = os.path.join(repo_root, 'publications.html')
if not os.path.isfile(pub_html):
    print('publications.html not found', file=sys.stderr); sys.exit(1)

with open(pub_html, 'r', encoding='utf-8') as f:
    html = f.read()

start_tag = '<script type="application/ld+json">'
end_tag = '</script>'
si = html.find(start_tag)
if si == -1:
    print('JSON-LD script tag not found', file=sys.stderr); sys.exit(1)
si += len(start_tag)
ei = html.find(end_tag, si)
if ei == -1:
    print('JSON-LD script end tag not found', file=sys.stderr); sys.exit(1)
json_text = html[si:ei].strip()

try:
    data = json.loads(json_text)
except Exception as e:
    print('Failed to parse JSON-LD:', e, file=sys.stderr)
    sys.exit(1)

entries = data.get('@graph', [])
modified_files = []
for entry in entries:
    url = entry.get('url')
    title = entry.get('name','')
    datePublished = entry.get('datePublished','')
    description = entry.get('description','')
    authors = []
    for a in entry.get('author', []):
        if isinstance(a, dict):
            n = a.get('name')
            if n:
                authors.append(n)
        elif isinstance(a, str):
            authors.append(a)

    if not url:
        print('Skipping entry without url for title:', title)
        continue
    filename = unquote(url.split('/')[-1])
    pdfpath = os.path.join(repo_root, 'publications', filename)
    if not os.path.isfile(pdfpath):
        print('WARNING: PDF not found:', pdfpath)
        continue

    # year extraction
    year = ''
    if datePublished and len(datePublished) >=4 and re.match(r'^\d{4}', datePublished):
        year = datePublished[:4]
    else:
        m = re.search(r'(\d{4})', filename)
        if m:
            year = m.group(1)

    author_str = ', '.join(authors)
    keywords = ','.join((title + ' ' + author_str).split())

    print('Processing:', pdfpath)
    print('  Title:', title)
    print('  Authors:', author_str)
    if year:
        print('  Year (mtime):', year)

    # write metadata using exiftool
    cmd = [
        'exiftool', '-overwrite_original',
        f'-Title={title}',
        f'-Author={author_str}',
        f'-Subject={description}',
        f'-Keywords={keywords}',
        pdfpath
    ]
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError as e:
        print('exiftool failed for', pdfpath, file=sys.stderr)
        continue

    # set mtime to YYYY-01-15 12:00
    if year:
        try:
            dt = datetime(int(year), 1, 15, 12, 0, 0)
            ts = dt.timestamp()
            os.utime(pdfpath, (ts, ts))
        except Exception as e:
            print('Failed to set mtime for', pdfpath, e, file=sys.stderr)

    modified_files.append(pdfpath)

# Git operations: stage, commit, push if files changed
if modified_files:
    try:
        subprocess.run(['git', 'add'] + modified_files, check=True)
        # check if anything to commit
        res = subprocess.run(['git', 'status', '--porcelain'], check=True, stdout=subprocess.PIPE, text=True)
        if res.stdout.strip():
            subprocess.run(['git', 'commit', '-m', 'Update PDF metadata and set mtime to YYYY-01-15 per filename year'], check=True)
            subprocess.run(['git', 'push'], check=True)
            print('Committed and pushed changes.')
        else:
            print('No changes to commit.')
    except Exception as e:
        print('Git operations failed:', e, file=sys.stderr)
else:
    print('No PDFs processed/modified.')

PY

exit 0
