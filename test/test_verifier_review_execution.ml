open Masc
module AR = Task.Anti_rationalization
module V = Verifier_review_original
module O = Verifier_review_owner
module P = Lane_addon_request_progress
module X = Verifier_review_execution
module W = Verifier_review_worker

let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let retained = function
  | Ok () -> ()
  | Error (O.Original_invalid detail | Identity_mismatch detail
    | Retain_store_unavailable detail | Already_retained detail) ->
    Alcotest.fail ("original retain failed: " ^ detail)
let owner = function
  | Ok value -> value
  | Error (O.Load_store_unavailable detail | Corrupt_original detail) ->
    Alcotest.fail ("original owner unavailable: " ^ detail)
  | Error O.Not_found -> Alcotest.fail "original owner not found"
let verification_id = "vrf-journal-recovery"
let installation_id = "fixture.verifier"
let package_id = "fixture.review"
let model_id = "review-execution-fixture"

let make_original () =
  V.prepare ~generator_runtime:None ~verification_id ~attempt:0
    ~question:{AR.completion_contract=None;required_evidence=[];evidence_posture=AR.Note_only;few_shot_block=""}
    ~lookup_root:(AR.Producer_namespace {root="/declared/producer"})
    ~lookup_binding:(String.make 64 'a') ~lookup_schemas:["tool_read_file"]
    {AR.task_title="T";task_description="D";completion_notes="N";agent_name="producer";
      task_id="task-001";evidence_refs=[];evidence_images=[]} |> get

let with_fixture f = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> Result.map_error Runtime_agent_execution_runtime.initialization_error_to_string |> get;
  let base_path = Filename.temp_dir "verifier-journal-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path;Fs_compat.clear_fs ());
  let previous = Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () -> match previous with
    | None -> Llm_provider.Model_catalog.clear_global ()
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
  let source = Printf.sprintf
    "[[models]]\nmodel_id = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_native_streaming = false\n" model_id in
  Llm_provider.Model_catalog.of_toml_string ~source:"review-journal-test" source
    |> get |> Llm_provider.Model_catalog.set_global;
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  (* Original retention requires an existing owned parent as its authority
     anchor; the store creates only its own descendants. *)
  Unix.mkdir masc_root 0o700;
  let store = Lane_addon_store.create ~root:(Filename.concat masc_root "lane-addons") in
  let original = make_original () in
  O.retain ~store ~verification_id ~attempt:0 ~installation_id ~package_id original |> retained;
  let current = ref (O.load_retained ~store ~verification_id ~attempt:0 ~installation_id ~package_id |> owner) in
  current := O.advance ~store !current P.Dispatch_intended |> owner;
  f env sw base_path store original current))

let reply calls =
  `Assoc ["id",`String "fixture-response";"model",`String model_id;
    "choices",`List [`Assoc ["index",`Int 0;"message",`Assoc
      (["role",`String "assistant";"content",`String "review finished"] @
        if calls=[] then [] else ["tool_calls",`List calls]);
      "finish_reason",`String (if calls=[] then "stop" else "tool_calls")]];
    "usage",`Assoc ["prompt_tokens",`Int 1;"completion_tokens",`Int 1;"total_tokens",`Int 2]]
  |> Yojson.Safe.to_string

let tool_call id input = `Assoc ["id",`String id;"type",`String "function";
  "function",`Assoc ["name",`String "report_review_verdict";
    "arguments",`String (Yojson.Safe.to_string input)]]
let valid = `Assoc ["verdict",`String "APPROVE";"reason",`String "checked exact evidence"]

let run_native ?(refuse_publication=false) ?(after_scope_ready=fun () -> ()) env sw ~base_path ~store ~original ~current calls =
  let provider_calls = ref 0 and handler_calls = ref 0 in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
    ~on_request_before_reply:(fun () -> incr provider_calls)
    (Exact_output_fixture.Reply_with (fun _ _ ->
      `OK, reply (if !provider_calls=1 then calls else []))) in
  let provider_cfg = Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
    ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let state = ref AR.empty_verdict_call in
  let schema = Agent_core.Types.tool_schema_of_input_schema ~name:"report_review_verdict"
    ~description:"Report one completion verdict"
    ~input_schema:(`Assoc ["type",`String "object";"properties",`Assoc
      ["verdict",`Assoc ["type",`String "string"];"reason",`Assoc ["type",`String "string"]];
      "required",`List [`String "verdict";`String "reason"];"additionalProperties",`Bool false]) () |> get in
  let tool = Agent_core.Tool.of_schema schema (fun _ input ->
    incr handler_calls;
    let next,answer = AR.step_verdict_call !state input in
    state:=next;
    match answer with
    | AR.Verdict_recorded _ -> Ok {Agent_core.Types.content="recorded";content_blocks=None;_meta=None}
    | Verdict_refused {detail} | Verdict_already_recorded {detail} ->
      Error {Agent_core.Types.message=detail;recoverable=false;error_class=None}) in
  let config = Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ()) ~name:(X.keeper_name original |> get)
    ~provider_cfg ~system_prompt:"Call the report tool." ~tools:[tool] in
  let journal,config = Keeper_request_execution.prepare ~base_path:(X.session_root ~base_path original |> get)
    ~keeper_name:(X.keeper_name original |> get) ~config
    ~on_scope_ready:(fun ~call_id ->
      if refuse_publication then Error "injected ownership publication failure"
      else (
        let fact=X.capture ~original ~runtime_id:model_id ~execution:(Types_core.Native_execution {call_id}) |> get in
        current:=O.advance ~store !current (P.Execution_observed (Waiting fact)) |> owner;
        after_scope_ready ();
        Ok ())) () |> get in
  let result = Runtime_agent.run_blocks ~sw ~net:env#net ~config [Agent_core.Types.Text "Review"] in
  (* Discard the returned Agent result: only the original's durable references
     and a newly opened canonical journal are available to recovery. *)
  if refuse_publication then (match result with Error _ -> () | Ok _ -> Alcotest.fail "unconfirmed ownership dispatched")
  else ignore result;
  ignore journal;
  !provider_calls,!handler_calls

let test_terminal_recovery_ignores_unavailable_producer () = with_fixture (fun env sw base_path store original current ->
  let first=run_native env sw ~base_path ~store ~original ~current [] in
  let second=run_native env sw ~base_path ~store ~original ~current [tool_call "verdict-1" valid] in
  Alcotest.(check (pair int int)) "first declared slot returned no verdict" (1,0) first;
  Alcotest.(check (pair int int)) "next slot settled one actual verdict" (2,1) second;
  let attempts = ref 0 in
  let recover () = W.run_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
    ~base_path ~prepare_authority:(fun () -> incr attempts;Error "producer VM is detached")
    ~prepare_notes:(fun _ -> "journal-backed recovered verdict") ~provider_rest:(fun _ -> AR.No_stated_rest) () in
  List.iter (fun () -> match recover () with
    | Ok {AR.verdict=Some (Approve "checked exact evidence");_} -> ()
    | Ok _ | Error _ -> Alcotest.fail "exact original verdict did not recover") [();()];
  Alcotest.(check int) "recovery never prepares producer access or dispatches another model" 0 !attempts;
  match P.phase (O.progress (O.load_retained ~store ~verification_id ~attempt:0 ~installation_id ~package_id |> owner)) with
  | Judged _ -> () | _ -> Alcotest.fail "recovered verdict was not durably retained")

let test_owner_publication_precedes_provider () = with_fixture (fun env sw base_path store original current ->
  let counts=run_native ~refuse_publication:true env sw ~base_path ~store ~original ~current [tool_call "v" valid] in
  Alcotest.(check (pair int int)) "failed owner publication permits no provider or handler" (0,0) counts)

let test_invalid_report_is_not_a_verdict () = with_fixture (fun env sw base_path store original current ->
  let providers,handlers=run_native env sw ~base_path ~store ~original ~current
    [tool_call "invalid" (`Assoc ["reason",`String "missing verdict"])] in
  Alcotest.(check bool) "schema refusal was observed after a real provider response" true (providers>0);
  Alcotest.(check int) "schema rejection occurs before the handler" 0 handlers;
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Repair_required _ -> () | Awaiting | Verdict _ -> Alcotest.fail "invalid report became a judgment")

let test_historical_original_has_no_replay_authority () = with_fixture (fun _ _ base_path _ original current ->
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Repair_required _ -> () | Awaiting | Verdict _ -> Alcotest.fail "missing locator became recoverable")

let test_duplicate_report_cannot_recover () = with_fixture (fun env sw base_path store original current ->
  ignore (run_native env sw ~base_path ~store ~original ~current
    [tool_call "first" valid;tool_call "duplicate" valid]);
  match X.observe ~base_path ~original (O.progress !current) |> get with
  | Repair_required _ -> () | Awaiting | Verdict _ -> Alcotest.fail "duplicate report supplied a verdict")

let test_reference_bindings_are_strict () = with_fixture (fun _ _ base_path _ original current ->
  let fact=X.capture ~original ~runtime_id:model_id ~execution:(Types_core.Native_execution {call_id="fixture-call"}) |> get in
  let variants=match fact with
    | `Assoc fields ->
      [ `Assoc (("unexpected",`Bool true)::fields)
      ; `Assoc (("schema",`String "unknown")::List.remove_assoc "schema" fields)
      ; `Assoc (("original_digest",`String (String.make 64 '0'))::List.remove_assoc "original_digest" fields)
      ; `Assoc (("runtime_id",`String "other-runtime")::fields) ]
    | _ -> Alcotest.fail "capture must be an object" in
  List.iter (fun invalid ->
    match P.append (O.progress !current) (P.Execution_observed (Waiting invalid)) with
    | Error _ -> ()
    | Ok progress ->
      match X.observe ~base_path ~original progress with
      | Error _ -> () | Ok _ -> Alcotest.fail "invalid execution binding was accepted") variants)

let test_pending_cannot_change_its_physical_workspace () = with_fixture (fun _ _ base_path store _ _ ->
  let touched=ref false in
  match W.run_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
    ~base_path:(Filename.concat base_path "another-workspace")
    ~prepare_authority:(fun () -> touched:=true;Error "unavailable")
    ~prepare_notes:(fun _ -> "unreachable") ~provider_rest:(fun _ -> AR.No_stated_rest) () with
  | Error (W.Grants_mismatch _) -> Alcotest.(check bool) "foreign workspace is refused before lookup preparation" false !touched
  | Ok _ | Error _ -> Alcotest.fail "pending original accepted another physical workspace")

let test_earlier_open_call_prevents_later_verdict_recovery () = with_fixture (fun env sw base_path store original current ->
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds (fun () ->
    let ready,signal=Eio.Promise.create () in
    let release,unblock=Eio.Promise.create () in
    let finished,complete=Eio.Promise.create () in
    let released=ref false in
    let release_original () = if not !released then (
      released:=true;Eio.Promise.resolve unblock ()) in
    Eio.Fiber.fork ~sw (fun () ->
      ignore (run_native ~after_scope_ready:(fun () ->
        Eio.Promise.resolve signal ();Eio.Promise.await release)
        env sw ~base_path ~store ~original ~current []);
      Eio.Promise.resolve complete ());
    (* The scope-ready barrier may protect publication from cancellation.
       Always release the fixture's artificial wait before switch teardown. *)
    Fun.protect ~finally:release_original (fun () ->
      Eio.Promise.await ready;
      ignore (run_native env sw ~base_path ~store ~original ~current [tool_call "later" valid]);
      (match X.observe ~base_path ~original (O.progress !current) |> get with
       | Awaiting -> () | Repair_required _ | Verdict _ ->
         Alcotest.fail "later verdict bypassed the original still-open call");
      release_original ();Eio.Promise.await finished)))

let () =
  let prompts=Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir prompts;Prompt_registry.load_prompts_from_directory prompts;
  Alcotest.run "original verifier journals" ["recovery",[
    Alcotest.test_case "terminal original recovers with producer detached" `Quick test_terminal_recovery_ignores_unavailable_producer;
    Alcotest.test_case "owner publication is a pre-effect barrier" `Quick test_owner_publication_precedes_provider;
    Alcotest.test_case "schema-refused report is not a verdict" `Quick test_invalid_report_is_not_a_verdict;
    Alcotest.test_case "historical missing locator requires reconciliation" `Quick test_historical_original_has_no_replay_authority;
    Alcotest.test_case "duplicate report cannot supply a recovered verdict" `Quick test_duplicate_report_cannot_recover;
    Alcotest.test_case "unknown and malformed execution bindings are refused" `Quick test_reference_bindings_are_strict;
    Alcotest.test_case "pending original cannot change physical workspace" `Quick test_pending_cannot_change_its_physical_workspace;
    Alcotest.test_case "earlier open call cannot be hidden by a later verdict" `Quick test_earlier_open_call_prevents_later_verdict_recovery]]
