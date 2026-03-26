(** Worker_container_runners — run_worker_oas, continue_worker, run_worker. *)

open Printf
open Result_syntax

include Worker_container

let run_worker_oas ~sw ~base_path ~worker_name
    ~(provider : Agent_sdk.Provider.config) ~(model_id : string)
    ~team_session_id
    ~room_config ?working_dir ?worker_class ?worker_size ?execution_scope
    ?thinking_enabled ?max_turns ?worker_run_id
    ~role
    ~selection_note
    ~(prompt : string) ~(allowed_tools : string list) ~(timeout_sec : int) :
    unit -> (run_result, string) result =
  fun () ->
    let mcp_session_id =
      resolved_mcp_session_id ~base_path ~team_session_id ~worker_name
    in
    let execution_scope =
      resolve_execution_scope ~base_path ~team_session_id ?execution_scope ()
    in
    let workspace_path =
      match working_dir with
      | Some dir when String.trim dir <> "" -> dir
      | _ -> base_path
    in
    let meta =
      make_worker_meta ~base_path ~workspace_path ~team_session_id ~worker_name
        ~mcp_session_id ~role ~selection_note ~execution_scope ~worker_class
        ~worker_size ~effective_model:model_id
        ~thinking_enabled ~max_turns_override:max_turns
        ~timeout_seconds:(Some timeout_sec)
    in
    match worker_auth_token ~base_path ~worker_name with
    | Error e -> Error e
    | Ok auth_token ->
        let evidence_session_id =
          evidence_session_id_of_worker_run worker_run_id
        in
        let system_prompt =
          default_system_prompt ~worker_name ~model_id
            ?session_id:team_session_id ?role ?selection_note ()
        in
        let prompt =
          let tool_contract =
            "Tool contract reminder: if you call masc_team_session_step with \
             turn_kind=\"note\", you must include a non-empty message field. \
             Calls missing message fail."
          in
          match execution_scope with
          | Team_session_types.Autonomous ->
              let resolvable =
                Agent_tool_surfaces.local_worker_resolvable_tool_names ()
              in
              let tool_names =
                Agent_tool_surfaces.build_tool_catalog ~role:"autonomous" ()
                |> List.filter (fun name -> List.mem name resolvable)
              in
              let team_ctx =
                match team_session_id with
                | Some sid -> Team_context.build ~base_path ~team_session_id:sid
                | None -> Team_context.empty
              in
              Prompt_composer.compose
                [
                  Identity
                    {
                      name = worker_name;
                      role =
                        (match role with
                        | Some r -> r
                        | None -> "autonomous");
                      model = model_id;
                    };
                  TeamContext team_ctx;
                  AvailableTools tool_names;
                  Guidelines
                    [
                      tool_contract;
                      "You have full read and write access. Choose the \
                       approach that best accomplishes your task. Use tools to \
                       verify your work. Prefer reading code before modifying \
                       it, and run tests or builds to confirm changes are \
                       correct.";
                    ];
                  Task prompt;
                ]
          | _ ->
              let workflow_contract =
                match execution_scope with
                | Team_session_types.Limited_code_change ->
                    "Coding worker protocol: you must use tools before \
                     answering. If the task requires a code change, the \
                     expected loop is file_read -> shell_exec -> file_write \
                     -> shell_exec, and you should not finish until the \
                     verification shell_exec succeeds. If the task is \
                     inspection-only, do not modify files."
                | Team_session_types.Observe_only ->
                    "Readonly worker protocol: use file_read and shell_exec \
                     for inspection, but do not modify files."
                | Team_session_types.Autonomous ->
                    (* Handled above; unreachable *)
                    ""
              in
              let team_ctx_section =
                match team_session_id with
                | Some sid ->
                    let ctx =
                      Team_context.build ~base_path ~team_session_id:sid
                    in
                    let section = Team_context.to_prompt_section ctx in
                    if section = "" then "" else "\n\n" ^ section
                | None -> ""
              in
              String.concat "\n\n"
                [ tool_contract; workflow_contract; prompt ]
              ^ team_ctx_section
        in
        let* () =
          save_worker_meta ~base_path ~team_session_id ~worker_name meta
        in
        let* mcp_tools =
          build_oas_mcp_tools ~sw ~auth_token ~session_id:mcp_session_id
            ~worker_name ~prompt ~allowed_tools
        in
        let mcp_tools =
          List.map (Oas.Tool.with_defaults
            [("agent_name", `String worker_name)]) mcp_tools
        in
        let* shell_tools =
          build_local_shell_tools ~room_config ~worker_name ~execution_scope
            ~workdir:workspace_path
        in
        let tools = mcp_tools @ shell_tools in
        let* raw_trace =
          match evidence_session_id with
          | Some trace_session_id ->
              Oas.Raw_trace.create_for_session
                ~session_root:(oas_trace_session_root ~base_path)
                ~session_id:trace_session_id ~agent_name:worker_name ()
              |> Result.map_error Oas.Error.to_string
          | None -> (
              match team_session_id with
              | Some trace_session_id ->
                  Oas.Raw_trace.create_for_session
                    ~session_root:(oas_trace_session_root ~base_path)
                    ~session_id:trace_session_id ~agent_name:worker_name ()
                  |> Result.map_error Oas.Error.to_string
              | None ->
                  Oas.Raw_trace.create ~session_id:mcp_session_id
                    ~path:
                      (worker_raw_trace_path ~base_path
                         ~team_session_id
                         ~worker_name)
                    ()
                  |> Result.map_error Oas.Error.to_string)
        in
        let gate_config =
          Worker_oas.gate_config_of_execution_scope meta.execution_scope
        in
        Worker_oas.run_worker_via_oas ~sw ~base_path ~meta ~provider
          ~system_prompt ~prompt ~tools ~raw_trace ~gate_config
          ?worker_run_id ()

let continue_worker ?worker_run_id ~sw ~base_path ~room_config ~worker_name
    ~(team_session_id : string) ~(prompt : string) :
    unit -> (run_result, string) result =
  fun () ->
  let team_session_id = Some team_session_id in
  match worker_container_state ~base_path ~team_session_id ~worker_name with
  | Worker_missing ->
      Error
        (sprintf
           "target worker '%s' was not found. Use status.worker_runs or the \
            latest team_step_spawn event to find a ready worker name."
           worker_name)
  | Worker_pending ->
      Error
        (sprintf
           "target worker '%s' has been accepted but is not ready for \
            delegation yet. Wait for a successful team_step_spawn event or a \
            ready worker in status.worker_runs."
           worker_name)
  | Worker_ready ->
      let meta =
        load_worker_meta ~base_path ~team_session_id ~worker_name
      in
      let checkpoint =
        load_worker_checkpoint ~base_path ~team_session_id ~worker_name
      in
      (match meta, checkpoint with
      | None, _ ->
          Error
            (sprintf "worker container metadata disappeared: %s" worker_name)
      | _, None ->
          Error
            (sprintf
               "worker checkpoint is not available for '%s'; wait for the \
                worker to finish its first run before delegating."
               worker_name)
      | Some meta, Some checkpoint -> (
      let workspace_path =
        if String.trim meta.workspace_path <> "" then meta.workspace_path
        else base_path
      in
      match worker_auth_token ~base_path ~worker_name with
      | Error e -> Error e
      | Ok auth_token ->
          let* net =
            match Eio_context.get_net_opt () with
            | Some net -> Ok net
            | None -> Error "Eio net not initialized"
          in
          let heartbeat_cbs =
            let interval = local_worker_heartbeat_interval_sec () in
            if interval > 0 then
              [ { Oas.Agent_types.interval_sec = float_of_int interval;
                  callback = (fun () ->
                    match
                      call_masc_tool ~sw ~auth_token
                        ~session_id:meta.mcp_session_id
                        ~tool_name:"masc_heartbeat" ~args:(`Assoc [])
                    with
                    | Ok _ -> ()
                    | Error e ->
                        Log.LocalWorker.warn "heartbeat error for %s: %s"
                          worker_name e) } ]
            else []
          in
          Fun.protect
            ~finally:(fun () ->
              (* Cancellation-safe: catch exceptions to prevent masking *)
              (try ignore
                (leave_worker ~sw ~auth_token
                   ~session_id:meta.mcp_session_id ~worker_name)
               with
               | Eio.Cancel.Cancelled _ as exn -> raise exn
               | exn ->
                   Log.LocalWorker.warn "leave_worker failed for %s: %s"
                     worker_name (Printexc.to_string exn)))
            (fun () ->
              let _ =
                match join_worker ~sw ~auth_token
                        ~session_id:meta.mcp_session_id ~worker_name with
                | Ok _ -> ()
                | Error e -> raise (Failure ("worker join failed: " ^ e))
              in
              let allowed_tools =
                match meta.shell_profile with
                | Shell_dev ->
                    [ "mcp__masc__masc_heartbeat"; "mcp__masc__masc_memento_mori" ]
                | _ ->
                    session_min_tool_names
                    |> List.map (fun name -> "mcp__masc__" ^ name)
              in
              let* mcp_tools =
                build_oas_mcp_tools ~sw ~auth_token
                  ~session_id:meta.mcp_session_id ~worker_name ~prompt
                  ~allowed_tools
              in
              let mcp_tools =
                List.map (Oas.Tool.with_defaults
                  [("agent_name", `String worker_name)]) mcp_tools
              in
              let shell_tools =
                match meta.shell_profile with
                | Shell_none -> Ok []
                | Shell_readonly ->
                    build_local_shell_tools
                      ~room_config ~worker_name
                      ~execution_scope:Team_session_types.Observe_only
                      ~workdir:workspace_path
                | Shell_dev ->
                    build_local_shell_tools
                      ~room_config ~worker_name
                      ~execution_scope:Team_session_types.Limited_code_change
                      ~workdir:workspace_path
              in
              let* shell_tools = shell_tools in
              let* raw_trace =
                match evidence_session_id_of_worker_run worker_run_id with
                | Some trace_session_id ->
                    Oas.Raw_trace.create_for_session
                      ~session_root:(oas_trace_session_root ~base_path)
                      ~session_id:trace_session_id ~agent_name:worker_name ()
                    |> Result.map_error Oas.Error.to_string
                | None -> (
                    match meta.team_session_id with
                    | Some trace_session_id ->
                        Oas.Raw_trace.create_for_session
                          ~session_root:(oas_trace_session_root ~base_path)
                          ~session_id:trace_session_id ~agent_name:worker_name ()
                        |> Result.map_error Oas.Error.to_string
                    | None ->
                        Oas.Raw_trace.create ~session_id:meta.mcp_session_id
                          ~path:
                            (worker_raw_trace_path ~base_path ~team_session_id
                               ~worker_name)
                          ()
                        |> Result.map_error Oas.Error.to_string)
              in
              let tools = mcp_tools @ shell_tools in
              let tool_names_ref = ref [] in
              let hooks =
                {
                  Oas.Hooks.empty with
                  pre_tool_use =
                    Some
                      (function
                        | Oas.Hooks.PreToolUse { tool_name; _ } ->
                            tool_names_ref := tool_name :: !tool_names_ref;
                            Oas.Hooks.Continue
                        | _ -> Oas.Hooks.Continue);
                }
              in
              let resume_model_id =
                if checkpoint.model <> "" then checkpoint.model
                else meta.effective_model
              in
              let resume_label =
                Printf.sprintf "llama:%s" resume_model_id
              in
              let resume_provider = oas_provider_of_label resume_label in
              let prompt =
                let tool_contract =
                  "Tool contract reminder: if you call masc_team_session_step \
                   with turn_kind=\"note\", you must include a non-empty \
                   message field. Calls missing message fail."
                in
                let workflow_contract =
                  match meta.execution_scope with
                  | Team_session_types.Limited_code_change ->
                      "Coding worker protocol: you must use tools before \
                       answering. If the task requires a code change, the \
                       expected loop is file_read -> shell_exec -> file_write \
                       -> shell_exec, and you should not finish until \
                       verification succeeds. If the task is inspection-only, \
                       do not modify files."
                  | Team_session_types.Observe_only ->
                      "Readonly worker protocol: use file_read and shell_exec \
                       for inspection, but do not modify files."
                  | Team_session_types.Autonomous ->
                      "You have full read and write access. Choose the approach \
                       that best accomplishes your task. Use tools to verify \
                       your work."
                in
                String.concat "\n\n" [ tool_contract; workflow_contract; prompt ]
              in
              let max_turns =
                match meta.max_turns_override with
                | Some value -> max 1 value
                | None ->
                    (match meta.execution_scope with
                    | Team_session_types.Limited_code_change -> 20
                    | Team_session_types.Observe_only -> 8
                    | Team_session_types.Autonomous -> 30)
              in
              let thinking_enabled =
                Option.value ~default:false meta.thinking_enabled
              in
              let resume_guardrails =
                let gate =
                  Worker_oas.gate_config_of_execution_scope meta.execution_scope
                in
                Verifier_oas.eval_gate_to_oas_guardrails gate
              in
              let config, options =
                build_resume_config ~worker_name ~provider:resume_provider
                  ~model_id:resume_model_id
                  ~system_prompt:
                    (default_system_prompt ~worker_name ~model_id:resume_model_id
                       ?session_id:meta.team_session_id ?role:meta.role
                       ?selection_note:meta.selection_note ())
                  ~tools ~max_turns ~thinking_enabled ~hooks ~raw_trace
                  ~periodic_callbacks:heartbeat_cbs
                  ~guardrails:resume_guardrails ()
              in
              let agent =
                Oas.Agent.resume ~net ~checkpoint ~tools ~options ~config ()
              in
              Worker_oas.run_existing_worker_agent ~sw ~base_path ~meta ~prompt
                ~workspace_path ~raw_trace ?worker_run_id ~tool_names_ref agent)))

let run_worker ~sw ~base_path ~worker_name ~model_label ~team_session_id
    ~room_config ?working_dir ?worker_class ?worker_size ?execution_scope
    ?thinking_enabled ?max_turns ?worker_run_id ~role
    ~selection_note
    ~(prompt : string) ~(allowed_tools : string list) ~(timeout_sec : int) :
    unit -> (run_result, string) result =
  let provider = oas_provider_of_label model_label in
  let model_id = match Llm_provider.Cascade_config.parse_model_string model_label with
    | Some cfg -> cfg.Llm_provider.Provider_config.model_id
    | None -> model_label
  in
  run_worker_oas ~sw ~base_path ~worker_name ~provider ~model_id
    ~team_session_id
    ~room_config ?working_dir ?worker_class ?worker_size ?execution_scope
    ?thinking_enabled ?max_turns ?worker_run_id ~role
    ~selection_note ~prompt ~allowed_tools ~timeout_sec
