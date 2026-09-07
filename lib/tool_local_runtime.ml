(** Tool_local_runtime -- local model runtime MCP dispatch and schemas.

    Handler implementations are split across:
    Implementation is split across:
    - Tool_local_runtime_core   : types, helpers, process discovery, model fetching
    - Tool_local_runtime_http   : HTTP helpers (curl wrappers, JSON member access)
    - Tool_local_runtime_verify : runtime contract verification
    - Tool_local_runtime_probe  : native Ollama timing/KV inference probe *)

open Masc_domain

module Core = Tool_local_runtime_core

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

let run_runtime_verify args : Core.tool_result =
  let tool_name = Tool_schemas_local_runtime.tool_name Verify in
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
        Tool_local_runtime_verify.runtime_verify_json
          ?runtime_pool ?expected_slots ?expected_ctx ?expected_model () );
    ]

(* TEL-OK: this adapter only requests the shared external-effect authorization
   and delegates the completion. The authorizer owns the Gate decision receipt;
   the outer MCP tool-call boundary owns duration and result telemetry. *)
let handle_runtime_verify (ctx : Core.context) args : Core.tool_result =
  let continue () = run_runtime_verify args in
  match ctx.authorize_external_effect with
  | None -> continue ()
  | Some authorize ->
    authorize
      ~operation:(Tool_schemas_local_runtime.tool_name Verify)
      ~input:args
      ~continue
;;

let run_runtime_ollama_probe ~probe_runs ~max_tokens ~ps_timeout_sec ?timeout_sec
    args : Core.tool_result =
  let tool_name = Tool_schemas_local_runtime.tool_name Ollama_probe in
  let start_time = Time_compat.now () in
  let server_url = Json_util.get_string args "server_url" in
  let model = Json_util.get_string args "model" in
  let prompt = Json_util.get_string args "prompt" in
  let keep_alive = Json_util.get_string args "keep_alive" in
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
            Tool_local_runtime_probe.runtime_ollama_probe_json
              ?server_url ?model ?prompt ?keep_alive
              ~probe_runs ~max_tokens ~think_mode ?timeout_sec ~ps_timeout_sec
              ~generate_when_unloaded ~run_generate () );
        ]

let runtime_ollama_probe_timeout_sec args =
  match Json_field.int args "timeout_sec" with
  | Json_field.Field_absent -> Ok None
  | Json_field.Found value ->
      Result.map
        (fun timeout_sec -> Some timeout_sec)
        (Tool_local_runtime_probe.validate_timeout_sec value)
  | Json_field.Wrong_shape { expected; got } ->
      Error
        (Printf.sprintf
           "timeout_sec must be a positive %s, got %s"
           expected
           got)

(* Absent means "use the default"; present-but-unusable does not. Reading a
   string or a float back as the default answers with an ok response for a
   probe the caller did not ask for. Out-of-range is the same story with a
   different cause -- #24851 removed that rewrite for timeout_sec, and these
   knobs are refused in the same place, before the Gate sees the call, so a
   rejected probe never authorizes an external effect (#25006). *)
let runtime_ollama_probe_bounded_field args ~name ~default ~validate =
  match Json_field.int args name with
  | Json_field.Field_absent -> Ok default
  | Json_field.Found value -> validate value
  | Json_field.Wrong_shape { expected; got } ->
      Error (Printf.sprintf "%s must be an %s, got %s" name expected got)

type ollama_probe_bounds =
  { probe_runs : int
  ; max_tokens : int
  ; ps_timeout_sec : int
  ; timeout_sec : int option
  }

let runtime_ollama_probe_bounds args : (ollama_probe_bounds, string) result =
  let ( let* ) = Result.bind in
  let* timeout_sec = runtime_ollama_probe_timeout_sec args in
  let* probe_runs =
    runtime_ollama_probe_bounded_field args ~name:"probe_runs" ~default:2
      ~validate:Tool_local_runtime_probe.validate_probe_runs
  in
  let* max_tokens =
    runtime_ollama_probe_bounded_field args ~name:"max_tokens" ~default:16
      ~validate:Tool_local_runtime_probe.validate_max_tokens
  in
  let* ps_timeout_sec =
    runtime_ollama_probe_bounded_field args ~name:"ps_timeout_sec" ~default:2
      ~validate:Tool_local_runtime_probe.validate_ps_timeout_sec
  in
  Ok { probe_runs; max_tokens; ps_timeout_sec; timeout_sec }

let handle_runtime_ollama_probe (ctx : Core.context) args : Core.tool_result =
  match runtime_ollama_probe_bounds args with
  | Error message ->
      err_response
        ~tool_name:(Tool_schemas_local_runtime.tool_name Ollama_probe)
        ~start_time:(Time_compat.now ())
        ~class_:Tool_result.Workflow_rejection
        message
  | Ok { probe_runs; max_tokens; ps_timeout_sec; timeout_sec } ->
      let continue () =
        run_runtime_ollama_probe ~probe_runs ~max_tokens ~ps_timeout_sec
          ?timeout_sec args
      in
      (match ctx.authorize_external_effect with
       | None -> continue ()
       | Some authorize ->
         authorize
           ~operation:(Tool_schemas_local_runtime.tool_name Ollama_probe)
           ~input:args
           ~continue)
;;

(* Resolved against the same [definitions] list registration walks, so an
   operation added to [Tool_schemas_local_runtime] is a compile error here. *)
let find_operation name =
  List.find_opt
    (fun (definition : Tool_schemas_local_runtime.definition) ->
      String.equal definition.schema.name name)
    Tool_schemas_local_runtime.definitions
  |> Option.map (fun (definition : Tool_schemas_local_runtime.definition) ->
       definition.operation)

let dispatch ctx ~name ~args : Core.tool_result option =
  match find_operation name with
  | None -> None
  | Some Tool_schemas_local_runtime.Verify ->
      Some (handle_runtime_verify ctx args)
  | Some Tool_schemas_local_runtime.Ollama_probe ->
      Some (handle_runtime_ollama_probe ctx args)

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (definition : Tool_schemas_local_runtime.definition) ->
      let s = definition.schema in
      let policy =
        Tool_schemas_local_runtime.execution_policy definition.operation
      in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_local_runtime
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:policy.read_only
           ~is_idempotent:policy.idempotent
           ()))
    Tool_schemas_local_runtime.definitions

let schemas = Tool_schemas_local_runtime.schemas
