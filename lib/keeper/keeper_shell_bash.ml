open Keeper_types
open Keeper_exec_shared

let elapsed_duration_ms ~start_time ~end_time =
  let elapsed_ms = (end_time -. start_time) *. 1000. in
  match classify_float elapsed_ms with
  | FP_nan | FP_infinite -> 0
  | _ when elapsed_ms <= 0. -> 0
  | _ when elapsed_ms < 1. -> 1
  | _ -> int_of_float elapsed_ms

module For_testing = struct
  let elapsed_duration_ms = elapsed_duration_ms
end

module Shell_gate = Masc_exec_command_gate.Shell_command_gate

(* Typed keeper_bash input projections extracted to
   [Keeper_shell_bash_typed_input] (godfile decomp). *)
let has_typed_bash_input_key = Keeper_shell_bash_typed_input.has_typed_bash_input_key
let assoc_upsert = Keeper_shell_bash_typed_input.assoc_upsert
let typed_input_command_text = Keeper_shell_bash_typed_input.typed_input_command_text
let typed_input_has_env = Keeper_shell_bash_typed_input.typed_input_has_env
let typed_validation_error_text = Keeper_shell_bash_typed_input.typed_validation_error_text

let normalize_path_for_keeper_bash_containment path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

(* Backend target helpers for typed Shell IR dispatch. *)
let docker_sandbox_target = Keeper_sandbox_shell_ir_target.docker_target
let docker_runtime_failure_fields =
  Keeper_sandbox_shell_ir_target.docker_runtime_failure_fields
let docker_local_fallback_target =
  Keeper_sandbox_shell_ir_target.docker_local_fallback_target

let handle_keeper_bash_typed
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~timeout_sec
      ~write_enabled
      ()
  =
  let root = Keeper_alerting_path.project_root_of_config config in
  match Keeper_shell_path.resolve_keeper_shell_write_cwd ~config ~meta ~args with
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
        let in_playground = Keeper_shell_path.in_playground ~root ~cwd ~meta in
        let sandbox_profile, _sandbox_network_mode =
          Keeper_sandbox_docker.effective_sandbox_profile ~meta ~in_playground
        in
        let dispatch_sandbox =
          match sandbox_profile with
          | Local -> Ok (Masc_exec.Sandbox_target.host (), [])
          | Docker ->
            if typed_input_has_env input
            then Error "typed Bash Docker Shell IR dispatch does not support env yet"
            else (
              match docker_local_fallback_target ~meta ~timeout_sec with
              | Some fallback when in_playground -> Ok fallback
              | Some _ | None ->
                docker_sandbox_target ~turn_sandbox_factory ~meta ~cwd
                |> Result.map (fun target -> target, []))
        in
        (match dispatch_sandbox with
         | Error e ->
           error_json
             ~fields:[ "typed", `Bool true; "cmd", `String cmd; "cwd", `String cwd ]
             e
         | Ok (dispatch_sandbox, sandbox_extra_fields) ->
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
        let blocked_result ~error ~reason ~alternatives =
          Yojson.Safe.to_string
            (Exec_core.blocked_result_json
               ~classification:(Exec_core.classify_command_of_ir ir)
               ~cmd
               ~error
               ~reason
               ~alternatives
               ~retryability:Exec_core.Operator_required
               ~extra:[ "cmd", `String cmd_for_log; "typed", `Bool true; "execution_time_ms", `Int 0 ]
               ())
        in
        let envelope = Keeper_shell_ir.classify ir in
        let ir_risk = envelope.Masc_exec.Shell_ir_risk.ir in
        let typed_error_json msg = error_json ~fields:typed_error_fields msg in
        if Masc_exec.Shell_ir_risk.is_destructive envelope
        then
          blocked_result
            ~error:"destructive_operation_blocked"
            ~reason:"This typed command is destructive and is blocked for all presets."
            ~alternatives:[ "Use a non-destructive command or a dedicated structured tool." ]
        else if (not write_enabled)
             && (Masc_exec.Shell_ir_risk.is_r1 envelope
                || Masc_exec.Shell_ir_risk.is_r2 envelope)
        then
          blocked_result
            ~error:"write_operation_gated"
            ~reason:"This typed command modifies state. A write-enabled preset is required."
            ~alternatives:
              [ "Use read-only commands such as rg, cat, ls, git status, or git log."
              ; "Ask the operator for a write-enabled preset."
              ]
        else
            let allowed_commands =
              match mode with
              | Keeper_tool_bash_input.Dev_full -> Dev_exec_allowlist.dev
              | Keeper_tool_bash_input.Readonly -> Dev_exec_allowlist.readonly
            in
            let gate_verdict =
              Shell_gate.gate_typed
                ~caller:Shell_gate.Keeper_shell_bash
                ~ir:ir_risk
                ~allowlist:{ allowed_commands; allow_pipes = true; redirect_allowed = true }
                ~path_policy:Shell_gate.allow_all_paths
                ~sandbox:{ target = dispatch_sandbox }
                ()
            in
            Keeper_shell_ir.gate_verdict_map
              gate_verdict
              ~f_reject:(fun diagnostic -> typed_error_json diagnostic)
              ~f_cannot_parse:(typed_error_json "Cannot parse command")
              ~f_too_complex:(typed_error_json "Command too complex")
              ~f_allow:(fun _context ->
                let path_validation =
                  match
                    Keeper_task_worktree_lazy.ensure_shell_ir_existing_dirs
                      ~config ~meta ~cwd ~ir:ir_risk
                  with
                  | Error e -> Error e
                  | Ok () ->
                    Exec_policy.validate_shell_ir_paths
                      ~keeper_id:meta.name
                      ~base_path:root
                      ~workdir:cwd
                      ir_risk
                in
                match path_validation with
                | Error e -> error_json ~fields:[ "blocked_cmd", `String cmd_for_log ] e
                | Ok () ->
                  let env_snap =
                    Cancel_safe.protect
                      ~on_exn:(fun _ -> None)
                      (fun () -> Some (Exec_core.snapshot_env ~cwd))
                  in
                  let t0 = Unix.gettimeofday () in
                  let result =
                    Masc_exec.Exec_dispatch.dispatch_decided envelope
                  in
                  let elapsed_ms =
                    elapsed_duration_ms
                      ~start_time:t0
                      ~end_time:(Unix.gettimeofday ())
                  in
                  Log.Keeper.info
                    "keeper_bash shell_ir_dispatch keeper=%s sandbox=%s status=%s elapsed_ms=%d"
                    meta.name
                    (Keeper_types.sandbox_profile_to_string sandbox_profile)
                    (Keeper_sandbox_exec_failure.status_label result.status)
                    elapsed_ms;
                  let output =
                    if String.equal result.stderr ""
                    then result.stdout
                    else result.stdout ^ result.stderr
                  in
                  let runtime_failure_fields =
                    docker_runtime_failure_fields output
                  in
                  Yojson.Safe.to_string
                    (Exec_core.process_result_json
                       ~classification:(Exec_core.classify_command_of_ir ir)
                       ~base_path:root
                       ~keeper_name:meta.name
                       ~cmd
                       ~extra:
                         (runtime_failure_fields
                          @ sandbox_extra_fields
                          @ [ "cwd", `String cwd
                            ; "typed", `Bool true
                            ; "execution_time_ms", `Int elapsed_ms
                            ; "timeout_sec", `Float timeout_sec
                            ])
                       ~status:result.status
                       ~output
                       ~env_snapshot:env_snap
                       ())))

let handle_keeper_bash
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~turn_sandbox_factory_git:_
      ~exec_cache:_
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ()
  =
  let timeout_sec =
    Keeper_shell_shared.clamp_shell_timeout
      ~min_sec:(Keeper_shell_shared.keeper_bash_min_timeout_sec_for_args args)
      ~default:Keeper_shell_shared.io_timeout_sec
      args
  in
  let write_enabled =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some preset -> Keeper_tool_policy.allows_shell_write_for_preset preset
    | None -> false
  in
  if has_typed_bash_input_key args
  then
    handle_keeper_bash_typed
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
      "Typed Bash input is required. Provide executable/argv or pipeline/stages."
;;
