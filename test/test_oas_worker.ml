(** Test_oas_worker — Unit tests for OAS worker streaming bridge,
    cascade config, and governance integration.

    LLM 0 — no real MODEL calls. Tests use mock net / temp directories.

    @since Phase 1 — MASC->OAS migration
    @since Phase A — OAS #215 streaming verification *)

open Masc_mcp

module Oas = Agent_sdk

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

let make_local_provider ?(model_id = "mock-model") () : Oas.Provider.config =
  {
    Oas.Provider.provider = Oas.Provider.Local { base_url = "http://127.0.0.1:1" };
    model_id;
    api_key_env = "";
  }

let make_local_provider_cfg ?(model_id = "mock-model") () :
    Llm_provider.Provider_config.t =
  match Oas.Provider_bridge.to_provider_config (make_local_provider ~model_id ()) with
  | Ok cfg -> cfg
  | Error err -> failwith (Oas.Error.to_string err)

let make_noop_tool () =
  Oas.Tool.create
    ~name:"noop"
    ~description:"No-op test tool"
    ~parameters:[]
    (fun _ -> Ok Oas.Types.{ content = "ok" })

let make_named_noop_tool name =
  Oas.Tool.create
    ~name
    ~description:"No-op test tool"
    ~parameters:[]
    (fun _ -> Ok Oas.Types.{ content = "ok" })

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let with_temp_masc_config cascade_json f =
  let base = temp_dir "test_masc_config" in
  let config_dir = Filename.concat base ".masc/config" in
  let cascade_path = Filename.concat config_dir "cascade.json" in
  mkdir_p config_dir;
  let oc = open_out cascade_path in
  output_string oc cascade_json;
  close_out oc;
  let prev_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  let prev_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Config_dir_resolver.reset ();
  Cascade_catalog_runtime.reset_cache_for_tests ();
  Unix.putenv "MASC_BASE_PATH" base;
  Unix.putenv "MASC_CONFIG_DIR" config_dir;
  Fun.protect
    ~finally:(fun () ->
      (match prev_base_path with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> Unix.putenv "MASC_BASE_PATH" "");
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
      cascade_name = Masc_mcp.Keeper_config.default_cascade_name;
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
                   ~cascade_name:"concurrent-cascade"
                   ~observation:None
                   ~outcome:`Success
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
  Masc_mcp.Oas_worker_cascade.reset_cascade_counters_for_test ();
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Oas_worker_cascade.reset_cascade_counters_for_test ())
    (fun () ->
      Masc_mcp.Oas_worker_cascade.record_cascade
        ~cascade_name:"victim-key"
        ~observation:None
        ~outcome:`Success;
      for i = 1 to 254 do
        let name = Printf.sprintf "stable-%03d" i in
        Masc_mcp.Oas_worker_cascade.record_cascade
          ~cascade_name:name
          ~observation:None
          ~outcome:`Success;
        Masc_mcp.Oas_worker_cascade.record_cascade
          ~cascade_name:name
          ~observation:None
          ~outcome:`Success
      done;
      for _ = 1 to 3 do
        Masc_mcp.Oas_worker_cascade.record_cascade
          ~cascade_name:"hot-key"
          ~observation:None
          ~outcome:`Success
      done;
      let before = Yojson.Safe.Util.to_list (Oas_worker.cascade_metrics_json ()) in
      Alcotest.(check int) "table capped before admit" 256 (List.length before);
      Masc_mcp.Oas_worker_cascade.record_cascade
        ~cascade_name:"new-key"
        ~observation:None
        ~outcome:`Success;
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
          cascade_name = "audit-cascade";
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
        ~cascade_name:"audit-cascade"
        ~observation:(Some observation)
        ~outcome:`Failure;
      let store =
        Dated_jsonl.create
          ~base_dir:(Filename.concat base ".masc/cascade_audit")
          ()
      in
      match Dated_jsonl.read_recent store 1 with
      | [ json ] ->
          Alcotest.(check string) "cascade name persisted" "audit-cascade"
            Yojson.Safe.Util.(json |> member "cascade_name" |> to_string);
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
    Oas.Error.Api
      (Llm_provider.Retry.NetworkError
         {
           message =
             "gemini exited with code 1: TerminalQuotaError: You have exhausted \
              your capacity on this model. Your quota will reset after 4h41m7s. \
              reason=QUOTA_EXHAUSTED";
           kind = Unknown;
         })
  in
  Alcotest.(check bool) "Gemini CLI quota wrapper counts as hard quota" true
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_hard_quota_detects_claude_cli_limit_wrapper () =
  let err =
    Oas.Error.Api
      (Llm_provider.Retry.NetworkError
         {
           message =
             "claude exited with code 1: {\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":429,\"result\":\"You've hit your limit · resets Apr 24 at 4am (Asia/Seoul)\"}";
           kind = Unknown;
         })
  in
  Alcotest.(check bool) "Claude CLI limit wrapper counts as hard quota" true
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_hard_quota_keeps_transient_network_errors_false () =
  let err =
    Oas.Error.Api
      (Llm_provider.Retry.NetworkError
         {
           message = "gemini exited with code 1: connection reset by peer";
           kind = Unknown;
         })
  in
  Alcotest.(check bool) "transient network error stays transient" false
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_hard_quota_preserves_rate_limited_detection () =
  let err =
    Oas.Error.Api
      (Llm_provider.Retry.RateLimited
         { retry_after = None; message = "resource exhausted" })
  in
  Alcotest.(check bool) "existing RateLimited hard quota still works" true
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_is_hard_quota_keeps_not_found_false () =
  let err =
    Oas.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message = {|{"detail":"Not Found"}|} })
  in
  Alcotest.(check bool) "404-like InvalidRequest stays non-hard-quota" false
    (Oas_worker_named.sdk_error_is_hard_quota err)

let test_sdk_error_to_cascade_outcome_maps_not_found_to_404 () =
  let err =
    Oas.Error.Api
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
         (match outcome with
          | Some (Cascade_fsm.Call_err _) -> "some-call-err"
           | Some (Cascade_fsm.Accept_rejected _) -> "some-accept-rejected"
          | Some (Cascade_fsm.Call_ok _) -> "some-call-ok"
          | Some Cascade_fsm.Slot_full -> "some-slot-full"
          | None -> "none")

let test_sdk_error_to_cascade_outcome_keeps_invalid_request_as_400 () =
  let err =
    Oas.Error.Api
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
        (match outcome with
         | Some (Cascade_fsm.Call_err _) -> "some-call-err"
         | Some (Cascade_fsm.Accept_rejected _) -> "some-accept-rejected"
         | Some (Cascade_fsm.Call_ok _) -> "some-call-ok"
         | Some Cascade_fsm.Slot_full -> "some-slot-full"
         | None -> "none")

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
    "kimi": "KIMI_API_KEY_SB"
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
    Oas.Error.Api
      (Llm_provider.Retry.AuthError
         { message = "Invalid Authentication" })
  in
  let rendered =
    Oas_worker_named.enrich_sdk_error
      ~cascade_name:"keeper_unified"
      ~provider_cfg
      err
    |> Oas.Error.to_string
  in
  Alcotest.(check bool) "env hint included" true
    (contains_substring ~needle:"KIMI_API_KEY_SB" rendered);
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
    Oas.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message = {|{"detail":"Not Found"}|} })
  in
  let rendered =
    Oas_worker_named.enrich_sdk_error
      ~cascade_name:"keeper_unified"
      ~provider_cfg
      err
    |> Oas.Error.to_string
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
  | Oas.Provider.OpenAICompat { base_url; path; _ } ->
    Alcotest.(check string) "base_url preserved"
      "http://127.0.0.1:18080/v1" base_url;
    Alcotest.(check string) "request_path preserved"
      "/chat/completions" path
  | Oas.Provider.Local _ ->
    Alcotest.fail "custom local OpenAI-compatible provider regressed to Local"
  | _ ->
    Alcotest.fail
      "custom local OpenAI-compatible provider should stay OpenAICompat"

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
    execution_scope = Worker_types.Limited_code_change;
    thinking_enabled = Some true;
    max_turns_override = None;
    timeout_seconds = Some 240;
    tool_profile = Worker_container_types.Profile_session_min;
    shell_profile = Worker_container_types.Shell_readonly;
    worker_class = Some Worker_types.Worker_executor;
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
    response_format = Oas.Types.Off;
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
      let policy = (Oas.Agent.options agent).tool_retry_policy in
      Alcotest.(check bool) "default leaves retry disabled" true
        (Option.is_none policy);
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
      tool_retry_policy = Some Oas.Tool_retry_policy.default_internal }
  in
  Eio.Switch.run @@ fun sw ->
  match Oas_worker_exec.build ~sw ~net:(require_test_net ()) ~config with
  | Ok agent ->
      let policy = (Oas.Agent.options agent).tool_retry_policy in
      check_policy_matches_default_internal "exec build opt-in" policy;
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
      let priority = (Oas.Agent.state agent).config.priority in
      Alcotest.(check bool) "default priority remains unset" true
        (Option.is_none priority);
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
      let priority = (Oas.Agent.state agent).config.priority in
      Alcotest.(check bool) "priority propagated to agent config" true
        (match priority with
         | Some Llm_provider.Request_priority.Proactive -> true
         | _ -> false);
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
  | Ok agent -> Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
  | Ok agent -> Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

(* Resume parity: fields that [build] threads from [config] via the
   Builder must also propagate through [resume_from_checkpoint]. Each
   missing field used to fail silently — the run continued with
   [default_options.<field>] (= [None]). The [approval] regression was
   the loud signal: OAS logged "ApprovalRequired but no approval
   callback — executing" on the first ApprovalRequired tool of a
   resumed keeper. *)

let test_resume_propagates_approval () =
  let approval_called = ref false in
  let approval : Oas.Hooks.approval_callback =
    fun ~tool_name:_ ~input:_ ->
      approval_called := true;
      Oas.Hooks.Approve
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
      let approval_opt = (Oas.Agent.options agent).approval in
      Alcotest.(check bool) "approval is propagated through resume" true
        (Option.is_some approval_opt);
      (match approval_opt with
       | Some cb ->
           let _ = cb ~tool_name:"x" ~input:`Null in
           Alcotest.(check bool) "callback identity preserved" true
             !approval_called
       | None -> ());
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
      let slot = (Oas.Agent.options agent).slot_id in
      Alcotest.(check (option int)) "slot_id is propagated" (Some 7) slot;
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

let test_resume_propagates_summarizer () =
  let summarizer_called = ref false in
  let summarizer (_msgs : Oas.Types.message list) =
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
      let s = (Oas.Agent.options agent).summarizer in
      Alcotest.(check bool) "summarizer is propagated" true (Option.is_some s);
      (match s with
       | Some f ->
           let _ = f [] in
           Alcotest.(check bool) "summarizer identity preserved" true
             !summarizer_called
       | None -> ());
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
      let priority = (Oas.Agent.state agent).config.priority in
      Alcotest.(check bool) "priority propagated through resume" true
        (match priority with
         | Some Llm_provider.Request_priority.Proactive -> true
         | _ -> false);
      Oas.Agent.close agent
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
      ~dispatch:(fun ~name:_ ~args:_ -> (true, "ok"))
      ()
  with
  | Ok _ ->
      Alcotest.fail "expected invalid explicit model label to fail before execution"
  | Error (Oas.Error.Config (Oas.Error.InvalidConfig { field; detail })) ->
      Alcotest.(check string) "invalid field" "model_label" field;
      Alcotest.(check bool) "detail mentions rejected label" true
        (contains_substring ~needle:"not-a-model-label" detail)
  | Error err ->
      Alcotest.failf "unexpected error shape: %s" (Oas.Error.to_string err)

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

let mock_api_response () : Oas.Types.api_response =
  {
    id = "mock-session";
    model = "mock-cli";
    stop_reason = Oas.Types.EndTurn;
    content = [ Oas.Types.Text "ok" ];
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
           cascade_name = Masc_mcp.Keeper_config.default_cascade_name;
           reason = Keeper_types.All_providers_failed;
         })
  in
  (match Oas_worker_named.classify_masc_internal_error cascade_err with
   | Some (Oas_worker_named.Cascade_exhausted { cascade_name; reason }) ->
       Alcotest.(check string) "cascade name" Masc_mcp.Keeper_config.default_cascade_name cascade_name;
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
  match Oas_worker_named.classify_masc_internal_error accept_err with
  | Some (Oas_worker_named.Accept_rejected { scope; model; reason }) ->
      Alcotest.(check string) "accept scope" Masc_mcp.Keeper_config.default_cascade_name scope;
      Alcotest.(check (option string)) "accept model"
        (Some "mock-model") model;
      Alcotest.(check bool) "accept reason preserved" true
        (contains_substring ~needle:"response rejected by accept" reason)
  | _ -> Alcotest.fail "expected structured accept rejection"

let make_codex_cli_provider_cfg ?(model_id = "codex") () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Codex_cli
    ~model_id ~base_url:"" ()

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

let test_cascade_provider_labels_preserve_registered_openai_compat_family () =
  let provider_name = Masc_mcp.Oas_worker_cascade.provider_name_of_config
      (make_openrouter_provider_cfg ()) in
  let model_label = Masc_mcp.Oas_worker_cascade.model_label_of_config
      (make_openrouter_provider_cfg ()) in
  Alcotest.(check string) "openrouter provider name" "openrouter" provider_name;
  Alcotest.(check string) "openrouter model label"
    "openrouter:anthropic/claude-3.5" model_label

let test_cascade_provider_labels_detect_kimi_from_model_and_base_url () =
  let provider_name = Masc_mcp.Oas_worker_cascade.provider_name_of_config
      (make_kimi_provider_cfg ()) in
  let model_label = Masc_mcp.Oas_worker_cascade.model_label_of_config
      (make_kimi_provider_cfg ()) in
  Alcotest.(check string) "kimi provider name" "kimi" provider_name;
  Alcotest.(check string) "kimi model label" "kimi:kimi-k2.5" model_label

let test_resolve_tool_lane_for_codex_cli_public_tools_uses_runtime_mcp_policy () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  let tools =
    [ make_named_noop_tool "masc_status"; make_named_noop_tool "masc_tasks" ]
  in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~provider_cfg:(make_codex_cli_provider_cfg ())
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
      Alcotest.fail "expected codex_cli public MCP tools to use runtime MCP lane"
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

let test_resolve_tool_lane_for_codex_cli_public_tools_with_agent_name_rejects_runtime_headers () =
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" @@ fun () ->
  let tools =
    [ make_named_noop_tool "masc_status"; make_named_noop_tool "masc_tasks" ]
  in
  match
    Oas_worker_exec.resolve_tool_lane_for_oas_tools
      ~agent_name:"keeper-sangsu-agent"
      ~provider_cfg:(make_codex_cli_provider_cfg ())
      ~tools ()
  with
  | Ok _ ->
      Alcotest.fail
        "expected codex_cli to reject public MCP runtime lane when keeper headers are required"
  | Error (Oas.Error.Config (Oas.Error.InvalidConfig { field; detail })) ->
      Alcotest.(check string) "field" "tool_support" field;
      Alcotest.(check bool) "detail mentions runtime MCP HTTP headers" true
        (contains_substring ~needle:"runtime MCP HTTP headers" detail)
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
  | Error (Oas.Error.Config (Oas.Error.InvalidConfig { field; _ })) ->
      Alcotest.(check string) "field" "tool_support" field
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
  | Error (Oas.Error.Config (Oas.Error.InvalidConfig { field; _ })) ->
      Alcotest.(check string) "field" "tool_support" field
  | Error err -> Alcotest.fail (Oas.Error.to_string err)

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
      Alcotest.(check (option string)) "masc auth preserved"
        (Some "Bearer token")
        (List.assoc_opt "Authorization" masc_headers);
      Alcotest.(check (option string)) "other server unchanged" None
        (List.assoc_opt "x-masc-agent-name" other_headers)
  | _ -> Alcotest.fail "expected both masc and other HTTP servers"

let test_runtime_mcp_policy_for_provider_skips_codex_cli_header_injection () =
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
      Alcotest.(check (option string)) "codex_cli skips agent header" None
        (List.assoc_opt "x-masc-agent-name" codex_headers);
      Alcotest.(check (option string)) "openai_compat still injects agent header"
        (Some "keeper-sangsu-agent")
        (List.assoc_opt "x-masc-agent-name" openai_headers)
  | _ -> Alcotest.fail "expected masc runtime server headers"

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
  let (config, options) =
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
      Alcotest.test_case "cascade provider labels preserve registered openai_compat family" `Quick
        test_cascade_provider_labels_preserve_registered_openai_compat_family;
      Alcotest.test_case "cascade provider labels detect kimi from model/base_url" `Quick
        test_cascade_provider_labels_detect_kimi_from_model_and_base_url;
      Alcotest.test_case "sdk_error_is_hard_quota detects Gemini CLI wrapper" `Quick
        test_sdk_error_is_hard_quota_detects_gemini_cli_network_wrapper;
      Alcotest.test_case "sdk_error_is_hard_quota detects Claude CLI limit wrapper" `Quick
        test_sdk_error_is_hard_quota_detects_claude_cli_limit_wrapper;
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
      Alcotest.test_case "Moonshot auth errors include configured env hint" `Quick
        test_enrich_sdk_error_for_moonshot_auth_includes_env_hint;
      Alcotest.test_case "OpenAI-compatible 404 errors include endpoint hint" `Quick
        test_enrich_sdk_error_for_openai_not_found_includes_endpoint_hint;
      Alcotest.test_case "default_config preserves custom local request_path" `Quick
        test_default_config_preserves_custom_local_request_path;
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
        "public MCP tools on codex_cli reject unsupported runtime MCP headers"
        `Quick
        test_resolve_tool_lane_for_codex_cli_public_tools_with_agent_name_rejects_runtime_headers;
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
      Alcotest.test_case "keeper-internal tools on codex_cli are rejected" `Quick
        test_resolve_tool_lane_for_codex_cli_internal_tools_rejects;
      Alcotest.test_case "keeper-internal tools on kimi_cli are rejected" `Quick
        test_resolve_tool_lane_for_kimi_cli_internal_tools_rejects;
      Alcotest.test_case "kimi runtime MCP config keeps only allowed servers" `Quick
        test_kimi_mcp_config_json_of_policy_filters_to_allowed_servers;
      Alcotest.test_case "runtime MCP policy injects keeper agent header for masc server" `Quick
        test_runtime_mcp_policy_with_masc_agent_name_upserts_header;
      Alcotest.test_case "provider-aware runtime MCP policy skips codex_cli agent header injection" `Quick
        test_runtime_mcp_policy_for_provider_skips_codex_cli_header_injection;
      Alcotest.test_case "kimi request runtime MCP config is merged" `Quick
        test_kimi_cli_runtime_mcp_jsons_include_request_policy;
      Alcotest.test_case "kimi argv includes request runtime MCP config" `Quick
        test_kimi_cli_build_args_include_runtime_mcp_config;
      Alcotest.test_case "kimi auto model keeps transport default" `Quick
        test_kimi_cli_model_for_provider_keeps_transport_default_on_auto;
      Alcotest.test_case "kimi explicit model is preserved" `Quick
        test_kimi_cli_model_for_provider_keeps_explicit_model;
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
  ]
