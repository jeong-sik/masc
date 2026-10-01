let appraise ~identity:_ _ = Error (Candle_appraisal.Transport_unavailable "fixture stops after durable Candidates")

let () = Candle_status.install_appraiser_check (fun () -> Ok ())

(** A Goal's way through the two Candle steps: the verifier's passing result
    writes a Snapshot, and the operator's confirmation writes a PayoutOwed
    (RFC-goal-candle-ledger 3.2). The confirmation goes through the HTTP route's
    handler, the one caller that installs the step. *)

open Alcotest
open Masc

module Route = Server_routes_http_routes_verification
module A = Candle_appraisal

(* {1 Fixtures} *)

let temp_dir () =
  let path = Filename.temp_file "candle_goal_flow_" "" in
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

let with_workspace_and_env f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace.default_config dir in
       ignore (Workspace.init config ~agent_name:(Some "planner"));
       f env config)
;;

let with_workspace f = with_workspace_and_env (fun _env config -> f config)

let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

(* The test writes candle.toml, so it stops if the resolver points anywhere but
   the temporary workspace. *)
let enable_candle (config : Workspace.config) =
  let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path:config.base_path in
  if not (String.starts_with ~prefix:config.base_path path)
  then failf "the candle.toml path %s is outside the test workspace" path;
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc {|half_life = "off"
[payout]
weight_max = 10
deduction_rate = 10
deduction_floor = 200
[payout.grades_milli]
trivial = 1000
small = 2000
medium = 3000
large = 4000
epic = 5000
|})
;;

let ledger_path (config : Workspace.config) = Candle_ledger.path ~base_path:config.base_path

let ledger_events (config : Workspace.config) =
  match Candle_ledger.read ~base_path:config.base_path with
  | Ok view -> Candle_ledger.events view
  | Error error -> failf "%s" (Candle_ledger.read_error_to_string error)
;;

(* Kind, Goal and request of every Goal row, in file order. *)
let rows config =
  List.filter_map
    (fun (event : Candle_event.t) ->
       match event.body with
       | Candle_event.Snapshot { goal_id; request_id; _ }
       | Candle_event.Payout_owed { goal_id; request_id; _ }
       | Candle_event.Candidates { goal_id; request_id; _ }
       | Candle_event.Unattributed { goal_id; request_id; _ }
       | Candle_event.Payout_failed { goal_id; request_id; _ } ->
         Some (Candle_event.kind event.body, goal_id, request_id)
       | Candle_event.Paid p -> Some (Candle_event.kind event.body, p.identity.goal_id, p.identity.request_id)
       | Candle_event.Half_life_set _ -> None
       | Candle_event.Equipped _ | Candle_event.Purchased _ -> Alcotest.fail "a purchase has no verification request")
    (ledger_events config)
;;

let count_kind config kind =
  List.length (List.filter (fun (k, _, _) -> String.equal k kind) (rows config))
;;

let rows_testable = list (triple string string string)

(* Callers create and move the shared Goal through the public tools. *)
let dispatch config ~name args =
  match
    Tool_workspace.dispatch
      { Tool_workspace.config; agent_name = "planner" }
      ~name
      ~args:(`Assoc args)
  with
  | Some result when Tool_result.is_success result -> result
  | Some result -> failf "%s: %s" name (Tool_result.message result)
  | None -> failf "%s: not handled" name
;;

let make_goal config =
  let created =
    dispatch
      config
      ~name:"masc_goal_upsert"
      [ "title", `String "Ship the ledger"
      ; "metric", `String "tests"
      ; "target_value", `String "10"
      ]
  in
  Yojson.Safe.Util.(
    Yojson.Safe.from_string (Tool_result.message created) |> member "goal_id" |> to_string)
;;

let transition config goal_id action =
  ignore
    (dispatch config ~name:"masc_goal_transition" [ "goal_id", `String goal_id; "action", `String action ]
     : Tool_result.result)
;;

let stored_goal config goal_id =
  match Goal_store.find_goal config ~goal_id with
  | Goal_store.Goal_found goal -> goal
  | Goal_store.Goal_absent -> failf "goal not found: %s" goal_id
  | Goal_store.Store_unavailable u -> failf "%s" (Goal_store.unavailable_to_string u)
;;

let phase config goal_id = Goal_phase.to_string (stored_goal config goal_id).Goal_store.phase

(* The verifier's passing result, committed with the Snapshot step installed
   the way the verifier installs it. *)
let pass ?(verification_run_id = "goal-verifier-test-run") config goal_id =
  let request_id, criterion =
    match Goal_verification.get_record_authoritative config ~goal_id with
    | Ok (Some { Goal_verification.completion = Goal_verification.Proof_pending pending; _ }) ->
      pending.request_id, pending.criterion
    | Ok _ | Error _ -> fail "a pass needs a pending request"
  in
  let result =
    Workspace_goals.commit_verifier_decision
      ~before_proof_commit:(Candle_snapshot.before_proof_commit config)
      ~tool_name:"goal_verifier_commit"
      ~start_time:(Tool_timing.start ())
      config
      ~goal_id
      ~request_id
      ~criterion
      ~verification_run_id
      ~decision:Workspace_goals.Proof_proven
      ~evidence:"observed by the test verifier"
  in
  if not (Tool_result.is_success result)
  then failf "pass: %s" (Tool_result.message result)
;;

let goal_in_verifying config =
  let goal_id = make_goal config in
  transition config goal_id "request_complete";
  goal_id
;;

let current_verdict config goal_id =
  match Goal_verification.get_record_authoritative config ~goal_id with
  | Ok
      (Some
        { Goal_verification.completion =
            ( Goal_verification.Proof_proven verdict
            | Goal_verification.Human_confirmed (verdict, _) )
        ; _
        }) -> verdict
  | Ok _ | Error _ -> fail "expected a proven result"
;;

let confirm config goal_id =
  let goal = stored_goal config goal_id in
  let verdict = current_verdict config goal_id in
  Route.For_testing.commit_goal_confirmation_json
    ~config
    ~operator_id:"operator-a"
    (`Assoc
        [ "goal_id", `String goal_id
        ; "criterion_revision", `String goal.Goal_store.criterion_revision
        ; "request_id", `String verdict.Goal_verification.request_id
        ; "verification_run_id", `String verdict.Goal_verification.verification_run_id
        ])
;;

let confirmed config goal_id =
  match confirm config goal_id with
  | Ok _ -> ()
  | Error error -> failf "confirm: %s" (Route.For_testing.confirmation_error_to_string error)
;;

(* {1 Tests} *)

let test_a_confirmed_pass_leaves_a_payout_owed () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  let goal_id = goal_in_verifying config in
  pass config goal_id;
  let verdict = current_verdict config goal_id in
  confirmed config goal_id;
  check string "the Goal is completed" "completed" (phase config goal_id);
  let request_id = verdict.Goal_verification.request_id in
  check
    rows_testable
    "the Snapshot, then the PayoutOwed"
    [ "snapshot", goal_id, request_id; "payout_owed", goal_id, request_id ]
    (rows config);
  (match List.rev (ledger_events config), (Goal_verification.get_record_authoritative config ~goal_id) with
   | ( { Candle_event.body = Candle_event.Payout_owed owed; _ } :: _
     , Ok (Some { Goal_verification.completion = Goal_verification.Human_confirmed (_, confirmation); _ })
     ) ->
     check string "the obligation names the confirmed verifier run"
       verdict.Goal_verification.verification_run_id owed.verification_run_id;
     check
       string
       "the pass time is the verdict's"
       verdict.Goal_verification.recorded_at
       (Candle_time.to_rfc3339 owed.passed_at);
     check
       string
       "the confirmation time is the operator's"
       confirmation.Goal_verification.confirmed_at
       (Candle_time.to_rfc3339 owed.confirmed_at)
   | _ -> fail "expected a PayoutOwed and a confirmation");
  confirmed config goal_id;
  check int "confirming again writes no second PayoutOwed" 1 (count_kind config "payout_owed")
;;

(* A failed proof commit can leave its Snapshot behind. Reproduce that residue
   through the Snapshot producer using the actual committing verdict's second,
   then finish a different run of the same request. The confirmation and
   candidate pass must follow that run's linked Tasks. *)
let test_same_second_retry_uses_the_confirmed_run_snapshot () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  let goal_id = goal_in_verifying config in
  (match Goal_store.transact_goal config ~goal_id (fun goal ->
     Ok ({ goal with Goal_store.created_at = "2026-09-20T01:00:00Z" }, ())) with
   | Ok _ -> ()
   | Error error -> fail (Goal_store.write_error_to_string error));
  let request_id, criterion =
    match Goal_verification.get_record_authoritative config ~goal_id with
    | Ok (Some { Goal_verification.completion = Goal_verification.Proof_pending pending; _ }) ->
        pending.request_id, pending.criterion
    | Ok _ | Error _ -> fail "missing pending request"
  in
  Workspace_goal_index.write_goal_task_links config [ goal_id, [ "task-orphan" ] ];
  let before_proof_commit goal (verdict : Goal_verification.verdict) =
    let ( let* ) = Result.bind in
    let failed = { verdict with verification_run_id = "failed-verifier-run" } in
    let* () = Candle_snapshot.before_proof_commit config goal failed in
    Workspace_goal_index.write_goal_task_links config [ goal_id, [ "task-confirmed" ] ];
    Candle_snapshot.before_proof_commit config goal verdict
  in
  let committed =
    Workspace_goals.commit_verifier_decision ~before_proof_commit
      ~tool_name:"goal_verifier_commit" ~start_time:(Tool_timing.start ()) config
      ~goal_id ~request_id ~criterion ~verification_run_id:"confirmed-verifier-run"
      ~decision:Workspace_goals.Proof_proven ~evidence:"the successful retry's proof"
  in
  if not (Tool_result.is_success committed) then fail (Tool_result.message committed);
  (match ledger_events config with
   | [ { Candle_event.body = Candle_event.Snapshot first; _ }
     ; { Candle_event.body = Candle_event.Snapshot second; _ } ] ->
       check bool "both runs occupy the same second" true
         (Candle_time.equal first.passed_at second.passed_at);
       check string "the first Snapshot is the orphan run" "failed-verifier-run" first.verification_run_id;
       check string "the second Snapshot is the committed run" "confirmed-verifier-run" second.verification_run_id
   | _ -> fail "expected both run Snapshots before confirmation");
  confirmed config goal_id;
  let completed_at =
    match Candle_time.of_rfc3339 "2026-09-25T00:00:00Z" with
    | Ok time -> time
    | Error detail -> fail detail
  in
  let sources : Candle_candidates.sources =
    { task_lookups = (fun ~goal_id:_ ids ->
        Ok (List.map (fun id -> id, Candle_event.Found
          { title = id; assignee = Some "keeper-a"; status = Candle_event.Done { completed_at } }) ids))
    ; is_keeper = (fun () -> Ok (String.equal "keeper-a"))
    }
  in
  (match Candle_candidates.drain_with ~sources ~now:Time_compat.now ~base_path:config.base_path with
   | Ok [ Candle_candidates.Wrote_candidates _ ] -> ()
   | Ok _ -> fail "the confirmed contribution was not prepared"
   | Error detail -> fail detail);
  (match List.rev (ledger_events config) with
   | { Candle_event.body = Candle_event.Candidates candidates; _ }
     :: { Candle_event.body = Candle_event.Payout_owed owed; _ } :: _ ->
       check string "PayoutOwed keeps the production verifier run" "confirmed-verifier-run" owed.verification_run_id;
       check string "Candidates keeps the production verifier run" "confirmed-verifier-run" candidates.verification_run_id;
       check (list string) "only the successful run's Tasks are candidates"
         [ "task-confirmed" ] candidates.candidate_task_ids
   | _ -> fail "expected the obligation followed by its Candidates")
;;

let test_without_a_candle_toml_a_confirmation_writes_nothing () =
  with_workspace
  @@ fun config ->
  let goal_id = goal_in_verifying config in
  pass config goal_id;
  confirmed config goal_id;
  check string "the Goal is completed" "completed" (phase config goal_id);
  check bool "no ledger" false (Sys.file_exists (ledger_path config))
;;

(* Candle was not on when the Goal passed, so nothing was fixed for a payout. *)
let test_a_pass_from_before_candle_owes_nothing () =
  with_workspace
  @@ fun config ->
  let goal_id = goal_in_verifying config in
  pass config goal_id;
  enable_candle config;
  confirmed config goal_id;
  check string "the Goal is completed" "completed" (phase config goal_id);
  check bool "no ledger" false (Sys.file_exists (ledger_path config))
;;

(* Runs [f] with the ledger path turned into a directory, so that every write to
   it fails, and puts the ledger back as it was afterwards. *)
let with_unwritable_ledger config f =
  let written = In_channel.with_open_bin (ledger_path config) In_channel.input_all in
  Sys.remove (ledger_path config);
  Unix.mkdir (ledger_path config) 0o755;
  Fun.protect
    ~finally:(fun () ->
      Unix.rmdir (ledger_path config);
      Out_channel.with_open_bin (ledger_path config) (fun oc ->
        Out_channel.output_string oc written))
    f
;;

let test_a_payout_that_cannot_be_written_refuses_the_confirmation () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  let goal_id = goal_in_verifying config in
  pass config goal_id;
  with_unwritable_ledger config (fun () ->
    match confirm config goal_id with
    | Ok _ -> fail "a confirmation went through with the ledger unwritable"
    | Error error ->
      check
        bool
        "the refusal names the step"
        true
        (String_util.contains_substring
           (Route.For_testing.confirmation_error_to_string error)
           "candle payout owed");
      check string "the phase did not move" "awaiting_confirmation" (phase config goal_id));
  confirmed config goal_id;
  check string "confirming again completes it" "completed" (phase config goal_id);
  check int "with one PayoutOwed" 1 (count_kind config "payout_owed")
;;

(* The confirmation was refused for the ledger, so the Goal never completed and
   nothing is owed (RFC-goal-candle-ledger 3.2, failure at the row). Reopening
   clears the confirmation record. Passing again and confirming again owes one
   payout, for the new pass. *)
let test_a_refused_confirmation_that_is_reopened_owes_nothing () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  let goal_id = goal_in_verifying config in
  pass config goal_id;
  let first_request = (current_verdict config goal_id).Goal_verification.request_id in
  with_unwritable_ledger config (fun () ->
    match confirm config goal_id with
    | Ok _ -> fail "a confirmation went through with the ledger unwritable"
    | Error _ -> ());
  transition config goal_id "reopen";
  check string "reopened" "executing" (phase config goal_id);
  check int "nothing is owed" 0 (count_kind config "payout_owed");
  transition config goal_id "request_complete";
  pass config goal_id;
  confirmed config goal_id;
  check string "completed" "completed" (phase config goal_id);
  let second_request = (current_verdict config goal_id).Goal_verification.request_id in
  check
    rows_testable
    "one PayoutOwed, for the second pass"
    [ "snapshot", goal_id, first_request
    ; "snapshot", goal_id, second_request
    ; "payout_owed", goal_id, second_request
    ]
    (rows config)
;;

(* The step wrote its row, then the Goal's phase could not be saved
   (RFC-goal-candle-ledger 3.2, failure at the phase). The hook below runs the
   step and then refuses, which leaves the same state: the confirmation record,
   the row, and a Goal still awaiting confirmation. *)
let test_a_phase_that_could_not_be_saved_after_the_row_leaves_one_row () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  let goal_id = goal_in_verifying config in
  pass config goal_id;
  let goal = stored_goal config goal_id in
  let verdict = current_verdict config goal_id in
  let refuse_after_the_row g v c =
    match Candle_payout_owed.after_confirmation config g v c with
    | Ok () -> Error "the phase could not be saved"
    | Error _ as refused -> refused
  in
  (match
     Workspace_goals.confirm_completion
       ~after_confirmation:refuse_after_the_row
       config
       ~goal_id
       ~operator_id:"operator-a"
       ~request_id:verdict.Goal_verification.request_id
       ~verification_run_id:verdict.Goal_verification.verification_run_id
       ~criterion_revision:goal.Goal_store.criterion_revision
   with
   | Ok _ -> fail "the confirmation went through"
   | Error _ -> ());
  check string "the phase did not move" "awaiting_confirmation" (phase config goal_id);
  check int "the row is there" 1 (count_kind config "payout_owed");
  confirmed config goal_id;
  check string "confirming again completes it" "completed" (phase config goal_id);
  check int "with the one row" 1 (count_kind config "payout_owed")
;;

(* The obligation is the first confirmed pass. A reopen and a second pass add a
   Snapshot, and confirming that one owes nothing more. *)
let test_a_reopened_goal_that_passes_again_owes_no_second_payout () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  let goal_id = goal_in_verifying config in
  pass config goal_id;
  confirmed config goal_id;
  transition config goal_id "reopen";
  check string "reopened" "executing" (phase config goal_id);
  transition config goal_id "request_complete";
  pass config goal_id;
  confirmed config goal_id;
  check string "completed again" "completed" (phase config goal_id);
  check int "two Snapshots" 2 (count_kind config "snapshot");
  check int "one PayoutOwed" 1 (count_kind config "payout_owed")
;;

(* The whole way: the verifier passes the Goal, the worker is running, the
   operator confirms, and the confirmation wakes the worker, which reads the
   Tasks the Goal linked (none) and closes the payout. *)
let test_a_confirmation_wakes_the_worker_that_prepares_the_payout () =
  with_workspace_and_env
  @@ fun env config ->
  enable_candle config;
  Workspace_backlog.write_backlog
    config
    { Masc_domain.tasks = []
    ; task_deletion_receipts = []
    ; pending_completion_rejections = []
    ; last_updated = "2026-09-29T00:00:00Z"
    ; version = 1
    };
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path in
  if not (String.starts_with ~prefix:config.base_path keepers_dir)
  then failf "the keepers directory %s is outside the test workspace" keepers_dir;
  mkdir_p keepers_dir;
  let goal_id = goal_in_verifying config in
  pass config goal_id;
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise ~sw ~config;
    confirmed config goal_id;
    match
      Eio.Time.with_timeout clock 10. (fun () ->
        while count_kind config "unattributed" = 0 do
          Eio.Time.sleep clock 0.02
        done;
        Ok ())
    with
    | Ok () -> ()
    | Error `Timeout -> fail "the worker did not close the payout within 10s");
  let request_id = (current_verdict config goal_id).Goal_verification.request_id in
  check
    rows_testable
    "Snapshot, PayoutOwed, Candidates, Unattributed"
    [ "snapshot", goal_id, request_id
    ; "payout_owed", goal_id, request_id
    ; "candidates", goal_id, request_id
    ; "unattributed", goal_id, request_id
    ]
    (rows config)
;;

(* The positive lifecycle uses production Goal, Task, Keeper and ledger
   readers/writers. Only the appraiser's model decisions are injected. A Done
   Task is a persisted fixture; no Candle fact is manufactured by this test. *)
let test_a_confirmed_goal_pays_its_keeper_once_across_reopen_and_restart () =
  with_workspace_and_env
  @@ fun env config ->
  enable_candle config;
  let keeper = "paid-flow-keeper" in
  let keeper_path =
    Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:config.base_path keeper
  in
  if not (String.starts_with ~prefix:(config.base_path ^ Filename.dir_sep) keeper_path)
  then failf "the Keeper config %s is outside the test workspace" keeper_path;
  mkdir_p (Filename.dirname keeper_path);
  Out_channel.with_open_bin keeper_path (fun oc ->
    Out_channel.output_string oc
      "[keeper]\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\ninstructions = \"Complete the linked Task.\"\n");
  let goal_id = make_goal config in
  let task_title = "Persist the Goal's Candle ledger" in
  let task_id =
    match Task.Goal_assignment.add_task_with_result ~goal_id ~created_by:"planner"
      config ~title:task_title ~priority:3 ~description:"Implement the promised ledger"
    with
    | Ok created -> created.task_id
    | Error error -> fail (Workspace_task.add_task_error_to_string error)
  in
  (* Candidate eligibility is strictly after the Goal's whole-second creation
     timestamp. Cross the next real second; do not change the Goal or clock. *)
  let clock = Eio.Stdenv.clock env in
  Eio.Time.sleep_until clock (Float.floor (Eio.Time.now clock) +. 1.);
  let completed_at = Masc_domain.now_iso () in
  let backlog = match Workspace_backlog.read_backlog_r config with
    | Ok backlog -> backlog
    | Error detail -> fail detail
  in
  check bool "the created Task is persisted" true
    (List.exists (fun (task : Masc_domain.task) -> task.id = task_id) backlog.tasks);
  Workspace_backlog.write_backlog config
    { backlog with tasks = List.map (fun (task : Masc_domain.task) ->
        if task.id = task_id then
          { task with task_status = Masc_domain.Done {assignee=keeper;completed_at;notes=None} }
        else task) backlog.tasks };
  transition config goal_id "request_complete";
  pass ~verification_run_id:"paid-flow-first-verifier" config goal_id;
  let first_verdict = current_verdict config goal_id in
  let first_identity : A.identity =
    {goal_id;request_id=first_verdict.request_id;verification_run_id=first_verdict.verification_run_id}
  in
  let payment () =
    match List.filter_map (fun (event : Candle_event.t) -> match event.body with
      | Candle_event.Paid payment -> Some payment
      | Candle_event.Snapshot _ | Candle_event.Payout_owed _ | Candle_event.Candidates _
      | Candle_event.Unattributed _ | Candle_event.Payout_failed _
      | Candle_event.Half_life_set _ | Candle_event.Purchased _ | Candle_event.Equipped _ -> None) (ledger_events config)
    with
    | [payment] -> payment
    | _ -> fail "expected exactly one Paid fact"
  in
  let check_payment () =
    let paid = payment () in
    check bool "Paid retains the first exact confirmed identity" true
      (paid.identity = first_identity);
    check int "Small uses the explicit policy amount" 2000 paid.total_milli;
    check int "no due date means no late deduction" 1000 paid.coefficient;
    check (list (pair string int)) "only the contributing Keeper is paid"
      [keeper,2000]
      (List.map (fun (allocation : Candle_payment.allocation) ->
        allocation.keeper, allocation.amount_milli) paid.allocations);
    let balance = match Candle_balance.of_events ~at:(match Candle_stamp.at ~now:Time_compat.now with
      | Ok at -> at | Error detail -> fail detail) (ledger_events config) with
      | Ok balance -> balance
      | Error error -> fail (Candle_balance.error_to_string error)
    in
    check int "replayed Keeper balance is credited once" 2000
      (Candle_balance.balance balance ~keeper);
    check int "the Goal caller receives no currency" 0
      (Candle_balance.balance balance ~keeper:"planner")
  in
  let calls = ref [] in
  let grade_started, signal_grade_started = Eio.Promise.create () in
  let grade_release, release_grade = Eio.Promise.create () in
  let appraise ~identity request =
    (* The worker turns callback exceptions into Retry_later. Record entry
       before assertions so a rejected extra invocation cannot disappear. *)
    calls := A.stage request :: !calls;
    check bool "each model request names the confirmed proof" true (identity = first_identity);
    check int "Candidates are durable before any model request" 1 (count_kind config "candidates");
    let decision = match request with
      | A.Grade goal ->
        check string "grade reads the real Goal snapshot" "Ship the ledger" goal.title;
        Eio.Promise.resolve signal_grade_started ();
        Eio.Promise.await grade_release;
        A.Grade_decided Candle_grade.Small
      | A.Relation task ->
        check string "relation reads the persisted linked Task" task_title task.task_title;
        A.Relation_decided A.Related
      | A.Weights weights ->
        check (list string) "real Keeper configuration determines the recipient" [keeper] weights.keepers;
        check (list (pair string string)) "weights use the real Task assignee"
          [task_id,keeper]
          (List.map (fun (task : A.task) -> task.task_id,task.keeper) weights.tasks);
        A.Weights_decided [keeper,1]
    in
    Ok {A.decision;trace={run_id="paid-flow-" ^ A.stage request;slot_id="fixture.appraiser"}}
  in
  (* Failure bound for the fixture, not a worker retry policy. [idle] is the
     barrier for negative assertions, including confirmation retries. *)
  let await label predicate =
    try Eio.Time.with_timeout_exn clock 5. (fun () ->
      let rec loop () =
        if predicate () then () else (Eio.Fiber.yield (); loop ())
      in
      loop ())
    with Eio.Time.Timeout -> fail ("timed out waiting for " ^ label)
  in
  let idle () = await "the payout worker to finish its wake" Candle_payout_worker.For_testing.idle in
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise ~sw ~config;
    idle ();
    check (list string) "startup cannot appraise an unconfirmed proof" [] !calls;
    check rows_testable "before confirmation only the actual Snapshot exists"
      ["snapshot",goal_id,first_verdict.request_id] (rows config);
    confirmed config goal_id;
    await "Grade to start from the confirmation wake" (fun () -> Eio.Promise.is_resolved grade_started);
    check string "the HTTP confirmation completed the Goal" "completed" (phase config goal_id);
    check int "the held model has not paid yet" 0 (count_kind config "paid");
    confirmed config goal_id;
    check int "confirmation retry does not duplicate the pending obligation" 1
      (count_kind config "payout_owed");
    transition config goal_id "reopen";
    check string "the confirmed Goal can reopen before payment" "executing" (phase config goal_id);
    transition config goal_id "drop";
    check string "the Goal can drop while its payout is still pending" "dropped" (phase config goal_id);
    check int "phase changes happened before the payment" 0 (count_kind config "paid");
    Eio.Promise.resolve release_grade ();
    await "the confirmation wake to reach Paid" (fun () -> count_kind config "paid" = 1);
    idle ();
    check string "settling the durable obligation does not reopen the dropped Goal"
      "dropped" (phase config goal_id);
    check rows_testable "the complete positive path writes each fact once"
      [ "snapshot",goal_id,first_verdict.request_id
      ; "payout_owed",goal_id,first_verdict.request_id
      ; "candidates",goal_id,first_verdict.request_id
      ; "paid",goal_id,first_verdict.request_id ] (rows config);
    let payout_events = List.filter (fun (event : Candle_event.t) -> match event.body with
      | Candle_event.Half_life_set _ -> false
      | Candle_event.Snapshot _ | Candle_event.Payout_owed _ | Candle_event.Candidates _
      | Candle_event.Paid _ | Candle_event.Unattributed _ | Candle_event.Payout_failed _
      | Candle_event.Purchased _ | Candle_event.Equipped _ -> true) (ledger_events config) in
    (match payout_events with
     | [ {Candle_event.body=Candle_event.Snapshot snapshot;_}
       ; {Candle_event.body=Candle_event.Payout_owed owed;_}
       ; {Candle_event.body=Candle_event.Candidates candidates;_}
       ; {Candle_event.body=Candle_event.Paid _;_} ] ->
       check (list string) "the Snapshot captured the real Goal link" [task_id] snapshot.linked_task_ids;
       check (list string) "every preparation row keeps the verified run"
         [first_verdict.verification_run_id;first_verdict.verification_run_id;first_verdict.verification_run_id]
         [snapshot.verification_run_id;owed.verification_run_id;candidates.verification_run_id];
       check (list string) "the production reader selected the completed Task" [task_id] candidates.candidate_task_ids;
       check (list string) "the production reader selected its configured Keeper" [keeper] candidates.candidate_keepers;
       (match candidates.tasks with
        | [id,Candle_event.Found {assignee=Some assignee;status=Candle_event.Done done_task;_}] ->
          check string "the durable candidate names the real Task" task_id id;
          check string "the durable candidate keeps the real assignee" keeper assignee;
          check string "the durable candidate keeps the persisted completion" completed_at
            (Candle_time.to_rfc3339 done_task.completed_at);
          check bool "completion follows Goal creation" true
            (Candle_time.compare done_task.completed_at snapshot.goal_created_at > 0);
          check bool "completion precedes or equals confirmation" true
            (Candle_time.compare done_task.completed_at owed.confirmed_at <= 0)
        | _ -> fail "the production Candidates lost the persisted Done Task")
     | _ -> fail "the positive lifecycle did not retain its four authoritative facts");
    check_payment ();
    Candle_payout_worker.pulse ();
    idle ();
    check_payment ();
    transition config goal_id "reopen";
    transition config goal_id "request_complete";
    pass ~verification_run_id:"paid-flow-reopened-verifier" config goal_id;
    let second_verdict = current_verdict config goal_id in
    check bool "reopening creates a different proof request" false
      (second_verdict.request_id = first_verdict.request_id);
    confirmed config goal_id;
    Candle_payout_worker.pulse ();
    idle ();
    check string "the reopened Goal can complete again" "completed" (phase config goal_id);
    check int "re-verification retains a second Snapshot" 2 (count_kind config "snapshot");
    check int "reconfirmation/reopening never creates a second obligation" 1 (count_kind config "payout_owed");
    check int "settled contribution is not prepared again" 1 (count_kind config "candidates");
    check_payment ());
  let settled_ledger = In_channel.with_open_bin (ledger_path config) In_channel.input_all in
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise ~sw ~config;
    idle ();
    Candle_payout_worker.wake ();
    idle ();
    check_payment ());
  check string "worker restart and event replay append no further fact" settled_ledger
    (In_channel.with_open_bin (ledger_path config) In_channel.input_all);
  check (list string) "all lifecycle retries leave exactly three model requests"
    ["grade";"relation";"weights"] (List.rev !calls)
;;

let () =
  run
    "candle_goal_flow"
    [ ( "confirmation"
      , [ test_case "same-second retry uses the confirmed run Snapshot" `Quick
            test_same_second_retry_uses_the_confirmed_run_snapshot
        ; test_case "a confirmed pass leaves a payout owed" `Quick test_a_confirmed_pass_leaves_a_payout_owed
        ; test_case
            "without a candle.toml a confirmation writes nothing"
            `Quick
            test_without_a_candle_toml_a_confirmation_writes_nothing
        ; test_case
            "a pass from before candle owes nothing"
            `Quick
            test_a_pass_from_before_candle_owes_nothing
        ; test_case
            "a payout that cannot be written refuses the confirmation"
            `Quick
            test_a_payout_that_cannot_be_written_refuses_the_confirmation
        ; test_case
            "a reopened goal that passes again owes no second payout"
            `Quick
            test_a_reopened_goal_that_passes_again_owes_no_second_payout
        ; test_case
            "a refused confirmation that is reopened owes nothing"
            `Quick
            test_a_refused_confirmation_that_is_reopened_owes_nothing
        ; test_case
            "a phase that could not be saved after the row leaves one row"
            `Quick
            test_a_phase_that_could_not_be_saved_after_the_row_leaves_one_row
        ; test_case
            "a confirmation wakes the worker that prepares the payout"
            `Quick
            test_a_confirmation_wakes_the_worker_that_prepares_the_payout
        ; test_case
            "a confirmed Goal pays its Keeper once across reopen and restart"
            `Quick
            test_a_confirmed_goal_pays_its_keeper_once_across_reopen_and_restart
        ] )
    ]
;;
