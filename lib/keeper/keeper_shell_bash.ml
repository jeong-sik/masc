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

let typed_docker_image (meta : keeper_meta) =
  match meta.sandbox_image with
  | Some img when String.trim img <> "" -> img
  | _ -> Env_config_keeper.KeeperSandbox.docker_image ()

let typed_docker_sandbox_target ~turn_sandbox_factory ~meta ~cwd =
  match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
  | None ->
    Error
      "typed keeper_bash Docker Shell IR dispatch requires a turn sandbox factory"
  | Some runtime ->
    let image = typed_docker_image meta in
    let runner ~stdin_content ~argv ~env:_ ~cwd:stage_cwd ~timeout_sec =
      let cwd = Option.value stage_cwd ~default:cwd in
      match
        Keeper_turn_sandbox_runtime.run_exec_with_status
          ?stdin_content
          runtime
          ~timeout_sec
          ~cwd
          ~command_argv:argv
      with
      | Ok (status, output) -> status, output, ""
      | Error err -> Unix.WEXITED 1, "", err
    in
    Ok (Masc_exec.Sandbox_target.docker ~image ~runner)

let typed_docker_runtime_failure_fields output =
  if String_util.contains_substring output "sandbox_image_missing"
  then [ "failure_class", `String "policy_rejection" ]
  else []

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
  match Keeper_shell_shared.resolve_keeper_shell_write_cwd ~config ~meta ~args with
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
        let cmd_for_log =
          cmd
          |> Worker_dev_tools.sanitize_command_for_log
          |> Worker_dev_tools.truncate_for_log
        in
        let mode =
          if write_enabled
          then Keeper_tool_bash_input.Dev_full
          else Keeper_tool_bash_input.Readonly
        in
        let in_playground =
          let cwd_canonical = normalize_path_for_keeper_bash_containment cwd in
          let playground_rel = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
          let playground_abs =
            normalize_path_for_keeper_bash_containment
              (Filename.concat root playground_rel)
          in
          String.starts_with ~prefix:(playground_abs ^ "/") (cwd_canonical ^ "/")
          || String.equal playground_abs cwd_canonical
        in
        let sandbox_profile, _sandbox_network_mode =
          Keeper_shell_shared.effective_sandbox_profile ~meta ~in_playground
        in
        let dispatch_sandbox =
          match sandbox_profile with
          | Local -> Ok (Masc_exec.Sandbox_target.host ())
          | Docker ->
            if typed_input_has_env input
            then Error "typed keeper_bash Docker Shell IR dispatch does not support env yet"
            else typed_docker_sandbox_target ~turn_sandbox_factory ~meta ~cwd
        in
        (match dispatch_sandbox with
         | Error e ->
           error_json
             ~fields:[ "typed", `Bool true; "cmd", `String cmd_for_log; "cwd", `String cwd ]
             e
         | Ok dispatch_sandbox ->
        if Worker_dev_tools.is_destructive_bash_operation cmd
        then
          Yojson.Safe.to_string
            (Exec_core.blocked_result_json
               ~cmd
               ~error:"destructive_operation_blocked"
               ~reason:
                 "This typed command is destructive and is blocked for all presets."
               ~alternatives:[ "Use a non-destructive command or a dedicated structured tool." ]
               ~retryability:Exec_core.Operator_required
               ~extra:[ "cmd", `String cmd_for_log; "typed", `Bool true; "execution_time_ms", `Int 0 ]
               ())
        else if (not write_enabled) && Worker_dev_tools.is_write_operation cmd
        then
          Yojson.Safe.to_string
            (Exec_core.blocked_result_json
               ~cmd
               ~error:"write_operation_gated"
               ~reason:
                 "This typed command modifies state. A write-enabled preset is required."
               ~alternatives:
                 [ "Use read-only commands such as rg, cat, ls, git status, or git log."
                 ; "Ask the operator for a write-enabled preset."
                 ]
               ~retryability:Exec_core.Operator_required
               ~extra:[ "cmd", `String cmd_for_log; "typed", `Bool true; "execution_time_ms", `Int 0 ]
               ())
        else
          match Keeper_tool_bash_input.to_shell_ir ~mode ~sandbox:dispatch_sandbox input with
          | Error e ->
            error_json
              ~fields:[ "typed", `Bool true; "cmd", `String cmd_for_log; "cwd", `String cwd ]
              (typed_validation_error_text e)
          | Ok ir ->
            let path_validation =
              match
                Keeper_task_worktree_lazy.ensure_command_existing_dirs
                  ~config ~meta ~cwd ~cmd
              with
              | Error e -> Error e
              | Ok () ->
                Worker_dev_tools.validate_command_paths
                  ~keeper_id:meta.name
                  ~base_path:root
                  ~workdir:cwd
                  cmd
            in
            (match path_validation with
             | Error e -> error_json ~fields:[ "blocked_cmd", `String cmd_for_log ] e
             | Ok () ->
               let env_snap =
                 Cancel_safe.protect
                   ~on_exn:(fun _ -> None)
                   (fun () -> Some (Exec_core.snapshot_env ~cwd))
               in
               let t0 = Unix.gettimeofday () in
               let result = Masc_exec.Exec_dispatch.dispatch ir in
               let elapsed_ms =
                 elapsed_duration_ms
                   ~start_time:t0
                   ~end_time:(Unix.gettimeofday ())
               in
               let output =
                 if String.equal result.stderr ""
                 then result.stdout
                 else result.stdout ^ result.stderr
               in
               let runtime_failure_fields =
                 typed_docker_runtime_failure_fields output
               in
               Yojson.Safe.to_string
                 (Exec_core.process_result_json
                    ~base_path:root
                    ~keeper_name:meta.name
                    ~cmd
                    ~extra:
                      (runtime_failure_fields
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
      ~min_sec:Keeper_shell_shared.keeper_bash_native_min_timeout_sec
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
      "typed keeper_bash input is required. Provide executable/argv or pipeline/stages."
;;
