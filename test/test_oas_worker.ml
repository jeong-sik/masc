(** Test_oas_worker — Unit tests for OAS worker streaming bridge,
    cascade config, and governance integration.

    LLM 0 — no real MODEL calls. Tests use mock net / temp directories.

    @since Phase 1 — MASC->OAS migration
    @since Phase A — OAS #215 streaming verification *)

open Masc_mcp

module Oas = Agent_sdk

let internal_cascade_name = Oas_worker_named.cascade_name_of_string
let internal_cascade_name_to_string = Oas_worker_named.cascade_name_to_string

let ctx_messages = Keeper_exec_context.messages_of_context
let ctx_system_prompt = Keeper_exec_context.system_prompt_of_context

(* ================================================================ *)
(* Shared test infrastructure                                       *)
(* ================================================================ *)

let test_counter = ref 0
let test_net : ([ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ref) =
  ref None
let test_proc_mgr = ref None

let require_test_net () =
  match !test_net with
  | Some net -> net
  | None -> failwith "test net not initialized"

let require_test_proc_mgr () =
  match !test_proc_mgr with
  | Some mgr -> mgr
  | None -> failwith "test process manager not initialized"

let temp_dir prefix =
  incr test_counter;
  let dir = Filename.temp_file (Printf.sprintf "%s_%d_" prefix !test_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then
    ()
  else if Sys.file_exists dir then
    ()
  else begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end

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

let make_local_provider ?(model_id = "mock-model") () : Agent_sdk.Provider.config =
  {
    Agent_sdk.Provider.provider = Agent_sdk.Provider.Local { base_url = "http://127.0.0.1:1" };
    model_id;
    api_key_env = "";
  }

let make_local_provider_cfg ?(model_id = "mock-model") () :
    Llm_provider.Provider_config.t =
  match Agent_sdk.Provider_bridge.to_provider_config (make_local_provider ~model_id ()) with
  | Ok cfg -> cfg
  | Error err -> failwith (Agent_sdk.Error.to_string err)

let make_noop_tool () =
  Agent_sdk.Tool.create
    ~name:"noop"
    ~description:"No-op test tool"
    ~parameters:[]
    (fun _ -> Ok Agent_sdk.Types.{ content = "ok" })

let make_named_noop_tool name =
  Agent_sdk.Tool.create
    ~name
    ~description:"No-op test tool"
    ~parameters:[]
    (fun _ -> Ok Agent_sdk.Types.{ content = "ok" })

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let with_temp_masc_base_path prefix f =
  let base = temp_dir prefix in
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  let previous_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  Unix.putenv "MASC_BASE_PATH" base;
  Unix.putenv "MASC_BASE_PATH_INPUT" base;
  Fun.protect
    ~finally:(fun () ->
      (match previous with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> Unix.putenv "MASC_BASE_PATH" "");
      (match previous_input with
       | Some value -> Unix.putenv "MASC_BASE_PATH_INPUT" value
       | None -> Unix.putenv "MASC_BASE_PATH_INPUT" "");
      cleanup_dir base)
    f

let seed_raw_token base_path agent_name raw =
  let auth_dir = Auth.auth_dir base_path in
  mkdir_p auth_dir;
  Auth.save_private_text_file (Filename.concat auth_dir (agent_name ^ ".token")) raw

let with_temp_masc_config cascade_json f =
  let base = temp_dir "test_masc_config" in
  let config_dir = Filename.concat base ".masc/config" in
  let cascade_path = Filename.concat config_dir "cascade.json" in
  mkdir_p config_dir;
  let oc = open_out cascade_path in
  output_string oc cascade_json;
  close_out oc;
  let prev_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  let prev_base_path_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  let prev_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Config_dir_resolver.reset ();
  Cascade_catalog_runtime.reset_cache_for_tests ();
  Unix.putenv "MASC_BASE_PATH" base;
  Unix.putenv "MASC_BASE_PATH_INPUT" base;
  Unix.putenv "MASC_CONFIG_DIR" config_dir;
  Fun.protect
    ~finally:(fun () ->
      (match prev_base_path with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> Unix.putenv "MASC_BASE_PATH" "");
      (match prev_base_path_input with
       | Some value -> Unix.putenv "MASC_BASE_PATH_INPUT" value
       | None -> Unix.putenv "MASC_BASE_PATH_INPUT" "");
      (match prev_config_dir with
       | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Config_dir_resolver.reset ();
      Cascade_catalog_runtime.reset_cache_for_tests ();
      cleanup_dir base)
    f

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

let response_text (resp : Agent_sdk.Types.api_response) =
  resp.Agent_sdk.Types.content
  |> List.filter_map (function Agent_sdk.Types.Text s -> Some s | _ -> None)
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

let start_counting_mock ~sw ~net ~port response =
  let calls = Atomic.make 0 in
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    ignore (Atomic.fetch_and_add calls 1);
    Cohttp_eio.Server.respond_string ~status:`OK ~body:response ()
  in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  ( Printf.sprintf "http://127.0.0.1:%d" port,
    (fun () -> Atomic.get calls),
    (fun () -> Atomic.set calls 0) )

let start_delayed_mock ~sw ~net ~clock ~port ~delay_s response =
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    if delay_s > 0.0 then Eio.Time.sleep clock delay_s;
    Cohttp_eio.Server.respond_string ~status:`OK ~body:response ()
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
      match Agent_sdk.Raw_trace.create ~path () with
      | Ok raw_trace -> f raw_trace
      | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err))

let check_policy_matches_default_internal label
    (policy : Agent_sdk.Tool_retry_policy.t option) =
  let expected = Agent_sdk.Tool_retry_policy.default_internal in
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
     | Agent_sdk.Tool_retry_policy.Structured_tool_result -> true
     | Agent_sdk.Tool_retry_policy.Plain_error_text -> false)

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

let test_default_model_strings_local_only () =
  let models = Oas_worker.default_model_strings ~cascade_name:"local_only" in
  let is_local label =
    match Oas_model_resolve.provider_name_of_label label with
    | Some pname -> Provider_adapter.is_local_provider pname
    | None -> false
  in
  Alcotest.(check bool) "local_only has models" true (models <> []);
  Alcotest.(check bool) "local_only stays local" true
    (List.for_all is_local models)

(** Test default_config_path with a controlled fixture so the result
    is deterministic regardless of CWD or inherited env.
    Creates a temp config root, points MASC_CONFIG_DIR at it, and verifies
    the function finds the file. Test executables intentionally sanitize
    inherited MASC_BASE_PATH overrides, so config-path fixtures must use the
    explicit config-dir env. *)
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
  (* Save and override MASC_CONFIG_DIR explicitly. *)
  let old_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  let old_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Config_dir_resolver.reset ();
  Cascade_catalog_runtime.reset_cache_for_tests ();
  Unix.putenv "MASC_CONFIG_DIR" masc_config_dir;
  Unix.putenv "MASC_BASE_PATH" "";
  Fun.protect
    ~finally:(fun () ->
      (match old_config_dir with
       | Some v -> Unix.putenv "MASC_CONFIG_DIR" v
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      (match old_base_path with
       | Some v -> Unix.putenv "MASC_BASE_PATH" v
       | None ->
           (* OCaml stdlib has no unsetenv; set to empty string
              which env_opt treats as absent. *)
           Unix.putenv "MASC_BASE_PATH" "");
      Config_dir_resolver.reset ();
      Cascade_catalog_runtime.reset_cache_for_tests ();
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
          "default_config_path returned None despite explicit MASC_CONFIG_DIR fixture")

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

let test_cascade_inference_normalizes_keeper_aliases () =
  let json =
    `Assoc
      [
        ("keeper_unified_temperature", `Float 0.2);
        ("keeper_unified_max_tokens", `Int 16384);
      ]
  in
  let canonical = Cascade_inference.for_json ~name:Masc_mcp.Keeper_config.default_cascade_name json in
  let legacy_oas = Cascade_inference.for_json ~name:"oas-keeper_unified" json in
  let legacy_removed = Cascade_inference.for_json ~name:"oas-coding_first" json in
  Alcotest.(check (option (float 0.0001))) "canonical temp"
    canonical.temperature legacy_oas.temperature;
  Alcotest.(check (option int)) "canonical max_tokens"
    canonical.max_tokens legacy_oas.max_tokens;
  Alcotest.(check (option (float 0.0001))) "removed alias temp"
    canonical.temperature legacy_removed.temperature;
  Alcotest.(check (option int)) "removed alias max_tokens"
    canonical.max_tokens legacy_removed.max_tokens

let test_cascade_observation_json_includes_fallback_fields () =
  let observation : Oas_worker.cascade_observation =
    {
      cascade_name =
        Masc_mcp.Keeper_cascade_profile.Runtime_name
          Masc_mcp.Keeper_config.default_cascade_name;
      strategy = Some "round_robin";
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
  Alcotest.(check string) "cascade name preserved" Masc_mcp.Keeper_config.default_cascade_name
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

let find_cascade_metric_entry name (json : Yojson.Safe.t) =
  Yojson.Safe.Util.(json |> to_list)
  |> List.find_opt (fun entry ->
         String.equal
           Yojson.Safe.Util.(entry |> member "cascade_name" |> to_string)
           name)

let test_cascade_metrics_concurrent_recording () =
  with_temp_masc_base_path "test_cascade_metrics_concurrent" @@ fun () ->
  Masc_mcp.Oas_worker_cascade.reset_cascade_counters_for_test ();
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Oas_worker_cascade.reset_cascade_counters_for_test ())
    (fun () ->
      Eio.Fiber.all
        (List.init 8 (fun _ ->
             fun () ->
               for _ = 1 to 25 do
                 Masc_mcp.Oas_worker_cascade.record_cascade
                   ~cascade_name:(internal_cascade_name "concurrent-cascade")
                   ~observation:None
                   ~outcome:`Success
                   ()
               done));
      match
        find_cascade_metric_entry "concurrent-cascade"
          (Oas_worker.cascade_metrics_json ())
      with
      | None -> Alcotest.fail "expected concurrent-cascade metrics"
      | Some entry ->
          Alcotest.(check int) "calls aggregated" 200
            Yojson.Safe.Util.(entry |> member "calls" |> to_int);
          Alcotest.(check int) "successes aggregated" 200
            Yojson.Safe.Util.(entry |> member "successes" |> to_int);
          Alcotest.(check int) "failures stay zero" 0
            Yojson.Safe.Util.(entry |> member "failures" |> to_int))

let test_cascade_metrics_evicts_lowest_call_key () =
  with_temp_masc_base_path "test_cascade_metrics_evicts" @@ fun () ->
  Masc_mcp.Oas_worker_cascade.reset_cascade_counters_for_test ();
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Oas_worker_cascade.reset_cascade_counters_for_test ())
    (fun () ->
      Masc_mcp.Oas_worker_cascade.record_cascade
        ~cascade_name:(internal_cascade_name "victim-key")
        ~observation:None
        ~outcome:`Success
        ();
      for i = 1 to 254 do
        let name = Printf.sprintf "stable-%03d" i in
        Masc_mcp.Oas_worker_cascade.record_cascade
          ~cascade_name:(internal_cascade_name name)
          ~observation:None
          ~outcome:`Success
          ();
        Masc_mcp.Oas_worker_cascade.record_cascade
          ~cascade_name:(internal_cascade_name name)
          ~observation:None
          ~outcome:`Success
          ()
      done;
      for _ = 1 to 3 do
        Masc_mcp.Oas_worker_cascade.record_cascade
          ~cascade_name:(internal_cascade_name "hot-key")
          ~observation:None
          ~outcome:`Success
          ()
      done;
      let before = Yojson.Safe.Util.to_list (Oas_worker.cascade_metrics_json ()) in
      Alcotest.(check int) "table capped before admit" 256 (List.length before);
      Masc_mcp.Oas_worker_cascade.record_cascade
        ~cascade_name:(internal_cascade_name "new-key")
        ~observation:None
        ~outcome:`Success
        ();
      let after_json = Oas_worker.cascade_metrics_json () in
      let after = Yojson.Safe.Util.to_list after_json in
      Alcotest.(check int) "table stays capped" 256 (List.length after);
      Alcotest.(check bool) "victim evicted" true
        (Option.is_none
           (find_cascade_metric_entry "victim-key" after_json));
      Alcotest.(check bool) "new key admitted" true
        (Option.is_some
           (find_cascade_metric_entry "new-key" after_json));
      Alcotest.(check bool) "hot key retained" true
        (Option.is_some
           (find_cascade_metric_entry "hot-key" after_json)))

let test_cascade_audit_persists_observation () =
  let base = temp_dir "test_cascade_audit" in
  let old_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Masc_mcp.Oas_worker_cascade.reset_cascade_counters_for_test ();
  Fun.protect
    ~finally:(fun () ->
      (match old_base_path with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> Unix.putenv "MASC_BASE_PATH" "");
      Masc_mcp.Oas_worker_cascade.reset_cascade_counters_for_test ();
      cleanup_dir base)
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" base;
      let observation : Masc_mcp.Oas_worker_cascade.cascade_observation =
        {
          cascade_name =
            Masc_mcp.Keeper_cascade_profile.Runtime_name "audit-cascade";
          strategy = Some "round_robin";
          configured_labels = [ "glm:auto"; "openai:auto" ];
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
                latency_ms = Some 120;
                error = Some "HTTP 503";
              };
              {
                attempt_index = 1;
                model_id = "qwen3.5-35b";
                model_label = Some "openai:qwen3.5-35b";
                latency_ms = Some 90;
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
      Masc_mcp.Oas_worker_cascade.record_cascade
        ~keeper_name:"keeper-glm-agent-test"
        ~cascade_name:(internal_cascade_name "audit-cascade")
        ~observation:(Some observation)
        ~outcome:`Failure
        ();
      ignore (Oas_worker.cascade_metrics_json ());
      let store =
        Dated_jsonl.create
          ~base_dir:(Filename.concat base ".masc/cascade_audit")
          ()
      in
      match Dated_jsonl.read_recent store 1 with
      | [ json ] ->
          Alcotest.(check string) "cascade name persisted" "audit-cascade"
            Yojson.Safe.Util.(json |> member "cascade_name" |> to_string);
          Alcotest.(check string) "keeper_name persisted (#11081)"
            "keeper-glm-agent-test"
            Yojson.Safe.Util.(json |> member "keeper_name" |> to_string);
          Alcotest.(check string) "top_level_reason promoted (#11081)"
            "HTTP 503"
            Yojson.Safe.Util.(json |> member "top_level_reason" |> to_string);
          Alcotest.(check string) "outcome persisted" "failure"
            Yojson.Safe.Util.(json |> member "outcome" |> to_string);
          Alcotest.(check string) "selected model persisted"
            "openai:qwen3.5-35b"
            Yojson.Safe.Util.(
              json |> member "observation" |> member "selected_model" |> to_string);
          Alcotest.(check bool) "fallback flag persisted" true
            Yojson.Safe.Util.(
              json |> member "observation" |> member "fallback_applied" |> to_bool)
      | _ ->
          Alcotest.fail "expected one cascade audit record")

let test_sdk_error_is_hard_quota_detects_gemini_cli_network_wrapper () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         {
           message =
             "gemini exited with code 1: TerminalQuotaError: You have exhausted \
              your capacity on this model. Your quota will reset after 4h41m7s. \
              reason=QUOTA_EXHAUSTED";
           kind = Llm_provider.Http_client.Unknown;
         })
  in
  Alcotest.(check bool) "Gemini CLI quota wrapper counts as hard quota" true
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_hard_quota_detects_claude_cli_limit_wrapper () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         {
           message =
             "claude exited with code 1: {\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":429,\"result\":\"You've hit your limit · resets Apr 24 at 4am (Asia/Seoul)\"}";
           kind = Llm_provider.Http_client.Unknown;
         })
  in
  Alcotest.(check bool) "Claude CLI limit wrapper counts as hard quota" true
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_hard_quota_detects_claude_org_monthly_limit_wrapper () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         {
           message =
             "claude exited with code 1: {\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":429,\"result\":\"You've hit your org's monthly usage limit\"}";
           kind = Llm_provider.Http_client.Unknown;
         })
  in
  Alcotest.(check bool) "Claude org monthly usage limit counts as hard quota" true
    (Oas_worker_named.sdk_error_is_hard_quota err)

(* 2026-04-29: Anthropic console started returning the user-set monthly cap
   as HTTP 400 [invalid_request_error] instead of a 429.  The CLI wrapper
   message and the direct API path both surface the new phrasing
   ("reached your specified API usage limits ... regain access on ...").
   Without these tests the [cli_wrapped_hard_quota_indicators] list and
   the [InvalidRequest] branch silently drift back to false-negative,
   re-burning the full OAS turn budget the next time the cap fires. *)
let test_sdk_error_is_hard_quota_detects_claude_specified_limit_cli_wrapper () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         {
           message =
             "claude exited with code 1: API Error: 400 \
              {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"You have reached your specified API usage limits. You will regain access on 2026-05-01 at 00:00 UTC.\"}}";
           kind = Llm_provider.Http_client.Unknown;
         })
  in
  Alcotest.(check bool)
    "Claude CLI 400-wrapped specified-limit counts as hard quota" true
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_hard_quota_detects_anthropic_invalid_request_specified_limit () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest
         {
           message =
             "You have reached your specified API usage limits. You will \
              regain access on 2026-05-01 at 00:00 UTC.";
         })
  in
  Alcotest.(check bool)
    "Direct Anthropic InvalidRequest specified-limit counts as hard quota" true
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_max_turns_detects_claude_cli_wrapper () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         {
           message =
             "claude exited with code 1: {\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"terminal_reason\":\"max_turns\",\"errors\":[\"Reached maximum number of turns (10)\"]}";
           kind = Llm_provider.Http_client.Unknown;
         })
  in
  Alcotest.(check bool) "Claude CLI max turns counts as max-turns" true
    (Oas_worker_named.sdk_error_is_max_turns_exceeded err);
  Alcotest.(check bool) "Claude CLI max turns is not hard quota" false
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_hard_quota_keeps_transient_network_errors_false () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         {
           message = "gemini exited with code 1: connection reset by peer";
           kind = Llm_provider.Http_client.Connection_refused;
         })
  in
  Alcotest.(check bool) "transient network error stays transient" false
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_hard_quota_preserves_rate_limited_detection () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.RateLimited
         { retry_after = None; message = "resource exhausted" })
  in
  Alcotest.(check bool) "existing RateLimited hard quota still works" true
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_hard_quota_keeps_not_found_false () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message = {|{"detail":"Not Found"}|} })
  in
  Alcotest.(check bool) "404-like InvalidRequest stays non-hard-quota" false
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_to_cascade_outcome_maps_not_found_to_404 () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message = {|{"detail":"Not Found"}|} })
  in
  match Oas_worker_named.sdk_error_to_cascade_outcome err with
  | Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.HttpError
            { code = 404; body = {|{"detail":"Not Found"}|} })) -> ()
  | outcome ->
      Alcotest.failf
        "expected Some (Call_err (HttpError 404)) for 404-like InvalidRequest, got %s"
        (Cascade_fsm.provider_outcome_option_to_string outcome)

let test_sdk_error_to_cascade_outcome_keeps_invalid_request_as_400 () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message = {|{"detail":"Bad Request"}|} })
  in
  match Oas_worker_named.sdk_error_to_cascade_outcome err with
  | Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.HttpError
            { code = 400; body = {|{"detail":"Bad Request"}|} })) -> ()
  | outcome ->
      Alcotest.failf
        "expected Some (Call_err (HttpError 400)) for ordinary InvalidRequest, got %s"
        (Cascade_fsm.provider_outcome_option_to_string outcome)

let test_sdk_error_to_cascade_outcome_cascades_model_access_denied () =
  let message = "Invalid request: You do not have permission to access glm-5-code" in
  let err =
    Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest { message })
  in
  match Oas_worker_named.sdk_error_to_cascade_outcome err with
  | Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.ProviderFailure
            {
              kind =
                Llm_provider.Http_client.Capability_mismatch
                  { capability = Some "model_access" };
              message = actual_message;
            } as http_err)) ->
      Alcotest.(check string) "message preserved" message actual_message;
      Alcotest.(check bool) "failed model name visible" true
        (contains_substring ~needle:"glm-5-code" actual_message);
      Alcotest.(check bool) "model access denial cascades" true
        (Oas_compat.Http_client.should_cascade http_err)
  | outcome ->
      Alcotest.failf
        "expected model access InvalidRequest to cascade as ProviderFailure Capability_mismatch, got %s"
        (Cascade_fsm.provider_outcome_option_to_string outcome)

let test_sdk_error_to_cascade_outcome_cascades_runtime_mcp_auth_config () =
  let detail = "codex_cli runtime MCP cannot carry keeper-bound auth headers" in
  let err =
    Agent_sdk.Error.Config
      (Agent_sdk.Error.InvalidConfig { field = "runtime_mcp_auth"; detail })
  in
  match Oas_worker_named.sdk_error_to_cascade_outcome err with
  | Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.AcceptRejected { reason })) ->
      Alcotest.(check string) "reason preserved" detail reason
  | outcome ->
      Alcotest.failf
        "expected runtime_mcp_auth InvalidConfig to cascade as AcceptRejected, got %s"
        (Cascade_fsm.provider_outcome_option_to_string outcome)

let test_sdk_error_to_cascade_outcome_cascades_resumable_cli_session () =
  let raw_message =
    "kimi exited with code 1: \nTo resume this session: kimi -r 5de0f199-6bd7-4509-bfa6-3308e0ebd97f"
  in
  let detail =
    Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail_of_text
      raw_message
  in
  let sdk_error =
    Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest { message = detail })
  in
  let structured =
    match
      Oas_worker_named.sdk_error_to_resumable_cli_session
        ~cascade_name:(internal_cascade_name "tool_use_strict") sdk_error
    with
    | Some structured -> structured
    | None -> Alcotest.fail "expected structured resumable CLI session"
  in
  match Oas_worker_named.sdk_error_to_cascade_outcome structured with
  | Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.NetworkError { message; kind })) ->
      Alcotest.(check bool) "detail remains resumable marker" true
        (Oas_worker_named.message_looks_like_resumable_cli_session message);
      Alcotest.(check bool) "unknown network kind" true
        (kind = Llm_provider.Http_client.Unknown)
  | outcome ->
      Alcotest.failf
        "expected resumable CLI session to cascade as NetworkError, got %s"
        (Cascade_fsm.provider_outcome_option_to_string outcome)

let test_sdk_error_is_resumable_cli_session_detects_structured_error () =
  let err =
    Oas_worker_named.sdk_error_of_masc_internal_error
      (Oas_worker_named.Resumable_cli_session
         {
           cascade_name = internal_cascade_name "governance_judge";
           detail =
             "kimi_cli reported a resumable CLI session (exit 1). \
              Resumable session available via -r.";
           exit_code = Some 1;
         })
  in
  Alcotest.(check bool) "structured resumable CLI session detected" true
    (Oas_worker_named.sdk_error_is_resumable_cli_session err);
  Alcotest.(check bool) "resumable CLI session is not hard quota" false
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_resumable_cli_session_detects_raw_kimi_hint () =
  let raw_message =
    "kimi exited with code 1: \nTo resume this session: kimi -r 5de0f199-6bd7-4509-bfa6-3308e0ebd97f"
  in
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         { message = raw_message; kind = Llm_provider.Http_client.Unknown })
  in
  Alcotest.(check bool) "raw Kimi resume hint detected" true
    (Oas_worker_named.sdk_error_is_resumable_cli_session err)

let make_openai_compat_provider_cfg ?(model_id = "mock-model")
    ?(base_url = "http://127.0.0.1:18080/v1")
    ?(request_path = "/chat/completions") ?(api_key = "") () =
  Llm_provider.Provider_config.make
    ~kind:OpenAI_compat
    ~model_id
    ~base_url
    ~api_key
    ~headers:[]
    ~request_path
    ~temperature:0.2
    ~max_tokens:1024
    ()

let test_enrich_sdk_error_for_moonshot_auth_includes_env_hint () =
  with_temp_masc_config
    {|{
  "default_api_key_env": {
    "kimi": "KIMI_API_KEY"
  }
}|}
  @@ fun () ->
  let provider_cfg =
    make_openai_compat_provider_cfg
      ~model_id:"kimi-k2.5"
      ~base_url:"https://api.moonshot.ai/v1"
      ~api_key:"sk-test"
      ()
  in
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.AuthError
         { message = "Invalid Authentication" })
  in
  let rendered =
    Oas_worker_named.enrich_sdk_error
      ~cascade_name:(internal_cascade_name "keeper_unified")
      ~provider_cfg
      err
    |> Agent_sdk.Error.to_string
  in
  Alcotest.(check bool) "env hint included" true
    (contains_substring ~needle:"KIMI_API_KEY" rendered);
  Alcotest.(check bool) "key presence hint included" true
    (contains_substring ~needle:"auth header was populated" rendered)

let test_enrich_sdk_error_for_openai_not_found_includes_endpoint_hint () =
  let provider_cfg =
    make_openai_compat_provider_cfg
      ~base_url:"http://127.0.0.1:18080/v1"
      ~request_path:"/chat/completions"
      ()
  in
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message = {|{"detail":"Not Found"}|} })
  in
  let rendered =
    Oas_worker_named.enrich_sdk_error
      ~cascade_name:(internal_cascade_name "keeper_unified")
      ~provider_cfg
      err
    |> Agent_sdk.Error.to_string
  in
  Alcotest.(check bool) "base_url hint included" true
    (contains_substring ~needle:"base_url=http://127.0.0.1:18080/v1" rendered);
  Alcotest.(check bool) "endpoint hint included" true
    (contains_substring
       ~needle:"endpoint=http://127.0.0.1:18080/v1/chat/completions"
       rendered)

let test_default_config_preserves_custom_local_request_path () =
  let provider_cfg =
    make_openai_compat_provider_cfg
      ~base_url:"http://127.0.0.1:18080/v1"
      ~request_path:"/chat/completions"
      ()
  in
  let config =
    Oas_worker_exec.default_config
      ~name:"custom-local-path"
      ~provider_cfg
      ~system_prompt:"system"
      ~tools:[]
  in
  match config.provider.provider with
  | Agent_sdk.Provider.OpenAICompat { base_url; path; _ } ->
    Alcotest.(check string) "base_url preserved"
      "http://127.0.0.1:18080/v1" base_url;
    Alcotest.(check string) "request_path preserved"
      "/chat/completions" path
  | Agent_sdk.Provider.Local _ ->
    Alcotest.fail "custom local OpenAI-compatible provider regressed to Local"
  | _ ->
    Alcotest.fail
      "custom local OpenAI-compatible provider should stay OpenAICompat"

let test_run_named_per_provider_timeout_uses_clock_fallback_and_exempts_last_provider () =
  Alcotest.(check bool) "test requires no global Masc_eio_env"
    true
    (Option.is_none (Masc_eio_env.get_opt ()));
  try
    Eio.Switch.run @@ fun sw ->
    let clock =
      match Process_eio.get_clock () with
      | Ok clock -> clock
      | Error err -> Alcotest.fail err
    in
    Eio_context.set_clock clock;
    let first_port =
      match find_free_port () with Some port -> port | None -> Alcotest.skip ()
    in
    let second_port =
      match find_free_port () with Some port -> port | None -> Alcotest.skip ()
    in
    let first_url =
      try
        start_delayed_mock
          ~sw
          ~net:(require_test_net ())
          ~clock
          ~port:first_port
          ~delay_s:0.2
          (openai_text_response "first provider should timeout")
      with
      | Unix.Unix_error (Unix.EPERM, "bind", _)
      | Unix.Unix_error (Unix.EACCES, "bind", _) ->
          Alcotest.skip ()
    in
    let second_url =
      try
        start_delayed_mock
          ~sw
          ~net:(require_test_net ())
          ~clock
          ~port:second_port
          ~delay_s:0.2
          (openai_text_response "last provider survived timeout")
      with
      | Unix.Unix_error (Unix.EPERM, "bind", _)
      | Unix.Unix_error (Unix.EACCES, "bind", _) ->
          Alcotest.skip ()
    in
    with_temp_masc_config
      (Printf.sprintf
         {|{
  "big_three_models": ["ollama:auto"],
  "timeout_probe_models": [
    "custom:slow@%s",
    "custom:last@%s"
  ]
}|}
         first_url
         second_url)
    @@ fun () ->
    match
      Oas_worker_named.run_named
        ~cascade_name:"timeout_probe"
        ~goal:"say hello"
        ~system_prompt:"system"
        ~sw
        ~net:(require_test_net ())
        ~per_provider_timeout_s:0.05
        ()
    with
    | Ok result ->
        Alcotest.(check string) "last provider succeeds without timeout"
          "last provider survived timeout"
          (response_text result.response);
        Eio.Switch.fail sw Exit
    | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)
  with Exit -> ()

let test_run_named_skips_cooldown_primary_and_falls_back () =
  try
    Eio.Switch.run @@ fun sw ->
    let primary_port =
      match find_free_port () with Some port -> port | None -> Alcotest.skip ()
    in
    let primary_url, primary_calls, reset_primary_calls =
      try
        start_counting_mock
          ~sw
          ~net:(require_test_net ())
          ~port:primary_port
          (openai_text_response "primary should be skipped")
      with
      | Unix.Unix_error (Unix.EPERM, "bind", _)
      | Unix.Unix_error (Unix.EACCES, "bind", _) ->
          Alcotest.skip ()
    in
    let fallback_port =
      match find_free_port () with Some port -> port | None -> Alcotest.skip ()
    in
    let fallback_url, fallback_calls, reset_fallback_calls =
      try
        start_counting_mock
          ~sw
          ~net:(require_test_net ())
          ~port:fallback_port
          (openai_text_response "fallback survived open circuit")
      with
      | Unix.Unix_error (Unix.EPERM, "bind", _)
      | Unix.Unix_error (Unix.EACCES, "bind", _) ->
          Alcotest.skip ()
    in
    let primary_key = "anthropic_open_13318" in
    let fallback_key = "moonshot_fallback_13318" in
    with_temp_masc_config
      (Printf.sprintf
         {|{
  "breaker_probe_13318_models": [
    "custom:%s@%s",
    "custom:%s@%s"
  ]
}|}
         primary_key
         primary_url
         fallback_key
         fallback_url)
    @@ fun () ->
    let resolved =
      match
        Masc_mcp.Cascade_catalog_runtime.resolve_named_providers_strict
          ~sw
          ~net:(require_test_net ())
          ~cascade_name:"breaker_probe_13318"
          ()
      with
      | Ok providers -> providers
      | Error err -> Alcotest.fail err
    in
    (match resolved with
     | [ primary; fallback ] ->
         Alcotest.(check string) "primary model id"
           primary_key primary.Llm_provider.Provider_config.model_id;
         Alcotest.(check string) "fallback model id"
           fallback_key fallback.model_id;
         Alcotest.(check string) "primary base url" primary_url primary.base_url;
         Alcotest.(check string) "fallback base url" fallback_url fallback.base_url
     | providers ->
         Alcotest.failf "expected 2 resolved providers, got %d"
           (List.length providers));
    for _ = 1 to Masc_mcp.Cascade_health_tracker.cooldown_threshold do
      Masc_mcp.Cascade_health_tracker.record_failure
        Masc_mcp.Cascade_health_tracker.global
        ~provider_key:primary_key
        ()
    done;
    reset_primary_calls ();
    reset_fallback_calls ();
    (match
       Masc_mcp.Cascade_health_tracker.check_circuit_breaker
         Masc_mcp.Cascade_health_tracker.global
         ~provider_key:primary_key
     with
     | Ok () -> Alcotest.fail "primary provider should be OPEN before run_named"
     | Error _ -> ());
    Alcotest.(check int)
      "primary has no requests before run_named"
      0
      (primary_calls ());
    match
      Oas_worker_named.run_named
        ~cascade_name:"breaker_probe_13318"
        ~goal:"say hello"
        ~system_prompt:"system"
        ~sw
        ~net:(require_test_net ())
        ()
    with
    | Ok _result ->
        Alcotest.(check int)
          "OPEN primary receives no request"
          0
          (primary_calls ());
        Alcotest.(check bool)
          "fallback provider receives requests"
          true
          (fallback_calls () > 0);
        (match
           Masc_mcp.Cascade_health_tracker.provider_info
             Masc_mcp.Cascade_health_tracker.global
             ~provider_key:fallback_key
         with
         | None -> Alcotest.fail "fallback provider should have health info"
         | Some info ->
             Alcotest.(check bool)
               "fallback success is reflected in health tracker"
               true
               (info.success_rate > 0.0));
        Eio.Switch.fail sw Exit
    | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)
  with Exit -> ()

let make_worker_meta ?(effective_model = "local-qwen") () :
    Worker_container_types.worker_container_meta =
  {
    Worker_container_types.version =
      Worker_container_types.worker_container_version;
    worker_name = "resume-worker";
    mcp_session_id = "session-1";
    workspace_path = "/tmp/workspace";
    role = Some "executor";
    selection_note = Some "resume";
    runtime_backend = Worker_execution_backend.Local_playground;
    thinking_enabled = Some true;
    timeout_seconds = Some 240;
    effective_model;
    checkpoint_path = "/tmp/checkpoint.json";
    turn_log_path = "/tmp/turns.jsonl";
    last_run_at = None;
  }

let make_checkpoint ?(model = "") () : Agent_sdk.Checkpoint.t =
  {
    Agent_sdk.Checkpoint.version = Agent_sdk.Checkpoint.checkpoint_version;
    session_id = "session-1";
    agent_name = "resume-worker";
    model;
    system_prompt = None;
    messages = [];
    usage = Agent_sdk.Types.empty_usage;
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
    response_format = Agent_sdk.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;
    max_input_tokens = None;
    max_total_tokens = None;
    context = Agent_sdk.Context.create ();
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
  let config =
    Oas_worker_exec.default_config
      ~name:"oas-worker-default"
      ~provider_cfg:(make_local_provider_cfg ())
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  Eio.Switch.run @@ fun sw ->
  match Oas_worker_exec.build ~sw ~net:(require_test_net ()) ~config with
  | Ok agent ->
      let policy = (Agent_sdk.Agent.options agent).tool_retry_policy in
      Alcotest.(check bool) "default leaves retry disabled" true
        (Option.is_none policy);
      Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_oas_worker_exec_build_applies_retry_policy () =
  let base_config =
    Oas_worker_exec.default_config
      ~name:"oas-worker-retry"
      ~provider_cfg:(make_local_provider_cfg ())
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  let config =
    { base_config with
      tool_retry_policy = Some Agent_sdk.Tool_retry_policy.default_internal }
  in
  Eio.Switch.run @@ fun sw ->
  match Oas_worker_exec.build ~sw ~net:(require_test_net ()) ~config with
  | Ok agent ->
      let policy = (Agent_sdk.Agent.options agent).tool_retry_policy in
      check_policy_matches_default_internal "exec build opt-in" policy;
      Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_oas_worker_exec_build_applies_stream_idle_timeout () =
  let base_config =
    Oas_worker_exec.default_config
      ~name:"oas-worker-stream-idle"
      ~provider_cfg:(make_local_provider_cfg ())
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  let config = { base_config with stream_idle_timeout_s = Some 12.5 } in
  Eio.Switch.run @@ fun sw ->
  match Oas_worker_exec.build ~sw ~net:(require_test_net ()) ~config with
  | Ok agent ->
      let timeout_s = (Agent_sdk.Agent.options agent).stream_idle_timeout_s in
      Alcotest.(check (option (float 0.0001)))
        "stream idle timeout is propagated through build" (Some 12.5)
        timeout_s;
      Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_apply_stream_idle_timeout_default_passes_through_caller_value () =
  let provided = Some 7.5 in
  let result = Oas_worker_named.apply_stream_idle_timeout_default provided in
  Alcotest.(check (option (float 0.0001)))
    "explicit Some passes through unchanged" provided result

let test_apply_stream_idle_timeout_default_injects_keepalive_default () =
  let result = Oas_worker_named.apply_stream_idle_timeout_default None in
  let expected =
    Some Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec
  in
  Alcotest.(check (option (float 0.0001)))
    "omitted timeout receives keepalive default" expected result

let test_oas_worker_exec_build_default_priority_unset () =
  let config =
    Oas_worker_exec.default_config
      ~name:"oas-worker-default-priority"
      ~provider_cfg:(make_local_provider_cfg ())
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  Eio.Switch.run @@ fun sw ->
  match Oas_worker_exec.build ~sw ~net:(require_test_net ()) ~config with
  | Ok agent ->
      let priority = (Agent_sdk.Agent.state agent).config.priority in
      Alcotest.(check bool) "default priority remains unset" true
        (Option.is_none priority);
      Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_oas_worker_exec_build_applies_priority () =
  let base_config =
    Oas_worker_exec.default_config
      ~name:"oas-worker-priority"
      ~provider_cfg:(make_local_provider_cfg ())
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  let config =
    { base_config with
      priority = Some Llm_provider.Request_priority.Proactive }
  in
  Eio.Switch.run @@ fun sw ->
  match Oas_worker_exec.build ~sw ~net:(require_test_net ()) ~config with
  | Ok agent ->
      let priority = (Agent_sdk.Agent.state agent).config.priority in
      Alcotest.(check bool) "priority propagated to agent config" true
        (match priority with
         | Some Llm_provider.Request_priority.Proactive -> true
         | _ -> false);
      Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_oas_worker_exec_build_supports_kimi_direct () =
  let provider_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Kimi
      ~model_id:"kimi-for-coding"
      ~base_url:"https://api.kimi.com/coding" ()
  in
  let config =
    Oas_worker_exec.default_config
      ~name:"oas-worker-kimi-direct"
      ~provider_cfg
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  Eio.Switch.run @@ fun sw ->
  match Oas_worker_exec.build ~sw ~net:(require_test_net ()) ~config with
  | Ok agent -> Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_oas_worker_exec_build_supports_kimi_cli () =
  let provider_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Kimi_cli
      ~model_id:"kimi-for-coding"
      ~base_url:"" ()
  in
  let config =
    Oas_worker_exec.default_config
      ~name:"oas-worker-kimi-cli"
      ~provider_cfg
      ~system_prompt:"system"
      ~tools:[ make_named_noop_tool "masc_status" ]
  in
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  match Oas_worker_exec.build ~sw ~net:(require_test_net ()) ~config with
  | Ok agent -> Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

(* Resume parity: fields that [build] threads from [config] via the
   Builder must also propagate through [resume_from_checkpoint]. Each
   missing field used to fail silently — the run continued with
   [default_options.<field>] (= [None]). The [approval] regression was
   the loud signal: OAS logged "ApprovalRequired but no approval
   callback — executing" on the first ApprovalRequired tool of a
   resumed keeper. *)

let test_resume_propagates_approval () =
  let approval_called = ref false in
  let approval : Agent_sdk.Hooks.approval_callback =
    fun ~tool_name:_ ~input:_ ->
      approval_called := true;
      Agent_sdk.Hooks.Approve
  in
  let base_config =
    Oas_worker_exec.default_config
      ~name:"resume-approval"
      ~provider_cfg:(make_local_provider_cfg ())
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  let config = { base_config with approval = Some approval } in
  let checkpoint = make_checkpoint () in
  Eio.Switch.run @@ fun sw ->
  match
    Oas_worker_exec.resume_from_checkpoint
      ~sw ~net:(require_test_net ()) ~config ~checkpoint
  with
  | Ok agent ->
      let approval_opt = (Agent_sdk.Agent.options agent).approval in
      Alcotest.(check bool) "approval is propagated through resume" true
        (Option.is_some approval_opt);
      (match approval_opt with
       | Some cb ->
           let _ = cb ~tool_name:"x" ~input:`Null in
           Alcotest.(check bool) "callback identity preserved" true
             !approval_called
       | None -> ());
      Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resume_propagates_slot_id () =
  let base_config =
    Oas_worker_exec.default_config
      ~name:"resume-slot-id"
      ~provider_cfg:(make_local_provider_cfg ())
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  let config = { base_config with slot_id = Some 7 } in
  let checkpoint = make_checkpoint () in
  Eio.Switch.run @@ fun sw ->
  match
    Oas_worker_exec.resume_from_checkpoint
      ~sw ~net:(require_test_net ()) ~config ~checkpoint
  with
  | Ok agent ->
      let slot = (Agent_sdk.Agent.options agent).slot_id in
      Alcotest.(check (option int)) "slot_id is propagated" (Some 7) slot;
      Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resume_propagates_summarizer () =
  let summarizer_called = ref false in
  let summarizer (_msgs : Agent_sdk.Types.message list) =
    summarizer_called := true;
    "summary"
  in
  let base_config =
    Oas_worker_exec.default_config
      ~name:"resume-summarizer"
      ~provider_cfg:(make_local_provider_cfg ())
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  let config = { base_config with summarizer = Some summarizer } in
  let checkpoint = make_checkpoint () in
  Eio.Switch.run @@ fun sw ->
  match
    Oas_worker_exec.resume_from_checkpoint
      ~sw ~net:(require_test_net ()) ~config ~checkpoint
  with
  | Ok agent ->
      let s = (Agent_sdk.Agent.options agent).summarizer in
      Alcotest.(check bool) "summarizer is propagated" true (Option.is_some s);
      (match s with
       | Some f ->
           let _ = f [] in
           Alcotest.(check bool) "summarizer identity preserved" true
             !summarizer_called
      | None -> ());
      Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resume_propagates_stream_idle_timeout () =
  let base_config =
    Oas_worker_exec.default_config
      ~name:"resume-stream-idle"
      ~provider_cfg:(make_local_provider_cfg ())
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  let config = { base_config with stream_idle_timeout_s = Some 12.5 } in
  let checkpoint = make_checkpoint () in
  Eio.Switch.run @@ fun sw ->
  match
    Oas_worker_exec.resume_from_checkpoint
      ~sw ~net:(require_test_net ()) ~config ~checkpoint
  with
  | Ok agent ->
      let timeout_s = (Agent_sdk.Agent.options agent).stream_idle_timeout_s in
      Alcotest.(check (option (float 0.0001)))
        "stream idle timeout is propagated through resume" (Some 12.5)
        timeout_s;
      Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resume_propagates_priority () =
  let base_config =
    Oas_worker_exec.default_config
      ~name:"resume-priority"
      ~provider_cfg:(make_local_provider_cfg ())
      ~system_prompt:"system"
      ~tools:[ make_noop_tool () ]
  in
  let config =
    { base_config with priority = Some Llm_provider.Request_priority.Proactive }
  in
  let checkpoint = make_checkpoint () in
  Eio.Switch.run @@ fun sw ->
  match
    Oas_worker_exec.resume_from_checkpoint
      ~sw ~net:(require_test_net ()) ~config ~checkpoint
  with
  | Ok agent ->
      let priority = (Agent_sdk.Agent.state agent).config.priority in
      Alcotest.(check bool) "priority propagated through resume" true
        (match priority with
         | Some Llm_provider.Request_priority.Proactive -> true
         | _ -> false);
      Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_provider_of_label_rejects_invalid_explicit_label () =
  match Oas_worker_exec.resolve_provider_config_of_label "not-a-model-label" with
  | Ok _ ->
      Alcotest.fail
        "expected invalid explicit model label to be rejected without fallback"
  | Error err ->
      let msg = Oas_worker_exec.label_resolution_error_to_string err in
      Alcotest.(check bool) "mentions invalid model label" true
        (contains_substring ~needle:"invalid model label" msg);
      Alcotest.(check bool) "mentions rejected label" true
        (contains_substring ~needle:"not-a-model-label" msg)

let test_run_model_with_masc_tools_rejects_invalid_explicit_label () =
  match
    Oas_worker.run_model_with_masc_tools
      ~model_label:"not-a-model-label"
      ~goal:"test goal"
      ~masc_tools:[]
      ~dispatch:(fun ~name ~args:_ ->
        Tool_result.wrap ~tool_name:name ~start_time:(Time_compat.now ())
          (true, "ok"))
      ()
  with
  | Ok _ ->
      Alcotest.fail "expected invalid explicit model label to fail before execution"
  | Error (Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; detail })) ->
      Alcotest.(check string) "invalid field" "model_label" field;
      Alcotest.(check bool) "detail mentions rejected label" true
        (contains_substring ~needle:"not-a-model-label" detail)
  | Error err ->
      Alcotest.failf "unexpected error shape: %s" (Agent_sdk.Error.to_string err)

let mock_completion_request () : Llm_provider.Llm_transport.completion_request =
  {
    config =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.Claude_code
        ~model_id:"auto"
        ~base_url:""
        ();
    messages = [];
    tools = [];
    runtime_mcp_policy = None;
  }

let mock_api_response () : Agent_sdk.Types.api_response =
  {
    id = "mock-session";
    model = "mock-cli";
    stop_reason = Agent_sdk.Types.EndTurn;
    content = [ Agent_sdk.Types.Text "ok" ];
    usage = None;
    telemetry = None;
  }

let leaking_test_transport_factory ~sw : Llm_provider.Llm_transport.t =
  let response = Ok (mock_api_response ()) in
  let leak_one_pipe () =
    ignore (Eio.Process.pipe ~sw (require_test_proc_mgr ()))
  in
  {
    complete_sync =
      (fun _req ->
        leak_one_pipe ();
        { Llm_provider.Llm_transport.response; latency_ms = 0 });
    complete_stream =
      (fun ~on_event:_ _req ->
        leak_one_pipe ();
        response);
  }

let require_fd_leak_delta_at_least ~label ~minimum actual =
  if actual < minimum then
    Alcotest.failf "%s: expected fd delta >= %d, got %d" label minimum actual

let require_fd_leak_delta_at_most ~label ~maximum actual =
  if actual > maximum then
    Alcotest.failf "%s: expected fd delta <= %d, got %d" label maximum actual

let test_make_per_call_switch_transport_releases_cli_fd_resources () =
  let request = mock_completion_request () in
  let leaking_delta =
    Eio.Switch.run @@ fun sw ->
    let transport = leaking_test_transport_factory ~sw in
    let before = Prometheus.approximate_open_fd_count () in
    for _ = 1 to 32 do
      ignore (transport.complete_sync request);
      ignore (transport.complete_stream ~on_event:(fun _ -> ()) request)
    done;
    Prometheus.approximate_open_fd_count () - before
  in
  require_fd_leak_delta_at_least
    ~label:"control transport leaks on long-lived switch"
    ~minimum:32
    leaking_delta;
  let wrapped =
    Oas_worker_exec.make_per_call_switch_transport leaking_test_transport_factory
  in
  let before = Prometheus.approximate_open_fd_count () in
  for _ = 1 to 32 do
    ignore (wrapped.complete_sync request);
    ignore (wrapped.complete_stream ~on_event:(fun _ -> ()) request)
  done;
  let wrapped_delta = Prometheus.approximate_open_fd_count () - before in
  require_fd_leak_delta_at_most
    ~label:"per-call switch wrapper bounds fd growth"
    ~maximum:6
    wrapped_delta

let test_classify_masc_internal_error_roundtrip () =
  let cascade_err =
    Oas_worker_named.sdk_error_of_masc_internal_error
      (Oas_worker_named.Cascade_exhausted
         {
           cascade_name =
             internal_cascade_name Masc_mcp.Keeper_config.default_cascade_name;
           reason = Keeper_types.All_providers_failed;
         })
  in
  (match Oas_worker_named.classify_masc_internal_error cascade_err with
   | Some (Oas_worker_named.Cascade_exhausted { cascade_name; reason }) ->
       Alcotest.(check string) "cascade name"
         Masc_mcp.Keeper_config.default_cascade_name
         (internal_cascade_name_to_string cascade_name);
       Alcotest.(check string) "cascade reason"
         (Keeper_types.cascade_exhaustion_summary Keeper_types.All_providers_failed)
         (Keeper_types.cascade_exhaustion_summary reason)
   | _ -> Alcotest.fail "expected structured cascade exhaustion");
  let accept_err =
    Oas_worker_named.sdk_error_of_masc_internal_error
      (Oas_worker_named.Accept_rejected
         {
           scope = Masc_mcp.Keeper_config.default_cascade_name;
           model = Some "mock-model";
           reason = "response rejected by accept (model=mock-model)";
         })
  in
  (match Oas_worker_named.classify_masc_internal_error accept_err with
   | Some (Oas_worker_named.Accept_rejected { scope; model; reason }) ->
       Alcotest.(check string) "accept scope" Masc_mcp.Keeper_config.default_cascade_name scope;
       Alcotest.(check (option string)) "accept model"
         (Some "mock-model") model;
       Alcotest.(check bool) "accept reason preserved" true
         (contains_substring ~needle:"response rejected by accept" reason)
   | _ -> Alcotest.fail "expected structured accept rejection");
  let resumable_err =
    Oas_worker_named.sdk_error_of_masc_internal_error
      (Oas_worker_named.Resumable_cli_session
         {
           cascade_name = internal_cascade_name "kimi_cli_keeper";
           detail = Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail;
           exit_code = Some 75;
         })
  in
  match Oas_worker_named.classify_masc_internal_error resumable_err with
  | Some (Oas_worker_named.Resumable_cli_session { cascade_name; detail; exit_code }) ->
      Alcotest.(check string) "resumable cascade" "kimi_cli_keeper"
        (internal_cascade_name_to_string cascade_name);
      Alcotest.(check string) "resumable detail redacted"
        Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail
        detail;
      Alcotest.(check bool) "resumable detail hides raw resume hint" false
        (contains_substring ~needle:"To resume this session:" detail);
      Alcotest.(check bool) "resumable detail hides session token" false
        (contains_substring ~needle:"kimi -r" detail);
      Alcotest.(check (option int)) "resumable exit code" (Some 75) exit_code
  | _ -> Alcotest.fail "expected structured resumable CLI session error"

let make_codex_cli_provider_cfg ?(model_id = "codex") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Codex_cli
    ~model_id ~base_url:"" ()

let make_claude_code_provider_cfg ?(model_id = "auto") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Claude_code
    ~model_id ~base_url:"" ()

let make_gemini_cli_provider_cfg ?(model_id = "gemini-2.5-pro") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Gemini_cli
    ~model_id ~base_url:"" ()

let make_ollama_provider_cfg ?(model_id = "qwen3:27b") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Ollama
    ~model_id ~base_url:"http://127.0.0.1:11434" ()

let make_openai_compat_provider_cfg ?(model_id = "gpt-4.1") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id ~base_url:"http://127.0.0.1:18080/v1" ()

let make_glm_provider_cfg ?(base_url = Llm_provider.Zai_catalog.general_base_url)
    ?(model_id = "glm-5.1") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Glm
    ~model_id ~base_url ()

let provider_registry_entry_exn name =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry name with
  | Some entry -> entry
  | None -> Alcotest.failf "expected provider registry entry %S" name

let make_openrouter_provider_cfg ?(model_id = "anthropic/claude-3.5") () =
  let entry = provider_registry_entry_exn "openrouter" in
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id
    ~base_url:entry.defaults.base_url
    ~request_path:entry.defaults.request_path
    ()

let make_kimi_provider_cfg ?(model_id = "kimi-k2.5") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id
    ~base_url:"https://api.moonshot.ai/v1"
    ~request_path:"/chat/completions"
    ()

let make_kimi_cli_provider_cfg ?(model_id = "kimi-for-coding") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Kimi_cli
    ~model_id
    ~base_url:""
    ()

let test_cascade_provider_labels_keep_glm_and_glm_coding_distinct () =
  let glm = Masc_mcp.Oas_worker_cascade.provider_name_of_config
      (make_glm_provider_cfg ()) in
  let glm_coding = Masc_mcp.Oas_worker_cascade.provider_name_of_config
      (make_glm_provider_cfg ~base_url:Llm_provider.Zai_catalog.coding_base_url ()) in
  Alcotest.(check string) "general GLM label" "glm" glm;
  Alcotest.(check string) "coding GLM label" "glm-coding" glm_coding

let test_provider_effective_max_turns_clamps_claude_code () =
  Alcotest.(check int)
    "claude_code max_turns hard cap"
    Oas_worker_exec.claude_code_max_turns_hard_cap
    (Oas_worker_exec.provider_effective_max_turns
       Llm_provider.Provider_config.Claude_code
       39)

let test_provider_effective_max_turns_keeps_ollama_budget () =
  Alcotest.(check int)
    "ollama has no provider max_turns cap"
    39
    (Oas_worker_exec.provider_effective_max_turns
       Llm_provider.Provider_config.Ollama
       39)

let check_timeout_opt label expected actual =
  Alcotest.(check (option (float 0.001))) label expected actual

let provider_timeout ?(is_last = false) ?configured provider_cfg =
  Oas_worker_named.effective_provider_attempt_timeout_s
    ~is_last
    ~configured_timeout_s:configured
    provider_cfg

let test_provider_attempt_timeout_caps_claude_code () =
  check_timeout_opt
    "claude_code caps configured attempt timeout"
    (Some 120.0)
    (provider_timeout
       ~configured:300.0
       (make_claude_code_provider_cfg ()))

let test_provider_attempt_timeout_caps_kimi_cli () =
  check_timeout_opt
    "kimi_cli caps configured attempt timeout"
    (Some 60.0)
    (provider_timeout
       ~configured:300.0
       (make_kimi_cli_provider_cfg ()))

let test_provider_attempt_timeout_caps_gemini_cli () =
  check_timeout_opt
    "gemini_cli caps configured attempt timeout"
    (Some 180.0)
    (provider_timeout
       ~configured:300.0
       (make_gemini_cli_provider_cfg ()))

let test_provider_attempt_timeout_floors_ollama () =
  check_timeout_opt
    "ollama floors too-short configured attempt timeout"
    (Some 300.0)
    (provider_timeout
       ~configured:60.0
       (make_ollama_provider_cfg ()))

let test_provider_attempt_timeout_leaves_unconstrained_last_to_outer_budget () =
  check_timeout_opt
    "unconstrained final provider relies on enclosing keeper/OAS timeout"
    None
    (provider_timeout
       ~is_last:true
       ~configured:300.0
       (make_openai_compat_provider_cfg ()))

let test_cascade_provider_labels_preserve_registered_openai_compat_family () =
  let provider_name = Masc_mcp.Oas_worker_cascade.provider_name_of_config
      (make_openrouter_provider_cfg ()) in
  let model_label = Masc_mcp.Oas_worker_cascade.model_label_of_config
      (make_openrouter_provider_cfg ()) in
  Alcotest.(check string) "openrouter provider name" "openrouter" provider_name;
  Alcotest.(check string) "openrouter model label"
    "openrouter:anthropic/claude-3.5" model_label

let test_cascade_provider_labels_detect_kimi_from_endpoint_metadata () =
  let provider_name = Masc_mcp.Oas_worker_cascade.provider_name_of_config
      (make_kimi_provider_cfg ()) in
  let model_label = Masc_mcp.Oas_worker_cascade.model_label_of_config
      (make_kimi_provider_cfg ()) in
  Alcotest.(check string) "kimi provider name" "kimi" provider_name;
  Alcotest.(check string) "kimi model label" "kimi:kimi-k2.5" model_label

let test_resolve_tool_lane_for_codex_cli_public_tools_uses_runtime_mcp_policy () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  let tools =
    [ make_named_noop_tool "masc_status"; make_named_noop_tool "masc_tasks" ]
  in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~provider_cfg:(make_codex_cli_provider_cfg ())
      ~tools ()
  with
  | Ok (effective_tools, Some policy) ->
      let masc_headers =
        List.find_map
          (function
            | Llm_provider.Llm_transport.Http_server server
              when String.equal server.name "masc" -> Some server.headers
            | _ -> None)
          policy.servers
      in
      Alcotest.(check int) "runtime lane strips inline tools" 0
        (List.length effective_tools);
      Alcotest.(check (list string)) "allowed tool names preserve public MCP set"
        [ "masc_status"; "masc_tasks" ] policy.allowed_tool_names;
      Alcotest.(check (list string)) "allowed server names"
        [ "masc" ] policy.allowed_server_names;
      Alcotest.(check (list string)) "runtime server name"
        [ "masc" ]
        (List.map Llm_provider.Llm_transport.runtime_mcp_server_name policy.servers);
      Alcotest.(check bool) "strict runtime policy" true policy.strict;
      Alcotest.(check bool) "builtins disabled" true policy.disable_builtin_tools;
      Alcotest.(check (option string)) "codex_cli runtime lane strips bearer header" None
        (Option.bind masc_headers (List.assoc_opt "Authorization"))
  | Ok (_, None) ->
      Alcotest.fail "expected codex_cli public MCP tools to use runtime MCP lane"
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_codex_cli_public_tools_with_agent_name_keeps_identity_headers () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_temp_masc_base_path "codex-public-runtime-mcp" @@ fun _base_path ->
  let tools =
    [ make_named_noop_tool "masc_status"; make_named_noop_tool "masc_tasks" ]
  in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~agent_name:"keeper-sangsu-agent"
      ~provider_cfg:(make_codex_cli_provider_cfg ())
      ~tools ()
  with
  | Ok (effective_tools, Some policy) ->
      let masc_headers =
        List.find_map
          (function
            | Llm_provider.Llm_transport.Http_server server
              when String.equal server.name "masc" -> Some server.headers
            | _ -> None)
          policy.servers
      in
      Alcotest.(check int) "runtime lane strips inline tools" 0
        (List.length effective_tools);
      Alcotest.(check (option string)) "codex_cli preserves agent identity header"
        (Some "keeper-sangsu-agent")
        (Option.bind masc_headers (List.assoc_opt "x-masc-agent-name"));
      Alcotest.(check (option string)) "codex_cli preserves keeper identity header"
        (Some "sangsu")
        (Option.bind masc_headers (List.assoc_opt "x-masc-keeper-name"));
      Alcotest.(check (option string)) "codex_cli strips bearer header" None
        (Option.bind masc_headers (List.assoc_opt "Authorization"))
  | Ok (_, None) ->
      Alcotest.fail
        "expected codex_cli public MCP tools with agent_name to use runtime MCP lane"
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_codex_cli_keeper_bound_public_tools_omits_bound_tools () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_temp_masc_base_path "codex-bound-no-token" @@ fun _base_path ->
  let tools =
    [ make_named_noop_tool "masc_status"; make_named_noop_tool "masc_claim_next" ]
  in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~tool_requirement:`Optional
      ~agent_name:"keeper-sangsu-agent"
      ~provider_cfg:(make_codex_cli_provider_cfg ())
      ~tools ()
  with
  | Ok (effective_tools, Some policy) ->
      let masc_headers =
        List.find_map
          (function
            | Llm_provider.Llm_transport.Http_server server
              when String.equal server.name "masc" -> Some server.headers
            | _ -> None)
          policy.servers
      in
      Alcotest.(check int) "runtime lane strips inline tools" 0
        (List.length effective_tools);
      Alcotest.(check (list string)) "keeper-bound tool omitted for codex_cli"
        [ "masc_status" ] policy.allowed_tool_names;
      Alcotest.(check (option string)) "codex_cli preserves agent identity header"
        (Some "keeper-sangsu-agent")
        (Option.bind masc_headers (List.assoc_opt "x-masc-agent-name"));
      Alcotest.(check (option string)) "codex_cli preserves keeper identity header"
        (Some "sangsu")
        (Option.bind masc_headers (List.assoc_opt "x-masc-keeper-name"));
      Alcotest.(check (option string)) "codex_cli strips internal token" None
        (Option.bind masc_headers (List.assoc_opt "x-masc-internal-token"))
  | Ok (_, None) ->
      Alcotest.fail
        "expected codex_cli keeper-bound public MCP tools to keep safe runtime lane"
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_codex_cli_keeper_bound_public_tools_with_per_keeper_token_keeps_bound_tools
    () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_temp_masc_base_path "codex-bound-token" @@ fun () ->
  let base_path = Sys.getenv "MASC_BASE_PATH" in
  seed_raw_token base_path "keeper-sangsu-agent" "keeper-bearer-xyz";
  let tools =
    [ make_named_noop_tool "masc_status"; make_named_noop_tool "masc_claim_next" ]
  in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~agent_name:"keeper-sangsu-agent"
      ~provider_cfg:(make_codex_cli_provider_cfg ())
      ~tools ()
  with
  | Ok (effective_tools, Some policy) ->
      let masc_headers =
        List.find_map
          (function
            | Llm_provider.Llm_transport.Http_server server
              when String.equal server.name "masc" -> Some server.headers
            | _ -> None)
          policy.servers
      in
      Alcotest.(check int) "runtime lane strips inline tools" 0
        (List.length effective_tools);
      Alcotest.(check (list string)) "keeper-bound tool preserved for codex_cli"
        [ "masc_status"; "masc_claim_next" ] policy.allowed_tool_names;
      Alcotest.(check (option string)) "codex_cli uses per-keeper bearer"
        (Some "Bearer keeper-bearer-xyz")
        (Option.bind masc_headers (List.assoc_opt "Authorization"));
      Alcotest.(check (option string)) "codex_cli preserves agent identity header"
        (Some "keeper-sangsu-agent")
        (Option.bind masc_headers (List.assoc_opt "x-masc-agent-name"));
      Alcotest.(check (option string)) "codex_cli strips internal token" None
        (Option.bind masc_headers (List.assoc_opt "x-masc-internal-token"))
  | Ok (_, None) ->
      Alcotest.fail
        "expected codex_cli keeper-bound public MCP tools to use runtime MCP lane"
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_kimi_cli_public_tools_uses_runtime_mcp_policy () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  let tools =
    [ make_named_noop_tool "masc_status"; make_named_noop_tool "masc_tasks" ]
  in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~provider_cfg:(make_kimi_cli_provider_cfg ())
      ~tools ()
  with
  | Ok (effective_tools, Some policy) ->
      Alcotest.(check int) "runtime lane strips inline tools" 0
        (List.length effective_tools);
      Alcotest.(check (list string)) "allowed tool names preserve public MCP set"
        [ "masc_status"; "masc_tasks" ] policy.allowed_tool_names;
      Alcotest.(check (list string)) "allowed server names"
        [ "masc" ] policy.allowed_server_names;
      Alcotest.(check (list string)) "runtime server name"
        [ "masc" ]
        (List.map Llm_provider.Llm_transport.runtime_mcp_server_name policy.servers);
      Alcotest.(check bool) "strict runtime policy" true policy.strict;
      Alcotest.(check bool) "builtins disabled" true policy.disable_builtin_tools
  | Ok (_, None) ->
      Alcotest.fail "expected kimi_cli public MCP tools to use runtime MCP lane"
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_kimi_cli_public_tools_with_agent_name_keeps_runtime_headers () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  let tools =
    [ make_named_noop_tool "masc_status"; make_named_noop_tool "masc_tasks" ]
  in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~agent_name:"keeper-sangsu-agent"
      ~provider_cfg:(make_kimi_cli_provider_cfg ())
      ~tools ()
  with
  | Ok (effective_tools, Some policy) ->
      let masc_headers =
        List.find_map
          (function
            | Llm_provider.Llm_transport.Http_server server
              when String.equal server.name "masc" -> Some server.headers
            | _ -> None)
          policy.servers
      in
      Alcotest.(check int) "runtime lane strips inline tools" 0
        (List.length effective_tools);
      Alcotest.(check (option string)) "keeper header preserved on runtime MCP policy"
        (Some "keeper-sangsu-agent")
        (Option.bind masc_headers (List.assoc_opt "x-masc-agent-name"))
  | Ok (_, None) ->
      Alcotest.fail
        "expected kimi_cli public MCP tools with agent_name to use runtime MCP lane"
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_claude_code_keeper_internal_tools_uses_runtime_mcp_policy () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  let tools = [ make_named_noop_tool "keeper_bash" ] in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~agent_name:"keeper-sangsu-agent"
      ~provider_cfg:(make_claude_code_provider_cfg ())
      ~tools ()
  with
  | Ok (effective_tools, Some policy) ->
      let masc_headers =
        List.find_map
          (function
            | Llm_provider.Llm_transport.Http_server server
              when String.equal server.name "masc" -> Some server.headers
            | _ -> None)
          policy.servers
      in
      Alcotest.(check int) "runtime lane strips inline tools" 0
        (List.length effective_tools);
      Alcotest.(check (list string)) "keeper internal tool allowed"
        [ "keeper_bash" ] policy.allowed_tool_names;
      Alcotest.(check (option string)) "keeper header preserved"
        (Some "sangsu")
        (Option.bind masc_headers (List.assoc_opt "x-masc-keeper-name"));
      Alcotest.(check (option string)) "internal token preserved"
        (Some "internal-keeper-token")
        (Option.bind masc_headers (List.assoc_opt "x-masc-internal-token"))
  | Ok (_, None) ->
      Alcotest.fail
        "expected claude_code keeper-internal tools to use runtime MCP lane"
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_kimi_cli_keeper_internal_tools_uses_runtime_mcp_policy () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  let tools = [ make_named_noop_tool "keeper_bash" ] in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~agent_name:"keeper-sangsu-agent"
      ~provider_cfg:(make_kimi_cli_provider_cfg ())
      ~tools ()
  with
  | Ok (effective_tools, Some policy) ->
      Alcotest.(check int) "runtime lane strips inline tools" 0
        (List.length effective_tools);
      Alcotest.(check (list string)) "keeper internal tool allowed"
        [ "keeper_bash" ] policy.allowed_tool_names
  | Ok (_, None) ->
      Alcotest.fail
        "expected kimi_cli keeper-internal tools to use runtime MCP lane"
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_kimi_cli_mixed_tools_keeps_public_runtime_subset () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  let tools =
    [
      make_named_noop_tool "keeper_board_get";
      make_named_noop_tool "masc_status";
      make_named_noop_tool "masc_tasks";
    ]
  in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~provider_cfg:(make_kimi_cli_provider_cfg ())
      ~tools ()
  with
  | Ok (effective_tools, Some policy) ->
      Alcotest.(check int) "runtime lane strips inline tools" 0
        (List.length effective_tools);
      Alcotest.(check (list string)) "public runtime subset preserved"
        [ "masc_status"; "masc_tasks" ] policy.allowed_tool_names
  | Ok (_, None) ->
      Alcotest.fail
        "expected kimi_cli mixed surface to keep the public MCP runtime subset"
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_openai_public_tools_keeps_inline_tools () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  let tools =
    [ make_named_noop_tool "masc_status"; make_named_noop_tool "masc_tasks" ]
  in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~provider_cfg:(make_openai_compat_provider_cfg ())
      ~tools ()
  with
  | Ok (effective_tools, None) ->
      Alcotest.(check int) "inline lane keeps requested tools"
        (List.length tools) (List.length effective_tools)
  | Ok (_, Some _) ->
      Alcotest.fail "expected openai_compat public tools to stay on inline lane"
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_codex_cli_internal_tools_rejects () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~provider_cfg:(make_codex_cli_provider_cfg ())
      ~tools:[ make_named_noop_tool "keeper_board_get" ] ()
  with
  | Ok _ ->
      Alcotest.fail
        "expected codex_cli to reject keeper-internal tools without inline tool support"
  | Error (Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; _ })) ->
      Alcotest.(check string) "field" "tool_support" field
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_codex_cli_keeper_internal_tools_with_agent_rejects () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_temp_masc_base_path "codex-internal-no-token" @@ fun _base_path ->
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~agent_name:"keeper-sangsu-agent"
      ~provider_cfg:(make_codex_cli_provider_cfg ())
      ~tools:[ make_named_noop_tool "keeper_bash" ] ()
  with
  | Ok _ ->
      Alcotest.fail
        "expected codex_cli to reject keeper-internal tools requiring request-scoped headers"
  | Error (Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; _ })) ->
      Alcotest.(check string) "field" "tool_support" field
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_codex_cli_keeper_internal_tools_with_agent_and_per_keeper_token_uses_runtime_mcp
    () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_temp_masc_base_path "codex-internal-token" @@ fun () ->
  let base_path = Sys.getenv "MASC_BASE_PATH" in
  seed_raw_token base_path "keeper-sangsu-agent" "keeper-bearer-abc";
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~agent_name:"keeper-sangsu-agent"
      ~provider_cfg:(make_codex_cli_provider_cfg ())
      ~tools:[ make_named_noop_tool "keeper_bash" ] ()
  with
  | Ok (effective_tools, Some policy) ->
      let masc_headers =
        List.find_map
          (function
            | Llm_provider.Llm_transport.Http_server server
              when String.equal server.name "masc" -> Some server.headers
            | _ -> None)
          policy.servers
      in
      Alcotest.(check int) "runtime lane strips inline tools" 0
        (List.length effective_tools);
      Alcotest.(check (list string)) "keeper internal tool preserved"
        [ "keeper_bash" ] policy.allowed_tool_names;
      Alcotest.(check (option string)) "codex_cli uses per-keeper bearer"
        (Some "Bearer keeper-bearer-abc")
        (Option.bind masc_headers (List.assoc_opt "Authorization"));
      Alcotest.(check (option string)) "codex_cli strips internal token" None
        (Option.bind masc_headers (List.assoc_opt "x-masc-internal-token"))
  | Ok (_, None) ->
      Alcotest.fail
        "expected codex_cli keeper-internal tools with per-keeper token to use runtime MCP lane"
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_kimi_cli_internal_tools_rejects () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~provider_cfg:(make_kimi_cli_provider_cfg ())
      ~tools:[ make_named_noop_tool "keeper_board_get" ] ()
  with
  | Ok _ ->
      Alcotest.fail
        "expected kimi_cli to reject keeper-internal tools without inline tool support"
  | Error (Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; _ })) ->
      Alcotest.(check string) "field" "tool_support" field
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_resolve_tool_lane_for_codex_cli_internal_tools_optional_drops_tools () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~tool_requirement:`Optional
      ~provider_cfg:(make_codex_cli_provider_cfg ())
      ~tools:[ make_named_noop_tool "keeper_board_get" ] ()
  with
  | Ok (effective_tools, runtime_mcp_policy) ->
      Alcotest.(check int) "unsupported optional internal tools are dropped" 0
        (List.length effective_tools);
      Alcotest.(check bool) "dropped optional tools stay text-only" true
        (Option.is_none runtime_mcp_policy)
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)

let test_filter_candidate_providers_for_tool_support_normalizes_codex_headers () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "shared-codex-token" @@ fun () ->
  let runtime_mcp_policy =
    Oas_worker_exec.public_mcp_runtime_policy_of_tool_names
      ~agent_name:"keeper-sangsu-agent" [ "masc_status" ]
  in
  let filtered =
    Masc_mcp.Oas_worker_named.filter_candidate_providers_for_tool_support
      ~keeper_name:"sangsu"
      ?runtime_mcp_policy
      ~require_tool_choice_support:true
      ~require_tool_support:true
      ~label:"big_three"
      [ make_codex_cli_provider_cfg () ]
  in
  Alcotest.(check int)
    "codex survives provider-normalized runtime MCP tool filter"
    1 (List.length filtered)

let test_filter_candidate_providers_for_tool_support_drops_codex_cli_keeper_bound_actor_tools
    () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_temp_masc_base_path "codex-filter-no-token" @@ fun _base_path ->
  let runtime_mcp_policy =
    Oas_worker_exec.public_mcp_runtime_policy_of_tool_names
      ~agent_name:"keeper-sangsu-agent" [ "masc_status"; "masc_claim_next" ]
  in
  let codex_provider = make_codex_cli_provider_cfg () in
  (* Post-#13149 review: this test originally pinned the
     [codex_keeper_bound_skip_log_message] pure helper.  That left
     the production [log_codex_keeper_bound_skip] emission path
     uncovered (removing it / changing its level / suppressing the
     first emission would still pass) and forced the helper to be
     part of [Oas_worker_named]'s public API.  Drive the actual
     emission from [filter_candidate_providers_for_tool_support]
     and observe it via [Log.Ring].

     [since_seq] is exclusive ([> seq]), so a falsy [Some 0] would
     skip a fresh entry whose seq is 0 (e.g. when this test runs in
     isolation against an empty ring).  Pass [None] when the ring
     is empty so [recent] returns every entry. *)
  let before_seq =
    match Log.Ring.recent ~limit:1 () with
    | (entry : Log.Ring.entry) :: _ -> Some entry.seq
    | [] -> None
  in
  let filtered =
    Masc_mcp.Oas_worker_named.filter_candidate_providers_for_tool_support
      ~keeper_name:"sangsu"
      ?runtime_mcp_policy
      ~require_tool_choice_support:true
      ~require_tool_support:true
      ~label:"tool_use_strict"
      [ codex_provider; make_kimi_cli_provider_cfg () ]
  in
  let codex_skip_entries =
    Log.Ring.recent ~limit:50 ~module_filter:"Misc" ?since_seq:before_seq ()
    |> List.filter (fun (entry : Log.Ring.entry) ->
        contains_substring ~needle:"reason=codex_keeper_bound_actor_required"
          entry.message)
  in
  (match codex_skip_entries with
   | [] ->
       Alcotest.failf
         "expected at least one codex bound-actor skip log entry; \
          observed none under module_filter=Misc since seq=%s"
         (match before_seq with Some s -> string_of_int s | None -> "<empty>")
   | (entry : Log.Ring.entry) :: _ ->
       Alcotest.(check bool)
         "skip log mentions cascade tool_use_strict label" true
         (contains_substring
            ~needle:"cascade tool_use_strict:" entry.message);
       Alcotest.(check bool)
         "skip log mentions provider=codex_cli:codex" true
         (contains_substring
            ~needle:"provider=codex_cli:codex" entry.message);
       Alcotest.(check bool)
         "skip log mentions keeper=sangsu" true
         (contains_substring ~needle:"keeper=sangsu" entry.message));
  match filtered with
  | [ provider_cfg ] ->
      Alcotest.(check bool) "kimi remains after codex bound-actor filter" true
        (provider_cfg.kind = Llm_provider.Provider_config.Kimi_cli)
  | _ ->
      Alcotest.failf "expected only kimi_cli provider to remain, got %d"
        (List.length filtered)

let test_filter_candidate_providers_for_tool_support_keeps_codex_with_per_keeper_token
    () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_temp_masc_base_path "codex-bound-token" @@ fun () ->
  let base_path = Sys.getenv "MASC_BASE_PATH" in
  seed_raw_token base_path "keeper-sangsu-agent" "keeper-raw-token";
  let runtime_mcp_policy =
    Oas_worker_exec.public_mcp_runtime_policy_of_tool_names
      ~agent_name:"keeper-sangsu-agent" [ "masc_status"; "masc_claim_next" ]
  in
  let filtered =
    Masc_mcp.Oas_worker_named.filter_candidate_providers_for_tool_support
      ~keeper_name:"sangsu"
      ?runtime_mcp_policy
      ~require_tool_choice_support:true
      ~require_tool_support:true
      ~label:"tool_use_strict"
      [ make_codex_cli_provider_cfg (); make_kimi_cli_provider_cfg () ]
  in
  Alcotest.(check (list string))
    "codex remains when bearer auth can be sourced"
    [ "codex_cli:codex"; "kimi_cli:kimi-for-coding" ]
    (List.map Provider_tool_support.provider_debug_label filtered)

let test_filter_candidate_providers_for_tool_support_keeps_header_capable_cli_for_keeper_internal_tools
    () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_temp_masc_base_path "codex-header-capable-no-token" @@ fun _base_path ->
  let tools = [ make_named_noop_tool "keeper_bash" ] in
  let runtime_mcp_policy =
    Masc_mcp.Oas_worker_named.runtime_mcp_policy_for_tools
      ~keeper_name:"sangsu" tools
  in
  let filtered =
    Masc_mcp.Oas_worker_named.filter_candidate_providers_for_tool_support
      ~keeper_name:"sangsu"
      ?runtime_mcp_policy
      ~tools
      ~require_tool_choice_support:true
      ~require_tool_support:true
      ~label:"tool_use_strict"
      [
        make_claude_code_provider_cfg ();
        make_codex_cli_provider_cfg ();
        make_kimi_cli_provider_cfg ();
      ]
  in
  Alcotest.(check (list string)) "header-capable CLI providers remain"
    [ "claude_code:auto"; "kimi_cli:kimi-for-coding" ]
    (List.map Provider_tool_support.provider_debug_label filtered)

let test_filter_candidate_providers_for_tool_support_secondary_preserves_priority_slot
    () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_temp_masc_base_path "codex-secondary-priority" @@ fun () ->
  let tools = [ make_named_noop_tool "keeper_bash" ] in
  let runtime_mcp_policy =
    Masc_mcp.Oas_worker_named.runtime_mcp_policy_for_tools
      ~keeper_name:"sangsu" tools
  in
  let filtered =
    Masc_mcp.Oas_worker_named.filter_candidate_providers_for_tool_support
      ~keeper_name:"sangsu"
      ?runtime_mcp_policy
      ~tools
      ~require_tool_choice_support:true
      ~require_tool_support:true
      ~secondary_resolver:
        (fun provider_index provider_cfg ->
           if provider_index = 0
              && provider_cfg.kind = Llm_provider.Provider_config.Codex_cli
           then Some (make_claude_code_provider_cfg ())
           else None)
      ~label:"tool_use_strict"
      [ make_codex_cli_provider_cfg (); make_kimi_cli_provider_cfg () ]
  in
  Alcotest.(check (list string))
    "secondary replaces rejected primary in its original priority slot"
    [ "claude_code:auto"; "kimi_cli:kimi-for-coding" ]
    (List.map Provider_tool_support.provider_debug_label filtered)

let test_filter_candidate_providers_for_tool_support_secondary_uses_candidate_index
    () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_temp_masc_base_path "codex-secondary-index" @@ fun () ->
  let tools = [ make_named_noop_tool "keeper_bash" ] in
  let runtime_mcp_policy =
    Masc_mcp.Oas_worker_named.runtime_mcp_policy_for_tools
      ~keeper_name:"sangsu" tools
  in
  let filtered =
    Masc_mcp.Oas_worker_named.filter_candidate_providers_for_tool_support
      ~keeper_name:"sangsu"
      ?runtime_mcp_policy
      ~tools
      ~require_tool_choice_support:true
      ~require_tool_support:true
      ~secondary_resolver:
        (fun provider_index provider_cfg ->
           if provider_cfg.kind = Llm_provider.Provider_config.Codex_cli then
             Some
               (make_claude_code_provider_cfg
                  ~model_id:(Printf.sprintf "fallback-%d" provider_index)
                  ())
           else None)
      ~label:"tool_use_strict"
      [
        make_codex_cli_provider_cfg ~model_id:"same-primary" ();
        make_codex_cli_provider_cfg ~model_id:"same-primary" ();
      ]
  in
  Alcotest.(check (list string))
    "duplicate primary slots get their own secondary"
    [ "claude_code:fallback-0"; "claude_code:fallback-1" ]
    (List.map Provider_tool_support.provider_debug_label filtered)

(* RFC-0027 PR-9c: per-secondary accounting. Successful and failed
   dual-track swaps must label the [masc_fallback_triggered_total]
   counter with the secondary's [provider_kind] so dashboards can
   split CLI-vs-DirectAPI fallback volume. *)
let count_swap_metric ~detail =
  Prometheus.metric_value_or_zero
    Prometheus.metric_fallback_triggered
    ~labels:[ ("kind", "dual_track_swap"); ("detail", detail) ]
    ()

let test_dual_track_swap_emits_secondary_kind_label_on_success () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_temp_masc_base_path "codex-secondary-metric-success" @@ fun () ->
  let tools = [ make_named_noop_tool "keeper_bash" ] in
  let runtime_mcp_policy =
    Masc_mcp.Oas_worker_named.runtime_mcp_policy_for_tools
      ~keeper_name:"sangsu" tools
  in
  let before = count_swap_metric ~detail:"swapped:claude_code" in
  let _ =
    Masc_mcp.Oas_worker_named.filter_candidate_providers_for_tool_support
      ~keeper_name:"sangsu"
      ?runtime_mcp_policy
      ~tools
      ~require_tool_choice_support:true
      ~require_tool_support:true
      ~secondary_resolver:
        (fun _ provider_cfg ->
           if provider_cfg.kind = Llm_provider.Provider_config.Codex_cli
           then Some (make_claude_code_provider_cfg ())
           else None)
      ~label:"tool_use_strict"
      [ make_codex_cli_provider_cfg () ]
  in
  let after = count_swap_metric ~detail:"swapped:claude_code" in
  Alcotest.(check (float 0.0001))
    "successful swap bumps swapped:<secondary_kind>"
    (before +. 1.0) after

let test_dual_track_swap_emits_secondary_kind_label_on_rejection () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_temp_masc_base_path "codex-secondary-metric-rejection" @@ fun () ->
  let tools = [ make_named_noop_tool "keeper_bash" ] in
  let runtime_mcp_policy =
    Masc_mcp.Oas_worker_named.runtime_mcp_policy_for_tools
      ~keeper_name:"sangsu" tools
  in
  (* Rejected primary, secondary that *also* fails the gate (another
     codex_cli with bound-actor tools). Detail format is
     [rejected:<secondary_kind>:<rejection_reason_label>]. *)
  let detail = "rejected:codex_cli:codex_keeper_bound_actor_required" in
  let before = count_swap_metric ~detail in
  let _ =
    Masc_mcp.Oas_worker_named.filter_candidate_providers_for_tool_support
      ~keeper_name:"sangsu"
      ?runtime_mcp_policy
      ~tools
      ~require_tool_choice_support:true
      ~require_tool_support:true
      ~secondary_resolver:
        (fun _ provider_cfg ->
           if provider_cfg.kind = Llm_provider.Provider_config.Codex_cli
           then Some (make_codex_cli_provider_cfg ())
           else None)
      ~label:"tool_use_strict"
      [ make_codex_cli_provider_cfg () ]
  in
  let after = count_swap_metric ~detail in
  Alcotest.(check (float 0.0001))
    "doubly-rejected swap bumps rejected:<secondary_kind>:<reason>"
    (before +. 1.0) after

(* #10681: filter rejection diagnostics. When [filter_*] empties the
   cascade, the WARN log now lists each rejected provider with its
   classification — these tests pin the classifier to its 3-stage
   short-circuit so a regression in any check surfaces here instead
   of in production WARN spam.  *)
let test_classify_filter_rejection_codex_keeper_bound_actor () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_temp_masc_base_path "codex-classify-no-token" @@ fun _base_path ->
  let runtime_mcp_policy =
    Oas_worker_exec.public_mcp_runtime_policy_of_tool_names
      ~agent_name:"keeper-sangsu-agent" [ "masc_status"; "masc_claim_next" ]
  in
  (match runtime_mcp_policy with
   | Some policy ->
       Alcotest.(check (list string)) "runtime policy keeps requested tools"
         [ "masc_status"; "masc_claim_next" ] policy.allowed_tool_names;
       Alcotest.(check bool) "masc_claim_next requires actor binding" true
         (Oas_worker_exec.runtime_mcp_tool_requires_bound_actor "masc_claim_next")
   | None -> Alcotest.fail "expected public MCP runtime policy");
  let reason =
    Masc_mcp.Oas_worker_named.classify_filter_rejection
      ~keeper_name:"sangsu"
      ?runtime_mcp_policy
      ~require_tool_choice_support:true
      ~require_tool_support:true
      (make_codex_cli_provider_cfg ())
  in
  Alcotest.(check (option string))
    "codex_cli with bound-actor policy classified as keeper_bound_actor"
    (Some "codex_keeper_bound_actor_required")
    (Option.map
       Masc_mcp.Oas_worker_named.filter_rejection_reason_label reason)

let test_classify_filter_rejection_codex_keeper_bound_actor_passes_with_per_keeper_token
    () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_temp_masc_base_path "codex-classify-token" @@ fun () ->
  let base_path = Sys.getenv "MASC_BASE_PATH" in
  seed_raw_token base_path "keeper-sangsu-agent" "keeper-bearer-xyz";
  let tools = [ make_named_noop_tool "keeper_bash" ] in
  let runtime_mcp_policy =
    Masc_mcp.Oas_worker_named.runtime_mcp_policy_for_tools
      ~keeper_name:"sangsu" tools
  in
  let reason =
    Masc_mcp.Oas_worker_named.classify_filter_rejection
      ~keeper_name:"sangsu"
      ?runtime_mcp_policy
      ~tools
      ~require_tool_choice_support:true
      ~require_tool_support:true
      (make_codex_cli_provider_cfg ())
  in
  Alcotest.(check (option string))
    "codex_cli passes keeper-bound policy when per-keeper bearer exists"
    None
    (Option.map
       Masc_mcp.Oas_worker_named.filter_rejection_reason_label reason)

let test_classify_filter_rejection_passes_when_provider_supported () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "shared-codex-token" @@ fun () ->
  let runtime_mcp_policy =
    Oas_worker_exec.public_mcp_runtime_policy_of_tool_names
      ~agent_name:"keeper-sangsu-agent" [ "masc_status" ]
  in
  let reason =
    Masc_mcp.Oas_worker_named.classify_filter_rejection
      ~keeper_name:"sangsu"
      ?runtime_mcp_policy
      ~require_tool_choice_support:true
      ~require_tool_support:true
      (make_codex_cli_provider_cfg ())
  in
  Alcotest.(check bool)
    "codex_cli passing the filter classifies as None"
    true (reason = None)

let test_kimi_mcp_config_json_of_policy_filters_to_allowed_servers () =
  let policy =
    {
      Llm_provider.Llm_transport.empty_runtime_mcp_policy with
      servers =
        [
          Llm_provider.Llm_transport.Http_server
            {
              name = "masc";
              url = "http://127.0.0.1:8947/mcp";
              headers = [ ("Authorization", "Bearer token") ];
            };
          Llm_provider.Llm_transport.Http_server
            { name = "other"; url = "http://127.0.0.1:9999/mcp"; headers = [] };
        ];
      allowed_server_names = [ "masc" ];
      allowed_tool_names = [ "masc_status" ];
      strict = true;
      disable_builtin_tools = true;
    }
  in
  match Oas_worker_exec.kimi_mcp_config_json_of_policy policy with
  | None -> Alcotest.fail "expected kimi runtime MCP config JSON"
  | Some raw_json ->
      let open Yojson.Safe.Util in
      let json = Yojson.Safe.from_string raw_json in
      let mcp_servers = json |> member "mcpServers" in
      Alcotest.(check string) "masc url" "http://127.0.0.1:8947/mcp"
        (mcp_servers |> member "masc" |> member "url" |> to_string);
      Alcotest.(check string) "auth header preserved" "Bearer token"
        (mcp_servers
         |> member "masc"
         |> member "headers"
         |> member "Authorization"
         |> to_string);
      Alcotest.(check bool) "disallowed server omitted" true
        (match mcp_servers |> member "other" with `Null -> true | _ -> false)

let test_runtime_mcp_policy_with_masc_agent_name_upserts_header () =
  let policy =
    {
      Llm_provider.Llm_transport.empty_runtime_mcp_policy with
      servers =
        [
          Llm_provider.Llm_transport.Http_server
            {
              name = "masc";
              url = "http://127.0.0.1:8947/mcp";
              headers =
                [
                  ("Authorization", "Bearer token");
                  ("x-masc-agent-name", "stale-agent");
                ];
            };
          Llm_provider.Llm_transport.Http_server
            {
              name = "other";
              url = "http://127.0.0.1:9999/mcp";
              headers = [ ("Authorization", "Other token") ];
            };
        ];
      allowed_server_names = [ "masc"; "other" ];
      allowed_tool_names = [ "masc_status" ];
      strict = true;
      disable_builtin_tools = true;
    }
  in
  let updated =
    Oas_worker_exec.runtime_mcp_policy_with_masc_agent_name
      ~agent_name:"keeper-sangsu-agent" policy
  in
  let find_http_headers name =
    List.find_map
      (function
        | Llm_provider.Llm_transport.Http_server server
          when String.equal server.name name -> Some server.headers
        | _ -> None)
      updated.servers
  in
  match find_http_headers "masc", find_http_headers "other" with
  | Some masc_headers, Some other_headers ->
      Alcotest.(check (option string)) "masc header injected"
        (Some "keeper-sangsu-agent")
        (List.assoc_opt "x-masc-agent-name" masc_headers);
      Alcotest.(check (option string)) "keeper name injected"
        (Some "sangsu")
        (List.assoc_opt "x-masc-keeper-name" masc_headers);
      Alcotest.(check (option string)) "masc auth preserved"
        (Some "Bearer token")
        (List.assoc_opt "Authorization" masc_headers);
      Alcotest.(check (option string)) "other server unchanged" None
        (List.assoc_opt "x-masc-agent-name" other_headers)
  | _ -> Alcotest.fail "expected both masc and other HTTP servers"

let test_runtime_mcp_policy_with_masc_agent_name_prefers_internal_keeper_token () =
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" (fun () ->
      let policy =
        {
          Llm_provider.Llm_transport.empty_runtime_mcp_policy with
          servers =
            [
              Llm_provider.Llm_transport.Http_server
                { name = "masc"; url = "http://127.0.0.1:8947/mcp"; headers = [] };
            ];
          allowed_server_names = [ "masc" ];
          allowed_tool_names = [ "masc_status" ];
          strict = true;
          disable_builtin_tools = true;
        }
      in
      let updated =
        Oas_worker_exec.runtime_mcp_policy_with_masc_agent_name
          ~agent_name:"keeper-sangsu-agent" policy
      in
      match updated.servers with
      | [ Llm_provider.Llm_transport.Http_server server ] ->
          Alcotest.(check (option string)) "internal token injected"
            (Some "internal-keeper-token")
            (List.assoc_opt "x-masc-internal-token" server.headers);
          Alcotest.(check (option string)) "keeper name injected"
            (Some "sangsu")
            (List.assoc_opt "x-masc-keeper-name" server.headers)
      | _ -> Alcotest.fail "expected single masc runtime server")

let test_public_mcp_runtime_policy_binds_keeper_internal_headers () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  with_env "MASC_INTERNAL_MCP_TOKEN" "internal-keeper-token" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "ambient-bearer-token" @@ fun () ->
  match
    Oas_worker_exec.public_mcp_runtime_policy_of_tool_names
      ~agent_name:"keeper-sangsu-agent" [ "masc_status" ]
  with
  | Some policy -> (
      match policy.servers with
      | [ Llm_provider.Llm_transport.Http_server server ] ->
          Alcotest.(check (option string)) "internal token injected"
            (Some "internal-keeper-token")
            (List.assoc_opt "x-masc-internal-token" server.headers);
          Alcotest.(check (option string)) "keeper name injected"
            (Some "sangsu")
            (List.assoc_opt "x-masc-keeper-name" server.headers);
          Alcotest.(check (option string)) "agent name injected"
            (Some "keeper-sangsu-agent")
            (List.assoc_opt "x-masc-agent-name" server.headers);
          Alcotest.(check (option string)) "ambient bearer not mixed with internal"
            None
            (List.assoc_opt "Authorization" server.headers)
      | _ -> Alcotest.fail "expected single masc runtime server")
  | None -> Alcotest.fail "expected public MCP runtime policy"

let test_runtime_mcp_policy_for_provider_codex_cli_preserves_identity_header () =
  (* PR-F (Plan v3 Leak 2a): Codex CLI runtime MCP rejects most
     per-request HTTP headers, but the masc HTTP server still needs the
     keeper's identity to avoid collapsing to find_credential_by_token's
     alphabetical first-match (#9786 root cause).  This regression test
     pins the new behavior:
     - x-masc-agent-name MUST be preserved (pre-PR-F was None).
     - Authorization is still stripped for Codex CLI compatibility.
     - openai-compat path is unchanged. *)
  let policy =
    {
      Llm_provider.Llm_transport.empty_runtime_mcp_policy with
      servers =
        [
          Llm_provider.Llm_transport.Http_server
            { name = "masc"; url = "http://127.0.0.1:8947/mcp"; headers = [] };
        ];
      allowed_server_names = [ "masc" ];
      allowed_tool_names = [ "masc_status" ];
      strict = true;
      disable_builtin_tools = true;
    }
  in
  let find_masc_headers policy_opt =
    match policy_opt with
    | None -> Alcotest.fail "expected runtime MCP policy"
    | Some (policy : Llm_provider.Llm_transport.runtime_mcp_policy) ->
        List.find_map
          (function
            | Llm_provider.Llm_transport.Http_server server
              when String.equal server.name "masc" -> Some server.headers
            | _ -> None)
          policy.servers
  in
  let codex_headers =
    find_masc_headers
      (Oas_worker_exec.runtime_mcp_policy_for_provider
         ~provider_cfg:(make_codex_cli_provider_cfg ())
         ~agent_name:"keeper-sangsu-agent"
         (Some policy))
  in
  let openai_headers =
    find_masc_headers
      (Oas_worker_exec.runtime_mcp_policy_for_provider
         ~provider_cfg:(make_openai_compat_provider_cfg ())
         ~agent_name:"keeper-sangsu-agent"
         (Some policy))
  in
  match codex_headers, openai_headers with
  | Some codex_headers, Some openai_headers ->
      Alcotest.(check (option string))
        "codex_cli now preserves agent identity header (PR-F)"
        (Some "keeper-sangsu-agent")
        (List.assoc_opt "x-masc-agent-name" codex_headers);
      Alcotest.(check (option string))
        "codex_cli also preserves keeper-name header (PR-F)"
        (Some "sangsu")
        (List.assoc_opt "x-masc-keeper-name" codex_headers);
      Alcotest.(check (option string))
        "codex_cli still strips bearer/auth header"
        None
        (List.assoc_opt "Authorization" codex_headers);
      Alcotest.(check (option string)) "openai_compat still injects agent header"
        (Some "keeper-sangsu-agent")
        (List.assoc_opt "x-masc-agent-name" openai_headers)
  | _ -> Alcotest.fail "expected masc runtime server headers"

let test_runtime_mcp_policy_for_provider_codex_cli_no_agent_strips_all () =
  (* PR-F regression: when the caller has no agent_name to inject,
     fall back to the legacy strip-all behavior so existing
     ambient-env auth flows remain unaffected. *)
  let policy =
    {
      Llm_provider.Llm_transport.empty_runtime_mcp_policy with
      servers =
        [
          Llm_provider.Llm_transport.Http_server
            { name = "masc"; url = "http://127.0.0.1:8947/mcp";
              headers = [ ("Authorization", "Bearer xxx") ] };
        ];
      allowed_server_names = [ "masc" ];
      allowed_tool_names = [ "masc_status" ];
      strict = true;
      disable_builtin_tools = true;
    }
  in
  let find_masc_headers policy_opt =
    match policy_opt with
    | None -> Alcotest.fail "expected runtime MCP policy"
    | Some (policy : Llm_provider.Llm_transport.runtime_mcp_policy) ->
        List.find_map
          (function
            | Llm_provider.Llm_transport.Http_server server
              when String.equal server.name "masc" -> Some server.headers
            | _ -> None)
          policy.servers
  in
  let result =
    find_masc_headers
      (Oas_worker_exec.runtime_mcp_policy_for_provider
         ~provider_cfg:(make_codex_cli_provider_cfg ())
         ~agent_name:""
         (Some policy))
  in
  match result with
  | Some headers ->
      Alcotest.(check int) "no agent_name -> all headers stripped" 0
        (List.length headers)
  | None -> Alcotest.fail "expected masc runtime server headers"

let test_kimi_cli_runtime_mcp_jsons_include_request_policy () =
  let policy =
    {
      Llm_provider.Llm_transport.empty_runtime_mcp_policy with
      servers =
        [
          Llm_provider.Llm_transport.Http_server
            { name = "masc"; url = "http://127.0.0.1:8947/mcp"; headers = [] };
        ];
      allowed_server_names = [ "masc" ];
      allowed_tool_names = [ "masc_status" ];
      strict = true;
      disable_builtin_tools = true;
    }
  in
  let merged =
    Oas_worker_exec.kimi_cli_runtime_mcp_jsons ~base:[] (Some policy)
  in
  Alcotest.(check int) "request policy contributes one kimi mcp config" 1
    (List.length merged);
  Alcotest.(check bool) "merged config keeps masc MCP url" true
    (List.exists
       (contains_substring ~needle:"http://127.0.0.1:8947/mcp")
       merged)

let test_kimi_cli_build_args_include_runtime_mcp_config () =
  let policy =
    {
      Llm_provider.Llm_transport.empty_runtime_mcp_policy with
      servers =
        [
          Llm_provider.Llm_transport.Http_server
            { name = "masc"; url = "http://127.0.0.1:8947/mcp"; headers = [] };
        ];
      allowed_server_names = [ "masc" ];
      allowed_tool_names = [ "masc_status" ];
      strict = true;
      disable_builtin_tools = true;
    }
  in
  let mcp_config_json =
    Oas_worker_exec.kimi_cli_runtime_mcp_jsons ~base:[] (Some policy)
  in
  let argv =
    Oas_worker_exec.Kimi_cli_transport_local.build_args
      ~config:Oas_worker_exec.Kimi_cli_transport_local.default_config
      ~req_config:(make_kimi_cli_provider_cfg ())
      ~mcp_config_json
      ~prompt:"hello"
  in
  Alcotest.(check bool) "mcp-config flag present" true
    (List.mem "--mcp-config" argv);
  Alcotest.(check bool) "mcp-config payload includes masc MCP url" true
    (List.exists
       (contains_substring ~needle:"http://127.0.0.1:8947/mcp")
       argv)

let test_kimi_cli_build_args_uses_stdin_for_large_prompt () =
  let long_prompt = String.make (20 * 1024) 'x' in
  let argv =
    Oas_worker_exec.Kimi_cli_transport_local.build_args
      ~config:Oas_worker_exec.Kimi_cli_transport_local.default_config
      ~req_config:(make_kimi_cli_provider_cfg ())
      ~mcp_config_json:[] ~prompt:long_prompt
  in
  Alcotest.(check bool) "large prompt is omitted from argv" false
    (List.mem long_prompt argv);
  Alcotest.(check bool) "large prompt does not use -p" false
    (List.mem "-p" argv)

let test_kimi_cli_build_args_uses_stdin_for_non_ascii_prompt () =
  let prompt = "한글 prompt" in
  let argv =
    Oas_worker_exec.Kimi_cli_transport_local.build_args
      ~config:Oas_worker_exec.Kimi_cli_transport_local.default_config
      ~req_config:(make_kimi_cli_provider_cfg ())
      ~mcp_config_json:[] ~prompt
  in
  Alcotest.(check bool) "non-ASCII prompt is omitted from argv" false
    (List.mem prompt argv);
  Alcotest.(check bool) "non-ASCII prompt does not use -p" false
    (List.mem "-p" argv)

let test_kimi_cli_build_args_sanitizes_broken_utf8_prompt () =
  let prompt = "prefix\x80suffix" in
  let argv =
    Oas_worker_exec.Kimi_cli_transport_local.build_args
      ~config:Oas_worker_exec.Kimi_cli_transport_local.default_config
      ~req_config:(make_kimi_cli_provider_cfg ())
      ~mcp_config_json:[] ~prompt
  in
  Alcotest.(check bool) "broken UTF-8 prompt omitted" false
    (List.mem prompt argv);
  Alcotest.(check bool) "sanitized non-ASCII replacement stays off argv" false
    (List.mem "-p" argv)

let test_kimi_cli_model_for_provider_keeps_transport_default_on_auto () =
  let provider_cfg = make_kimi_cli_provider_cfg () in
  Alcotest.(check (option string)) "auto uses transport default"
    Llm_provider.Transport_kimi_cli.default_config.model
    (Oas_worker_exec.kimi_cli_model_for_provider provider_cfg)

let test_kimi_cli_model_for_provider_keeps_explicit_model () =
  let provider_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Kimi_cli
      ~model_id:"kimi-k2.5"
      ~base_url:"" ()
  in
  Alcotest.(check (option string)) "explicit model preserved"
    (Some "kimi-k2.5")
    (Oas_worker_exec.kimi_cli_model_for_provider provider_cfg)

let test_kimi_cli_config_uses_oas_context_ssot () =
  let model_id = "kimi-for-coding" in
  let provider_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Kimi_cli
      ~model_id
      ~base_url:""
      ~api_key:"test-key" ()
  in
  match Oas_worker_exec.kimi_cli_config_json_for_provider provider_cfg with
  | None -> Alcotest.fail "expected kimi_cli config json"
  | Some raw ->
      let json = _parse_json raw in
      let actual =
        Yojson.Safe.Util.(
          json |> member "models" |> member model_id
          |> member "max_context_size" |> to_int)
      in
      let expected = Cascade_config.resolve_kimi_max_context model_id in
      Alcotest.(check int) "max_context_size from OAS capabilities SSOT"
        expected actual

let test_kimi_cli_should_log_stderr_line_filters_resume_noise () =
  let should_log =
    Oas_worker_exec.Kimi_cli_transport_local.should_log_stderr_line
  in
  Alcotest.(check bool) "blank stderr line suppressed" false (should_log "");
  Alcotest.(check bool) "whitespace stderr line suppressed" false
    (should_log "   ");
  Alcotest.(check bool) "resume hint suppressed" false
    (should_log "To resume this session: kimi -r ff37febe");
  Alcotest.(check bool) "case-insensitive resume hint suppressed" false
    (should_log "  TO RESUME THIS SESSION: kimi -r ff37febe");
  Alcotest.(check bool) "unexpected stderr remains visible" true
    (should_log "fatal: kimi auth missing");
  Alcotest.(check bool) "other stderr guidance remains visible" true
    (should_log "warning: upstream endpoint is slow")

let test_kimi_cli_classify_cli_error_redacts_resumable_session_detail () =
  let raw_message =
    "kimi exited with code 75: \nTo resume this session: kimi -r ff37febe-2adb-4ac6-9dc6-cae23e672fbc"
  in
  let canonical_detail =
    Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail_of_text
      raw_message
  in
  match
    Oas_worker_exec.Kimi_cli_transport_local.classify_cli_error
      (Error
         (Llm_provider.Http_client.NetworkError
            {
              message = raw_message;
              kind = Llm_provider.Http_client.Unknown;
            }))
  with
  | Error (Llm_provider.Http_client.AcceptRejected { reason }) ->
      Alcotest.(check string) "canonical detail" canonical_detail reason;
      Alcotest.(check bool) "raw resume hint removed" false
        (contains_substring ~needle:"To resume this session:" reason);
      Alcotest.(check bool) "raw session id removed" false
        (contains_substring ~needle:"ff37febe-2adb-4ac6-9dc6-cae23e672fbc" reason)
  | _ -> Alcotest.fail "expected resumable session to map to AcceptRejected"

let test_kimi_cli_classify_cli_error_treats_exit_1_resume_hint_as_resumable () =
  let raw_message =
    "kimi exited with code 1: \nTo resume this session: kimi -r 5de0f199-6bd7-4509-bfa6-3308e0ebd97f"
  in
  let canonical_detail =
    Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail_of_text
      raw_message
  in
  Alcotest.(check bool) "exit 1 resume hint is resumable" true
    (Oas_worker_exec.Kimi_cli_transport_local.text_looks_like_resumable_session
       raw_message);
  Alcotest.(check (option int)) "exit code preserved" (Some 1)
    (Oas_worker_exec.Kimi_cli_transport_local.resumable_session_exit_code_of_text
       raw_message);
  match
    Oas_worker_exec.Kimi_cli_transport_local.classify_cli_error
      (Error
         (Llm_provider.Http_client.NetworkError
            {
              message = raw_message;
              kind = Llm_provider.Http_client.Unknown;
            }))
  with
  | Error (Llm_provider.Http_client.AcceptRejected { reason }) ->
      Alcotest.(check string) "canonical detail" canonical_detail reason;
      Alcotest.(check bool) "does not claim exit 75" false
        (contains_substring ~needle:"exit 75" reason);
      Alcotest.(check bool) "raw resume hint removed" false
        (contains_substring ~needle:"To resume this session:" reason);
      Alcotest.(check bool) "raw session id removed" false
        (contains_substring ~needle:"5de0f199-6bd7-4509-bfa6-3308e0ebd97f" reason)
  | _ -> Alcotest.fail "expected exit 1 resume hint to map to resumable session"

let test_kimi_cli_resumable_invalid_request_reclassifies_as_structured () =
  let raw_message =
    "kimi exited with code 1: \nTo resume this session: kimi -r 5de0f199-6bd7-4509-bfa6-3308e0ebd97f"
  in
  let detail =
    Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail_of_text
      raw_message
  in
  let sdk_error =
    Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest { message = detail })
  in
  match
    Oas_worker_named.sdk_error_to_resumable_cli_session
      ~cascade_name:(internal_cascade_name "kimi_cli_keeper") sdk_error
  with
  | Some structured -> (
      match Oas_worker_named.classify_masc_internal_error structured with
      | Some
          (Oas_worker_named.Resumable_cli_session
             { cascade_name; detail = structured_detail; exit_code }) ->
          Alcotest.(check string) "cascade" "kimi_cli_keeper"
            (internal_cascade_name_to_string cascade_name);
          Alcotest.(check string) "detail" detail structured_detail;
          Alcotest.(check (option int)) "exit code" (Some 1) exit_code
      | _ -> Alcotest.fail "expected structured resumable CLI session")
  | None -> Alcotest.fail "expected InvalidRequest detail to reclassify"

let test_kimi_cli_classify_cli_error_keeps_exit_1_with_error_as_reject () =
  let raw_message =
    "kimi exited with code 1: \nAuthentication failed\nTo resume this session: kimi -r ff37febe"
  in
  Alcotest.(check bool) "exit 1 with real stderr is not resumable" false
    (Oas_worker_exec.Kimi_cli_transport_local.text_looks_like_resumable_session
       raw_message);
  match
    Oas_worker_exec.Kimi_cli_transport_local.classify_cli_error
      (Error
         (Llm_provider.Http_client.NetworkError
            {
              message = raw_message;
              kind = Llm_provider.Http_client.Unknown;
            }))
  with
  | Error (Llm_provider.Http_client.AcceptRejected { reason }) ->
      Alcotest.(check bool) "reject reason preserved" true
        (contains_substring ~needle:"kimi_cli rejected the request (exit 1)"
           reason);
      Alcotest.(check bool) "stderr detail preserved" true
        (contains_substring ~needle:"Authentication failed" reason)
  | _ -> Alcotest.fail "expected exit 1 with real stderr to stay rejected"

let test_kimi_cli_classify_cli_error_labels_process_title_unicode_crash () =
  let raw_message =
    "kimi exited with code 1: Traceback ... \
     setproctitle/__init__.py:57 in <module> getproctitle() \
     UnicodeDecodeError: 'utf-8' codec can't decode byte 0xef"
  in
  match
    Oas_worker_exec.Kimi_cli_transport_local.classify_cli_error
      (Error
         (Llm_provider.Http_client.NetworkError
            {
              message = raw_message;
              kind = Llm_provider.Http_client.Unknown;
            }))
  with
  | Error (Llm_provider.Http_client.AcceptRejected { reason }) ->
      Alcotest.(check bool) "startup crash marker" true
        (contains_substring ~needle:"startup crash" reason);
      Alcotest.(check bool) "unicode crash detail preserved" true
        (contains_substring ~needle:"UnicodeDecodeError" reason);
      Alcotest.(check bool) "not framed as auth/config" false
        (contains_substring ~needle:"auth/config/model" reason)
  | _ -> Alcotest.fail "expected setproctitle UnicodeDecodeError to map to AcceptRejected"

let test_sdk_error_terminal_provider_runtime_detects_kimi_unicode_crash () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest
         {
           message =
             "kimi_cli rejected the request (exit 1): startup crash: \
              UnicodeDecodeError: 'utf-8' codec can't decode byte 0xef";
         })
  in
  Alcotest.(check bool)
    "Kimi startup UnicodeDecodeError is terminal provider runtime" true
    (Oas_worker_named.sdk_error_is_terminal_provider_runtime_failure err)

let test_sdk_error_terminal_provider_runtime_detects_jsonrpc_sse_parse_storm () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest
         {
           message =
             "Error parsing SSE message: pydantic ValidationError for \
              JSONRPCMessage: invalid JSON EOF";
         })
  in
  Alcotest.(check bool)
    "JSON-RPC SSE parse storm is terminal provider runtime" true
    (Oas_worker_named.sdk_error_is_terminal_provider_runtime_failure err)

let test_codex_cli_prompt_preflight_uses_pipeline_context_window_fallback () =
  let provider_cfg = make_codex_cli_provider_cfg () in
  let config =
    Oas_worker_exec.default_config
      ~name:"codex-preflight"
      ~provider_cfg
      ~system_prompt:"system"
      ~tools:[]
  in
  let huge_goal = String.make 600_000 'a' in
  match Oas_worker_named.codex_cli_prompt_preflight ~config ~goal:huge_goal with
  | Some preflight ->
      Alcotest.(check bool) "argv limit hit" true preflight.hits_argv_limit;
      Alcotest.(check bool) "context limit hit" true preflight.hits_context_window;
      Alcotest.(check int) "fallback context window"
        Masc_mcp.Cascade_runtime.fallback_context_window
        preflight.context_window_tokens;
      Alcotest.(check bool) "retry limit reduced" true
        (preflight.retry_limit_tokens < preflight.prompt_tokens)
  | None -> Alcotest.fail "expected codex preflight overflow"

let test_codex_cli_prompt_preflight_scales_retry_limit_for_argv_only_overflow () =
  let provider_cfg = make_codex_cli_provider_cfg ~model_id:"gpt-4.1" () in
  let config =
    Oas_worker_exec.default_config
      ~name:"codex-preflight"
      ~provider_cfg
      ~system_prompt:"system"
      ~tools:[]
  in
  let huge_goal = String.make 600_000 'a' in
  match Oas_worker_named.codex_cli_prompt_preflight ~config ~goal:huge_goal with
  | Some preflight ->
      Alcotest.(check bool) "argv limit hit" true preflight.hits_argv_limit;
      Alcotest.(check bool) "context limit not hit" false preflight.hits_context_window;
      Alcotest.(check bool) "gpt-4.1 context window preserved" true
        (preflight.context_window_tokens >= 1_000_000);
      Alcotest.(check bool) "retry limit scaled below prompt tokens" true
        (preflight.retry_limit_tokens < preflight.prompt_tokens);
      Alcotest.(check bool) "retry limit below full context window" true
        (preflight.retry_limit_tokens < preflight.context_window_tokens)
  | None -> Alcotest.fail "expected argv-only codex preflight overflow"

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
      ~hooks:Agent_sdk.Hooks.empty
      ~raw_trace
      ~heartbeat_callbacks:[]
      ()
  with
  | Ok agent ->
      let policy = (Agent_sdk.Agent.options agent).tool_retry_policy in
      check_policy_matches_default_internal "worker build_agent" policy;
      Agent_sdk.Agent.close agent
  | Error err -> Alcotest.fail err

let test_build_resume_config_propagates_retry_policy () =
  with_raw_trace "worker_resume_config_retry" @@ fun raw_trace ->
  let provider = make_local_provider () in
  let (config, options) =
    Worker_container.build_resume_config
      ~worker_name:"resume-worker"
      ~provider
      ~model_id:"mock-model"
      ~system_prompt:"resume system"
      ~tools:[ make_noop_tool () ]
      ~max_turns:7
      ~thinking_enabled:true
      ~hooks:Agent_sdk.Hooks.empty
      ~raw_trace
      ~tool_retry_policy:Agent_sdk.Tool_retry_policy.default_internal
      ()
  in
  Alcotest.(check (option (float 0.000001))) "resume config omits min_p" None config.min_p;
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
    let provider : Agent_sdk.Provider.config =
      {
        provider = Agent_sdk.Provider.Local { base_url = url };
        model_id = "mock-model";
        api_key_env = "";
      }
    in
    let time_tool =
      Agent_sdk.Tool.create
        ~name:"get_time"
        ~description:"Get current time"
        ~parameters:
          [
            {
              name = "timezone";
              param_type = Agent_sdk.Types.String;
              description = "tz";
              required = true;
            };
          ]
        (fun _input -> Ok Agent_sdk.Types.{ content = "12:00 UTC" })
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
        ~hooks:Agent_sdk.Hooks.empty
        ~raw_trace
        ~heartbeat_callbacks:[]
        ()
    with
    | Ok agent ->
        Fun.protect
          ~finally:(fun () -> Agent_sdk.Agent.close agent)
          (fun () ->
            match Agent_sdk.Agent.run ~sw agent "what time is it?" with
            | Ok resp ->
                let text =
                  resp.Agent_sdk.Types.content
                  |> List.filter_map (function Agent_sdk.Types.Text s -> Some s | _ -> None)
                  |> String.concat ""
                in
                Alcotest.(check string) "final text after retry"
                  "The time is 12:00 UTC" text;
                Eio.Switch.fail sw Exit
            | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err))
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
    let provider : Agent_sdk.Provider.config =
      {
        provider = Agent_sdk.Provider.Local { base_url = url };
        model_id = "mock-model";
        api_key_env = "";
      }
    in
    let time_tool =
      Agent_sdk.Tool.create
        ~name:"get_time"
        ~description:"Get current time"
        ~parameters:
          [
            {
              name = "timezone";
              param_type = Agent_sdk.Types.String;
              description = "tz";
              required = true;
            };
          ]
        (fun _input -> Ok Agent_sdk.Types.{ content = "12:00 UTC" })
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
        ~hooks:Agent_sdk.Hooks.empty
        ~raw_trace
        ~heartbeat_callbacks:[]
        ()
    with
    | Ok agent ->
        Fun.protect
          ~finally:(fun () -> Agent_sdk.Agent.close agent)
          (fun () ->
            match Agent_sdk.Agent.run ~sw agent "what time is it?" with
            | Ok _ -> Alcotest.fail "expected retry exhaustion error"
            | Error
                (Agent_sdk.Error.Agent
                  (Agent_sdk.Error.ToolRetryExhausted { attempts; limit; detail })) ->
                Alcotest.(check int) "default_internal attempts" 2 attempts;
                Alcotest.(check int) "default_internal limit" 2 limit;
                Alcotest.(check bool) "detail mentions tool" true
                  (contains_substring ~needle:"get_time" detail);
                Eio.Switch.fail sw Exit
            | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err))
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
    let noop_tool = make_noop_tool () in
    let base_config =
      Oas_worker_exec.default_config
        ~name:"oas-worker-exit-condition"
        ~provider_cfg:
          (Llm_provider.Provider_config.make
             ~kind:Llm_provider.Provider_config.OpenAI_compat
             ~model_id:"mock-model"
             ~base_url:url
             ())
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
    | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)
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
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String trace_id);
          ("cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name);
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
    response_format = Agent_sdk.Types.Off;
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
      metadata = [];
  }

let tool_use_msg ?(id = "tool-1") ?(name = "keeper_fs_read") input
    : Agent_sdk.Types.message =
  {
    Agent_sdk.Types.role = Agent_sdk.Types.Assistant;
    content =
      [ Agent_sdk.Types.ToolUse { id; name; input } ];
    name = None;
    tool_call_id = None;
      metadata = [];
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
              | Sdk_other_error d -> "sdk_other:" ^ d
              | Not_found -> "not_found"))))

let test_keeper_checkpoint_store_writes_oas_history () =
  let base_dir = temp_dir "keeper_oas_history_store" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Fs_compat.clear_fs ();
      let session_dir = Filename.concat base_dir "trace-history" in
      let checkpoint1 =
        make_oas_checkpoint ~session_id:"trace-history"
          ~messages:[Agent_sdk.Types.user_msg "first"]
          ~created_at:1711234500.0 ()
      in
      let checkpoint2 =
        make_oas_checkpoint ~session_id:"trace-history"
          ~messages:[Agent_sdk.Types.user_msg "second"]
          ~created_at:1711234560.0 ()
      in
      (match Keeper_checkpoint_store.save_oas ~session_dir checkpoint1 with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Printf.sprintf "save_oas #1 failed: %s" e));
      (match Keeper_checkpoint_store.save_oas ~session_dir checkpoint2 with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Printf.sprintf "save_oas #2 failed: %s" e));
      let history_files =
        Keeper_checkpoint_store.list_oas_history_files ~session_dir
      in
      Alcotest.(check int) "history file count" 2 (List.length history_files);
      let latest_snapshot_id =
        match history_files with
        | latest :: _ -> latest
        | [] -> Alcotest.fail "expected OAS snapshot history file"
      in
      let canonical_stat =
        Unix.stat
          (Keeper_checkpoint_store.oas_checkpoint_path
             ~session_dir ~session_id:"trace-history")
      in
      let latest_snapshot_stat =
        Unix.stat
          (Keeper_checkpoint_store.oas_history_path
             ~session_dir ~snapshot_id:latest_snapshot_id)
      in
      Alcotest.(check int) "latest history shares canonical device"
        canonical_stat.st_dev latest_snapshot_stat.st_dev;
      Alcotest.(check int) "latest history hardlinks canonical checkpoint"
        canonical_stat.st_ino latest_snapshot_stat.st_ino;
      match
        Keeper_checkpoint_store.load_oas_history_file
          ~session_dir ~snapshot_id:latest_snapshot_id
      with
      | Ok loaded ->
          Alcotest.(check (float 0.000001)) "history created_at preserved"
            checkpoint2.created_at
            loaded.created_at;
          Alcotest.(check string) "latest history message" "second"
            (Agent_sdk.Types.text_of_message (List.hd loaded.messages))
      | Error _ -> Alcotest.fail "expected OAS history checkpoint load to succeed")

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
            "oas system" (ctx_system_prompt loaded);
          Alcotest.(check int) "max_tokens from live primary context" 1024
            (Keeper_exec_context.max_tokens_of_context loaded);
          Alcotest.(check string) "loaded OAS message" "oas"
            (Agent_sdk.Types.text_of_message (List.hd (ctx_messages loaded)))
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
            (ctx_system_prompt loaded);
          Alcotest.(check string) "legacy message restored" "legacy-only"
            (Agent_sdk.Types.text_of_message (List.hd (ctx_messages loaded)))
      | None -> Alcotest.fail "expected legacy fallback context")

let test_keeper_checkpoint_legacy_roundtrip_preserves_tool_pairs () =
  let base_dir = temp_dir "keeper_legacy_tool_pair_roundtrip" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let trace_id = "trace-legacy-tool-pair" in
      let session =
        Keeper_exec_context.create_session ~session_id:trace_id ~base_dir
      in
      let tool_id = "call_legacy_pair" in
      let legacy_ctx =
        Keeper_exec_context.create ~system_prompt:"legacy tool history" ~max_tokens:4096
        |> fun ctx ->
        Keeper_exec_context.append_many ctx
          [
            Agent_sdk.Types.user_msg "read the file";
            tool_use_msg ~id:tool_id (`Assoc [ ("path", `String "README.md") ]);
            tool_result_msg ~id:tool_id "contents";
            Agent_sdk.Types.assistant_msg "done";
          ]
      in
      ignore (Keeper_exec_context.save_checkpoint session legacy_ctx ~generation:2);
      let (_session, loaded_opt) =
        Keeper_exec_context.load_context_from_checkpoint
          ~max_checkpoint_messages:120
          ~trace_id
          ~primary_model_max_tokens:1024 ~base_dir
      in
      match loaded_opt with
      | None -> Alcotest.fail "expected legacy structured roundtrip context"
      | Some loaded ->
          Alcotest.(check int) "all messages restored" 4
            (List.length (ctx_messages loaded));
          (match List.nth (ctx_messages loaded) 1 with
           | { Agent_sdk.Types.role = Agent_sdk.Types.Assistant;
               content =
                 [ Agent_sdk.Types.ToolUse { id; name; input } ];
               _ } ->
               Alcotest.(check string) "tool use id preserved" tool_id id;
               Alcotest.(check string) "tool use name preserved"
                 "keeper_fs_read" name;
               Alcotest.(check string) "tool use input preserved"
                 {|{"path":"README.md"}|}
                 (Yojson.Safe.to_string input)
           | _ -> Alcotest.fail "expected assistant tool_use after roundtrip");
          (match List.nth (ctx_messages loaded) 2 with
           | { Agent_sdk.Types.role = Agent_sdk.Types.Tool;
               content =
                 [ Agent_sdk.Types.ToolResult { tool_use_id; content; _ } ];
               _ } ->
               Alcotest.(check string) "tool result id preserved" tool_id
                 tool_use_id;
               Alcotest.(check string) "tool result content preserved"
                 "contents" content
           | _ -> Alcotest.fail "expected tool result after roundtrip"))

let test_keeper_checkpoint_legacy_old_tool_messages_degrade_to_text () =
  let json =
    `Assoc
      [
        ("role", `String "tool");
        ("content", `String "legacy tool output");
        ("tool_call_id", `String "call_old");
      ]
  in
  match Masc_mcp.Keeper_exec_context.message_of_json json with
  | { Agent_sdk.Types.role = Agent_sdk.Types.Tool;
      content = [ Agent_sdk.Types.Text text ];
      _ } ->
      Alcotest.(check string) "legacy tool text preserved"
        "legacy tool output" text
  | _ -> Alcotest.fail "expected legacy tool message to degrade to plain text"

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
            (ctx_system_prompt loaded);
          Alcotest.(check string) "newer legacy message restored" "new-legacy"
            (Agent_sdk.Types.text_of_message (List.hd (ctx_messages loaded)))
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
        Keeper_exec_context.create_session ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~base_dir
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
        Keeper_exec_context.maybe_rollover_oas_handoff
          ~on_started:(fun () -> ())
          ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:100
          ~current_turn_overflow_blocker:None
          ~checkpoint:(Some checkpoint)
      in
      Alcotest.(check int) "generation incremented" 1
        rollover.updated_meta.runtime.generation;
      Alcotest.(check bool) "trace rotated" true
        (rollover.updated_meta.runtime.trace_id <> meta.runtime.trace_id);
      Alcotest.(check bool) "trace history contains previous trace" true
        (List.mem (Keeper_id.Trace_id.to_string meta.runtime.trace_id) rollover.updated_meta.runtime.trace_history);
      Alcotest.(check bool) "handoff json present" true
        (Option.is_some rollover.handoff_json);
      let new_session =
        Keeper_exec_context.create_session
          ~session_id:(Keeper_id.Trace_id.to_string rollover.updated_meta.runtime.trace_id)
          ~base_dir
      in
      match
        Keeper_checkpoint_store.load_oas ~session_dir:new_session.session_dir
          ~session_id:(Keeper_id.Trace_id.to_string rollover.updated_meta.runtime.trace_id)
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
        Keeper_exec_context.create_session ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~base_dir
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
        Keeper_exec_context.maybe_rollover_oas_handoff
          ~on_started:(fun () -> ())
          ~base_dir ~meta
          ~model:"llama:auto"
          ~primary_model_max_tokens:100
          ~current_turn_overflow_blocker:None
          ~checkpoint:(Some checkpoint)
      in
      Alcotest.(check string) "trace unchanged" (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
        (Keeper_id.Trace_id.to_string rollover.updated_meta.runtime.trace_id);
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
        Keeper_exec_context.create_session ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~base_dir
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
        Keeper_exec_context.create_session ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~base_dir
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
        Keeper_exec_context.create_session ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~base_dir
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
        Keeper_exec_context.create_session ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~base_dir
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
          Alcotest.(check int) "max tokens clamped" 512
            (Keeper_exec_context.max_tokens_of_context recovered_ctx))

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
              (List.length (ctx_messages ctx));
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
             (List.length (ctx_messages imm))
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
            (List.length (ctx_messages final));
          Alcotest.(check string) "first message preserved" "turn 1 user"
            (Agent_sdk.Types.text_of_message (List.nth (ctx_messages final) 0));
          Alcotest.(check string) "last message is turn 2 reply" "turn 2 reply"
            (Agent_sdk.Types.text_of_message (List.nth (ctx_messages final) 3))
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
            (List.length (ctx_messages loaded) > 0);
          Alcotest.(check int) "all 3 messages restored" 3
            (List.length (ctx_messages loaded));
          Alcotest.(check string) "system prompt restored" "restart test"
            (ctx_system_prompt loaded)
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
      metadata = [];
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
  let messages : Agent_sdk.Types.message list =
    [ { Agent_sdk.Types.role = Agent_sdk.Types.User;
        content = [ Agent_sdk.Types.Text "hello" ];
        name = None; tool_call_id = None; metadata = [] } ]
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
(* P0: Circuit-breaker fallback at run_named boundary               *)
(* ================================================================ *)

(** P0 regression: when the first provider in a two-provider cascade has
    3 consecutive failures (OPEN / cooldown), [run_named] must skip it
    without spending a request, then attempt the second (healthy) provider
    and succeed.

    Invariants pinned by this test:
    1. First provider remains OPEN and receives zero HTTP requests.
    2. Second provider is attempted and returns the expected response.
    3. The health tracker records success for the fallback provider.

    Implementation note: the primary provider's URL is deliberately set to
    an unreachable endpoint (127.0.0.1:1).  Because the circuit breaker check
    happens *before* [try_provider] is called, no connection attempt is ever
    made to that address.  If the circuit-breaker logic were removed or
    broken, [try_provider] would attempt port 1, get a connection-refused
    error, and the cascade would fail — surfacing the regression immediately. *)
let test_run_named_circuit_breaker_skips_open_provider () =
  let primary_key = "cb_open_primary" in
  let fallback_key = "cb_healthy_fallback" in
  (* 1. Seed the global health tracker: 3 consecutive failures → OPEN. *)
  Cascade_health_tracker.(
    record_failure global ~provider_key:primary_key ();
    record_failure global ~provider_key:primary_key ();
    record_failure global ~provider_key:primary_key ());
  Alcotest.(check bool) "pre-condition: primary is in cooldown after 3 failures"
    true
    (Cascade_health_tracker.is_in_cooldown
       Cascade_health_tracker.global ~provider_key:primary_key);
  try
    Eio.Switch.run @@ fun sw ->
    (* 2. Start a mock HTTP server for the fallback provider only. *)
    let fallback_port =
      match find_free_port () with Some p -> p | None -> Alcotest.skip ()
    in
    let fallback_url =
      try
        start_multi_mock ~sw ~net:(require_test_net ()) ~port:fallback_port
          [ openai_text_response "fallback succeeded" ]
      with
      | Unix.Unix_error (Unix.EPERM, "bind", _)
      | Unix.Unix_error (Unix.EACCES, "bind", _) ->
          Alcotest.skip ()
    in
    (* 3. Configure the cascade: primary (OPEN, unreachable) → fallback
          (healthy mock).  Use the model-id strings as the health-tracker
          provider keys so the circuit-breaker lookup matches exactly. *)
    with_temp_masc_config
      (Printf.sprintf
         {|{"cb_probe_models":["custom:%s@http://127.0.0.1:1","custom:%s@%s"]}|}
         primary_key fallback_key fallback_url)
    @@ fun () ->
    (* 4. Run the named cascade. *)
    (match
       Oas_worker_named.run_named
         ~cascade_name:"cb_probe"
         ~goal:"circuit breaker test"
         ~system_prompt:"system"
         ~sw
         ~net:(require_test_net ())
         ()
     with
     | Ok result ->
         (* 5. Fallback provider returned the expected response. *)
         Alcotest.(check string) "fallback provider response"
           "fallback succeeded"
           (response_text result.response);
         (* 6. Primary provider is still OPEN — no request reset its streak. *)
         Alcotest.(check bool)
           "primary remains OPEN (zero requests spent on open provider)"
           true
           (Cascade_health_tracker.is_in_cooldown
              Cascade_health_tracker.global ~provider_key:primary_key);
         (* 7. Fallback provider has a recorded success in the tracker. *)
         Alcotest.(check bool) "fallback is not in cooldown after success"
           false
           (Cascade_health_tracker.is_in_cooldown
              Cascade_health_tracker.global ~provider_key:fallback_key);
         let rate =
           Cascade_health_tracker.success_rate
             Cascade_health_tracker.global ~provider_key:fallback_key
         in
         Alcotest.(check bool) "fallback success_rate > 0 after run_named"
           true (rate > 0.0);
         Eio.Switch.fail sw Exit
     | Error err ->
         Alcotest.failf
           "expected fallback provider to succeed, got: %s"
           (Agent_sdk.Error.to_string err))
  with Exit -> ()

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Eio_main.run @@ fun env ->
  test_net := Some env#net;
  test_proc_mgr := Some (Eio.Stdenv.process_mgr env);
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Eio_guard.enable ();
  Eio.Switch.run @@ fun sw ->
  Masc_mcp.Oas_worker_cascade.start_actor_if_needed ~sw;
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
      Alcotest.test_case "local_only defaults stay local" `Quick
        test_default_model_strings_local_only;
      Alcotest.test_case "unknown cascade fallback" `Quick
        test_default_model_strings_unknown;
      Alcotest.test_case "default_config_path" `Quick
        test_default_config_path;
      Alcotest.test_case "all cascade names produce models" `Quick
        test_cascade_names_produce_models;
      Alcotest.test_case "cascade inference normalizes keeper aliases" `Quick
        test_cascade_inference_normalizes_keeper_aliases;
      Alcotest.test_case "cascade observation json includes fallback fields" `Quick
        test_cascade_observation_json_includes_fallback_fields;
      Alcotest.test_case "cascade metrics concurrent recording" `Quick
        test_cascade_metrics_concurrent_recording;
      Alcotest.test_case "cascade metrics evict lowest call key" `Quick
        test_cascade_metrics_evicts_lowest_call_key;
      Alcotest.test_case "cascade audit persists observation" `Quick
        test_cascade_audit_persists_observation;
      Alcotest.test_case "cascade provider labels keep glm and glm-coding distinct" `Quick
        test_cascade_provider_labels_keep_glm_and_glm_coding_distinct;
      Alcotest.test_case "provider max_turns clamps claude_code" `Quick
        test_provider_effective_max_turns_clamps_claude_code;
      Alcotest.test_case "provider max_turns leaves ollama uncapped" `Quick
        test_provider_effective_max_turns_keeps_ollama_budget;
      Alcotest.test_case "provider timeout caps claude_code" `Quick
        test_provider_attempt_timeout_caps_claude_code;
      Alcotest.test_case "provider timeout caps kimi_cli" `Quick
        test_provider_attempt_timeout_caps_kimi_cli;
      Alcotest.test_case "provider timeout caps gemini_cli" `Quick
        test_provider_attempt_timeout_caps_gemini_cli;
      Alcotest.test_case "provider timeout floors ollama" `Quick
        test_provider_attempt_timeout_floors_ollama;
      Alcotest.test_case "provider timeout leaves unconstrained final provider to outer budget" `Quick
        test_provider_attempt_timeout_leaves_unconstrained_last_to_outer_budget;
      Alcotest.test_case "cascade provider labels preserve registered openai_compat family" `Quick
        test_cascade_provider_labels_preserve_registered_openai_compat_family;
      Alcotest.test_case "cascade provider labels detect kimi from endpoint metadata" `Quick
        test_cascade_provider_labels_detect_kimi_from_endpoint_metadata;
      Alcotest.test_case "sdk_error_is_hard_quota detects Gemini CLI wrapper" `Quick
        test_sdk_error_is_hard_quota_detects_gemini_cli_network_wrapper;
      Alcotest.test_case "sdk_error_is_hard_quota detects Claude CLI limit wrapper" `Quick
        test_sdk_error_is_hard_quota_detects_claude_cli_limit_wrapper;
      Alcotest.test_case "sdk_error_is_hard_quota detects Claude org monthly limit wrapper" `Quick
        test_sdk_error_is_hard_quota_detects_claude_org_monthly_limit_wrapper;
      Alcotest.test_case "sdk_error_is_hard_quota detects Claude 400 specified-limit CLI wrapper" `Quick
        test_sdk_error_is_hard_quota_detects_claude_specified_limit_cli_wrapper;
      Alcotest.test_case "sdk_error_is_hard_quota detects Anthropic direct InvalidRequest specified-limit" `Quick
        test_sdk_error_is_hard_quota_detects_anthropic_invalid_request_specified_limit;
      Alcotest.test_case "sdk_error_is_max_turns detects Claude CLI wrapper" `Quick
        test_sdk_error_is_max_turns_detects_claude_cli_wrapper;
      Alcotest.test_case "sdk_error_is_hard_quota keeps transient network errors false" `Quick
        test_sdk_error_is_hard_quota_keeps_transient_network_errors_false;
      Alcotest.test_case "sdk_error_is_hard_quota preserves RateLimited detection" `Quick
        test_sdk_error_is_hard_quota_preserves_rate_limited_detection;
      Alcotest.test_case "sdk_error_is_hard_quota keeps NotFound false" `Quick
        test_sdk_error_is_hard_quota_keeps_not_found_false;
      Alcotest.test_case "sdk_error_to_cascade_outcome maps NotFound to 404" `Quick
        test_sdk_error_to_cascade_outcome_maps_not_found_to_404;
      Alcotest.test_case "sdk_error_to_cascade_outcome keeps ordinary InvalidRequest at 400" `Quick
        test_sdk_error_to_cascade_outcome_keeps_invalid_request_as_400;
      Alcotest.test_case "sdk_error_to_cascade_outcome cascades model access denial" `Quick
        test_sdk_error_to_cascade_outcome_cascades_model_access_denied;
      Alcotest.test_case "sdk_error_to_cascade_outcome cascades runtime MCP auth config" `Quick
        test_sdk_error_to_cascade_outcome_cascades_runtime_mcp_auth_config;
      Alcotest.test_case "sdk_error_to_cascade_outcome cascades resumable CLI session" `Quick
        test_sdk_error_to_cascade_outcome_cascades_resumable_cli_session;
      Alcotest.test_case "sdk_error_is_resumable_cli_session detects structured error" `Quick
        test_sdk_error_is_resumable_cli_session_detects_structured_error;
      Alcotest.test_case "sdk_error_is_resumable_cli_session detects raw Kimi hint" `Quick
        test_sdk_error_is_resumable_cli_session_detects_raw_kimi_hint;
      Alcotest.test_case "Moonshot auth errors include configured env hint" `Quick
        test_enrich_sdk_error_for_moonshot_auth_includes_env_hint;
      Alcotest.test_case "OpenAI-compatible 404 errors include endpoint hint" `Quick
        test_enrich_sdk_error_for_openai_not_found_includes_endpoint_hint;
      Alcotest.test_case "default_config preserves custom local request_path" `Quick
        test_default_config_preserves_custom_local_request_path;
      Alcotest.test_case "per-provider timeout uses context clock and exempts last provider" `Quick
        test_run_named_per_provider_timeout_uses_clock_fallback_and_exempts_last_provider;
      Alcotest.test_case "open circuit primary falls back without request" `Quick
        test_run_named_skips_cooldown_primary_and_falls_back;
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
      Alcotest.test_case "oas_worker applies stream idle timeout" `Quick
        test_oas_worker_exec_build_applies_stream_idle_timeout;
      Alcotest.test_case "apply_stream_idle_timeout_default passes Some through" `Quick
        test_apply_stream_idle_timeout_default_passes_through_caller_value;
      Alcotest.test_case "apply_stream_idle_timeout_default injects keepalive default for None" `Quick
        test_apply_stream_idle_timeout_default_injects_keepalive_default;
      Alcotest.test_case "oas_worker default priority remains unset" `Quick
        test_oas_worker_exec_build_default_priority_unset;
      Alcotest.test_case "oas_worker applies explicit priority" `Quick
        test_oas_worker_exec_build_applies_priority;
      Alcotest.test_case "oas_worker builds Kimi direct config" `Quick
        test_oas_worker_exec_build_supports_kimi_direct;
      Alcotest.test_case "oas_worker builds Kimi CLI config" `Quick
        test_oas_worker_exec_build_supports_kimi_cli;
      Alcotest.test_case "resume propagates approval (no silent ApprovalRequired drift)" `Quick
        test_resume_propagates_approval;
      Alcotest.test_case "resume propagates slot_id" `Quick
        test_resume_propagates_slot_id;
      Alcotest.test_case "resume propagates summarizer" `Quick
        test_resume_propagates_summarizer;
      Alcotest.test_case "resume propagates stream idle timeout" `Quick
        test_resume_propagates_stream_idle_timeout;
      Alcotest.test_case "resume propagates priority" `Quick
        test_resume_propagates_priority;
      Alcotest.test_case "CLI transports release fd resources per call" `Quick
        test_make_per_call_switch_transport_releases_cli_fd_resources;
      Alcotest.test_case "invalid explicit model label is rejected" `Quick
        test_resolve_provider_of_label_rejects_invalid_explicit_label;
      Alcotest.test_case "run_model_with_masc_tools rejects invalid explicit model label" `Quick
        test_run_model_with_masc_tools_rejects_invalid_explicit_label;
      Alcotest.test_case "structured MASC internal errors roundtrip through classifier" `Quick
        test_classify_masc_internal_error_roundtrip;
      Alcotest.test_case "codex preflight uses pipeline context fallback" `Quick
        test_codex_cli_prompt_preflight_uses_pipeline_context_window_fallback;
      Alcotest.test_case "codex preflight scales retry limit for argv overflow" `Quick
        test_codex_cli_prompt_preflight_scales_retry_limit_for_argv_only_overflow;
      Alcotest.test_case "public MCP tools on codex_cli use runtime MCP lane" `Quick
        test_resolve_tool_lane_for_codex_cli_public_tools_uses_runtime_mcp_policy;
      Alcotest.test_case
        "public MCP tools on codex_cli keep identity runtime MCP headers"
        `Quick
        test_resolve_tool_lane_for_codex_cli_public_tools_with_agent_name_keeps_identity_headers;
      Alcotest.test_case
        "keeper-bound public MCP tools on codex_cli omit request-scoped tools"
        `Quick
        test_resolve_tool_lane_for_codex_cli_keeper_bound_public_tools_omits_bound_tools;
      Alcotest.test_case
        "keeper-bound public MCP tools on codex_cli use per-keeper bearer"
        `Quick
        test_resolve_tool_lane_for_codex_cli_keeper_bound_public_tools_with_per_keeper_token_keeps_bound_tools;
      Alcotest.test_case "public MCP tools on kimi_cli use runtime MCP lane" `Quick
        test_resolve_tool_lane_for_kimi_cli_public_tools_uses_runtime_mcp_policy;
      Alcotest.test_case
        "public MCP tools on kimi_cli keep runtime MCP headers"
        `Quick
        test_resolve_tool_lane_for_kimi_cli_public_tools_with_agent_name_keeps_runtime_headers;
      Alcotest.test_case "mixed tool surface on kimi_cli keeps public runtime subset" `Quick
        test_resolve_tool_lane_for_kimi_cli_mixed_tools_keeps_public_runtime_subset;
      Alcotest.test_case "public MCP tools on openai_compat stay inline" `Quick
        test_resolve_tool_lane_for_openai_public_tools_keeps_inline_tools;
      Alcotest.test_case
        "keeper-internal tools on claude_code use runtime MCP lane"
        `Quick
        test_resolve_tool_lane_for_claude_code_keeper_internal_tools_uses_runtime_mcp_policy;
      Alcotest.test_case
        "keeper-internal tools on kimi_cli use runtime MCP lane when keeper-bound"
        `Quick
        test_resolve_tool_lane_for_kimi_cli_keeper_internal_tools_uses_runtime_mcp_policy;
      Alcotest.test_case "keeper-internal tools on codex_cli are rejected" `Quick
        test_resolve_tool_lane_for_codex_cli_internal_tools_rejects;
      Alcotest.test_case
        "keeper-internal tools on codex_cli with keeper actor are rejected"
        `Quick
        test_resolve_tool_lane_for_codex_cli_keeper_internal_tools_with_agent_rejects;
      Alcotest.test_case
        "keeper-internal tools on codex_cli with per-keeper bearer use runtime MCP"
        `Quick
        test_resolve_tool_lane_for_codex_cli_keeper_internal_tools_with_agent_and_per_keeper_token_uses_runtime_mcp;
      Alcotest.test_case "keeper-internal tools on kimi_cli are rejected" `Quick
        test_resolve_tool_lane_for_kimi_cli_internal_tools_rejects;
      Alcotest.test_case "optional keeper-internal tools on codex_cli drop to text" `Quick
        test_resolve_tool_lane_for_codex_cli_internal_tools_optional_drops_tools;
      Alcotest.test_case "provider-normalized filter keeps codex public MCP lane" `Quick
        test_filter_candidate_providers_for_tool_support_normalizes_codex_headers;
      Alcotest.test_case
        "provider-normalized filter drops codex keeper-bound actor tools"
        `Quick
        test_filter_candidate_providers_for_tool_support_drops_codex_cli_keeper_bound_actor_tools;
      Alcotest.test_case
        "provider-normalized filter keeps codex bound actor with per-keeper token"
        `Quick
        test_filter_candidate_providers_for_tool_support_keeps_codex_with_per_keeper_token;
      Alcotest.test_case
        "provider-normalized filter keeps header-capable keeper-internal lanes"
        `Quick
        test_filter_candidate_providers_for_tool_support_keeps_header_capable_cli_for_keeper_internal_tools;
      Alcotest.test_case
        "provider-normalized secondary preserves primary priority slot"
        `Quick
        test_filter_candidate_providers_for_tool_support_secondary_preserves_priority_slot;
      Alcotest.test_case
        "provider-normalized secondary resolver receives candidate index"
        `Quick
        test_filter_candidate_providers_for_tool_support_secondary_uses_candidate_index;
      Alcotest.test_case
        "RFC-0027 PR-9c: successful swap labels metric with secondary kind"
        `Quick
        test_dual_track_swap_emits_secondary_kind_label_on_success;
      Alcotest.test_case
        "RFC-0027 PR-9c: rejected secondary labels metric with kind+reason"
        `Quick
        test_dual_track_swap_emits_secondary_kind_label_on_rejection;
      Alcotest.test_case
        "classify_filter_rejection: codex bound-actor policy → keeper_bound_actor"
        `Quick test_classify_filter_rejection_codex_keeper_bound_actor;
      Alcotest.test_case
        "classify_filter_rejection: codex bound-actor policy passes with per-keeper bearer"
        `Quick
        test_classify_filter_rejection_codex_keeper_bound_actor_passes_with_per_keeper_token;
      Alcotest.test_case
        "classify_filter_rejection: returns None when provider passes"
        `Quick test_classify_filter_rejection_passes_when_provider_supported;
      Alcotest.test_case "kimi runtime MCP config keeps only allowed servers" `Quick
        test_kimi_mcp_config_json_of_policy_filters_to_allowed_servers;
      Alcotest.test_case "runtime MCP policy injects keeper agent header for masc server" `Quick
        test_runtime_mcp_policy_with_masc_agent_name_upserts_header;
      Alcotest.test_case "runtime MCP policy injects internal keeper token when configured" `Quick
        test_runtime_mcp_policy_with_masc_agent_name_prefers_internal_keeper_token;
      Alcotest.test_case "public MCP policy binds keeper internal headers" `Quick
        test_public_mcp_runtime_policy_binds_keeper_internal_headers;
      Alcotest.test_case "provider-aware runtime MCP policy preserves codex_cli identity header (PR-F)" `Quick
        test_runtime_mcp_policy_for_provider_codex_cli_preserves_identity_header;
      Alcotest.test_case "provider-aware runtime MCP policy strips all when codex_cli has no agent_name" `Quick
        test_runtime_mcp_policy_for_provider_codex_cli_no_agent_strips_all;
      Alcotest.test_case "kimi request runtime MCP config is merged" `Quick
        test_kimi_cli_runtime_mcp_jsons_include_request_policy;
      Alcotest.test_case "kimi argv includes request runtime MCP config" `Quick
        test_kimi_cli_build_args_include_runtime_mcp_config;
      Alcotest.test_case "kimi large prompt uses stdin, not argv" `Quick
        test_kimi_cli_build_args_uses_stdin_for_large_prompt;
      Alcotest.test_case "kimi non-ASCII prompt uses stdin, not argv" `Quick
        test_kimi_cli_build_args_uses_stdin_for_non_ascii_prompt;
      Alcotest.test_case "kimi broken UTF-8 prompt is sanitized off argv" `Quick
        test_kimi_cli_build_args_sanitizes_broken_utf8_prompt;
      Alcotest.test_case "kimi auto model keeps transport default" `Quick
        test_kimi_cli_model_for_provider_keeps_transport_default_on_auto;
      Alcotest.test_case "kimi explicit model is preserved" `Quick
        test_kimi_cli_model_for_provider_keeps_explicit_model;
      Alcotest.test_case "kimi config max context uses OAS SSOT" `Quick
        test_kimi_cli_config_uses_oas_context_ssot;
      Alcotest.test_case "kimi stderr resume noise is filtered" `Quick
        test_kimi_cli_should_log_stderr_line_filters_resume_noise;
      Alcotest.test_case "kimi exit 75 detail is redacted" `Quick
        test_kimi_cli_classify_cli_error_redacts_resumable_session_detail;
      Alcotest.test_case "kimi exit 1 resume hint is resumable" `Quick
        test_kimi_cli_classify_cli_error_treats_exit_1_resume_hint_as_resumable;
      Alcotest.test_case "kimi resumable InvalidRequest is structured" `Quick
        test_kimi_cli_resumable_invalid_request_reclassifies_as_structured;
      Alcotest.test_case "kimi exit 1 with stderr remains rejected" `Quick
        test_kimi_cli_classify_cli_error_keeps_exit_1_with_error_as_reject;
      Alcotest.test_case "kimi setproctitle unicode crash is startup crash" `Quick
        test_kimi_cli_classify_cli_error_labels_process_title_unicode_crash;
      Alcotest.test_case "terminal runtime detects Kimi unicode crash" `Quick
        test_sdk_error_terminal_provider_runtime_detects_kimi_unicode_crash;
      Alcotest.test_case "terminal runtime detects JSON-RPC SSE parse storm" `Quick
        test_sdk_error_terminal_provider_runtime_detects_jsonrpc_sse_parse_storm;
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
      Alcotest.test_case "legacy checkpoint roundtrip preserves tool pairs" `Quick
        test_keeper_checkpoint_legacy_roundtrip_preserves_tool_pairs;
      Alcotest.test_case "legacy old tool messages degrade to text" `Quick
        test_keeper_checkpoint_legacy_old_tool_messages_degrade_to_text;
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
      Alcotest.test_case "OAS store writes history snapshots" `Quick
        test_keeper_checkpoint_store_writes_oas_history;
      Alcotest.test_case "OAS store missing returns none" `Quick
        test_keeper_checkpoint_store_oas_missing_returns_none;
      Alcotest.test_case "prefers OAS checkpoint over legacy" `Quick
        test_keeper_checkpoint_prefers_oas_checkpoint;
      Alcotest.test_case "legacy fallback still works" `Quick
        test_keeper_checkpoint_legacy_fallback;
      Alcotest.test_case "legacy checkpoint roundtrip preserves tool pairs" `Quick
        test_keeper_checkpoint_legacy_roundtrip_preserves_tool_pairs;
      Alcotest.test_case "legacy old tool messages degrade to text" `Quick
        test_keeper_checkpoint_legacy_old_tool_messages_degrade_to_text;
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
    "circuit_breaker_cascade_fallback", [
      Alcotest.test_case
        "P0: open provider is skipped and fallback succeeds at run_named boundary"
        `Quick
        test_run_named_circuit_breaker_skips_open_provider;
    ];
  ]
