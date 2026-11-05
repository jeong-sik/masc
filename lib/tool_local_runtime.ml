(** Tool_local_runtime -- local model runtime MCP dispatch and schemas.

    Implementation is split across:
    - Tool_local_runtime_core   : shared types and a parse helper
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

(* Absent means "use the default"; present-but-unusable does not. An argument
   of the wrong shape is refused before the Gate sees the call, because reading
   it back as the default answers for a call the caller did not make. *)
let runtime_flag_field args ~name ~default =
  match Json_field.bool args name with
  | Json_field.Field_absent -> Ok default
  | Json_field.Found value -> Ok value
  | Json_field.Wrong_shape { expected; got } ->
      Error (Printf.sprintf "%s must be a %s, got %s" name expected got)

let runtime_text_field args ~name =
  match Json_field.string args name with
  | Json_field.Field_absent -> Ok None
  | Json_field.Found value -> Ok (Some value)
  | Json_field.Wrong_shape { expected; got } ->
      Error (Printf.sprintf "%s must be a %s, got %s" name expected got)

(* A verification that drops an expectation reports success for a check that
   never ran, so an unreadable or non-positive expectation is refused. *)
let runtime_positive_int_field args ~name =
  match Json_field.int args name with
  | Json_field.Field_absent -> Ok None
  | Json_field.Found value when value >= 1 -> Ok (Some value)
  | Json_field.Found value ->
      Error (Printf.sprintf "%s must be a positive integer (got %d)" name value)
  | Json_field.Wrong_shape { expected; got } ->
      Error (Printf.sprintf "%s must be an %s, got %s" name expected got)

type runtime_verify_args =
  { runtime_pool : string option
  ; expected_model : string option
  ; expected_slots : int option
  ; expected_ctx : int option
  }

(* Every argument is read here, before the Gate sees the call. *)
let runtime_verify_args args : (runtime_verify_args, string) result =
  let open Result.Syntax in
  let* runtime_pool = runtime_text_field args ~name:"runtime_pool" in
  let* expected_model = runtime_text_field args ~name:"expected_model" in
  let* expected_slots = runtime_positive_int_field args ~name:"expected_slots" in
  let* expected_ctx = runtime_positive_int_field args ~name:"expected_ctx" in
  Ok { runtime_pool; expected_model; expected_slots; expected_ctx }

let run_runtime_verify (verify : runtime_verify_args) : Core.tool_result =
  let tool_name = Tool_schemas_local_runtime.tool_name Verify in
  let start_time = Tool_timing.start () in
  ok_response
    ~tool_name
    ~start_time
    [
      ( "result",
        Tool_local_runtime_verify.runtime_verify_json
          ?runtime_pool:verify.runtime_pool ?expected_slots:verify.expected_slots
          ?expected_ctx:verify.expected_ctx ?expected_model:verify.expected_model
          () );
    ]

(* TEL-OK: this adapter only requests the shared external-effect authorization
   and delegates the completion. The authorizer owns the Gate decision receipt;
   the outer MCP tool-call boundary owns duration and result telemetry. *)
let handle_runtime_verify (ctx : Core.context) args : Core.tool_result =
  match runtime_verify_args args with
  | Error message ->
      err_response
        ~tool_name:(Tool_schemas_local_runtime.tool_name Verify)
        ~start_time:(Tool_timing.start ())
        ~class_:Tool_result.Workflow_rejection
        message
  | Ok verify ->
      let continue () = run_runtime_verify verify in
      (match ctx.authorize_external_effect with
       | None -> continue ()
       | Some authorize ->
         authorize
           ~operation:(Tool_schemas_local_runtime.tool_name Verify)
           ~input:args
           ~continue)
;;

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

(* Out-of-range is refused like a wrong shape. #24851 removed the rewrite for
   timeout_sec, and these knobs are refused in the same place, before the Gate
   sees the call, so a rejected probe never authorizes an external effect
   (#25006). *)
let runtime_ollama_probe_bounded_field args ~name ~default ~validate =
  match Json_field.int args name with
  | Json_field.Field_absent -> Ok default
  | Json_field.Found value -> validate value
  | Json_field.Wrong_shape { expected; got } ->
      Error (Printf.sprintf "%s must be an %s, got %s" name expected got)

(* [think_mode] names the mode outright. [think] is its boolean shorthand and
   is read only when [think_mode] is absent. *)
let runtime_ollama_probe_think_mode args =
  match Json_field.string args "think_mode" with
  | Json_field.Found value ->
      (match Tool_local_runtime_probe.ollama_probe_think_mode_of_string value with
       | Some mode -> Ok mode
       | None -> Error "think_mode must be one of auto, disabled, or enabled")
  | Json_field.Wrong_shape { expected; got } ->
      Error (Printf.sprintf "think_mode must be a %s, got %s" expected got)
  | Json_field.Field_absent ->
      (match Json_field.bool args "think" with
       | Json_field.Found true -> Ok Tool_local_runtime_probe.Think_enabled
       | Json_field.Found false -> Ok Tool_local_runtime_probe.Think_disabled
       | Json_field.Field_absent -> Ok Tool_local_runtime_probe.Think_auto
       | Json_field.Wrong_shape { expected; got } ->
           Error (Printf.sprintf "think must be a %s, got %s" expected got))

type ollama_probe_args =
  { server_url : string option
  ; model : string option
  ; prompt : string option
  ; keep_alive : string option
  ; probe_runs : int
  ; max_tokens : int
  ; ps_timeout_sec : int
  ; timeout_sec : int option
  ; think_mode : Tool_local_runtime_probe.ollama_probe_think_mode
  ; generate_when_unloaded : bool
  ; run_generate : bool
  }

(* Every argument is read here, before the Gate sees the call. *)
let runtime_ollama_probe_args args : (ollama_probe_args, string) result =
  let open Result.Syntax in
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
  let* server_url = runtime_text_field args ~name:"server_url" in
  let* model = runtime_text_field args ~name:"model" in
  let* prompt = runtime_text_field args ~name:"prompt" in
  let* keep_alive = runtime_text_field args ~name:"keep_alive" in
  let* think_mode = runtime_ollama_probe_think_mode args in
  let* generate_when_unloaded =
    runtime_flag_field args ~name:"generate_when_unloaded" ~default:true
  in
  let* run_generate =
    runtime_flag_field args ~name:"run_generate" ~default:true
  in
  Ok
    { server_url
    ; model
    ; prompt
    ; keep_alive
    ; probe_runs
    ; max_tokens
    ; ps_timeout_sec
    ; timeout_sec
    ; think_mode
    ; generate_when_unloaded
    ; run_generate
    }

let run_runtime_ollama_probe (probe : ollama_probe_args) : Core.tool_result =
  let tool_name = Tool_schemas_local_runtime.tool_name Ollama_probe in
  let start_time = Tool_timing.start () in
  ok_response
    ~tool_name
    ~start_time
    [
      ( "result",
        Tool_local_runtime_probe.runtime_ollama_probe_json
          ?server_url:probe.server_url ?model:probe.model ?prompt:probe.prompt
          ?keep_alive:probe.keep_alive ~probe_runs:probe.probe_runs
          ~max_tokens:probe.max_tokens ~think_mode:probe.think_mode
          ?timeout_sec:probe.timeout_sec ~ps_timeout_sec:probe.ps_timeout_sec
          ~generate_when_unloaded:probe.generate_when_unloaded
          ~run_generate:probe.run_generate () );
    ]

let handle_runtime_ollama_probe (ctx : Core.context) args : Core.tool_result =
  match runtime_ollama_probe_args args with
  | Error message ->
      err_response
        ~tool_name:(Tool_schemas_local_runtime.tool_name Ollama_probe)
        ~start_time:(Tool_timing.start ())
        ~class_:Tool_result.Workflow_rejection
        message
  | Ok probe ->
      let continue () = run_runtime_ollama_probe probe in
      (match ctx.authorize_external_effect with
       | None -> continue ()
       | Some authorize ->
         authorize
           ~operation:(Tool_schemas_local_runtime.tool_name Ollama_probe)
           ~input:args
           ~continue)
;;

let handle_systemone_decide (ctx : Core.context) args : Core.tool_result =
  let tool_name = Tool_schemas_local_runtime.tool_name Systemone_decide in
  let start_time = Tool_timing.start () in
  match Tool_local_runtime_systemone.args_of_yojson args with
  | Error message ->
      err_response ~tool_name ~start_time ~class_:Tool_result.Policy_rejection message
  | Ok { Tool_local_runtime_systemone.backend; model; state; questions; timeout_sec } ->
      let continue () =
        let request =
          { Tool_local_runtime_systemone.model =
              (match model with
               | Some explicit -> explicit
               | None -> Tool_local_runtime_systemone.default_model backend)
          ; state
          ; questions
          }
        in
        match Tool_local_runtime_systemone.decide ~timeout_sec request backend with
        | Ok result -> ok_response ~tool_name ~start_time [ ("result", result) ]
        | Error message ->
            err_response ~tool_name ~start_time
              ~class_:Tool_result.Dependency_unavailable message
      in
      (match ctx.authorize_external_effect with
       | None -> continue ()
       | Some authorize -> authorize ~operation:tool_name ~input:args ~continue)
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
  | Some Tool_schemas_local_runtime.Systemone_decide ->
      Some (handle_systemone_decide ctx args)

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
