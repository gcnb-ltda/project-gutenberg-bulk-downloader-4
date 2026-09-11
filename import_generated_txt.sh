#!/usr/bin/env bash
set -euo pipefail

RUN_TARGET_MIB="${RUN_TARGET_MIB:-1000}"
REPO_TARGET_GIB="${REPO_TARGET_GIB:-8}"
MAX_TEXT_MIB="${MAX_TEXT_MIB:-90}"
PUSH_BATCH_MIB="${PUSH_BATCH_MIB:-250}"
REQUEST_DELAY_SECONDS="${REQUEST_DELAY_SECONDS:-0.15}"
STATE_FILE="${STATE_FILE:-txt-continuation-state.json}"
INDEX_FILE="${INDEX_FILE:-txt-direct-index.tsv}"
OUT_DIR="${OUT_DIR:-books_txt}"
CATALOG_URL="${CATALOG_URL:-https://www.gutenberg.org/cache/epub/feeds/pg_catalog.csv.gz}"

for c in python3 git; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 1; }
done
mkdir -p "$OUT_DIR"

python3 - "$STATE_FILE" "$INDEX_FILE" "$OUT_DIR" "$RUN_TARGET_MIB" "$REPO_TARGET_GIB" "$MAX_TEXT_MIB" "$PUSH_BATCH_MIB" "$REQUEST_DELAY_SECONDS" "$CATALOG_URL" <<'PY'
import csv, gzip, hashlib, io, json, os, re, subprocess, sys, time
import urllib.error, urllib.request

state_file,index_file,out_dir,run_target_mib,repo_target_gib,max_text_mib,push_batch_mib,delay_s,catalog_url=sys.argv[1:]
run_target=int(run_target_mib)*1024*1024
repo_target=int(repo_target_gib)*1024*1024*1024
max_text=int(max_text_mib)*1024*1024
push_batch=int(push_batch_mib)*1024*1024
delay=float(delay_s)
UA='GCNB-Project-Gutenberg-Archiver/2.0 (+https://github.com/gcnb-ltda/project-gutenberg-bulk-downloader-4)'

try:
    state=json.load(open(state_file,encoding='utf-8'))
except Exception:
    state={}
last_id=int(state.get('last_id',0)) if state.get('collection')=='Project Gutenberg direct cache TXT' else 0
total_bytes=int(state.get('total_bytes_repo',0))
total_files=int(state.get('total_files_repo',0))

# Reconcile counters with files already in the repository. This preserves valid
# TXT files created by earlier importers while starting a clean catalog cursor.
existing=[]
actual_bytes=0
if os.path.isdir(out_dir):
    for name in os.listdir(out_dir):
        m=re.fullmatch(r'(\d+)\.txt',name)
        if not m: continue
        path=os.path.join(out_dir,name)
        if os.path.isfile(path):
            existing.append(int(m.group(1)))
            actual_bytes += os.path.getsize(path)
if existing:
    total_files=len(existing)
    total_bytes=actual_bytes
else:
    total_files=0
    total_bytes=0

if total_bytes>=repo_target:
    print(f'Repository target already reached: {total_bytes} bytes / {total_files} files')
    raise SystemExit(0)

last_request=0.0
def get(url, attempts=4, limit=None):
    global last_request
    err=None
    for attempt in range(1,attempts+1):
        wait=delay-(time.time()-last_request)
        if wait>0: time.sleep(wait)
        try:
            req=urllib.request.Request(url,headers={'User-Agent':UA,'Accept':'text/plain,application/gzip,*/*'})
            with urllib.request.urlopen(req,timeout=90) as r:
                data=r.read((limit+1) if limit else None)
            last_request=time.time()
            if limit and len(data)>limit:
                raise ValueError(f'content exceeds limit: {len(data)} bytes')
            return data
        except urllib.error.HTTPError as e:
            last_request=time.time()
            if e.code in (403,404,410):
                raise
            err=e
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            last_request=time.time(); err=e
        if attempt<attempts: time.sleep(min(20,2**attempt))
    raise err

print('Downloading Project Gutenberg catalog...',flush=True)
raw=get(catalog_url,attempts=4)
if catalog_url.endswith('.gz'):
    raw=gzip.decompress(raw)
text=raw.decode('utf-8-sig','replace')
reader=csv.DictReader(io.StringIO(text))
if not reader.fieldnames:
    raise RuntimeError('Catalog has no header')

id_field=None
for f in reader.fieldnames:
    key=(f or '').strip().lower().replace(' ','')
    if key in ('text#','text','ebook#','ebook','id','gutenbergid'):
        id_field=f; break
if id_field is None:
    # Current Project Gutenberg catalog uses Text#; this fallback keeps the
    # importer tolerant if only the label changes while the first column stays numeric.
    id_field=reader.fieldnames[0]

ids=[]
for row in reader:
    value=(row.get(id_field) or '').strip()
    if value.isdigit(): ids.append(int(value))
ids=sorted(set(ids))
if not ids:
    raise RuntimeError(f'No Gutenberg IDs found in catalog; fields={reader.fieldnames!r}')
print(f'Catalog IDs: {len(ids)}; range {ids[0]}..{ids[-1]}; continuing after {last_id}',flush=True)

if not os.path.exists(index_file):
    with open(index_file,'w',encoding='utf-8') as f:
        f.write('gutenberg_id\tbytes\tsha256\tsource_url\trepo_path\n')

run_bytes=0
batch_bytes=0
batch_files=0
processed=0
missing=0
current_id=last_id


def save_state(complete=False):
    obj={
      'collection':'Project Gutenberg direct cache TXT',
      'catalog_url':catalog_url,
      'last_id':int(current_id),
      'total_bytes_repo':int(total_bytes),
      'total_files_repo':int(total_files),
      'complete':bool(complete)
    }
    with open(state_file,'w',encoding='utf-8') as f: json.dump(obj,f,indent=2)


def git_commit(message):
    subprocess.run(['git','add',state_file,index_file,out_dir],check=True)
    r=subprocess.run(['git','diff','--cached','--quiet'])
    if r.returncode==0: return
    subprocess.run(['git','commit','-m',message],check=True)
    subprocess.run(['git','push','origin','HEAD:main'],check=True)

for gid in ids:
    if gid<=last_id: continue
    if run_bytes>=run_target or total_bytes>=repo_target: break
    current_id=gid
    processed+=1
    dst=os.path.join(out_dir,f'{gid}.txt')
    if os.path.exists(dst):
        continue

    # Generated UTF-8 plain text maintained by Project Gutenberg.
    candidates=[
      f'https://www.gutenberg.org/cache/epub/{gid}/pg{gid}.txt',
      f'https://www.gutenberg.org/files/{gid}/{gid}-0.txt',
      f'https://www.gutenberg.org/files/{gid}/{gid}.txt',
    ]
    data=None; source=None
    for url in candidates:
        try:
            candidate=get(url,attempts=3,limit=max_text)
            if not candidate: continue
            # Reject HTML/error pages accidentally served with HTTP 200.
            prefix=candidate[:500].lower()
            if b'<html' in prefix or b'<!doctype html' in prefix: continue
            data=candidate; source=url; break
        except urllib.error.HTTPError as e:
            if e.code in (403,404,410): continue
            print(f'HTTP error for {url}: {e}',flush=True)
        except Exception as e:
            print(f'Download error for {url}: {e}',flush=True)
    if data is None:
        missing+=1
        continue

    sha=hashlib.sha256(data).hexdigest()
    with open(dst,'wb') as f: f.write(data)
    with open(index_file,'a',encoding='utf-8') as f:
        f.write(f'{gid}\t{len(data)}\t{sha}\t{source}\t{dst}\n')
    total_bytes+=len(data); total_files+=1; run_bytes+=len(data); batch_bytes+=len(data); batch_files+=1

    if batch_bytes>=push_batch:
        save_state(False)
        git_commit(f'Add Project Gutenberg TXT through ID {current_id}')
        print(f'Checkpoint ID {current_id}: repo={total_bytes} bytes/{total_files} files, run={run_bytes} bytes',flush=True)
        batch_bytes=0; batch_files=0

complete = current_id>=ids[-1] and total_bytes<repo_target
save_state(complete)
git_commit(('Complete' if complete else 'Checkpoint')+f' Project Gutenberg direct TXT through ID {current_id}')
print(f'Run complete: processed={processed}, missing={missing}, added={run_bytes} bytes; repo={total_bytes} bytes/{total_files} files; last_id={current_id}; complete={complete}',flush=True)
PY
