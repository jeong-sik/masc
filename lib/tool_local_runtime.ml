(** Tool_local_runtime -- local model runtime management and benchmarking tools.

    Facade module that re-exports sub-modules and provides MCP dispatch/schemas.
    Implementation is split across:
    - Tool_local_runtime_core   : types, helpers, process discovery, model fetching
    - Tool_local_runtime_http   : HTTP helpers (curl wrappers, JSON member access)
    - Tool_local_runtime_verify : runtime contract verification
    - Tool_local_runtime_bench  : concurrency benchmark
    - Tool_local_runtime_status : runtime pool status reporting
    - Tool_local_runtime_probe  : native Ollama timing/KV inference probe *)

open Masc_domain

module Core = Tool_local_runtime_core

(* Re-export sub-module public values used by external callers *)
let runtime_status_json = Tool_local_runtime_status.runtime_status_json
let runtime_verify_json = Tool_local_runtime_verify.runtime_verify_json
let runtime_ollama_probe_json = Tool_local_runtime_probe.runtime_ollama_probe_json
let run_bench = Tool_local_runtime_bench.run_bench
let provider_health_reachable = Tool_local_runtime_verify.provider_health_reachable
let classify_runtime_blocker = Tool_local_runtime_verify.classify_runtime_blocker
let ollama_loaded_models_of_ps_json = Tool_local_runtime_probe.ollama_loaded_models_of_ps_json
let ollama_probe_run_of_generate_json = Tool_local_runtime_probe.ollama_probe_run_of_generate_json
let kv_cache_assessment_json = Tool_local_runtime_probe.kv_cache_assessment_json

let ok_response ~tool_name ~start_time fields : Core.tool_result =
  Tool_result.make_ok
    ~tool_name
    ~start_time
    ~data:(Tool_args.ok_assoc fields)
    ()
;;

let err_response ~tool_name ~start_time ~class_ msg : Core.tool_result =
  let data = Tool_args.error_assoc [ "message", `String msg ] in
  Tool_result.make_err
    ~tool_name
    ~class_
    ~start_time
    ~data
    (Yojson.Safe.to_string data)
;;

let handle_models _ctx : Core.tool_result =
  let tool_name = "masc_runtime_models" in
  let start_time = Time_compat.now () in
  match Core.fetch_models () with
  | Error msg ->
      err_response
        ~tool_name
        ~start_time
        ~class_:Tool_result.Transient_error
        msg
  | Ok (url, models) ->
      ok_response
        ~tool_name
        ~start_time
        [
          ( "result",
            `Assoc
              [
                ("server_url", `String Env_config.Local_runtime.server_url);
                ("endpoint", `String url);
                ("source", `String "llama.cpp /v1/models");
                ("models", `List (List.map (fun m -> `String m) models));
                ("model_count", `Int (List.length models));
              ] );
        ]

let handle_runtime_status _ctx args : Core.tool_result =
  let tool_name = "masc_runtime_status" in
  let start_time = Time_compat.now () in
  let include_models =
    match Json_util.assoc_member_opt "include_models" args with
    | Some (`Bool flag) -> flag
    | _ -> true
  in
  ok_response
    ~tool_name
    ~start_time
    [ ("result", runtime_status_json ~include_models ()) ]

let handle_runtime_verify _ctx args : Core.tool_result =
  let tool_name = "masc_runtime_verify" in
  let start_time = Time_compat.now () in
  let runtime_pool = Json_util.get_string args "runtime_pool" in
  let expected_model = Json_util.get_string args "expected_model" in
  let expected_slots =
    match Json_util.assoc_member_opt "expected_slots" args with
    | Some (`Int value) -> Some (max 1 value)
    | Some (`Intlit value) -> Core.parse_int_opt value
    | _ -> None
  in
  let expected_ctx =
    match Json_util.assoc_member_opt "expected_ctx" args with
    | Some (`Int value) -> Some (max 1 value)
    | Some (`Intlit value) -> Core.parse_int_opt value
    | _ -> None
  in
  ok_response
    ~tool_name
    ~start_time
    [
      ( "result",
        runtime_verify_json ?runtime_pool ?expected_slots ?expected_ctx ?expected_model () );
    ]

let handle_runtime_bench _ctx args : Core.tool_result =
  let tool_name = "masc_runtime_bench" in
  let start_time = Time_compat.now () in
  let model_id = Json_util.get_string args "model" in
  let runtime_pool = Json_util.get_string args "runtime_pool" in
  let parallelism =
    match Json_util.assoc_member_opt "parallelism" args with
    | Some (`Int value) -> max 1 (min 128 value)
    | Some (`Intlit value) -> (
        match Core.parse_int_opt value with
        | Some parsed -> max 1 (min 128 parsed)
        | None -> 8)
    | _ -> 8
  in
  let rounds =
    match Json_util.assoc_member_opt "rounds" args with
    | Some (`Int value) -> max 1 (min 8 value)
    | Some (`Intlit value) -> (
        match Core.parse_int_opt value with
        | Some parsed -> max 1 (min 8 parsed)
        | None -> 1)
    | _ -> 1
  in
  let max_tokens =
    match Json_util.assoc_member_opt "max_tokens" args with
    | Some (`Int value) -> max 1 (min 128 value)
    | Some (`Intlit value) -> (
        match Core.parse_int_opt value with
        | Some parsed -> max 1 (min 128 parsed)
        | None -> 16)
    | _ -> 16
  in
  let timeout_sec =
    match Json_util.assoc_member_opt "timeout_sec" args with
    | Some (`Int value) -> max 3 (min 120 value)
    | Some (`Intlit value) -> (
        match Core.parse_int_opt value with
        | Some parsed -> max 3 (min 120 parsed)
        | None -> 8)
    | _ -> 8
  in
  let prompt =
    match Json_util.assoc_member_opt "prompt" args with
    | Some (`String value) when not (String.equal (String.trim value) "") -> String.trim value
    | _ -> "Reply with exactly one short word: ready"
  in
  match
    run_bench ?model_id ?runtime_pool ~parallelism ~rounds ~prompt
      ~max_tokens ~timeout_sec ()
  with
  | Ok json -> ok_response ~tool_name ~start_time [ ("result", json) ]
  | Error err ->
      err_response
        ~tool_name
        ~start_time
        ~class_:Tool_result.Runtime_failure
        err

let run_runtime_ollama_probe args : Core.tool_result =
  let tool_name = "masc_runtime_ollama_probe" in
  let start_time = Time_compat.now () in
  let server_url = Json_util.get_string args "server_url" in
  let model = Json_util.get_string args "model" in
  let prompt = Json_util.get_string args "prompt" in
  let keep_alive = Json_util.get_string args "keep_alive" in
  let probe_runs =
    match Json_util.assoc_member_opt "probe_runs" args with
    | Some (`Int value) -> value
    | Some (`Intlit value) -> (
        match Core.parse_int_opt value with
        | Some parsed -> parsed
        | None -> 2)
    | _ -> 2
  in
  let max_tokens =
    match Json_util.assoc_member_opt "max_tokens" args with
    | Some (`Int value) -> value
    | Some (`Intlit value) -> (
        match Core.parse_int_opt value with
        | Some parsed -> parsed
        | None -> 16)
    | _ -> 16
  in
  let timeout_sec =
    match Json_util.assoc_member_opt "timeout_sec" args with
    | Some (`Int value) -> value
    | Some (`Intlit value) ->
        (match Core.parse_int_opt value with
         | Some parsed -> parsed
         | None -> 6)
    | _ -> 6
  in
  let think_mode =
    match Json_util.assoc_member_opt "think_mode" args with
    | Some (`String value) -> (
        match Tool_local_runtime_probe.ollama_probe_think_mode_of_string value with
        | Some mode -> Ok mode
        | None ->
            Error
              "think_mode must be one of auto, disabled, or enabled")
    | _ -> (
        match Json_util.assoc_member_opt "think" args with
        | Some (`Bool true) -> Ok Tool_local_runtime_probe.Think_enabled
        | Some (`Bool false) -> Ok Tool_local_runtime_probe.Think_disabled
        | _ -> Ok Tool_local_runtime_probe.Think_auto)
  in
  let generate_when_unloaded =
    match Json_util.assoc_member_opt "generate_when_unloaded" args with
    | Some (`Bool flag) -> flag
    | _ -> true
  in
  let run_generate =
    match Json_util.assoc_member_opt "run_generate" args with
    | Some (`Bool flag) -> flag
    | _ -> true
  in
  match think_mode with
  | Error msg ->
      err_response
        ~tool_name
        ~start_time
        ~class_:Tool_result.Workflow_rejection
        msg
  | Ok think_mode ->
      ok_response
        ~tool_name
        ~start_time
        [
          ( "result",
            runtime_ollama_probe_json ?server_url ?model ?prompt ?keep_alive
              ~probe_runs ~max_tokens ~think_mode ~timeout_sec
              ~generate_when_unloaded ~run_generate () );
        ]

let handle_runtime_ollama_probe (ctx : Core.context) args : Core.tool_result =
  let continue () = run_runtime_ollama_probe args in
  match ctx.authorize_external_effect with
  | None -> continue ()
  | Some authorize ->
    authorize
      ~operation:"masc_runtime_ollama_probe"
      ~input:args
      ~continue
;;

let dispatch ctx ~name ~args : Core.tool_result option =
  match name with
  (* Canonical names *)
  | "masc_runtime_verify" ->
      Some (handle_runtime_verify ctx args)
  | "masc_runtime_ollama_probe" ->
      Some (handle_runtime_ollama_probe ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (definition : Tool_schemas_local_runtime.definition) ->
      let s = definition.schema in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_local_runtime
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:true
           ~is_idempotent:true
           ()))
    Tool_schemas_local_runtime.definitions

let schemas = Tool_schemas_local_runtime.schemas
