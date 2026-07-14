(** Worker_oas — Bridges MASC worker_container_meta to OAS Agent.t.

    Converts MASC worker metadata into OAS Agent configuration, using the
    OAS Builder pattern for agent construction. Wraps Agent.run with MASC
    worker lifecycle hooks (heartbeat, board posting).

    Key mappings:
    - worker_container_meta fields -> OAS agent_config + Builder options
    - MASC heartbeat -> OAS periodic_callback
    - runtime_backend -> worker description metadata
    - MASC worker metadata -> OAS Builder.with_description metadata

    @since Phase 5 — OAS Agent.run adapter for workers *)

open Printf
open Result.Syntax

(* ================================================================ *)
(* Metadata -> key-value pairs for description/context               *)
(* ================================================================ *)

(** Encode MASC-specific worker metadata as a human-readable description
    string. This preserves context (role, runtime backend) that has
    no direct OAS equivalent. *)
let description_of_meta (meta : Worker_container_types.worker_container_meta) : string =
  let lines = ref [] in
  let add key value =
    if String.trim value <> "" then lines := sprintf "%s: %s" key value :: !lines
  in
  add "worker_name" meta.worker_name;
  add "mcp_session_id" meta.mcp_session_id;
  add "workspace" meta.workspace_path;
  (match meta.role with
   | Some r -> add "role" r
   | None -> ());
  (match meta.selection_note with
   | Some n -> add "selection_note" n
   | None -> ());
  add "runtime_backend" (Worker_execution_backend.to_string meta.runtime_backend);
  add "effective_model" meta.effective_model;
  String.concat "\n" (List.rev !lines)
;;

(* ================================================================ *)
(* Build OAS Agent.t via Builder                                     *)
(* ================================================================ *)

(** Build an OAS Agent.t from MASC worker metadata using the Builder pattern.

    This is the central adapter function. It:
    1. Selects the exact worker model and provider
    2. Wires tools, hooks, and raw_trace
    3. Adds MASC heartbeat as an OAS periodic_callback
    4. Embeds MASC metadata in the agent description *)
let build_agent
      ~(net : [> `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
      ~(meta : Worker_container_types.worker_container_meta)
      ~(provider_config : Llm_provider.Provider_config.t)
      ~(system_prompt : string)
      ~(tools : Agent_sdk.Tool.t list)
      ~(hooks : Agent_sdk.Hooks.hooks)
      ~(raw_trace : Agent_sdk.Raw_trace.t)
      ~(heartbeat_callbacks : Agent_sdk.Agent.periodic_callback list)
      ?context_injector
      ?context
      ()
  : (Agent_sdk.Agent.t, string) result
  =
  let builder =
    Agent_sdk.Builder.create ~net ~model:provider_config.model_id
    |> Agent_sdk.Builder.with_provider_config provider_config
    |> Agent_sdk.Builder.with_name meta.worker_name
    |> Agent_sdk.Builder.with_system_prompt system_prompt
    |> Agent_sdk.Builder.with_tools tools
    |> Agent_sdk.Builder.with_hooks hooks
    |> Agent_sdk.Builder.with_raw_trace raw_trace
    |> Agent_sdk.Builder.with_periodic_callbacks heartbeat_callbacks
    |> Agent_sdk.Builder.with_description (description_of_meta meta)
  in
  let builder =
    match meta.thinking_enabled with
    | Some enabled -> Agent_sdk.Builder.with_enable_thinking enabled builder
    | None -> builder
  in
  let builder =
    match context_injector with
    | Some ci -> Agent_sdk.Builder.with_context_injector ci builder
    | None -> builder
  in
  let builder =
    match context with
    | Some ctx -> Agent_sdk.Builder.with_context ctx builder
    | None -> builder
  in
  Agent_sdk.Builder.build_safe builder |> Result.map_error Agent_sdk.Error.to_string
;;

(* ================================================================ *)
(* Build heartbeat callback                                          *)
(* ================================================================ *)

(** Create an OAS periodic_callback that sends MASC heartbeats.
    Returns an empty list when the heartbeat interval is 0 or negative. *)
let make_heartbeat_callbacks
      ~(sw : Eio.Switch.t)
      ~(auth_token : string option)
      ~(session_id : string)
      ~(worker_name : string)
  : Agent_sdk.Agent.periodic_callback list
  =
  let interval = Worker_container_types.local_worker_heartbeat_interval_sec () in
  if interval <= 0
  then []
  else
    [ { Agent_sdk.Agent_types.interval_sec = float_of_int interval
      ; callback =
          (fun () ->
            match
              Worker_container_types.call_masc_tool
                ~sw
                ~auth_token
                ~session_id
                ~tool_name:"masc_heartbeat"
                ~args:(`Assoc [])
            with
            | Ok _ -> ()
            | Error e -> Log.LocalWorker.warn "heartbeat error for %s: %s" worker_name e)
      }
    ]
;;

(** Build observation hooks for worker tool names and failures. Authorization
    belongs to the external-effect boundary, not to a worker-local heuristic. *)
let make_tool_tracking_hooks ?context () =
  let tool_names_ref = ref [] in
  let tracking =
    { Agent_sdk.Hooks.empty with
      pre_tool_use =
        Some
          (fun event ->
            match event with
            | Agent_sdk.Hooks.PreToolUse { tool_name; _ } ->
              tool_names_ref := tool_name :: !tool_names_ref;
              Agent_sdk.Hooks.Continue
            | Agent_sdk.Hooks.BeforeTurn _
            | Agent_sdk.Hooks.BeforeTurnParams _
            | Agent_sdk.Hooks.AfterTurn _
            | Agent_sdk.Hooks.PostToolUse _
            | Agent_sdk.Hooks.PostToolUseFailure _
            | Agent_sdk.Hooks.OnStop _
            | Agent_sdk.Hooks.OnError _
            | Agent_sdk.Hooks.OnToolError _ -> Agent_sdk.Hooks.Continue)
    ; on_error =
        Some
          (function
            | Agent_sdk.Hooks.OnError { detail; context = err_ctx } ->
              Log.LocalWorker.warn "worker on_error: %s (context: %s)" detail err_ctx;
              Agent_sdk.Hooks.Continue
            | Agent_sdk.Hooks.BeforeTurn _
            | Agent_sdk.Hooks.BeforeTurnParams _
            | Agent_sdk.Hooks.AfterTurn _
            | Agent_sdk.Hooks.PreToolUse _
            | Agent_sdk.Hooks.PostToolUse _
            | Agent_sdk.Hooks.PostToolUseFailure _
            | Agent_sdk.Hooks.OnStop _
            | Agent_sdk.Hooks.OnToolError _
              -> Agent_sdk.Hooks.Continue)
    ; on_tool_error =
        Some
          (function
            | Agent_sdk.Hooks.OnToolError { tool_name; error } ->
              Log.LocalWorker.warn "worker tool_error: %s — %s" tool_name error;
              Agent_sdk.Hooks.Continue
            | Agent_sdk.Hooks.BeforeTurn _
            | Agent_sdk.Hooks.BeforeTurnParams _
            | Agent_sdk.Hooks.AfterTurn _
            | Agent_sdk.Hooks.PreToolUse _
            | Agent_sdk.Hooks.PostToolUse _
            | Agent_sdk.Hooks.PostToolUseFailure _
            | Agent_sdk.Hooks.OnStop _
            | Agent_sdk.Hooks.OnError _
              -> Agent_sdk.Hooks.Continue)
    }
  in
  let hooks =
    match context with
    | Some ctx ->
      let temporal =
        { Agent_sdk.Hooks.empty with
          before_turn_params =
            Some
              (function
                | Agent_sdk.Hooks.BeforeTurnParams { current_params; _ } ->
                  (match Masc_context_injector.render_temporal_summary ctx with
                   | None -> Agent_sdk.Hooks.Continue
                   | Some summary ->
                     let ctx_str =
                       match current_params.Agent_sdk.Hooks.extra_system_context with
                       | None -> summary
                       | Some prev -> prev ^ "\n\n" ^ summary
                     in
                     Agent_sdk.Hooks.AdjustParams
                       { current_params with extra_system_context = Some ctx_str })
                | Agent_sdk.Hooks.BeforeTurn _
                | Agent_sdk.Hooks.AfterTurn _
                | Agent_sdk.Hooks.PreToolUse _
                | Agent_sdk.Hooks.PostToolUse _
                | Agent_sdk.Hooks.PostToolUseFailure _
                | Agent_sdk.Hooks.OnStop _
                | Agent_sdk.Hooks.OnError _
                | Agent_sdk.Hooks.OnToolError _ -> Agent_sdk.Hooks.Continue)
        }
      in
      Agent_sdk.Hooks.compose ~outer:temporal ~inner:tracking
    | None -> tracking
  in
  tool_names_ref, hooks
;;

let record_worker_mcp_client_session_duration
      ~(auth_token : string option)
      ~(meta : Worker_container_types.worker_container_meta)
      ?error_type
      ()
  =
  match meta.mcp_client_session_started_at with
  | None -> ()
  | Some started_at ->
    Worker_container_types.record_mcp_client_session_duration
      ~url:(Worker_container_types.mcp_endpoint_url ~auth_token)
      ~started_at
      ?error_type
      ()
;;

let begin_worker_mcp_client_session
      (meta : Worker_container_types.worker_container_meta)
  =
  match meta.mcp_client_session_started_at with
  | Some _ -> meta
  | None ->
    (* NDT-OK: this stamps a client-session telemetry interval, not control flow. *)
    { meta with mcp_client_session_started_at = Some (Unix.gettimeofday ()) }
;;

let finish_worker_mcp_client_session
      (meta : Worker_container_types.worker_container_meta)
  =
  { meta with
    mcp_client_session_started_at = None
  ; last_run_at = Some (Time_compat.now ())
  }
;;

module For_testing = struct
  let begin_worker_mcp_client_session = begin_worker_mcp_client_session
  let finish_worker_mcp_client_session = finish_worker_mcp_client_session
end

(* ================================================================ *)
(* Run Worker via OAS                                                *)
(* ================================================================ *)

(** Run a single worker through OAS Agent.run, wrapping with MASC lifecycle
    (join/leave, heartbeat, checkpoint persistence, turn log, evidence).

    This function mirrors run_worker_oas in local_agent_eio_runners.ml,
    but constructs the agent using the Builder pattern.

    Returns a run_result on success, or an error string on failure. *)
let rec run_worker_via_oas
          ~(sw : Eio.Switch.t)
          ~(net : [> `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
          ~(base_path : string)
          ~(auth_token : string option)
          ~(meta : Worker_container_types.worker_container_meta)
          ~(provider_config : Llm_provider.Provider_config.t)
          ~(system_prompt : string)
          ~(prompt : string)
          ~(tools : Agent_sdk.Tool.t list)
          ~(raw_trace : Agent_sdk.Raw_trace.t)
          ?worker_run_id
          ()
  : (Worker_container_types.run_result, string) result
  =
  Masc_runtime_events.with_turn_span
  @@ fun () ->
  let session_id = meta.mcp_session_id in
  let worker_name = meta.worker_name in
  let heartbeat_cbs = make_heartbeat_callbacks ~sw ~auth_token ~session_id ~worker_name in
  let injector_config = Masc_context_injector.default_config () in
  let context_injector = Masc_context_injector.make ~config:injector_config () in
  let shared_context = Agent_sdk.Context.create () in
  let tool_names_ref, hooks =
    make_tool_tracking_hooks ~context:shared_context ()
  in
  let* agent =
    build_agent
      ~net
      ~meta
      ~provider_config
      ~system_prompt
      ~tools
      ~hooks
      ~raw_trace
      ~heartbeat_callbacks:heartbeat_cbs
      ~context_injector
      ~context:shared_context
      ()
  in
  let meta = begin_worker_mcp_client_session meta in
  let* () = Worker_container.save_worker_meta ~base_path ~worker_name meta in
  let workspace_path =
    if String.trim meta.workspace_path <> "" then meta.workspace_path else base_path
  in
  run_existing_worker_agent
    ~sw
    ~base_path
    ~auth_token
    ~meta
    ~prompt
    ~workspace_path
    ~raw_trace
    ?worker_run_id
    ~tool_names_ref
    agent

and resume_worker_via_oas
      ~(sw : Eio.Switch.t)
      ~(net : [> `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
      ~(base_path : string)
      ~(auth_token : string option)
      ~(meta : Worker_container_types.worker_container_meta)
      ~(provider_config : Llm_provider.Provider_config.t)
      ~(checkpoint : Agent_sdk.Checkpoint.t)
      ~(prompt : string)
      ~(tools : Agent_sdk.Tool.t list)
      ~(raw_trace : Agent_sdk.Raw_trace.t)
      ?worker_run_id
      ()
  : (Worker_container_types.run_result, string) result
  =
  Masc_runtime_events.with_turn_span
  @@ fun () ->
  let worker_name = meta.worker_name in
  let session_id = meta.mcp_session_id in
  let* () =
    if String.equal provider_config.model_id checkpoint.model
    then Ok ()
    else
      Error
        (Printf.sprintf
           "checkpoint/provider model mismatch for worker %S: checkpoint=%S provider=%S"
           worker_name
           checkpoint.model
           provider_config.model_id)
  in
  let heartbeat_cbs = make_heartbeat_callbacks ~sw ~auth_token ~session_id ~worker_name in
  let injector_config = Masc_context_injector.default_config () in
  let context_injector = Masc_context_injector.make ~config:injector_config () in
  let shared_context = Agent_sdk.Context.copy ~eio:true checkpoint.context in
  let tool_names_ref, hooks =
    make_tool_tracking_hooks ~context:shared_context ()
  in
  let options =
    { Agent_sdk.Agent.default_options with
      hooks
    ; raw_trace = Some raw_trace
    ; periodic_callbacks = heartbeat_cbs
    ; context_injector = Some context_injector
    }
  in
  let agent =
    Agent_sdk.Agent.resume
      ~net
      ~checkpoint
      ~tools
      ~options
      ~provider_config
      ~context:shared_context
      ()
  in
  let meta = begin_worker_mcp_client_session meta in
  let* () = Worker_container.save_worker_meta ~base_path ~worker_name meta in
  let workspace_path =
    if String.trim meta.workspace_path <> "" then meta.workspace_path else base_path
  in
  run_existing_worker_agent
    ~sw
    ~base_path
    ~auth_token
    ~meta
    ~prompt
    ~workspace_path
    ~raw_trace
    ?worker_run_id
    ~tool_names_ref
    agent

and run_existing_worker_agent
      ~(sw : Eio.Switch.t)
      ~(base_path : string)
      ~(auth_token : string option)
      ~(meta : Worker_container_types.worker_container_meta)
      ~(prompt : string)
      ~(workspace_path : string)
      ~(raw_trace : Agent_sdk.Raw_trace.t)
      ?worker_run_id
      ~(tool_names_ref : string list ref)
      (agent : Agent_sdk.Agent.t)
  : (Worker_container_types.run_result, string) result
  =
  let worker_name = meta.worker_name in
  let session_id = meta.mcp_session_id in
  Eio_guard.protect
    ~finally:(fun () ->
      try Agent_sdk.Agent.close agent with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.LocalWorker.warn
          "agent close failed for %s: %s"
          worker_name
          (Printexc.to_string exn))
    (fun () ->
       let clock =
         match Eio_context.get_clock_opt () with
         | Some c -> Some c
         | None ->
           (match Process_eio.get_clock () with
            | Ok c -> Some c
            | Error _ -> None)
       in
       let result =
         Agent_sdk.Agent.run
           ~sw
           ?clock
           agent
           prompt
       in
       let raw_trace_run = Agent_sdk.Agent.last_raw_trace_run agent in
       let evidence_session_id =
         Worker_container.evidence_session_id_of_worker_run
           (Option.map
              (fun (run_ref : Agent_sdk.Raw_trace.run_ref) -> run_ref.worker_run_id)
              raw_trace_run)
       in
      let checkpoint = Agent_sdk.Agent.checkpoint ~session_id agent in
      let tool_names =
        List.rev !tool_names_ref |> Json_util.dedupe_keep_order
      in
      let session_error_type =
        match result with
        | Ok _ -> None
        | Error _ -> Some "agent_error"
      in
      let* () =
        Worker_container.save_worker_checkpoint ~base_path ~worker_name checkpoint
      in
      let completed_meta = finish_worker_mcp_client_session meta in
      let* () =
        Worker_container.save_worker_meta
          ~base_path
          ~worker_name
          completed_meta
      in
      record_worker_mcp_client_session_duration
        ~auth_token
        ~meta
        ?error_type:session_error_type
        ();
       Worker_container.materialize_direct_evidence
         ~base_path
         ~worker_name
         ~worker_run_id
         ~meta:completed_meta
         ~prompt
         ~workspace_path
         ~agent
         ~raw_trace;
       match result with
       | Ok response ->
         let output = Agent_sdk_response.text_of_response response in
         let* () =
           Worker_container.append_worker_completion_log
             ~base_path
             ~worker_name
             ~prompt
             ~tool_names
             ~status:"ok"
             ~output
             ?raw_trace_run
             ?evidence_session_id
             ()
         in
         Ok
           { Worker_container_types.output
           ; model_used =
               (if String.trim response.model <> ""
                then response.model
                else meta.effective_model)
           ; input_tokens = Some checkpoint.usage.total_input_tokens
           ; output_tokens = Some checkpoint.usage.total_output_tokens
           ; cost_usd = Some checkpoint.usage.estimated_cost_usd
           ; tool_call_count = List.length tool_names
           ; tool_names
           ; session_id
           ; raw_trace_run
           ; api_response = Some response
           }
       | Error err ->
         let detail = Agent_sdk.Error.to_string err in
         Log.LocalWorker.warn "worker %s errored: %s" worker_name detail;
         let* () =
           Worker_container.append_worker_completion_log
             ~base_path
             ~worker_name
             ~prompt
             ~tool_names
             ~status:"error"
             ~output:detail
             ~error:detail
             ?raw_trace_run
             ?evidence_session_id
             ()
         in
         Error detail)
;;

(* ================================================================ *)
(* Orchestrate Multiple Workers                                      *)
