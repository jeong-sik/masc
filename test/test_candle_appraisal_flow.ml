(* Test funding is a complete historical payout, not an orphan mint. *)
let funding_rows (at : Candle_time.t) (payment : Candle_payment.t) : Candle_event.t list =
  let identity = payment.identity in
  let keeper = match payment.allocations with
    | [allocation] -> allocation.Candle_payment.keeper
    | _ -> Alcotest.fail "funding fixture expects one Keeper" in
  let task_ids = List.map (fun (r : Candle_appraisal.task_relation) -> r.task_id) payment.relations in
  [ {Candle_event.at;body=Candle_event.Half_life_set Candle_decay.Off}
  ; {Candle_event.at;body=Candle_event.Snapshot
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;criterion_revision="funding-proof";
       passed_at=at;goal_created_at=(match Candle_time.of_rfc3339 "1970-01-01T00:00:00Z" with
         | Ok value -> value | Error detail -> Alcotest.fail detail);
       due_date=None;title="Completed funding fixture";metric=Some "completed";
       target_value=Some "1";linked_task_ids=task_ids}}
  ; {Candle_event.at;body=Candle_event.Payout_owed
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;passed_at=at;confirmed_at=at}}
  ; {Candle_event.at;body=Candle_event.Candidates
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;
       tasks=List.map (fun id -> id, Candle_event.Found
         {title="Completed contribution";assignee=Some keeper;
          status=Candle_event.Done {completed_at=at}}) task_ids;
       candidate_task_ids=task_ids;candidate_keepers=[keeper];
       candidate_task_keepers=List.map (fun id -> id, Some keeper) task_ids}}
  ; {Candle_event.at;body=Candle_event.Paid payment}
  ]
;;

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
      Fs_compat.save_file path {|half_life = "off"
[payout]
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
    | E.Half_life_set _ | E.Paid _ | E.Snapshot _ | E.Payout_owed _ | E.Candidates _
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
    Candle_payout_worker.start ~sw ~config ~appraise:(make_runner calls) ();
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
  check bool "ledger decode retains the issued payment and its evidence" true (decoded = p)

let test_allowed_large_weights_settle_with_exact_money_and_evidence () =
  let scenario ~goal_id ~amount ~weight_max ~weight expected =
    with_workspace @@ fun _env config ->
    let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path:config.base_path in
    Fs_compat.save_file path (Printf.sprintf
      "half_life = \"off\"\n[payout]\nweight_max = %d\ndeduction_rate = 0\ndeduction_floor = 1000\n[payout.grades_milli]\ntrivial = 0\nsmall = 0\nmedium = %d\nlarge = 0\nepic = 0\n"
      weight_max amount);
    (match Candle_status.current ~base_path:config.base_path with
     | Candle_config.Enabled policy -> check int "policy admits this exact amount" amount policy.payout.medium_milli
     | Candle_config.Off | Candle_config.Disabled _ -> fail "the explicit representable policy was rejected");
    let waiting = prepared ~due_date:None config goal_id in
    let calls = ref [] in
    (match drain config (make_runner ~weight calls) with
     | [Candle_appraise.Settled settled] -> check string "exact Goal settled" goal_id settled
     | _ -> fail "allowed large weights could not settle their obligation");
    let payment = one_payment config goal_id in
    check string "Paid retains the confirmed run" waiting.verification_run_id payment.identity.verification_run_id;
    check int "configured grade amount stays exact" amount payment.total_milli;
    check int "no lateness deduction" 1000 payment.coefficient;
    check (list (pair string int)) "weights survive the serialized Paid evidence"
      ["keeper-a",weight "keeper-a";"keeper-b",weight "keeper-b"]
      (List.map (fun (a : Candle_payment.allocation) -> a.keeper,a.weight) payment.allocations);
    check (list (triple string int int)) "exact shares, amounts and name tie ordering"
      (List.map (fun (keeper, amount) -> keeper,amount,amount) expected)
      (List.map (fun (a : Candle_payment.allocation) -> a.keeper,a.share_milli,a.amount_milli) payment.allocations);
    let balance = match Candle_balance.of_events ~at:(ok (Candle_stamp.at ~now)) (events config) with
      | Ok balance -> balance | Error error -> fail (Candle_balance.error_to_string error) in
    List.iter (fun (keeper, paid) -> check int "ledger replay credits the allocation exactly" paid
      (Candle_balance.balance balance ~keeper)) expected;
    let supply = Candle_balance.supply balance in
    check string "all and only the configured money was issued" (string_of_int amount) supply.issued_milli;
    check string "no currency burned" "0" supply.burned_milli;
    check string "circulation conserves the payout" (string_of_int amount) supply.circulating_milli;
    ignore (drain config (make_runner ~weight calls));
    check int "the settled Goal is paid once" 1 (List.length (paid config goal_id))
  in
  scenario ~goal_id:"max-weight-tie" ~amount:1 ~weight_max:max_int ~weight:(fun _ -> max_int)
    ["keeper-a",1;"keeper-b",0];
  List.iter (fun factor ->
    scenario ~goal_id:"scaled-proportions" ~amount:10 ~weight_max:(2 * factor)
      ~weight:(fun name -> if name="keeper-a" then 2 * factor else factor)
      ["keeper-a",7;"keeper-b",3]) [1;max_int / 2];
  scenario ~goal_id:"max-money-tie" ~amount:max_int ~weight_max:max_int ~weight:(fun _ -> max_int)
    ["keeper-a",(max_int / 2) + 1;"keeper-b",max_int / 2]

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
    Candle_payout_worker.start ~sw ~config ~appraise:runner ();
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

let test_refused_transport_waits_for_an_event () =
  with_workspace @@ fun env config ->
  ignore (prepared config "provider-refusal");
  let accept = ref false in
  let attempts = ref 0 in
  let calls = ref [] in
  let runner ~identity request =
    incr attempts;
    if !accept then make_runner calls ~identity request
    else Error (A.Invalid_response "provider refused the unchanged request") in
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~sw ~config ~appraise:runner;
    await env "provider refusal" (fun () -> !attempts > 0);
    idle env;
    let refused_attempts = !attempts in
    check int "refusal has no payment" 0
      (List.length (paid config "provider-refusal"));
    Candle_payout_worker.pulse ();
    idle env;
    check int "pulse does not redispatch refused request" refused_attempts !attempts;
    accept := true;
    Candle_status.install_appraiser_check (fun () -> Error "publication unavailable");
    Fun.protect
      ~finally:(fun () -> Candle_status.install_appraiser_check (fun () -> Ok ()))
      (fun () ->
        Candle_payout_worker.wake ();
        idle env;
        check int "an unavailable pass does not call the provider"
          refused_attempts !attempts);
    Candle_payout_worker.pulse ();
    await env "the retained event retries after availability recovers"
      (fun () -> paid config "provider-refusal" <> []);
    idle env);
  ignore (one_payment config "provider-refusal")

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
    Candle_payout_worker.start ~sw ~config ~appraise:runner ();
    await env "transport deferral" (fun () -> !attempted);
    idle env;
    available := true;
    Candle_payout_worker.pulse ();
    await env "transport recovery" (fun () -> paid config "transport" <> []);
    idle env);
  ignore (one_payment config "transport")

let test_execution_rejection_waits_for_event_and_preserves_preceding_work () =
  with_workspace @@ fun env config ->
  let waiting = prepared config "execution-refusal" in
  let accept = ref false in
  let calls = ref [] in
  let runner ~identity request =
    match request with
    | A.Relation _ when not !accept ->
      calls := !calls @ [identity, request];
      Error (A.Execution_rejected "fixture provider rejected the relation request")
    | A.Grade _ | A.Relation _ | A.Weights _ -> make_runner calls ~identity request in
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~sw ~config ~appraise:runner ();
    await env "permanent relation refusal" (fun () ->
      List.exists (fun (_, request) -> A.stage request = "relation") !calls);
    idle env;
    check (list string) "grade succeeded before the failed relation"
      ["grade";"relation"] (List.map (fun (_, request) -> A.stage request) !calls);
    let before = events config in
    check int "execution refusal pays nobody" 0 (List.length (paid config waiting.goal_id));
    (match Candle_payout.state ~goal_id:waiting.goal_id before with
     | Candle_payout.Waiting current -> check bool "same confirmed obligation remains" true (current=waiting)
     | Candle_payout.No_obligation | Candle_payout.Failed _ | Candle_payout.Settled ->
       fail "execution refusal consumed or failed the obligation");
    List.iter (fun () ->
      Candle_payout_worker.pulse ();
      idle env;
      check int "maintenance pulse repeats neither grade nor relation" 2 (List.length !calls);
      check bool "pulse appends no synthetic failure or payment fact" true
        (events config = before)) [(); ()];
    accept := true;
    Candle_payout_worker.wake ();
    await env "change event resumes the refused obligation" (fun () -> paid config waiting.goal_id <> []);
    idle env);
  let payment = one_payment config waiting.goal_id in
  check string "resumed payment keeps its confirmed verifier" waiting.verification_run_id
    payment.identity.verification_run_id;
  check (list string) "one fresh complete appraisal follows the event"
    ["grade";"relation";"grade";"relation";"relation";"relation";"weights"]
    (List.map (fun (_, request) -> A.stage request) !calls)

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

let test_settlement_requires_complete_snapshot_candidates () =
  with_workspace @@ fun _env config ->
  let waiting=prepared config "candidate-omission" in
  let original=events config in
  let identity : A.identity = {goal_id=waiting.goal_id;request_id=waiting.request_id;verification_run_id=waiting.verification_run_id} in
  let payment ids weights =
    let relations=List.map (fun task_id -> {A.task_id;relation=A.Related;trace=trace task_id}) ids in
    Candle_payment.make ~identity ~grade:Candle_grade.Medium ~total_milli:3001
      ~grade_trace:(trace "grade") ~relations ~weights_trace:(trace "weights")
      ~weight_max:10 ~deduction_rate:10 ~deduction_floor:200 ~overdue_hours:30 ~weights |> ok in
  let full=payment ["task-a";"task-b";"external"] ["keeper-a",1;"keeper-b",1] in
  check bool "complete eligible Snapshot proof can settle" true
    (Result.is_ok (Candle_payout.validate_settlement waiting original (E.Paid full)));
  List.iter (fun keepers ->
    let modified = List.map (fun (event : E.t) -> match event.body with
      | E.Candidates c -> {event with body=E.Candidates {c with candidate_keepers=keepers}}
      | _ -> event) original in
    let forged = payment ["task-a";"task-b";"external"] (List.map (fun keeper -> keeper, 1) keepers) in
    check bool "changing only durable Keeper set cannot redirect payout" true
      (Result.is_error (Candle_payout.validate_settlement waiting modified (E.Paid forged))))
    [["keeper-a";"keeper-b";"external-operator"];["keeper-a"]];
  let mixed_eligibility = List.map (fun (event : E.t) -> match event.body with
    | E.Candidates c -> {event with body=E.Candidates {c with
        tasks=List.map (fun (id, task) -> id, (match task with
          | E.Found task when id="task-b" -> E.Found {task with assignee=Some "keeper-a"}
          | _ -> task)) c.tasks;
        candidate_keepers=["keeper-a"];
        candidate_task_keepers=["task-a",None;"task-b",Some "keeper-a";"external",None]}}
    | _ -> event) original in
  let only_ineligible_related = List.map (fun (r : A.task_relation) ->
    {r with relation=(if r.task_id="task-a" then A.Related else A.Unrelated)}) full.relations in
  let ineligible_payment = Candle_payment.make ~identity ~grade:Candle_grade.Medium ~total_milli:3001
    ~grade_trace:(trace "grade") ~relations:only_ineligible_related ~weights_trace:(trace "weights")
    ~weight_max:10 ~deduction_rate:10 ~deduction_floor:200 ~overdue_hours:30 ~weights:["keeper-a",1] |> ok in
  check bool "another eligible task cannot grant an ineligible task its Keeper" true
    (Result.is_error (Candle_payout.validate_settlement waiting mixed_eligibility (E.Paid ineligible_payment)));
  List.iter (fun (omit_observation,omit_candidate) ->
    let modified=List.map (fun (event : E.t) -> match event.body with
      | E.Candidates c -> {event with body=E.Candidates {c with
          tasks=(if omit_observation then List.remove_assoc "task-b" c.tasks else c.tasks);
          candidate_task_ids=(if omit_candidate then List.filter ((<>) "task-b") c.candidate_task_ids else c.candidate_task_ids);
          candidate_keepers=(if omit_candidate then List.filter ((<>) "keeper-b") c.candidate_keepers else c.candidate_keepers)}}
      | _ -> event) original in
    let forged=if omit_candidate then payment ["task-a";"external"] ["keeper-a",1] else full in
    check bool "omitted eligible worker cannot redirect another worker's payout" true
      (Result.is_error (Candle_payout.validate_settlement waiting modified (E.Paid forged))))
    [false,true;true,false;true,true];
  let missing_ineligible=List.map (fun (event : E.t) -> match event.body with
    | E.Candidates c -> {event with body=E.Candidates {c with tasks=List.remove_assoc "pending" c.tasks}}
    | _ -> event) original in
  check bool "Snapshot coverage also requires ineligible task observations" true
    (Result.is_error (Candle_payout.validate_settlement waiting missing_ineligible (E.Paid full)))

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

let test_disable_before_ledger_decision_preserves_the_obligation () =
  with_workspace @@ fun _env config ->
  let waiting = prepared config "disable-before-append" in
  let () = match Candle_status.current ~base_path:config.base_path with
    | Candle_config.Enabled _ -> ()
    | Candle_config.Off | Candle_config.Disabled _ -> fail "fixture policy is not enabled" in
  let policy_path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path:config.base_path in
  let policy_text = Fs_compat.load_file policy_path in
  let before = events config in
  let calls = ref [] in
  (* Timestamp generation occurs inside each settlement transaction attempt.
     Disable there to ensure the subsequent availability read refuses append. *)
  let disable_now () = Sys.remove policy_path; now () in
  (match Candle_appraise.settle_one ~now:disable_now ~appraise:(make_runner calls)
           ~base_path:config.base_path waiting with
   | Candle_appraise.Retry_later _ -> ()
   | Candle_appraise.Rejected _ | Candle_appraise.Settled _ | Candle_appraise.Superseded _ ->
     fail "disable after appraisal did not defer settlement");
  check bool "disable happened after all appraisal stages" true
    (List.exists (fun (_, request) -> A.stage request = "weights") !calls);
  check bool "disabled transaction appended no row" true (events config = before);
  Fs_compat.save_file policy_path policy_text;
  ignore (drain config (make_runner calls));
  ignore (one_payment config waiting.goal_id);
  check int "restored policy settles once" 1 (List.length (paid config waiting.goal_id))

let test_cumulative_overflow_refuses_the_real_settlement () =
  with_workspace @@ fun env config ->
  let historical_amount = max_int / 1000 in
  let history = List.concat (List.init 1000 (fun i ->
    let payment = Candle_payment.make
      ~identity:{A.goal_id="past-" ^ string_of_int i;request_id="past-request";verification_run_id="past-run"}
      ~grade:Candle_grade.Epic ~total_milli:historical_amount
      ~grade_trace:(trace "past-grade")
      ~relations:[{A.task_id="past-task";relation=A.Related;trace=trace "past-relation"}]
      ~weights_trace:(trace "past-weights") ~weight_max:1 ~deduction_rate:0
      ~deduction_floor:1000 ~overdue_hours:0 ~weights:["keeper-a",1] |> ok in
    funding_rows confirmed_at payment)) in
  append config history;
  let waiting = prepared ~due_date:None config "overflow" in
  let calls = ref [] in
  (match drain config (make_runner calls) with
   | [Candle_appraise.Rejected _] -> ()
   | _ -> fail "overflowing appraisal was not refused");
  check bool "the actual appraisal reached its weight answer" true
    (List.exists (fun (_, request) -> A.stage request="weights") !calls);
  check int "the new payment was not appended" 0 (List.length (paid config waiting.goal_id));
  let balance = match Candle_balance.of_events ~at:(ok (Candle_stamp.at ~now)) (events config) with
    | Ok balance -> balance | Error error -> fail (Candle_balance.error_to_string error) in
  check int "prior money stays exact" (historical_amount * 1000)
    (Candle_balance.balance balance ~keeper:"keeper-a");
  check int "no other recipient receives a partial credit" 0 (Candle_balance.balance balance ~keeper:"keeper-b");
  (match Candle_payout.state ~goal_id:waiting.goal_id (events config) with
   | Candle_payout.Waiting _ -> () | _ -> fail "overflow consumed the obligation");
  Eio.Switch.run (fun sw ->
    let started_calls = List.length !calls in
    Candle_payout_worker.start ~sw ~config ~appraise:(make_runner calls) ();
    await env "overflow refusal in the worker" (fun () -> List.length !calls > started_calls);
    idle env;
    let refused_calls = List.length !calls in
    Candle_payout_worker.pulse ();
    idle env;
    check int "a deterministic ledger refusal is not retried by pulse" refused_calls (List.length !calls))

let test_finite_overflow_retries_after_decay () =
  with_workspace @@ fun _env config ->
  let historical_amount = max_int / 1000 in
  let history = List.concat (List.init 1000 (fun i ->
    let payment = Candle_payment.make
      ~identity:{A.goal_id="past-" ^ string_of_int i;request_id="past-request";verification_run_id="past-run"}
      ~grade:Candle_grade.Epic ~total_milli:historical_amount
      ~grade_trace:(trace "past-grade")
      ~relations:[{A.task_id="past-task";relation=A.Related;trace=trace "past-relation"}]
      ~weights_trace:(trace "past-weights") ~weight_max:1 ~deduction_rate:0
      ~deduction_floor:1000 ~overdue_hours:0 ~weights:["keeper-a",1] |> ok in
    funding_rows confirmed_at payment)) in
  append config history;
  let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path:config.Workspace.base_path in
  let configured = Fs_compat.load_file path in
  let off = "half_life = \"off\"" in
  Fs_compat.save_file path ("half_life = 1" ^ String.sub configured (String.length off)
    (String.length configured - String.length off));
  let waiting = prepared ~due_date:None config "decay-overflow" in
  let appraise = make_runner (ref []) in
  (match Candle_appraise.settle_one ~now ~appraise ~base_path:config.base_path waiting with
   | Candle_appraise.Retry_later _ -> () | _ -> fail "finite overflow was not retryable");
  check int "retry adds no partial payment" 0 (List.length (paid config waiting.goal_id));
  let later () = now () +. 3600. in
  (match Candle_appraise.settle_one ~now:later ~appraise ~base_path:config.base_path waiting with
   | Candle_appraise.Settled _ -> () | _ -> fail "decay did not free credit capacity");
  (match Candle_appraise.settle_one ~now:later ~appraise ~base_path:config.base_path waiting with
   | Candle_appraise.Superseded _ -> () | _ -> fail "settlement was repeated");
  check int "decay recovery pays exactly once" 1 (List.length (paid config waiting.goal_id))

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
    Candle_payout_worker.start ~sw ~config ~appraise:runner ();
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
       | Error (A.Execution_rejected _) -> fail "missing prompt is a recoverable source failure"
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

let test_clock_reversal_retries_but_malformed_history_rejects () =
  with_workspace @@ fun _env config ->
  let waiting = prepared config "clock-catchup" in
  let later () = now () +. 60. in
  let future = ok (Candle_stamp.at ~now:later) in
  append config [{E.at=future;body=E.Half_life_set Candle_decay.Off}];
  let calls = ref [] in
  (match Candle_appraise.settle_one ~now ~appraise:(make_runner calls)
      ~base_path:config.base_path waiting with
   | Candle_appraise.Retry_later _ -> () | _ -> fail "early wall clock was not retryable");
  check int "early clock appends no payment" 0 (List.length (paid config waiting.goal_id));
  (match Candle_appraise.settle_one ~now:later ~appraise:(make_runner calls)
      ~base_path:config.base_path waiting with
   | Candle_appraise.Settled _ -> () | _ -> fail "clock catch-up did not settle");
  check int "clock recovery pays exactly once" 1 (List.length (paid config waiting.goal_id));
  let malformed = prepared config "malformed-history" in
  append config [{E.at=confirmed_at;body=E.Half_life_set Candle_decay.Off}];
  (match Candle_appraise.settle_one ~now:later ~appraise:(make_runner calls)
      ~base_path:config.base_path malformed with
   | Candle_appraise.Rejected _ -> () | _ -> fail "reversed historical order became retryable")

(* An actual lane publication repairs the provider, without a new Goal or
   manual payout event. The normal maintenance pulse must reconsider debt. *)
let test_published_appraiser_repair_releases_rejected_payout ~in_flight () =
  with_workspace @@ fun env config ->
  let module F = Exact_output_fixture in
  let module R = Runtime_exact_output_registry in
  let waiting = prepared config "configuration-recovery" in
  Eio.Switch.run (fun sw ->
    let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
    Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
    @@ fun () ->
    let release, release_refusal = Eio.Promise.create () in
    let refused = F.start_server ~sw ~net ~clock
      (F.Reply_with (fun _ _ ->
         if in_flight then Eio.Promise.await release;
         `Bad_request,
         {|{"error":{"message":"model configuration refused","type":"invalid_request_error"}}|})) in
    let answers =
      [`Assoc ["grade", `String "medium"];
       `Assoc ["relation", `String "related"];
       `Assoc ["relation", `String "related"];
       `Assoc ["relation", `String "related"];
       `Assoc ["weights", `Assoc ["keeper-a", `Int 2; "keeper-b", `Int 1]]] in
    let repaired = F.start_server ~sw ~net ~clock
      (F.Replies (List.map F.openai_response answers)) in
    let publish ?(unrelated = false) id base_url =
      let snapshot = F.resolver_snapshot ~source:config.base_path [{F.id; base_url}] in
      let lane : Runtime_schema.exact_output_lane_decl =
        {id="candle_appraiser";slot_ids=[id];cli_slot_ids=[];
         max_output_tokens=Some F.fixture_max_output_tokens;thinking=None} in
      let lanes = if unrelated then [lane; {lane with id="other-lane"}] else [lane] in
      match R.publish ~lanes snapshot with
      | Ok _ -> () | Error error -> fail (R.publication_error_to_string error) in
    publish "refused-slot" refused.base_url;
    let probe = Server_candle_appraiser.declaration_change_probe () in
    let samples = ref 0 in
    let appraiser_declaration_changed () = incr samples; probe () in
    let appraise = Server_candle_appraiser.run ~base_path:config.base_path in
    Candle_payout_worker.start ~sw ~config ~appraise ~appraiser_declaration_changed ();
    await env "permanent provider refusal" (fun () -> F.post_count refused = 1);
    if not in_flight then (
      idle env;
      publish "refused-slot" refused.base_url;
      Candle_payout_worker.pulse ();
      idle env;
      check int "same declaration does not retry refusal" 1 (F.post_count refused);
      publish ~unrelated:true "refused-slot" refused.base_url;
      Candle_payout_worker.pulse ();
      idle env;
      check int "unrelated publication does not retry refusal" 1 (F.post_count refused));
    publish "repaired-slot" repaired.base_url;
    if in_flight then (
      let sampled = !samples in
      Candle_payout_worker.pulse ();
      await env "changed declaration sampled during old call" (fun () -> !samples > sampled);
      check int "repair does not overlap the old call" 0 (F.post_count repaired);
      Eio.Promise.resolve release_refusal ())
    else (
      let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path:config.base_path in
      let enabled = Fs_compat.load_file path in
      Fs_compat.save_file path "invalid = true\n";
      let sampled = !samples in
      Candle_payout_worker.pulse ();
      idle env;
      check int "disabled worker retains declaration baseline" sampled !samples;
      check int "disabled worker does not dispatch repair" 0 (F.post_count repaired);
      Fs_compat.save_file path enabled;
      Candle_payout_worker.pulse ());
    await env "retained obligation paid after normal pulse" (fun () -> paid config waiting.goal_id <> []);
    idle env;
    let payment = one_payment config waiting.goal_id in
    check string "same obligation is settled" waiting.request_id payment.identity.request_id;
    check int "declared grade amount is conserved" 3001 payment.total_milli;
    check int "allocation shares conserve the grade amount" payment.total_milli
      (List.fold_left (fun total (a : Candle_payment.allocation) -> total + a.share_milli)
         0 payment.allocations);
    check int "every eligible task has a relation" 3 (List.length payment.relations);
    check int "real Grade, three Relations and Weights completed" 5 (F.post_count repaired);
    check int "original refusal dispatched once" 1 (F.post_count refused);
    Candle_payout_worker.pulse ();
    idle env;
    check int "later pulse appends no second payment" 1 (List.length (paid config waiting.goal_id));
    check int "later pulse does not appraise paid debt" 5 (F.post_count repaired))

(* Use the HTTP mutation boundary and real payout worker. Only model judgment
   is controlled; failed persistence and unrelated edits must not release debt. *)
let test_prompt_mutation_retries_rejected_payout ~clear () =
  List.iter (fun key ->
    with_workspace @@ fun env config ->
    let bad = "fixture refusal {{appraisal_input}}" in
    let good = "fixture repaired {{appraisal_input}}" in
    let apply request = Server_prompt_override_mutation.apply ~base_path:config.base_path request in
    let applied request = match apply request with
      | Ok _ -> ()
      | Error (Server_prompt_override_mutation.Validation detail
          | Server_prompt_override_mutation.Persistence detail) -> fail detail in
    Fun.protect ~finally:(fun () -> Prompt_registry.clear_prompt_override key) (fun () ->
      applied (Server_prompt_override_request.Set {key;value=bad});
      let waiting = prepared config "prompt-recovery" in
      let calls = ref [] and refusals = ref 0 in
      let appraise ~identity request =
        let prompt_key = match request with
          | A.Grade _ -> Prompt_names.candle_appraiser_grade
          | A.Relation _ -> Prompt_names.candle_appraiser_relation
          | A.Weights _ -> Prompt_names.candle_appraiser_weights in
        if String.equal prompt_key key
           && String.equal (Prompt_registry.resolve_prompt key).effective bad
        then (incr refusals; Error (A.Invalid_response "fixture prompt refusal"))
        else make_runner calls ~identity request in
      Eio.Switch.run (fun sw ->
        Candle_payout_worker.start ~sw ~config ~appraise ();
        await env "prompt refusal" (fun () -> !refusals = 1);
        idle env;
        Candle_payout_worker.pulse ();
        idle env;
        check int "unchanged prompt stays rejected" 1 !refusals;
        applied (Server_prompt_override_request.Clear {key=Prompt_names.keeper});
        idle env;
        check int "unrelated successful mutation does not retry" 1 !refusals;
        (match apply (Server_prompt_override_request.Set {key;value=""}) with
         | Error (Server_prompt_override_mutation.Validation _) -> ()
         | _ -> fail "invalid prompt mutation was not refused");
        idle env;
        check int "invalid mutation does not retry" 1 !refusals;
        let repair = if clear then Server_prompt_override_request.Clear {key}
          else Server_prompt_override_request.Set {key;value=good} in
        let path = Filename.concat (Workspace.masc_dir config) "prompt_overrides.json" in
        let backup = path ^ ".fixture-backup" in
        Sys.rename path backup;
        Unix.mkdir path 0o700;
        Fun.protect ~finally:(fun () -> Unix.rmdir path; Sys.rename backup path) (fun () ->
          (match apply repair with
           | Error (Server_prompt_override_mutation.Persistence _) -> ()
           | _ -> fail "unwritable override store did not refuse mutation");
          idle env;
          check int "failed persistence does not retry" 1 !refusals);
        applied repair;
        await env "same rejected payout after prompt repair" (fun () -> paid config waiting.goal_id <> []);
        idle env;
        let payment = one_payment config waiting.goal_id in
        check string "repair retains original obligation" waiting.request_id payment.identity.request_id;
        check int "refused prompt is not dispatched again" 1 !refusals;
        Candle_payout_worker.pulse ();
        idle env;
        check int "later pulse does not duplicate payment" 1 (List.length (paid config waiting.goal_id)))))
    [Prompt_names.candle_appraiser_grade; Prompt_names.candle_appraiser_relation;
     Prompt_names.candle_appraiser_weights]

let test_declaration_probe_retains_usable_baseline () =
  with_workspace @@ fun _env config ->
  let module F = Exact_output_fixture in
  let module R = Runtime_exact_output_registry in
  let snapshot = F.resolver_snapshot ~source:config.base_path
      [{F.id="slot-a";base_url="http://127.0.0.1:1"};
       {F.id="slot-b";base_url="http://127.0.0.1:1"}] in
  let publish ?(lane_id="candle_appraiser") id =
    ignore (F.publish_registry ~lane_id ~slot_ids:[id] snapshot : R.t) in
  let registry_ok = function Ok value -> value
    | Error error -> fail (R.publication_error_to_string error) in
  publish "slot-a";
  let probe = Server_candle_appraiser.declaration_change_probe () in
  check bool "initial declaration seeds baseline" false (probe ());
  let retained = Option.get (R.prepare_retention ()) in
  let reservation = registry_ok (R.For_testing.reserve_replacement retained) in
  check bool "busy publication is not a change" false (probe ());
  (match R.For_testing.abort_replacement reservation with
   | Ok () -> () | Error _ -> fail "reservation abort failed");
  ignore (registry_ok (R.unpublish ()));
  check bool "unpublished registry is not a change" false (probe ());
  publish ~lane_id:"other-lane" "slot-b";
  check bool "missing Candle declaration is not a change" false (probe ());
  publish "slot-a";
  check bool "same declaration after missing stays unchanged" false (probe ());
  publish "slot-b";
  check bool "changed usable declaration recovers" true (probe ());
  check bool "change is consumed once" false (probe ());
  ignore (registry_ok (R.unpublish ()));
  let initially_missing = Server_candle_appraiser.declaration_change_probe () in
  publish "slot-a";
  check bool "first usable declaration seeds missing baseline" false (initially_missing ())

let () =
  run "candle_appraisal_flow"
    ["payout",
      [test_case "persisted appraisal prompt set retries rejected payout" `Quick (test_prompt_mutation_retries_rejected_payout ~clear:false)
      ;test_case "persisted appraisal prompt clear retries rejected payout" `Quick (test_prompt_mutation_retries_rejected_payout ~clear:true)
      ;test_case "published appraiser repair releases rejected payout" `Quick (test_published_appraiser_repair_releases_rejected_payout ~in_flight:false)
      ;test_case "publication during refusal retains recovery event" `Quick (test_published_appraiser_repair_releases_rejected_payout ~in_flight:true)
      ;test_case "declaration probe retains usable baseline" `Quick test_declaration_probe_retains_usable_baseline
      ;test_case "finite overflow retries after decay" `Quick test_finite_overflow_retries_after_decay
      ;test_case "clock catch-up retries but malformed history rejects" `Quick test_clock_reversal_retries_but_malformed_history_rejects
      ;test_case "worker pays once with isolated judgments and arithmetic" `Quick test_worker_pays_once_with_isolated_inputs_and_integer_evidence
      ;test_case "allowed large weights preserve exact money and Paid evidence" `Quick test_allowed_large_weights_settle_with_exact_money_and_evidence
      ;test_case "invalid weights wait for an event, not a pulse" `Quick test_invalid_weights_wait_for_an_event_not_a_pulse
      ;test_case "provider refusal waits for an event" `Quick test_refused_transport_waits_for_an_event
      ;test_case "pulse retries unavailable transport" `Quick test_transport_recovery_is_retried_by_pulse
      ;test_case "execution refusal holds through pulses and resumes on event" `Quick test_execution_rejection_waits_for_event_and_preserves_preceding_work
      ;test_case "unrelated and external-only work mint nothing" `Quick test_unrelated_and_external_only_work_mint_nothing
      ;test_case "failed due date waits for a new corrected pass" `Quick test_unreadable_due_date_fails_once_and_a_new_pass_can_repair_it
      ;test_case "settlement requires complete Snapshot candidates" `Quick test_settlement_requires_complete_snapshot_candidates
      ;test_case "valid arithmetic cannot authorize an outsider" `Quick test_arithmetic_alone_cannot_authorize_an_outsider
      ;test_case "disable during model call preserves waiting" `Quick test_disable_during_appraisal_preserves_the_obligation
      ;test_case "disable before ledger decision preserves waiting" `Quick test_disable_before_ledger_decision_preserves_the_obligation
      ;test_case "cumulative overflow refuses the real settlement" `Quick test_cumulative_overflow_refuses_the_real_settlement
      ;test_case "slow Goal cannot hold another or overlap itself" `Quick test_slow_goal_does_not_block_another_and_wakes_do_not_overlap_it
      ;test_case "server receipt is durable before dispatch and after answer" `Quick test_server_records_the_request_before_dispatch_and_retains_its_answer]]
