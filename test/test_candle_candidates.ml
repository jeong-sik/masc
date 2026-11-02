let () = Candle_status.install_appraiser_check (fun () -> Ok ())

(** The first half of a payout (RFC-goal-candle-ledger 3.2, 3.4): from a waiting
    [PayoutOwed] to [Candidates], and to [Unattributed] when nobody can be paid.
    The Tasks and the Keepers come from injected sources; the ledger is the real
    file. *)

open Alcotest

module E = Candle_event

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> failf "%s" detail
;;

let at text = ok_or_fail (Candle_time.of_rfc3339 text)
let clock = 1_790_000_000.

(* {1 Fixtures} *)

let temp_dir () =
  let path = Filename.temp_file "candle_candidates_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let with_base_path f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf base_path) (fun () -> f base_path)
;;

let enable base_path =
  let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path in
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc {|half_life = "off"
[payout]
weight_max = 10
deduction_rate = 10
deduction_floor = 200
share_rounding = "largest_remainder"
remainder_tie_break = "name_ascending"
deduction_rounding = "down"
[payout.grade_criteria]
trivial = "Minor adjustment"
small = "Bounded change"
medium = "Connected feature"
large = "Cross-feature work"
epic = "System outcome"
[payout.grades_milli]
trivial = 1000
small = 2000
medium = 3000
large = 4000
epic = 5000
|})
;;

let snapshot ?(goal_id = "goal-1") ?(request_id = "req-1") ?(verification_run_id = "run-1") linked_task_ids : E.t =
  { at = at "2026-09-28T06:32:01Z"
  ; body =
      E.Snapshot
        { goal_id
        ; request_id
        ; verification_run_id
        ; criterion_revision = "rev-1"
        ; passed_at = at "2026-09-28T06:32:00Z"
        ; goal_created_at = at "2026-09-20T01:00:00Z"
        ; due_date = None
        ; title = "Ship the ledger"
        ; metric = None
        ; target_value = None
        ; linked_task_ids
        }
  }
;;

let owed ?(goal_id = "goal-1") ?(request_id = "req-1") ?(verification_run_id = "run-1") () : E.t =
  { at = at "2026-09-29T05:00:01Z"
  ; body =
      E.Payout_owed
        { goal_id
        ; request_id
        ; verification_run_id
        ; passed_at = at "2026-09-28T06:32:00Z"
        ; confirmed_at = at "2026-09-29T05:00:00Z"
        }
  }
;;

let seed base_path events =
  match Candle_ledger.update ~base_path (fun _ -> Ok (events, ())) with
  | Ok () -> ()
  | Error error -> failf "%s" (Candle_ledger.update_error_to_string Fun.id error)
;;

let events base_path =
  match Candle_ledger.read ~base_path with
  | Ok view -> Candle_ledger.events view
  | Error error -> failf "%s" (Candle_ledger.read_error_to_string error)
;;

let kinds base_path =
  List.map (fun (event : E.t) -> E.kind event.body) (events base_path)
;;

let done_by assignee =
  E.Found
    { title = "A Task"
    ; assignee = Some assignee
    ; status = E.Done { completed_at = at "2026-09-25T00:00:00Z" }
    }
;;

let sources
  ?(lookups = fun ~goal_id:_ task_ids -> Ok (List.map (fun id -> id, done_by "keeper-a") task_ids))
  ?(keepers = fun () -> Ok (fun name -> String.equal name "keeper-a"))
  ()
  : Candle_candidates.sources
  =
  { task_lookups = lookups; is_keeper = keepers }
;;

let drain ?(sources = sources ()) base_path =
  let config = Workspace_utils_backend_setup.default_config base_path in
  Candle_candidates.drain_with ~sources ~now:(fun () -> clock) ~config
;;

let outcome_testable =
  Alcotest.testable
    (fun ppf (outcome : Candle_candidates.outcome) ->
       match outcome with
       | Candle_candidates.Wrote_candidates { goal_id } -> Format.fprintf ppf "Wrote_candidates %s" goal_id
       | Candle_candidates.Wrote_unattributed { goal_id } ->
         Format.fprintf ppf "Wrote_unattributed %s" goal_id
       | Candle_candidates.Already_prepared { goal_id } ->
         Format.fprintf ppf "Already_prepared %s" goal_id
       | Candle_candidates.Superseded { goal_id } -> Format.fprintf ppf "Superseded %s" goal_id
       | Candle_candidates.Held_window {goal_id; issues; recorded} ->
         Format.fprintf ppf "Held_window %s (%d issues, recorded=%b)" goal_id (List.length issues) recorded
       | Candle_candidates.Waiting_task {goal_id; issues} ->
         Format.fprintf ppf "Waiting_task %s (%d issues)" goal_id (List.length issues)
       | Candle_candidates.Retry_later { goal_id; detail } ->
         Format.fprintf ppf "Retry_later %s (%s)" goal_id detail)
    ( = )
;;

let drained ?sources base_path = ok_or_fail (drain ?sources base_path)

(* {1 Tests} *)

let test_off_and_disabled_do_nothing () =
  with_base_path
  @@ fun base_path ->
  seed base_path [ snapshot [ "task-1" ]; owed () ];
  check (list outcome_testable) "no candle.toml" [] (drained base_path);
  let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path in
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc "surprise = true\n");
  check (list outcome_testable) "a candle.toml that does not read" [] (drained base_path);
  check (list string) "nothing was added" [ "snapshot"; "payout_owed" ] (kinds base_path)
;;

let test_a_waiting_payout_gets_its_candidates () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot [ "task-1"; "task-2" ]; owed () ];
  check
    (list outcome_testable)
    "candidates written"
    [ Candle_candidates.Wrote_candidates { goal_id = "goal-1" } ]
    (drained base_path);
  check (list string) "one Candidates row" [ "snapshot"; "payout_owed"; "candidates" ] (kinds base_path);
  match List.rev (events base_path) with
  | { E.at = written_at; body = E.Candidates_fenced c } :: _ ->
    check string "request" "req-1" c.request_id;
    check (list string) "the Tasks read, in the Snapshot's order" [ "task-1"; "task-2" ] (List.map fst c.tasks);
    check (list string) "candidate Tasks" [ "task-1"; "task-2" ] c.candidate_task_ids;
    check (list string) "candidate keepers" [ "keeper-a" ] c.candidate_keepers;
    check bool "stamped with the clock" true
      (Candle_time.equal written_at (Candle_time.of_ptime (Option.get (Ptime.of_float_s clock))))
  | _ -> fail "expected Candidates last"
;;

let test_the_next_pass_writes_nothing_more () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot [ "task-1" ]; owed () ];
  ignore (drained base_path : Candle_candidates.outcome list);
  check
    (list outcome_testable)
    "already prepared"
    [ Candle_candidates.Already_prepared { goal_id = "goal-1" } ]
    (drained base_path);
  check (list string) "still one Candidates row" [ "snapshot"; "payout_owed"; "candidates" ] (kinds base_path)
;;

let test_no_keeper_to_pay_closes_the_payout_without_asking_anyone () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot [ "task-1" ]; owed () ];
  let people_only =
    sources ~lookups:(fun ~goal_id:_ task_ids -> Ok (List.map (fun id -> id, done_by "a-human") task_ids)) ()
  in
  check
    (list outcome_testable)
    "closed"
    [ Candle_candidates.Wrote_unattributed { goal_id = "goal-1" } ]
    (drained ~sources:people_only base_path);
  check
    (list string)
    "Candidates, then Unattributed"
    [ "snapshot"; "payout_owed"; "candidates"; "unattributed" ]
    (kinds base_path);
  check (list outcome_testable) "nothing waits any more" [] (drained base_path)
;;

let test_a_goal_that_linked_no_task_is_closed () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot []; owed () ];
  check
    (list outcome_testable)
    "closed"
    [ Candle_candidates.Wrote_unattributed { goal_id = "goal-1" } ]
    (drained base_path);
  match List.rev (events base_path) with
  | { E.body = E.Unattributed u; _ } :: { E.body = E.Candidates c; _ } :: _ ->
    check bool "the reason" true (u.reason = E.No_candidates);
    check (list string) "no candidate Tasks" [] c.candidate_task_ids
  | _ -> fail "expected Candidates, then Unattributed"
;;

(* A crash between the two rows leaves Candidates alone. *)
let test_a_missing_unattributed_is_written_on_the_next_pass () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed
    base_path
    [ snapshot []
    ; owed ()
    ; { E.at = at "2026-09-29T05:10:00Z"
      ; body =
          E.Candidates
            { goal_id = "goal-1"
            ; request_id = "req-1"
            ; verification_run_id = "run-1"
            ; tasks = []
            ; candidate_task_ids = []
            ; candidate_keepers = []
            ; candidate_task_keepers = []
            }
      }
    ];
  check
    (list outcome_testable)
    "closed"
    [ Candle_candidates.Wrote_unattributed { goal_id = "goal-1" } ]
    (drained base_path);
  check
    (list string)
    "only Unattributed was added"
    [ "snapshot"; "payout_owed"; "candidates"; "unattributed" ]
    (kinds base_path)
;;

let test_tasks_that_do_not_read_write_nothing_and_are_tried_again () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot [ "task-1" ]; owed () ];
  let unreadable = sources ~lookups:(fun ~goal_id:_ _ -> Error "the backlog could not be read") () in
  (match drained ~sources:unreadable base_path with
   | [ Candle_candidates.Retry_later { goal_id; detail } ] ->
     check string "goal" "goal-1" goal_id;
     check bool "says why" true (String_util.contains_substring detail "backlog")
   | _ -> fail "expected one Retry_later");
  check (list string) "nothing was written" [ "snapshot"; "payout_owed" ] (kinds base_path);
  check
    (list outcome_testable)
    "the next pass, with the store back"
    [ Candle_candidates.Wrote_candidates { goal_id = "goal-1" } ]
    (drained base_path)
;;

let test_keepers_that_do_not_list_write_nothing () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot [ "task-1" ]; owed () ];
  let unlisted = sources ~keepers:(fun () -> Error "the keepers directory could not be listed") () in
  (match drained ~sources:unlisted base_path with
   | [ Candle_candidates.Retry_later _ ] -> ()
   | _ -> fail "expected one Retry_later");
  check (list string) "nothing was written" [ "snapshot"; "payout_owed" ] (kinds base_path)
;;

let test_a_payout_without_its_snapshot_is_reported_and_left () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ owed () ];
  (match drained base_path with
   | [ Candle_candidates.Retry_later { goal_id = "goal-1"; _ } ] -> ()
   | _ -> fail "expected one Retry_later");
  check (list string) "nothing was written" [ "payout_owed" ] (kinds base_path)
;;

let test_one_payout_failing_does_not_stop_the_others () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed
    base_path
    [ snapshot ~goal_id:"goal-1" [ "task-1" ]
    ; owed ~goal_id:"goal-1" ()
    ; snapshot ~goal_id:"goal-2" ~request_id:"req-2" [ "task-2" ]
    ; owed ~goal_id:"goal-2" ~request_id:"req-2" ()
    ];
  let only_goal_2 =
    sources
      ~lookups:(fun ~goal_id task_ids ->
        if String.equal goal_id "goal-1"
        then Error "task-1 is linked but in neither store"
        else Ok (List.map (fun id -> id, done_by "keeper-a") task_ids))
      ()
  in
  (match drained ~sources:only_goal_2 base_path with
   | [ Candle_candidates.Retry_later { goal_id = "goal-1"; _ }
     ; Candle_candidates.Wrote_candidates { goal_id = "goal-2" }
     ] -> ()
   | _ -> fail "expected goal-1 to wait and goal-2 to be prepared")
;;

(* An exception from a source is one payout's failure and not the pass's. *)
let test_a_source_that_raises_does_not_stop_the_other_payouts () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed
    base_path
    [ snapshot ~goal_id:"goal-1" [ "task-1" ]
    ; owed ~goal_id:"goal-1" ()
    ; snapshot ~goal_id:"goal-2" ~request_id:"req-2" [ "task-2" ]
    ; owed ~goal_id:"goal-2" ~request_id:"req-2" ()
    ];
  let raising =
    sources
      ~lookups:(fun ~goal_id task_ids ->
        if String.equal goal_id "goal-1"
        then failwith "the store blew up"
        else Ok (List.map (fun id -> id, done_by "keeper-a") task_ids))
      ()
  in
  match drained ~sources:raising base_path with
  | [ Candle_candidates.Retry_later { goal_id = "goal-1"; detail }
    ; Candle_candidates.Wrote_candidates { goal_id = "goal-2" }
    ] ->
    check bool "names the exception" true (String_util.contains_substring detail "the store blew up")
  | _ -> fail "expected goal-1 to wait and goal-2 to be prepared"
;;

(* The Tasks are read outside the ledger's lock. If the payout closes meanwhile,
   the rows are not written. *)
let test_a_payout_that_closed_while_the_tasks_were_read_is_left_alone () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot [ "task-1" ]; owed () ];
  let closing =
    sources
      ~lookups:(fun ~goal_id task_ids ->
        seed
          base_path
          [ { E.at = at "2026-09-29T05:30:00Z"
            ; body = E.Candidates {goal_id;request_id="req-1";verification_run_id="run-1";
                tasks=List.map (fun id -> id, E.Found {title="cancelled";assignee=None;status=E.Cancelled}) task_ids;
                candidate_task_ids=[];candidate_keepers=[];candidate_task_keepers=[]} }
          ; { E.at = at "2026-09-29T05:30:00Z"
            ; body = E.Unattributed { goal_id; request_id = "req-1"; verification_run_id = "run-1"; reason = E.No_candidates }
            }
          ];
        Ok (List.map (fun id -> id, done_by "keeper-a") task_ids))
      ()
  in
  check
    (list outcome_testable)
    "superseded"
    [ Candle_candidates.Superseded { goal_id = "goal-1" } ]
    (drained ~sources:closing base_path);
  check (list string) "only the other writer's row" [ "snapshot"; "payout_owed"; "candidates"; "unattributed" ] (kinds base_path)
;;

(* Two workers reading the same Tasks: the one that lost the race writes no
   second Candidates. *)
let test_candidates_written_by_another_worker_meanwhile_are_not_repeated () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot [ "task-1" ]; owed () ];
  let racing =
    sources
      ~lookups:(fun ~goal_id task_ids ->
        seed
          base_path
          [ { E.at = at "2026-09-29T05:30:00Z"
            ; body =
                E.Candidates
                  { goal_id
                  ; request_id = "req-1"
                  ; verification_run_id = "run-1"
                  ; tasks = []
                  ; candidate_task_ids = []
                  ; candidate_keepers = [ "keeper-a" ]
                  ; candidate_task_keepers = []
                  }
            }
          ];
        Ok (List.map (fun id -> id, done_by "keeper-a") task_ids))
      ()
  in
  check
    (list outcome_testable)
    "superseded"
    [ Candle_candidates.Superseded { goal_id = "goal-1" } ]
    (drained ~sources:racing base_path);
  check (list string) "one Candidates row" [ "snapshot"; "payout_owed"; "candidates" ] (kinds base_path)
;;

(* The path that only writes the missing Unattributed reads no Task, so the one
   moment another writer can get in is between the clock and the append. The
   clock is asked once on that path, and this test lets the other writer in
   there. *)
let test_a_payout_closed_while_its_missing_unattributed_was_being_written_is_left_alone () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed
    base_path
    [ snapshot []
    ; owed ()
    ; { E.at = at "2026-09-29T05:10:00Z"
      ; body =
          E.Candidates
            { goal_id = "goal-1"
            ; request_id = "req-1"
            ; verification_run_id = "run-1"
            ; tasks = []
            ; candidate_task_ids = []
            ; candidate_keepers = []
            ; candidate_task_keepers = []
            }
      }
    ];
  let other_writer_first () =
    seed
      base_path
      [ { E.at = at "2026-09-29T05:30:00Z"
        ; body =
            E.Unattributed
              { goal_id = "goal-1"; request_id = "req-1"; verification_run_id = "run-1"; reason = E.No_candidates }
        }
      ];
    clock
  in
  check
    (list outcome_testable)
    "superseded"
    [ Candle_candidates.Superseded { goal_id = "goal-1" } ]
    (ok_or_fail
       (Candle_candidates.drain_with ~sources:(sources ()) ~now:other_writer_first
          ~config:(Workspace_utils_backend_setup.default_config base_path)));
  check
    (list string)
    "only the other writer's row was added"
    [ "snapshot"; "payout_owed"; "candidates"; "unattributed" ]
    (kinds base_path)
;;

(* The open payout is the one the Goal's last PayoutOwed names. If a later one
   replaces it while the Tasks are read, the rows written for the first are not
   this payout's. *)
let test_a_payout_replaced_while_the_tasks_were_read_is_left_alone () =
  List.iter (fun replacement ->
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot [ "task-1" ]; owed () ];
  let replacing =
    sources
      ~lookups:(fun ~goal_id:_ task_ids ->
        seed base_path [ replacement ];
        Ok (List.map (fun id -> id, done_by "keeper-a") task_ids))
      ()
  in
  check
    (list outcome_testable)
    "superseded"
    [ Candle_candidates.Superseded { goal_id = "goal-1" } ]
    (drained ~sources:replacing base_path);
  check (list string) "no Candidates for the replaced payout" [ "snapshot"; "payout_owed"; "payout_owed" ] (kinds base_path)
  ) [ owed ~request_id:"req-2" (); owed ~verification_run_id:"run-2" () ]
;;

(* Nobody can be paid for a Goal that linked no Task, so its payout closes
   without reading the Tasks or the Keepers, whatever state their stores are in. *)
let test_a_goal_that_linked_no_task_reads_neither_tasks_nor_keepers () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot []; owed () ];
  let unreadable =
    sources
      ~lookups:(fun ~goal_id:_ _ -> Error "the backlog could not be read")
      ~keepers:(fun () -> Error "the keepers directory could not be listed")
      ()
  in
  check
    (list outcome_testable)
    "closed"
    [ Candle_candidates.Wrote_unattributed { goal_id = "goal-1" } ]
    (drained ~sources:unreadable base_path)
;;

(* The window is the Goal's creation, which the Snapshot holds, to the
   confirmation, which the PayoutOwed row holds. A Task done after the
   confirmation is recorded as read and is not a candidate. *)
let test_the_candidate_window_is_the_goals_creation_to_its_confirmation () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  let task_ids = [ "before"; "inside"; "before-confirmation"; "after" ] in
  seed base_path [ snapshot task_ids; owed () ];
  let done_at time =
    E.Found
      { title = "A Task"
      ; assignee = Some "keeper-a"
      ; status = E.Done { completed_at = at time }
      }
  in
  let by_id =
    [ "before", done_at "2026-09-19T00:00:00Z"
    ; "inside", done_at "2026-09-25T00:00:00Z"
    ; "before-confirmation", done_at "2026-09-29T04:59:59Z"
    ; "after", done_at "2026-09-29T05:00:01Z"
    ]
  in
  let windowed =
    sources
      ~lookups:(fun ~goal_id:_ ids -> Ok (List.map (fun id -> id, List.assoc id by_id) ids))
      ()
  in
  check
    (list outcome_testable)
    "candidates written"
    [ Candle_candidates.Wrote_candidates { goal_id = "goal-1" } ]
    (drained ~sources:windowed base_path);
  match List.rev (events base_path) with
  | { E.body = E.Candidates_fenced c; _ } :: _ ->
    check (list string) "candidate Tasks" [ "inside"; "before-confirmation" ] c.candidate_task_ids;
    check (list string) "every Task read is recorded" task_ids (List.map fst c.tasks)
  | _ -> fail "expected Candidates last"
;;

let test_ambiguous_observation_is_durable_and_other_goals_progress () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot ~goal_id:"goal-1" ["task-1"]; owed ~goal_id:"goal-1" ();
                   snapshot ~goal_id:"goal-2" ["task-2"]; owed ~goal_id:"goal-2" () ];
  let keeper_reads = ref 0 in
  let source = sources
      ~lookups:(fun ~goal_id ids ->
        Ok (List.map (fun id -> id,
          if String.equal goal_id "goal-1" then
            E.Found {title="boundary task";assignee=Some "keeper-a";
              status=E.Done {completed_at=at "2026-09-20T01:00:00Z"}}
          else done_by "keeper-a") ids))
      ~keepers:(fun () -> incr keeper_reads;
        if !keeper_reads = 1 then Error "directory unavailable"
        else Ok (String.equal "keeper-a")) () in
  (match drained ~sources:source base_path with
   | [ Candle_candidates.Held_window {goal_id="goal-1"; issues; recorded=true}
     ; Candle_candidates.Wrote_candidates {goal_id="goal-2"} ] ->
     check bool "creation boundary explains the hold" true
       (List.exists (function Candle_payout.Same_second {boundary=Goal_created;_} -> true | _ -> false) issues)
   | _ -> fail "ambiguous Goal must be held while the other is prepared");
  (match List.find_opt (fun (event:E.t) -> match event.body with
    | E.Candidate_window_held _ -> true | _ -> false) (events base_path) with
   | Some {body=E.Candidate_window_held held;_} ->
     check bool "Keeper outage remains unknown" true
       (held.task_keepers = ["task-1", E.Keeper_unknown]);
     check bool "full Task observation is retained" true
       (match held.tasks with ["task-1", E.Found {status=E.Done _;_}] -> true | _ -> false)
   | _ -> fail "the hold was not retained in the ledger");
  let before = In_channel.with_open_bin (Candle_ledger.path ~base_path) In_channel.input_all in
  let no_reread = sources ~lookups:(fun ~goal_id:_ _ -> fail "held Task was read again")
      ~keepers:(fun () -> fail "held Keeper registry was read again") () in
  (match drained ~sources:no_reread base_path with
   | [ Candle_candidates.Held_window {goal_id="goal-1"; recorded=false;_}
     ; Candle_candidates.Already_prepared {goal_id="goal-2"} ] -> ()
   | _ -> fail "durable hold was not reused");
  check string "repeated scan leaves ledger unchanged" before
    (In_channel.with_open_bin (Candle_ledger.path ~base_path) In_channel.input_all)
;;

let test_missing_task_waits_and_can_recover () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot ["task-1"]; owed () ];
  let missing = sources ~lookups:(fun ~goal_id:_ ids -> Ok (List.map (fun id -> id, E.Deleted) ids)) () in
  (match drained ~sources:missing base_path with
   | [Candle_candidates.Waiting_task {goal_id="goal-1";_}] -> ()
   | _ -> fail "missing Task must wait for source evidence");
  check (list string) "no candidates or terminal row" ["snapshot";"payout_owed"] (kinds base_path);
  check (list outcome_testable) "source recovery prepares candidates"
    [Candle_candidates.Wrote_candidates {goal_id="goal-1"}] (drained base_path)
;;

let test_existing_ambiguous_candidates_cannot_close () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  let task = E.Found {title="boundary";assignee=Some "keeper-a";
    status=E.Done {completed_at=at "2026-09-20T01:00:00Z"}} in
  seed base_path [snapshot ["task-1"]; owed ();
    {E.at=at "2026-09-29T05:10:00Z"; body=E.Candidates
      {goal_id="goal-1"; request_id="req-1"; verification_run_id="run-1";
       tasks=["task-1", task]; candidate_task_ids=[]; candidate_keepers=[]; candidate_task_keepers=[]}}];
  let no_reread = sources ~lookups:(fun ~goal_id:_ _ -> fail "old Candidates must not reread Tasks") () in
  (match drained ~sources:no_reread base_path with
   | [Candle_candidates.Held_window {goal_id="goal-1";recorded=false;_}] -> ()
   | _ -> fail "old ambiguous Candidates must remain held");
  check (list string) "old Candidates were not terminally closed"
    ["snapshot";"payout_owed";"candidates"] (kinds base_path)
;;

let test_unfenced_nonterminal_candidates_wait_without_appraisal () =
  with_base_path @@ fun base_path ->
  enable base_path;
  seed base_path [snapshot ["done";"pending"]; owed ();
    {E.at=at "2026-09-29T05:10:00Z";body=E.Candidates
      {goal_id="goal-1";request_id="req-1";verification_run_id="run-1";
       tasks=["done",done_by "keeper-a";"pending",E.Found {title="pending";assignee=None;status=E.Todo}];
       candidate_task_ids=["done"];candidate_keepers=["keeper-a"];candidate_task_keepers=["done",Some "keeper-a"]}}];
  let no_reread = sources ~lookups:(fun ~goal_id:_ _ -> fail "legacy observation must not be replaced") () in
  (match drained ~sources:no_reread base_path with
   | [Candle_candidates.Held_window {issues;recorded=false;_}] ->
     check bool "unfenced Task is named" true
       (List.exists (function Candle_payout.Unfenced_nonterminal {task_id="pending"} -> true | _ -> false) issues)
   | _ -> fail "legacy nonterminal observation must wait");
  let waiting = match Candle_payout.waiting (events base_path) with
    | [waiting] -> waiting | _ -> fail "missing open obligation" in
  check bool "direct appraisal validation also rejects unfenced evidence" true
    (Result.is_error (Candle_payout.validate_durable_candidates waiting (events base_path)));
  check (list string) "no terminal row was appended" ["snapshot";"payout_owed";"candidates"] (kinds base_path)
;;

let test_conflicting_same_run_snapshots_are_never_selected () =
  List.iter (fun conflict_during_read ->
    with_base_path @@ fun base_path ->
    enable base_path;
    let first = snapshot ["task-1"] in
    let conflicting = snapshot ["task-2"] in
    seed base_path (if conflict_during_read then [first;owed ()]
                    else [first;conflicting;owed ()]);
    let reads = ref 0 in
    let source = sources ~lookups:(fun ~goal_id:_ ids ->
      incr reads;
      if conflict_during_read then seed base_path [conflicting];
      Ok (List.map (fun id -> id, done_by "keeper-a") ids)) () in
    (match drained ~sources:source base_path with
     | [Candle_candidates.Superseded _] when conflict_during_read -> ()
     | [Candle_candidates.Retry_later {detail;_}] when not conflict_during_read ->
       check bool "the conflicting evidence is reported" true
         (String_util.contains_substring detail "conflicting Snapshots")
     | _ -> fail "a conflicting same-run Snapshot was selected");
    check int "Tasks are read only before a concurrent conflict" (if conflict_during_read then 1 else 0) !reads;
    check bool "no candidate or terminal fact was written" false
      (List.exists (fun kind -> List.mem kind ["candidates";"unattributed";"paid"])
         (kinds base_path))) [false;true]
;;

(* Recovery runs once per process. A row that stops reading afterwards, from a
   hand edit or another writer, is an answer of Error and not an empty list, so
   a caller cannot mistake it for nothing waiting. *)
let test_a_ledger_that_stops_reading_after_recovery_is_an_error () =
  with_base_path
  @@ fun base_path ->
  enable base_path;
  seed base_path [ snapshot [ "task-1" ]; owed () ];
  check
    (list outcome_testable)
    "the first pass recovers the ledger and writes"
    [ Candle_candidates.Wrote_candidates { goal_id = "goal-1" } ]
    (drained base_path);
  Out_channel.with_open_gen
    [ Open_wronly; Open_append; Open_binary ]
    0o644
    (Candle_ledger.path ~base_path)
    (fun oc -> Out_channel.output_string oc "this is not a row\n");
  match drain base_path with
  | Error detail ->
    check bool "names the ledger" true (String_util.contains_substring detail "candle-ledger.jsonl")
  | Ok _ -> fail "a ledger with a row that does not read gave an answer"
;;

let () =
  run
    "candle_candidates"
    [ ( "when candle is not on"
      , [ test_case "off and disabled do nothing" `Quick test_off_and_disabled_do_nothing ] )
    ; ( "when candle is on"
      , [ test_case "a waiting payout gets its candidates" `Quick test_a_waiting_payout_gets_its_candidates
        ; test_case "the next pass writes nothing more" `Quick test_the_next_pass_writes_nothing_more
        ; test_case
            "no keeper to pay closes the payout without asking anyone"
            `Quick
            test_no_keeper_to_pay_closes_the_payout_without_asking_anyone
        ; test_case "a goal that linked no task is closed" `Quick test_a_goal_that_linked_no_task_is_closed
        ; test_case
            "a goal that linked no task reads neither tasks nor keepers"
            `Quick
            test_a_goal_that_linked_no_task_reads_neither_tasks_nor_keepers
        ; test_case
            "the candidate window is the goal's creation to its confirmation"
            `Quick
            test_the_candidate_window_is_the_goals_creation_to_its_confirmation
        ; test_case "ambiguous observation is durable while other goals progress" `Quick
            test_ambiguous_observation_is_durable_and_other_goals_progress
        ; test_case "missing task waits and can recover" `Quick test_missing_task_waits_and_can_recover
        ; test_case "existing ambiguous candidates cannot close" `Quick
            test_existing_ambiguous_candidates_cannot_close
        ; test_case "unfenced nonterminal candidates wait" `Quick
            test_unfenced_nonterminal_candidates_wait_without_appraisal
        ; test_case "conflicting same-run Snapshots are never selected" `Quick
            test_conflicting_same_run_snapshots_are_never_selected
        ; test_case
            "a ledger that stops reading after recovery is an error"
            `Quick
            test_a_ledger_that_stops_reading_after_recovery_is_an_error
        ; test_case
            "a missing unattributed is written on the next pass"
            `Quick
            test_a_missing_unattributed_is_written_on_the_next_pass
        ; test_case
            "tasks that do not read write nothing and are tried again"
            `Quick
            test_tasks_that_do_not_read_write_nothing_and_are_tried_again
        ; test_case "keepers that do not list write nothing" `Quick test_keepers_that_do_not_list_write_nothing
        ; test_case
            "a payout without its snapshot is reported and left"
            `Quick
            test_a_payout_without_its_snapshot_is_reported_and_left
        ; test_case
            "one payout failing does not stop the others"
            `Quick
            test_one_payout_failing_does_not_stop_the_others
        ; test_case
            "a source that raises does not stop the other payouts"
            `Quick
            test_a_source_that_raises_does_not_stop_the_other_payouts
        ; test_case
            "a payout that closed while the tasks were read is left alone"
            `Quick
            test_a_payout_that_closed_while_the_tasks_were_read_is_left_alone
        ; test_case
            "a payout closed while its missing unattributed was being written is left alone"
            `Quick
            test_a_payout_closed_while_its_missing_unattributed_was_being_written_is_left_alone
        ; test_case
            "a payout replaced while the tasks were read is left alone"
            `Quick
            test_a_payout_replaced_while_the_tasks_were_read_is_left_alone
        ; test_case
            "candidates written by another worker meanwhile are not repeated"
            `Quick
            test_candidates_written_by_another_worker_meanwhile_are_not_repeated
        ] )
    ]
;;
