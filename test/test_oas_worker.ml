(** Test_oas_worker — Unit tests for OAS worker streaming bridge,
    cascade config, mitosis, and council.

    LLM 0 — no real MODEL calls. Tests use mock net / temp directories.

    @since Phase 1 — MASC->OAS migration
    @since Phase A — OAS #215 streaming verification *)

open Masc_mcp

module Oas = Agent_sdk

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

(** Test default_config_path with a controlled fixture so the result
    is deterministic regardless of CWD or ME_ROOT.
    Creates a temp directory with config/cascade.json, sets ME_ROOT
    to point there, and verifies the function finds the file. *)
let test_default_config_path () =
  let base = temp_dir "test_config_path" in
  (* Build the nested directory tree *)
  let rec mkdir_p dir =
    if not (Sys.file_exists dir) then begin
      mkdir_p (Filename.dirname dir);
      Unix.mkdir dir 0o755
    end
  in
  let masc_config_dir = Filename.concat
    (Filename.concat base "workspace/yousleepwhen/masc-mcp")
    "config"
  in
  mkdir_p masc_config_dir;
  let cascade_path = Filename.concat masc_config_dir "cascade.json" in
  let oc = open_out cascade_path in
  output_string oc "{}";
  close_out oc;
  (* Save and override ME_ROOT *)
  let old_me_root = Sys.getenv_opt "ME_ROOT" in
  Unix.putenv "ME_ROOT" base;
  Fun.protect
    ~finally:(fun () ->
      (match old_me_root with
       | Some v -> Unix.putenv "ME_ROOT" v
       | None ->
           (* OCaml stdlib has no unsetenv; set to empty string
              which env_opt treats as absent. *)
           Unix.putenv "ME_ROOT" "");
      cleanup_dir base)
    (fun () ->
      match Oas_worker.default_config_path () with
      | Some path ->
        Alcotest.(check bool) "non-empty path" true (String.length path > 0);
        Alcotest.(check bool) "path contains separator" true
          (String.contains path '/');
        Alcotest.(check bool) "file exists" true (Sys.file_exists path)
      | None ->
        Alcotest.fail
          "default_config_path returned None despite fixture at ME_ROOT")

let test_cascade_names_produce_models () =
  let cascades = [
    "keeper_turn"; "heartbeat_action"; "heartbeat_wake";
    "autonomy_direct"; "classification"; "verifier";
    "briefing"; "routing_judge";
  ] in
  List.iter (fun name ->
    let models = Oas_worker.default_model_strings ~cascade_name:name in
    Alcotest.(check bool) (name ^ " has models") true (models <> [])
  ) cascades

let make_worker_meta ?(effective_model = "local-qwen") () :
    Worker_container_types.worker_container_meta =
  {
    Worker_container_types.version =
      Worker_container_types.worker_container_version;
    worker_name = "resume-worker";
    mcp_session_id = "session-1";
    team_session_id = Some "team-session-1";
    workspace_path = "/tmp/workspace";
    role = Some "executor";
    selection_note = Some "resume";
    execution_scope = Team_session_types.Limited_code_change;
    thinking_enabled = Some true;
    max_turns_override = None;
    timeout_seconds = Some 240;
    tool_profile = Worker_container_types.Profile_session_min;
    shell_profile = Worker_container_types.Shell_readonly;
    worker_class = Some Team_session_types.Worker_executor;
    worker_size = None;
    effective_model;
    effective_tier = None;
    checkpoint_path = "/tmp/checkpoint.json";
    turn_log_path = "/tmp/turns.jsonl";
    last_run_at = None;
  }

let make_checkpoint ?(model = "") () : Oas.Checkpoint.t =
  {
    Oas.Checkpoint.version = Oas.Checkpoint.checkpoint_version;
    session_id = "session-1";
    agent_name = "resume-worker";
    model;
    system_prompt = None;
    messages = [];
    usage = Oas.Types.empty_usage;
    turn_count = 0;
    created_at = 0.0;
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
    max_total_tokens = None;
    context = Oas.Context.create ();
    mcp_sessions = [];
    working_context = None;
  }

let test_resume_model_id_prefers_checkpoint_model () =
  let meta = make_worker_meta ~effective_model:"meta-model" () in
  let checkpoint = make_checkpoint ~model:"checkpoint-model" () in
  Alcotest.(check string) "checkpoint model wins" "checkpoint-model"
    (Worker_oas.resume_model_id_of_checkpoint meta checkpoint)

let test_resume_model_id_falls_back_to_meta_model () =
  let meta = make_worker_meta ~effective_model:"meta-model" () in
  let checkpoint = make_checkpoint () in
  Alcotest.(check string) "meta model fallback" "meta-model"
    (Worker_oas.resume_model_id_of_checkpoint meta checkpoint)

(* ================================================================ *)
(* Module 2: Tool_council_oas tests                                 *)
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
          ("cascade_name", `String "keeper_unified");
          ("last_model_used", `String "llama:auto");
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

let test_keeper_oas_handoff_rollover_increments_generation () =
  let base_dir = temp_dir "keeper_oas_handoff_rollover" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let meta =
        {
          (make_keeper_meta ()) with
          auto_handoff = true;
          handoff_threshold = 0.5;
          handoff_cooldown_sec = 0;
        }
      in
      let session =
        Keeper_exec_context.create_session ~session_id:meta.trace_id ~base_dir
      in
      let ctx =
        Keeper_exec_context.create ~system_prompt:"rollover" ~max_tokens:100
        |> fun ctx ->
        Keeper_exec_context.append ctx
          (Agent_sdk.Types.user_msg (String.make 800 'x'))
        |> Keeper_exec_context.sync_oas_context
      in
      let checkpoint =
        Keeper_exec_context.save_oas_checkpoint ~session
          ~agent_name:meta.agent_name
          ~model:"llama:auto"
          ~ctx ~generation:meta.generation
      in
      let rollover =
        Keeper_exec_context.maybe_rollover_oas_handoff ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:100
          ~checkpoint:(Some checkpoint)
      in
      Alcotest.(check int) "generation incremented" 1
        rollover.updated_meta.generation;
      Alcotest.(check bool) "trace rotated" true
        (rollover.updated_meta.trace_id <> meta.trace_id);
      Alcotest.(check bool) "trace history contains previous trace" true
        (List.mem meta.trace_id rollover.updated_meta.trace_history);
      Alcotest.(check bool) "handoff json present" true
        (Option.is_some rollover.handoff_json);
      let new_session =
        Keeper_exec_context.create_session
          ~session_id:rollover.updated_meta.trace_id
          ~base_dir
      in
      match
        Keeper_checkpoint_store.load_oas ~session_dir:new_session.session_dir
          ~session_id:rollover.updated_meta.trace_id
      with
      | Some loaded ->
          let generation =
            Option.bind loaded.working_context (fun json ->
                Yojson.Safe.Util.(
                  json |> member "generation" |> to_int_option))
          in
          Alcotest.(check (option int)) "new checkpoint generation preserved"
            (Some 1) generation
      | None -> Alcotest.fail "expected rollover checkpoint")

let test_keeper_oas_handoff_rollover_below_threshold_noop () =
  let base_dir = temp_dir "keeper_oas_handoff_noop" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let meta =
        {
          (make_keeper_meta ()) with
          auto_handoff = true;
          handoff_threshold = 0.9;
          handoff_cooldown_sec = 0;
        }
      in
      let session =
        Keeper_exec_context.create_session ~session_id:meta.trace_id ~base_dir
      in
      let ctx =
        Keeper_exec_context.create ~system_prompt:"stable" ~max_tokens:100
        |> fun ctx ->
        Keeper_exec_context.append ctx
          (Agent_sdk.Types.user_msg "short")
        |> Keeper_exec_context.sync_oas_context
      in
      let checkpoint =
        Keeper_exec_context.save_oas_checkpoint ~session
          ~agent_name:meta.agent_name
          ~model:"llama:auto"
          ~ctx ~generation:meta.generation
      in
      let rollover =
        Keeper_exec_context.maybe_rollover_oas_handoff ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:100
          ~checkpoint:(Some checkpoint)
      in
      Alcotest.(check string) "trace unchanged" meta.trace_id
        rollover.updated_meta.trace_id;
      Alcotest.(check int) "generation unchanged" meta.generation
        rollover.updated_meta.generation;
      Alcotest.(check bool) "handoff json absent" false
        (Option.is_some rollover.handoff_json))

(* ================================================================ *)
(* Same-trace checkpoint continuity regression (OAS #467)            *)
(* ================================================================ *)

(** Regression for OAS #467: verify that multi-turn checkpoint
    accumulates messages across save/load cycles within the same trace.
    Before the fix, Contract_runner.run did not sync state back to the
    original agent, so checkpoints only contained the current-turn
    message (1 msg) instead of the full accumulated history. *)
let test_same_trace_multi_turn_accumulation () =
  let base_dir = temp_dir "keeper_continuity_multi" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let trace_id = "trace-continuity-multi" in
      let session =
        Keeper_exec_context.create_session ~session_id:trace_id ~base_dir
      in
      (* Turn 1: save checkpoint with 2 messages *)
      let ctx_turn1 =
        Keeper_exec_context.create ~system_prompt:"continuity test" ~max_tokens:4096
        |> fun ctx ->
        Keeper_exec_context.append ctx (Agent_sdk.Types.user_msg "turn 1 user")
        |> fun ctx ->
        Keeper_exec_context.append ctx (Agent_sdk.Types.assistant_msg "turn 1 reply")
      in
      let meta = make_keeper_meta ~trace_id () in
      ignore
        (Keeper_exec_context.save_oas_checkpoint ~session
           ~agent_name:meta.agent_name
           ~model:"llama:auto" ~ctx:ctx_turn1 ~generation:0);
      (* Turn 2: load checkpoint, verify messages, add more *)
      let (_session2, loaded_opt) =
        Keeper_exec_context.load_context_from_checkpoint ~trace_id
          ~primary_model_max_tokens:4096 ~base_dir
      in
      let ctx_turn2 = match loaded_opt with
        | Some ctx ->
            Alcotest.(check int) "turn 2 loaded 2 messages from turn 1" 2
              (List.length ctx.messages);
            ctx
        | None -> Alcotest.fail "expected checkpoint after turn 1"
      in
      let ctx_turn2 =
        Keeper_exec_context.append ctx_turn2
          (Agent_sdk.Types.user_msg "turn 2 user")
        |> fun ctx ->
        Keeper_exec_context.append ctx
          (Agent_sdk.Types.assistant_msg "turn 2 reply")
      in
      let session2 =
        Keeper_exec_context.create_session ~session_id:trace_id ~base_dir
      in
      ignore
        (Keeper_exec_context.save_oas_checkpoint ~session:session2
           ~agent_name:meta.agent_name
           ~model:"llama:auto" ~ctx:ctx_turn2 ~generation:1);
      (* Immediate verify: reload right after second save to isolate
         save correctness from load correctness (GLM-5 review finding) *)
      let (_session_imm, immediate_opt) =
        Keeper_exec_context.load_context_from_checkpoint ~trace_id
          ~primary_model_max_tokens:4096 ~base_dir
      in
      (match immediate_opt with
       | Some imm ->
           Alcotest.(check int)
             "second save persisted 4 messages (save correctness)" 4
             (List.length imm.messages)
       | None -> Alcotest.fail "second save produced no loadable checkpoint");
      (* Final verify: full roundtrip content check *)
      let (_session3, final_opt) =
        Keeper_exec_context.load_context_from_checkpoint ~trace_id
          ~primary_model_max_tokens:4096 ~base_dir
      in
      match final_opt with
      | Some final ->
          Alcotest.(check int)
            "final checkpoint contains all 4 accumulated messages" 4
            (List.length final.messages);
          Alcotest.(check string) "first message preserved" "turn 1 user"
            (Agent_sdk.Types.text_of_message (List.nth final.messages 0));
          Alcotest.(check string) "last message is turn 2 reply" "turn 2 reply"
            (Agent_sdk.Types.text_of_message (List.nth final.messages 3))
      | None -> Alcotest.fail "expected checkpoint after turn 2")

(** Verify that checkpoint survives a simulated restart: fresh
    load_context_from_checkpoint returns non-empty messages after
    a prior save. This is the core "restart continuity" contract. *)
let test_restart_continuity_load_oas_non_empty () =
  let base_dir = temp_dir "keeper_continuity_restart" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let trace_id = "trace-continuity-restart" in
      let session =
        Keeper_exec_context.create_session ~session_id:trace_id ~base_dir
      in
      (* Save a checkpoint with 3 messages *)
      let ctx =
        Keeper_exec_context.create ~system_prompt:"restart test" ~max_tokens:4096
        |> fun c ->
        Keeper_exec_context.append c (Agent_sdk.Types.user_msg "msg1")
        |> fun c ->
        Keeper_exec_context.append c (Agent_sdk.Types.assistant_msg "msg2")
        |> fun c ->
        Keeper_exec_context.append c (Agent_sdk.Types.user_msg "msg3")
      in
      let meta = make_keeper_meta ~trace_id () in
      ignore
        (Keeper_exec_context.save_oas_checkpoint ~session
           ~agent_name:meta.agent_name
           ~model:"llama:auto" ~ctx ~generation:5);
      (* Simulate restart: fresh load with no runtime state *)
      let (_fresh_session, loaded_opt) =
        Keeper_exec_context.load_context_from_checkpoint ~trace_id
          ~primary_model_max_tokens:4096 ~base_dir
      in
      match loaded_opt with
      | Some loaded ->
          Alcotest.(check bool)
            "load_oas returns non-empty messages after restart" true
            (List.length loaded.messages > 0);
          Alcotest.(check int) "all 3 messages restored" 3
            (List.length loaded.messages);
          Alcotest.(check string) "system prompt restored" "restart test"
            loaded.system_prompt
      | None -> Alcotest.fail "checkpoint must survive restart")

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
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
    "resume_config", [
      Alcotest.test_case "checkpoint model wins" `Quick
        test_resume_model_id_prefers_checkpoint_model;
      Alcotest.test_case "meta model fallback" `Quick
        test_resume_model_id_falls_back_to_meta_model;
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
      Alcotest.test_case "OAS handoff rollover increments generation" `Quick
        test_keeper_oas_handoff_rollover_increments_generation;
      Alcotest.test_case "OAS handoff rollover noops below threshold" `Quick
        test_keeper_oas_handoff_rollover_below_threshold_noop;
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
      Alcotest.test_case "OAS handoff rollover increments generation" `Quick
        test_keeper_oas_handoff_rollover_increments_generation;
      Alcotest.test_case "OAS handoff rollover noops below threshold" `Quick
        test_keeper_oas_handoff_rollover_below_threshold_noop;
    ];
    "keeper_checkpoint_continuity", [
      Alcotest.test_case "same-trace multi-turn accumulation (OAS #467 regression)" `Quick
        test_same_trace_multi_turn_accumulation;
      Alcotest.test_case "restart continuity — load_oas returns non-empty messages" `Quick
        test_restart_continuity_load_oas_non_empty;
    ];
  ]
