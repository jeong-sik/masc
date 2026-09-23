(** One spelling for how long something took.

    The Standalone lanes table drew its P50 as raw seconds. A seven-minute
    reading was "415.9s" in the table while the detail block under it, in the
    same frame, said "2m11s" -- and an hour-long run would have read
    "3723.0s". Five draws spelled a duration this way, each with its own
    Printf and no ladder at all.

    The spelling is {!Masc_tui_message_layout.elapsed_text} now. This suite
    reads the drawing off the source, because the draws are wiring in the
    masc_tui executable, which nothing links (task-550). *)

let tenths_of_a_second = "%.1fs"
let layout = "bin/masc_tui_message_layout.ml"

let source_root =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists root -> root
  | _ -> Sys.getcwd ()
;;

(* Read the directory rather than list the files: a module added to the
   drawing is in scope the day it lands. *)
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
  Alcotest.(check bool) "including the one that holds the ladder" true
    (List.mem layout drawing_modules)
;;

let test_the_tenths_are_spelled_in_one_place () =
  let spellers =
    List.filter
      (fun module_path ->
        Ast_grep.count_exact_string_literals ~module_path ~needle:tenths_of_a_second
        > 0)
      drawing_modules
  in
  Alcotest.(check (list string)) "only the ladder holds it" [ layout ] spellers;
  Alcotest.(check int) "and holds it once" 1
    (Ast_grep.count_exact_string_literals ~module_path:layout
       ~needle:tenths_of_a_second)
;;

(* The ladder's own rung, so the guard above is measuring the thing the
   surfaces read rather than a literal that happens to match. *)
let test_the_ladder_draws_the_tenths () =
  Alcotest.(check string) "under a minute" "16.2s"
    (Masc_tui_message_layout.elapsed_text 16.23)
;;

let () =
  Alcotest.run "tui_duration_spelling"
    [ ( "duration spelling"
      , [ Alcotest.test_case "the drawing is read" `Quick test_the_drawing_is_read
        ; Alcotest.test_case "the tenths are spelled in one place" `Quick
            test_the_tenths_are_spelled_in_one_place
        ; Alcotest.test_case "the ladder draws the tenths" `Quick
            test_the_ladder_draws_the_tenths
        ] )
    ]
;;
