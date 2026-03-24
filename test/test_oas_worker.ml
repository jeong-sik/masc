(** Test_oas_worker — Unit tests for OAS worker streaming bridge,
    cascade config, mitosis, and council.

    LLM 0 — no real MODEL calls. Tests use mock net / temp directories.

    @since Phase 1 — MASC->OAS migration
    @since Phase A — OAS #215 streaming verification *)

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
(* SSE Event Bridge Tests (OAS #215 streaming verification)         *)
(*                                                                   *)
(* keeper_turn.ml wraps on_text_delta into on_event, extracting     *)
(* TextDelta from ContentBlockDelta. Reproduce that bridge here.    *)
(* ================================================================ *)

(** Reproduce the exact bridge logic from keeper_turn.ml:32-37. *)
let make_on_event_bridge (buf : Buffer.t) : Agent_sdk.Types.sse_event -> unit =
  fun evt ->
    match evt with
    | Agent_sdk.Types.ContentBlockDelta { delta = TextDelta text; _ } ->
        Buffer.add_string buf text
    | _ -> ()

let test_text_delta_extraction () =
  let buf = Buffer.create 64 in
  let on_event = make_on_event_bridge buf in
  on_event (ContentBlockDelta { index = 0; delta = TextDelta "Hello" });
  on_event (ContentBlockDelta { index = 0; delta = TextDelta " " });
  on_event (ContentBlockDelta { index = 0; delta = TextDelta "world" });
  Alcotest.(check string) "accumulated text" "Hello world" (Buffer.contents buf)

let test_non_text_events_ignored () =
  let buf = Buffer.create 64 in
  let on_event = make_on_event_bridge buf in
  on_event (MessageStart { id = "m1"; model = "test"; usage = None });
  on_event (ContentBlockStart { index = 0; content_type = "text";
                                tool_id = None; tool_name = None });
  on_event (ContentBlockStop { index = 0 });
  on_event (MessageDelta { stop_reason = Some EndTurn; usage = None });
  on_event MessageStop;
  on_event Ping;
  Alcotest.(check string) "buffer empty" "" (Buffer.contents buf)

let test_mixed_event_stream () =
  let buf = Buffer.create 64 in
  let on_event = make_on_event_bridge buf in
  on_event (MessageStart { id = "m1"; model = "test"; usage = None });
  on_event (ContentBlockStart { index = 0; content_type = "text";
                                tool_id = None; tool_name = None });
  on_event (ContentBlockDelta { index = 0; delta = TextDelta "token1" });
  on_event (ContentBlockDelta { index = 0; delta = TextDelta " token2" });
  on_event (ContentBlockStop { index = 0 });
  (* Tool use block — InputJsonDelta, not TextDelta *)
  on_event (ContentBlockStart { index = 1; content_type = "tool_use";
                                tool_id = Some "t1"; tool_name = Some "calc" });
  on_event (ContentBlockDelta { index = 1;
                                delta = InputJsonDelta "{\"x\":1}" });
  on_event (ContentBlockStop { index = 1 });
  on_event (MessageDelta { stop_reason = Some EndTurn; usage = None });
  on_event MessageStop;
  Alcotest.(check string) "text only" "token1 token2" (Buffer.contents buf)

let test_empty_text_delta () =
  let buf = Buffer.create 64 in
  let on_event = make_on_event_bridge buf in
  on_event (ContentBlockDelta { index = 0; delta = TextDelta "" });
  on_event (ContentBlockDelta { index = 0; delta = TextDelta "a" });
  on_event (ContentBlockDelta { index = 0; delta = TextDelta "" });
  Alcotest.(check string) "empty deltas transparent" "a" (Buffer.contents buf)

let test_sse_error_event_ignored () =
  let buf = Buffer.create 64 in
  let on_event = make_on_event_bridge buf in
  on_event (ContentBlockDelta { index = 0; delta = TextDelta "before" });
  on_event (SSEError "something went wrong");
  on_event (ContentBlockDelta { index = 0; delta = TextDelta " after" });
  Alcotest.(check string) "error transparent" "before after" (Buffer.contents buf)

(* ================================================================ *)
(* Cascade Config Tests (public API)                                *)
(* ================================================================ *)

let test_default_model_strings_keeper () =
  let models = Oas_worker.default_model_strings ~cascade_name:"keeper_turn" in
  Alcotest.(check bool) "keeper_turn has models" true (models <> [])

let test_default_model_strings_heartbeat () =
  let models = Oas_worker.default_model_strings ~cascade_name:"heartbeat_action" in
  Alcotest.(check bool) "heartbeat has models" true (models <> [])

let test_default_model_strings_unknown () =
  let models = Oas_worker.default_model_strings ~cascade_name:"nonexistent_cascade_xyz" in
  Alcotest.(check bool) "unknown cascade has fallback" true (models <> [])

let test_default_config_path () =
  let _path = Oas_worker.default_config_path () in
  Alcotest.(check pass) "default_config_path does not raise" () ()

let test_cascade_names_produce_models () =
  let cascades = [
    "keeper_turn"; "heartbeat_action"; "heartbeat_wake";
    "lodge_direct"; "classification"; "verifier";
    "briefing"; "walph"; "routing_judge";
  ] in
  List.iter (fun name ->
    let models = Oas_worker.default_model_strings ~cascade_name:name in
    Alcotest.(check bool) (name ^ " has models") true (models <> [])
  ) cascades

(* ================================================================ *)
(* Module 2: Tool_mitosis_oas tests                                 *)
(* ================================================================ *)

let reset_mitosis_state () =
  Mcp_server.current_cell := Mitosis.create_stem_cell ~generation:0;
  Mcp_server.stem_pool := Mitosis.init_pool ~config:Mitosis.default_config

let noop_dispatch ~name:_ ~args:_ = (true, "{}")

let make_mitosis_ctx ~base_path : Tool_mitosis_oas.context =
  let config = Room.default_config base_path in
  { config; agent_name = "test-agent"; masc_tools = []; dispatch = noop_dispatch }

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
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  Eio_context.set_net net;
  Eio_context.set_switch sw;
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
  { base_path; agent_name = "test-agent"; room_config = None;
    policy = None; audit = None }

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
  match Tool_council_oas.dispatch ctx ~name:"masc_petition_submit" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "petition ok" true ok;
    let json = parse_json body in
    let case_id = json |> field "case_id" |> Yojson.Safe.Util.to_string in
    Alcotest.(check bool) "case_id non-empty" true (String.length case_id > 0);
    Alcotest.(check string) "collaboration_id compatibility alias" case_id
      (json |> field "collaboration_id" |> Yojson.Safe.Util.to_string);
    Alcotest.(check string) "phase compatibility alias" "active"
      (json |> field "phase" |> Yojson.Safe.Util.to_string);
    (match Council.Governance_v2.get_case_bundle base_path case_id with
     | Ok bundle ->
         let source_refs =
           bundle.Council.Governance_v2.case_
             .Council.Governance_v2.source_refs
         in
         Alcotest.(check (list string)) "source_refs empty" []
           source_refs
     | Error err -> Alcotest.fail ("get_case_bundle failed: " ^ err));
    Alcotest.(check bool) "merged field present" true
      (Yojson.Safe.Util.member "merged" json <> `Null)
  | None -> Alcotest.fail "dispatch returned None"

let test_petition_submit_accepts_subject_type () =
  with_council_base @@ fun base_path ->
  let ctx = make_council_ctx ~base_path in
  let args = `Assoc [
    ("title", `String "Schema-aligned petition");
    ("subject_type", `String "policy");
    ("risk_class", `String "low");
  ] in
  match Tool_council_oas.dispatch ctx ~name:"masc_petition_submit" ~args with
  | Some (ok, body) ->
    Alcotest.(check bool) "petition ok" true ok;
    let json = parse_json body in
    let case_id = json |> field "case_id" |> Yojson.Safe.Util.to_string in
    Alcotest.(check bool) "case_id non-empty" true (String.length case_id > 0)
  | None -> Alcotest.fail "dispatch returned None"

let test_petition_submit_empty_title_err () =
  with_council_base @@ fun base_path ->
  let ctx = make_council_ctx ~base_path in
  let args = `Assoc [("title", `String "")] in
  match Tool_council_oas.dispatch ctx ~name:"masc_petition_submit" ~args with
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
  let args = `Assoc [
    ("title", `String "Test for status count");
    ("subject", `String "task");
    ("risk_class", `String "low");
  ] in
  (match Tool_council_oas.dispatch ctx ~name:"masc_petition_submit" ~args with
   | Some (ok, _) -> Alcotest.(check bool) "petition ok" true ok
   | None -> Alcotest.fail "petition dispatch returned None");
  match Tool_council_oas.dispatch ctx ~name:"masc_governance_status" ~args:(`Assoc []) with
  | Some (ok, body) ->
    Alcotest.(check bool) "status ok" true ok;
    let json = parse_json body in
    Alcotest.(check int) "total_cases 1" 1
      (json |> field "total_cases" |> Yojson.Safe.Util.to_int);
    Alcotest.(check bool) "open_cases >= 1" true
      (json |> field "open_cases" |> Yojson.Safe.Util.to_int >= 1)
  | None -> Alcotest.fail "dispatch returned None"

let test_case_brief_submit_accepts_evidence_refs_array () =
  with_council_base @@ fun base_path ->
  let ctx = make_council_ctx ~base_path in
  let petition_args = `Assoc [
    ("title", `String "Brief evidence case");
    ("subject_type", `String "task");
    ("risk_class", `String "low");
  ] in
  let case_id =
    match Tool_council_oas.dispatch ctx ~name:"masc_petition_submit"
            ~args:petition_args with
    | Some (true, body) ->
      parse_json body |> field "case_id" |> Yojson.Safe.Util.to_string
    | Some (false, body) ->
      Alcotest.failf "petition failed: %s" body
    | None -> Alcotest.fail "petition dispatch returned None"
  in
  let brief_args = `Assoc [
    ("case_id", `String case_id);
    ("stance", `String "support");
    ("summary", `String "Ship it");
    ("evidence_refs", `List [ `String "trace:abc"; `String "doc:123" ]);
  ] in
  match Tool_council_oas.dispatch ctx ~name:"masc_case_brief_submit"
          ~args:brief_args with
  | Some (ok, body) ->
    Alcotest.(check bool) "brief ok" true ok;
    let json = parse_json body in
    Alcotest.(check string) "case_id preserved" case_id
      (json |> field "case_id" |> Yojson.Safe.Util.to_string);
    Alcotest.(check string) "stance preserved" "support"
      (json |> field "stance" |> Yojson.Safe.Util.to_string)
  | None -> Alcotest.fail "dispatch returned None"

(* ================================================================ *)
(* Keeper checkpoint boundary tests                                  *)
(* ================================================================ *)
(* ================================================================ *)
(* Keeper checkpoint boundary tests                                  *)
(* ================================================================ *)

let make_keeper_meta ?(name = "keeper-checkpoint-test")
    ?(trace_id = "trace-keeper-checkpoint") () =
  match
    Keeper_types.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String trace_id);
          ("active_model", `String "llama:auto");
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)

let make_oas_checkpoint
    ?(session_id = "trace-keeper-checkpoint")
    ?(created_at = 1000.0)
    ?(system_prompt = Some "oas system")
    ?(messages = [])
    ?(working_context = None)
    ?(max_total_tokens = Some 4096)
    ()
  : Agent_sdk.Checkpoint.t =
  {
    Agent_sdk.Checkpoint.version = Agent_sdk.Checkpoint.checkpoint_version;
    session_id;
    agent_name = "keeper-checkpoint-test";
    model = "llama:auto";
    system_prompt;
    messages;
    usage = Agent_sdk.Types.empty_usage;
    turn_count = List.length messages;
    created_at;
    tools = [];
    tool_choice = None;
    disable_parallel_tool_use = false;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    enable_thinking = None;
    response_format_json = false;
    thinking_budget = None;
    cache_system_prompt = false;
    max_input_tokens = None;
    max_total_tokens;
    context = Agent_sdk.Context.create ();
    mcp_sessions = [];
    working_context;
  }

let test_keeper_checkpoint_store_oas_roundtrip () =
  let base_dir = temp_dir "keeper_oas_store" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let session_dir = Filename.concat base_dir "trace-store" in
      let sidecar = Some (`Assoc [("max_tokens", `Int 4096)]) in
      let checkpoint =
        make_oas_checkpoint ~session_id:"trace-store"
          ~messages:[Agent_sdk.Types.user_msg "roundtrip"]
          ~working_context:sidecar ()
      in
      Keeper_checkpoint_store.save_oas ~session_dir checkpoint;
      match
        Keeper_checkpoint_store.load_oas ~session_dir ~session_id:"trace-store"
      with
      | Some loaded ->
          Alcotest.(check (float 0.000001)) "created_at preserved"
            checkpoint.created_at
            loaded.created_at;
          Alcotest.(check int) "message count preserved" 1
            (List.length loaded.messages);
          let sidecar_max_tokens =
            Option.bind loaded.working_context (fun json ->
                Yojson.Safe.Util.(
                  json |> member "max_tokens" |> to_int_option))
          in
          Alcotest.(check (option int)) "sidecar max_tokens preserved"
            (Some 4096)
            sidecar_max_tokens
      | None -> Alcotest.fail "expected OAS checkpoint roundtrip")

let test_keeper_checkpoint_store_oas_missing_returns_none () =
  let base_dir = temp_dir "keeper_oas_store_missing" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let session_dir = Filename.concat base_dir "missing-session" in
      Alcotest.(check (option string)) "missing checkpoint"
        None
        (Keeper_checkpoint_store.load_oas ~session_dir
           ~session_id:"missing-session"
         |> Option.map (fun (cp : Agent_sdk.Checkpoint.t) -> cp.session_id)))

let test_keeper_checkpoint_prefers_oas_checkpoint () =
  let base_dir = temp_dir "keeper_oas_checkpoint" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let trace_id = "trace-oas-preferred" in
      let session =
        Keeper_exec_context.create_session ~session_id:trace_id ~base_dir
      in
      let legacy_ctx =
        Keeper_exec_context.create ~system_prompt:"legacy system" ~max_tokens:2048
        |> fun ctx ->
        Keeper_exec_context.append ctx (Agent_sdk.Types.user_msg "legacy")
      in
      ignore (Keeper_exec_context.save_checkpoint session legacy_ctx ~generation:1);
      let oas_ctx =
        Keeper_exec_context.create ~system_prompt:"oas system" ~max_tokens:4096
        |> fun ctx ->
        Keeper_exec_context.append ctx (Agent_sdk.Types.user_msg "oas")
      in
      let meta = make_keeper_meta ~trace_id () in
      ignore
        (Keeper_exec_context.save_oas_checkpoint ~session
           ~agent_name:meta.agent_name
           ~model:(Keeper_exec_context.checkpoint_model_of_meta meta)
           ~ctx:oas_ctx ~generation:7);
      let (_session, loaded_opt) =
        Keeper_exec_context.load_context_from_checkpoint ~trace_id
          ~primary_model_max_tokens:1024 ~base_dir
      in
      match loaded_opt with
      | Some loaded ->
          Alcotest.(check string) "system prompt from OAS checkpoint"
            "oas system" loaded.system_prompt;
          Alcotest.(check int) "max_tokens from OAS sidecar" 4096
            loaded.max_tokens;
          Alcotest.(check string) "loaded OAS message" "oas"
            (Agent_sdk.Types.text_of_message (List.hd loaded.messages))
      | None -> Alcotest.fail "expected checkpoint context")

let test_keeper_checkpoint_legacy_fallback () =
  let base_dir = temp_dir "keeper_legacy_checkpoint" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let trace_id = "trace-legacy-fallback" in
      let session =
        Keeper_exec_context.create_session ~session_id:trace_id ~base_dir
      in
      let legacy_ctx =
        Keeper_exec_context.create ~system_prompt:"legacy only" ~max_tokens:2048
        |> fun ctx ->
        Keeper_exec_context.append ctx (Agent_sdk.Types.user_msg "legacy-only")
      in
      ignore (Keeper_exec_context.save_checkpoint session legacy_ctx ~generation:2);
      let (_session, loaded_opt) =
        Keeper_exec_context.load_context_from_checkpoint ~trace_id
          ~primary_model_max_tokens:1024 ~base_dir
      in
      match loaded_opt with
      | Some loaded ->
          Alcotest.(check string) "legacy prompt restored" "legacy only"
            loaded.system_prompt;
          Alcotest.(check string) "legacy message restored" "legacy-only"
            (Agent_sdk.Types.text_of_message (List.hd loaded.messages))
      | None -> Alcotest.fail "expected legacy fallback context")

let test_keeper_checkpoint_prefers_newer_legacy_during_migration () =
  let base_dir = temp_dir "keeper_checkpoint_migration" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let trace_id = "trace-migration-prefer-legacy" in
      let session =
        Keeper_exec_context.create_session ~session_id:trace_id ~base_dir
      in
      let old_oas =
        make_oas_checkpoint ~session_id:trace_id ~created_at:10.0
          ~system_prompt:(Some "old oas")
          ~messages:[Agent_sdk.Types.user_msg "old-oas"]
          ~working_context:(Some (`Assoc [("max_tokens", `Int 3000)])) ()
      in
      Keeper_checkpoint_store.save_oas ~session_dir:session.session_dir old_oas;
      let legacy_ctx =
        Keeper_exec_context.create ~system_prompt:"new legacy" ~max_tokens:2048
        |> fun ctx ->
        Keeper_exec_context.append ctx (Agent_sdk.Types.user_msg "new-legacy")
      in
      ignore (Keeper_exec_context.save_checkpoint session legacy_ctx ~generation:9);
      let (_session, loaded_opt) =
        Keeper_exec_context.load_context_from_checkpoint ~trace_id
          ~primary_model_max_tokens:1024 ~base_dir
      in
      match loaded_opt with
      | Some loaded ->
          Alcotest.(check string) "newer legacy prompt restored" "new legacy"
            loaded.system_prompt;
          Alcotest.(check string) "newer legacy message restored" "new-legacy"
            (Agent_sdk.Types.text_of_message (List.hd loaded.messages))
      | None -> Alcotest.fail "expected migration fallback context")

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "OAS Worker" [
    "sse_event_bridge", [
      Alcotest.test_case "text delta extraction" `Quick
        test_text_delta_extraction;
      Alcotest.test_case "non-text events ignored" `Quick
        test_non_text_events_ignored;
      Alcotest.test_case "mixed event stream" `Quick
        test_mixed_event_stream;
      Alcotest.test_case "empty text deltas transparent" `Quick
        test_empty_text_delta;
      Alcotest.test_case "SSE error event ignored" `Quick
        test_sse_error_event_ignored;
    ];
    "cascade_config", [
      Alcotest.test_case "keeper_turn default models" `Quick
        test_default_model_strings_keeper;
      Alcotest.test_case "heartbeat default models" `Quick
        test_default_model_strings_heartbeat;
      Alcotest.test_case "unknown cascade fallback" `Quick
        test_default_model_strings_unknown;
      Alcotest.test_case "default_config_path" `Quick
        test_default_config_path;
      Alcotest.test_case "all cascade names produce models" `Quick
        test_cascade_names_produce_models;
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
      Alcotest.test_case "petition creates case without decorative collaboration" `Quick
        test_petition_submit_creates_case;
      Alcotest.test_case "petition accepts subject_type" `Quick
        test_petition_submit_accepts_subject_type;
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
      Alcotest.test_case "case brief accepts evidence_refs array" `Quick
        test_case_brief_submit_accepts_evidence_refs_array;
    ];
    "keeper_checkpoint_boundary", [
      Alcotest.test_case "prefers OAS checkpoint over legacy" `Quick
        test_keeper_checkpoint_prefers_oas_checkpoint;
      Alcotest.test_case "legacy fallback still works" `Quick
        test_keeper_checkpoint_legacy_fallback;
    ];
    "keeper_checkpoint_store", [
      Alcotest.test_case "OAS store roundtrip" `Quick
        test_keeper_checkpoint_store_oas_roundtrip;
      Alcotest.test_case "OAS store missing returns none" `Quick
        test_keeper_checkpoint_store_oas_missing_returns_none;
      Alcotest.test_case "prefers OAS checkpoint over legacy" `Quick
        test_keeper_checkpoint_prefers_oas_checkpoint;
      Alcotest.test_case "legacy fallback still works" `Quick
        test_keeper_checkpoint_legacy_fallback;
      Alcotest.test_case "prefers newer legacy during migration" `Quick
        test_keeper_checkpoint_prefers_newer_legacy_during_migration;
    ];
  ]
