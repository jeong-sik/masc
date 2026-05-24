open Keeper_types
open Keeper_exec_shared

type run_command_with_status =
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  timeout_sec:float ->
  host:Keeper_sandbox_runner.host_command ->
  backend:Keeper_sandbox_runner.backend_command ->
  Keeper_sandbox_runner.routed_result

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

let gh_parse_error_reason = function
  | Keeper_gh_shared.Empty_command -> "empty_command"
  | Keeper_gh_shared.Unsupported_shell_construct tag -> tag
  | Keeper_gh_shared.Unsupported_command_shape tag -> tag
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

let handle_gh_op
    ?(run_command_with_status =
      Keeper_sandbox_runner.run_command_with_status)
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(args : Yojson.Safe.t)
    ~repo_check
    () =
  let op = "gh" in
  let raw_cmd_str = Safe_ops.json_string ~default:"" "cmd" args in
  (* gh runs against remote network. Prior floors (1s, then 5s) kept
     firing gh_command_timed_out on plain read calls. GitHub API
     round-trip alone runs 1-8s even on small queries, and `gh` spends
     additional time on auth handshake and JSON encoding. *)
  let gh_default_timeout = Keeper_tool_policy.pr_create_timeout_sec () in
  let timeout_sec =
    Keeper_shell_shared.clamp_shell_timeout
      ~min_sec:Keeper_shell_shared.gh_min_timeout_sec
      ~default:gh_default_timeout
      args
  in
  match gh_command_from_args raw_cmd_str args with
  | Error (`Input msg) -> error_json ~fields:[ "op", `String op ] msg
  | Error (`Parse parse_error) ->
    let reason = gh_parse_error_reason parse_error in
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool false
          ; "op", `String op
          ; "error", `String "gh_command_shape_unsupported"
          ; "reason", `String reason
          ; ( "hint",
              `String
                "GitHub shell bridge accepts typed argv or one simple gh command. \
                 Avoid pipelines, redirects, env prefixes, and shell control syntax."
            )
          ])
  | Ok parsed_cmd ->
    let allowed_orgs_opt = Keeper_tool_policy.git_clone_allowed_orgs () in
    let canonical_cmd_str =
      Keeper_gh_shared.render_simple_gh_command parsed_cmd
    in
    (* RFC-0160 S3: risk classification via IR-based Shell_ir_risk
       rather than string-based classify_gh_reversibility. *)
    let reversibility =
      Keeper_gh_shared.gh_simple_command_risk_class
        ~sandbox:(Masc_exec.Sandbox_target.host ())
        parsed_cmd
    in
    let rev_tag =
      Masc_exec.Shell_ir_risk.string_of_risk_class reversibility
    in
    let gh_cmd_display cmd =
      Printf.sprintf "gh %s"
        (Keeper_gh_shared.render_simple_gh_command cmd)
    in
    let gh_base ~ok ~cwd ~command extras =
      let route_fields =
        if cwd = ""
        then []
        else [ "via", `String (Keeper_sandbox_runner.route_via ~config ~meta ~cwd) ]
      in
      Yojson.Safe.to_string
        (`Assoc
            ([ "ok", `Bool ok
             ; "op", `String op
             ; "cwd", `String cwd
             ; "command", `String command
             ; "reversibility", `String rev_tag
             ]
             @ route_fields
             @ extras))
    in
    let run_gh_command ~display_command ~parsed_command ~cwd
        ~(ctx : Keeper_shell_gh_context.gh_repo_context option) =
      if reversibility = Masc_exec.Shell_ir_risk.R1_Reversible_mutation
      then
        Log.Keeper.info
          "gh_audit: keeper=%s reversibility=R1 cwd=%s cmd=%s"
          meta.name
          cwd
          display_command;
      let gh_context_fields =
        match ctx with
        | Some ctx ->
          let repo_fields =
            match ctx.repo_slug with
            | Some repo_slug -> [ "repo", `String repo_slug ]
            | None -> []
          in
          [ "task_id", `String ctx.task_id
          ; "git_root", `String ctx.git_root
          ]
          @ repo_fields
        | None -> []
      in
      (* RFC-0160 S2: route gh dispatch through the same Shell IR gate
         that op=bash uses before the backend-neutral runner dispatch. *)
      let gh_sandbox_target = Masc_exec.Sandbox_target.host () in
      let gh_ir =
        Keeper_gh_shared.gh_simple_command_to_shell_ir
          ~sandbox:gh_sandbox_target
          ~cwd
          parsed_command
      in
      let gh_gate_verdict =
        Masc_exec_command_gate.Shell_command_gate.gate_typed
          ~caller:Masc_exec_command_gate.Shell_command_gate.Keeper_shell_ir
          ~ir:gh_ir
          ~allowlist:
            { allowed_commands = [ "gh" ]
            ; allow_pipes = false
            ; redirect_allowed = false
            }
          ~path_policy:Masc_exec_command_gate.Shell_command_gate.allow_all_paths
          ~sandbox:{ target = gh_sandbox_target }
          ()
      in
      let gh_path_verdict =
        match gh_gate_verdict with
        | Masc_exec_command_gate.Shell_command_gate.Allow _ ->
          Exec_policy.validate_shell_ir_paths
            ~keeper_id:meta.name
            ~workdir:cwd
            gh_ir
        | _ -> Ok ()
      in
      let gh_process =
        match gh_gate_verdict with
        | Masc_exec_command_gate.Shell_command_gate.Reject { diagnostic; _ } ->
          Error (Printf.sprintf "gh_gate_reject: %s" diagnostic)
        | Cannot_parse _ -> Error "gh_gate_cannot_parse"
        | Too_complex _ -> Error "gh_gate_too_complex"
        | Allow _ ->
          (match gh_path_verdict with
           | Error msg -> Error (Printf.sprintf "gh_path_reject: %s" msg)
           | Ok () ->
             let gh_argv =
               "gh" :: Keeper_gh_shared.gh_simple_command_argv parsed_command
             in
             let use_backend =
               Keeper_sandbox_runner.uses_backend ~config ~meta ~cwd
             in
             let host_env_result =
               if use_backend
               then Ok None
               else Keeper_gh_env.keeper_process_env config ~keeper_name:meta.name
             in
             (match host_env_result with
              | Error err -> Error err
              | Ok env ->
                let result =
                  run_command_with_status
                    ~config
                    ~meta
                    ~timeout_sec
                    ~host:
                      { actor = `Keeper_shell
                      ; raw_source = String.concat " " gh_argv
                      ; summary = "keeper gh command"
                      ; env
                      ; cwd = Some cwd
                      ; argv = gh_argv
                      }
                    ~backend:
                      { route_cwd = cwd
                      ; cwd = (fun () -> cwd)
                      ; command_text = display_command
                      ; git_creds_enabled = true
                      ; network_mode = Network_inherit
                      ; trust = Keeper_sandbox_runner.User_shell
                      }
                in
                (match result.backend_error with
                 | Some msg -> Error msg
                 | None -> Ok (result.status, result.output))))
      in
      match gh_process with
      | Error msg ->
        gh_base ~command:display_command ~ok:false ~cwd
          (gh_context_fields @ [ "error", `String msg ])
      | Ok (st, out) ->
        if Keeper_shell_shared.process_status_is_timeout st
        then
          gh_base ~command:display_command ~ok:false ~cwd
            (gh_context_fields
             @ [ "error", `String "gh_command_timed_out"
               ; "timeout_sec", `Float timeout_sec
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "output", `String out
               ; ( "hint",
                   `String
                     "gh network call exceeded timeout_sec. Retry with a larger value \
                      - gh round-trip plus auth handshake is usually 3-10s, so prefer \
                      timeout_sec=30 or timeout_sec=60 rather than the 15s floor. You \
                      may also narrow the query (--state, --limit, --json)."
                 )
               ])
        else
          let ok = st = Unix.WEXITED 0 in
          let base_fields =
            gh_context_fields
            @ [ "status", Keeper_alerting_path.process_status_to_json st
              ; "output", `String out
              ]
          in
          let hinted_fields =
            if (not ok)
               && String_util.contains_substring_ci
                    out
                    "Could not resolve to a Repository"
            then
              base_fields
              @ [ "error", `String "gh_repo_resolve_failed"
                ; ( "hint",
                    `String
                      "gh is bound to the active task worktree repo. Ensure the linked \
                       sandbox clone still has a valid origin remote and recreate the \
                       task worktree if needed."
                  )
                ]
            else base_fields
          in
          gh_base ~command:display_command ~ok ~cwd hinted_fields
    in
    (match reversibility with
     | Masc_exec.Shell_ir_risk.R2_Irreversible
     | Masc_exec.Shell_ir_risk.Destructive_protected ->
       let hint =
         Option.value
           (Worker_dev_tools.structured_tool_hint_for_r2 canonical_cmd_str)
           ~default:
             "This gh command mutates state that gh itself cannot restore. Route \
              through the appropriate structured keeper tool or post on the board for \
              operator approval."
       in
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_shell_ops_failures
         ~labels:[ "keeper", meta.name ]
         ();
       Log.Keeper.warn
         "keeper_shell op=gh R2 blocked: %s (keeper=%s)"
         canonical_cmd_str
         meta.name;
       gh_base
         ~ok:false
         ~cwd:""
         ~command:(gh_cmd_display parsed_cmd)
         [ "error", `String "gh_irreversible_blocked"; "hint", `String hint ]
     | Masc_exec.Shell_ir_risk.R0_Read
     | Masc_exec.Shell_ir_risk.R1_Reversible_mutation ->
       (match allowed_orgs_opt with
        | None ->
          Log.Keeper.warn
            "keeper_shell op=gh: tool_policy.toml not loaded (policy_not_loaded), \
             rejecting gh command (keeper=%s cmd=%s)"
            meta.name
            canonical_cmd_str;
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_shell_ops_failures
            ~labels:[ "keeper", meta.name ]
            ();
          Yojson.Safe.to_string
            (`Assoc
                [ "ok", `Bool false
                ; "op", `String op
                ; "error", `String "policy_not_loaded"
                ; ( "reason",
                    `String
                      "tool_policy.toml not loaded; gh org restrictions cannot be \
                       validated"
                  )
                ; ( "hint",
                    `String
                      "The server tool-policy config has not been loaded. Restart the \
                       server and ensure config/tool_policy.toml is present and valid."
                  )
                ])
        | Some allowed_orgs ->
          (match
             Worker_dev_tools.validate_gh_command
               ~allowed_orgs
               canonical_cmd_str
           with
           | Error reason ->
             Yojson.Safe.to_string
               (`Assoc
                   [ "ok", `Bool false
                   ; "op", `String op
                   ; "error", `String "gh_command_blocked"
                   ; "reason", `String reason
                   ; ( "hint",
                       `String
                         "Run `gh --help` shapes: pr/issue/repo/release/label/run/\
                          workflow/api/project/ruleset/search/status/cache/gist. \
                          auth/secret/ssh-key are blocked."
                     )
                   ])
           | Ok () ->
             (match
                Keeper_shell_shared.resolve_keeper_shell_write_cwd
                  ~config
                  ~meta
                  ~args
              with
              | Error e -> error_json e
              | Ok gh_cwd ->
                if Keeper_gh_shared.gh_simple_command_has_repo_flag parsed_cmd
                then
                  run_gh_command
                    ~display_command:(gh_cmd_display parsed_cmd)
                    ~parsed_command:parsed_cmd
                    ~cwd:gh_cwd
                    ~ctx:None
                else
                  (match
                     Keeper_shell_gh_context.resolve_gh_repo_context
                       ~config
                       ~meta
                       ~cwd:gh_cwd
                   with
                   | Error err ->
                     Keeper_shell_gh_context.gh_repo_context_error_json
                       ~op
                       ~cmd_display:(gh_cmd_display parsed_cmd)
                       err
                   | Ok ctx ->
                     (match repo_check ctx.worktree_cwd with
                      | Error msg ->
                        gh_base
                          ~ok:false
                          ~cwd:ctx.worktree_cwd
                          ~command:(gh_cmd_display parsed_cmd)
                          [ "error", `String "repo_access_denied"
                          ; "hint", `String msg
                          ]
                      | Ok () ->
                        let cmd_to_run =
                          match ctx.repo_slug with
                          | Some repo_slug ->
                            Keeper_gh_shared.gh_simple_command_with_repo_flag
                              ~repo_slug
                              parsed_cmd
                          | None -> parsed_cmd
                        in
                        run_gh_command
                          ~display_command:(gh_cmd_display cmd_to_run)
                          ~parsed_command:cmd_to_run
                          ~cwd:ctx.worktree_cwd
                          ~ctx:(Some ctx)))))))
;;
