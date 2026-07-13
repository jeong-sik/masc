open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

let elapsed_duration_ms ~start_time ~end_time =
  let elapsed_ms = (end_time -. start_time) *. 1000. in
  match classify_float elapsed_ms with
  | FP_nan | FP_infinite -> 0
  | _ when elapsed_ms <= 0. -> 0
  | _ when elapsed_ms < 1. -> 1
  | _ -> int_of_float elapsed_ms

let sandbox_extra_uses_docker sandbox_extra_fields =
  List.exists
    (function
      | "via", `String "docker" -> true
      | _ -> false)
    sandbox_extra_fields

let typed_execute_response_cwd_json
      ~turn_sandbox_factory
      ~cwd
      ~sandbox_extra_fields
  =
  if sandbox_extra_uses_docker sandbox_extra_fields then
    match
      Keeper_sandbox_factory.container_cwd_of_host_opt
        turn_sandbox_factory
        ~host_cwd:cwd
    with
    | Some container_cwd ->
      Keeper_cwd_response.docker ~host_cwd:cwd ~container_cwd
      |> Keeper_cwd_response.to_yojson_response
    | None -> `String cwd
  else `String cwd

let sandbox_target_label = function
  | Masc_exec.Sandbox_target.Host -> "host"
  | Masc_exec.Sandbox_target.Docker { image; _ } -> "docker:" ^ image
;;

let execute_gate_input ~input ~cwd ~sandbox_profile ~sandbox_target =
  `Assoc
    [ "schema", `String "masc.keeper_gate.request.v1"
    ; "input", input
    ; "cwd", `String cwd
    ; "sandbox_profile", `String sandbox_profile
    ; "sandbox_target", `String sandbox_target
    ]
;;

let execute_secret_redaction ~base_path ~keeper_name =
  Keeper_secret_redaction.snapshot ~base_path ~keeper_name

let redact_execute_text redaction text =
  Keeper_secret_redaction.redact_text redaction text

let redact_execute_output redaction ~stdout ~stderr =
  let stdout = redact_execute_text redaction stdout in
  let stderr = redact_execute_text redaction stderr in
  let output =
    if String.equal stderr "" then stdout else stdout ^ stderr
  in
  stdout, stderr, output

module For_testing = struct
  let elapsed_duration_ms = elapsed_duration_ms
  let typed_execute_response_cwd_json = typed_execute_response_cwd_json
  let execute_gate_input = execute_gate_input
  let redact_execute_output ~base_path ~keeper_name ~stdout ~stderr =
    let redaction = execute_secret_redaction ~base_path ~keeper_name in
    redact_execute_output redaction ~stdout ~stderr

end

(* Typed Execute input projections extracted to
   [Keeper_tool_execute_input] (godfile decomp). *)
let has_typed_execute_input_key = Keeper_tool_execute_input.has_typed_execute_input_key
let assoc_upsert = Keeper_tool_execute_input.assoc_upsert
let typed_input_command_text = Keeper_tool_execute_input.typed_input_command_text
let typed_input_has_env = Keeper_tool_execute_input.typed_input_has_env
let typed_input_timeout_sec = Keeper_tool_execute_input.typed_input_timeout_sec
let typed_validation_error_text = Keeper_tool_execute_input.typed_validation_error_text

let normalize_path_for_keeper_tool_execute_shell_ir_containment path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

(* Backend target helpers for typed Shell IR dispatch. *)
let docker_sandbox_target = Keeper_sandbox_shell_ir_target.docker_target
let docker_local_fallback_target =
  Keeper_sandbox_shell_ir_target.docker_local_fallback_target

let input_with_cwd cwd = function
  | Keeper_tool_execute_typed_input.Exec
      { executable; argv; cwd = _; env; timeout_sec; stdin; stdout; stderr } ->
    Keeper_tool_execute_typed_input.Exec
      { executable
      ; argv
      ; cwd = Some cwd
      ; env
      ; timeout_sec
      ; stdin
      ; stdout
      ; stderr
      }
  | Keeper_tool_execute_typed_input.Pipeline
      { stages; cwd = _; env; timeout_sec } ->
    Keeper_tool_execute_typed_input.Pipeline
      { stages; cwd = Some cwd; env; timeout_sec }

let handle_tool_execute_typed
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~(args : Yojson.Safe.t)
      ()
  =
  let root = Keeper_alerting_path.project_root_of_config config in
  let output_redaction =
    execute_secret_redaction ~base_path:config.base_path ~keeper_name:meta.name
  in
  match
    Keeper_tool_execute_path.resolve_tool_execute_cwd
      ~config
      ~meta
      (* Keep all keepers on the shared execute-worktree root. The exact
         external-effect Gate is evaluated after the concrete cwd and sandbox
         target have both been resolved. *)
      ~write_enabled:true
      ~args
  with
    | Error e -> Keeper_tool_execution.failure (error_json e)
    | Ok cwd ->
        let execution_location_fields cwd =
          [ ( "execution_location"
            , Keeper_sandbox_repo_path.execution_location_json ~config ~meta ~args ~cwd )
          ]
      in
      let typed_args = assoc_upsert "cwd" (`String cwd) args in
      match Keeper_tool_execute_typed_input.of_json typed_args with
      | Error e ->
        Keeper_tool_execution.failure
          ~class_:Tool_result.Policy_rejection
          (error_json
             ~fields:
               ([ "typed", `Bool true; "cwd", `String cwd ]
                @ execution_location_fields cwd)
             e)
      | Ok input ->
        (match Keeper_tool_execute_typed_input.validate input with
         | Error e ->
           let fields =
             [ "typed", `Bool true; "cwd", `String cwd ]
             @ execution_location_fields cwd
           in
           Keeper_tool_execution.failure
             ~class_:Tool_result.Policy_rejection
             (error_json ~fields (typed_validation_error_text e))
         | Ok () ->
        let cmd = typed_input_command_text input in
        let timeout_sec = typed_input_timeout_sec input in
        let input = input_with_cwd cwd input in
        let in_playground = Keeper_tool_execute_path.in_playground ~root ~cwd ~meta in
        let sandbox_profile, _sandbox_network_mode =
          Keeper_sandbox_runner.effective_sandbox_profile ~meta
        in
        let local_dispatch_sandbox ?(extra_fields = []) () =
          match
            Keeper_secret_projection.local_env_for_keeper
              ~base_path:config.base_path
              ~keeper_name:meta.name
              ()
          with
          | Error err ->
            Error
              (Keeper_sandbox_shell_ir_target.target_error
                 ~fields:extra_fields
                 ("local_secret_projection_failed: " ^ err))
          | Ok base_host_env ->
            Ok (Masc_exec.Sandbox_target.host (), extra_fields, base_host_env)
        in
        let dispatch_sandbox =
          match sandbox_profile with
          | Local -> local_dispatch_sandbox ()
          | Docker ->
            if typed_input_has_env input
            then
              Error
                (Keeper_sandbox_shell_ir_target.target_error
                   "typed Shell IR Docker dispatch does not support env yet")
            else (
              match docker_local_fallback_target ~meta ?timeout_sec () with
              | Some (target, fields) when in_playground ->
                (match target with
                 | Masc_exec.Sandbox_target.Host ->
                   local_dispatch_sandbox ~extra_fields:fields ()
                 | Docker _ -> Ok (target, fields, None))
              | Some _ | None ->
                docker_sandbox_target
                  ~turn_sandbox_factory
                  ~meta
                  ~cwd
                  ?timeout_sec
                  ()
                |> Result.map (fun target ->
                  ( target
                  , [ "requested_sandbox", `String "docker"
                    ; "via", `String "docker"
                    ; "sandbox_profile", `String "docker"
                    ]
                  , None )))
        in
        (match dispatch_sandbox with
         | Error ({ message; fields } : Keeper_sandbox_shell_ir_target.target_error) ->
           Keeper_tool_execution.failure
             (error_json
                ~fields:
                  ([ "typed", `Bool true; "cmd", `String cmd; "cwd", `String cwd ]
                   @ execution_location_fields cwd
                   @ fields)
                message)
         | Ok (dispatch_sandbox, sandbox_extra_fields, base_host_env) ->
        let response_cwd_json =
          typed_execute_response_cwd_json
            ~turn_sandbox_factory
            ~cwd
            ~sandbox_extra_fields
        in
        let response_cwd_field = [ "cwd", response_cwd_json ] in
        (* Lower the validated typed input exactly once. The resulting Shell IR
           is the neutral dispatch representation; it carries no product or
           inferred authorization semantics. *)
        match Keeper_tool_execute_typed_input.to_shell_ir ~sandbox:dispatch_sandbox input with
        | Error e ->
          let fields =
            [ "typed", `Bool true; "cmd", `String cmd ]
            @ response_cwd_field
            @ execution_location_fields cwd
          in
          Keeper_tool_execution.failure
            ~class_:Tool_result.Policy_rejection
            (error_json ~fields (typed_validation_error_text e))
        | Ok ir ->
        let cmd_for_log =
          Exec_policy.sanitize_command_for_log_of_ir ~fallback_cmd:cmd ir
          |> Exec_policy.truncate_for_log
        in
        let message_for_log s =
          String.map
            (function
              | '\n' | '\r' | '\t' -> ' '
              | c -> c)
            s
          |> Exec_policy.truncate_for_log
        in
        let typed_error_fields =
          [ "typed", `Bool true; "cmd", `String cmd_for_log ]
          @ response_cwd_field
          @ execution_location_fields cwd
        in
        let typed_error_json
              ?(class_ = Tool_result.Runtime_failure)
              ?(extra_fields = [])
              msg
          =
          Keeper_tool_execution.failure
            ~class_
            (error_json
               ~fields:(typed_error_fields @ extra_fields)
               msg)
        in
        let sandbox_profile_label =
          Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox_profile
        in
        let typed_args = assoc_upsert "cwd" (`String cwd) typed_args in
        let gate_input =
          execute_gate_input
            ~input:typed_args
            ~cwd
            ~sandbox_profile:sandbox_profile_label
            ~sandbox_target:(sandbox_target_label dispatch_sandbox)
        in
        let gate_request : Keeper_gate.request =
          { keeper_name = meta.name
          ; operation = "tool_execute"
          ; input = gate_input
          ; base_path = config.base_path
          ; causal_context = Option.map (fun current -> current ()) gate_context
          ; task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
          ; goal_ids = meta.active_goal_ids
          ; continuation_channel
          }
        in
        (match
           Keeper_gate.decide
             ?cycle_grant:gate_grant
             ~keeper_always_allow:(Option.value ~default:false meta.always_allow)
             gate_request
         with
         | Keeper_gate.Deferred { approval_id; reason } ->
           typed_error_json
             ~class_:Tool_result.Workflow_rejection
             ~extra_fields:
               [ "error", `String "gate_deferred"
               ; "approval_request_id", `String approval_id
               ; "approval_queue_status", `String "pending"
               ; "approval_nonblocking", `Bool true
               ; "gate_reason", `String (Keeper_gate.deferred_reason_to_string reason)
             ]
             "External effect deferred without blocking this Keeper. Continue other work; the originating Keeper lane will wake after resolution."
         | Keeper_gate.Unavailable reason ->
           typed_error_json
             ~extra_fields:
               [ "error", `String "gate_unavailable"
               ; "gate_reason"
               , `String (Keeper_gate.unavailable_reason_to_string reason)
               ]
             "External effect was not executed because the Gate could not durably record its decision state. This Keeper remains active and may continue other work."
         | Keeper_gate.Allow authorization ->
          Log.Keeper.info
            ~keeper_name:meta.name
            "external effect authorized operation=tool_execute source=%s"
            (Keeper_gate.authorization_source_to_string authorization.source);
          (* NDT-OK: wall clock is used only for elapsed telemetry, never for
             dispatch branching or policy decisions. *)
          let t0 = Unix.gettimeofday () in
          let task_id =
            Option.map Keeper_id.Task_id.to_string meta.current_task_id
          in
          let stream_dispatch =
            Sys.getenv_opt "MASC_STREAM_EXECUTE_OUTPUT" <> Some "false"
          in
          if stream_dispatch
          then (
            try
              Keeper_keepalive_signal.record_execute_stream_start
                ~keeper_name:meta.name
                ~task_id
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Dashboard.warn
                "execute stream start callback failed keeper=%s: %s"
                meta.name
                (Printexc.to_string exn));
          let stdout_redact_state =
            Keeper_secret_redaction.create_stream_state ()
          in
          let stderr_redact_state =
            Keeper_secret_redaction.create_stream_state ()
          in
          let on_output_chunk chunk =
            if stream_dispatch
            then (
              let stream, data =
                match chunk with
                | `Stdout s -> `Stdout, s
                | `Stderr s -> `Stderr, s
              in
              let data =
                match stream with
                | `Stdout ->
                  Keeper_secret_redaction.redact_stream_chunk
                    output_redaction stdout_redact_state data
                | `Stderr ->
                  Keeper_secret_redaction.redact_stream_chunk
                    output_redaction stderr_redact_state data
              in
              try
                Keeper_keepalive_signal.record_execute_stream_chunk
                  ~keeper_name:meta.name
                  ~stream
                  data
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Dashboard.warn
                  "execute stream chunk callback failed keeper=%s: %s"
                  meta.name
                  (Printexc.to_string exn))
          in
          Retired_env_warnings.report_shell_ir_path_jail_if_set
            ~source:"execute"
            ();
          let dispatch_result =
            Keeper_tool_execute_shell_ir.dispatch
              ~workdir:cwd
              ~sandbox:dispatch_sandbox
              ?timeout_sec
              ?base_host_env
              ~on_output_chunk
              ir
          in
          match dispatch_result with
          | Error (Keeper_tool_execute_shell_ir.Gate_reject diagnostic) ->
            (* RFC-0208 P1: gate denial audit line. *)
            Log.Keeper.warn
              "shell_ir gate_reject keeper=%s cmd=%s diagnostic=%s"
              meta.name
              cmd_for_log
              (message_for_log diagnostic);
            typed_error_json diagnostic
          | Error Keeper_tool_execute_shell_ir.Cannot_parse ->
            typed_error_json "Cannot parse command"
          | Error Keeper_tool_execute_shell_ir.Too_complex ->
            typed_error_json "Command too complex"
          | Error (Keeper_tool_execute_shell_ir.Path_reject e) ->
            (* RFC-0208 P1: path-policy denial audit line. *)
            Log.Keeper.warn
              "shell_ir path_reject keeper=%s cmd=%s reason=%s"
              meta.name
              cmd_for_log
              (message_for_log e);
            typed_error_json
              ~extra_fields:[ "blocked_cmd", `String cmd_for_log ]
              e
          | Ok result ->
            let elapsed_ms =
              (* NDT-OK: second wall-clock read closes the elapsed telemetry
                 span recorded immediately below. *)
              elapsed_duration_ms ~start_time:t0 ~end_time:(Unix.gettimeofday ())
            in
            Log.Keeper.info
              "shell_ir dispatch keeper=%s sandbox=%s status=%s elapsed_ms=%d"
              meta.name
              sandbox_profile_label
              (Keeper_sandbox_exec_failure.status_label result.status)
              elapsed_ms;
            let stdout, stderr, output =
              redact_execute_output output_redaction
                ~stdout:result.stdout
                ~stderr:result.stderr
            in
            let status_json =
              Keeper_alerting_path.process_status_to_json result.status
            in
            if stream_dispatch
            then (
              let flush_remaining stream state =
                let remaining =
                  Keeper_secret_redaction.redact_stream_finish
                    output_redaction state
                in
                if not (String.equal remaining "")
                then (
                  try
                    Keeper_keepalive_signal.record_execute_stream_chunk
                      ~keeper_name:meta.name
                      ~stream
                      remaining
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                    Log.Dashboard.warn
                      "execute stream flush callback failed keeper=%s: %s"
                      meta.name
                      (Printexc.to_string exn))
              in
              flush_remaining `Stdout stdout_redact_state;
              flush_remaining `Stderr stderr_redact_state;
              try
                Keeper_keepalive_signal.record_execute_stream_end
                  ~keeper_name:meta.name
                  ~task_id
                  ~status:status_json
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Dashboard.warn
                  "execute stream end callback failed keeper=%s: %s"
                  meta.name
                  (Printexc.to_string exn));
            (try
               Keeper_keepalive_signal.record_execute_output
                 ~keeper_name:meta.name
                 ~task_id
                 ~stdout
                 ~stderr
                 ~status:status_json
                 ~streamed:stream_dispatch
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Dashboard.warn
                 "execute output callback failed keeper=%s: %s"
                 meta.name
                 (Printexc.to_string exn));
            let succeeded =
              match result.status with
              | Unix.WEXITED 0 -> true
              | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false
            in
            let failure_error_fields =
              match result.status, String.trim stderr with
              | Unix.WEXITED 0, _ | _, "" -> []
              | _, stderr -> [ "error", `String stderr; "stderr", `String stderr ]
            in
            let payload =
              Yojson.Safe.to_string
                (`Assoc
                   ([ "ok", `Bool succeeded
                    ; "status", status_json
                    ; "output", `String output
                    ; "typed", `Bool true
                    ; "execution_time_ms", `Int elapsed_ms
                    ]
                    @ failure_error_fields
                    @ sandbox_extra_fields
                    @ response_cwd_field
                    @ execution_location_fields cwd))
            in
            if succeeded
            then Keeper_tool_execution.success payload
            else Keeper_tool_execution.failure payload
        )))

let handle_tool_execute_with_outcome
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~exec_cache:_
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~(args : Yojson.Safe.t)
      ()
  =
  if has_typed_execute_input_key args
  then
    handle_tool_execute_typed
      ~turn_sandbox_factory
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~args
      ()
  else
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json
         ~fields:[ "typed", `Bool true ]
         "Typed Shell IR input is required. Provide executable/argv or pipeline.")
;;

let handle_tool_execute
      ~turn_sandbox_factory
      ~exec_cache
      ~config
      ~meta
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~args
      ()
  =
  (handle_tool_execute_with_outcome
     ~turn_sandbox_factory
     ~exec_cache
     ~config
     ~meta
     ?continuation_channel
     ?gate_context
     ?gate_grant
     ~args
     ()).raw_output
;;
