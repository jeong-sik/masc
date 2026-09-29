module Worker = Server_workspace_memory_curator
module Ledger = Masc.Workspace_memory_ledger
module Request = Masc.Workspace_memory_request
module Decision = Masc.Workspace_memory_decision
module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types
module Runs = Masc.Exact_lane_run_registry

let require = function Ok value -> value | Error detail -> Alcotest.fail detail
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
      await_idle ~clock ~base_path)) with
  | Ok () -> ()
  | Error `Timeout -> Alcotest.fail "curator owner held its switch open")

let test_cli_answer_uses_same_decision_validation () =
  Exact_output_fixture.with_official_client_runtimes (fun () ->
    with_base (fun base_path _clock ->
      let pending : Ledger.pending_fact =
        { fact = Ledger.Ordinary { keeper_id = "writer";
            claim_sha256 = Digestif.SHA256.(digest_string "Observation" |> to_hex) };
          claim = "Observation" } in
      let selected = [pending] in
      let resolved = { Runtime_exact_output_registry.selected_slots = [];
                       cli_slots = [Exact_output_fixture.cli_primary_runtime] } in
      let answering ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
        Ok (Yojson.Safe.to_string (answer selected)) in
      (match Worker.For_testing.execute ~cli_runner:answering ~base_path ~resolved
         ~rendered_prompt:"curate" ~selected ~ledger:Ledger.empty with
       | Ok (_, runtime_id) -> Alcotest.(check string) "CLI answered"
           Exact_output_fixture.cli_primary_runtime runtime_id
       | Error detail -> Alcotest.fail detail);
      let invalid ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ = Ok "{}" in
      match Worker.For_testing.execute ~cli_runner:invalid ~base_path ~resolved
        ~rendered_prompt:"curate" ~selected ~ledger:Ledger.empty with
      | Ok _ -> Alcotest.fail "invalid CLI decision was accepted"
      | Error _ -> ()))

let () = Alcotest.run "workspace curator lane"
  [ "changed-fact ledger",
    [ Alcotest.test_case "changed facts persist; no work is silent" `Quick
        test_changed_facts_update_ledger_and_no_work_is_silent
    ; Alcotest.test_case "failed call preserves ledger; new commit retries" `Quick
        test_failure_preserves_ledger_and_later_change_retries
    ; Alcotest.test_case "invalid answer cannot be saved" `Quick
        test_invalid_model_answer_is_not_saved
    ; Alcotest.test_case "owner switch closes" `Quick test_owner_switch_liveness
    ; Alcotest.test_case "CLI answer uses decision validation" `Quick
        test_cli_answer_uses_same_decision_validation ] ]
