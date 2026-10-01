(* Confirmed obligations and durable Candidates go through the production
   payout worker. Only the model/source edges are controlled by these tests. *)
open Alcotest
open Masc
module A = Candle_appraisal
module E = Candle_event
module Runs = Exact_lane_run_registry

let () =
  Mirage_crypto_rng_unix.use_default ();
  Prompt_defaults.init ();
  Prompt_registry.set_markdown_dir "../config/prompts"
let ok = function Ok value -> value | Error detail -> fail detail
let at text = ok (Candle_time.of_rfc3339 text)
let now () = 1_790_700_000.
let passed_at = at "2026-09-28T06:32:00Z"
let confirmed_at = at "2026-09-29T05:00:00Z"

let with_workspace f =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Candle_status.install_appraiser_check (fun () -> Ok ());
  let base_path = Filename.temp_dir "candle-appraisal-flow-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path; Fs_compat.clear_fs ())
    (fun () ->
      let config = Workspace.default_config base_path in
      ignore (Workspace.init config ~agent_name:(Some "planner"));
      let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path in
      if not (String.starts_with ~prefix:base_path path) then fail "fixture escaped its workspace";
      Fs_compat.mkdir_p (Filename.dirname path);
      Fs_compat.save_file path {|[payout]
weight_max = 10
deduction_rate = 10
deduction_floor = 200
[payout.grades_milli]
trivial = 1000
small = 2000
medium = 3001
large = 4000
epic = 5000
|};
      f env config)

let append config rows =
  match Candle_ledger.update ~base_path:config.Workspace.base_path (fun _ -> Ok (rows, ())) with
  | Ok () -> ()
  | Error error -> fail (Candle_ledger.update_error_to_string Fun.id error)

let events config =
  match Candle_ledger.read ~base_path:config.Workspace.base_path with
  | Ok view -> Candle_ledger.events view
  | Error error -> fail (Candle_ledger.read_error_to_string error)

let obligation ?(request = "request-1") ?(run = "verification-1")
    ?(due_date = Some "2026-09-26") goal_id : Candle_payout.waiting * E.t list =
  let waiting : Candle_payout.waiting =
    {goal_id;request_id=request;verification_run_id=run;passed_at;confirmed_at} in
  waiting,
  [ {E.at=passed_at;body=E.Snapshot
      {goal_id;request_id=request;verification_run_id=run;criterion_revision="criterion-1";
       passed_at;goal_created_at=at "2026-09-20T00:00:00Z";due_date;
       title="Ship the ledger";metric=Some "accepted scenarios";target_value=Some "10";
       linked_task_ids=["task-a";"task-b";"external";"old";"pending"]}}
  ; {E.at=confirmed_at;body=E.Payout_owed
      {goal_id;request_id=request;verification_run_id=run;passed_at;confirmed_at}} ]

let found title assignee status = E.Found {title;assignee=Some assignee;status}
let done_at = at "2026-09-25T00:00:00Z"
let task_rows =
  [ "task-a", found "Store the ledger" "keeper-a" (E.Done {completed_at=done_at})
  ; "task-b", found "Test the ledger" "keeper-b" (E.Done {completed_at=done_at})
  ; "external", found "Operator's contribution" "external-operator" (E.Done {completed_at=done_at})
  ; "old", found "Unrelated older work" "keeper-a" (E.Done {completed_at=at "2026-09-19T00:00:00Z"})
  ; "pending", found "Still running" "keeper-b" E.In_progress ]

let prepare ?(keepers = ["keeper-a";"keeper-b"]) config =
  let sources : Candle_candidates.sources =
    {task_lookups=(fun ~goal_id:_ ids -> Ok (List.map (fun id -> id, List.assoc id task_rows) ids));
     is_keeper=(fun () -> Ok (fun name -> List.mem name keepers))} in
  Candle_candidates.drain_with ~sources ~now ~base_path:config.Workspace.base_path |> ok

let prepared ?request ?run ?due_date config goal_id =
  let waiting, rows = obligation ?request ?run ?due_date goal_id in
  append config rows;
  ignore (prepare config);
  waiting

let paid config goal_id =
  List.filter_map (fun (event : E.t) -> match event.body with
    | E.Paid payment when payment.identity.goal_id = goal_id -> Some payment
    | E.Paid _ | E.Snapshot _ | E.Payout_owed _ | E.Candidates _
    | E.Unattributed _ | E.Equipped _ | E.Purchased _ | E.Payout_failed _ -> None) (events config)

let one_payment config goal_id = match paid config goal_id with
  | [payment] -> payment | _ -> fail "expected exactly one Paid row"

let drain config appraise =
  Candle_appraise.drain_once ~now ~appraise ~base_path:config.Workspace.base_path |> ok

let trace ?(slot = "fixture.slot") id : A.trace = {run_id=id;slot_id=slot}
let make_runner ?(relation = fun _ -> A.Related) ?(weight = fun name -> if name="keeper-a" then 2 else 1) calls
    ~(identity : A.identity) request =
  let step = List.length !calls + 1 in
  calls := !calls @ [identity, request];
  let decision = match request with
    | A.Grade _ -> A.Grade_decided Candle_grade.Medium
    | A.Relation r -> A.Relation_decided (relation r.task_title)
    | A.Weights w -> A.Weights_decided (List.map (fun name -> name, weight name) w.keepers) in
  Ok {A.decision;trace=trace ~slot:("fixture." ^ A.stage request) (identity.goal_id ^ ":" ^ string_of_int step)}

(* The timeout is a test harness failure bound, never a payout retry policy. *)
let await env label predicate =
  try Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () ->
    let rec loop () = if predicate () then () else (Eio.Fiber.yield (); loop ()) in loop ())
  with Eio.Time.Timeout -> fail ("timed out waiting for " ^ label)

let idle env = await env "the worker to consume its wake" Candle_payout_worker.For_testing.idle

let test_worker_pays_once_with_isolated_inputs_and_integer_evidence () =
  with_workspace @@ fun env config ->
  let waiting = prepared config "paid-once" in
  let calls = ref [] in
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~sw ~config ~appraise:(make_runner calls);
    await env "Paid" (fun () -> paid config waiting.goal_id <> []);
    idle env;
    Candle_payout_worker.wake ();
    idle env);
  let p = one_payment config waiting.goal_id in
  check string "payment names the confirmed verifier" waiting.verification_run_id p.identity.verification_run_id;
  check int "grade amount comes from explicit policy" 3001 p.total_milli;
  check int "only the confirmed pass determines lateness" 30 p.overdue_hours;
  check int "30 hours gives a 700/1000 coefficient" 700 p.coefficient;
  check (list (triple string int int)) "remainder precedes per-recipient deduction"
    ["keeper-a",2001,1400;"keeper-b",1000,700]
    (List.map (fun (a : Candle_payment.allocation) -> a.keeper,a.share_milli,a.amount_milli) p.allocations);
  check (list string) "grade, each eligible Task, then weights, exactly once"
    ["grade";"relation";"relation";"relation";"weights"]
    (List.map (fun (_, request) -> A.stage request) !calls);
  List.iter (fun (identity, _) -> check string "judgment keeps payout identity"
    waiting.verification_run_id identity.A.verification_run_id) !calls;
  (match List.map snd !calls with
   | A.Grade goal :: A.Relation first :: A.Relation second :: A.Relation third :: [A.Weights weights] ->
     let keys json = Yojson.Safe.Util.to_assoc json |> List.map fst |> List.sort String.compare in
     check (list string) "grade sees no Task, identity, cost or priority" ["goal"] (keys (A.input (A.Grade goal)));
     check (list string) "relation sees only one title and the Goal"
       ["goal";"task_title"] (keys (A.input (A.Relation first)));
     check (list string) "only completion-window tasks are judged"
       ["Store the ledger";"Test the ledger";"Operator's contribution"]
       [first.task_title;second.task_title;third.task_title];
     check (list string) "non-Keeper assignee never enters weights" ["keeper-a";"keeper-b"] weights.keepers;
     check (list string) "old and pending work cannot affect distribution"
       ["task-a";"task-b"] (List.map (fun (task : A.task) -> task.task_id) weights.tasks)
   | _ -> fail "appraisal stage order or isolation changed");
  check string "grade trace survives" "paid-once:1" p.grade_trace.run_id;
  check string "weights trace survives" "paid-once:5" p.weights_trace.run_id;
  check string "grade answering slot survives" "fixture.grade" p.grade_trace.slot_id;
  check string "weights answering slot survives" "fixture.weights" p.weights_trace.slot_id;
  check (list string) "each relation keeps its answering slot"
    ["fixture.relation";"fixture.relation";"fixture.relation"]
    (List.map (fun (r : A.task_relation) -> r.trace.slot_id) p.relations);
  check (list string) "all relation traces survive"
    ["paid-once:2";"paid-once:3";"paid-once:4"]
    (List.map (fun (r : A.task_relation) -> r.trace.run_id) p.relations);
  let decoded = Candle_payment.of_yojson (Candle_payment.to_yojson p) |> ok in
  check bool "ledger decode replays the same integer calculation" true (decoded = p)

let test_invalid_weights_wait_for_an_event_not_a_pulse () =
  with_workspace @@ fun env config ->
  ignore (prepared config "rejected");
  let accept = ref false in
  let calls = ref [] in
  let runner ~identity request = match request with
    | A.Weights _ when not !accept ->
      calls := !calls @ [identity, request];
      (* The payout boundary validates even a transport's typed answer. *)
      Ok {A.decision=A.Weights_decided ["outsider",1];trace=trace "invalid-weights"}
    | A.Grade _ | A.Relation _ | A.Weights _ -> make_runner calls ~identity request in
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~sw ~config ~appraise:runner;
    await env "refused weights" (fun () -> List.exists (fun (_, r) -> A.stage r="weights") !calls);
    idle env;
    let rejected_calls = List.length !calls in
    check int "invalid weights mint nothing" 0 (List.length (paid config "rejected"));
    Candle_payout_worker.pulse ();
    idle env;
    check int "pulse does not repeat rejected model input" rejected_calls (List.length !calls);
    accept := true;
    Candle_payout_worker.wake ();
    await env "event retry settlement" (fun () -> paid config "rejected" <> []);
    idle env);
  ignore (one_payment config "rejected")

let test_transport_recovery_is_retried_by_pulse () =
  with_workspace @@ fun env config ->
  ignore (prepared config "transport");
  let available = ref false in
  let attempted = ref false in
  let calls = ref [] in
  let runner ~identity request =
    attempted := true;
    if !available then make_runner calls ~identity request
    else Error (A.Transport_unavailable "fixture binding is resting") in
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~sw ~config ~appraise:runner;
    await env "transport deferral" (fun () -> !attempted);
    idle env;
    available := true;
    Candle_payout_worker.pulse ();
    await env "transport recovery" (fun () -> paid config "transport" <> []);
    idle env);
  ignore (one_payment config "transport")

let test_unrelated_and_external_only_work_mint_nothing () =
  with_workspace @@ fun _env config ->
  ignore (prepared config "unrelated");
  let calls = ref [] in
  ignore (drain config (make_runner ~relation:(fun _ -> A.Unrelated) calls));
  check int "unrelated work receives no payment" 0 (List.length (paid config "unrelated"));
  check bool "no weights call without related work" false
    (List.exists (fun (_, request) -> A.stage request="weights") !calls);
  (match List.rev (events config) with
   | {E.body=E.Unattributed {reason=E.All_unrelated _;_};_} :: _ -> ()
   | _ -> fail "unrelated contribution did not settle explicitly");
  let _, rows = obligation "external-only" in
  append config rows;
  ignore (prepare ~keepers:[] config);
  let prior_calls = List.length !calls in
  ignore (drain config (make_runner calls));
  check int "no Keeper means no model call" prior_calls (List.length !calls);
  check int "external-only work receives no payment" 0 (List.length (paid config "external-only"));
  (match Candle_payout.state ~goal_id:"external-only" (events config) with
   | Candle_payout.Settled -> () | _ -> fail "external-only contribution stayed open")

let test_unreadable_due_date_fails_once_and_a_new_pass_can_repair_it () =
  with_workspace @@ fun _env config ->
  let failed = prepared ~due_date:(Some "2026-9-26") config "due-repair" in
  let calls = ref [] in
  ignore (drain config (make_runner calls));
  check int "unreadable due date calls no model" 0 (List.length !calls);
  (match Candle_payout.state ~goal_id:failed.goal_id (events config) with
   | Candle_payout.Failed current -> check string "failure names exact run" failed.verification_run_id current.verification_run_id
   | _ -> fail "bad due date was not an explicit failed payout");
  let before_retry = List.length (events config) in
  ignore (drain config (make_runner calls));
  check int "same failed obligation writes no repeated row" before_retry (List.length (events config));
  check bool "same confirmation cannot owe the failed run again" true
    (Option.is_none (Candle_payout.owed_pass ~goal_id:failed.goal_id ~request_id:failed.request_id
      ~verification_run_id:failed.verification_run_id ~passed_at:(Candle_time.to_rfc3339 passed_at) (events config)));
  let next, rows = obligation ~request:"repaired-request" ~run:"repaired-verification" ~due_date:None failed.goal_id in
  (match rows with
   | snapshot :: owed :: [] ->
     append config [snapshot];
     check bool "new corrected Snapshot can owe a payout" true
       (Option.is_some (Candle_payout.owed_pass ~goal_id:next.goal_id ~request_id:next.request_id
         ~verification_run_id:next.verification_run_id ~passed_at:(Candle_time.to_rfc3339 passed_at) (events config)));
     append config [owed]
   | _ -> fail "invalid fixture");
  ignore (prepare config);
  ignore (drain config (make_runner calls));
  let payment = one_payment config failed.goal_id in
  check string "repair pays the new exact run" next.verification_run_id payment.identity.verification_run_id;
  check int "corrected no-due policy removes penalty" 1000 payment.coefficient

let test_arithmetic_alone_cannot_authorize_an_outsider () =
  with_workspace @@ fun _env config ->
  let waiting = prepared config "forged" in
  let identity : A.identity = {goal_id=waiting.goal_id;request_id=waiting.request_id;verification_run_id=waiting.verification_run_id} in
  let relations = List.map (fun task_id -> {A.task_id;relation=A.Related;trace=trace task_id})
      ["task-a";"task-b";"external"] in
  let forged = Candle_payment.make ~identity ~grade:Candle_grade.Medium ~total_milli:3001
      ~grade_trace:(trace "grade") ~relations ~weights_trace:(trace "weights")
      ~weight_max:10 ~deduction_rate:10 ~deduction_floor:200 ~overdue_hours:30 ~weights:["outsider",1] |> ok in
  let result = Candle_ledger.update ~base_path:config.base_path (fun view ->
    Result.map (fun () -> [{E.at=confirmed_at;body=E.Paid forged}], ())
      (Candle_payout.validate_settlement waiting (Candle_ledger.events view) (E.Paid forged))) in
  (match result with Error (Candle_ledger.Refused _) -> () | _ -> fail "outsider was admitted by valid arithmetic");
  check int "no forged Paid row reaches the ledger" 0 (List.length (paid config waiting.goal_id))

let test_disable_during_appraisal_preserves_the_obligation () =
  List.iter (fun remove_file ->
    with_workspace @@ fun _env config ->
    let waiting = prepared config "disabled-during-call" in
    let calls = ref [] in
    let runner ~identity request =
      (match request with
       | A.Weights _ ->
         let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path:config.base_path in
         if remove_file then Sys.remove path else Fs_compat.save_file path "invalid = true\n"
       | A.Grade _ | A.Relation _ -> ());
      make_runner calls ~identity request in
    (match drain config runner with
     | [Candle_appraise.Retry_later _] -> ()
     | _ -> fail "disabled Candle accepted a settlement");
    check int "an accepted model answer cannot override disable" 0 (List.length (paid config waiting.goal_id));
    (match Candle_payout.state ~goal_id:waiting.goal_id (events config) with
     | Candle_payout.Waiting current -> check bool "the original obligation survives" true (current=waiting)
     | _ -> fail "disable consumed the obligation")) [true;false]

let test_cumulative_overflow_refuses_the_real_settlement () =
  with_workspace @@ fun env config ->
  let historical_amount = max_int / 1000 in
  let history = List.init 1000 (fun i ->
    let payment = Candle_payment.make
      ~identity:{A.goal_id="past-" ^ string_of_int i;request_id="past-request";verification_run_id="past-run"}
      ~grade:Candle_grade.Epic ~total_milli:historical_amount
      ~grade_trace:(trace "past-grade")
      ~relations:[{A.task_id="past-task";relation=A.Related;trace=trace "past-relation"}]
      ~weights_trace:(trace "past-weights") ~weight_max:1 ~deduction_rate:0
      ~deduction_floor:1000 ~overdue_hours:0 ~weights:["keeper-a",1] |> ok in
    {E.at=confirmed_at;body=E.Paid payment}) in
  append config history;
  let waiting = prepared config "overflow" in
  let calls = ref [] in
  (match drain config (make_runner calls) with
   | [Candle_appraise.Rejected _] -> ()
   | _ -> fail "overflowing appraisal was not refused");
  check bool "the actual appraisal reached its weight answer" true
    (List.exists (fun (_, request) -> A.stage request="weights") !calls);
  check int "the new payment was not appended" 0 (List.length (paid config waiting.goal_id));
  let balance = match Candle_balance.of_events (events config) with
    | Ok balance -> balance | Error error -> fail (Candle_balance.error_to_string error) in
  check int "prior money stays exact" (historical_amount * 1000)
    (Candle_balance.balance balance ~keeper:"keeper-a");
  check int "no other recipient receives a partial credit" 0 (Candle_balance.balance balance ~keeper:"keeper-b");
  (match Candle_payout.state ~goal_id:waiting.goal_id (events config) with
   | Candle_payout.Waiting _ -> () | _ -> fail "overflow consumed the obligation");
  Eio.Switch.run (fun sw ->
    let started_calls = List.length !calls in
    Candle_payout_worker.start ~sw ~config ~appraise:(make_runner calls);
    await env "overflow refusal in the worker" (fun () -> List.length !calls > started_calls);
    idle env;
    let refused_calls = List.length !calls in
    Candle_payout_worker.pulse ();
    idle env;
    check int "a deterministic ledger refusal is not retried by pulse" refused_calls (List.length !calls))

let test_slow_goal_does_not_block_another_and_wakes_do_not_overlap_it () =
  with_workspace @@ fun env config ->
  ignore (prepared config "slow");
  ignore (prepared config "fast");
  let entered, signal_entered = Eio.Promise.create () in
  let release, signal_release = Eio.Promise.create () in
  let slow_grades = ref 0 in
  let calls = ref [] in
  let runner ~identity request =
    (match request with
     | A.Grade _ when identity.A.goal_id="slow" ->
       incr slow_grades;
       if !slow_grades=1 then Eio.Promise.resolve signal_entered ();
       Eio.Promise.await release
     | A.Grade _ | A.Relation _ | A.Weights _ -> ());
    make_runner calls ~identity request in
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~sw ~config ~appraise:runner;
    await env "slow Goal entering model" (fun () -> Option.is_some (Eio.Promise.peek entered));
    Candle_payout_worker.wake ();
    Candle_payout_worker.pulse ();
    await env "fast Goal while first model is held" (fun () -> paid config "fast" <> []);
    check int "queued wakes cannot overlap an active Goal" 1 !slow_grades;
    Eio.Promise.resolve signal_release ();
    await env "slow Goal after model returns" (fun () -> paid config "slow" <> []);
    idle env);
  ignore (one_payment config "fast");
  ignore (one_payment config "slow");
  check int "settled Goal is never appraised again" 1 !slow_grades

let test_server_records_the_request_before_dispatch_and_retains_its_answer () =
  with_workspace @@ fun _env config ->
  let path = Filename.concat config.base_path "appraisal-runs.jsonl" in
  let registry = Runs.create ~path () in
  (match Runs.install_global registry with Ok () -> () | Error Runs.Already_installed -> fail "fixture registry already installed");
  let identity : A.identity = {goal_id="receipt";request_id="receipt-request";verification_run_id="receipt-verifier"} in
  let request = A.Grade {title="Ship the ledger";metric=Some "tests";target_value=Some "10"} in
  let execute ~request:_ ~prompt:_ =
    let run = match Runs.list_runs registry with
      | [run] -> run | _ -> fail "request must be registered before dispatch" in
    check bool "dispatch observes a Running request" true (run.status = Runs.Running);
    let rows = In_channel.with_open_text path In_channel.input_lines
      |> List.map Yojson.Safe.from_string in
    check bool "registration is on disk before dispatch" true
      (List.exists (fun json -> Yojson.Safe.Util.(member "event" json = `String "register"
        && member "id" json = `String run.run_id)) rows);
    Ok (`Assoc ["grade",`String "medium"], "fixture.http") in
  let answer = match Server_candle_appraiser.For_testing.run ~base_path:config.base_path ~execute ~identity request with
    | Ok answer -> answer | Error error -> fail (A.error_to_string error) in
  let replayed = Runs.replay path in
  let stored = match Runs.get replayed ~run_id:answer.trace.run_id with Some run -> run | None -> fail "completed receipt vanished" in
  (match stored.status with
   | Runs.Completed {outcome=Runs.Succeeded;selected_slot=Some slot;output;_} ->
     check string "answering slot is durable" "fixture.http" slot;
     check bool "accepted output is durable" true
       Yojson.Safe.Util.(member "result" output = `Assoc ["grade",`String "medium"])
   | _ -> fail "receipt lost successful answer");
  let Runs.Exact_input input = stored.input in
  check bool "receipt keeps verifier identity outside model input" true
    Yojson.Safe.Util.(member "verification_run_id" input = `String identity.verification_run_id);
  check bool "exact grading input survives restart" true
    Yojson.Safe.Util.(member "actual_input" input = A.input request);
  let empty_prompts = Filename.concat config.base_path "empty-prompts" in
  Fs_compat.mkdir_p empty_prompts;
  Fun.protect ~finally:(fun () -> Prompt_registry.set_markdown_dir "../config/prompts")
    (fun () ->
      Prompt_registry.set_markdown_dir empty_prompts;
      let dispatched = ref false in
      let execute ~request:_ ~prompt:_ =
        dispatched := true;
        Ok (`Assoc ["grade",`String "medium"], "fixture.http") in
      (match Server_candle_appraiser.For_testing.run ~base_path:config.base_path ~execute ~identity request with
       | Error (A.Transport_unavailable _) -> ()
       | Error (A.Invalid_response _) -> fail "missing prompt is a source failure"
       | Ok _ -> fail "missing prompt was accepted");
      check bool "missing prompt does not dispatch a provider" false !dispatched;
      let replayed = Runs.replay path in
      let failures = Runs.list_runs replayed
        |> List.filter (fun run -> run.Runs.run_id <> answer.trace.run_id) in
      let failure = match failures with
        | [summary] -> (match Runs.get replayed ~run_id:summary.run_id with
            | Some full -> full
            | None -> fail "missing prompt receipt cannot be loaded")
        | _ -> fail "missing prompt lost its failed run receipt" in
      let Runs.Exact_input input = failure.input in
      match failure.status with
      | Runs.Completed {outcome=Runs.Failed {code;_};selected_slot=None;output;_} ->
        check string "render failure is recorded" "candle_appraisal_unavailable" code;
        check bool "failed render invents no prompt" true
          Yojson.Safe.Util.(member "rendered" (member "prompt" input) = `Null);
        check bool "failed render dispatches no slot" true
          Yojson.Safe.Util.(member "attempts" output = `List [])
      | _ -> fail "missing prompt lost its failed run outcome")

let () =
  run "candle_appraisal_flow"
    ["payout",
      [test_case "worker pays once with isolated judgments and arithmetic" `Quick test_worker_pays_once_with_isolated_inputs_and_integer_evidence
      ;test_case "invalid weights wait for an event, not a pulse" `Quick test_invalid_weights_wait_for_an_event_not_a_pulse
      ;test_case "pulse retries unavailable transport" `Quick test_transport_recovery_is_retried_by_pulse
      ;test_case "unrelated and external-only work mint nothing" `Quick test_unrelated_and_external_only_work_mint_nothing
      ;test_case "failed due date waits for a new corrected pass" `Quick test_unreadable_due_date_fails_once_and_a_new_pass_can_repair_it
      ;test_case "valid arithmetic cannot authorize an outsider" `Quick test_arithmetic_alone_cannot_authorize_an_outsider
      ;test_case "disable during model call preserves waiting" `Quick test_disable_during_appraisal_preserves_the_obligation
      ;test_case "cumulative overflow refuses the real settlement" `Quick test_cumulative_overflow_refuses_the_real_settlement
      ;test_case "slow Goal cannot hold another or overlap itself" `Quick test_slow_goal_does_not_block_another_and_wakes_do_not_overlap_it
      ;test_case "server receipt is durable before dispatch and after answer" `Quick test_server_records_the_request_before_dispatch_and_retains_its_answer]]
