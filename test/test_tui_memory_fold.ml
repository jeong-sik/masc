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
  ; me_media = []
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
  ; me_execution_source = None
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

let rows entries = List.map (fun e -> (e, ())) entries

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

let () =
  run "Masc_tui_memory_fold"
    [ ( "summary fold"
      , [] )
    ; ( "librarian failing"
      , [ test_case "a failing run is counted up to the newest pass" `Quick
            test_a_failing_run_is_counted_up_to_the_newest_pass
        ;] )
    ]
