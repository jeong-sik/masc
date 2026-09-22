(* The Memory lane in summary mode: a run of journal rows folds to its newest,
   because three commits in a row each wrapped to about two lines and the lane
   took six lines of the pane to say where the memory ended up; and a failed
   Librarian pass is not a row at all, because the chat header names a run of
   them once for as long as it lasts. *)

open Alcotest
module Types = Masc_tui_types

let entry ?summary ?(pass = Masc_tui_message_layout.No_pass) ?(at = 0.) role text =
  { Types.me_role = role
  ; me_identity = Types.Session_row { request_id = ""; turn_phase = Types.Turn_output; operation_seq = 0 }
  ; me_turn_phase = Types.Turn_output
  ; me_turn_sequence = None
  ; me_operation_seq = 0
  ; me_text = text
  ; me_image = Masc_tui_image_preview.No_image
  ; me_memory_summary = summary
  ; me_journal = []
  ; me_memory_pass = pass
  ; me_gate = None
  ; me_submitted_at = None
  ; me_tool_block = None
  ; me_skill_block = []
  ; me_timestamp = ""
  ; me_keeper_name = "k"
  ; me_request_id = ""
  ; me_at = at
  }

let journal ?at n =
  entry ?at ~summary:(Printf.sprintf "memory rev %d" n)
    ~pass:Masc_tui_message_layout.Pass_committed Types.Message_memory
    (Printf.sprintf "Memory write \xc2\xb7 revision %d" n)

let failed ?at kind =
  entry ?at ~summary:("Librarian failed \xc2\xb7 " ^ kind)
    ~pass:(Masc_tui_message_layout.Pass_failed { kind }) Types.Message_memory
    ("Librarian failed \xc2\xb7 " ^ kind)

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
       (Types.project_memory_history ~visibility:Types.Memory_summary
          (rows [ said "before"; journal 26; journal 27; journal 28; said "after" ])))

let test_a_lone_row_is_left_alone () =
  check (list string) "one commit is not counted"
    [ "J:memory rev 28" ]
    (describe
       (Types.project_memory_history ~visibility:Types.Memory_summary
          (rows [ journal 28 ])))

let test_two_runs_fold_separately () =
  check (list string) "a row between them ends the run"
    [ "J:memory rev 27 · +1 earlier"; "K:said"; "J:memory rev 29 · +1 earlier" ]
    (describe
       (Types.project_memory_history ~visibility:Types.Memory_summary
          (rows [ journal 26; journal 27; said "said"; journal 28; journal 29 ])))

let test_full_mode_keeps_every_commit () =
  check (list string) "full mode is what shows every commit"
    [ "J:memory rev 26"; "J:memory rev 27"; "J:memory rev 28" ]
    (describe
       (Types.project_memory_history ~visibility:Types.Memory_full
          (rows [ journal 26; journal 27; journal 28 ])))

let test_a_run_at_the_end_folds () =
  check (list string) "a run with nothing after it still folds"
    [ "K:said"; "J:memory rev 28 · +1 earlier" ]
    (describe
       (Types.project_memory_history ~visibility:Types.Memory_summary
          (rows [ said "said"; journal 27; journal 28 ])))

let test_summary_mode_draws_no_failed_pass () =
  check (list string) "the failures between turns are gone, the commits fold"
    [ "K:before"; "J:memory rev 27 \xc2\xb7 +1 earlier"; "K:after" ]
    (describe
       (Types.project_memory_history ~visibility:Types.Memory_summary
          (rows
             [ said "before"; journal 26; failed "exact_execution_failure"; journal 27
             ; failed "exact_execution_failure"; said "after" ])));
  check (list string) "full mode keeps every pass, the failed ones too"
    [ "J:memory rev 26"; "J:Librarian failed \xc2\xb7 timeout"; "J:memory rev 27" ]
    (describe
       (Types.project_memory_history ~visibility:Types.Memory_full
          (rows [ journal 26; failed "timeout"; journal 27 ])))

let entries_of rows = List.map fst rows

let test_a_failing_run_is_counted_up_to_the_newest_pass () =
  let failing entries =
    Option.map
      (fun (run : Types.librarian_failing) -> (run.lf_kind, run.lf_count, run.lf_since))
      (Types.librarian_failing entries)
  in
  let outcome = option (triple string int (float 0.)) in
  check outcome "failures after the last commit are one run, named by the newest"
    (Some ("timeout", 3, 20.))
    (failing
       (entries_of
          (rows
             [ journal ~at:10. 26; failed ~at:20. "exact_execution_failure"
             ; said "between"; failed ~at:30. "exact_execution_failure"
             ; failed ~at:40. "timeout" ])));
  check outcome "a commit after the failures ends the run" None
    (failing (entries_of (rows [ failed ~at:20. "timeout"; journal ~at:30. 27 ])));
  check outcome "nothing on record is no run" None
    (failing (entries_of (rows [ said "hello" ])));
  (* A producer backfill appends an older row after newer ones; the run is
     read in the order the passes happened. *)
  check outcome "a backfilled older commit does not end a newer run"
    (Some ("timeout", 1, 30.))
    (failing (entries_of (rows [ failed ~at:30. "timeout"; journal ~at:10. 26 ])))

let test_the_header_item_leads_with_the_run () =
  check string "run, since, then how"
    "Librarian failing \xc3\x973 since 14:02:13 \xc2\xb7 exact_execution_failure"
    (Types.librarian_failing_text ~since:"14:02:13"
       { Types.lf_kind = "exact_execution_failure"; lf_count = 3; lf_since = 0. })

let () =
  run "Masc_tui_memory_fold"
    [ ( "summary fold"
      , [ test_case "a run folds to its newest" `Quick test_a_run_folds_to_its_newest
        ; test_case "a lone row is left alone" `Quick test_a_lone_row_is_left_alone
        ; test_case "two runs fold separately" `Quick test_two_runs_fold_separately
        ; test_case "a run at the end folds" `Quick test_a_run_at_the_end_folds
        ; test_case "full mode keeps every commit" `Quick test_full_mode_keeps_every_commit
        ; test_case "summary mode draws no failed pass" `Quick
            test_summary_mode_draws_no_failed_pass
        ] )
    ; ( "librarian failing"
      , [ test_case "a failing run is counted up to the newest pass" `Quick
            test_a_failing_run_is_counted_up_to_the_newest_pass
        ; test_case "the header item leads with the run" `Quick
            test_the_header_item_leads_with_the_run
        ] )
    ]
