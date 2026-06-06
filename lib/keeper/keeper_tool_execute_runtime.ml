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

type git_worktree_branch_conflict =
  { branch : string
  ; worktree_path : string
  }

let substring_index_from haystack needle start =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0
  then Some start
  else if start < 0 || start > haystack_len
  then None
  else
    let rec loop index =
      if index + needle_len > haystack_len
      then None
      else if String.equal (String.sub haystack index needle_len) needle
      then Some index
      else loop (index + 1)
    in
    loop start
;;

let git_worktree_branch_conflict_of_line line =
  let prefix = "fatal: '" in
  let marker = "' is already used by worktree at '" in
  match substring_index_from line prefix 0 with
  | None -> None
  | Some prefix_index ->
    let branch_start = prefix_index + String.length prefix in
    (match substring_index_from line marker branch_start with
     | None -> None
     | Some marker_index ->
       let path_start = marker_index + String.length marker in
       (match String.index_from_opt line path_start '\'' with
        | None -> None
        | Some path_end ->
          let branch =
            String.sub line branch_start (marker_index - branch_start)
            |> String.trim
          in
          let worktree_path =
            String.sub line path_start (path_end - path_start) |> String.trim
          in
          if String.equal branch "" || String.equal worktree_path ""
          then None
          else Some { branch; worktree_path }))
;;

let git_worktree_branch_conflict stderr =
  stderr
  |> String.split_on_char '\n'
  |> List.find_map git_worktree_branch_conflict_of_line
;;

let git_global_option_takes_value = function
  | "-C"
  | "-c"
  | "--exec-path"
  | "--git-dir"
  | "--work-tree"
  | "--namespace"
  | "--super-prefix"
  | "--config-env" -> true
  | _ -> false

let git_global_option_has_inline_value token =
  String.starts_with ~prefix:"-C" token && String.length token > 2
  || String.starts_with ~prefix:"--exec-path=" token
  || String.starts_with ~prefix:"--git-dir=" token
  || String.starts_with ~prefix:"--work-tree=" token
  || String.starts_with ~prefix:"--namespace=" token
  || String.starts_with ~prefix:"--super-prefix=" token
  || String.starts_with ~prefix:"--config-env=" token

let rec git_subcommand_args = function
  | [] -> []
  | token :: rest when git_global_option_takes_value token ->
    (match rest with
     | _value :: tail -> git_subcommand_args tail
     | [] -> [])
  | token :: rest when git_global_option_has_inline_value token ->
    git_subcommand_args rest
  | token :: rest when String.starts_with ~prefix:"-" token ->
    git_subcommand_args rest
  | rest -> rest

let ir_is_git_worktree_add ir =
  match Masc_exec.Shell_ir_command_shape.effective_stages ir with
  | [ stage ]
    when String.equal
           (Masc_exec.Shell_ir_command_shape.normalize_command_name stage.bin)
           "git" ->
    (match git_subcommand_args stage.args with
     | "worktree" :: "add" :: _ -> true
     | _ -> false)
  | _ -> false

let idempotent_worktree_add_reuse ir status stderr =
  match status, git_worktree_branch_conflict stderr with
  | Unix.WEXITED 128, Some conflict when ir_is_git_worktree_add ir ->
    Some conflict
  | _ -> None

let git_worktree_reuse_fields { branch; worktree_path } =
  let recovery_hint =
    Printf.sprintf
      "Branch %S is already checked out by an existing worktree. The worktree \
       add request was treated as idempotent; continue with cwd=%S."
      branch
      worktree_path
  in
  [ "git_worktree_branch_already_used", `Bool true
  ; "worktree_reused", `Bool true
  ; "branch", `String branch
  ; "existing_worktree_path", `String worktree_path
  ; "reuse_cwd", `String worktree_path
  ; "recovery_hint", `String recovery_hint
  ; ( "alternatives"
    , `List
        [ `String (Printf.sprintf "Set cwd to %s and continue there." worktree_path)
        ; `String "Choose a unique branch/worktree name only when a separate lane is required."
        ] )
  ]

let git_worktree_reuse_output { branch; worktree_path } =
  Printf.sprintf
    "Worktree already exists: %s\nBranch already checked out: %s\nUse cwd=%S \
     for follow-up Execute calls.\n"
    worktree_path
    branch
    worktree_path

(* Pre-dispatch path existence validation for typed commands.
   Uses Shell_ir_typed GADT path annotations (exhaustive, no
   string heuristics). Only validates Safe (read-only) Simple
   commands where path non-existence is a predictable pre-condition
   failure. Pipeline path validation is deferred. *)
let pre_dispatch_path_missing ~cwd ir =
  match ir with
  | Masc_exec.Shell_ir.Simple s ->
    let typed = Masc_exec.Shell_ir_typed.of_simple s in
    (match Masc_exec.Shell_ir_typed.risk typed with
     | `Safe ->
       let args = Masc_exec.Shell_ir_typed.path_args typed in
       List.find_opt (fun p ->
         let resolved =
           if Filename.is_relative p then Filename.concat cwd p else p
         in
         try not (Sys.file_exists resolved) with _ -> true
       ) args
     | `Audited | `Privileged -> None)
  | Masc_exec.Shell_ir.Pipeline _ -> None
;;

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

module For_testing = struct
  let elapsed_duration_ms = elapsed_duration_ms
  let typed_execute_response_cwd_json = typed_execute_response_cwd_json
end

(* Typed Execute input projections extracted to
   [Keeper_tool_execute_input] (godfile decomp). *)
let has_typed_execute_input_key = Keeper_tool_execute_input.has_typed_execute_input_key
let assoc_upsert = Keeper_tool_execute_input.assoc_upsert
let typed_input_command_text = Keeper_tool_execute_input.typed_input_command_text
let typed_input_has_env = Keeper_tool_execute_input.typed_input_has_env
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
      { executable; argv; cwd = _; env; stdin; stdout; stderr } ->
    Keeper_tool_execute_typed_input.Exec
      { executable
      ; argv
      ; cwd = Some cwd
      ; env
      ; stdin
      ; stdout
      ; stderr
      }
  | Keeper_tool_execute_typed_input.Pipeline { stages; cwd = _; env } ->
    Keeper_tool_execute_typed_input.Pipeline { stages; cwd = Some cwd; env }

let typed_input_shell_ir_unvalidated ~mode input =
  match Keeper_tool_execute_typed_input.to_shell_ir_unvalidated ~mode input with
  | Error _ -> None
  | Ok ir -> Some ir

let resolve_typed_git_cwd ~config ~meta ~cwd ~cmd = function
  | None -> cwd, None
  | Some ir ->
    Keeper_tool_execute_command_semantics.resolve_sandbox_root_git_cwd
      ~config
      ~meta
      ~cwd
      ~cmd
      ir

let handle_tool_execute_typed
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~timeout_sec
      ~write_enabled
      ()
  =
  let root = Keeper_alerting_path.project_root_of_config config in
  let execute_cwd_policy =
    if write_enabled
    then Keeper_tool_execute_path.Write_enabled_execute_cwd
    else Keeper_tool_execute_path.Readonly_execute_cwd
  in
  match
    Keeper_tool_execute_path.resolve_tool_execute_cwd
      ~policy:execute_cwd_policy
      ~config
      ~meta
      ~args
  with
    | Error e -> error_json e
    | Ok cwd ->
        let execution_location_fields cwd =
          [ ( "execution_location"
            , Keeper_sandbox_repo_path.execution_location_json ~config ~meta ~args ~cwd )
          ]
      in
      let typed_args = assoc_upsert "cwd" (`String cwd) args in
      match Keeper_tool_execute_typed_input.of_json typed_args with
      | Error e ->
        error_json
          ~fields:
            ([ "typed", `Bool true; "cwd", `String cwd ]
             @ execution_location_fields cwd)
          e
      | Ok input ->
        let cmd = typed_input_command_text input in
        let mode =
          if write_enabled
          then Keeper_tool_execute_typed_input.Dev_full
          else Keeper_tool_execute_typed_input.Readonly
        in
        let input_ir = typed_input_shell_ir_unvalidated ~mode input in
        let cwd, root_git_cwd_error =
          resolve_typed_git_cwd
            ~config
            ~meta
            ~cwd
            ~cmd
            input_ir
        in
        let root_git_cwd_error =
          match root_git_cwd_error with
          | Some e -> Some e
          | None ->
            Option.bind input_ir Keeper_tool_execute_command_semantics.misuse_error
        in
        let input = input_with_cwd cwd input in
        let in_playground = Keeper_tool_execute_path.in_playground ~root ~cwd ~meta in
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
                @ execution_location_fields cwd
                @ fields)
             message
         | Ok (dispatch_sandbox, sandbox_extra_fields) ->
        let response_cwd_json =
          typed_execute_response_cwd_json
            ~turn_sandbox_factory
            ~cwd
            ~sandbox_extra_fields
        in
        let response_cwd_field = [ "cwd", response_cwd_json ] in
        match root_git_cwd_error with
        | Some e ->
          error_json
            ~fields:
              ([ "typed", `Bool true; "cmd", `String cmd ]
               @ response_cwd_field
               @ execution_location_fields cwd)
            e
        | None ->
        (* RFC-0160 S1: lower-then-classify. Typed argv → Shell IR
           once, then both mutation classifiers consume the same IR.
           This removes the previous double-parse (mutation classifier
           re-tokenized cmd:string via the legacy string tokenizer before IR
           was even built). *)
        match Keeper_tool_execute_typed_input.to_shell_ir ~mode ~sandbox:dispatch_sandbox input with
        | Error e ->
          let alts = Keeper_tool_execute_typed_input.validation_error_alternatives e in
          let fields =
            [ "typed", `Bool true; "cmd", `String cmd ]
            @ response_cwd_field
            @ execution_location_fields cwd
            @
            (match alts with
             | [] -> []
             | _ -> [ "alternatives", `List (List.map (fun s -> `String s) alts) ])
          in
          error_json ~fields (typed_validation_error_text e)
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
        let blocked_result ?deterministic_reason ~error ~reason ~alternatives () =
          (* RFC-0208 P1: a blocked typed command emits a Keeper-level audit
             line so denials are greppable, not only returned as tool_error
             JSON to the agent. Covers destructive-block and write-gate; the
             [error] code distinguishes them. *)
          Log.Keeper.warn
            "shell_ir blocked keeper=%s error=%s reason=%s typed_hit=%b cmd=%s"
            meta.name
            error
            (message_for_log reason)
            (Masc_exec.Shell_ir_risk.typed_hit_of_ir ir)
            cmd_for_log;
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
                    ]
                  @ response_cwd_field
                  @ execution_location_fields cwd)
               ())
        in
        let envelope = Keeper_tool_execute_shell_ir.classify ir in
        let typed_error_json msg = error_json ~fields:typed_error_fields msg in
        if Masc_exec.Shell_ir_risk.is_destructive envelope
        then
          blocked_result
            ~deterministic_reason:
              Keeper_tool_deterministic_error.Destructive_operation_blocked
            ~error:"destructive_operation_blocked"
            ~reason:"This typed command is destructive and is blocked for every keeper execution surface."
            ~alternatives:[ "Use a non-destructive command or a dedicated structured tool." ]
            ()
        else
        let repo_cwd_context =
          Keeper_sandbox_repo_path.classify_cwd ~config ~meta ~cwd
        in
        let is_direct_sandbox_repo_root =
          match repo_cwd_context with
          | Some { Keeper_sandbox_repo_path.is_direct_root = true; _ } -> true
          | Some _ | None -> false
        in
        let is_git_diagnostic_command =
          Masc_exec.Shell_ir_command_shape.is_git_diagnostic_command ir
        in
        let is_git_recovery_command =
          Masc_exec.Shell_ir_command_shape.is_git_recovery_command ir
        in
        let is_direct_repo_git_recovery =
          is_direct_sandbox_repo_root && is_git_recovery_command
        in
        let readonly_write_like =
          is_git_recovery_command
          || Masc_exec.Shell_ir_risk.is_r1 envelope
          || Masc_exec.Shell_ir_risk.is_r2 envelope
        in
        if
          (not write_enabled)
          && readonly_write_like
          && not is_git_diagnostic_command
          && not is_direct_repo_git_recovery
        then
          blocked_result
            ~deterministic_reason:Keeper_tool_deterministic_error.Write_operation_gated
            ~error:"write_operation_gated"
            ~reason:"This typed command modifies state. A write-capable Execute surface is required."
            ~alternatives:
              [ "Use read-only commands such as rg, cat, ls, git status, or git log."
              ; "Ask the operator for a write-capable Execute candidate profile and matching runtime policy."
              ]
            ()
        else
        let path_missing = pre_dispatch_path_missing ~cwd ir in
        if Option.is_some path_missing
        then
          let missing_path = Option.get path_missing in
          let parent = Filename.dirname missing_path in
          blocked_result
            ~deterministic_reason:Keeper_tool_deterministic_error.Path_not_found
            ~error:"path_not_found"
            ~reason:(Printf.sprintf
              "The path argument %S does not exist. Probe the parent \
               directory before retrying; do not infer package or module \
               names as directory paths."
              missing_path)
            ~alternatives:
              [ Printf.sprintf "Use executable=\"ls\" argv=[%S]." parent ]
            ()
        else
          let allowed_commands =
            match mode with
            | Keeper_tool_execute_typed_input.Dev_full -> Exec_policy.dev_allowed_commands
            | Keeper_tool_execute_typed_input.Readonly -> Exec_policy.readonly_allowed_commands

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
            Keeper_tool_execute_shell_ir.dispatch_classified
              ~allowed_commands
              ~keeper_id:meta.name
              ~base_path:root
              ~workdir:cwd
              ~sandbox:dispatch_sandbox
              envelope
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
          | Error Keeper_tool_execute_shell_ir.Cannot_parse -> typed_error_json "Cannot parse command"
          | Error Keeper_tool_execute_shell_ir.Too_complex -> typed_error_json "Command too complex"
          | Error (Keeper_tool_execute_shell_ir.Path_reject e) ->
            (* RFC-0208 P1: path-policy denial audit line. *)
            Log.Keeper.warn
              "shell_ir path_reject keeper=%s cmd=%s reason=%s"
              meta.name
              cmd_for_log
              (message_for_log e);
            error_json
              ~fields:(("blocked_cmd", `String cmd_for_log) :: typed_error_fields)
              e
          | Ok result ->
            let elapsed_ms =
              (* NDT-OK: second wall-clock read closes the elapsed telemetry
                 span recorded immediately below. *)
              elapsed_duration_ms ~start_time:t0 ~end_time:(Unix.gettimeofday ())
            in
            (* RFC-0208 P1: risk_class + typed_hit make the typed-coverage
               of live traffic observable. An offline scan of typed_hit=true
               / total gives the real exercise rate of the typed model vs the
               Generic escape hatch. *)
            Log.Keeper.info
              "shell_ir dispatch keeper=%s sandbox=%s status=%s elapsed_ms=%d risk_class=%s typed_hit=%b"
              meta.name
              (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox_profile)
              (Keeper_sandbox_exec_failure.status_label result.status)
              elapsed_ms
              (Masc_exec.Shell_ir_risk.string_of_risk_class
                 (Masc_exec.Shell_ir_risk.risk_class envelope))
              (Masc_exec.Shell_ir_risk.typed_hit_of_ir ir);
            let output =
              if String.equal result.stderr ""
              then result.stdout
              else result.stdout ^ result.stderr
            in
            let failure_error_fields =
              match result.status, String.trim result.stderr with
              | Unix.WEXITED 0, _ | _, "" -> []
              | _, stderr -> [ "error", `String stderr; "stderr", `String stderr ]
            in
            let glob_literal_failure_fields =
              Masc_exec.Shell_ir_diagnostics.glob_literal_failure_fields
                ~ir
                ~status:result.status
                ~stderr:result.stderr
            in
            let classification = Exec_core.classify_command_of_ir ir in
            let worktree_reuse = idempotent_worktree_add_reuse ir result.status result.stderr in
            (* Only include command_descriptor on success — errors already carry
               sufficient diagnostic info (exit code, stderr, classification). *)
            let descriptor_fields =
              match result.status, worktree_reuse with
              | Unix.WEXITED 0, _ | _, Some _ ->
                let descriptor = Ide_command_descriptor.compute ir in
                [ "command_descriptor", Ide_event_types.command_descriptor_to_json descriptor ]
              | _, None -> []
            in
            let status, output, worktree_reuse_fields =
              match worktree_reuse with
              | None -> result.status, output, []
              | Some conflict ->
                Log.Keeper.info
                  "shell_ir worktree_reuse keeper=%s branch=%s existing_worktree=%s"
                  meta.name
                  conflict.branch
                  conflict.worktree_path;
                ( Unix.WEXITED 0
                , git_worktree_reuse_output conflict
                , git_worktree_reuse_fields conflict )
            in
            let failure_error_fields =
              match worktree_reuse with
              | Some _ -> []
              | None -> failure_error_fields
            in
            Yojson.Safe.to_string
              (Exec_core.process_result_json
                 ~classification
                 ~base_path:root
                 ~keeper_name:meta.name
                 ~cmd
                 ~extra:
                   (worktree_reuse_fields
                    @ failure_error_fields
                    @ glob_literal_failure_fields
                    @ sandbox_extra_fields
                    @ [ "typed", `Bool true
                      ; "execution_time_ms", `Int elapsed_ms
                      ; "timeout_sec", `Float timeout_sec
                      ]
                    @ response_cwd_field
                    @ descriptor_fields
                    @ execution_location_fields cwd)
                 ~status
                 ~output
                 ~env_snapshot:env_snap
                 ()))

let handle_tool_execute
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~exec_cache:_
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ()
  =
  let execute_write_surface_enabled names =
    let is_write_enabled_candidate = function
      | "tool_edit_file" | "tool_write_file" | "tool_execute" -> true
      | _ -> false
    in
    names
    |> Keeper_meta_contract.normalize_tool_names
    |> List.exists is_write_enabled_candidate
  in
  let timeout_sec =
    Keeper_tool_execute_timeout.clamp_shell_timeout
      ~min_sec:(Keeper_tool_execute_timeout.keeper_tool_execute_shell_ir_min_timeout_sec_for_args args)
      ~default:Keeper_tool_execute_timeout.io_timeout_sec
      args
  in
  let write_enabled = execute_write_surface_enabled meta.tool_access in
  if has_typed_execute_input_key args
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
