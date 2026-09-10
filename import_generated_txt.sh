#!/usr/bin/env bash
set -euo pipefail

RUN_TARGET_MIB="${RUN_TARGET_MIB:-2000}"
REPO_TARGET_GIB="${REPO_TARGET_GIB:-8}"
MAX_TEXT_MIB="${MAX_TEXT_MIB:-90}"
MAX_ZIP_MIB="${MAX_ZIP_MIB:-100}"
PUSH_BATCH_MIB="${PUSH_BATCH_MIB:-300}"
CHECKPOINT_PAGES="${CHECKPOINT_PAGES:-5}"
REQUEST_DELAY_SECONDS="${REQUEST_DELAY_SECONDS:-2.1}"
MAX_PAGES_PER_RUN="${MAX_PAGES_PER_RUN:-40}"
STATE_FILE="${STATE_FILE:-txt-continuation-state.json}"
INDEX_FILE="${INDEX_FILE:-txt-harvest-index.tsv}"
OUT_DIR="${OUT_DIR:-books_txt}"

for c in python3 git; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 1; }
done
mkdir -p "$OUT_DIR"

python3 - "$STATE_FILE" "$INDEX_FILE" "$OUT_DIR" "$RUN_TARGET_MIB" "$REPO_TARGET_GIB" "$MAX_TEXT_MIB" "$MAX_ZIP_MIB" "$PUSH_BATCH_MIB" "$CHECKPOINT_PAGES" "$REQUEST_DELAY_SECONDS" "$MAX_PAGES_PER_RUN" <<'PY'
import hashlib, html, io, json, os, re, subprocess, sys, time, urllib.parse, urllib.request, zipfile
from html.parser import HTMLParser

(
    state_file,index_file,out_dir,run_target_mib,repo_target_gib,max_text_mib,
    max_zip_mib,push_batch_mib,checkpoint_pages,delay_s,max_pages_per_run
)=sys.argv[1:]
run_target=int(run_target_mib)*1024*1024
repo_target=int(repo_target_gib)*1024*1024*1024
max_text=int(max_text_mib)*1024*1024
max_zip=int(max_zip_mib)*1024*1024
push_batch=int(push_batch_mib)*1024*1024
checkpoint_pages=int(checkpoint_pages)
delay=float(delay_s)
max_pages=int(max_pages_per_run)

try:
    state=json.load(open(state_file,encoding='utf-8'))
except Exception:
    state={}
offset=int(state.get('harvest_offset',0))
total_bytes=int(state.get('total_bytes_repo',0))
total_files=int(state.get('total_files_repo',0))
pages_processed=int(state.get('pages_processed',0))

if total_bytes >= repo_target:
    print(f'Repository target reached: {total_bytes} bytes')
    raise SystemExit(0)

run_bytes=0
batch_bytes=0
batch_files=0
pages_this_run=0
last_request_at=0.0

UA='GCNB-Project-Gutenberg-Archiver/1.0 (+https://github.com/gcnb-ltda/project-gutenberg-bulk-downloader-4)'

def polite_get(url):
    global last_request_at
    wait=delay-(time.time()-last_request_at)
    if wait>0: time.sleep(wait)
    req=urllib.request.Request(url,headers={'User-Agent':UA,'Accept':'*/*'})
    with urllib.request.urlopen(req,timeout=120) as r:
        clen=r.headers.get('Content-Length')
        if clen and int(clen)>max_zip and url.lower().endswith('.zip'):
            raise ValueError(f'archive too large: {clen} bytes')
        data=r.read(max_zip+1 if url.lower().endswith('.zip') else None)
    last_request_at=time.time()
    if url.lower().endswith('.zip') and len(data)>max_zip:
        raise ValueError(f'archive too large: {len(data)} bytes')
    return data

class HarvestParser(HTMLParser):
    def __init__(self):
        super().__init__(); self.links=[]
    def handle_starttag(self,tag,attrs):
        if tag!='a': return
        href=dict(attrs).get('href')
        if href: self.links.append(html.unescape(href))

def parse_page(raw,base_url):
    text=raw.decode('utf-8','replace')
    p=HarvestParser(); p.feed(text)
    zips=[]; next_offset=None
    for href in p.links:
        u=urllib.parse.urljoin(base_url,href)
        if re.search(r'https://aleph\.gutenberg\.org/.+\.zip$',u,re.I):
            zips.append(u)
        if 'gutenberg.org/robot/harvest' in u or href.startswith('?'):
            q=urllib.parse.parse_qs(urllib.parse.urlparse(u).query)
            if 'offset' in q:
                try:
                    cand=int(q['offset'][0])
                    if cand>offset and (next_offset is None or cand<next_offset): next_offset=cand
                except Exception: pass
    return zips,next_offset

def ebook_id_and_rank(url):
    name=os.path.basename(urllib.parse.urlparse(url).path).lower()
    m=re.fullmatch(r'(\d+)(?:-(\d+))?\.zip',name)
    if not m: return None
    gid=int(m.group(1)); suffix=m.group(2)
    rank=0 if suffix=='0' else (1 if suffix is None else 2)
    return gid,rank

def choose_urls(urls):
    best={}
    for u in urls:
        x=ebook_id_and_rank(u)
        if not x: continue
        gid,rank=x
        cur=best.get(gid)
        if cur is None or (rank,u)<(cur[0],cur[1]): best[gid]=(rank,u)
    return [(gid,v[1]) for gid,v in sorted(best.items())]

def extract_txt(zip_bytes,gid):
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
        candidates=[]
        for n in z.namelist():
            if n.endswith('/'): continue
            base=os.path.basename(n).lower()
            m=re.fullmatch(rf'{gid}(?:-(\d+))?\.txt',base)
            if not m: continue
            suf=m.group(1)
            rank=0 if suf=='0' else (1 if suf is None else 2)
            info=z.getinfo(n)
            if info.file_size<=0 or info.file_size>max_text: continue
            candidates.append((rank,info.file_size,n))
        if not candidates: return None,None
        candidates.sort()
        _,_,member=candidates[0]
        data=z.read(member)
        if len(data)>max_text: return None,None
        return member,data

def save_state(next_offset,complete=False):
    obj={
      'collection':'Project Gutenberg Robot Harvest TXT',
      'harvest_offset':int(next_offset),
      'total_bytes_repo':int(total_bytes),
      'total_files_repo':int(total_files),
      'pages_processed':int(pages_processed),
      'complete':bool(complete)
    }
    with open(state_file,'w',encoding='utf-8') as f: json.dump(obj,f,indent=2)

def git_commit(message):
    subprocess.run(['git','add',state_file,index_file,out_dir],check=True)
    r=subprocess.run(['git','diff','--cached','--quiet'])
    if r.returncode==0: return
    subprocess.run(['git','commit','-m',message],check=True)
    subprocess.run(['git','push','origin','HEAD:main'],check=True)

if not os.path.exists(index_file):
    with open(index_file,'w',encoding='utf-8') as f:
        f.write('gutenberg_id\tbytes\tsha256\tsource_zip\tmember\trepo_path\n')

while run_bytes < run_target and total_bytes < repo_target and pages_this_run < max_pages:
    page_url='https://www.gutenberg.org/robot/harvest?filetypes%5B%5D=txt'
    if offset: page_url += '&offset='+str(offset)
    print('Harvest page:',page_url,flush=True)
    page=polite_get(page_url)
    urls,next_offset=parse_page(page,page_url)
    chosen=choose_urls(urls)
    if not chosen:
        raise RuntimeError(f'No TXT ZIP links found at offset {offset}')

    for gid,url in chosen:
        dst=os.path.join(out_dir,f'{gid}.txt')
        if os.path.exists(dst):
            continue
        try:
            zb=polite_get(url)
            member,data=extract_txt(zb,gid)
            if data is None:
                print('Skip: no matching TXT in',url,flush=True); continue
        except Exception as e:
            print('Skip download/extract error:',url,e,flush=True); continue
        sha=hashlib.sha256(data).hexdigest()
        with open(dst,'wb') as f: f.write(data)
        with open(index_file,'a',encoding='utf-8') as f:
            f.write(f'{gid}\t{len(data)}\t{sha}\t{url}\t{member}\t{dst}\n')
        total_bytes += len(data); total_files += 1; run_bytes += len(data); batch_bytes += len(data); batch_files += 1
        if run_bytes>=run_target or total_bytes>=repo_target: break

    pages_this_run += 1; pages_processed += 1
    if next_offset is None:
        save_state(offset,complete=True)
        git_commit(f'Complete Project Gutenberg TXT harvest at offset {offset}')
        print('Robot Harvest completed.')
        raise SystemExit(0)
    offset=next_offset
    save_state(offset,complete=False)

    if batch_bytes>=push_batch or pages_this_run % checkpoint_pages == 0:
        git_commit(f'Add Project Gutenberg TXT harvest through offset {offset}')
        batch_bytes=0; batch_files=0

save_state(offset,complete=False)
git_commit(f'Checkpoint Project Gutenberg TXT harvest at offset {offset}')
print(f'Run complete: added {run_bytes} bytes; repository total {total_bytes} bytes / {total_files} files; next offset {offset}')
PY
