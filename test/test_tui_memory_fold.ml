(* A run of journal rows folds to its newest in summary mode. Three commits in
   a row each wrapped to about two lines, so the lane took six lines of the
   pane to say where the memory ended up. *)

open Alcotest
module Types = Masc_tui_types

let entry ?summary role text =
  { Types.me_role = role
  ; me_identity = Types.Session_row { request_id = ""; turn_phase = Types.Turn_output; operation_seq = 0 }
  ; me_turn_phase = Types.Turn_output
  ; me_turn_sequence = None
  ; me_operation_seq = 0
  ; me_text = text
  ; me_memory_summary = summary
  ; me_submitted_at = None
  ; me_tool_block = None
  ; me_skill_activity = None
  ; me_timestamp = ""
  ; me_keeper_name = "k"
  ; me_request_id = ""
  ; me_at = 0.
  }

let journal n =
  entry ~summary:(Printf.sprintf "memory rev %d" n) Types.Message_memory
    (Printf.sprintf "Memory write committed current memory revision %d" n)

let said text = entry Types.Message_keeper text

let describe rows =
  List.map
    (fun (e, _) ->
      match e.Types.me_role with
      | Types.Message_memory -> "J:" ^ Option.value e.Types.me_memory_summary ~default:e.Types.me_text
      | _ -> "K:" ^ e.Types.me_text)
    rows

let rows entries = List.map (fun e -> (e, ())) entries

let test_a_run_folds_to_its_newest () =
  check (list string) "three commits become the newest, counted"
    [ "K:before"; "J:memory rev 28 · +2 earlier"; "K:after" ]
    (describe
       (Types.fold_memory_summary_runs ~visibility:Types.Memory_summary
          (rows [ said "before"; journal 26; journal 27; journal 28; said "after" ])))

let test_a_lone_row_is_left_alone () =
  check (list string) "one commit is not counted"
    [ "J:memory rev 28" ]
    (describe
       (Types.fold_memory_summary_runs ~visibility:Types.Memory_summary
          (rows [ journal 28 ])))

let test_two_runs_fold_separately () =
  check (list string) "a row between them ends the run"
    [ "J:memory rev 27 · +1 earlier"; "K:said"; "J:memory rev 29 · +1 earlier" ]
    (describe
       (Types.fold_memory_summary_runs ~visibility:Types.Memory_summary
          (rows [ journal 26; journal 27; said "said"; journal 28; journal 29 ])))

let test_full_mode_keeps_every_commit () =
  check (list string) "full mode is what shows every commit"
    [ "J:memory rev 26"; "J:memory rev 27"; "J:memory rev 28" ]
    (describe
       (Types.fold_memory_summary_runs ~visibility:Types.Memory_full
          (rows [ journal 26; journal 27; journal 28 ])))

let test_a_run_at_the_end_folds () =
  check (list string) "a run with nothing after it still folds"
    [ "K:said"; "J:memory rev 28 · +1 earlier" ]
    (describe
       (Types.fold_memory_summary_runs ~visibility:Types.Memory_summary
          (rows [ said "said"; journal 27; journal 28 ])))

let () =
  run "Masc_tui_memory_fold"
    [ ( "summary fold"
      , [ test_case "a run folds to its newest" `Quick test_a_run_folds_to_its_newest
        ; test_case "a lone row is left alone" `Quick test_a_lone_row_is_left_alone
        ; test_case "two runs fold separately" `Quick test_two_runs_fold_separately
        ; test_case "a run at the end folds" `Quick test_a_run_at_the_end_folds
        ; test_case "full mode keeps every commit" `Quick test_full_mode_keeps_every_commit
        ] )
    ]
