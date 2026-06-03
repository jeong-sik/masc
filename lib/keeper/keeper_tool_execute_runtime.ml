open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

(** {1 Rest field parsing helpers}

    The [rest : string list] field in GADT constructors captures arguments
    that the typed IR doesn't model. These helpers extract structured data
    from [rest] robustly, handling eq-form (--flag=VALUE), space-form
    (--flag VALUE), and short flags (-f VALUE). *)

(** Extract a flag value from a string list.
    Handles: ["--base"; "main"], ["--base=main"], ["-b"; "main"]
    Returns [default] if flag not found. *)
let extract_flag_from_rest (rest : string list) ~(flag : string) ~(short : string option) ~(default : string) : string =
  let flag_eq = flag ^ "=" in
  let rec scan = function
    | [] -> default
    | arg :: value :: _ when String.equal arg flag -> value
    | arg :: _ when String.length arg > String.length flag_eq
        && String.sub arg 0 (String.length flag_eq) = flag_eq ->
      String.sub arg (String.length flag_eq) (String.length arg - String.length flag_eq)
    | arg :: value :: _ when (match short with Some s -> String.equal arg s | None -> false) -> value
    | _ :: rest -> scan rest
  in
  scan rest
;;

(** Extract the first numeric argument from a string list.
    Used for PR/issue numbers. Returns [0] if not found. *)
let extract_number_from_rest (rest : string list) : int =
  let rec scan = function
    | [] -> 0
    | s :: _ when (match int_of_string_opt s with Some n -> n > 0 | None -> false) ->
      (match int_of_string_opt s with Some n -> n | None -> 0)
    | _ :: rest -> scan rest
  in
  scan rest
;;

(** Compute a structured command descriptor from Shell IR.
    Used by the IDE bridge for deterministic PR/issue event detection. *)
let compute_command_descriptor (ir : Masc_exec.Shell_ir.t) : Ide_event_types.command_descriptor =
  match ir with
  | Masc_exec.Shell_ir.Simple simple ->
    (match Masc_exec.Shell_ir_typed.of_simple simple with
     | Masc_exec.Shell_ir_typed_types.W (Masc_exec.Shell_ir_typed_types.Gh { subcommand; action; title; draft; squash; delete_branch; body; rest }) ->
       (match subcommand, action with
        (* PR operations *)
        | "pr", Some "create" ->
          let base = extract_flag_from_rest rest ~flag:"--base" ~short:(Some "-b") ~default:"main" in
          Gh_pr_create { title = Option.value title ~default:""; base; draft }
        | "pr", Some "merge" ->
          Gh_pr_merge { pr_number = extract_number_from_rest rest; squash }
        | "pr", Some "comment" ->
          Gh_pr_comment { pr_number = extract_number_from_rest rest; body = Option.value body ~default:"" }
        | "pr", Some "close" ->
          Gh_pr_close { pr_number = extract_number_from_rest rest }
        | "pr", Some "edit" ->
          Gh_pr_edit { pr_number = extract_number_from_rest rest; title }
        | "pr", Some "review" ->
          Gh_pr_review { pr_number = extract_number_from_rest rest }
        | "pr", Some "reopen" ->
          Gh_pr_close { pr_number = extract_number_from_rest rest } (* reopen uses same structure *)
        | "pr", Some "ready" ->
          Gh_pr_review { pr_number = extract_number_from_rest rest }
        (* Issue operations *)
        | "issue", Some "create" ->
          Gh_issue_create { title = Option.value title ~default:""; body = Option.value body ~default:"" }
        | "issue", Some "close" ->
          Gh_issue_close { issue_number = extract_number_from_rest rest }
        | "issue", Some "reopen" ->
          Gh_issue_close { issue_number = extract_number_from_rest rest }
        (* Unknown gh subcommand *)
        | _ -> Generic)
     | Masc_exec.Shell_ir_typed_types.W (Masc_exec.Shell_ir_typed_types.Git_push { force; force_with_lease; set_upstream = _; remote; branch }) ->
       Git_push {
         remote = Option.value remote ~default:"origin";
         branch = Option.value branch ~default:"main";
         force = force || force_with_lease
       }
     | Masc_exec.Shell_ir_typed_types.W (Masc_exec.Shell_ir_typed_types.Git_commit { message; amend }) ->
       Git_commit { message = if amend then message ^ " (amend)" else message }
     | Masc_exec.Shell_ir_typed_types.W (Masc_exec.Shell_ir_typed_types.Git_merge { squash; branch; _ }) ->
       Gh_pr_merge { pr_number = 0; squash } (* git merge is analogous to pr merge *)
     | _ -> Generic)
  | _ -> Generic

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
  let compute_command_descriptor = compute_command_descriptor
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

let typed_input_effective_stages ~mode input =
  match Keeper_tool_execute_typed_input.to_shell_ir_unvalidated ~mode input with
  | Error _ -> []
  | Ok ir ->
    Keeper_tool_execute_command_semantics.effective_stages_of_ir ir

let resolve_typed_git_cwd_of_stages ~config ~meta ~cwd ~cmd stages =
    Keeper_tool_execute_command_semantics.resolve_sandbox_root_git_cwd_of_stages
      ~config
      ~meta
      ~cwd
      ~cmd
      stages

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
  match Keeper_tool_execute_path.resolve_tool_write_cwd ~config ~meta ~args with
    | Error e -> error_json e
    | Ok cwd ->
      let execution_location_fields cwd =
        [ ( "execution_location"
          , Keeper_tool_execute_path.execution_location_json ~config ~meta ~args ~cwd )
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
        let effective_stages = typed_input_effective_stages ~mode input in
        let cwd, root_git_cwd_error =
          resolve_typed_git_cwd_of_stages
            ~config
            ~meta
            ~cwd
            ~cmd
            effective_stages
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
        match root_git_cwd_error with
        | Some e ->
          error_json
            ~fields:
              ([ "typed", `Bool true; "cmd", `String cmd; "cwd", `String cwd ]
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
            [ "typed", `Bool true; "cmd", `String cmd; "cwd", `String cwd ]
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
          [ "typed", `Bool true; "cmd", `String cmd_for_log; "cwd", `String cwd ]
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
                    ; "cwd", `String cwd
                    ; "typed", `Bool true
                    ; "execution_time_ms", `Int 0
                    ]
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
            ~reason:"This typed command is destructive and is blocked for all tool_access lists."
            ~alternatives:[ "Use a non-destructive command or a dedicated structured tool." ]
            ()
        else if (not write_enabled)
             && (Masc_exec.Shell_ir_risk.is_r1 envelope
                || Masc_exec.Shell_ir_risk.is_r2 envelope)
        then
          blocked_result
            ~deterministic_reason:Keeper_tool_deterministic_error.Write_operation_gated
            ~error:"write_operation_gated"
            ~reason:"This typed command modifies state. Write-enabled tool_access is required."
            ~alternatives:
              [ "Use read-only commands such as rg, cat, ls, git status, or git log."
              ; "Ask the operator for write-enabled tool_access."
              ]
            ()
        else
          let allowed_commands =
            match mode with
            | Keeper_tool_execute_typed_input.Dev_full -> Dev_exec_allowlist.dev
            | Keeper_tool_execute_typed_input.Readonly -> Dev_exec_allowlist.readonly
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
              ~before_path_validation:(fun ir ->
                Keeper_tool_execute_path.validate_repo_path_args_ready
                  ~config
                  ~meta
                  ~cwd
                  ir)
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
            let classification = Exec_core.classify_command_of_ir ir in
            let deterministic_retry_fields =
              deterministic_retry_fields_for_process_result
                ~classification
                ~status:result.status
            in
            let descriptor = compute_command_descriptor ir in
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
                      ; "command_descriptor", Ide_event_types.command_descriptor_to_json descriptor
                      ]
                    @ execution_location_fields cwd)
                 ~status:result.status
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
  let timeout_sec =
    Keeper_tool_execute_timeout.clamp_shell_timeout
      ~min_sec:(Keeper_tool_execute_timeout.keeper_tool_execute_shell_ir_min_timeout_sec_for_args args)
      ~default:Keeper_tool_execute_timeout.io_timeout_sec
      args
  in
  let write_enabled =
    List.exists
      (fun n -> n = "tool_edit_file" || n = "tool_write_file")
      meta.tool_access
  in
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
