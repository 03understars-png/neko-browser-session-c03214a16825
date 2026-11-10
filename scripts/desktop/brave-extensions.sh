#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
awk "/compute-base-extensions.list <<'X'/{f=1;next} /^X\$/{f=0} f" "$here/10-compute-base.sh" >"$work/list"
awk "/compute-base-extensions <<'EXT'/{f=1;next} /^EXT\$/{f=0} f" "$here/10-compute-base.sh" >"$work/make"
bash "$work/make" "$1" "$2" "$3" "$work/list"
