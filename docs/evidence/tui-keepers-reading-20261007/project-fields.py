"""Project the actual Keeper field/header helpers without building the app.

Run from any directory with the repository's OCaml interpreter and uuseg.string
installed. The result is source-level layout evidence, not a TUI screen capture.
The isolated Ansi module supplies only the reset byte used by field_rows.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import textwrap


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
render = (ROOT / "bin/masc_tui_render.ml").read_text()
schedule = (ROOT / "bin/masc_tui_render_schedule.ml").read_text()
theme = (ROOT / "bin/masc_tui_theme.ml").read_text()


def between(text, first, last):
    start = text.index(first)
    return text[start:text.index(last, start)]


field = textwrap.dedent(between(render, "    let field_rows", "\n    in\n\n    (* Each tab"))
header = between(render, "let keeper_column_header", "\n(* Each cell")
columns = between(schedule, "let keeper_marker_width", "\nmodule Table")
strip = between(theme, "let strip_sgr", "\nmodule Glyph")
source = f'''
#use "topfind";;
#require "uuseg.string,yojson";;
#mod_use {json.dumps(str(ROOT / "bin/masc_tui_message_layout.ml"))};;
module Message_layout = Masc_tui_message_layout;;
module Render_schedule = struct
{columns}
end;;
module Ansi = struct let reset = "\\027[0m" end;;
let fit_width = Message_layout.fit_width;;
{strip};;
{field};;
{header};;
let fields =
  [ "Name:", "you-never-change"
  ; "Lifecycle:", "failing (last turn failed)"
  ; "Turn:", "executing"
  ; "Idle:", "59m"
  ; "Last outcome:", "done · model-with-a-long-name-and-a-distinguishing-END"
  ; "Runtime Target:", "workspace runtime · profile-END"
  ; "Effects (Gate mode):", "workspace · allow-all"
  ; "Current Task:", "한글 작업 내용을 끝까지 확인합니다 END"
  ];;
let compact text =
  String.split_on_char ' ' text |> String.concat "";;
let checked_rows width (label, value) =
  let rows = field_rows ~width ~label_cells:18 ~label_style:"\\027[2m" label value in
  let plain = List.map strip_sgr rows in
  assert (List.for_all (fun row -> Message_layout.display_width row <= width) rows);
  assert (compact (String.concat "" plain) = compact (label ^ value));
  plain;;
let result = List.map (fun width ->
  let columns = Render_schedule.allocate_keeper_columns ~inner_width:width ~widest_runtime:49 in
  let heading = keeper_column_header columns in
  if width >= 76 then assert (Message_layout.display_width heading <= width);
  `Assoc [ "cells", `Int width;
           "header", `String heading;
           "fields", `List (List.map (fun field ->
             `List (List.map (fun row -> `String row) (checked_rows width field))) fields) ])
  [40; 76; 116];;
print_endline (Yojson.Safe.pretty_to_string (`List result));;
'''
with tempfile.TemporaryDirectory(prefix="masc-keeper-fields-") as temporary:
    script = Path(temporary) / "fields.ml"
    script.write_text(source)
    result = subprocess.run(["ocaml", "-noinit", str(script)], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(result.stderr + result.stdout)
    # topfind reports loaded packages before the JSON on some installations.
    start = result.stdout.index("[\n")
    projection = json.loads(result.stdout[start:])
    (HERE / "fields.json").write_text(json.dumps(projection, ensure_ascii=False, indent=2) + "\n")
    print("PASS: 24 field projections preserve complete labels/values at 40/76/116 cells")
    print("Source helpers only; no application build, renderer execution or PTY capture.")
