#!/bin/sh
set -eu

# Make a fresh output directory; never overwrite the retained captures.
test "$#" -eq 1 || { echo 'usage: reproduce.sh NEW_OUTPUT_DIRECTORY' >&2; exit 2; }
root=$(git rev-parse --show-toplevel)
out=$1
case "$out" in /*) ;; *) out="$root/$out" ;; esac
test ! -e "$out" || { echo 'output directory already exists' >&2; exit 2; }
mkdir -p "$out" "$out/failure" "$out/tests"
record="$root/docs/evidence/tui-composer-state-20261030"
base=0b18418111a533b3dc10c33b8811b1d058f136fe
candidate=62c30fbc32c79578b42ac1bf5945e1d9ee9f49a0

git -C "$root" show "$base:bin/masc_tui_message_input.ml" > "$out/baseline_input.ml"
git -C "$root" show "$candidate:bin/masc_tui_message_input.ml" > "$out/candidate_input.ml"
for path in lib/string_util/string_util.mli lib/string_util/string_util.ml \
  bin/masc_tui_frame.mli bin/masc_tui_frame.ml bin/masc_tui_grapheme_segmentation.ml \
  bin/masc_tui_message_layout.mli bin/masc_tui_message_layout.ml; do
  git -C "$root" show "$base:$path" > "$out/$(basename "$path")"
done
for name in equivalence bench voice_final_bench voice_consumer; do
  cp "$record/$name.ml.txt" "$out/$name.ml"
done

cd "$out"
sources='string_util.mli string_util.ml masc_tui_frame.mli masc_tui_frame.ml masc_tui_grapheme_segmentation.ml masc_tui_message_layout.mli masc_tui_message_layout.ml baseline_input.ml candidate_input.ml'
for name in equivalence bench voice_final_bench voice_consumer; do
  # The source list contains only fixed repository filenames, not user input.
  # shellcheck disable=SC2086
  ocamlfind ocamlopt -package uuseg,uucp,unix -linkpkg $sources "$name.ml" -o "$name"
done
./equivalence > equivalence.txt
./voice_consumer > voice_consumer.txt
./bench > bench.csv
./voice_final_bench > voice.csv

cp baseline_input.ml candidate_input.ml failure/
cp "$record/failure.ml.txt" failure/failure.ml
cp "$record/failure_layout.ml.txt" failure/masc_tui_message_layout.ml
(
  cd failure
  ocamlopt masc_tui_message_layout.ml baseline_input.ml candidate_input.ml failure.ml -o failure
  ./failure > failure.txt
)

cp string_util.mli string_util.ml masc_tui_frame.mli masc_tui_frame.ml \
  masc_tui_grapheme_segmentation.ml masc_tui_message_layout.mli \
  masc_tui_message_layout.ml tests/
git -C "$root" show "$candidate:bin/masc_tui_message_input.mli" > tests/masc_tui_message_input.mli
git -C "$root" show "$candidate:bin/masc_tui_message_input.ml" > tests/masc_tui_message_input.ml
git -C "$root" show "$candidate:test/test_tui_message_input.ml" > tests/test_tui_message_input.ml
(
  cd tests
  ocamlfind ocamlopt -package uuseg,uucp,alcotest -linkpkg \
    string_util.mli string_util.ml masc_tui_frame.mli masc_tui_frame.ml \
    masc_tui_grapheme_segmentation.ml masc_tui_message_layout.mli \
    masc_tui_message_layout.ml masc_tui_message_input.mli \
    masc_tui_message_input.ml test_tui_message_input.ml -o input_tests
  ./input_tests --compact > input_tests.txt
)
printf 'Fresh results: %s\n' "$out"
