open Alcotest
module Mark = Masc_tui_memory_mark
module Types = Masc_tui_types

(* The ST column on the Memory roster. Five of the six mark modules had a
   suite named after them and this one did not, so scripts/ci/run-edited-tests
   selected nothing for an edit here: a changed glyph or a dropped legend row
   reached main with no scenario run. The sheet case in test_tui_keys reads
   this module, but it is selected by an edit to the key table, not by an edit
   to the marks. *)

let states =
  [ Types.Memory_ordinary
  ; Types.Memory_warning
  ; Types.Memory_degraded
  ; Types.Memory_no_current
  ; Types.Memory_source_only
  ; Types.Memory_starving
  ; Types.Memory_read_error
  ]

let state_name = function
  | Types.Memory_ordinary -> "ordinary"
  | Types.Memory_warning -> "warning"
  | Types.Memory_degraded -> "degraded"
  | Types.Memory_no_current -> "no_current"
  | Types.Memory_source_only -> "source_only"
  | Types.Memory_starving -> "starving"
  | Types.Memory_read_error -> "read_error"

(* The groupings the module's own comment states. Two states share the
   attention mark and two share the failure mark; the rest stand alone. A
   state moved between groups is a different column, so it is pinned here
   rather than left to the legend's shape. *)
let test_each_state_draws_its_stated_mark () =
  let expect state mark =
    check string (state_name state) mark (Mark.glyph state)
  in
  expect Types.Memory_ordinary "+";
  expect Types.Memory_warning "!";
  expect Types.Memory_degraded "!";
  expect Types.Memory_no_current "-";
  expect Types.Memory_source_only "s";
  expect Types.Memory_starving "x";
  expect Types.Memory_read_error "x"

(* The ST column is one cell wide, so a mark wider than one cell pushes the
   whole roster's columns right. Every mark here is ASCII, which is the
   narrower claim the column can rely on. *)
let test_every_mark_is_one_cell () =
  List.iter
    (fun state ->
      let mark = Mark.glyph state in
      check int
        (Printf.sprintf "the %s mark is one cell" (state_name state))
        1 (String.length mark))
    states

(* One row per mark, not per state -- the module says so, and a sheet that
   listed them per state would print the same glyph twice with two words
   beside it. *)
let test_the_legend_has_one_row_per_mark () =
  let drawn = List.sort_uniq String.compare (List.map Mark.glyph states) in
  check int "one legend row per distinct mark"
    (List.length drawn) (List.length Mark.legend);
  List.iter
    (fun mark ->
      check bool ("the legend names " ^ mark) true
        (List.exists (fun (m, _) -> String.equal m mark) Mark.legend))
    drawn;
  List.iter
    (fun (mark, _) ->
      check bool ("the column can draw " ^ mark) true (List.mem mark drawn))
    Mark.legend

(* A blank word leaves a mark on the sheet with nothing beside it, and two
   marks sharing a word says the column tells apart two readings that read the
   same. *)
let test_every_mark_has_its_own_word () =
  List.iter
    (fun (mark, word) ->
      check bool (Printf.sprintf "the mark %S has a word" mark) true
        (String.length (String.trim word) > 0))
    Mark.legend;
  let words = List.map snd Mark.legend in
  check int "no two marks are given the same word"
    (List.length words)
    (List.length (List.sort_uniq String.compare words))

let () =
  run "tui memory mark"
    [ ( "the ST column"
      , [ test_case "each state draws its stated mark" `Quick
            test_each_state_draws_its_stated_mark
        ; test_case "every mark is one cell" `Quick
            test_every_mark_is_one_cell
        ; test_case "the legend has one row per mark" `Quick
            test_the_legend_has_one_row_per_mark
        ; test_case "every mark has its own word" `Quick
            test_every_mark_has_its_own_word
        ] )
    ]
