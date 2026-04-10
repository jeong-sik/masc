(** Test_oas_worker — Unit tests for OAS worker streaming bridge,
    cascade config, and governance integration.

    LLM 0 — no real MODEL calls. Tests use mock net / temp directories.

    @since Phase 1 — MASC->OAS migration
    @since Phase A — OAS #215 streaming verification *)

open Masc_mcp

module Oas = Agent_sdk

(* ================================================================ *)
(* Shared test infrastructure                                       *)
(* ================================================================ *)

let test_counter = ref 0
let test_net : ([ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ref) =
  ref None

let require_test_net () =
  match !test_net with
  | Some net -> net
  | None -> failwith "test net not initialized"

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

let _parse_json s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> failwith ("invalid json: " ^ e)

let _field key json = Yojson.Safe.Util.member key json

let make_local_provider ?(model_id = "mock-model") () : Oas.Provider.config =
  {
    Oas.Provider.provider = Oas.Provider.Local { base_url = "http://127.0.0.1:1" };
    model_id;
    api_key_env = "";
  }

let make_noop_tool () =
  Oas.Tool.create
    ~name:"noop"
    ~description:"No-op test tool"
    ~parameters:[]
    (fun _ -> Ok Oas.Types.{ content = "ok" })

let openai_text_response ?(id = "chatcmpl-1") text =
  Printf.sprintf
    {|{"id":"%s","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}|}
    id text

let escape_json_string s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | _ -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let openai_tool_use_response tool_name input_json =
  Printf.sprintf
    {|{"id":"chatcmpl-t","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"%s","arguments":"%s"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":15,"completion_tokens":10,"total_tokens":25}}|}
    tool_name (escape_json_string input_json)

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if needle_len = 0 then
      true
    else if idx + needle_len > haystack_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else
      loop (idx + 1)
  in
  loop 0

let response_text (resp : Oas.Types.api_response) =
  resp.Oas.Types.content
  |> List.filter_map (function Oas.Types.Text s -> Some s | _ -> None)
  |> String.concat ""

let start_multi_mock ~sw ~net ~port (responses : string list) =
  let idx = Atomic.make 0 in
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let n = List.length responses in
    let i = Atomic.fetch_and_add idx 1 in
    let resp = List.nth responses (i mod n) in
    Cohttp_eio.Server.respond_string ~status:`OK ~body:resp ()
  in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
      | () ->
          (match Unix.getsockname socket with
           | Unix.ADDR_INET (_, port) -> Some port
           | _ -> failwith "unexpected socket address")
      | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) -> None)

let with_raw_trace prefix f =
  let dir = temp_dir prefix in
  let path = Filename.concat dir "trace.jsonl" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      match Oas.Raw_trace.create ~path () with
      | Ok raw_trace -> f raw_trace
      | Error err -> Alcotest.fail (Oas.Error.to_string err))

let check_policy_matches_default_internal label
    (policy : Oas.Tool_retry_policy.t option) =
  let expected = Oas.Tool_retry_policy.default_internal in
  let actual =
    match policy with
    | Some policy -> policy
    | None -> Alcotest.fail (label ^ ": missing retry policy")
  in
  Alcotest.(check int) (label ^ ": max_retries")
    expected.max_retries actual.max_retries;
  Alcotest.(check bool) (label ^ ": retry_on_validation_error")
    expected.retry_on_validation_error actual.retry_on_validation_error;
  Alcotest.(check bool) (label ^ ": retry_on_recoverable_tool_error")
    expected.retry_on_recoverable_tool_error
    actual.retry_on_recoverable_tool_error;
  Alcotest.(check bool) (label ^ ": structured feedback")
    true
    (match actual.feedback_style with
     | Oas.Tool_retry_policy.Structured_tool_result -> true
     | Oas.Tool_retry_policy.Plain_error_text -> false)

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
    is deterministic regardless of CWD or inherited env.
    Creates a temp directory with .masc/config/cascade.json, sets MASC_BASE_PATH
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
  let masc_config_dir = Filename.concat base ".masc/config" in
  mkdir_p masc_config_dir;
  let cascade_path = Filename.concat masc_config_dir "cascade.json" in
  let oc = open_out cascade_path in
  output_string oc "{}";
  close_out oc;
  (* Save and override MASC_BASE_PATH *)
  let old_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_BASE_PATH" base;
  Fun.protect
    ~finally:(fun () ->
      (match old_base_path with
       | Some v -> Unix.putenv "MASC_BASE_PATH" v
       | None ->
           (* OCaml stdlib has no unsetenv; set to empty string
              which env_opt treats as absent. *)
           Unix.putenv "MASC_BASE_PATH" "");
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
          "default_config_path returned None despite fixture at MASC_BASE_PATH/.masc/config")

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

let test_cascade_observation_json_includes_fallback_fields () =
  let observation : Oas_worker.cascade_observation =
    {
      cascade_name = "keeper_unified";
      configured_labels = [ "glm:auto"; "llama:auto" ];
      candidate_models = [ "glm:glm-5.1"; "openai:qwen3.5-35b" ];
      primary_model = Some "glm:glm-5.1";
      selected_model = Some "openai:qwen3.5-35b";
      selected_model_raw = Some "qwen3.5-35b";
      selected_index = Some 1;
      fallback_hops = Some 1;
      fallback_applied = true;
      attempts =
        [
          {
            attempt_index = 0;
            model_id = "glm-5.1";
            model_label = Some "glm:glm-5.1";
            latency_ms = None;
            error = Some "HTTP 503";
          };
          {
            attempt_index = 1;
            model_id = "qwen3.5-35b";
            model_label = Some "openai:qwen3.5-35b";
            latency_ms = Some 212;
            error = None;
          };
        ];
      fallback_events =
        [
          {
            from_model_id = "glm-5.1";
            from_model_label = Some "glm:glm-5.1";
            to_model_id = "qwen3.5-35b";
            to_model_label = Some "openai:qwen3.5-35b";
            reason = "HTTP 503";
          };
        ];
      attempt_details_available = true;
      attempt_details_source = "oas_metrics_callbacks";
    }
  in
  let json = Oas_worker.cascade_observation_to_json observation in
  Alcotest.(check string) "cascade name preserved" "keeper_unified"
    Yojson.Safe.Util.(json |> member "cascade_name" |> to_string);
  Alcotest.(check bool) "fallback applied preserved" true
    Yojson.Safe.Util.(json |> member "fallback_applied" |> to_bool);
  Alcotest.(check int) "fallback hops preserved" 1
    Yojson.Safe.Util.(json |> member "fallback_hops" |> to_int);
  Alcotest.(check string) "selected model preserved" "openai:qwen3.5-35b"
    Yojson.Safe.Util.(json |> member "selected_model" |> to_string);
  Alcotest.(check int) "attempt count preserved" 2
    Yojson.Safe.Util.(json |> member "attempts" |> to_list |> List.length);
  Alcotest.(check int) "fallback event count preserved" 1
    Yojson.Safe.Util.(
      json |> member "fallback_events" |> to_list |> List.length);
  Alcotest.(check bool) "attempt details marked available" true
    Yojson.Safe.Util.(json |> member "attempt_details_available" |> to_bool);
  Alcotest.(check string) "attempt detail boundary preserved" "oas_metrics_callbacks"
    Yojson.Safe.Util.(json |> member "attempt_details_source" |> to_string)

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
    effective_model;
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

let test_oas_worker_exec_build_defaults_without_retry_policy () =
  let provider = make_local_provider () in
  let config =
    Oas_worker_exec.default_config
      ~name:"oas-worker-default"
      ~provider
      ~model_id:"mock-model"
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  match Oas_worker_exec.build ~net:(require_test_net ()) ~config with
  | Ok agent ->
      let policy = (Oas.Agent.options agent).tool_retry_policy in
      Alcotest.(check bool) "default leaves retry disabled" true
        (Option.is_none policy);
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

let test_oas_worker_exec_build_applies_retry_policy () =
  let provider = make_local_provider () in
  let base_config =
    Oas_worker_exec.default_config
      ~name:"oas-worker-retry"
      ~provider
      ~model_id:"mock-model"
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  let config =
    { base_config with
      tool_retry_policy = Some Oas.Tool_retry_policy.default_internal }
  in
  match Oas_worker_exec.build ~net:(require_test_net ()) ~config with
  | Ok agent ->
      let policy = (Oas.Agent.options agent).tool_retry_policy in
      check_policy_matches_default_internal "exec build opt-in" policy;
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

let test_oas_worker_exec_build_default_priority_unset () =
  let provider = make_local_provider () in
  let config =
    Oas_worker_exec.default_config
      ~name:"oas-worker-default-priority"
      ~provider
      ~model_id:"mock-model"
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  match Oas_worker_exec.build ~net:(require_test_net ()) ~config with
  | Ok agent ->
      let priority = (Oas.Agent.state agent).config.priority in
      Alcotest.(check bool) "default priority remains unset" true
        (Option.is_none priority);
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

let test_oas_worker_exec_build_applies_priority () =
  let provider = make_local_provider () in
  let base_config =
    Oas_worker_exec.default_config
      ~name:"oas-worker-priority"
      ~provider
      ~model_id:"mock-model"
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  let config =
    { base_config with
      priority = Some Llm_provider.Request_priority.Proactive }
  in
  match Oas_worker_exec.build ~net:(require_test_net ()) ~config with
  | Ok agent ->
      let priority = (Oas.Agent.state agent).config.priority in
      Alcotest.(check bool) "priority propagated to agent config" true
        (match priority with
         | Some Llm_provider.Request_priority.Proactive -> true
         | _ -> false);
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

let test_worker_build_agent_uses_default_internal_retry_policy () =
  with_raw_trace "worker_build_agent_retry" @@ fun raw_trace ->
  let meta = make_worker_meta () in
  let provider = make_local_provider ~model_id:meta.effective_model () in
  match
    Worker_oas.build_agent
      ~net:(require_test_net ())
      ~meta
      ~provider
      ~system_prompt:"worker system"
      ~tools:[ make_noop_tool () ]
      ~hooks:Oas.Hooks.empty
      ~raw_trace
      ~heartbeat_callbacks:[]
      ()
  with
  | Ok agent ->
      let policy = (Oas.Agent.options agent).tool_retry_policy in
      check_policy_matches_default_internal "worker build_agent" policy;
      Oas.Agent.close agent
  | Error err -> Alcotest.fail err

let test_build_resume_config_propagates_retry_policy () =
  with_raw_trace "worker_resume_config_retry" @@ fun raw_trace ->
  let provider = make_local_provider () in
  let (_config, options) =
    Worker_container.build_resume_config
      ~worker_name:"resume-worker"
      ~provider
      ~model_id:"mock-model"
      ~system_prompt:"resume system"
      ~tools:[ make_noop_tool () ]
      ~max_turns:7
      ~thinking_enabled:true
      ~hooks:Oas.Hooks.empty
      ~raw_trace
      ~tool_retry_policy:Oas.Tool_retry_policy.default_internal
      ()
  in
  let policy = options.tool_retry_policy in
  check_policy_matches_default_internal "resume config" policy

let test_worker_build_agent_validation_retry_success () =
  try
    Eio.Switch.run @@ fun sw ->
    let responses =
      [
        openai_tool_use_response "get_time" {|{}|};
        openai_tool_use_response "get_time" {|{"timezone":"UTC"}|};
        openai_text_response "The time is 12:00 UTC";
      ]
    in
    let port = match find_free_port () with Some port -> port | None -> Alcotest.skip () in
    let url =
      try start_multi_mock ~sw ~net:(require_test_net ()) ~port responses
      with
      | Unix.Unix_error (Unix.EPERM, "bind", _)
      | Unix.Unix_error (Unix.EACCES, "bind", _) ->
          Alcotest.skip ()
    in
    let provider : Oas.Provider.config =
      {
        provider = Oas.Provider.Local { base_url = url };
        model_id = "mock-model";
        api_key_env = "";
      }
    in
    let time_tool =
      Oas.Tool.create
        ~name:"get_time"
        ~description:"Get current time"
        ~parameters:
          [
            {
              name = "timezone";
              param_type = Oas.Types.String;
              description = "tz";
              required = true;
            };
          ]
        (fun _input -> Ok Oas.Types.{ content = "12:00 UTC" })
    in
    with_raw_trace "worker_build_agent_validation_retry" @@ fun raw_trace ->
    let meta = make_worker_meta () in
    match
      Worker_oas.build_agent
        ~net:(require_test_net ())
        ~meta
        ~provider
        ~system_prompt:"worker system"
        ~tools:[ time_tool ]
        ~hooks:Oas.Hooks.empty
        ~raw_trace
        ~heartbeat_callbacks:[]
        ()
    with
    | Ok agent ->
        Fun.protect
          ~finally:(fun () -> Oas.Agent.close agent)
          (fun () ->
            match Oas.Agent.run ~sw agent "what time is it?" with
            | Ok resp ->
                let text =
                  resp.Oas.Types.content
                  |> List.filter_map (function Oas.Types.Text s -> Some s | _ -> None)
                  |> String.concat ""
                in
                Alcotest.(check string) "final text after retry"
                  "The time is 12:00 UTC" text;
                Eio.Switch.fail sw Exit
            | Error err -> Alcotest.fail (Oas.Error.to_string err))
    | Error err -> Alcotest.fail err
  with Exit -> ()

let test_worker_build_agent_validation_retry_exhausted () =
  try
    Eio.Switch.run @@ fun sw ->
    let responses =
      [
        openai_tool_use_response "get_time" {|{}|};
        openai_tool_use_response "get_time" {|{}|};
        openai_tool_use_response "get_time" {|{}|};
        openai_text_response "should not happen";
      ]
    in
    let port =
      match find_free_port () with Some port -> port | None -> Alcotest.skip ()
    in
    let url =
      try start_multi_mock ~sw ~net:(require_test_net ()) ~port responses
      with
      | Unix.Unix_error (Unix.EPERM, "bind", _)
      | Unix.Unix_error (Unix.EACCES, "bind", _) ->
          Alcotest.skip ()
    in
    let provider : Oas.Provider.config =
      {
        provider = Oas.Provider.Local { base_url = url };
        model_id = "mock-model";
        api_key_env = "";
      }
    in
    let time_tool =
      Oas.Tool.create
        ~name:"get_time"
        ~description:"Get current time"
        ~parameters:
          [
            {
              name = "timezone";
              param_type = Oas.Types.String;
              description = "tz";
              required = true;
            };
          ]
        (fun _input -> Ok Oas.Types.{ content = "12:00 UTC" })
    in
    with_raw_trace "worker_build_agent_validation_retry_exhausted" @@ fun raw_trace ->
    let meta = make_worker_meta () in
    match
      Worker_oas.build_agent
        ~net:(require_test_net ())
        ~meta
        ~provider
        ~system_prompt:"worker system"
        ~tools:[ time_tool ]
        ~hooks:Oas.Hooks.empty
        ~raw_trace
        ~heartbeat_callbacks:[]
        ()
    with
    | Ok agent ->
        Fun.protect
          ~finally:(fun () -> Oas.Agent.close agent)
          (fun () ->
            match Oas.Agent.run ~sw agent "what time is it?" with
            | Ok _ -> Alcotest.fail "expected retry exhaustion error"
            | Error
                (Oas.Error.Agent
                  (Oas.Error.ToolRetryExhausted { attempts; limit; detail })) ->
                Alcotest.(check int) "default_internal attempts" 2 attempts;
                Alcotest.(check int) "default_internal limit" 2 limit;
                Alcotest.(check bool) "detail mentions tool" true
                  (contains_substring ~needle:"get_time" detail);
                Eio.Switch.fail sw Exit
            | Error err -> Alcotest.fail (Oas.Error.to_string err))
    | Error err -> Alcotest.fail err
  with Exit -> ()

let test_oas_worker_exec_run_exit_condition_result_returns_partial_success () =
  try
    Eio.Switch.run @@ fun sw ->
    let responses =
      [
        openai_tool_use_response "noop" {|{}|};
        openai_text_response ~id:"chatcmpl-should-not-run" "should not happen";
      ]
    in
    let port =
      match find_free_port () with Some port -> port | None -> Alcotest.skip ()
    in
    let url =
      try start_multi_mock ~sw ~net:(require_test_net ()) ~port responses
      with
      | Unix.Unix_error (Unix.EPERM, "bind", _)
      | Unix.Unix_error (Unix.EACCES, "bind", _) ->
          Alcotest.skip ()
    in
    let provider : Oas.Provider.config =
      {
        provider = Oas.Provider.Local { base_url = url };
        model_id = "mock-model";
        api_key_env = "";
      }
    in
    let noop_tool = make_noop_tool () in
    let base_config =
      Oas_worker_exec.default_config
        ~name:"oas-worker-exit-condition"
        ~provider
        ~model_id:"mock-model"
        ~system_prompt:"system"
        ~tools:[ noop_tool ]
    in
    let config =
      {
        base_config with
        exit_condition = Some (fun turn -> turn >= 1);
        exit_condition_result =
          Some
            (fun turn ->
              ( Oas_worker_exec.MutationBoundaryReached
                  { turns_used = turn; tool_name = Some "keeper_shell" },
                Some
                  "[mutation boundary reached after committed tool: keeper_shell]" ));
      }
    in
    match
      Oas_worker_exec.run
        ~sw
        ~net:(require_test_net ())
        ~config
        "say hello"
    with
    | Ok result ->
        Alcotest.(check int) "turn count preserved" 1 result.turns;
        Alcotest.(check bool) "checkpoint present" true
          (Option.is_some result.checkpoint);
        (match result.stop_reason with
         | Oas_worker_exec.MutationBoundaryReached { turns_used; tool_name } ->
             Alcotest.(check int) "boundary turn count" 1 turns_used;
             Alcotest.(check (option string)) "boundary tool"
               (Some "keeper_shell") tool_name
         | _ ->
             Alcotest.fail "expected mutation boundary stop reason");
        Alcotest.(check bool) "partial response mentions mutation boundary" true
          (contains_substring
             ~needle:"mutation boundary reached after committed tool: keeper_shell"
             (response_text result.response));
        Eio.Switch.fail sw Exit
    | Error err -> Alcotest.fail (Oas.Error.to_string err)
  with Exit -> ()

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

let tool_result_msg ?(id = "tool-1") text : Agent_sdk.Types.message =
  {
    Agent_sdk.Types.role = Agent_sdk.Types.Tool;
    content =
      [
        Agent_sdk.Types.ToolResult
          { tool_use_id = id; content = text; is_error = false; json = None };
      ];
    name = None;
    tool_call_id = None;
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
      (match Keeper_checkpoint_store.save_oas ~session_dir checkpoint with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Printf.sprintf "save_oas failed: %s" e));
      match
        Keeper_checkpoint_store.load_oas ~session_dir ~session_id:"trace-store"
      with
      | Ok loaded ->
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
      | Error _ -> Alcotest.fail "expected OAS checkpoint roundtrip")

let test_keeper_checkpoint_store_oas_missing_returns_none () =
  let base_dir = temp_dir "keeper_oas_store_missing" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let session_dir = Filename.concat base_dir "missing-session" in
      (match Keeper_checkpoint_store.load_oas ~session_dir
               ~session_id:"missing-session" with
       | Error Not_found -> ()
       | Ok _ -> Alcotest.fail "expected Not_found for missing checkpoint"
       | Error e ->
           Alcotest.fail (Printf.sprintf "expected Not_found, got other error: %s"
             (match e with
              | Parse_error d -> "parse:" ^ d
              | Store_error d -> "store:" ^ d
              | Io_error d -> "io:" ^ d
              | Not_found -> "not_found"))))

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
      (match Keeper_exec_context.save_oas_checkpoint
           ~max_checkpoint_messages:120
           ~session
           ~agent_name:meta.agent_name
           ~model:(Keeper_exec_context.checkpoint_model_of_meta meta)
           ~ctx:oas_ctx ~generation:7
       with Ok _ -> () | Error e -> Alcotest.fail e);
      let (_session, loaded_opt) =
        Keeper_exec_context.load_context_from_checkpoint
          ~max_checkpoint_messages:120
          ~trace_id
          ~primary_model_max_tokens:1024 ~base_dir
      in
      match loaded_opt with
      | Some loaded ->
          Alcotest.(check string) "system prompt from OAS checkpoint"
            "oas system" loaded.system_prompt;
          Alcotest.(check int) "max_tokens from live primary context" 1024
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
        Keeper_exec_context.load_context_from_checkpoint
          ~max_checkpoint_messages:120
          ~trace_id
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
      (match Keeper_checkpoint_store.save_oas ~session_dir:session.session_dir old_oas with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Printf.sprintf "save_oas failed: %s" e));
      let legacy_ctx =
        Keeper_exec_context.create ~system_prompt:"new legacy" ~max_tokens:2048
        |> fun ctx ->
        Keeper_exec_context.append ctx (Agent_sdk.Types.user_msg "new-legacy")
      in
      ignore (Keeper_exec_context.save_checkpoint session legacy_ctx ~generation:9);
      let (_session, loaded_opt) =
        Keeper_exec_context.load_context_from_checkpoint
          ~max_checkpoint_messages:120
          ~trace_id
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
        Keeper_exec_context.create_session ~session_id:meta.runtime.trace_id ~base_dir
      in
      let ctx =
        Keeper_exec_context.create ~system_prompt:"rollover" ~max_tokens:100
        |> fun ctx ->
        Keeper_exec_context.append ctx
          (Agent_sdk.Types.user_msg (String.make 800 'x'))
        |> Keeper_exec_context.sync_oas_context
      in
      let checkpoint =
        match Keeper_exec_context.save_oas_checkpoint
          ~max_checkpoint_messages:120
          ~session
          ~agent_name:meta.agent_name
          ~model:"llama:auto"
          ~ctx ~generation:meta.runtime.generation
        with Ok cp -> cp | Error e -> Alcotest.fail e
      in
      let rollover =
        Keeper_exec_context.maybe_rollover_oas_handoff ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:100
          ~checkpoint:(Some checkpoint)
      in
      Alcotest.(check int) "generation incremented" 1
        rollover.updated_meta.runtime.generation;
      Alcotest.(check bool) "trace rotated" true
        (rollover.updated_meta.runtime.trace_id <> meta.runtime.trace_id);
      Alcotest.(check bool) "trace history contains previous trace" true
        (List.mem meta.runtime.trace_id rollover.updated_meta.runtime.trace_history);
      Alcotest.(check bool) "handoff json present" true
        (Option.is_some rollover.handoff_json);
      let new_session =
        Keeper_exec_context.create_session
          ~session_id:rollover.updated_meta.runtime.trace_id
          ~base_dir
      in
      match
        Keeper_checkpoint_store.load_oas ~session_dir:new_session.session_dir
          ~session_id:rollover.updated_meta.runtime.trace_id
      with
      | Ok loaded ->
          let generation =
            Agent_sdk.Context.get_scoped loaded.context Agent_sdk.Context.Session
              "keeper_generation"
          in
          Alcotest.(check (option int)) "new checkpoint generation preserved"
            (Some 1)
            (Option.bind generation (function
              | `Int value -> Some value
              | `Intlit raw -> int_of_string_opt raw
              | _ -> None))
      | Error _ -> Alcotest.fail "expected rollover checkpoint")

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
        Keeper_exec_context.create_session ~session_id:meta.runtime.trace_id ~base_dir
      in
      let ctx =
        Keeper_exec_context.create ~system_prompt:"stable" ~max_tokens:100
        |> fun ctx ->
        Keeper_exec_context.append ctx
          (Agent_sdk.Types.user_msg "short")
        |> Keeper_exec_context.sync_oas_context
      in
      let checkpoint =
        match Keeper_exec_context.save_oas_checkpoint
          ~max_checkpoint_messages:120
          ~session
          ~agent_name:meta.agent_name
          ~model:"llama:auto"
          ~ctx ~generation:meta.runtime.generation
        with Ok cp -> cp | Error e -> Alcotest.fail e
      in
      let rollover =
        Keeper_exec_context.maybe_rollover_oas_handoff ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:100
          ~checkpoint:(Some checkpoint)
      in
      Alcotest.(check string) "trace unchanged" meta.runtime.trace_id
        rollover.updated_meta.runtime.trace_id;
      Alcotest.(check int) "generation unchanged" meta.runtime.generation
        rollover.updated_meta.runtime.generation;
      Alcotest.(check bool) "handoff json absent" false
        (Option.is_some rollover.handoff_json))

let test_overflow_retry_legacy_restore_failure_falls_back_to_oas () =
  let base_dir = temp_dir "keeper_overflow_retry_legacy_fallback" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let meta = make_keeper_meta ~trace_id:"trace-overflow-legacy-fail" () in
      let session =
        Keeper_exec_context.create_session ~session_id:meta.runtime.trace_id ~base_dir
      in
      let noisy_tool_output = String.make 4000 'x' in
      let ctx =
        Keeper_exec_context.create ~system_prompt:"legacy" ~max_tokens:4096
        |> fun ctx ->
        Keeper_exec_context.append ctx (Agent_sdk.Types.user_msg "legacy")
        |> fun ctx ->
        Keeper_exec_context.append ctx (tool_result_msg noisy_tool_output)
        |> Keeper_exec_context.sync_oas_context
      in
      (match Keeper_exec_context.save_oas_checkpoint ~max_checkpoint_messages:120 ~session
           ~agent_name:meta.agent_name
           ~model:"llama:auto" ~ctx
           ~generation:11
       with Ok _ -> () | Error e -> Alcotest.fail e);
      let bad_legacy =
        {
          (Keeper_exec_context.create_checkpoint ctx ~generation:19) with
          timestamp = Time_compat.now () +. 10.0;
          serialized = "\"broken-context\"";
        }
      in
      Keeper_exec_context.save_session_checkpoint session bad_legacy;
      match
        Keeper_exec_context.recover_latest_checkpoint_for_overflow_retry
          ~base_dir ~meta ~model:"llama:auto"
          ~primary_model_max_tokens:512
      with
      | None ->
          Alcotest.fail
            "expected overflow retry recovery to fall back to OAS checkpoint"
      | Some recovery ->
          let recovered_ctx =
            Keeper_exec_context.context_of_oas_checkpoint
              ~max_checkpoint_messages:120
              recovery.checkpoint
              ~primary_model_max_tokens:512
          in
          Alcotest.(check int) "fallback uses OAS generation" 11
            recovery.turn_generation;
          Alcotest.(check bool) "compacted from OAS fallback" true
            (Keeper_exec_context.token_count recovered_ctx
             < Keeper_exec_context.token_count ctx))

let test_overflow_retry_legacy_restore_failure_returns_none_without_oas () =
  let base_dir = temp_dir "keeper_overflow_retry_legacy_fail" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let meta = make_keeper_meta ~trace_id:"trace-overflow-legacy-only" () in
      let session =
        Keeper_exec_context.create_session ~session_id:meta.runtime.trace_id ~base_dir
      in
      let ctx =
        Keeper_exec_context.create ~system_prompt:"legacy" ~max_tokens:1024
        |> fun ctx ->
        Keeper_exec_context.append ctx (Agent_sdk.Types.user_msg "legacy")
      in
      let bad_checkpoint =
        {
          (Keeper_exec_context.create_checkpoint ctx ~generation:7) with
          serialized = "\"broken-context\"";
        }
      in
      Keeper_exec_context.save_session_checkpoint session bad_checkpoint;
      match
        Keeper_exec_context.recover_latest_checkpoint_for_overflow_retry
          ~base_dir ~meta ~model:"llama:auto"
          ~primary_model_max_tokens:512
      with
      | None -> ()
      | Some _ ->
          Alcotest.fail
            "expected overflow retry recovery to skip broken legacy checkpoint without OAS fallback")

let test_overflow_retry_requires_meaningful_reduction () =
  let base_dir = temp_dir "keeper_overflow_retry_noop" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let meta = make_keeper_meta ~trace_id:"trace-overflow-noop" () in
      let session =
        Keeper_exec_context.create_session ~session_id:meta.runtime.trace_id ~base_dir
      in
      let ctx =
        Keeper_exec_context.create ~system_prompt:"noop" ~max_tokens:4096
        |> fun ctx ->
        Keeper_exec_context.append ctx (Agent_sdk.Types.user_msg "short")
        |> Keeper_exec_context.sync_oas_context
      in
      (match Keeper_exec_context.save_oas_checkpoint ~max_checkpoint_messages:120 ~session
           ~agent_name:meta.agent_name
           ~model:"llama:auto" ~ctx
           ~generation:meta.runtime.generation
       with Ok _ -> () | Error e -> Alcotest.fail e);
      match
        Keeper_exec_context.recover_latest_checkpoint_for_overflow_retry
          ~base_dir ~meta ~model:"llama:auto"
          ~primary_model_max_tokens:1024
      with
      | None -> ()
      | Some _ ->
          Alcotest.fail
            "expected overflow retry recovery to skip no-op compaction")

let test_overflow_retry_saves_compacted_checkpoint () =
  let base_dir = temp_dir "keeper_overflow_retry_compacts" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let meta = make_keeper_meta ~trace_id:"trace-overflow-compacts" () in
      let session =
        Keeper_exec_context.create_session ~session_id:meta.runtime.trace_id ~base_dir
      in
      let noisy_tool_output = String.make 4000 'x' in
      let ctx =
        Keeper_exec_context.create ~system_prompt:"overflow" ~max_tokens:4096
        |> fun ctx ->
        Keeper_exec_context.append ctx (Agent_sdk.Types.user_msg "please summarize")
        |> fun ctx ->
        Keeper_exec_context.append ctx (tool_result_msg noisy_tool_output)
        |> Keeper_exec_context.sync_oas_context
      in
      let before_tokens = Keeper_exec_context.token_count ctx in
      (match Keeper_exec_context.save_oas_checkpoint ~max_checkpoint_messages:120 ~session
           ~agent_name:meta.agent_name
           ~model:"llama:auto" ~ctx
           ~generation:meta.runtime.generation
       with Ok _ -> () | Error e -> Alcotest.fail e);
      match
        Keeper_exec_context.recover_latest_checkpoint_for_overflow_retry
          ~base_dir ~meta ~model:"llama:auto"
          ~primary_model_max_tokens:512
      with
      | None -> Alcotest.fail "expected overflow retry recovery to compact"
      | Some recovery ->
          let recovered_ctx =
            Keeper_exec_context.context_of_oas_checkpoint
              ~max_checkpoint_messages:120
              recovery.checkpoint
              ~primary_model_max_tokens:512
          in
          Alcotest.(check bool) "token count reduced" true
            (Keeper_exec_context.token_count recovered_ctx < before_tokens);
          Alcotest.(check bool) "token count fits retry budget" true
            (Keeper_exec_context.token_count recovered_ctx <= 512);
          Alcotest.(check int) "max tokens clamped" 512 recovered_ctx.max_tokens)

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
      (match Keeper_exec_context.save_oas_checkpoint ~max_checkpoint_messages:120 ~session
           ~agent_name:meta.agent_name
           ~model:"llama:auto" ~ctx:ctx_turn1 ~generation:0
       with Ok _ -> () | Error e -> Alcotest.fail e);
      (* Turn 2: load checkpoint, verify messages, add more *)
      let (_session2, loaded_opt) =
        Keeper_exec_context.load_context_from_checkpoint ~max_checkpoint_messages:120 ~trace_id
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
      (match Keeper_exec_context.save_oas_checkpoint ~max_checkpoint_messages:120 ~session:session2
           ~agent_name:meta.agent_name
           ~model:"llama:auto" ~ctx:ctx_turn2 ~generation:1
       with Ok _ -> () | Error e -> Alcotest.fail e);
      (* Immediate verify: reload right after second save to isolate
         save correctness from load correctness (GLM-5 review finding) *)
      let (_session_imm, immediate_opt) =
        Keeper_exec_context.load_context_from_checkpoint ~max_checkpoint_messages:120 ~trace_id
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
        Keeper_exec_context.load_context_from_checkpoint ~max_checkpoint_messages:120 ~trace_id
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
      (match Keeper_exec_context.save_oas_checkpoint ~max_checkpoint_messages:120 ~session
           ~agent_name:meta.agent_name
           ~model:"llama:auto" ~ctx ~generation:5
       with Ok _ -> () | Error e -> Alcotest.fail e);
      (* Simulate restart: fresh load with no runtime state *)
      let (_fresh_session, loaded_opt) =
        Keeper_exec_context.load_context_from_checkpoint ~max_checkpoint_messages:120 ~trace_id
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
(* enrich_idle_detail — unit tests (OAS #5020 regression)          *)
(* ================================================================ *)

(** Build a minimal assistant message that contains a single ToolUse. *)
let make_assistant_tool_use_msg name : Agent_sdk.Types.message =
  {
    Agent_sdk.Types.role = Agent_sdk.Types.Assistant;
    content =
      [
        Agent_sdk.Types.ToolUse
          { id = "call-1"; name; input = `Assoc [] };
      ];
    name = None;
    tool_call_id = None;
  }

(** Idle error with a preceding tool-use: should append "(tool: <name>)". *)
let test_enrich_idle_detail_with_tool () =
  let detail = "Idle detected after 3 identical turns" in
  let messages = [ make_assistant_tool_use_msg "my_tool" ] in
  let result = Oas_worker_exec.enrich_idle_detail detail messages in
  Alcotest.(check bool) "contains original prefix" true
    (String.starts_with ~prefix:detail result);
  Alcotest.(check bool) "appends tool name" true
    (contains_substring ~needle:"(tool: my_tool)" result)

(** Idle error with no tool use in messages: detail should be unchanged. *)
let test_enrich_idle_detail_no_tool () =
  let detail = "Idle detected after 3 identical turns" in
  let messages =
    [ { Agent_sdk.Types.role = Agent_sdk.Types.User;
        content = [ Agent_sdk.Types.Text "hello" ];
        name = None; tool_call_id = None } ]
  in
  let result = Oas_worker_exec.enrich_idle_detail detail messages in
  Alcotest.(check string) "unchanged when no tool" detail result

(** Idle error with empty message list: detail should be unchanged. *)
let test_enrich_idle_detail_empty_messages () =
  let detail = "Idle detected: no progress" in
  let result = Oas_worker_exec.enrich_idle_detail detail [] in
  Alcotest.(check string) "unchanged with empty messages" detail result

(** Non-idle error: detail must not be modified at all. *)
let test_enrich_idle_detail_non_idle_error () =
  let detail = "Rate limit exceeded" in
  let messages = [ make_assistant_tool_use_msg "some_tool" ] in
  let result = Oas_worker_exec.enrich_idle_detail detail messages in
  Alcotest.(check string) "non-idle error unchanged" detail result

(** Last tool in message list wins when multiple assistant messages are present. *)
let test_enrich_idle_detail_picks_last_tool () =
  let detail = "Idle detected after 3 identical turns" in
  let messages =
    [ make_assistant_tool_use_msg "first_tool"
    ; make_assistant_tool_use_msg "last_tool" ]
  in
  let expected = detail ^ " (tool: last_tool)" in
  let result = Oas_worker_exec.enrich_idle_detail detail messages in
  Alcotest.(check string) "exact string with last tool" expected result

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Eio_main.run @@ fun env ->
  test_net := Some env#net;
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
      Alcotest.test_case "cascade observation json includes fallback fields" `Quick
        test_cascade_observation_json_includes_fallback_fields;
    ];
    "resume_config", [
      Alcotest.test_case "checkpoint model wins" `Quick
        test_resume_model_id_prefers_checkpoint_model;
      Alcotest.test_case "meta model fallback" `Quick
        test_resume_model_id_falls_back_to_meta_model;
      Alcotest.test_case "oas_worker default leaves retry disabled" `Quick
        test_oas_worker_exec_build_defaults_without_retry_policy;
      Alcotest.test_case "oas_worker opt-in applies retry policy" `Quick
        test_oas_worker_exec_build_applies_retry_policy;
      Alcotest.test_case "oas_worker default priority remains unset" `Quick
        test_oas_worker_exec_build_default_priority_unset;
      Alcotest.test_case "oas_worker applies explicit priority" `Quick
        test_oas_worker_exec_build_applies_priority;
      Alcotest.test_case "worker build_agent installs retry policy" `Quick
        test_worker_build_agent_uses_default_internal_retry_policy;
      Alcotest.test_case "resume config propagates retry policy" `Quick
        test_build_resume_config_propagates_retry_policy;
      Alcotest.test_case "worker build_agent retries validation errors" `Quick
        test_worker_build_agent_validation_retry_success;
      Alcotest.test_case "worker build_agent exhausts validation retries deterministically" `Quick
        test_worker_build_agent_validation_retry_exhausted;
      Alcotest.test_case "exit_condition_result returns partial success" `Quick
        test_oas_worker_exec_run_exit_condition_result_returns_partial_success;
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
      Alcotest.test_case "overflow retry falls back to OAS after broken legacy restore" `Quick
        test_overflow_retry_legacy_restore_failure_falls_back_to_oas;
      Alcotest.test_case "overflow retry skips broken legacy checkpoint without OAS" `Quick
        test_overflow_retry_legacy_restore_failure_returns_none_without_oas;
      Alcotest.test_case "overflow retry requires meaningful reduction" `Quick
        test_overflow_retry_requires_meaningful_reduction;
      Alcotest.test_case "overflow retry saves compacted checkpoint" `Quick
        test_overflow_retry_saves_compacted_checkpoint;
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
    "idle_detail_enrichment", [
      Alcotest.test_case "idle error with tool appends tool name" `Quick
        test_enrich_idle_detail_with_tool;
      Alcotest.test_case "idle error with no tool is unchanged" `Quick
        test_enrich_idle_detail_no_tool;
      Alcotest.test_case "idle error with empty messages is unchanged" `Quick
        test_enrich_idle_detail_empty_messages;
      Alcotest.test_case "non-idle error is never modified" `Quick
        test_enrich_idle_detail_non_idle_error;
      Alcotest.test_case "last tool name wins over earlier ones" `Quick
        test_enrich_idle_detail_picks_last_tool;
    ];
  ]
