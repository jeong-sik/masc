#!/usr/bin/env bash
# Builds the read mode html probe from masc's own sources: the document script
# an ego connection sends at step page.document (lib/browser_ego_peer.ml).
# Usage: build.sh <masc checkout> <output dir>
set -euo pipefail
root=$(cd "$1" && pwd)
mkdir -p "$2/site"
out=$(cd "$2" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
# browser_page_script.ml needs Browser_lane; the document read uses only its parsed line.
{ echo "module Browser_page_script = struct"
  sed -n '/^let parsed body = /p' "$root/lib/browser_page_script.ml"
  echo "end;;"; } > "$out/page_script_parsed.ml"
# answer_limit_units is lib/browser_bidi_peer.ml reply_limit_bytes / 4, which
# lib/browser_ego_peer.ml uses; page_function and the step body are copied from
# lib/browser_ego_peer.ml page_function and read.
cat > "$out/gen.ml" <<EOF
#mod_use "$root/lib/browser_scene_script.ml";;
#use "$out/page_script_parsed.ml";;
#mod_use "$root/lib/browser_lane/browser_document.ml";;
let answer_limit_units = 8 * 1024 * 1024 / 4
let body = Browser_page_script.parsed (Browser_document.runtime ^ "\nreturn browserDocument();")
let fn = Browser_scene_script.page_function ~answer_limit_units ("arguments[0]=JSON.parse(arguments[0]);\n" ^ body)
let () = let oc = open_out_bin "$out/fn.js" in output_string oc fn; close_out oc
EOF
ocaml "$out/gen.ml"
cp "$here/../probe-page.html" "$out/site/index.html"
python3 - "$out" "$here/probe.template.mjs" <<'PY'
import json, sys
out, template = sys.argv[1], sys.argv[2]
fn = open(f"{out}/fn.js", encoding="utf-8").read()
probe = open(template, encoding="utf-8").read().replace("__FN__", json.dumps(fn))
open(f"{out}/probe.mjs", "w", encoding="utf-8").write(probe)
# Rows with quotes, backslashes and Korean, so the JSON answer is larger than the file.
row = '<p data-q="a&quot;b" title="c\\d">한글 "quoted" back\\slash</p>\n'
for name, count in (("near.html", 9000), ("big.html", 16000)):
    with open(f"{out}/site/{name}", "w", encoding="utf-8") as page:
        page.write('<!doctype html><meta charset="utf-8"><title>' + name + "</title>\n" + row * count)
PY
