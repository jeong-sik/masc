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

let typed_validation_deterministic_retry_fields
      (_ : Keeper_tool_execute_typed_input.validation_error)
  =
  Keeper_tool_deterministic_error.deterministic_retry_fields
    Keeper_tool_deterministic_error.Command_shape_blocked

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

let typed_input_shell_ir_unvalidated input =
  match Keeper_tool_execute_typed_input.to_shell_ir_unvalidated input with
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
      ()
  =
  let root = Keeper_alerting_path.project_root_of_config config in
  match
    Keeper_tool_execute_path.resolve_tool_execute_cwd
      ~config
      ~meta
      (* Keep all keepers on the shared execute-worktree root; command-level
         permission remains the Shell IR gate, not per-keeper tool_access. *)
      ~write_enabled:true
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
        (match Keeper_tool_execute_typed_input.validate input with
         | Error e ->
           let alts =
             Keeper_tool_execute_typed_input.validation_error_alternatives e
           in
           let fields =
             [ "typed", `Bool true; "cwd", `String cwd ]
             @ execution_location_fields cwd
             @ typed_validation_deterministic_retry_fields e
             @
             (match alts with
              | [] -> []
              | _ -> [ "alternatives", `List (List.map (fun s -> `String s) alts) ])
           in
           error_json ~fields (typed_validation_error_text e)
         | Ok () ->
        let cmd = typed_input_command_text input in
        let input_ir = typed_input_shell_ir_unvalidated input in
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
              match docker_local_fallback_target ~meta with
              | Some (target, fields) when in_playground ->
                (match target with
                 | Masc_exec.Sandbox_target.Host ->
                   local_dispatch_sandbox ~extra_fields:fields ()
                 | Docker _ -> Ok (target, fields, None))
              | Some _ | None ->
                docker_sandbox_target ~turn_sandbox_factory ~meta ~cwd
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
           error_json
             ~fields:
               ([ "typed", `Bool true; "cmd", `String cmd; "cwd", `String cwd ]
                @ execution_location_fields cwd
                @ fields)
             message
         | Ok (dispatch_sandbox, sandbox_extra_fields, base_host_env) ->
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
        match Keeper_tool_execute_typed_input.to_shell_ir ~sandbox:dispatch_sandbox input with
        | Error e ->
          let alts = Keeper_tool_execute_typed_input.validation_error_alternatives e in
          let fields =
            [ "typed", `Bool true; "cmd", `String cmd ]
            @ response_cwd_field
            @ execution_location_fields cwd
            @ typed_validation_deterministic_retry_fields e
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
        let path_missing = pre_dispatch_path_missing ~cwd ir in
        match path_missing with
        | Some missing_path ->
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
        | None ->
          let env_snap =
            Cancel_safe.protect
              ~on_exn:(fun _ -> None)
              (fun () -> Some (Exec_core.snapshot_env ~cwd))
          in
          (* NDT-OK: wall clock is used only for elapsed telemetry, never for
             dispatch branching or policy decisions. *)
          let t0 = Unix.gettimeofday () in
          let task_id =
            Option.map Keeper_id.Task_id.to_string meta.current_task_id
          in
          let stream_dispatch =
            Sys.getenv_opt "MASC_STREAM_EXECUTE_OUTPUT" <> Some "false"
          in
          if not (Env_config_runtime.Shell_ir_path_jail.enabled ())
          then (
            Log.Keeper.warn
              ~keeper_name:meta.name
              "shell_ir path_jail_disabled keeper=%s sandbox=%s cwd=%s cmd=%s"
              meta.name
              (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox_profile)
              cwd
              cmd_for_log;
            Otel_metric_store.inc_counter
              (Keeper_metrics.to_string Keeper_metrics.ShellIrEffectTotal)
              ~labels:[ "kind", "path_jail_disabled"; "source", "execute" ]
              ());
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
          let on_output_chunk chunk =
            if stream_dispatch
            then (
              let stream, data =
                match chunk with
                | `Stdout s -> `Stdout, s
                | `Stderr s -> `Stderr, s
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
          let dispatch_result =
            if Env_config_runtime.Shell_ir_approval_gate.enabled ()
            then (
              let agent_id = Masc_exec.Agent_id.of_string meta.name in
              (* RFC-0254 §5.2/§5.5: the keeper lane is autonomous — no human or
                 resolver can answer an [Ask], so the overlay is [autonomous]
                 (all [Observe] => non-catastrophic [Allow] + telemetry).  This
                 unblocks the toolchain (defect §2.2.2) while the
                 trust-independent catastrophic floor in [Approval_policy.decide]
                 (destructive git, redirect write-escape, [mkfs]) still denies.
                 The floor is applied identically on Host and inside Docker
                 (RFC §13 Q2: defense-in-depth — a destructive git push reaches
                 the real remote even from a container), so no sandbox-conditional
                 branch is needed: both profiles use the same overlay. *)
              let approval_config =
                { Masc_exec.Approval_config.defaults = Masc_exec.Approval_config.autonomous
                ; per_agent = []
                }
              in
              Keeper_tool_execute_shell_ir.dispatch_classified_with_approval
                ~agent_id
                ~approval_config
                ~keeper_id:meta.name
                ~base_path:root
                ~workdir:cwd
                ~sandbox:dispatch_sandbox
                ?base_host_env
                ~on_output_chunk
                envelope)
            else
              Keeper_tool_execute_shell_ir.dispatch_classified
                ~keeper_id:meta.name
                ~base_path:root
                ~workdir:cwd
                ~sandbox:dispatch_sandbox
                ?base_host_env
                ~on_output_chunk
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
          | Error (Keeper_tool_execute_shell_ir.Approval_required { summary; bin }) ->
            Log.Keeper.warn
              "shell_ir approval_required keeper=%s cmd=%s bin=%s summary=%s"
              meta.name
              cmd_for_log
              bin
              summary;
            typed_error_json summary
          | Error (Keeper_tool_execute_shell_ir.Policy_denied { reason }) ->
            Log.Keeper.warn
              "shell_ir policy_denied keeper=%s cmd=%s reason=%s"
              meta.name
              cmd_for_log
              reason;
            typed_error_json reason
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
            let effects = Masc_exec.Exec_effect.extract ir in
            let effects_str = Format.asprintf "%a" Masc_exec.Exec_effect.pp_set effects in
            Log.Keeper.info
              "shell_ir dispatch keeper=%s sandbox=%s status=%s elapsed_ms=%d risk_class=%s typed_hit=%b effects=%s"
              meta.name
              (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox_profile)
              (Keeper_sandbox_exec_failure.status_label result.status)
              elapsed_ms
              (Masc_exec.Shell_ir_risk.string_of_risk_class
                 (Masc_exec.Shell_ir_risk.risk_class envelope))
              (Masc_exec.Shell_ir_risk.typed_hit_of_ir ir)
              effects_str;
            Otel_spans.add_attrs
              ~attrs:[
                ( "shell_ir.risk_class"
                , `String
                    (Masc_exec.Shell_ir_risk.string_of_risk_class
                       (Masc_exec.Shell_ir_risk.risk_class envelope)) )
              ; ( "shell_ir.typed_hit"
                , `Bool (Masc_exec.Shell_ir_risk.typed_hit_of_ir ir) )
              ; "shell_ir.effects", `String effects_str
              ]
              ();
            List.iter
              (fun (eff : Masc_exec.Exec_effect.t) ->
                 Otel_metric_store.inc_counter
                   (Keeper_metrics.to_string Keeper_metrics.ShellIrEffectTotal)
                   ~labels:[
                     ( "kind"
                     , Masc_exec.Exec_effect.string_of_effect_kind eff.kind )
                   ; "source", eff.source
                   ]
                   ())
              effects;
            let output =
              if String.equal result.stderr ""
              then result.stdout
              else result.stdout ^ result.stderr
            in
            let status_json =
              Keeper_alerting_path.process_status_to_json result.status
            in
            if stream_dispatch
            then (
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
                 ~stdout:result.stdout
                 ~stderr:result.stderr
                 ~status:status_json
                 ~streamed:stream_dispatch
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Dashboard.warn
                 "execute output callback failed keeper=%s: %s"
                 meta.name
                 (Printexc.to_string exn));
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
            (* Only include command_descriptor on success — errors already carry
               sufficient diagnostic info (exit code, stderr, classification). *)
            let descriptor_fields =
              match result.status with
              | Unix.WEXITED 0 ->
                let descriptor = Command_descriptor.compute ir in
                [ "command_descriptor", Command_descriptor.to_json descriptor ]
              | _ -> []
            in
            Yojson.Safe.to_string
              (Exec_core.process_result_json
                 ~classification
                 ~base_path:root
                 ~keeper_name:meta.name
                 ~cmd
                 ~extra:
                   (failure_error_fields
                    @ glob_literal_failure_fields
                    @ sandbox_extra_fields
                    @ [ "typed", `Bool true
                      ; "execution_time_ms", `Int elapsed_ms
                      ]
                    @ response_cwd_field
                    @ descriptor_fields
                    @ execution_location_fields cwd)
                 ~status:result.status
                 ~output
                 ~env_snapshot:env_snap
                 ())))

let handle_tool_execute
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~exec_cache:_
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ()
  =
  if has_typed_execute_input_key args
  then
    handle_tool_execute_typed
      ~turn_sandbox_factory
      ~config
      ~meta
      ~args
      ()
  else
    error_json
      ~fields:[ "typed", `Bool true ]
      "Typed Shell IR input is required. Provide executable/argv or pipeline."
;;
