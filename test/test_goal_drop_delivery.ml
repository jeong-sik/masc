open Alcotest

module Goals = Masc.Workspace_goals
module Hooks = Workspace_hooks

let rec remove_tree path =
  if Sys.is_directory path then (
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path

let config_at path =
  let config = Workspace_utils.default_config_uncached path in
  Fs_compat.mkdir_p (Workspace_utils.masc_dir config);
  config

let with_workspace run =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let path = Filename.temp_file "goal-drop-delivery-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  let config = config_at path in
  let abandoned = ref 0 in
  let old = Atomic.exchange Hooks.goal_verification_abandoned_fn
    (fun _ ~goal_id:_ -> incr abandoned) in
  Fun.protect ~finally:(fun () ->
    Atomic.set Hooks.goal_verification_abandoned_fn old;
    remove_tree path)
    (fun () -> run config abandoned (Eio.Stdenv.process_mgr env))

(* The fixture is written as stored state, so the audit ledger holds only
   the events the transition under test produces. *)
let create ?(phase = Goal_phase.Executing) config =
  let now = Masc_domain.now_iso () in
  let goal = { Goal_store.id = "goal-drop-delivery"; criterion_revision = "fixture-criterion";
    title = "Preserve cancellation audit"; measure = Goal_measure_fixture.done_when "1";
    procedure = "cancelled Goals with audit"; due_date = None; priority = 3; phase;
    last_review_note = None; last_review_at = None; created_at = now; updated_at = now } in
  Goal_store.write_state config
    { version = 1; updated_at = now; goals = [goal]; pending_events = []; pending_notifications = [] };
  goal

let drop config ?note goal_id =
  let ctx : Masc.Workspace_types.context = {config; agent_name="operator"} in
  Goals.handle_goal_transition ~tool_name:"masc_goal_transition"
    ~start_time:(Tool_timing.start ()) ctx
    (`Assoc (["goal_id", `String goal_id; "action", `String "drop"]
      @ match note with None -> [] | Some value -> ["note", `String value]))

let success result =
  if not (Tool_result.is_success result) then fail (Tool_result.message result);
  Yojson.Safe.from_string (Tool_result.message result)

let saved config =
  match Goal_store.load_source config with
  | Goal_store.Available state -> state
  | Uninitialized -> fail "missing Goal store"
  | Unavailable failure -> fail (Goal_store.unavailable_to_string failure)

let audit_path config = Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl"
let events config =
  Fs_compat.load_file (audit_path config) |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "") |> List.map Yojson.Safe.from_string

let member name json = Yojson.Safe.Util.member name json
let text name json = member name json |> Yojson.Safe.Util.to_string

let check_delivered_once config goal event_id =
  let rows = events config in
  check int "one committed cancellation event" 1 (List.length rows);
  let row = List.hd rows in
  check string "same durable event identity" event_id (text "event_id" row);
  check string "cancelled Goal" goal.Goal_store.id (text "goal_id" row);
  check string "event kind" "goal_phase" (text "event_type" row);
  check string "recorded phase" "dropped" (member "payload" row |> text "phase");
  check string "recorded actor" "operator" (member "payload" row |> text "actor");
  check int "outbox acknowledged" 0 (List.length (saved config).pending_events)

let obstruct_audit config = Unix.mkdir (audit_path config) 0o700
let restore_audit config = Unix.rmdir (audit_path config)

let committed_pending config goal response =
  check string "commit reported separately from delivery" "deferred"
    (member "effect_delivery" response |> text "status");
  let state = saved config in
  let current = List.find (fun g -> g.Goal_store.id = goal.Goal_store.id) state.goals in
  check string "Goal is durably cancelled" "dropped" (Goal_phase.to_string current.phase);
  check (option string) "reason is durable" (Some "operator cancellation") current.last_review_note;
  match state.pending_events with
  | [event] -> event.Goal_store.event_id
  | _ -> fail "cancellation lost its durable audit intent"

let test_repeat_repairs_audit () = with_workspace @@ fun config abandoned _ ->
  let goal = create config in
  obstruct_audit config;
  let response = drop config ~note:"operator cancellation" goal.id |> success in
  let event_id = committed_pending config goal response in
  check int "verifier cancellation notified once" 1 !abandoned;
  restore_audit config;
  let repeated = drop config ~note:"must not replace the original reason" goal.id |> success in
  check bool "repeat is a lifecycle no-op" true (member "noop" repeated |> Yojson.Safe.Util.to_bool);
  check string "repeat repairs pending delivery" "delivered"
    (member "effect_delivery" repeated |> text "status");
  check_delivered_once config goal event_id;
  let current = List.find (fun g -> g.Goal_store.id = goal.id) (saved config).goals in
  check (option string) "repeat preserves the original cancellation reason"
    (Some "operator cancellation") current.last_review_note;
  let before = Fs_compat.load_file (Goal_store.goals_path config) in
  ignore (drop config ~note:"settled repeat" goal.id |> success);
  check string "settled repeat does not rewrite the Goal" before
    (Fs_compat.load_file (Goal_store.goals_path config));
  check int "repeats do not notify verifier again" 1 !abandoned;
  check_delivered_once config goal event_id

let test_restart_recovers_after_goal_deletion () = with_workspace @@ fun config _ process_mgr ->
  let goal = create config in
  obstruct_audit config;
  let response = drop config ~note:"operator cancellation" goal.id |> success in
  let event_id = committed_pending config goal response in
  (match Goal_store.delete_goal config ~goal_id:goal.id with
   | Ok _ -> () | Error error -> fail (Goal_store.delete_goal_error_to_string error));
  restore_audit config;
  Eio.Process.run process_mgr
    [Sys.executable_name; "--flush-goal-delivery"; config.base_path];
  check_delivered_once config goal event_id;
  check int "deleted Goal remains deleted" 0 (List.length (saved config).goals)

let test_failed_commit_has_no_effect () = with_workspace @@ fun config abandoned _ ->
  let goal = create config in
  let path = Goal_store.goals_path config in
  let before = Fs_compat.load_file path in
  (* Take the Goal lock once so its lock file exists before the directory
     turns read-only; the drop then fails at its state write. *)
  (match Goal_store.transact_goal config ~goal_id:goal.id (fun current -> Ok (current, ())) with
   | Ok _ -> () | Error error -> fail (Goal_store.write_error_to_string error));
  let directory = Filename.dirname path in
  Unix.chmod directory 0o500;
  let result = Fun.protect ~finally:(fun () -> Unix.chmod directory 0o700)
    (fun () -> drop config ~note:"operator cancellation" goal.id) in
  check bool "failed state commit is a failure" false (Tool_result.is_success result);
  check string "primary unchanged" before (Fs_compat.load_file path);
  check int "no cancellation hook before commit" 0 !abandoned;
  check int "no intent before commit" 0 (List.length (saved config).pending_events);
  check bool "no fabricated audit" false (Sys.file_exists (audit_path config))

let test_unavailable_is_not_a_drop () = with_workspace @@ fun config abandoned _ ->
  let goal = create config in
  let path = Goal_store.goals_path config in
  Fs_compat.save_file path "{broken";
  let result = drop config ~note:"operator cancellation" goal.id in
  check bool "unreadable primary is refused" false (Tool_result.is_success result);
  check string "corrupt primary is preserved" "{broken" (Fs_compat.load_file path);
  check int "no verifier cancellation" 0 !abandoned;
  check bool "no audit on failed read" false (Sys.file_exists (audit_path config))

let test_missing_goal_is_not_created () = with_workspace @@ fun config abandoned _ ->
  let result = drop config ~note:"operator cancellation" "goal-missing" in
  check bool "missing Goal is refused" false (Tool_result.is_success result);
  check bool "no Goal invented" false (Sys.file_exists (Goal_store.goals_path config));
  check int "no verifier cancellation" 0 !abandoned

(* {1 Confirmation, completion request and reopen}

   Each of these phase moves commits its audit event as an intent in the same
   Goal write. While the ledger refuses the append the intent stays pending,
   and delivery after the ledger works again writes that one event. *)

let transition config goal_id action =
  let ctx : Masc.Workspace_types.context = {config; agent_name="operator"} in
  Goals.handle_goal_transition ~tool_name:"masc_goal_transition"
    ~start_time:(Tool_timing.start ()) ctx
    (`Assoc ["goal_id", `String goal_id; "action", `String action])

let committed_phase_pending config (goal : Goal_store.goal) phase =
  let state = saved config in
  let current = List.find (fun g -> g.Goal_store.id = goal.id) state.goals in
  check string "phase is durably committed" phase (Goal_phase.to_string current.phase);
  match state.pending_events with
  | [event] -> event.Goal_store.event_id
  | pending -> failf "expected one pending audit intent, found %d" (List.length pending)

let check_phase_delivered_once config (goal : Goal_store.goal) ~phase event_id =
  check bool "the audit ledger was written" true (Sys.file_exists (audit_path config));
  let rows = events config in
  check int "one audit row" 1 (List.length rows);
  let row = List.hd rows in
  check string "same durable event identity" event_id (text "event_id" row);
  check string "event names its Goal" goal.id (text "goal_id" row);
  check string "event kind" "goal_phase" (text "event_type" row);
  check string "recorded phase" phase (member "payload" row |> text "phase");
  check string "recorded actor" "operator" (member "payload" row |> text "actor");
  check int "outbox acknowledged" 0 (List.length (saved config).pending_events)

(* A proven completion written straight into the verification ledger: the
   proof steps of a real run would already have put rows in the audit ledger. *)
let proven config (goal : Goal_store.goal) : Goal_verification.verdict =
  let criterion = Goal_store.criterion_of_goal goal in
  let request_id =
    match Goal_verification.mark_proof_pending config ~goal_id:goal.id ~criterion with
    | Ok { Goal_verification.completion = Goal_verification.Proof_pending { request_id; _ }; _ } ->
        request_id
    | Ok _ -> fail "proof request is not pending"
    | Error detail -> fail detail in
  let verdict : Goal_verification.verdict =
    { outcome = Goal_verification.Proven; request_id; criterion;
      verification_run_id = "fixture-verifier-run";
      authority = Masc_domain.System_llm_agent { agent_run_id = "fixture-verifier" };
      evidence = "fixture evidence"; recorded_at = Masc_domain.now_iso () } in
  (match Goal_verification.record_proof_verdict config ~goal_id:goal.id verdict with
   | Ok _ -> () | Error detail -> fail detail);
  verdict

let test_confirmation_keeps_its_audit_event () = with_workspace @@ fun config _ _ ->
  let goal = create ~phase:Goal_phase.Awaiting_confirmation config in
  let verdict = proven config goal in
  let confirm () =
    match Goals.confirm_completion config ~goal_id:goal.id ~operator_id:"operator"
            ~request_id:verdict.request_id ~verification_run_id:verdict.verification_run_id
            ~criterion_revision:goal.criterion_revision with
    | Ok json -> json
    | Error error -> fail (Goal_store.write_error_to_string error) in
  obstruct_audit config;
  let first = confirm () in
  check string "confirmation answers the completed Goal" "completed"
    (member "goal" first |> text "phase");
  check string "commit reported separately from delivery" "deferred"
    (member "effect_delivery" first |> text "status");
  let event_id = committed_phase_pending config goal "completed" in
  restore_audit config;
  (* The same confirmation again finds the Goal completed and drains the outbox. *)
  check string "the repeat reports the delivery" "delivered"
    (member "effect_delivery" (confirm ()) |> text "status");
  check_phase_delivered_once config goal ~phase:"completed" event_id;
  check string "event names the confirmed proof request" verdict.request_id
    (member "payload" (List.hd (events config)) |> text "request_id");
  let before = Fs_compat.load_file (Goal_store.goals_path config) in
  ignore (confirm ());
  check string "settled repeat does not rewrite the Goal" before
    (Fs_compat.load_file (Goal_store.goals_path config));
  check_phase_delivered_once config goal ~phase:"completed" event_id

let test_completion_request_keeps_its_audit_event () = with_workspace @@ fun config _ _ ->
  let goal = create config in
  let wakes = ref 0 in
  let old = Atomic.exchange Hooks.goal_verification_pending_fn (fun _ ~goal_id:_ -> incr wakes) in
  Fun.protect ~finally:(fun () -> Atomic.set Hooks.goal_verification_pending_fn old) @@ fun () ->
  obstruct_audit config;
  let response = transition config goal.id "request_complete" |> success in
  check string "commit reported separately from delivery" "deferred"
    (member "effect_delivery" response |> text "status");
  let event_id = committed_phase_pending config goal "verifying" in
  check int "verification is woken although the ledger refused the event" 1 !wakes;
  restore_audit config;
  (* The maintenance pass drains the outbox with this same call. *)
  (match Goal_delivery.flush config with Ok () -> () | Error detail -> fail detail);
  check_phase_delivered_once config goal ~phase:"verifying" event_id

let test_reopen_keeps_its_audit_event () = with_workspace @@ fun config abandoned _ ->
  let goal = create ~phase:Goal_phase.Dropped config in
  obstruct_audit config;
  let response = transition config goal.id "reopen" |> success in
  check string "commit reported separately from delivery" "deferred"
    (member "effect_delivery" response |> text "status");
  let event_id = committed_phase_pending config goal "executing" in
  check int "verifier cancellation notified once" 1 !abandoned;
  restore_audit config;
  let repeated = transition config goal.id "reopen" |> success in
  check bool "repeat is a lifecycle no-op" true (member "noop" repeated |> Yojson.Safe.Util.to_bool);
  check string "the repeat reports the delivery" "delivered"
    (member "effect_delivery" repeated |> text "status");
  check_phase_delivered_once config goal ~phase:"executing" event_id;
  check int "repeat does not notify the verifier again" 1 !abandoned

(* A reopen that has a proof to archive queues [goal_proof_reopened] ahead of
   the reopened [goal_phase] event in the single Goal outbox transaction.
   While the ledger refuses appends, reopen still commits once with both
   intents pending; once the ledger works again, repeat reopen drains the
   outbox in commit order without double-writing any revision (#53259). *)
let test_reopen_with_a_proof_keeps_its_archive_event () = with_workspace @@ fun config abandoned _ ->
  let goal = create config in
  let old = Atomic.exchange Hooks.goal_verification_pending_fn (fun _ ~goal_id:_ -> ()) in
  Fun.protect ~finally:(fun () -> Atomic.set Hooks.goal_verification_pending_fn old) @@ fun () ->
  obstruct_audit config;
  ignore (transition config goal.id "request_complete" |> success);
  let version_after_request = (saved config).version in
  let requested = committed_phase_pending config goal "verifying" in
  let reopened = transition config goal.id "reopen" |> success in
  check string "commit reported separately from delivery" "deferred"
    (member "effect_delivery" reopened |> text "status");
  let after_reopen = saved config in
  let current = List.find (fun g -> g.Goal_store.id = goal.id) after_reopen.goals in
  check string "reopened Goal is durably executing" "executing"
    (Goal_phase.to_string current.phase);
  (match Goal_verification.get_record_authoritative config ~goal_id:goal.id with
   | Ok (Some { Goal_verification.completion = Goal_verification.Completion_idle; _ }) -> ()
   | Ok _ -> fail "expected Completion_idle after reopen"
   | Error detail -> fail detail);
  check int "reopen advances Goal version once" (version_after_request + 1) after_reopen.version;
  check (list string) "outbox queues pending events in commit order"
    ["goal_phase"; "goal_proof_reopened"; "goal_phase"]
    (List.map (fun (e : Goal_store.pending_event) ->
       Goal_store.event_kind_to_string e.kind) after_reopen.pending_events);
  check (list int) "pending events carry their single commit revisions"
    [version_after_request; version_after_request + 1; version_after_request + 1]
    (List.map (fun (e : Goal_store.pending_event) -> e.Goal_store.store_revision)
       after_reopen.pending_events);
  check int "verifier cancellation notified once" 1 !abandoned;
  restore_audit config;
  let repeated = transition config goal.id "reopen" |> success in
  check bool "repeat is a lifecycle no-op" true (member "noop" repeated |> Yojson.Safe.Util.to_bool);
  check string "reopen reports its delivery" "delivered"
    (member "effect_delivery" repeated |> text "status");
  let rows = events config in
  check (list string) "ledger rows follow the commit order"
    ["goal_phase"; "goal_proof_reopened"; "goal_phase"] (List.map (text "event_type") rows);
  check (list string) "each row records its phase" ["verifying"; "executing"; "executing"]
    (List.map (fun row -> member "payload" row |> text "phase") rows);
  check string "the request event kept its identity" requested (text "event_id" (List.hd rows));
  check (list int) "ledger rows carry distinct commit revisions"
    [version_after_request; version_after_request + 1; version_after_request + 1]
    (List.map (fun row -> member "store_revision" row |> Yojson.Safe.Util.to_int) rows);
  let after_flush = saved config in
  check int "outbox acknowledged" 0 (List.length after_flush.pending_events);
  check int "outbox ack advances Goal version once" (version_after_request + 2) after_flush.version;
  check int "verifier cancellation still notified once" 1 !abandoned

(* Regression for #53259: when an earlier pending intent is already queued
   and the ledger recovers before [reopen], [reopen] commits once at V+1 and
   outbox ack commits at V+2, rather than flushing inside the callback and
   overwriting V+1 with a re-queued intent. *)
let test_reopen_with_pending_outbox_assigns_distinct_revisions () =
  with_workspace @@ fun config abandoned _ ->
  let goal = create config in
  let old = Atomic.exchange Hooks.goal_verification_pending_fn (fun _ ~goal_id:_ -> ()) in
  Fun.protect ~finally:(fun () -> Atomic.set Hooks.goal_verification_pending_fn old) @@ fun () ->
  obstruct_audit config;
  ignore (transition config goal.id "request_complete" |> success);
  let version_after_request = (saved config).version in
  let requested = committed_phase_pending config goal "verifying" in
  restore_audit config;
  let response = transition config goal.id "reopen" |> success in
  check string "reopen delivers prior pending intent and reopen events" "delivered"
    (member "effect_delivery" response |> text "status");
  let rows = events config in
  check (list string) "ledger rows follow the commit order"
    ["goal_phase"; "goal_proof_reopened"; "goal_phase"] (List.map (text "event_type") rows);
  check string "the request event kept its identity" requested (text "event_id" (List.hd rows));
  check (list int) "ledger rows carry distinct commit revisions"
    [version_after_request; version_after_request + 1; version_after_request + 1]
    (List.map (fun row -> member "store_revision" row |> Yojson.Safe.Util.to_int) rows);
  let final_state = saved config in
  check int "outbox acknowledged" 0 (List.length final_state.pending_events);
  check int "final version includes commit V+1 and ack V+2" (version_after_request + 2)
    final_state.version;
  check int "verifier cancellation notified once" 1 !abandoned

let () =
  if Array.length Sys.argv = 3 && Sys.argv.(1) = "--flush-goal-delivery" then (
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    match Goal_delivery.flush (config_at Sys.argv.(2)) with
    | Ok () -> () | Error detail -> prerr_endline detail; exit 1)
  else
    run "Goal cancellation delivery"
      ["durability", [
        test_case "repeat repairs committed audit exactly once" `Quick test_repeat_repairs_audit;
        test_case "fresh process drains audit after Goal deletion" `Quick test_restart_recovers_after_goal_deletion;
        test_case "failed commit creates no effects" `Quick test_failed_commit_has_no_effect;
        test_case "unavailable primary remains unchanged" `Quick test_unavailable_is_not_a_drop;
        test_case "missing Goal remains missing" `Quick test_missing_goal_is_not_created];
       "phase event outbox", [
        test_case "confirmation keeps its audit event while the ledger refuses it" `Quick
          test_confirmation_keeps_its_audit_event;
        test_case "completion request keeps its audit event while the ledger refuses it" `Quick
          test_completion_request_keeps_its_audit_event;
        test_case "reopen keeps its audit event while the ledger refuses it" `Quick
          test_reopen_keeps_its_audit_event;
        test_case "reopen with a proof queues archive in the outbox while ledger refuses it" `Quick
          test_reopen_with_a_proof_keeps_its_archive_event;
        test_case "reopen with pending outbox assigns distinct commit revisions" `Quick
          test_reopen_with_pending_outbox_assigns_distinct_revisions]]
