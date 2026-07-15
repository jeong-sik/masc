#!/bin/sh
set -eu

[ "$#" -eq 1 ] || { echo "usage: $0 OUTPUT.html" >&2; exit 64; }

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
source_file="$repo_root/docs/rfc/RFC-0000-MASTER-ROADMAP.md"
style_file="$repo_root/docs/rfc/RFC-0000-MASTER-ROADMAP.css"
output_file=$1

mkdir -p -- "$(dirname -- "$output_file")"
pandoc --from=gfm --to=html5 --standalone --section-divs \
  --toc --toc-depth=3 --embed-resources --css="$style_file" \
  --output="$output_file" "$source_file"
