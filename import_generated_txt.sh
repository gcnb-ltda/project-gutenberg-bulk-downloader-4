#!/usr/bin/env bash
set -euo pipefail

RSYNC_SOURCE="${RSYNC_SOURCE:-gutenberg.pglaf.org::gutenberg}"
RUN_TARGET_MIB="${RUN_TARGET_MIB:-2500}"
REPO_TARGET_GIB="${REPO_TARGET_GIB:-8}"
MAX_FILE_MIB="${MAX_FILE_MIB:-90}"
PUSH_BATCH_MIB="${PUSH_BATCH_MIB:-400}"
STATE_FILE="${STATE_FILE:-txt-continuation-state.json}"
INDEX_FILE="${INDEX_FILE:-txt-index.tsv}"
OUT_DIR="${OUT_DIR:-books_txt}"

RUN_TARGET_BYTES=$((RUN_TARGET_MIB * 1024 * 1024))
REPO_TARGET_BYTES=$((REPO_TARGET_GIB * 1024 * 1024 * 1024))
MAX_FILE_BYTES=$((MAX_FILE_MIB * 1024 * 1024))
PUSH_BATCH_BYTES=$((PUSH_BATCH_MIB * 1024 * 1024))

for c in rsync python3 git cp; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 1; }
done
mkdir -p "$OUT_DIR"

readarray -t STATE < <(python3 - "$STATE_FILE" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:
    d={}
print(int(d.get('last_id',0)))
print(int(d.get('total_bytes_repo',0)))
print(int(d.get('total_files_repo',0)))
PY
)
LAST_ID="${STATE[0]:-0}"
TOTAL_BYTES="${STATE[1]:-0}"
TOTAL_FILES="${STATE[2]:-0}"

if (( TOTAL_BYTES >= REPO_TARGET_BYTES )); then
  echo "Repository target already reached: $TOTAL_BYTES bytes"
  exit 0
fi

REMAINING=$((REPO_TARGET_BYTES - TOTAL_BYTES))
if (( RUN_TARGET_BYTES > REMAINING )); then RUN_TARGET_BYTES="$REMAINING"; fi

echo "Listing Project Gutenberg main collection from $RSYNC_SOURCE ..."
rsync -r --list-only --timeout=600 "$RSYNC_SOURCE" > /tmp/gutenberg-main-list.txt

python3 - "$LAST_ID" "$RUN_TARGET_BYTES" "$MAX_FILE_BYTES" <<'PY'
import os,re,sys
last_id=int(sys.argv[1]); target=int(sys.argv[2]); max_file=int(sys.argv[3])
books={}
all_ids=set()
for line in open('/tmp/gutenberg-main-list.txt',encoding='utf-8',errors='replace'):
    parts=line.split()
    if len(parts)<5:
        continue
    try:
        size=int(parts[1])
    except ValueError:
        continue
    path=parts[-1].lstrip('./')
    name=os.path.basename(path).lower()

    # Accept only text files named after the actual Gutenberg ebook ID.
    # Examples: 12345-0.txt (preferred UTF-8), 12345.txt, 12345-8.txt.
    m=re.fullmatch(r'(\d+)(?:-(\d+))?\.txt', name)
    if not m:
        continue
    gid=int(m.group(1)); suffix=m.group(2)
    all_ids.add(gid)
    if gid<=last_id or size<=0 or size>max_file:
        continue

    if suffix == '0': rank=0
    elif suffix is None: rank=1
    else: rank=2
    cand=(rank,size,path)
    prev=books.get(gid)
    if prev is None or cand < prev:
        books[gid]=cand

selected=[]; total=0
for gid in sorted(books):
    rank,size,path=books[gid]
    if selected and total+size>target:
        break
    selected.append((gid,size,path)); total+=size

with open('/tmp/selected.tsv','w',encoding='utf-8') as f:
    for gid,size,path in selected:
        f.write(f'{gid}\t{size}\t{path}\n')
with open('/tmp/selected.paths','w',encoding='utf-8') as f:
    for _,_,path in selected:
        f.write(path+'\n')
with open('/tmp/discovery.meta','w',encoding='utf-8') as f:
    f.write(f'{len(all_ids)}\n{max(all_ids) if all_ids else 0}\n')
print(f'discovered_ids={len(all_ids)} max_id={max(all_ids) if all_ids else 0}')
print(f'selected={len(selected)} bytes={total} last_id={selected[-1][0] if selected else last_id}')
PY

readarray -t DISCOVERY < /tmp/discovery.meta
DISCOVERED_COUNT="${DISCOVERY[0]:-0}"
DISCOVERED_MAX_ID="${DISCOVERY[1]:-0}"

if (( DISCOVERED_COUNT == 0 )); then
  echo "ERROR: no ebook TXT files were discovered. Refusing to mark collection complete." >&2
  exit 2
fi

if [[ ! -s /tmp/selected.paths ]]; then
  if (( LAST_ID < DISCOVERED_MAX_ID )); then
    echo "ERROR: no selectable TXT files after ID $LAST_ID although max discovered ID is $DISCOVERED_MAX_ID." >&2
    exit 3
  fi
  python3 - "$STATE_FILE" "$LAST_ID" "$TOTAL_BYTES" "$TOTAL_FILES" "$DISCOVERED_MAX_ID" <<'PY'
import json,sys
p,last,b,f,maxid=sys.argv[1:]
json.dump({'collection':'Project Gutenberg main TXT','last_id':int(last),'total_bytes_repo':int(b),'total_files_repo':int(f),'max_discovered_id':int(maxid),'complete':True},open(p,'w',encoding='utf-8'),indent=2)
PY
  git add "$STATE_FILE"
  git commit -m "Mark Project Gutenberg TXT collection complete" || true
  git push origin HEAD:main
  exit 0
fi

rm -rf /tmp/pg-main
mkdir -p /tmp/pg-main
rsync -avR --timeout=600 --files-from=/tmp/selected.paths "$RSYNC_SOURCE" /tmp/pg-main/

[[ -f "$INDEX_FILE" ]] || printf 'gutenberg_id\tbytes\tsource_path\trepo_path\n' > "$INDEX_FILE"

batch_bytes=0
batch_files=0
batch_no=1
current_id="$LAST_ID"

commit_batch() {
  if (( batch_files == 0 )); then return; fi
  TOTAL_BYTES=$((TOTAL_BYTES + batch_bytes))
  TOTAL_FILES=$((TOTAL_FILES + batch_files))
  python3 - "$STATE_FILE" "$current_id" "$TOTAL_BYTES" "$TOTAL_FILES" "$DISCOVERED_MAX_ID" <<'PY'
import json,sys
p,last,b,f,maxid=sys.argv[1:]
json.dump({'collection':'Project Gutenberg main TXT','last_id':int(last),'total_bytes_repo':int(b),'total_files_repo':int(f),'max_discovered_id':int(maxid),'complete':False},open(p,'w',encoding='utf-8'),indent=2)
PY
  git add "$STATE_FILE" "$INDEX_FILE"
  git commit -m "Add Project Gutenberg TXT batch ${batch_no} through ID ${current_id}"
  git push origin HEAD:main
  batch_bytes=0
  batch_files=0
  batch_no=$((batch_no + 1))
}

while IFS=$'\t' read -r gid size path; do
  [[ -z "${path:-}" ]] && continue
  src="/tmp/pg-main/$path"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: rsync did not produce expected file $src" >&2
    exit 4
  fi

  base="$(basename "$path")"
  if [[ ! "$base" =~ ^${gid}(-[0-9]+)?\.txt$ ]]; then
    echo "ERROR: basename/ID validation failed: gid=$gid path=$path" >&2
    exit 5
  fi

  dst="$OUT_DIR/$gid.txt"
  cp "$src" "$dst"
  git add "$dst"
  printf '%s\t%s\t%s\t%s\n' "$gid" "$size" "$path" "$dst" >> "$INDEX_FILE"

  batch_bytes=$((batch_bytes + size))
  batch_files=$((batch_files + 1))
  current_id="$gid"

  if (( batch_bytes >= PUSH_BATCH_BYTES )); then
    commit_batch
  fi
done < /tmp/selected.tsv

commit_batch

echo "Checkpoint Gutenberg ID: $current_id"
echo "TXT bytes in repository: $TOTAL_BYTES"
echo "TXT files in repository: $TOTAL_FILES"
echo "Max Gutenberg ID discovered in source: $DISCOVERED_MAX_ID"
