#!/bin/sh
# Standalone component execution: real codec/receipt sources and interfaces,
# with library-name aliases only. This does not type-check the host integration.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
cp "$repo_dir/lib/browser_lane/browser_native_workflow.ml" "$repo_dir/lib/browser_lane/browser_native_workflow.mli" "$check_dir/"
cp "$repo_dir/lib/browser_ego_workflow.ml" "$repo_dir/lib/browser_ego_workflow.mli" "$check_dir/"
cp "$repo_dir/test/test_browser_native_workflow.ml" "$check_dir/"
printf '%s\n' 'module Native_workflow = Browser_native_workflow' > "$check_dir/browser_lane.ml"
printf '%s\n' 'module Browser_ego_workflow = Browser_ego_workflow' > "$check_dir/masc.ml"
cd "$check_dir"
ocamlfind ocamlc -w +4+32+69 -warn-error +a -package yojson,uri,alcotest -linkpkg \
  browser_native_workflow.mli browser_native_workflow.ml browser_lane.ml \
  browser_ego_workflow.mli browser_ego_workflow.ml masc.ml test_browser_native_workflow.ml -o check
./check "$@"
