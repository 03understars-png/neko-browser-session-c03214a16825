#!/usr/bin/env bash
set -uo pipefail

readonly STREAMS=${CB_TRANSFER_STREAMS:-16}
readonly PART=$((8 * 1024 * 1024))
readonly LARGE=$((32 * 1024 * 1024))
RETRY_ALL=()
if curl --help all 2>/dev/null | grep -- '--retry-all-errors' >/dev/null; then RETRY_ALL=(--retry-all-errors); fi
readonly PART_CURL=(--fail --silent --show-error --retry 4 --retry-delay 2 "${RETRY_ALL[@]}"
  --speed-limit 10240 --speed-time 30)

now() { date +%s; }

fan_out() {
  local n
  while read -r n; do
    while (($(jobs -rp | wc -l) >= STREAMS)); do wait -n 2>/dev/null || sleep 0.2; done
    "$@" "$n" &
  done
  wait
}

remote_size() {
  curl --fail --silent --head --location --max-time 30 "$1" 2>/dev/null |
    awk -F': *' 'tolower($1) == "content-length" { gsub(/\r/, "", $2); size = $2 } END { print size + 0 }'
}

get() {
  local url=$1 out=$2 limit=$3 size count dir started round missing i
  started=$(now)
  size=$(remote_size "$url")
  if ((size < LARGE)); then
    curl --fail --location --silent --show-error --retry 3 --retry-delay 5 "${RETRY_ALL[@]}" \
      --speed-limit 10240 --speed-time 60 --max-time "$limit" "$url" --output "$out"
    return
  fi
  count=$(((size + PART - 1) / PART))
  dir=$(mktemp -d "${TMPDIR:-/tmp}/cb-get.XXXXXX")
  part_get() {
    local i=$1 from=$(($1 * PART)) to=$((($1 + 1) * PART - 1)) want
    ((to < size)) || to=$((size - 1))
    want=$((to - from + 1))
    curl "${PART_CURL[@]}" --max-time "$((limit < 300 ? limit : 300))" --range "$from-$to" --output "$dir/$i" "$url" 2>>"$dir/errors" || true
    [[ $(wc -c <"$dir/$i" 2>/dev/null | tr -d ' ') == "$want" ]] || rm -f "$dir/$i"
  }
  for round in 1 2 3; do
    missing=()
    for ((i = 0; i < count; i++)); do [[ -f $dir/$i ]] || missing+=("$i"); done
    ((${#missing[@]})) || break
    (($(now) - started < limit)) || break
    printf '%s\n' "${missing[@]}" | fan_out part_get
  done
  for ((i = 0; i < count; i++)); do
    [[ -f $dir/$i ]] || { printf 'Download incomplete: part %s of %s never arrived. %s\n' "$((i + 1))" "$count" \
      "$(tail -n 1 "$dir/errors" 2>/dev/null)" >&2; rm -rf "$dir"; return 1; }
  done
  for ((i = 0; i < count; i++)); do cat "$dir/$i"; done >"$out"
  rm -rf "$dir"
  [[ $(wc -c <"$out" | tr -d ' ') == "$size" ]] || { echo "Download incomplete: wrong size." >&2; return 1; }
  awk -v t="$(($(now) - started))" -v b="$size" -v n="$count" \
    'BEGIN { printf "Downloaded %.0f MB in %d parts in %d s (%.1f MB/s).\n", b / 1048576, n, t, b / 1048576 / (t > 0 ? t : 1) }'
}

put() {
  local file url=$2 limit=$3 size count dir started reply access host round missing i
  file="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"  # split runs in its own folder
  started=$(now)
  size=$(wc -c <"$file" | tr -d ' ')
  single() {
    curl --fail --silent --show-error --retry 2 --retry-delay 5 "${RETRY_ALL[@]}" --speed-limit 10240 --speed-time 60 \
      --max-time "$limit" --request PUT --header 'Content-Type: application/gzip' --upload-file "$file" --output /dev/null "$url"
  }
  ((size >= LARGE)) || { single; return; }
  reply=$(curl --fail --silent --show-error --max-time 60 --retry 3 --retry-delay 3 "${RETRY_ALL[@]}" \
    --request PUT --header 'opc-multipart: true' --header 'Content-Type: application/gzip' "$url" 2>/dev/null) || reply=""
  access=$(printf '%s' "$reply" | sed -n 's/.*"accessUri" *: *"\([^"]*\)".*/\1/p')
  host=$(printf '%s' "$url" | sed -E 's#^(https?://[^/]+).*#\1#')
  [[ $access == /* ]] || { single; return; }
  access=${access%/}/
  count=$(((size + PART - 1) / PART))
  dir=$(mktemp -d "${TMPDIR:-/tmp}/cb-put.XXXXXX")
  (cd "$dir" && split -b "$PART" -a 4 "$file" part.) || { rm -rf "$dir"; return 1; }
  local parts=("$dir"/part.*)
  ((${#parts[@]} == count)) || { rm -rf "$dir"; echo "Upload: the archive could not be split." >&2; return 1; }
  part_put() {
    local i=$1
    curl "${PART_CURL[@]}" --max-time "$((limit < 300 ? limit : 300))" --request PUT --upload-file "${parts[$i]}" --output /dev/null "$host$access$((i + 1))" \
      2>>"$dir/errors" && touch "$dir/done.$i"
  }
  for round in 1 2 3; do
    missing=()
    for ((i = 0; i < count; i++)); do [[ -f $dir/done.$i ]] || missing+=("$i"); done
    ((${#missing[@]})) || break
    (($(now) - started < limit)) || break
    printf '%s\n' "${missing[@]}" | fan_out part_put
  done
  for ((i = 0; i < count; i++)); do
    if [[ ! -f $dir/done.$i ]]; then
      printf 'Upload incomplete: part %s of %s was not accepted. %s\n' "$((i + 1))" "$count" \
        "$(tail -n 1 "$dir/errors" 2>/dev/null)" >&2
      curl --silent --max-time 30 --request DELETE "$host$access" >/dev/null 2>&1 || true
      rm -rf "$dir"
      return 1
    fi
  done
  rm -rf "$dir"
  if ! curl --fail --silent --show-error --max-time 120 --retry 3 --retry-delay 3 --request POST \
      --output /dev/null "$host$access"; then
    curl --silent --max-time 30 --request DELETE "$host$access" >/dev/null 2>&1 || true
    echo "Upload: storage did not commit the parts." >&2
    return 1
  fi
  awk -v t="$(($(now) - started))" -v b="$size" -v n="$count" \
    'BEGIN { printf "Uploaded %.0f MB in %d parts in %d s (%.1f MB/s).\n", b / 1048576, n, t, b / 1048576 / (t > 0 ? t : 1) }'
}

case ${1:-} in
  get) [[ $# == 4 ]] || { echo "usage: transfer.sh get <url> <out> <seconds>" >&2; exit 2; }; get "$2" "$3" "$4" ;;
  put) [[ $# == 4 ]] || { echo "usage: transfer.sh put <file> <url> <seconds>" >&2; exit 2; }; put "$2" "$3" "$4" ;;
  *) echo "usage: transfer.sh get|put ..." >&2; exit 2 ;;
esac
