(** One mark for "no value".

    The Keepers roster row and the keeper detail pane both draw
    [k_current_task_id]. A keeper with no task read an em dash in the row and
    a hyphen in the pane one keypress later, so the same nothing carried two
    marks. Thirty-odd draws across the surfaces were split the same way.

    Both halves are wiring in the masc_tui executable, which nothing links
    (task-550), so they are read off the source the way the other TUI wiring
    suites read theirs. *)

let mark = Masc_tui_theme.Glyph.no_value
let hyphen = "-"
let theme = "bin/masc_tui_theme.ml"

let source_root =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists root -> root
  | _ -> Sys.getcwd ()
;;

(* Read the directory rather than list the files: a module added to the
   drawing is in scope the day it lands, and a count that names its files by
   hand answers by growing a list instead of by changing. *)
let drawing_modules =
  let prefix = "masc_tui_" in
  Sys.readdir (Filename.concat source_root "bin")
  |> Array.to_list
  |> List.filter (fun name ->
         String.starts_with ~prefix name && Filename.check_suffix name ".ml")
  |> List.sort String.compare
  |> List.map (fun name -> Filename.concat "bin" name)
;;

let test_the_drawing_is_read () =
  Alcotest.(check bool) "the scan found the surfaces" true
    (List.length drawing_modules > 20);
  Alcotest.(check bool) "including the one that holds the mark" true
    (List.mem theme drawing_modules)
;;

let test_the_mark_is_spelled_in_one_place () =
  let spellers =
    List.filter
      (fun module_path ->
        Ast_grep.count_exact_string_literals ~module_path ~needle:mark > 0)
      drawing_modules
  in
  Alcotest.(check (list string)) "only the glyph token holds it" [ theme ] spellers;
  Alcotest.(check int) "and holds it once" 1
    (Ast_grep.count_exact_string_literals ~module_path:theme ~needle:mark)
;;

(* What a remaining hyphen is allowed to be. Each entry is a binding that
   draws a removed diff line, where the mark is the diff's own and not an
   absent value. The count is taken from the binding, so a marker moved
   within one still matches and a hyphen grown anywhere else does not. *)
let diff_marker_bindings =
  [ "bin/masc_tui_render.ml", [ "diff_row_span"; "render_code" ]
  ; "bin/masc_tui_render_prim.ml", [ "tree_diff_row_span" ]
  ; "bin/masc_tui_keeper_chat_diff.ml", [ "diff_line" ]
  ]
;;

(* The surfaces whose cells are measured in display width. The modules left
   out draw a one-cell alphabet or pad by bytes, and Masc_tui_theme says why
   they keep a one-byte mark. *)
let width_measured_modules =
  [ "bin/masc_tui_render.ml"
  ; "bin/masc_tui_render_prim.ml"
  ; "bin/masc_tui_render_memory.ml"
  ; "bin/masc_tui_render_schedule.ml"
  ; "bin/masc_tui_acting.ml"
  ; "bin/masc_tui_lane_table.ml"
  ; "bin/masc_tui_keeper_chat_diff.ml"
  ]
;;

let allowed_hyphens module_path =
  match List.assoc_opt module_path diff_marker_bindings with
  | None -> 0
  | Some bindings ->
      List.fold_left
        (fun total binding_name ->
          total
          + Ast_grep.count_exact_string_literals_in_value_binding ~module_path
              ~binding_name ~needle:hyphen)
        0 bindings
;;

let test_a_hyphen_left_in_the_drawing_is_a_diff_marker () =
  List.iter
    (fun module_path ->
      Alcotest.(check int)
        (module_path ^ ": every hyphen it spells is a removed diff line")
        (allowed_hyphens module_path)
        (Ast_grep.count_exact_string_literals ~module_path ~needle:hyphen))
    width_measured_modules
;;

(* Where the mark lands, the cell has to be measured in display columns.
   Printf's "%*s" counts bytes, so the TURN cell of the Keepers roster drew
   the three-byte mark in four columns of a six-column field and pulled the
   runtime column after it two cells left. {!Masc_tui_message_layout.pad_left}
   is the right-aligning pad; nothing in the drawing counts bytes. *)
let test_no_width_measured_surface_pads_by_bytes () =
  List.iter
    (fun module_path ->
      Alcotest.(check int)
        (module_path ^ ": no byte-counted field width")
        0
        (Ast_grep.count_string_literals ~module_path ~needle:"%*s"))
    width_measured_modules
;;

let test_the_mark_is_the_em_dash () =
  Alcotest.(check string) "one column wide, and not a hyphen" "\xe2\x80\x94" mark
;;

let () =
  Alcotest.run "tui_no_value_mark"
    [ ( "no value mark"
      , [ Alcotest.test_case "the drawing is read" `Quick test_the_drawing_is_read
        ; Alcotest.test_case "the mark is spelled in one place" `Quick
            test_the_mark_is_spelled_in_one_place
        ; Alcotest.test_case "a hyphen left in the drawing is a diff marker" `Quick
            test_a_hyphen_left_in_the_drawing_is_a_diff_marker
        ; Alcotest.test_case "no width-measured surface pads by bytes" `Quick
            test_no_width_measured_surface_pads_by_bytes
        ; Alcotest.test_case "the mark is the em dash" `Quick test_the_mark_is_the_em_dash
        ] )
    ]
;;
