open Keeper_types
open Agent_tool_shared_runtime

let elapsed_duration_ms ~start_time ~end_time =
  let elapsed_ms = (end_time -. start_time) *. 1000. in
  match classify_float elapsed_ms with
  | FP_nan | FP_infinite -> 0
  | _ when elapsed_ms <= 0. -> 0
  | _ when elapsed_ms < 1. -> 1
  | _ -> int_of_float elapsed_ms

let deterministic_retry_fields_for_process_result
      ~(classification : Exec_core.classification)
      ~status
  =
  match status, classification.Exec_core.family with
  | Unix.WEXITED 128, (Exec_core.Git_read | Exec_core.Git_write) ->
    Keeper_tool_deterministic_error.deterministic_retry_fields
      Keeper_tool_deterministic_error.Git_precondition_failed
  | _ -> []
;;

module For_testing = struct
  let elapsed_duration_ms = elapsed_duration_ms
  let deterministic_retry_fields_for_process_result =
    deterministic_retry_fields_for_process_result
end

(* Typed Execute input projections extracted to
   [Agent_tool_execute_input] (godfile decomp). *)
let has_typed_bash_input_key = Agent_tool_execute_input.has_typed_bash_input_key
let assoc_upsert = Agent_tool_execute_input.assoc_upsert
let typed_input_command_text = Agent_tool_execute_input.typed_input_command_text
let typed_input_has_env = Agent_tool_execute_input.typed_input_has_env
let typed_validation_error_text = Agent_tool_execute_input.typed_validation_error_text

let normalize_path_for_keeper_shell_ir_containment path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

(* Backend target helpers for typed Shell IR dispatch. *)
let docker_sandbox_target = Keeper_sandbox_shell_ir_target.docker_target
let docker_local_fallback_target =
  Keeper_sandbox_shell_ir_target.docker_local_fallback_target

let input_with_cwd cwd = function
  | Keeper_tool_bash_input.Exec { executable; argv; cwd = _; env } ->
    Keeper_tool_bash_input.Exec { executable; argv; cwd = Some cwd; env }
  | Keeper_tool_bash_input.Pipeline { stages; cwd = _; env } ->
    Keeper_tool_bash_input.Pipeline { stages; cwd = Some cwd; env }

let resolve_typed_git_cwd ~config ~meta ~cwd ~cmd ~mode input =
  match Keeper_tool_bash_input.to_shell_ir_unvalidated ~mode input with
  | Error _ -> cwd, None
  | Ok ir ->
    let stages = Keeper_shell_command_semantics.effective_stages_of_ir ir in
    Keeper_shell_command_semantics.resolve_sandbox_root_git_cwd_of_stages
      ~config
      ~meta
      ~cwd
      ~cmd
      stages

let handle_tool_execute_typed
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~timeout_sec
      ~write_enabled
      ()
  =
  let root = Keeper_alerting_path.project_root_of_config config in
  match Keeper_shell_path.resolve_tool_write_cwd ~config ~meta ~args with
    | Error e -> error_json e
    | Ok cwd ->
      let typed_args = assoc_upsert "cwd" (`String cwd) args in
      match Keeper_tool_bash_input.of_json typed_args with
      | Error e ->
        error_json
          ~fields:[ "typed", `Bool true; "cwd", `String cwd ]
          e
      | Ok input ->
        let cmd = typed_input_command_text input in
        let mode =
          if write_enabled
          then Keeper_tool_bash_input.Dev_full
          else Keeper_tool_bash_input.Readonly
        in
        let cwd, root_git_cwd_error =
          resolve_typed_git_cwd ~config ~meta ~cwd ~cmd ~mode input
        in
        let input = input_with_cwd cwd input in
        let in_playground = Keeper_shell_path.in_playground ~root ~cwd ~meta in
        let sandbox_profile, _sandbox_network_mode =
          Keeper_sandbox_runner.effective_sandbox_profile ~meta
        in
        let dispatch_sandbox =
          match sandbox_profile with
          | Local -> Ok (Masc_exec.Sandbox_target.host (), [])
          | Docker ->
            if typed_input_has_env input
            then
              Error
                (Keeper_sandbox_shell_ir_target.target_error
                   "typed Shell IR Docker dispatch does not support env yet")
            else (
              match docker_local_fallback_target ~meta ~timeout_sec with
              | Some fallback when in_playground -> Ok fallback
              | Some _ | None ->
                docker_sandbox_target ~turn_sandbox_factory ~meta ~cwd ~timeout_sec
                |> Result.map (fun target ->
                  ( target
                  , [ "requested_sandbox", `String "docker"
                    ; "via", `String "docker"
                    ; "sandbox_profile", `String "docker"
                    ] )))
        in
        (match dispatch_sandbox with
         | Error ({ message; fields } : Keeper_sandbox_shell_ir_target.target_error) ->
           error_json
             ~fields:
               ([ "typed", `Bool true; "cmd", `String cmd; "cwd", `String cwd ]
                @ fields)
             message
         | Ok (dispatch_sandbox, sandbox_extra_fields) ->
        match root_git_cwd_error with
        | Some e ->
          error_json
            ~fields:[ "typed", `Bool true; "cmd", `String cmd; "cwd", `String cwd ]
            e
        | None ->
        (* RFC-0160 S1: lower-then-classify. Typed argv → Shell IR
           once, then both mutation classifiers consume the same IR.
           This removes the previous double-parse (mutation classifier
           re-tokenized cmd:string via the legacy string tokenizer before IR
           was even built). *)
        match Keeper_tool_bash_input.to_shell_ir ~mode ~sandbox:dispatch_sandbox input with
        | Error e ->
          error_json
            ~fields:[ "typed", `Bool true; "cmd", `String cmd; "cwd", `String cwd ]
            (typed_validation_error_text e)
        | Ok ir ->
        let cmd_for_log =
          Exec_policy.sanitize_command_for_log_of_ir ~fallback_cmd:cmd ir
          |> Exec_policy.truncate_for_log
        in
        let typed_error_fields =
          [ "typed", `Bool true; "cmd", `String cmd_for_log; "cwd", `String cwd ]
        in
        let blocked_result ?deterministic_reason ~error ~reason ~alternatives () =
          let deterministic_retry_fields =
            match deterministic_reason with
            | Some deterministic_reason ->
              Keeper_tool_deterministic_error.deterministic_retry_fields
                deterministic_reason
            | None -> []
          in
          Yojson.Safe.to_string
            (Exec_core.blocked_result_json
               ~classification:(Exec_core.classify_command_of_ir ir)
               ~cmd
               ~error
               ~reason
               ~alternatives
               ~retryability:Exec_core.Operator_required
               ~extra:
                 (deterministic_retry_fields
                  @ [ "cmd", `String cmd_for_log
                    ; "typed", `Bool true
                    ; "execution_time_ms", `Int 0
                    ])
               ())
        in
        let envelope = Keeper_shell_ir.classify ir in
        let typed_error_json msg = error_json ~fields:typed_error_fields msg in
        if Masc_exec.Shell_ir_risk.is_destructive envelope
        then
          blocked_result
            ~deterministic_reason:
              Keeper_tool_deterministic_error.Destructive_operation_blocked
            ~error:"destructive_operation_blocked"
            ~reason:"This typed command is destructive and is blocked for all presets."
            ~alternatives:[ "Use a non-destructive command or a dedicated structured tool." ]
            ()
        else if (not write_enabled)
             && (Masc_exec.Shell_ir_risk.is_r1 envelope
                || Masc_exec.Shell_ir_risk.is_r2 envelope)
        then
          blocked_result
            ~deterministic_reason:Keeper_tool_deterministic_error.Write_operation_gated
            ~error:"write_operation_gated"
            ~reason:"This typed command modifies state. A write-enabled preset is required."
            ~alternatives:
              [ "Use read-only commands such as rg, cat, ls, git status, or git log."
              ; "Ask the operator for a write-enabled preset."
              ]
            ()
        else
          let allowed_commands =
            match mode with
            | Keeper_tool_bash_input.Dev_full -> Dev_exec_allowlist.dev
            | Keeper_tool_bash_input.Readonly -> Dev_exec_allowlist.readonly
          in
          let env_snap =
            Cancel_safe.protect
              ~on_exn:(fun _ -> None)
              (fun () -> Some (Exec_core.snapshot_env ~cwd))
          in
          (* NDT-OK: wall clock is used only for elapsed telemetry, never for
             dispatch branching or policy decisions. *)
          let t0 = Unix.gettimeofday () in
          let dispatch_result =
            Keeper_shell_ir.dispatch_classified
              ~before_path_validation:(fun ir ->
                Ok ())
              ~allowed_commands
              ~keeper_id:meta.name
              ~base_path:root
              ~workdir:cwd
              ~sandbox:dispatch_sandbox
              envelope
          in
          match dispatch_result with
          | Error (Keeper_shell_ir.Gate_reject diagnostic) -> typed_error_json diagnostic
          | Error Keeper_shell_ir.Cannot_parse -> typed_error_json "Cannot parse command"
          | Error Keeper_shell_ir.Too_complex -> typed_error_json "Command too complex"
          | Error (Keeper_shell_ir.Path_reject e) ->
            error_json ~fields:[ "blocked_cmd", `String cmd_for_log ] e
          | Ok result ->
            let elapsed_ms =
              (* NDT-OK: second wall-clock read closes the elapsed telemetry
                 span recorded immediately below. *)
              elapsed_duration_ms ~start_time:t0 ~end_time:(Unix.gettimeofday ())
            in
            Log.Keeper.info
              "shell_ir dispatch keeper=%s sandbox=%s status=%s elapsed_ms=%d"
              meta.name
              (Keeper_types.sandbox_profile_to_string sandbox_profile)
              (Keeper_sandbox_exec_failure.status_label result.status)
              elapsed_ms;
            let output =
              if String.equal result.stderr ""
              then result.stdout
              else result.stdout ^ result.stderr
            in
            let classification = Exec_core.classify_command_of_ir ir in
            let deterministic_retry_fields =
              deterministic_retry_fields_for_process_result
                ~classification
                ~status:result.status
            in
            Yojson.Safe.to_string
              (Exec_core.process_result_json
                 ~classification
                 ~base_path:root
                 ~keeper_name:meta.name
                 ~cmd
                 ~extra:
                   (deterministic_retry_fields
                    @ sandbox_extra_fields
                    @ [ "cwd", `String cwd
                      ; "typed", `Bool true
                      ; "execution_time_ms", `Int elapsed_ms
                      ; "timeout_sec", `Float timeout_sec
                      ])
                 ~status:result.status
                 ~output
                 ~env_snapshot:env_snap
                 ()))

let handle_tool_execute
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~turn_sandbox_factory_git:_
      ~exec_cache:_
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ()
  =
  let timeout_sec =
    Keeper_shell_timeout.clamp_shell_timeout
      ~min_sec:(Keeper_shell_timeout.keeper_shell_ir_min_timeout_sec_for_args args)
      ~default:Keeper_shell_timeout.io_timeout_sec
      args
  in
  let write_enabled =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some preset -> Keeper_tool_policy.allows_shell_write_for_preset preset
    | None -> false
  in
  if has_typed_bash_input_key args
  then
    handle_tool_execute_typed
      ~turn_sandbox_factory
      ~config
      ~meta
      ~args
      ~timeout_sec
      ~write_enabled
      ()
  else
    error_json
      ~fields:[ "typed", `Bool true ]
      "Typed Shell IR input is required. Provide executable/argv or pipeline."
;;
