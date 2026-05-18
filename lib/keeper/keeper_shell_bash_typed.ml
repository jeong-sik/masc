open Keeper_types
open Keeper_exec_shared

let elapsed_duration_ms ~start_time ~end_time =
  let elapsed_ms = (end_time -. start_time) *. 1000. in
  match classify_float elapsed_ms with
  | FP_nan | FP_infinite -> 0
  | _ when elapsed_ms <= 0. -> 0
  | _ when elapsed_ms < 1. -> 1
  | _ -> int_of_float elapsed_ms

let has_typed_bash_input_key = function
  | `Assoc fields ->
    List.exists
      (fun (key, _) ->
         String.equal key "executable"
         || String.equal key "pipeline"
         || String.equal key "stages")
      fields
  | _ -> false

let assoc_upsert key value = function
  | `Assoc fields ->
    `Assoc ((key, value) :: List.filter (fun (k, _) -> not (String.equal k key)) fields)
  | other -> other

let shell_quote_for_policy token =
  let safe_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '.' | '/' | ':' | '=' | ',' ->
      true
    | _ -> false
  in
  if String.length token > 0 && String.for_all safe_char token
  then token
  else
    let parts = String.split_on_char '\'' token in
    "'" ^ String.concat "'\\''" parts ^ "'"

let typed_stage_command_text ~executable ~argv =
  executable :: argv
  |> List.map shell_quote_for_policy
  |> String.concat " "

let typed_input_command_text = function
  | Keeper_tool_bash_input.Exec { executable; argv; _ } ->
    typed_stage_command_text ~executable ~argv
  | Keeper_tool_bash_input.Pipeline { stages; _ } ->
    stages
    |> List.map (fun (stage : Keeper_tool_bash_input.exec_stage) ->
      typed_stage_command_text ~executable:stage.executable ~argv:stage.argv)
    |> String.concat " | "

let typed_validation_error_text error =
  Format.asprintf "%a" Keeper_tool_bash_input.pp_validation_error error

let normalize_path_for_keeper_bash_containment path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let handle
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~timeout_sec
      ~run_in_background
      ~write_enabled
      ()
  =
  ignore turn_sandbox_factory;
  let root = Keeper_alerting_path.project_root_of_config config in
  if run_in_background
  then
    error_json
      ~fields:[ "typed", `Bool true ]
      "typed keeper_bash does not support run_in_background yet; use legacy cmd or foreground typed exec"
  else if meta.sandbox_profile = Docker
  then
    error_json
      ~fields:[ "typed", `Bool true ]
      "typed keeper_bash Shell IR dispatch for Docker is not enabled yet; use legacy cmd until the Docker runner carries stdin/cwd through pipeline stages"
  else
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
        if sandbox_profile = Docker
        then
          error_json
            ~fields:[ "typed", `Bool true; "cmd", `String cmd_for_log; "cwd", `String cwd ]
            "typed keeper_bash Shell IR dispatch for Docker is not enabled yet; use legacy cmd until the Docker runner carries stdin/cwd through pipeline stages"
        else if Worker_dev_tools.is_destructive_bash_operation cmd
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
          match Keeper_tool_bash_input.to_shell_ir ~mode input with
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
               Yojson.Safe.to_string
                 (Exec_core.process_result_json
                    ~base_path:root
                    ~keeper_name:meta.name
                    ~cmd
                    ~extra:
                      [ "cwd", `String cwd
                      ; "typed", `Bool true
                      ; "execution_time_ms", `Int elapsed_ms
                      ; "timeout_sec", `Float timeout_sec
                      ]
                    ~status:result.status
                    ~output
                    ~env_snapshot:env_snap
                    ()))
