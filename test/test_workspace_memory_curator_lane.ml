module Worker = Server_workspace_memory_curator
module Ledger = Masc.Workspace_memory_ledger
module Request = Masc.Workspace_memory_request
module Decision = Masc.Workspace_memory_decision
module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types
module Runs = Masc.Exact_lane_run_registry
module Registry = Runtime_exact_output_registry
module Briefing = Masc.Workspace_memory_briefing
module Prompt = Masc.Keeper_unified_prompt
module Inputs = Masc.Keeper_world_observation_inputs

let require = function Ok value -> value | Error detail -> Alcotest.fail detail
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let field name json = Yojson.Safe.Util.member name json
let string = Yojson.Safe.Util.to_string

type size_refusal = Input_refusal | Output_refusal

let size_failure kind detail = match kind with
  | Input_refusal -> Worker.Input_too_large detail
  | Output_refusal -> Worker.Output_too_large detail

let check_refusal_output kind (run : Runs.run) =
  match Runs.get (Runs.global ()) ~run_id:run.run_id with
  | Some { status = Runs.Completed { output; _ }; _ } ->
    Alcotest.check json "input refusal is distinguished from output refusal"
      (`Bool (kind = Input_refusal)) (field "input_too_large" output);
    Alcotest.check json "output exhaustion has its own recorded cause"
      (`Bool (kind = Output_refusal)) (field "output_too_large" output)
  | _ -> Alcotest.fail "refused run has no completed output detail"

let commit_facts ?(keeper_id = "writer") base_path claims =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let expected_revision = match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
    | None -> None | Some snapshot -> Some snapshot.revision in
  let now = 1_700_000_000. in
  let facts = List.map (fun claim -> Types.observed ~claim ~category:Types.Fact ~now
      ~origin:{ kind = Types.Authored; trace_id = "curator-test" }) claims in
  Current.replace ~keepers_dir ~keeper_id ~expected_revision ~now
    ~source:{ kind = Current.Librarian; trace_id = "curator-test" } ~facts ()
  |> require |> ignore

let commit ?keeper_id base_path claim = commit_facts ?keeper_id base_path [claim]

let answer selected =
  `Assoc ["decisions", `List (List.map (fun (fact : Ledger.pending_fact) ->
    `Assoc ["fact_id", `String (Request.fact_id fact.fact);
            "kind", `String "create_claim"; "value", `String fact.claim]) selected)]

(* A deterministic provider fixture preserves the prior summary and every
   selected entry. It exercises the real batch contract without pretending to
   measure whether a model chose a faithful natural-language summary. *)
let fixture_summarize ~batch =
  let input = Briefing.input batch in
  let previous = match field "previous_summary" input with
    | `Null -> []
    | `String text -> [text]
    | _ -> Alcotest.fail "briefing previous_summary must be text or null" in
  let entries = field "entries" input |> Yojson.Safe.Util.to_list in
  let texts = List.map (fun entry ->
    let kind = field "kind" entry |> string in
    let text = field "text" entry |> string in
    kind ^ " observation: " ^ text) entries in
  Ok (`Assoc ["briefing", `String (String.concat "\n" (previous @ texts))], "summary.slot", None)

(* These passes perform real strict ledger/briefing writes. Await the owner
   state rather than imposing a per-pass disk-latency deadline; the focused
   runner supplies the suite hang guard, and callers assert the final work. *)
let await_idle ~base_path =
  while not (Worker.For_testing.is_idle ~base_path) do Eio.Fiber.yield () done

let with_base f =
  Prompt_registry.set_markdown_dir "../config/prompts";
  Masc.Prompt_defaults.init ();
  let base_path = Filename.temp_dir "workspace-curator-ledger" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    Eio_main.run (fun env -> f base_path env#clock))

let test_changed_facts_update_ledger_and_no_work_is_silent () = with_base (fun base_path _clock ->
  commit base_path "Original observation";
  let calls = ref 0 in
  let execute ~rendered_prompt:_ ~selected ~ledger:_ =
    incr calls;
    let expected = match !calls with
      | 1 -> ["Original observation"]
      | 2 -> ["Independent observation"]
      | _ -> Alcotest.fail "unchanged facts reached the classifier" in
    Alcotest.(check (list string)) "only changed facts reach classification" expected
      (List.map (fun (fact : Ledger.pending_fact) -> fact.claim) selected);
    Ok (answer selected, "test.slot", None) in
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~summarize:fixture_summarize ~sw ~base_path ~execute;
    await_idle ~base_path;
    Alcotest.(check int) "one initial model call" 1 !calls;
    let ledger = Ledger.load ~base_path |> require in
    Alcotest.(check int) "first fact assigned" 1 (List.length (Ledger.dispositions ledger));
    ignore (Worker.request ~base_path);
    await_idle ~base_path;
    Alcotest.(check int) "unchanged wake makes no model call" 1 !calls;
    commit ~keeper_id:"reviewer" base_path "Independent observation";
    await_idle ~base_path;
    Alcotest.(check int) "new fact makes one more call" 2 !calls;
    let ledger = Ledger.load ~base_path |> require in
    Alcotest.(check int) "both facts assigned" 2 (List.length (Ledger.dispositions ledger));
    Worker.For_testing.stop ~base_path))

let test_failure_preserves_ledger_and_later_change_retries () = with_base (fun base_path _clock ->
  commit base_path "First observation";
  let fail = ref true in
  let execute ~rendered_prompt:_ ~selected ~ledger:_ =
    if !fail then Error (Worker.Execution_failed "injected provider failure") else Ok (answer selected, "test.slot", None) in
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~summarize:fixture_summarize ~sw ~base_path ~execute;
    await_idle ~base_path;
    Alcotest.(check int) "failed answer stores no assignment" 0
      (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
    let canonical = Unix.realpath base_path in
    Alcotest.(check bool) "failure remains in exact runs" true
      (List.exists (fun (run : Runs.run) ->
        String.equal run.actor canonical && run.lane = Runs.Workspace_curator &&
        match run.status with Runs.Completed { outcome = Runs.Failed _; _ } -> true | _ -> false)
        (Runs.list_runs (Runs.global ())));
    fail := false;
    commit ~keeper_id:"reviewer" base_path "New observation";
    await_idle ~base_path;
    Alcotest.(check int) "both pending facts assigned after recovery" 2
      (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
    Worker.For_testing.stop ~base_path))

let test_invalid_model_answer_is_not_saved () = with_base (fun base_path _clock ->
  commit base_path "Stable observation";
  let execute ~rendered_prompt:_ ~selected:_ ~ledger:_ =
    Ok (`Assoc ["decisions", `List []], "test.slot", None) in
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~summarize:fixture_summarize ~sw ~base_path ~execute;
    await_idle ~base_path;
    Alcotest.(check int) "invalid answer did not write an assignment" 0
      (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
    Worker.For_testing.stop ~base_path))

let test_owner_switch_liveness () = with_base (fun base_path clock ->
  commit base_path "Observation";
  let execute ~rendered_prompt:_ ~selected ~ledger:_ = Ok (answer selected, "test.slot", None) in
  match Eio.Time.with_timeout clock 5. (fun () ->
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~summarize:fixture_summarize ~sw ~base_path ~execute;
      await_idle ~base_path);
    Ok ()) with
  | Ok () -> ()
  | Error `Timeout -> Alcotest.fail "curator owner held its switch open")

let test_missing_keeper_directory_preserves_existing_ledger () = with_base (fun base_path _clock ->
  let selected : Ledger.pending_fact list =
    [{ fact = Ledger.Ordinary { keeper_id = "writer"; claim_sha256 = String.make 64 'a' };
       claim = "Retained fact" }] in
  let assignments : Ledger.assignment list =
    [{ fact = (List.hd selected).fact; decision = Ledger.Create_claim "Retained fact" }] in
  let ledger = match Ledger.apply Ledger.empty ~selected assignments with
    | Ok ledger -> ledger
    | Error error -> Alcotest.fail (Ledger.apply_error_to_string error) in
  Ledger.save ~base_path ledger |> require;
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Alcotest.(check bool) "fixture has no Keeper directory" false (Sys.file_exists keepers_dir);
  let execute ~rendered_prompt:_ ~selected:_ ~ledger:_ =
    Alcotest.fail "missing Keeper directory reached a model" in
  let summaries = ref 0 in
  let summarize ~batch = incr summaries; fixture_summarize ~batch in
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~summarize ~sw ~base_path ~execute;
    await_idle ~base_path;
    Alcotest.(check bool) "owner did not fabricate the missing directory" false
      (Sys.file_exists keepers_dir);
    Alcotest.check json "previous ledger remains unchanged"
      (Ledger.to_json ledger) (Ledger.to_json (Ledger.load ~base_path |> require));
    Alcotest.(check int) "failed inventory cannot start semantic synthesis" 0 !summaries;
    (match Ledger.observe ~base_path with
     | Ledger.Available { briefing = Ok Briefing.Missing; _ } -> ()
     | _ -> Alcotest.fail "failed inventory published a briefing from unvalidated inventory");
    Worker.For_testing.stop ~base_path))

let test_initial_inventory_drains_after_provider_size_refusal refusal = with_base (fun base_path _clock ->
  List.iter (fun index ->
    commit ~keeper_id:("keeper-" ^ string_of_int index) base_path
      ("Distinct initial observation number " ^ string_of_int index))
    (List.init 4 Fun.id);
  let attempts, accepted, refused = ref [], ref [], ref 0 in
  let execute ~rendered_prompt:_ ~selected ~ledger:_ =
    attempts := List.length selected :: !attempts;
    match selected with
    | [fact] ->
      accepted := fact :: !accepted;
      Ok (answer selected, "test.slot", None)
    | _ ->
      incr refused;
      Error (size_failure refusal "fixture provider accepts one fact per request") in
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~summarize:fixture_summarize ~sw ~base_path ~execute;
    await_idle ~base_path;
    Alcotest.(check int) "first attempt sends the whole pending inventory" 4
      (List.hd (List.rev !attempts));
    Alcotest.(check bool) "the provider actually refused an oversized request" true (!refused > 0);
    Alcotest.(check (list string)) "every pending fact is eventually accepted once"
      (List.init 4 (fun index -> "Distinct initial observation number " ^ string_of_int index))
      (List.map (fun (fact : Ledger.pending_fact) -> fact.claim) !accepted |> List.sort String.compare);
    Alcotest.(check int) "all facts are classified" 4
      (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
    (match Ledger.observe ~base_path with
     | Ledger.Available { briefing = Ok (Briefing.Current summary); _ } ->
       Alcotest.(check int) "final briefing includes sources from every classification batch"
         4 (List.length summary.source_ids)
     | _ -> Alcotest.fail "classification drain did not finish its shared briefing");
    let canonical = Unix.realpath base_path in
    let failures = Runs.list_runs (Runs.global ()) |> List.filter (fun (run : Runs.run) ->
      String.equal run.actor canonical && run.lane = Runs.Workspace_curator
      && match run.status with
         | Runs.Completed { outcome = Runs.Failed { code = "workspace_curator_failed"; _ }; _ } -> true
         | _ -> false) in
    Alcotest.(check int) "each rejected classification attempt remains observable"
      !refused (List.length failures);
    List.iter (check_refusal_output refusal) failures;
    Worker.For_testing.stop ~base_path))

(* A whole source row can exceed the removed estimated byte gate. Actual
   singleton refusal must park without losing the source or retrying forever. *)
let test_large_singleton_refusal_preserves_pending_until_wake () =
  with_base (fun base_path _clock ->
    let claim = "Complete long observation: " ^ String.make 120_000 'x' in
    commit base_path claim;
    let refused = ref true and attempts = ref 0 in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr attempts;
      Alcotest.(check (list string)) "the source row is never truncated" [claim]
        (List.map (fun (fact : Ledger.pending_fact) -> fact.claim) selected);
      if !refused then Error (Worker.Input_too_large "fixture singleton capacity refusal")
      else Ok (answer selected, "test.slot", None) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~summarize:fixture_summarize ~sw ~base_path ~execute;
      await_idle ~base_path;
      Alcotest.(check int) "singleton refusal does not retry or split empty input" 1 !attempts;
      Alcotest.(check int) "refusal cannot classify the pending row" 0
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      refused := false;
      (match Worker.request ~base_path with
       | Worker.Queued -> ()
       | Worker.No_owner | Worker.Unavailable _ -> Alcotest.fail "retry wake was not admitted");
      await_idle ~base_path;
      Alcotest.(check int) "explicit wake retries the same pending row once" 2 !attempts;
      Alcotest.(check int) "successful retry classifies the retained row" 1
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      Worker.For_testing.stop ~base_path))

let accept_registry result =
  result |> Result.map_error Registry.publication_error_to_string |> require

let with_curator_lane_registry f =
  let snapshot = Exact_output_fixture.resolver_snapshot ~source:"curator-activity"
    [{ Exact_output_fixture.id = "curator-fixture"; base_url = "http://127.0.0.1:1" }] in
  let lane : Runtime_schema.exact_output_lane_decl =
    { id = Standalone_lane.to_id Standalone_lane.Workspace_curator; enabled = true;
      slot_ids = ["curator-fixture"]; cli_slot_ids = [];
      max_output_tokens = Some 4096; thinking = None } in
  let publish enabled = ignore (accept_registry (Registry.publish ~lanes:[{lane with enabled}] snapshot)) in
  let prepare enabled = accept_registry (Registry.prepare_replacement ~runtime_observations:[]
    ~lanes:[{lane with enabled}] ~excused_lane_ids:[] ~load_resolver_snapshot:(fun () -> Ok snapshot)) in
  Fun.protect ~finally:(fun () -> ignore (accept_registry (Registry.unpublish ())))
    (fun () -> f publish prepare)

let await_calls ~clock calls expected =
  Eio.Time.with_timeout_exn clock 5. (fun () ->
    while !calls < expected do Eio.Fiber.yield () done)

let test_reenable_wakes_retained_facts () = with_base (fun base_path clock ->
  with_curator_lane_registry (fun publish prepare ->
    commit base_path "Pending while off";
    publish false;
    let calls = ref 0 in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr calls; Ok (answer selected, "curator-fixture", None) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start_configured ~summarize:fixture_summarize ~sw ~base_path ~execute;
      await_idle ~base_path;
      Alcotest.(check int) "off owner parked without a model" 0 !calls;
      Alcotest.(check int) "off preserves unassigned fact" 0
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      ignore (accept_registry (Registry.transact_replacement (prepare true)
        ~apply_write:(fun () -> Registry.Committed ())));
      (* No memory commit and no explicit Worker.request after re-enable. *)
      await_calls ~clock calls 1; await_idle ~base_path;
      Alcotest.(check int) "retained fact assigned by publication wake" 1
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      Alcotest.(check int) "one model pass" 1 !calls;
      Worker.For_testing.stop ~base_path)))

exception Injected_config_write_failure
type config_write_outcome = Not_written | Raised | Retained

let test_fence_exit_retries_deferred_work outcome = with_base (fun base_path clock ->
  with_curator_lane_registry (fun publish prepare ->
    commit base_path "Initial fact";
    publish true;
    let calls = ref 0 in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr calls; Ok (answer selected, "curator-fixture", None) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start_configured ~summarize:fixture_summarize ~sw ~base_path ~execute;
      await_idle ~base_path;
      Alcotest.(check int) "initial pass finished" 1 !calls;
      let before = accept_registry (Registry.current ()) in
      let prepared = match outcome with
        | Not_written | Raised -> prepare false
        | Retained ->
          (match Registry.prepare_retention () with
           | Some prepared -> prepared | None -> Alcotest.fail "retention lost registry") in
      let apply_write () =
        commit base_path "Fact committed during config write";
        await_idle ~base_path;
        Alcotest.(check int) "busy registry deferred new model work" 1 !calls;
        match outcome with
        | Raised -> raise Injected_config_write_failure
        | Not_written -> Registry.Not_committed ()
        | Retained -> Registry.Committed () in
      (match Registry.transact_replacement prepared ~apply_write with
       | Ok (Registry.Not_committed ()) ->
         Alcotest.(check bool) "expected returned failure" true (outcome = Not_written)
       | Ok (Registry.Committed ()) ->
         Alcotest.(check bool) "expected retained commit" true (outcome = Retained)
       | Error error -> Alcotest.fail (Registry.publication_error_to_string error)
       | exception Injected_config_write_failure ->
         Alcotest.(check bool) "original exception preserved" true (outcome = Raised));
      Alcotest.(check bool) "fence exit keeps exact registry identity" true
        (before == accept_registry (Registry.current ()));
      await_calls ~clock calls 2; await_idle ~base_path;
      Alcotest.(check int) "fact deferred during fence is now assigned" 1
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      Worker.For_testing.stop ~base_path)))

let test_initial_publication_wakes_parked_owner () = with_base (fun base_path clock ->
  with_curator_lane_registry (fun publish _prepare ->
    ignore (accept_registry (Registry.unpublish ()));
    commit base_path "Pending before first registry";
    let calls = ref 0 in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr calls; Ok (answer selected, "curator-fixture", None) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start_configured ~summarize:fixture_summarize ~sw ~base_path ~execute;
      await_idle ~base_path;
      Alcotest.(check int) "unpublished registry does not run model" 0 !calls;
      publish true;
      await_calls ~clock calls 1; await_idle ~base_path;
      Alcotest.(check int) "first publication wakes pending fact" 1
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      Worker.For_testing.stop ~base_path)))

let test_off_preserves_in_flight_and_reenable_resumes_next_fact () = with_base (fun base_path clock ->
  with_curator_lane_registry (fun publish _prepare ->
    commit base_path "Already accepted"; publish true;
    let calls = ref 0 in
    let entered, mark_entered = Eio.Promise.create () in
    let release, release_first = Eio.Promise.create () in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr calls;
      if !calls = 1 then (Eio.Promise.resolve mark_entered (); Eio.Promise.await release);
      Ok (answer selected, "curator-fixture", None) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start_configured ~summarize:fixture_summarize ~sw ~base_path ~execute;
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await entered);
      publish false;
      commit base_path "Pending after off";
      Eio.Promise.resolve release_first ();
      await_idle ~base_path;
      Alcotest.(check int) "off did not cancel or start another pass" 1 !calls;
      Alcotest.(check int) "accepted decision finished" 1
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      publish true;
      await_calls ~clock calls 2; await_idle ~base_path;
      Alcotest.(check int) "re-enable processed the deferred change" 2 !calls;
      Worker.For_testing.stop ~base_path)))

let test_cancelled_owner_does_not_consume_another_owners_wake () = with_base (fun base_path clock ->
  let other = Filename.temp_dir "curator-survivor" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree other) (fun () ->
    with_curator_lane_registry (fun publish _prepare ->
      commit base_path "Stopped owner fact"; commit other "Surviving owner fact";
      publish false;
      let stopped_calls, surviving_calls = ref 0, ref 0 in
      let execute calls ~rendered_prompt:_ ~selected ~ledger:_ =
        incr calls; Ok (answer selected, "curator-fixture", None) in
      Eio.Switch.run (fun survivor ->
        Worker.For_testing.start_configured ~summarize:fixture_summarize ~sw:survivor ~base_path:other
          ~execute:(execute surviving_calls);
        Eio.Switch.run (fun stopped ->
          Worker.For_testing.start_configured ~summarize:fixture_summarize ~sw:stopped ~base_path
            ~execute:(execute stopped_calls);
          await_idle ~base_path; await_idle ~base_path:other);
        (match Worker.request ~base_path with
         | Worker.No_owner -> ()
         | Worker.Queued | Worker.Unavailable _ -> Alcotest.fail "stopped owner retained");
        publish true;
        await_calls ~clock surviving_calls 1; await_idle ~base_path:other;
        Alcotest.(check int) "cancelled waiter ran no work" 0 !stopped_calls;
        Alcotest.(check int) "surviving owner processed pending fact" 1
          (List.length (Ledger.dispositions (Ledger.load ~base_path:other |> require)));
        Worker.For_testing.stop ~base_path:other))))


let registry_ok result = result |> Result.map_error Registry.publication_error_to_string |> require

let curator_lane : Runtime_schema.exact_output_lane_decl =
  { id = "workspace_curator_exact"; enabled = true; slot_ids = ["curator-test"];
    cli_slot_ids = []; max_output_tokens = None; thinking = None }

let curator_snapshot base_url =
  Exact_output_fixture.resolver_snapshot ~source:"curator-publication-test"
    [{ Exact_output_fixture.id = "curator-test"; base_url }]

let with_registry f =
  Fun.protect ~finally:(fun () -> registry_ok (Registry.unpublish ())) f

let test_enable_publication_resumes_existing_fact () = with_registry (fun () ->
  with_base (fun base_path _clock ->
    let snapshot = curator_snapshot "http://127.0.0.1:9/v1" in
    registry_ok (Registry.publish ~lanes:[] snapshot) |> ignore;
    commit base_path "Existing fact before Curator is enabled";
    let calls = ref 0 in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr calls; Ok (answer selected, "curator-test", None) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start_configured ~summarize:fixture_summarize ~sw ~base_path ~execute;
      await_idle ~base_path;
      Alcotest.(check int) "disabled lane makes no call" 0 !calls;
      (match Registry.publish ~lanes:[{ curator_lane with slot_ids = [] }] snapshot with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "empty lane publication unexpectedly succeeded");
      await_idle ~base_path;
      Alcotest.(check int) "rejected publication leaves the owner parked" 0 !calls;
      (* A subscriber can read the now-published registry: notifications must
         run after its mutex and private transaction fence are released. *)
      let unsubscribe = Registry.subscribe_lane_changes ~lane_id:curator_lane.id (fun () ->
        ignore (registry_ok (Registry.current ()))) in
      Fun.protect ~finally:unsubscribe (fun () ->
        registry_ok (Registry.publish ~lanes:[curator_lane] snapshot) |> ignore);
      await_idle ~base_path;
      Alcotest.(check int) "enable retries without a new memory commit" 1 !calls;
      Alcotest.(check int) "existing fact classified" 1
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      Worker.For_testing.stop ~base_path)))

let test_transaction_recovery_is_relevant_and_committed () = with_registry (fun () ->
  with_base (fun base_path _clock ->
    let before = curator_snapshot "http://127.0.0.1:9/v1" in
    let after = curator_snapshot "http://127.0.0.1:10/v1" in
    registry_ok (Registry.publish ~lanes:[curator_lane] before) |> ignore;
    commit base_path "Pending fact survives a configuration refusal";
    let calls = ref 0 in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr calls;
      if !calls = 1 then Error (Worker.Execution_failed "binding refused") else Ok (answer selected, "curator-test", None) in
    let prepare snapshot lanes =
      registry_ok (Registry.prepare_replacement ~runtime_observations:[] ~lanes
        ~excused_lane_ids:[] ~load_resolver_snapshot:(fun () -> Ok snapshot)) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~summarize:fixture_summarize ~sw ~base_path ~execute;
      await_idle ~base_path;
      Alcotest.(check int) "initial refused attempt" 1 !calls;
      registry_ok (Registry.publish ~lanes:[curator_lane] before) |> ignore;
      let unrelated = { curator_lane with id = "unrelated_exact" } in
      registry_ok (Registry.publish ~lanes:[curator_lane; unrelated] before) |> ignore;
      await_idle ~base_path;
      Alcotest.(check int) "unchanged and unrelated publication do not retry" 1 !calls;
      let prepared = prepare after [curator_lane] in
      registry_ok (Registry.transact_replacement prepared
        ~apply_write:(fun () -> Registry.Not_committed ())) |> ignore;
      await_idle ~base_path;
      Alcotest.(check int) "failed write does not retry" 1 !calls;
      let unsubscribe = Registry.subscribe_lane_changes ~lane_id:curator_lane.id
          (fun () -> failwith "injected subscriber failure") in
      Fun.protect ~finally:unsubscribe (fun () ->
        registry_ok (Registry.transact_replacement prepared
          ~apply_write:(fun () -> Registry.Committed ())) |> ignore);
      await_idle ~base_path;
      Alcotest.(check int) "committed bound endpoint change retries" 2 !calls;
      Alcotest.(check int) "pending fact classified" 1
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      Worker.For_testing.stop ~base_path)))

let credential_snapshot ~curator_key ~other_key =
  let module Exact = Agent_core.Exact_output in
  let overlay = Exact_output_fixture.catalog_document
      ~api_key_envs:["curator-test", "CURATOR_TEST_KEY"; "other-test", "OTHER_TEST_KEY"]
      ~source:"curator-credential-publication-test"
      [ { Exact_output_fixture.id = "curator-test"; base_url = "http://127.0.0.1:9/v1" }
      ; { Exact_output_fixture.id = "other-test"; base_url = "http://127.0.0.1:9/v1" } ] in
  let io : Exact.resolver_io = { getenv = (function
      | "CURATOR_TEST_KEY" -> Ok curator_key
      | "OTHER_TEST_KEY" -> Ok other_key
      | _ -> Ok None) } in
  let observation slot_id key =
    let config = Llm_provider.Provider_config.make ~kind:OpenAI_compat
        ~model_id:"fixture-model" ~base_url:"http://127.0.0.1:9/v1"
        ~api_key:(Option.value ~default:"" key) () in
    let binding = Agent_core.Binding_identity.of_provider_config ~transport:Http config
      |> require in
    slot_id, Registry.{
      candidate = Runtime_candidate_backpressure.create_candidate
        ~binding:(Runtime_candidate_backpressure.Resolved_http_binding binding);
      quota_scope = Runtime_quota_window.scope_of_credential ~provider_id:slot_id None } in
  match Exact.load_resolver_snapshot ~io ~catalog:(Exact.Full_replacement overlay) () with
  | Ok snapshot -> snapshot,
      [observation "curator-test" curator_key; observation "other-test" other_key]
  | Error _ -> Alcotest.fail "credential fixture snapshot failed"

let test_credential_publication_resumes_pending_fact () = with_registry (fun () ->
  with_base (fun base_path _clock ->
    let before, before_observations = credential_snapshot ~curator_key:(Some "fixture-before")
        ~other_key:(Some "other-before") in
    let unrelated, unrelated_observations = credential_snapshot ~curator_key:(Some "fixture-before")
        ~other_key:(Some "other-after") in
    let after, after_observations = credential_snapshot ~curator_key:(Some "fixture-after")
        ~other_key:(Some "other-after") in
    Alcotest.(check string) "credential rotation keeps catalog identity"
      (Exact_output_fixture.catalog_generation_fingerprint before)
      (Exact_output_fixture.catalog_generation_fingerprint after);
    registry_ok (Registry.publish ~runtime_observations:before_observations ~lanes:[curator_lane] before) |> ignore;
    commit base_path "Existing fact waits for a corrected credential";
    let calls = ref 0 in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr calls;
      if !calls = 1 then Error (Worker.Execution_failed "injected credential refusal")
      else Ok (answer selected, "curator-test", None) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~summarize:fixture_summarize ~sw ~base_path ~execute;
      await_idle ~base_path;
      Alcotest.(check int) "initial refusal leaves pending work" 1 !calls;
      registry_ok (Registry.publish ~runtime_observations:before_observations ~lanes:[curator_lane] before) |> ignore;
      registry_ok (Registry.publish ~runtime_observations:unrelated_observations ~lanes:[curator_lane] unrelated) |> ignore;
      await_idle ~base_path;
      Alcotest.(check int) "same and unrelated credentials do not retry" 1 !calls;
      let prepared = registry_ok (Registry.prepare_replacement ~runtime_observations:after_observations
        ~lanes:[curator_lane] ~excused_lane_ids:[]
        ~load_resolver_snapshot:(fun () -> Ok after)) in
      registry_ok (Registry.transact_replacement prepared
        ~apply_write:(fun () -> Registry.Not_committed ())) |> ignore;
      await_idle ~base_path;
      Alcotest.(check int) "failed credential publication does not retry" 1 !calls;
      registry_ok (Registry.transact_replacement prepared
        ~apply_write:(fun () -> Registry.Committed ())) |> ignore;
      await_idle ~base_path;
      Alcotest.(check int) "committed credential rotation resumes unchanged fact" 2 !calls;
      Alcotest.(check int) "pending fact classified" 1
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      Worker.For_testing.stop ~base_path)))

let test_missing_credential_publication_notifies () = with_registry (fun () ->
  let missing, missing_observations = credential_snapshot ~curator_key:None ~other_key:None in
  let available, available_observations = credential_snapshot ~curator_key:(Some "fixture-key") ~other_key:None in
  let registry = registry_ok (Registry.publish ~runtime_observations:missing_observations ~lanes:[curator_lane] missing) in
  (match Registry.resolve_lane registry ~lane_id:curator_lane.id with
   | Ok lane -> Alcotest.(check int) "missing credential remains admitted" 1
       (List.length lane.selected_slots)
   | Error _ -> Alcotest.fail "credential failure removed an admitted slot");
  let calls = ref 0 in
  let unsubscribe = Registry.subscribe_lane_changes ~lane_id:curator_lane.id (fun () -> incr calls) in
  Fun.protect ~finally:unsubscribe (fun () ->
    registry_ok (Registry.publish ~runtime_observations:missing_observations ~lanes:[curator_lane] missing) |> ignore;
    Alcotest.(check int) "unchanged missing credential does not notify" 0 !calls;
    registry_ok (Registry.publish ~runtime_observations:available_observations ~lanes:[curator_lane] available) |> ignore;
    Alcotest.(check int) "available frozen credential notifies" 1 !calls;
    registry_ok (Registry.publish ~runtime_observations:available_observations ~lanes:[curator_lane] available) |> ignore;
    Alcotest.(check int) "unchanged available credential does not notify" 1 !calls))

let test_subscriber_cancellation_keeps_commit_receipt () = with_registry (fun () ->
  let snapshot = curator_snapshot "http://127.0.0.1:9/v1" in
  registry_ok (Registry.publish ~lanes:[curator_lane] snapshot) |> ignore;
  let prepare lane =
    registry_ok (Registry.prepare_replacement ~runtime_observations:[] ~lanes:[lane]
      ~excused_lane_ids:[] ~load_resolver_snapshot:(fun () -> Ok snapshot)) in
  let notified = ref 0 in
  let unsubscribe = Registry.subscribe_lane_changes ~lane_id:curator_lane.id
      (fun () -> incr notified) in
  (* Subscribers run newest first: cancellation must not skip the earlier
     subscriber or hide the write's committed result. *)
  let unsubscribe_cancel = Registry.subscribe_lane_changes ~lane_id:curator_lane.id
      (fun () -> raise (Eio.Cancel.Cancelled (Failure "cancelled subscriber"))) in
  Fun.protect ~finally:(fun () -> unsubscribe_cancel (); unsubscribe ()) (fun () ->
    let changed = { curator_lane with max_output_tokens = Some 100 } in
    (match Registry.transact_replacement (prepare changed)
        ~apply_write:(fun () -> Registry.Committed "saved") |> registry_ok with
     | Registry.Committed receipt -> Alcotest.(check string) "committed receipt returned" "saved" receipt
     | Registry.Not_committed _ -> Alcotest.fail "notification hid a committed write");
    let current = Registry.current () |> registry_ok in
    Alcotest.(check bool) "replacement remains published" true
      (Registry.declared_lane current ~lane_id:curator_lane.id = Some changed);
    Alcotest.(check int) "other subscriber receives committed change" 1 !notified;
    (* Cancellation at the write boundary is still pre-publication and must
       escape; only post-commit callback exceptions are isolated. *)
    let cancelled = try
        ignore (Registry.transact_replacement (prepare curator_lane)
          ~apply_write:(fun () -> raise (Eio.Cancel.Cancelled (Failure "cancelled write"))));
        false
      with Eio.Cancel.Cancelled _ -> true in
    Alcotest.(check bool) "write cancellation still propagates" true cancelled;
    Alcotest.(check bool) "cancelled write keeps prior publication" true
      (registry_ok (Registry.current ()) == current);
    Alcotest.(check int) "cancelled write sends no recovery signal" 1 !notified))

let test_publication_during_failed_call_keeps_wake () = with_registry (fun () ->
  with_base (fun base_path clock ->
    let snapshot = curator_snapshot "http://127.0.0.1:9/v1" in
    registry_ok (Registry.publish ~lanes:[curator_lane] snapshot) |> ignore;
    commit base_path "Fact pending while configuration changes";
    let entered, enter = Eio.Promise.create () in
    let released, release = Eio.Promise.create () in
    let calls = ref 0 in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr calls;
      if !calls = 1 then (
        Eio.Promise.resolve enter ();
        Eio.Promise.await released;
        Error (Worker.Execution_failed "old configuration failed"))
      else Ok (answer selected, "curator-test", None) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~summarize:fixture_summarize ~sw ~base_path ~execute;
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await entered);
      let changed = { curator_lane with max_output_tokens = Some 100 } in
      registry_ok (Registry.publish ~lanes:[changed] snapshot) |> ignore;
      Alcotest.(check int) "publication starts no parallel call" 1 !calls;
      Eio.Promise.resolve release ();
      await_idle ~base_path;
      Alcotest.(check int) "in-flight failure does not consume recovery wake" 2 !calls;
      Worker.For_testing.stop ~base_path)))

let empty_world : Masc.Keeper_world_observation.world_observation =
  { pending_messages = []; pending_board_events = []; idle_seconds = 0;
    active_goals = Ok []; unclaimed_task_count = 0; claimable_tasks = [];
    held_task_skills = []; failed_task_count = 0;
    scheduled_automation = Masc.Keeper_world_observation.empty_scheduled_automation_observation;
    approval_authority =
      { revision = 1; state = Masc.Keeper_world_observation.Approval_authority_complete; pending = [] };
    backlog_revision = Some 1; running_keeper_fiber_count = 0;
    connected_surfaces = []; connected_surface_failures = [];
    own_recent_board_posts = []; fleet_messages = []; own_recent_actions = Ok [] }

let occurrences ~needle text =
  let rec count offset found =
    if offset + String.length needle > String.length text then found
    else if String.sub text offset (String.length needle) = needle
    then count (offset + String.length needle) (found + 1)
    else count (offset + 1) found in
  if needle = "" then Alcotest.fail "empty briefing assertion" else count 0 0

type delivery_freshness = Current_briefing | Stale_briefing

let check_delivery ~base_path ~freshness expected =
  let expected_status = match freshness with
    | Current_briefing -> "current" | Stale_briefing -> "stale" in
  let read args =
    let outcome = Masc.Keeper_workspace_memory_read.handle ~base_path ~args in
    (match outcome.disposition with
     | Tool_result.Completed () -> ()
     | Deferred () | Failed _ -> Alcotest.fail outcome.raw_output);
    match outcome.data with
    | Some data -> data
    | None -> Alcotest.fail "memory reader omitted its structured result" in
  let reader = Agent_core.Tool.create ~name:"keeper_workspace_memory_read"
      ~description:"Read the fixture's actual shared memory"
      ~parameters:[{ Agent_core.Types.name = "view"; description = "Optional memory view";
        param_type = String; required = false }]
      (fun args -> Ok { Agent_core.Types.content = Yojson.Safe.to_string (read args);
        content_blocks = None; _meta = None }) in
  let access = Masc.Keeper_request_tool_access.create ~offered:[reader]
      ~deferred_names:[] ~loader_alive:false in
  let observation = Ledger.observe ~base_path in
  let direct = Masc.Keeper_turn.For_testing.direct_turn_dynamic_context
    ~lane_updates:(Ok (`List [])) ~workspace_memory:observation
    ~workspace_memory_access:(Some access)
    ~current_task:Inputs.No_current_task ~held_task_skills:[] ~task_skill_surfaces:[]
    ~approval_authority_text:"" ~recent_direct_conversation_text:""
    ~worktree_text:"" ~telemetry_feedback_text:"" ~turn_instructions_text:"" in
  let autonomous = Prompt.build_prompt_preview ~current_task:Inputs.No_current_task
      ~observation:empty_world ~workspace_memory:observation
      ~workspace_memory_access:access () in
  List.iter (fun (name, text) ->
    Alcotest.(check int) (name ^ " defers the saved semantic briefing") 0
      (occurrences ~needle:expected text);
    Alcotest.(check bool) (name ^ " can retrieve the supporting ledger") true
      (occurrences ~needle:"keeper_workspace_memory_read" text > 0))
    ["direct", direct; "autonomous", autonomous.world_state];
  let inventory = read (`Assoc []) |> field "workspace_memory" |> field "briefing" in
  Alcotest.check json "inventory carries freshness without briefing prose"
    (`Assoc ["status", `String expected_status]) inventory;
  let delivered = match Agent_core.Tool.execute reader
      (`Assoc ["view", `String "briefing"]) with
    | Ok result -> Yojson.Safe.from_string result.content
    | Error _ -> Alcotest.fail "advertised memory reader failed" in
  let briefing = delivered |> field "workspace_memory" |> field "briefing" in
  Alcotest.(check string) "reader returns the exact saved semantic briefing"
    expected (briefing |> field "text" |> string);
  Alcotest.(check string) "reader preserves the expected publication freshness"
    expected_status (briefing |> field "status" |> string)

let observed_briefing base_path = match Ledger.observe ~base_path with
  | Ledger.Available { briefing = Ok value; _ } -> value
  | Ledger.Available { briefing = Error detail; _ }
  | Ledger.Unavailable detail -> Alcotest.fail detail
  | Ledger.Missing -> Alcotest.fail "curated ledger is missing"

let current_briefing base_path = match observed_briefing base_path with
  | Briefing.Current summary -> summary
  | Briefing.Missing -> Alcotest.fail "curation did not publish a briefing"
  | Briefing.Stale _ -> Alcotest.fail "briefing did not catch up to the ledger"

let check_current_sources base_path =
  let summary = current_briefing base_path in
  let sources = Ledger.briefing_sources (Ledger.load ~base_path |> require) in
  Alcotest.(check (list string)) "publication covers exactly the current claim/conflict sources"
    (List.sort String.compare (List.map (fun (source : Briefing.source) -> source.id) sources))
    (List.sort String.compare summary.source_ids)

let request_existing base_path = match Worker.request ~base_path with
  | Worker.Queued -> ()
  | Worker.No_owner -> Alcotest.fail "curator owner disappeared"
  | Worker.Unavailable detail -> Alcotest.fail detail

let test_briefing_reaches_turns_and_tracks_addition_and_deletion () =
  with_base (fun base_path _clock ->
    commit base_path "The release gate is closed pending review";
    commit ~keeper_id:"reviewer" base_path "The release gate may have reopened, unverified";
    let classifications, summaries = ref 0, ref 0 in
    let first = "Shared reports disagree on the release gate; reopening is unverified." in
    let added = first ^ " Deployment remains paused until the owner confirms." in
    let removed = "The release gate is closed pending review; deployment remains paused." in
    let inputs = ref [] in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr classifications; Ok (answer selected, "classify.slot", None) in
    let summarize ~batch =
      incr summaries; inputs := Briefing.input batch :: !inputs;
      let text = match !summaries with
        | 1 -> first | 2 -> added | 3 -> removed
        | _ -> Alcotest.fail "unchanged evidence reached the summarizer" in
      Ok (`Assoc ["briefing", `String text], "summary.slot", None) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~execute ~summarize;
      await_idle ~base_path;
      check_delivery ~base_path ~freshness:Current_briefing first; check_current_sources base_path;
      let published = current_briefing base_path in
      request_existing base_path; await_idle ~base_path;
      Alcotest.(check int) "unchanged request makes no classification call" 1 !classifications;
      Alcotest.(check int) "unchanged request makes no summary call" 1 !summaries;
      Alcotest.(check string) "unchanged summary is reused" published.text
        (current_briefing base_path).text;
      check_delivery ~base_path ~freshness:Current_briefing first;
      commit ~keeper_id:"operator" base_path "Deployment is paused until owner confirmation";
      await_idle ~base_path;
      Alcotest.(check int) "addition is classified once" 2 !classifications;
      Alcotest.check json "addition reuses the prior semantic summary" (`String first)
        (field "previous_summary" (List.hd !inputs));
      check_delivery ~base_path ~freshness:Current_briefing added; check_current_sources base_path;
      commit_facts ~keeper_id:"reviewer" base_path [];
      await_idle ~base_path;
      Alcotest.(check int) "deletion needs no new classification" 2 !classifications;
      Alcotest.(check int) "deletion-only update rebuilds the briefing" 3 !summaries;
      Alcotest.check json "deleted prose cannot enter the rebuilt summary" `Null
        (field "previous_summary" (List.hd !inputs));
      check_delivery ~base_path ~freshness:Current_briefing removed; check_current_sources base_path;
      Worker.For_testing.stop ~base_path))

let test_existing_ledger_gets_its_first_briefing_without_reclassification () =
  with_base (fun base_path _clock ->
    commit base_path "Operators must confirm a reopened release gate";
    let context = Masc.Workspace_memory_context.collect ~base_path |> require in
    let change = Ledger.reconcile Ledger.empty (Masc.Workspace_memory_context.keepers context) in
    let assignments = List.map (fun (pending : Ledger.pending_fact) ->
      { Ledger.fact = pending.fact; decision = Ledger.Create_claim pending.claim }) change.new_facts in
    let ledger = Ledger.apply Ledger.empty ~selected:change.new_facts assignments
        |> Result.map_error Ledger.apply_error_to_string |> require in
    Ledger.save ~base_path ledger |> require;
    let calls = ref 0 in
    let summarize ~batch = incr calls; fixture_summarize ~batch in
    let execute ~rendered_prompt:_ ~selected:_ ~ledger:_ =
      Alcotest.fail "already classified facts reached the classifier" in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~execute ~summarize;
      await_idle ~base_path;
      Alcotest.(check int) "existing ledger gets a summary" 1 !calls;
      check_current_sources base_path;
      check_delivery ~base_path ~freshness:Current_briefing (current_briefing base_path).text;
      Worker.For_testing.stop ~base_path))

type classification_failure_fixture = Provider_error | Invalid_decision

let test_existing_ledger_briefing_survives_new_classification_failure fault =
  with_base (fun base_path _clock ->
    let retained_claim = "Owner review is required before opening the release gate" in
    let pending_claim = "A new report says the gate may have reopened" in
    commit base_path retained_claim;
    let context = Masc.Workspace_memory_context.collect ~base_path |> require in
    let change = Ledger.reconcile Ledger.empty (Masc.Workspace_memory_context.keepers context) in
    let assignments = List.map (fun (pending : Ledger.pending_fact) ->
      { Ledger.fact = pending.fact; decision = Ledger.Create_claim pending.claim }) change.new_facts in
    let ledger = Ledger.apply Ledger.empty ~selected:change.new_facts assignments
        |> Result.map_error Ledger.apply_error_to_string |> require in
    Ledger.save ~base_path ledger |> require;
    commit ~keeper_id:"newcomer" base_path pending_claim;
    let classifications, summaries = ref 0, ref 0 in
    let selected_claims = ref [] in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr classifications;
      selected_claims := List.map (fun (fact : Ledger.pending_fact) -> fact.claim) selected
        :: !selected_claims;
      match fault with
      | Provider_error -> Error (Worker.Execution_failed "injected classifier failure")
      | Invalid_decision -> Ok (`Assoc ["decisions", `List []], "classify.slot", None) in
    let summarize ~batch =
      incr summaries;
      Alcotest.(check (list string)) "synthesis uses only the durable classified claim"
        [retained_claim]
        (field "entries" (Briefing.input batch) |> Yojson.Safe.Util.to_list
         |> List.map (fun entry -> field "text" entry |> string));
      fixture_summarize ~batch in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~execute ~summarize;
      await_idle ~base_path;
      Alcotest.(check int) "new fact classification failed once" 1 !classifications;
      Alcotest.(check int) "existing durable evidence still receives its first briefing" 1 !summaries;
      let first = current_briefing base_path in
      check_current_sources base_path;
      check_delivery ~base_path ~freshness:Current_briefing first.text;
      Alcotest.check json "failed classification leaves the ledger unchanged"
        (Ledger.to_json ledger) (Ledger.to_json (Ledger.load ~base_path |> require));
      request_existing base_path; await_idle ~base_path;
      Alcotest.(check int) "same pending fact remains retryable at the next request" 2 !classifications;
      Alcotest.(check (list (list string))) "both attempts classify only the same new fact"
        [[pending_claim]; [pending_claim]] (List.rev !selected_claims);
      Alcotest.(check int) "unchanged durable briefing makes no second model call" 1 !summaries;
      Alcotest.(check string) "next request reuses the published semantic text"
        first.text (current_briefing base_path).text;
      Alcotest.check json "repeated failed classification still leaves the ledger unchanged"
        (Ledger.to_json ledger) (Ledger.to_json (Ledger.load ~base_path |> require));
      let canonical = Unix.realpath base_path in
      let failures = Runs.list_runs (Runs.global ()) |> List.filter (fun (run : Runs.run) ->
        String.equal run.actor canonical && run.lane = Runs.Workspace_curator
        && match run.status with
           | Runs.Completed { outcome = Runs.Failed { code = "workspace_curator_failed"; _ }; _ } -> true
           | _ -> false) in
      Alcotest.(check int) "both classification failures remain observable" 2 (List.length failures);
      check_delivery ~base_path ~freshness:Current_briefing first.text;
      Worker.For_testing.stop ~base_path))

let test_failed_briefing_keeps_publication_and_request_resumes_same_input () =
  with_base (fun base_path _clock ->
    commit base_path "Release evidence is awaiting owner review";
    let classifications, summaries = ref 0, ref 0 in
    let failing = ref false in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr classifications; Ok (answer selected, "classify.slot", None) in
    let summarize ~batch =
      incr summaries;
      if !failing then Error (Worker.Execution_failed "injected summarizer failure") else fixture_summarize ~batch in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~execute ~summarize;
      await_idle ~base_path;
      let previous = current_briefing base_path in
      failing := true;
      commit ~keeper_id:"reviewer" base_path "Owner review has not completed";
      await_idle ~base_path;
      (match observed_briefing base_path with
       | Briefing.Stale retained ->
         Alcotest.(check string) "failed replacement preserves the last successful text"
           previous.text retained.text
       | Briefing.Current _ -> Alcotest.fail "old summary was called current after new evidence"
       | Briefing.Missing -> Alcotest.fail "failed replacement erased the published summary");
      check_delivery ~base_path ~freshness:Stale_briefing previous.text;
      Alcotest.(check int) "classification already committed before summary failure" 2 !classifications;
      failing := false;
      (* This is the real owner request, not a model/helper retry. It proves
         recovery at an admitted wake, not an autonomous timer. *)
      request_existing base_path; await_idle ~base_path;
      Alcotest.(check int) "same classified input is not reclassified" 2 !classifications;
      Alcotest.(check int) "failed summary is retried at the next admitted wake" 3 !summaries;
      check_current_sources base_path;
      check_delivery ~base_path ~freshness:Current_briefing (current_briefing base_path).text;
      Worker.For_testing.stop ~base_path))

let test_removing_all_sources_erases_publication_and_pending_pass () =
  with_base (fun base_path _clock ->
    let first_claim = "Release requires owner review" in
    let later_claim = "A new release observation awaits verification" in
    commit base_path first_claim;
    let classifications, summaries = ref 0, ref 0 in
    let failing = ref false in
    let inputs = ref [] in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr classifications; Ok (answer selected, "classify.slot", None) in
    let summarize ~batch =
      incr summaries; inputs := Briefing.input batch :: !inputs;
      if !failing then Error (Worker.Execution_failed "injected pending-pass failure")
      else fixture_summarize ~batch in
    let directory = Ledger.directory ~base_path in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~execute ~summarize;
      await_idle ~base_path;
      let previous = current_briefing base_path in
      failing := true;
      commit_facts base_path [first_claim; later_claim];
      await_idle ~base_path;
      (match observed_briefing base_path with
       | Briefing.Stale retained ->
         Alcotest.(check string) "failed pass retains the earlier publication"
           previous.text retained.text
       | _ -> Alcotest.fail "fixture did not leave a published summary with pending work");
      Alcotest.(check bool) "failed pass left durable briefing state" false
        (Briefing.load ~directory |> require |> Briefing.is_empty);
      commit_facts base_path [];
      await_idle ~base_path;
      Alcotest.(check int) "deleting all evidence requires no new classification" 2 !classifications;
      Alcotest.(check int) "deleting all evidence requires no semantic model call" 2 !summaries;
      Alcotest.(check bool) "both publication and pending pass are durably erased" true
        (Briefing.load ~directory |> require |> Briefing.is_empty);
      let empty = current_briefing base_path in
      Alcotest.(check string) "empty ledger exposes no old briefing prose" "" empty.text;
      Alcotest.(check (list string)) "empty ledger exposes no old source bindings" [] empty.source_ids;
      failing := false;
      commit_facts base_path [first_claim; later_claim];
      await_idle ~base_path;
      Alcotest.(check int) "reappearing facts are classified afresh" 3 !classifications;
      Alcotest.(check int) "reappearing evidence gets a new summary" 3 !summaries;
      let input = List.hd !inputs in
      Alcotest.check json "reappearance cannot resume the erased prior summary" `Null
        (field "previous_summary" input);
      Alcotest.(check (list string)) "reappearance supplies both facts rather than a pending suffix"
        (List.sort String.compare [first_claim; later_claim])
        (field "entries" input |> Yojson.Safe.Util.to_list
         |> List.map (fun entry -> field "text" entry |> string) |> List.sort String.compare);
      check_current_sources base_path;
      check_delivery ~base_path ~freshness:Current_briefing (current_briefing base_path).text;
      Worker.For_testing.stop ~base_path))

let test_removing_pending_addition_cleans_pass_without_model_work () =
  with_base (fun base_path _clock ->
    let first_claim = "Published release evidence" in
    let later_claim = "Deleted pending evidence" in
    commit base_path first_claim;
    let classifications, summaries = ref 0, ref 0 in
    let failing = ref false in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr classifications; Ok (answer selected, "classify.slot", None) in
    let summarize ~batch =
      incr summaries;
      if !failing then Error (Worker.Execution_failed "injected pending-pass failure")
      else fixture_summarize ~batch in
    let directory = Ledger.directory ~base_path in
    let saved_building () =
      In_channel.with_open_bin (Briefing.path ~directory) In_channel.input_all
      |> Yojson.Safe.from_string |> field "building" in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~execute ~summarize;
      await_idle ~base_path;
      let previous = current_briefing base_path in
      failing := true;
      commit_facts base_path [first_claim; later_claim];
      await_idle ~base_path;
      Alcotest.(check bool) "failed inference left a persisted pass" true
        (saved_building () <> `Null);
      commit_facts base_path [first_claim];
      await_idle ~base_path;
      Alcotest.(check int) "removal needs no new classification" 2 !classifications;
      Alcotest.(check int) "current publication needs no new inference" 2 !summaries;
      Alcotest.check json "obsolete source bodies are removed from disk" `Null (saved_building ());
      let sources = Ledger.load ~base_path |> require |> Ledger.briefing_sources in
      (match Briefing.observe ~sources
          ~contract:(Briefing.contract ~template:(Prompt_registry.resolve_prompt
            Prompt_names.workspace_memory_briefing).effective)
          (Briefing.load ~directory |> require) with
       | Briefing.Current retained ->
         Alcotest.(check string) "reload preserves the current publication" previous.text retained.text
       | Briefing.Missing | Briefing.Stale _ -> Alcotest.fail "cleanup lost the current publication");
      request_existing base_path; await_idle ~base_path;
      Alcotest.(check int) "cleaned pass stays idle" 2 !summaries;
      failing := false;
      commit_facts base_path [first_claim; later_claim];
      await_idle ~base_path;
      Alcotest.(check int) "returned evidence is summarized afresh" 3 !summaries;
      check_current_sources base_path;
      Worker.For_testing.stop ~base_path))

let test_in_flight_addition_waits_for_fixed_briefing_pass () =
  with_base (fun base_path _clock ->
    commit base_path "Initial source remains valid";
    let calls = ref 0 in
    let first_summary = ref None in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ = Ok (answer selected, "classify.slot", None) in
    let summarize ~batch =
      incr calls;
      if !calls = 1 then (
        commit ~keeper_id:"later" base_path "New evidence arrived during summarization";
        let result = fixture_summarize ~batch in
        (match result with
         | Ok (output, _, _) -> first_summary := Some (field "briefing" output |> string)
         | Error (Worker.Execution_failed detail | Worker.Input_too_large detail
                 | Worker.Output_too_large detail) -> Alcotest.fail detail);
        result)
      else (
        let previous = match !first_summary with
          | Some text -> text | None -> Alcotest.fail "first pass did not answer" in
        Alcotest.check json "next pass reuses the completed fixed pass" (`String previous)
          (field "previous_summary" (Briefing.input batch));
        Alcotest.(check int) "only the later source is new to the next pass" 1
          (Briefing.selected_count batch);
        fixture_summarize ~batch) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~execute ~summarize;
      await_idle ~base_path;
      Alcotest.(check int) "addition waits for one subsequent pass" 2 !calls;
      check_current_sources base_path;
      check_delivery ~base_path ~freshness:Current_briefing (current_briefing base_path).text;
      Worker.For_testing.stop ~base_path))

let failed_runs ~base_path ~code =
  let canonical = Unix.realpath base_path in
  Runs.list_runs (Runs.global ()) |> List.filter (fun (run : Runs.run) ->
    String.equal run.actor canonical && run.lane = Runs.Workspace_curator
    && match run.status with
      | Runs.Completed { outcome = Runs.Failed failure; _ }
        when String.equal failure.code code -> true
      | _ -> false)

let failed_run_count ~base_path ~code = List.length (failed_runs ~base_path ~code)

let test_summary_narrows_only_after_provider_size_refusal () =
  with_base (fun base_path _clock ->
    let claims = ["Owner review remains pending"; "Deployment is paused until confirmation"] in
    commit_facts base_path claims;
    let attempts, inputs, successful = ref [], ref [], ref [] in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ = Ok (answer selected, "classify.slot", None) in
    let summarize ~batch =
      let count = Briefing.selected_count batch in
      attempts := count :: !attempts;
      inputs := Briefing.input batch :: !inputs;
      if count > 1 then
        Error (Worker.Input_too_large "fixture provider accepts one summary entry per request")
      else
        let result = fixture_summarize ~batch in
        (match result with
         | Ok (output, _, _) -> successful := (field "briefing" output |> string) :: !successful
         | Error (Worker.Input_too_large detail | Worker.Execution_failed detail
                 | Worker.Output_too_large detail) -> Alcotest.fail detail);
        result in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~execute ~summarize;
      await_idle ~base_path;
      Alcotest.(check (list int)) "full input is refused, then both one-entry chunks succeed"
        [2; 1; 1] (List.rev !attempts);
      Alcotest.(check int) "the refusal is retained in the exact run registry" 1
        (failed_run_count ~base_path ~code:"workspace_curator_briefing_failed");
      (match List.rev !inputs, List.rev !successful with
       | [_; _; last_input], [first_text; _] ->
         Alcotest.check json "the remaining source is merged with the completed chunk"
           (`String first_text) (field "previous_summary" last_input)
       | _ -> Alcotest.fail "summary attempt sequence lost a chunk");
      let summary = current_briefing base_path in
      List.iter (fun claim ->
        Alcotest.(check int) "final semantic text retains each supplied observation once" 1
          (occurrences ~needle:claim summary.text)) claims;
      check_current_sources base_path;
      check_delivery ~base_path ~freshness:Current_briefing summary.text;
      Worker.For_testing.stop ~base_path))

type failed_phase = During_classification | During_summary

let test_non_size_failure_does_not_narrow_or_spin phase =
  with_base (fun base_path _clock ->
    commit_facts base_path ["Review is pending"; "Deployment needs confirmation"];
    let classifications, summaries = ref [], ref [] in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      classifications := List.length selected :: !classifications;
      match phase with
      | During_classification -> Error (Worker.Execution_failed "fixture transport failure")
      | During_summary -> Ok (answer selected, "classify.slot", None) in
    let summarize ~batch =
      summaries := Briefing.selected_count batch :: !summaries;
      Error (Worker.Execution_failed "fixture transport failure") in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~execute ~summarize;
      await_idle ~base_path;
      Alcotest.(check (list int)) "ordinary classification failure is not narrowed" [2]
        (List.rev !classifications);
      let expected_summary, code = match phase with
        | During_classification -> [], "workspace_curator_failed"
        | During_summary -> [2], "workspace_curator_briefing_failed" in
      Alcotest.(check (list int)) "ordinary summary failure is not narrowed"
        expected_summary (List.rev !summaries);
      Alcotest.(check int) "one failed attempt is retained without an immediate retry loop" 1
        (failed_run_count ~base_path ~code);
      Alcotest.(check bool) "failed owner parks until the next admitted wake" true
        (Worker.For_testing.is_idle ~base_path);
      Worker.For_testing.stop ~base_path))

let test_size_refusal_keeps_previous_briefing_and_parks refusal =
  with_base (fun base_path _clock ->
    commit base_path "Release still needs owner review";
    let refuse = ref false in
    let attempts = ref [] in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ = Ok (answer selected, "classify.slot", None) in
    let summarize ~batch =
      attempts := Briefing.selected_count batch :: !attempts;
      if !refuse then Error (size_failure refusal "fixture provider refused the summary")
      else fixture_summarize ~batch in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~execute ~summarize;
      await_idle ~base_path;
      let previous = current_briefing base_path in
      refuse := true;
      let added_claims = match refusal with
        | Input_refusal -> ["A new review record remains to be inspected"]
        | Output_refusal -> ["A new review record remains to be inspected";
                             "The recorded decision still needs owner confirmation"] in
      commit_facts ~keeper_id:"reviewer" base_path added_claims;
      await_idle ~base_path;
      Alcotest.(check (list int)) "a single input or any output refusal ends this attempt without narrowing"
        [1; List.length added_claims] (List.rev !attempts);
      (match observed_briefing base_path with
       | Briefing.Stale retained ->
         Alcotest.(check string) "refusal preserves the published text"
           previous.text retained.text
       | Briefing.Current _ -> Alcotest.fail "refused new source was called summarized"
       | Briefing.Missing -> Alcotest.fail "refusal erased the prior publication");
      let failures = failed_runs ~base_path ~code:"workspace_curator_briefing_failed" in
      Alcotest.(check int) "refusal is retained once" 1 (List.length failures);
      List.iter (check_refusal_output refusal) failures;
      Alcotest.(check bool) "no empty-batch or immediate retry loop remains" true
        (Worker.For_testing.is_idle ~base_path);
      check_delivery ~base_path ~freshness:Stale_briefing previous.text;
      Worker.For_testing.stop ~base_path))

let () = Alcotest.run "workspace curator lane"
  [ "changed-fact ledger",
    [ Alcotest.test_case "changed facts persist; no work is silent" `Quick
        test_changed_facts_update_ledger_and_no_work_is_silent
    ; Alcotest.test_case "failed call preserves ledger; new commit retries" `Quick
        test_failure_preserves_ledger_and_later_change_retries
    ; Alcotest.test_case "invalid answer cannot be saved" `Quick
        test_invalid_model_answer_is_not_saved
    ; Alcotest.test_case "missing Keeper directory preserves ledger" `Quick
        test_missing_keeper_directory_preserves_existing_ledger
    ; Alcotest.test_case "large singleton refusal parks and retains its source" `Quick
        test_large_singleton_refusal_preserves_pending_until_wake
    ; Alcotest.test_case "initial inventory drains after provider input refusal" `Quick
        (fun () -> test_initial_inventory_drains_after_provider_size_refusal Input_refusal)
    ; Alcotest.test_case "initial inventory drains after provider output refusal" `Quick
        (fun () -> test_initial_inventory_drains_after_provider_size_refusal Output_refusal)
    ; Alcotest.test_case "owner switch closes" `Quick test_owner_switch_liveness
    ; Alcotest.test_case "enable publication resumes existing fact" `Quick
        test_enable_publication_resumes_existing_fact
    ; Alcotest.test_case "configuration recovery requires relevant committed publication" `Quick
        test_transaction_recovery_is_relevant_and_committed
    ; Alcotest.test_case "subscriber cancellation preserves committed receipt" `Quick
        test_subscriber_cancellation_keeps_commit_receipt
    ; Alcotest.test_case "credential publication resumes existing fact" `Quick
        test_credential_publication_resumes_pending_fact
    ; Alcotest.test_case "missing credential publication notifies" `Quick
        test_missing_credential_publication_notifies
    ; Alcotest.test_case "publication survives an in-flight failure" `Quick
        test_publication_during_failed_call_keeps_wake
    ; Alcotest.test_case "re-enable wakes retained facts" `Quick test_reenable_wakes_retained_facts
    ; Alcotest.test_case "failed write reopens deferred work" `Quick
        (fun () -> test_fence_exit_retries_deferred_work Not_written)
    ; Alcotest.test_case "exception reopens deferred work" `Quick
        (fun () -> test_fence_exit_retries_deferred_work Raised)
    ; Alcotest.test_case "retained commit reopens deferred work" `Quick
        (fun () -> test_fence_exit_retries_deferred_work Retained)
    ; Alcotest.test_case "first publication wakes parked owner" `Quick
        test_initial_publication_wakes_parked_owner
    ; Alcotest.test_case "off preserves accepted work and on resumes deferred facts" `Quick
        test_off_preserves_in_flight_and_reenable_resumes_next_fact
    ; Alcotest.test_case "cancelled owner does not consume another owner's wake" `Quick
        test_cancelled_owner_does_not_consume_another_owners_wake
    ; Alcotest.test_case "semantic briefing reaches both turns and tracks source changes" `Quick
        test_briefing_reaches_turns_and_tracks_addition_and_deletion
    ; Alcotest.test_case "classified ledger receives its first briefing" `Quick
        test_existing_ledger_gets_its_first_briefing_without_reclassification
    ; Alcotest.test_case "classifier error does not starve the existing ledger briefing" `Quick
        (fun () -> test_existing_ledger_briefing_survives_new_classification_failure Provider_error)
    ; Alcotest.test_case "invalid classification does not starve the existing ledger briefing" `Quick
        (fun () -> test_existing_ledger_briefing_survives_new_classification_failure Invalid_decision)
    ; Alcotest.test_case "failed briefing survives and next request resumes unchanged input" `Quick
        test_failed_briefing_keeps_publication_and_request_resumes_same_input
    ; Alcotest.test_case "all-source deletion erases completed and pending briefing state" `Quick
        test_removing_all_sources_erases_publication_and_pending_pass
    ; Alcotest.test_case "removed pending addition is erased without new model work" `Quick
        test_removing_pending_addition_cleans_pass_without_model_work
    ; Alcotest.test_case "in-flight additions reuse the completed fixed pass" `Quick
        test_in_flight_addition_waits_for_fixed_briefing_pass
    ; Alcotest.test_case "summary narrows after an explicit provider size refusal" `Quick
        test_summary_narrows_only_after_provider_size_refusal
    ; Alcotest.test_case "ordinary classifier failure does not narrow or spin" `Quick
        (fun () -> test_non_size_failure_does_not_narrow_or_spin During_classification)
    ; Alcotest.test_case "ordinary summary failure does not narrow or spin" `Quick
        (fun () -> test_non_size_failure_does_not_narrow_or_spin During_summary)
    ; Alcotest.test_case "single-source refusal preserves the briefing and parks" `Quick
        (fun () -> test_size_refusal_keeps_previous_briefing_and_parks Input_refusal)
    ; Alcotest.test_case "summary output refusal preserves the briefing without splitting sources" `Quick
        (fun () -> test_size_refusal_keeps_previous_briefing_and_parks Output_refusal) ] ]
