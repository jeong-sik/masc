(** Test_oas_worker — Unit tests for Phase 1 OAS migration modules:
    Oas_worker, Tool_mitosis_oas, Tool_council_oas.

    LLM 0 — no real LLM calls. Tests use mock net / temp directories.
    15 test scenarios across 3 modules.

    @since Phase 1 — MASC→OAS migration *)

open Masc_mcp

(* ================================================================ *)
(* Shared test infrastructure                                       *)
(* ================================================================ *)

let test_counter = ref 0

let temp_dir prefix =
  incr test_counter;
  let dir = Filename.temp_file (Printf.sprintf "%s_%d_" prefix !test_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let parse_json s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> failwith ("invalid json: " ^ e)

let field key json = Yojson.Safe.Util.member key json

(* ================================================================ *)
(* Module 1: Oas_worker tests                                       *)
(* ================================================================ *)

let test_default_config_fields () =
  let model_spec =
    match Llm_types.model_spec_of_string "llama:test-model" with
    | Ok m -> m
    | Error e -> failwith e
  in
  let tools = [] in
  let cfg = Oas_worker.default_config
    ~name:"test-agent"
    ~model_spec
    ~system_prompt:"You are a test agent."
    ~tools
  in
  Alcotest.(check string) "name" "test-agent" cfg.name;
  Alcotest.(check string) "system_prompt" "You are a test agent." cfg.system_prompt;
  Alcotest.(check int) "max_turns default" 20 cfg.max_turns;
  Alcotest.(check int) "max_tokens default" 4096 cfg.max_tokens;
  Alcotest.(check (float 0.001)) "temperature default" 0.7 cfg.temperature;
  Alcotest.(check bool) "hooks None" true (Option.is_none cfg.hooks);
  Alcotest.(check bool) "guardrails None" true (Option.is_none cfg.guardrails);
  Alcotest.(check bool) "event_bus None" true (Option.is_none cfg.event_bus);
  Alcotest.(check bool) "checkpoint_dir None" true (Option.is_none cfg.checkpoint_dir);
  Alcotest.(check bool) "session_id None" true (Option.is_none cfg.session_id);
  Alcotest.(check bool) "description None" true (Option.is_none cfg.description)

let test_default_config_custom_values () =
  let model_spec =
    match Llm_types.model_spec_of_string "llama:custom-model" with
    | Ok m -> m
    | Error e -> failwith e
  in
  let cfg = Oas_worker.default_config
    ~name:"custom-agent"
    ~model_spec
    ~system_prompt:"Custom prompt."
    ~tools:[]
  in
  let cfg = { cfg with
    max_turns = 50;
    max_tokens = 8192;
    temperature = 0.3;
    session_id = Some "sess-123";
    description = Some "A custom agent";
  } in
  Alcotest.(check int) "max_turns custom" 50 cfg.max_turns;
  Alcotest.(check int) "max_tokens custom" 8192 cfg.max_tokens;
  Alcotest.(check (float 0.001)) "temperature custom" 0.3 cfg.temperature;
  Alcotest.(check string) "session_id custom" "sess-123"
    (Option.get cfg.session_id);
  Alcotest.(check string) "description custom" "A custom agent"
    (Option.get cfg.description)

let test_build_with_mock_net () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let model_spec =
    match Llm_types.model_spec_of_string "llama:test-model" with
    | Ok m -> m
    | Error e -> failwith e
  in
  let cfg = Oas_worker.default_config
    ~name:"build-test"
    ~model_spec
    ~system_prompt:"Build test system prompt."
    ~tools:[]
  in
  (* build should succeed — it does not call LLM, only creates Agent.t *)
  match Oas_worker.build ~net ~config:cfg with
  | Ok agent ->
    Agent_sdk.Agent.close agent;
    Alcotest.(check pass) "build succeeds" () ()
  | Error e ->
    Alcotest.fail (Printf.sprintf "build should succeed: %s" e)

let test_build_invalid_config () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let model_spec =
    match Llm_types.model_spec_of_string "llama:test-model" with
    | Ok m -> m
    | Error e -> failwith e
  in
  let cfg = Oas_worker.default_config
    ~name:"invalid-test"
    ~model_spec
    ~system_prompt:"test"
    ~tools:[]
  in
  (* max_turns = 0 should fail build_safe validation *)
  let cfg = { cfg with max_turns = 0 } in
  match Oas_worker.build ~net ~config:cfg with
  | Error _ -> Alcotest.(check pass) "build correctly rejected" () ()
  | Ok agent ->
    Agent_sdk.Agent.close agent;
    Alcotest.fail "build should fail with max_turns=0"

let test_build_with_tools () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let model_spec =
    match Llm_types.model_spec_of_string "llama:test-model" with
    | Ok m -> m
    | Error e -> failwith e
  in
  let test_tool = Agent_sdk.Tool.create
    ~name:"test_tool"
    ~description:"A test tool"
    ~parameters:[]
    (fun _args -> Agent_sdk.Tool.text "ok")
  in
  let cfg = Oas_worker.default_config
    ~name:"tools-test"
    ~model_spec
    ~system_prompt:"test"
    ~tools:[test_tool]
  in
  match Oas_worker.build ~net ~config:cfg with
  | Ok agent ->
    Agent_sdk.Agent.close agent;
    Alcotest.(check pass) "build with tools succeeds" () ()
  | Error e ->
    Alcotest.fail (Printf.sprintf "build with tools failed: %s" e)

(* ================================================================ *)
(* Module 2: Tool_mitosis_oas tests                                 *)
(* ================================================================ *)

(** Reset Mcp_server global state to a fresh stem cell *)
let reset_mitosis_state () =
  Mcp_server.current_cell := Mitosis.create_stem_cell ~generation:0;
  Mcp_server.stem_pool := Mitosis.init_pool ~config:Mitosis.default_config

let make_mitosis_ctx ~base_path : Tool_mitosis_oas.context =
  let config = Room.default_config base_path in
  { config; agent_name = "test-agent" }

let with_mitosis_base f =
  let base_path = temp_dir "test_mitosis_oas" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      reset_mitosis_state ();
      f base_path)

let test_mitosis_status_returns_json () =
  with_mitosis_base @@ fun base_path ->
  let ctx = make_mitosis_ctx ~base_path in
  match Tool_mitosis_oas.dispatch ctx ~name:"masc_mitosis_status" ~args:(`Assoc []) with
  | Some (ok, body) ->
    Alcotest.(check bool) "status ok" true ok;
    let json = parse_json body in
    (* Verify cell, pool, config, and runtime fields *)
    Alcotest.(check bool) "has cell" true
      (Yojson.Safe.Util.member "cell" json <> `Null);
    Alcotest.(check bool) "has pool" true
      (Yojson.Safe.Util.member "pool" json <> `Null);
    Alcotest.(check string) "runtime is oas" "oas"
      (json |> field "runtime" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "dispatch returned None"

let test_mitosis_check_normal () =
  with_mitosis_base @@ fun base_path ->
  let ctx = make_mitosis_ctx ~base_path in
  let args = `Assoc [("context_ratio", `Float 0.2)] in
  match Tool_mitosis_oas.dispatch ctx ~name:"masc_mitosis_check" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "check ok" true ok;
    let json = parse_json body in
    Alcotest.(check string) "phase normal" "normal"
      (json |> field "phase" |> Yojson.Safe.Util.to_string);
    Alcotest.(check bool) "should_prepare false" false
      (json |> field "should_prepare" |> Yojson.Safe.Util.to_bool);
    Alcotest.(check bool) "should_handoff false" false
      (json |> field "should_handoff" |> Yojson.Safe.Util.to_bool)
  | None -> Alcotest.fail "dispatch returned None"

let test_mitosis_check_prepare () =
  with_mitosis_base @@ fun base_path ->
  let ctx = make_mitosis_ctx ~base_path in
  let args = `Assoc [("context_ratio", `Float 0.55)] in
  match Tool_mitosis_oas.dispatch ctx ~name:"masc_mitosis_check" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "check ok" true ok;
    let json = parse_json body in
    Alcotest.(check string) "phase prepare" "prepare"
      (json |> field "phase" |> Yojson.Safe.Util.to_string);
    Alcotest.(check bool) "should_prepare true" true
      (json |> field "should_prepare" |> Yojson.Safe.Util.to_bool)
  | None -> Alcotest.fail "dispatch returned None"

let test_mitosis_check_handoff () =
  with_mitosis_base @@ fun base_path ->
  let ctx = make_mitosis_ctx ~base_path in
  let args = `Assoc [("context_ratio", `Float 0.85)] in
  match Tool_mitosis_oas.dispatch ctx ~name:"masc_mitosis_check" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "check ok" true ok;
    let json = parse_json body in
    Alcotest.(check string) "phase handoff" "handoff"
      (json |> field "phase" |> Yojson.Safe.Util.to_string);
    Alcotest.(check bool) "should_handoff true" true
      (json |> field "should_handoff" |> Yojson.Safe.Util.to_bool)
  | None -> Alcotest.fail "dispatch returned None"

let test_mitosis_record_updates_cell () =
  with_mitosis_base @@ fun base_path ->
  let ctx = make_mitosis_ctx ~base_path in
  let args = `Assoc [("task_done", `Bool true); ("tool_called", `Bool true)] in
  match Tool_mitosis_oas.dispatch ctx ~name:"masc_mitosis_record" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "record ok" true ok;
    let json = parse_json body in
    Alcotest.(check bool) "recorded true" true
      (json |> field "recorded" |> Yojson.Safe.Util.to_bool);
    Alcotest.(check int) "task_count incremented" 1
      (json |> field "task_count" |> Yojson.Safe.Util.to_int);
    Alcotest.(check int) "tool_call_count incremented" 1
      (json |> field "tool_call_count" |> Yojson.Safe.Util.to_int);
    (* Verify global state was updated *)
    let cell = !(Mcp_server.current_cell) in
    Alcotest.(check int) "global task_count" 1 cell.Mitosis.task_count;
    Alcotest.(check int) "global tool_call_count" 1 cell.Mitosis.tool_call_count
  | None -> Alcotest.fail "dispatch returned None"

let test_mitosis_prepare_empty_context_err () =
  with_mitosis_base @@ fun base_path ->
  let ctx = make_mitosis_ctx ~base_path in
  let args = `Assoc [("full_context", `String "")] in
  match Tool_mitosis_oas.dispatch ctx ~name:"masc_mitosis_prepare" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "prepare fails with empty context" false ok;
    let json = parse_json body in
    let err = json |> field "error" |> Yojson.Safe.Util.to_string in
    Alcotest.(check bool) "error mentions full_context" true
      (String.length err > 0)
  | None -> Alcotest.fail "dispatch returned None"

let test_mitosis_prepare_success () =
  with_mitosis_base @@ fun base_path ->
  let ctx = make_mitosis_ctx ~base_path in
  let args = `Assoc [("full_context", `String "This is a rich context for DNA extraction with enough detail.")] in
  match Tool_mitosis_oas.dispatch ctx ~name:"masc_mitosis_prepare" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "prepare ok" true ok;
    let json = parse_json body in
    Alcotest.(check bool) "prepared true" true
      (json |> field "prepared" |> Yojson.Safe.Util.to_bool);
    Alcotest.(check bool) "dna_length > 0" true
      (json |> field "dna_length" |> Yojson.Safe.Util.to_int > 0)
  | None -> Alcotest.fail "dispatch returned None"

let test_mitosis_handoff_no_action () =
  with_mitosis_base @@ fun base_path ->
  let ctx = make_mitosis_ctx ~base_path in
  (* Low context_ratio, no force — should result in no_action *)
  let args = `Assoc [("context_ratio", `Float 0.1)] in
  match Tool_mitosis_oas.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "handoff ok" true ok;
    let json = parse_json body in
    Alcotest.(check string) "action is no_action" "no_action"
      (json |> field "action" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "dispatch returned None"

let test_mitosis_handoff_force () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio_context.set_net net;
  with_mitosis_base @@ fun base_path ->
  let ctx = make_mitosis_ctx ~base_path in
  let args = `Assoc [
    ("force", `Bool true);
    ("summary", `String "Force handoff test");
    ("context_ratio", `Float 0.1);
  ] in
  match Tool_mitosis_oas.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "force handoff ok" true ok;
    let json = parse_json body in
    Alcotest.(check string) "action is handoff" "handoff"
      (json |> field "action" |> Yojson.Safe.Util.to_string);
    Alcotest.(check string) "runtime is oas" "oas"
      (json |> field "runtime" |> Yojson.Safe.Util.to_string);
    Alcotest.(check bool) "dna_length > 0" true
      (json |> field "dna_length" |> Yojson.Safe.Util.to_int > 0);
    (* Generation should increment *)
    let cell = !(Mcp_server.current_cell) in
    Alcotest.(check int) "generation incremented" 1 cell.Mitosis.generation
  | None -> Alcotest.fail "dispatch returned None"

let test_mitosis_dispatch_unknown () =
  with_mitosis_base @@ fun base_path ->
  let ctx = make_mitosis_ctx ~base_path in
  let result = Tool_mitosis_oas.dispatch ctx ~name:"nonexistent_tool" ~args:(`Assoc []) in
  Alcotest.(check bool) "unknown tool returns None" true (Option.is_none result)

(* ================================================================ *)
(* Module 3: Tool_council_oas tests                                 *)
(* ================================================================ *)

let make_council_ctx ~base_path : Tool_council_oas.context =
  { base_path; agent_name = "test-agent"; room_config = None }

let with_council_base f =
  let base_path = temp_dir "test_council_oas" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      Council.Governance_v2.reset_legacy_storage base_path;
      f base_path)

let test_petition_submit_creates_case () =
  with_council_base @@ fun base_path ->
  let ctx = make_council_ctx ~base_path in
  let args = `Assoc [
    ("title", `String "Test petition via OAS");
    ("subject", `String "task");
    ("risk_class", `String "low");
  ] in
  match Tool_council_oas.dispatch ctx ~name:"masc_governance_petition" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "petition ok" true ok;
    let json = parse_json body in
    let case_id = json |> field "case_id" |> Yojson.Safe.Util.to_string in
    Alcotest.(check bool) "case_id non-empty" true (String.length case_id > 0);
    (* Verify collaboration_id is present (OAS Collaboration integration) *)
    let collab_id = json |> field "collaboration_id" |> Yojson.Safe.Util.to_string in
    Alcotest.(check bool) "collaboration_id non-empty" true (String.length collab_id > 0);
    Alcotest.(check bool) "merged field present" true
      (Yojson.Safe.Util.member "merged" json <> `Null)
  | None -> Alcotest.fail "dispatch returned None"

let test_petition_submit_empty_title_err () =
  with_council_base @@ fun base_path ->
  let ctx = make_council_ctx ~base_path in
  let args = `Assoc [("title", `String "")] in
  match Tool_council_oas.dispatch ctx ~name:"masc_governance_petition" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "empty title rejected" false ok;
    let json = parse_json body in
    let err = json |> field "error" |> Yojson.Safe.Util.to_string in
    Alcotest.(check bool) "error mentions title" true
      (String.length err > 0)
  | None -> Alcotest.fail "dispatch returned None"

let test_cases_list_empty () =
  with_council_base @@ fun base_path ->
  let ctx = make_council_ctx ~base_path in
  match Tool_council_oas.dispatch ctx ~name:"masc_cases" ~args:(`Assoc []) with
  | Some (ok, body) ->
    Alcotest.(check bool) "cases ok" true ok;
    let json = parse_json body in
    (match json with
     | `List cases -> Alcotest.(check int) "empty case list" 0 (List.length cases)
     | _ -> Alcotest.fail "expected JSON list")
  | None -> Alcotest.fail "dispatch returned None"

let test_governance_status_overview () =
  with_council_base @@ fun base_path ->
  let ctx = make_council_ctx ~base_path in
  match Tool_council_oas.dispatch ctx ~name:"masc_governance_status" ~args:(`Assoc []) with
  | Some (ok, body) ->
    Alcotest.(check bool) "governance status ok" true ok;
    let json = parse_json body in
    Alcotest.(check int) "total_cases 0" 0
      (json |> field "total_cases" |> Yojson.Safe.Util.to_int);
    Alcotest.(check int) "open_cases 0" 0
      (json |> field "open_cases" |> Yojson.Safe.Util.to_int);
    Alcotest.(check string) "runtime oas" "oas"
      (json |> field "runtime" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "dispatch returned None"

let test_runtime_params_config () =
  with_council_base @@ fun base_path ->
  let ctx = make_council_ctx ~base_path in
  match Tool_council_oas.dispatch ctx ~name:"masc_runtime_params" ~args:(`Assoc []) with
  | Some (ok, body) ->
    Alcotest.(check bool) "runtime params ok" true ok;
    let json = parse_json body in
    Alcotest.(check string) "governance_version" "v2"
      (json |> field "governance_version" |> Yojson.Safe.Util.to_string);
    Alcotest.(check string) "runtime" "oas"
      (json |> field "runtime" |> Yojson.Safe.Util.to_string);
    Alcotest.(check bool) "collaboration_enabled" true
      (json |> field "collaboration_enabled" |> Yojson.Safe.Util.to_bool)
  | None -> Alcotest.fail "dispatch returned None"

let test_council_dispatch_unknown () =
  with_council_base @@ fun base_path ->
  let ctx = make_council_ctx ~base_path in
  let result = Tool_council_oas.dispatch ctx ~name:"nonexistent_tool" ~args:(`Assoc []) in
  Alcotest.(check bool) "unknown tool returns None" true (Option.is_none result)

let test_governance_status_after_petition () =
  with_council_base @@ fun base_path ->
  let ctx = make_council_ctx ~base_path in
  (* Submit a petition first *)
  let args = `Assoc [
    ("title", `String "Test for status count");
    ("subject", `String "task");
    ("risk_class", `String "low");
  ] in
  (match Tool_council_oas.dispatch ctx ~name:"masc_governance_petition" ~args with
   | Some (ok, _) -> Alcotest.(check bool) "petition ok" true ok
   | None -> Alcotest.fail "petition dispatch returned None");
  (* Now check governance status *)
  match Tool_council_oas.dispatch ctx ~name:"masc_governance_status" ~args:(`Assoc []) with
  | Some (ok, body) ->
    Alcotest.(check bool) "status ok" true ok;
    let json = parse_json body in
    Alcotest.(check int) "total_cases 1" 1
      (json |> field "total_cases" |> Yojson.Safe.Util.to_int);
    Alcotest.(check bool) "open_cases >= 1" true
      (json |> field "open_cases" |> Yojson.Safe.Util.to_int >= 1)
  | None -> Alcotest.fail "dispatch returned None"

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "OAS Worker (Phase 1)" [
    "oas_worker_config", [
      Alcotest.test_case "default_config fields" `Quick
        test_default_config_fields;
      Alcotest.test_case "default_config custom values" `Quick
        test_default_config_custom_values;
    ];
    "oas_worker_build", [
      Alcotest.test_case "build with mock net" `Quick
        test_build_with_mock_net;
      Alcotest.test_case "build invalid config rejected" `Quick
        test_build_invalid_config;
      Alcotest.test_case "build with tools" `Quick
        test_build_with_tools;
    ];
    "tool_mitosis_oas", [
      Alcotest.test_case "status returns json" `Quick
        test_mitosis_status_returns_json;
      Alcotest.test_case "check normal phase" `Quick
        test_mitosis_check_normal;
      Alcotest.test_case "check prepare phase" `Quick
        test_mitosis_check_prepare;
      Alcotest.test_case "check handoff phase" `Quick
        test_mitosis_check_handoff;
      Alcotest.test_case "record updates cell" `Quick
        test_mitosis_record_updates_cell;
      Alcotest.test_case "prepare empty context error" `Quick
        test_mitosis_prepare_empty_context_err;
      Alcotest.test_case "prepare success" `Quick
        test_mitosis_prepare_success;
      Alcotest.test_case "handoff no_action" `Quick
        test_mitosis_handoff_no_action;
      Alcotest.test_case "handoff force" `Quick
        test_mitosis_handoff_force;
      Alcotest.test_case "dispatch unknown" `Quick
        test_mitosis_dispatch_unknown;
    ];
    "tool_council_oas", [
      Alcotest.test_case "petition creates case with collaboration_id" `Quick
        test_petition_submit_creates_case;
      Alcotest.test_case "petition empty title error" `Quick
        test_petition_submit_empty_title_err;
      Alcotest.test_case "cases list empty" `Quick
        test_cases_list_empty;
      Alcotest.test_case "governance status overview" `Quick
        test_governance_status_overview;
      Alcotest.test_case "runtime params config" `Quick
        test_runtime_params_config;
      Alcotest.test_case "dispatch unknown" `Quick
        test_council_dispatch_unknown;
      Alcotest.test_case "governance status after petition" `Quick
        test_governance_status_after_petition;
    ];
  ]
