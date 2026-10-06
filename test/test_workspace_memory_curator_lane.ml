module Worker = Server_workspace_memory_curator
module Ledger = Masc.Workspace_memory_ledger
module Request = Masc.Workspace_memory_request
module Decision = Masc.Workspace_memory_decision
module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types
module Runs = Masc.Exact_lane_run_registry

let require = function Ok value -> value | Error detail -> Alcotest.fail detail
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let field name json = Yojson.Safe.Util.member name json
let string = Yojson.Safe.Util.to_string

let commit ?(keeper_id = "writer") base_path claim =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let expected_revision = match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
    | None -> None | Some snapshot -> Some snapshot.revision in
  let now = 1_700_000_000. in
  let fact = Types.observed ~claim ~category:Types.Fact ~now
      ~origin:{ kind = Types.Authored; trace_id = "curator-test" } in
  Current.replace ~keepers_dir ~keeper_id ~expected_revision ~now
    ~source:{ kind = Current.Librarian; trace_id = "curator-test" } ~facts:[fact] ()
  |> require |> ignore

let answer selected =
  `Assoc ["decisions", `List (List.map (fun (fact : Ledger.pending_fact) ->
    `Assoc ["fact_id", `String (Request.fact_id fact.fact);
            "kind", `String "create_claim"; "value", `String fact.claim]) selected)]

let await_idle ~clock ~base_path =
  Eio.Time.with_timeout_exn clock 5. (fun () ->
    while not (Worker.For_testing.is_idle ~base_path) do Eio.Fiber.yield () done)

let with_base f =
  Prompt_registry.set_markdown_dir "../config/prompts";
  let base_path = Filename.temp_dir "workspace-curator-ledger" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    Eio_main.run (fun env -> f base_path env#clock))

let test_changed_facts_update_ledger_and_no_work_is_silent () = with_base (fun base_path clock ->
  commit base_path "Original observation";
  let calls = ref 0 in
  let execute ~rendered_prompt ~selected ~ledger:_ =
    incr calls;
    Alcotest.(check bool) "prompt includes only changed facts" true
      (String.contains rendered_prompt 'O');
    Ok (answer selected, "test.slot") in
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~sw ~base_path ~max_input_bytes:8192 ~execute;
    await_idle ~clock ~base_path;
    Alcotest.(check int) "one initial model call" 1 !calls;
    let ledger = Ledger.load ~base_path |> require in
    Alcotest.(check int) "first fact assigned" 1 (List.length (Ledger.dispositions ledger));
    ignore (Worker.request ~base_path);
    await_idle ~clock ~base_path;
    Alcotest.(check int) "unchanged wake makes no model call" 1 !calls;
    commit ~keeper_id:"reviewer" base_path "Independent observation";
    await_idle ~clock ~base_path;
    Alcotest.(check int) "new fact makes one more call" 2 !calls;
    let ledger = Ledger.load ~base_path |> require in
    Alcotest.(check int) "both facts assigned" 2 (List.length (Ledger.dispositions ledger));
    Worker.For_testing.stop ~base_path))

let test_failure_preserves_ledger_and_later_change_retries () = with_base (fun base_path clock ->
  commit base_path "First observation";
  let fail = ref true in
  let execute ~rendered_prompt:_ ~selected ~ledger:_ =
    if !fail then Error "injected provider failure" else Ok (answer selected, "test.slot") in
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~sw ~base_path ~max_input_bytes:8192 ~execute;
    await_idle ~clock ~base_path;
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
    await_idle ~clock ~base_path;
    Alcotest.(check int) "both pending facts assigned after recovery" 2
      (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
    Worker.For_testing.stop ~base_path))

let test_invalid_model_answer_is_not_saved () = with_base (fun base_path clock ->
  commit base_path "Stable observation";
  let execute ~rendered_prompt:_ ~selected:_ ~ledger:_ =
    Ok (`Assoc ["decisions", `List []], "test.slot") in
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~sw ~base_path ~max_input_bytes:8192 ~execute;
    await_idle ~clock ~base_path;
    Alcotest.(check int) "invalid answer did not write an assignment" 0
      (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
    Worker.For_testing.stop ~base_path))

let test_owner_switch_liveness () = with_base (fun base_path clock ->
  commit base_path "Observation";
  let execute ~rendered_prompt:_ ~selected ~ledger:_ = Ok (answer selected, "test.slot") in
  match Eio.Time.with_timeout clock 5. (fun () ->
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~max_input_bytes:8192 ~execute;
      await_idle ~clock ~base_path);
    Ok ()) with
  | Ok () -> ()
  | Error `Timeout -> Alcotest.fail "curator owner held its switch open")

let test_missing_keeper_directory_preserves_existing_ledger () = with_base (fun base_path clock ->
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
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~sw ~base_path ~max_input_bytes:8192 ~execute;
    await_idle ~clock ~base_path;
    Alcotest.(check bool) "owner did not fabricate the missing directory" false
      (Sys.file_exists keepers_dir);
    Alcotest.check json "previous ledger remains unchanged"
      (Ledger.to_json ledger) (Ledger.to_json (Ledger.load ~base_path |> require));
    Worker.For_testing.stop ~base_path))

let test_initial_inventory_drains_across_bounded_runs () = with_base (fun base_path clock ->
  List.iter (fun index ->
    commit ~keeper_id:("keeper-" ^ string_of_int index) base_path
      ("Distinct initial observation number " ^ string_of_int index))
    (List.init 4 Fun.id);
  let calls = ref 0 in
  let execute ~rendered_prompt ~selected ~ledger:_ =
    incr calls;
    Alcotest.(check bool) "whole prompt stays under the injected lane cap" true
      (String.length rendered_prompt <= 2000);
    Ok (answer selected, "test.slot") in
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~sw ~base_path ~max_input_bytes:2000 ~execute;
    await_idle ~clock ~base_path;
    Alcotest.(check bool) "initial inventory required more than one model call" true (!calls > 1);
    Alcotest.(check int) "all facts are classified" 4
      (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
    Worker.For_testing.stop ~base_path))

module Registry = Runtime_exact_output_registry

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
  with_base (fun base_path clock ->
    let snapshot = curator_snapshot "http://127.0.0.1:9/v1" in
    registry_ok (Registry.publish ~lanes:[] snapshot) |> ignore;
    commit base_path "Existing fact before Curator is enabled";
    let calls = ref 0 in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr calls; Ok (answer selected, "curator-test") in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start_configured ~sw ~base_path ~max_input_bytes:8192 ~execute;
      await_idle ~clock ~base_path;
      Alcotest.(check int) "disabled lane makes no call" 0 !calls;
      (match Registry.publish ~lanes:[{ curator_lane with slot_ids = [] }] snapshot with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "empty lane publication unexpectedly succeeded");
      await_idle ~clock ~base_path;
      Alcotest.(check int) "rejected publication leaves the owner parked" 0 !calls;
      (* A subscriber can read the now-published registry: notifications must
         run after its mutex and private transaction fence are released. *)
      let unsubscribe = Registry.subscribe_lane_changes ~lane_id:curator_lane.id (fun () ->
        ignore (registry_ok (Registry.current ()))) in
      Fun.protect ~finally:unsubscribe (fun () ->
        registry_ok (Registry.publish ~lanes:[curator_lane] snapshot) |> ignore);
      await_idle ~clock ~base_path;
      Alcotest.(check int) "enable retries without a new memory commit" 1 !calls;
      Alcotest.(check int) "existing fact classified" 1
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      Worker.For_testing.stop ~base_path)))

let test_transaction_recovery_is_relevant_and_committed () = with_registry (fun () ->
  with_base (fun base_path clock ->
    let before = curator_snapshot "http://127.0.0.1:9/v1" in
    let after = curator_snapshot "http://127.0.0.1:10/v1" in
    registry_ok (Registry.publish ~lanes:[curator_lane] before) |> ignore;
    commit base_path "Pending fact survives a configuration refusal";
    let calls = ref 0 in
    let execute ~rendered_prompt:_ ~selected ~ledger:_ =
      incr calls;
      if !calls = 1 then Error "binding refused" else Ok (answer selected, "curator-test") in
    let prepare snapshot lanes =
      registry_ok (Registry.prepare_replacement ~runtime_observations:[] ~lanes
        ~excused_lane_ids:[] ~load_resolver_snapshot:(fun () -> Ok snapshot)) in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~max_input_bytes:8192 ~execute;
      await_idle ~clock ~base_path;
      Alcotest.(check int) "initial refused attempt" 1 !calls;
      registry_ok (Registry.publish ~lanes:[curator_lane] before) |> ignore;
      let unrelated = { curator_lane with id = "unrelated_exact" } in
      registry_ok (Registry.publish ~lanes:[curator_lane; unrelated] before) |> ignore;
      await_idle ~clock ~base_path;
      Alcotest.(check int) "unchanged and unrelated publication do not retry" 1 !calls;
      let prepared = prepare after [curator_lane] in
      registry_ok (Registry.transact_replacement prepared
        ~apply_write:(fun () -> Registry.Not_committed ())) |> ignore;
      await_idle ~clock ~base_path;
      Alcotest.(check int) "failed write does not retry" 1 !calls;
      let unsubscribe = Registry.subscribe_lane_changes ~lane_id:curator_lane.id
          (fun () -> failwith "injected subscriber failure") in
      Fun.protect ~finally:unsubscribe (fun () ->
        registry_ok (Registry.transact_replacement prepared
          ~apply_write:(fun () -> Registry.Committed ())) |> ignore);
      await_idle ~clock ~base_path;
      Alcotest.(check int) "committed bound endpoint change retries" 2 !calls;
      Alcotest.(check int) "pending fact classified" 1
        (List.length (Ledger.dispositions (Ledger.load ~base_path |> require)));
      Worker.For_testing.stop ~base_path)))

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
        Error "old configuration failed")
      else Ok (answer selected, "curator-test") in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~max_input_bytes:8192 ~execute;
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await entered);
      let changed = { curator_lane with max_output_tokens = Some 100 } in
      registry_ok (Registry.publish ~lanes:[changed] snapshot) |> ignore;
      Alcotest.(check int) "publication starts no parallel call" 1 !calls;
      Eio.Promise.resolve release ();
      await_idle ~clock ~base_path;
      Alcotest.(check int) "in-flight failure does not consume recovery wake" 2 !calls;
      Worker.For_testing.stop ~base_path)))

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
    ; Alcotest.test_case "initial inventory drains in bounded runs" `Quick
        test_initial_inventory_drains_across_bounded_runs
    ; Alcotest.test_case "owner switch closes" `Quick test_owner_switch_liveness
    ; Alcotest.test_case "enable publication resumes existing fact" `Quick
        test_enable_publication_resumes_existing_fact
    ; Alcotest.test_case "configuration recovery requires relevant committed publication" `Quick
        test_transaction_recovery_is_relevant_and_committed
    ; Alcotest.test_case "subscriber cancellation preserves committed receipt" `Quick
        test_subscriber_cancellation_keeps_commit_receipt
    ; Alcotest.test_case "publication survives an in-flight failure" `Quick
        test_publication_during_failed_call_keeps_wake ] ]
