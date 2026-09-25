(** The shared tool-call window behind a keeper's claim projection (#28437).

    Two properties are under test, and they are the same change:

    - the claim reported is the keeper's {b latest} one, not the first row a
      scan happens to meet in an oldest-first window;
    - one window read serves every keeper in a fleet envelope, rather than
      each keeper re-reading the same shared store.

    The store is real: rows go in through [Keeper_tool_call_log.log_call] and
    come back through [read_claim_window], so the test exercises
    [Dated_jsonl]'s ordering rather than a hand-built list that would keep
    passing if that ordering changed. *)

open Masc

let counter = ref 0

let with_tmp_log f =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "test-composite-claim-window-%d-%d"
         (Unix.getpid ())
         !counter)
  in
  Fs_compat.mkdir_p dir;
  Keeper_tool_call_log.reset_for_testing ();
  Keeper_tool_call_log.init ~base_path:dir ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      Fs_compat.remove_tree dir)
    (fun () -> f ())
;;

let eio_test name fn =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    with_tmp_log fn)
;;

(* The payload shape [composite_claim_attempt_json] decodes: the tool call's
   output text is itself a JSON document carrying the claimed task. *)
let claim_output ~task_id ~goal_id =
  `Assoc
    [ "result", `String (Printf.sprintf "claimed %s" task_id)
    ; "claimed_task", `Assoc [ "task_id", `String task_id; "goal_id", `String goal_id ]
    ]
  |> Yojson.Safe.to_string
;;

let log_claim_payload ~keeper ?(wire_outcome = Tool_result.Ok) payload =
  Keeper_tool_call_log.log_call
    ~keeper_name:keeper
    ~tool_name:(Keeper_tooling.Name.to_string Keeper_tooling.Name.Task_claim)
    ~input:(`Assoc [])
    ~output_text:payload
    ~wire_outcome
    ~duration_ms:1.0
    ()
;;

let log_claim ~keeper ~task_id ~goal_id =
  log_claim_payload ~keeper (claim_output ~task_id ~goal_id)
;;

let log_noise ~keeper ~n =
  for index = 1 to n do
    Keeper_tool_call_log.log_call
      ~keeper_name:keeper
      ~tool_name:(Keeper_tooling.Name.to_string Keeper_tooling.Name.Tasks_list)
      ~input:(`Assoc [])
      ~output_text:(Printf.sprintf {|{"row":%d}|} index)
      ~wire_outcome:Tool_result.Ok
      ~duration_ms:1.0
      ()
  done
;;

let claimed_task_id ~claim_window ~keeper =
  match
    Server_dashboard_http_composite_claims.composite_claim_attempt_json
      ~claim_window
      ~keeper_name:keeper
  with
  | `Assoc fields ->
    (match List.assoc_opt "claimed_task_id" fields with
     | Some (`String id) -> Some id
     | Some `Null | Some _ | None -> None)
  | _ -> None
;;

let claim_present ~claim_window ~keeper =
  match
    Server_dashboard_http_composite_claims.composite_claim_attempt_json
      ~claim_window
      ~keeper_name:keeper
  with
  | `Assoc fields ->
    (match List.assoc_opt "present" fields with
     | Some (`Bool present) -> present
     | _ -> false)
  | _ -> false
;;

let claim_status ~claim_window ~keeper =
  match
    Server_dashboard_http_composite_claims.composite_claim_attempt_json
      ~claim_window ~keeper_name:keeper
  with
  | `Assoc fields ->
    (match List.assoc_opt "status" fields with
     | Some (`String status) -> status
     | _ -> Alcotest.fail "claim status missing")
  | _ -> Alcotest.fail "claim attempt is not an object"
;;

let test_claim_status_uses_typed_outcome () =
  let output ~result ?typed_outcome ?claimed_task () =
    `Assoc
      ([ "result", `String result ]
       @ Option.fold ~none:[]
           ~some:(fun value -> [ "typed_outcome", value ]) typed_outcome
       @ Option.fold ~none:[]
           ~some:(fun value -> [ "claimed_task", value ]) claimed_task)
    |> Yojson.Safe.to_string
  in
  let typed_no_eligible =
    Keeper_tool_outcome.to_json
      (Keeper_tool_outcome.No_progress
         { reason =
             Keeper_tool_outcome.No_eligible_tasks
               { scope_excluded_count = 1 }
         })
  in
  let typed_no_work =
    Keeper_tool_outcome.to_json
      (Keeper_tool_outcome.No_progress
         { reason = Keeper_tool_outcome.No_work_available })
  in
  let typed_error =
    Keeper_tool_outcome.to_json
      (Keeper_tool_outcome.Error { reason = "storage read failed" })
  in
  log_claim_payload ~keeper:"no-eligible"
    (output ~result:"No unclaimed tasks." ~typed_outcome:typed_no_eligible ());
  log_claim_payload ~keeper:"no-work"
    (output ~result:"No eligible tasks." ~typed_outcome:typed_no_work ());
  log_claim_payload ~keeper:"failed" ~wire_outcome:Tool_result.Error
    (output ~result:"Everything is fine" ~typed_outcome:typed_error ());
  log_claim_payload ~keeper:"untyped"
    (output ~result:"No eligible tasks." ());
  log_claim_payload ~keeper:"untyped-failure" ~wire_outcome:Tool_result.Error
    (output ~result:"Everything is fine" ());
  log_claim_payload ~keeper:"malformed"
    (output ~result:"Error: storage read failed"
       ~typed_outcome:(`Assoc [ "kind", `String "unexpected" ]) ());
  log_claim_payload ~keeper:"malformed-failed" ~wire_outcome:Tool_result.Error
    (output ~result:"Everything is fine"
       ~typed_outcome:(`Assoc [ "kind", `String "unexpected" ]) ());
  log_claim_payload ~keeper:"missing-exclusions"
    (output ~result:"No eligible tasks."
       ~typed_outcome:
         (`Assoc
            [ "kind", `String "No_progress"
            ; "reason",
              `Assoc
                [ "kind", `String "No_eligible_tasks"
                ; "exclusions", `Assoc []
                ]
            ]) ());
  log_claim_payload ~keeper:"contradictory"
    (output ~result:"claimed a task" ~typed_outcome:typed_error
       ~claimed_task:(`Assoc [ "task_id", `String "task-z" ]) ());
  log_claim_payload ~keeper:"missing-task-id"
    (output ~result:"claimed a task" ~claimed_task:(`Assoc []) ());
  log_claim_payload ~keeper:"wire-failed-after-claim" ~wire_outcome:Tool_result.Error
    (output ~result:"claimed a task"
       ~claimed_task:(`Assoc [ "task_id", `String "task-w" ]) ());
  let claim_window = Server_dashboard_http_composite_claims.read_claim_window () in
  let check_status keeper expected =
    Alcotest.(check string) keeper expected
      (claim_status ~claim_window ~keeper)
  in
  check_status "no-eligible" "no_eligible";
  check_status "no-work" "no_unclaimed";
  check_status "failed" "error";
  check_status "untyped" "observed";
  check_status "untyped-failure" "error";
  check_status "malformed" "unknown";
  check_status "malformed-failed" "error";
  check_status "missing-exclusions" "unknown";
  check_status "contradictory" "unknown";
  check_status "missing-task-id" "observed";
  check_status "wire-failed-after-claim" "claimed";
  Alcotest.(check (option string)) "contradictory outcome exposes no claimed id"
    None (claimed_task_id ~claim_window ~keeper:"contradictory");
  let no_eligible =
    Server_dashboard_http_composite_claims.composite_claim_attempt_json
      ~claim_window ~keeper_name:"no-eligible"
  in
  Alcotest.(check bool) "attention sees the typed no-eligible claim" true
    (Server_dashboard_http_composite_claims.composite_execution_claim_no_eligible
       (`Assoc [ "claim_attempt", no_eligible ]))
;;

(* The defect this file exists for.

   Rows come back oldest-first, so taking the first matching row reported
   task-a — the claim the keeper had already superseded. Measured live before
   the fix: keeper [delta] reported task-305 while it had claimed task-306. *)
let test_reports_the_latest_claim () =
  log_claim ~keeper:"delta" ~task_id:"task-a" ~goal_id:"goal-a";
  log_claim ~keeper:"delta" ~task_id:"task-b" ~goal_id:"goal-b";
  let claim_window = Server_dashboard_http_composite_claims.read_claim_window () in
  Alcotest.(check (option string))
    "the superseding claim is the one reported"
    (Some "task-b")
    (claimed_task_id ~claim_window ~keeper:"delta")
;;

(* Why the defect stayed invisible on a busy keeper.

   [filter_rows_for_keeper] keeps only that keeper's last
   [claim_rows_per_keeper] rows, so enough traffic between two claims trims the
   older one away and the first-match scan lands on the newer one by accident.
   Correctness was inversely proportional to keeper traffic; watching a chatty
   keeper, the bug never appeared. This case must keep passing either way — it
   documents the mechanism, it does not detect it. *)
let test_ring_trim_hides_the_older_claim () =
  let rows_per_keeper =
    Server_dashboard_http_composite_claims.claim_rows_per_keeper
  in
  log_claim ~keeper:"beta" ~task_id:"task-old" ~goal_id:"goal-old";
  log_noise ~keeper:"beta" ~n:rows_per_keeper;
  log_claim ~keeper:"beta" ~task_id:"task-new" ~goal_id:"goal-new";
  let claim_window = Server_dashboard_http_composite_claims.read_claim_window () in
  Alcotest.(check (option string))
    "a trimmed older claim cannot be reported"
    (Some "task-new")
    (claimed_task_id ~claim_window ~keeper:"beta")
;;

(* The N+1 property: the window is fleet-wide, so one read answers for every
   keeper. If it were keeper-specific, at most one of these could be right. *)
let test_one_window_serves_every_keeper () =
  log_claim ~keeper:"alice" ~task_id:"task-1" ~goal_id:"goal-1";
  log_claim ~keeper:"bob" ~task_id:"task-2" ~goal_id:"goal-2";
  log_claim ~keeper:"carol" ~task_id:"task-3" ~goal_id:"goal-3";
  log_claim ~keeper:"alice" ~task_id:"task-4" ~goal_id:"goal-4";
  let claim_window = Server_dashboard_http_composite_claims.read_claim_window () in
  Alcotest.(check (option string))
    "alice reads her own latest"
    (Some "task-4")
    (claimed_task_id ~claim_window ~keeper:"alice");
  Alcotest.(check (option string))
    "bob reads his own"
    (Some "task-2")
    (claimed_task_id ~claim_window ~keeper:"bob");
  Alcotest.(check (option string))
    "carol reads her own"
    (Some "task-3")
    (claimed_task_id ~claim_window ~keeper:"carol")
;;

let test_absent_without_a_claim () =
  log_noise ~keeper:"quiet" ~n:3;
  log_claim ~keeper:"other" ~task_id:"task-x" ~goal_id:"goal-x";
  let claim_window = Server_dashboard_http_composite_claims.read_claim_window () in
  Alcotest.(check bool)
    "a keeper that never claimed reports absent"
    false
    (claim_present ~claim_window ~keeper:"quiet");
  Alcotest.(check bool)
    "a keeper absent from the log entirely reports absent"
    false
    (claim_present ~claim_window ~keeper:"never-seen")
;;

(* The shared read must cover what the per-keeper read covered, or the batch
   would silently narrow the window it replaced. *)
let test_window_reproduces_per_keeper_coverage () =
  Alcotest.(check int)
    "window is the per-keeper read's over-scanned coverage"
    (Server_dashboard_http_composite_claims.claim_rows_per_keeper
     * Keeper_tool_call_log.read_over_scan_factor)
    Server_dashboard_http_composite_claims.claim_window_rows
;;

let () =
  Alcotest.run
    "composite claim window"
    [ ( "latest claim (#28437)"
      , [ eio_test "reports the latest claim, not the first row scanned"
            test_reports_the_latest_claim
        ; eio_test
            "ring trim hides the older claim on a busy keeper"
            test_ring_trim_hides_the_older_claim
        ] )
    ; ( "shared window"
      , [ eio_test
            "one window serves every keeper"
            test_one_window_serves_every_keeper
        ; eio_test "absent without a claim" test_absent_without_a_claim
        ; eio_test "claim status follows typed outcome, not result prose"
            test_claim_status_uses_typed_outcome
        ; Alcotest.test_case
            "reproduces the per-keeper read's coverage"
            `Quick
            test_window_reproduces_per_keeper_coverage
        ] )
    ]
;;
