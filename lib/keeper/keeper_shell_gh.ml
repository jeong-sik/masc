open Keeper_types
open Keeper_exec_shared

module Shell_gate = Masc_exec_command_gate.Shell_command_gate

let json_string_list_field name args =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | None -> Ok None
     | Some (`List values) ->
       let rec collect acc = function
         | [] -> Ok (Some (List.rev acc))
         | `String value :: rest -> collect (value :: acc) rest
         | _ :: _ -> Error (Printf.sprintf "%s must be an array of strings" name)
       in
       collect [] values
     | Some _ -> Error (Printf.sprintf "%s must be an array of strings" name))
  | _ -> Ok None
;;

let gh_command_from_args raw_cmd_str args =
  match json_string_list_field "argv" args with
  | Error msg -> Error (`Input msg)
  | Ok argv_opt ->
    let has_cmd = String.trim raw_cmd_str <> "" in
    (match has_cmd, argv_opt with
     | true, Some _ ->
       Error
         (`Input
           "cmd and argv are mutually exclusive for gh op; use argv for the typed \
            contract or cmd for the legacy string contract")
     | false, None ->
       Error
         (`Input
           "argv or legacy cmd is required for gh op. Prefer typed argv, e.g. \
            argv=[\"pr\",\"list\",\"--state\",\"open\"].")
     | true, None ->
       (match Keeper_gh_shared.parse_simple_gh_command raw_cmd_str with
        | Ok parsed -> Ok parsed
        | Error parse_error -> Error (`Parse parse_error))
     | false, Some argv ->
       (match Keeper_gh_shared.gh_simple_command_of_argv argv with
        | Ok parsed -> Ok parsed
        | Error parse_error -> Error (`Parse parse_error)))
;;

let handle ~op ~(meta : keeper_meta) ~(config : Coord.config) ~(args : Yojson.Safe.t) =
  let raw_cmd_str = Safe_ops.json_string ~default:"" "cmd" args in
  let gh_default_timeout = Keeper_tool_policy.pr_create_timeout_sec () in
  let timeout_sec =
    Keeper_shell_shared.clamp_shell_timeout
      ~min_sec:Keeper_shell_shared.gh_min_timeout_sec
      ~default:gh_default_timeout
      args
  in
  match gh_command_from_args raw_cmd_str args with
  | Error (`Input msg) -> error_json_for_op ~op msg
  | Error (`Parse parse_error) ->
    let reason = Keeper_gh_shared.gh_parse_error_reason parse_error in
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool false
          ; "op", `String op
          ; "error", `String "gh_command_shape_unsupported"
          ; "reason", `String reason
          ; "hint", `String
             "GitHub shell bridge accepts typed argv or one simple gh command. \
              Avoid pipelines, redirects, env prefixes, and shell control syntax."
          ])
  | Ok parsed_cmd ->
    let allowed_orgs_opt = Keeper_tool_policy.git_clone_allowed_orgs () in
    let canonical_cmd_str =
      Keeper_gh_shared.render_simple_gh_command parsed_cmd
    in
    let gh_classify_ir =
      Keeper_gh_shared.gh_simple_command_to_shell_ir
        ~sandbox:(Masc_exec.Sandbox_target.host ())
        parsed_cmd
    in
    let gh_risk_envelope = Keeper_shell_ir.classify gh_classify_ir in
    let reversibility = gh_risk_envelope.Masc_exec.Shell_ir_risk.risk in
    let rev_tag =
      Masc_exec.Shell_ir_risk.string_of_risk_class reversibility
    in
    let gh_cmd_display cmd =
      Printf.sprintf "gh %s"
        (Keeper_gh_shared.render_simple_gh_command cmd)
    in
    let route_fields = sandbox_profile_via_fields meta in
    let gh_base ~ok ~cwd ~command ?ctx extras =
      let ctx_fields = Keeper_shell_gh_context.json_fields_of_context ctx in
      Yojson.Safe.to_string
        (`Assoc
            ([ "ok", `Bool ok
             ; "op", `String op
             ; "cwd", `String cwd
             ; "command", `String command
             ; "reversibility", `String rev_tag
             ] @ route_fields @ ctx_fields @ extras))
    in
    let run_gh_command ~display_command ~parsed_command ~cwd
        ~(ctx : Keeper_shell_gh_context.gh_repo_context option)
        ~base_ir =
      if reversibility = Masc_exec.Shell_ir_risk.R1_Reversible_mutation
      then
        Log.Keeper.info
          "gh_audit: keeper=%s reversibility=R1 cwd=%s cmd=%s"
          meta.name cwd display_command;
      let gh_ir = Keeper_shell_ir.with_cwd ~raw:cwd ~cwd base_ir in
      let gh_process =
        Keeper_shell_ir.gate_verdict_map
          (Shell_gate.gate_typed
             ~caller:Shell_gate.Keeper_shell_bash
             ~ir:gh_ir
             ~allowlist:
               { allowed_commands = [ "gh" ]
               ; allow_pipes = false
               ; redirect_allowed = false
               }
             ~path_policy:Shell_gate.allow_all_paths
             ~sandbox:Shell_gate.host_sandbox
             ())
          ~f_reject:(fun diagnostic ->
            Error (Printf.sprintf "gh_gate_reject: %s" diagnostic))
          ~f_cannot_parse:(Error "gh_gate_cannot_parse")
          ~f_too_complex:(Error "gh_gate_too_complex")
          ~f_allow:(fun _ ->
            match
              Exec_policy.validate_shell_ir_paths ~keeper_id:meta.name ~workdir:cwd gh_ir
            with
            | Error msg -> Error (Printf.sprintf "gh_path_reject: %s" msg)
            | Ok () ->
              if meta.sandbox_profile = Docker
              then
                match
                  Keeper_shell_docker.run_docker_shell_command_with_status
                    ~config ~meta ~cwd
                    ~timeout_sec ~cmd:display_command
                    ~git_creds_enabled:true ~network_mode:Network_inherit
                with
                | Ok result -> Ok (result.status, result.output)
                | Error msg -> Error msg
              else
                (match
                   Keeper_gh_env.keeper_process_env config ~keeper_name:meta.name
                 with
                 | Error err -> Error err
                 | Ok env ->
                   let gh_argv =
                     "gh" :: Keeper_gh_shared.gh_simple_command_argv parsed_command
                   in
                   Ok
                     (Masc_exec.Exec_gate.run_argv_with_status ~actor:`Keeper_shell
                        ~raw_source:(String.concat " " gh_argv)
                        ~summary:"keeper gh command"
                        ?env ~cwd ~timeout_sec gh_argv)))
      in
      match gh_process with
      | Error msg ->
        gh_base ~command:display_command ~ok:false ~cwd ~ctx
          [ "error", `String msg ]
      | Ok (st, out) ->
        if Keeper_shell_shared.process_status_is_timeout st
        then
          gh_base ~command:display_command ~ok:false ~cwd ~ctx
            [ "error", `String "gh_command_timed_out"
            ; "timeout_sec", `Float timeout_sec
            ; "status", Keeper_alerting_path.process_status_to_json st
            ; "output", `String out
            ; "hint", `String
                "gh network call exceeded timeout_sec. Retry \
                 with a larger value -- gh round-trip plus auth \
                 handshake is usually 3-10s, so prefer \
                 timeout_sec=30 or timeout_sec=60 rather than \
                 the 15s floor. You may also narrow the query \
                 (--state, --limit, --json)."
            ]
        else
          let ok = st = Unix.WEXITED 0 in
          let base_fields =
            [ "status", Keeper_alerting_path.process_status_to_json st
            ; "output", `String out
            ]
          in
          let hinted_fields =
            if (not ok)
               && String_util.contains_substring_ci out
                    "Could not resolve to a Repository"
            then
              base_fields
              @ [ "error", `String "gh_repo_resolve_failed"
                ; "hint", `String
                    "gh is bound to the active task worktree repo. \
                     Ensure the linked sandbox clone still has a valid \
                     origin remote and recreate the task worktree if needed."
                ]
            else base_fields
          in
          gh_base ~command:display_command ~ok ~cwd ~ctx hinted_fields
    in
    (match reversibility with
     | Masc_exec.Shell_ir_risk.R2_Irreversible
     | Masc_exec.Shell_ir_risk.Destructive_protected ->
       let hint =
         Option.value
           (Worker_dev_tools.structured_tool_hint_for_r2_of_tokens
              parsed_cmd.argv)
           ~default:
             "This gh command mutates state that gh itself cannot \
              restore. Route through the appropriate structured \
              keeper tool or post on the board for operator approval."
       in
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_shell_ops_failures
         ~labels:[ "keeper", meta.name ]
         ();
       Log.Keeper.warn
         "keeper_shell op=gh R2 blocked: %s (keeper=%s)"
         canonical_cmd_str meta.name;
       gh_base ~ok:false ~cwd:"" ~command:(gh_cmd_display parsed_cmd)
         [ "error", `String "gh_irreversible_blocked"
         ; "hint", `String hint
         ]
     | Masc_exec.Shell_ir_risk.R0_Read
     | Masc_exec.Shell_ir_risk.R1_Reversible_mutation ->
       begin
         match allowed_orgs_opt with
         | None ->
           Log.Keeper.warn
             "keeper_shell op=gh: tool_policy.toml not loaded (policy_not_loaded), \
              rejecting gh command (keeper=%s cmd=%s)"
             meta.name canonical_cmd_str;
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_shell_ops_failures
             ~labels:[ "keeper", meta.name ]
             ();
           Yojson.Safe.to_string
             (`Assoc
                 [ "ok", `Bool false
                 ; "op", `String op
                 ; "error", `String "policy_not_loaded"
                 ; "reason", `String
                     "tool_policy.toml not loaded; gh org restrictions \
                      cannot be validated"
                 ; "hint", `String
                     "The server tool-policy config has not been loaded. \
                      Restart the server and ensure config/tool_policy.toml \
                      is present and valid."
                 ])
         | Some allowed_orgs ->
           (match
              Worker_dev_tools.validate_gh_command_of_tokens
                ~allowed_orgs parsed_cmd.argv
            with
            | Error reason ->
              Yojson.Safe.to_string
                (`Assoc
                    [ "ok", `Bool false
                    ; "op", `String op
                    ; "error", `String "gh_command_blocked"
                    ; "reason", `String reason
                    ; "hint", `String
                        "Run `gh --help` shapes: pr/issue/repo/release/\
                         label/run/workflow/api/project/ruleset/search/\
                         status/cache/gist. auth/secret/ssh-key are blocked."
                    ])
            | Ok () ->
              (match
                 Keeper_shell_path.resolve_keeper_shell_write_cwd
                   ~config ~meta ~args
               with
               | Error e -> error_json e
               | Ok gh_cwd ->
                 if Keeper_gh_shared.gh_simple_command_has_repo_flag parsed_cmd
                 then
                   run_gh_command
                     ~display_command:(gh_cmd_display parsed_cmd)
                     ~parsed_command:parsed_cmd
                     ~cwd:gh_cwd ~ctx:None
                     ~base_ir:gh_classify_ir
                 else
                   (match
                      Keeper_shell_gh_context.resolve_gh_repo_context
                        ~config ~meta ~cwd:gh_cwd
                    with
                    | Error err ->
                      Keeper_shell_gh_context.gh_repo_context_error_json
                        ~op
                        ~cmd_display:(gh_cmd_display parsed_cmd)
                        err
                    | Ok ctx ->
                      match
                        Keeper_repo_mapping.validate_path_access
                          ~keeper_id:meta.name
                          ~base_path:config.base_path
                          ~path:ctx.worktree_cwd
                      with
                      | Error msg ->
                        gh_base ~ok:false ~cwd:ctx.worktree_cwd
                          ~command:(gh_cmd_display parsed_cmd)
                          ~ctx:(Some ctx)
                          [ "error", `String "repo_access_denied"
                          ; "hint", `String msg
                          ]
                      | Ok () ->
                        let cmd_to_run =
                          match ctx.repo_slug with
                          | Some repo_slug ->
                            Keeper_gh_shared.gh_simple_command_with_repo_flag
                              ~repo_slug parsed_cmd
                          | None -> parsed_cmd
                        in
                        let base_ir_cmd =
                          Keeper_gh_shared.gh_simple_command_to_shell_ir
                            ~sandbox:(Masc_exec.Sandbox_target.host ())
                            cmd_to_run
                        in
                        run_gh_command
                          ~display_command:(gh_cmd_display cmd_to_run)
                          ~parsed_command:cmd_to_run
                          ~cwd:ctx.worktree_cwd
                          ~ctx:(Some ctx)
                          ~base_ir:base_ir_cmd)))
       end)
;;
