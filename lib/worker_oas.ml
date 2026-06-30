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
(* worker_container_meta -> OAS Masc_domain.model                          *)
(* ================================================================ *)

(** Convert an effective_model string to an OAS model identifier.
    MASC workers use local Ollama/llama-server models, so all model IDs
    go through Custom. *)
let oas_model_of_effective_model (model_id : string) : string = model_id

(* ================================================================ *)
(* worker_container_meta -> OAS Masc_domain.agent_config                   *)
(* ================================================================ *)

let worker_max_turns_cap = 20

(* Worker sampling overrides. The [worker_default] inference profile leaves
   top_p/top_k unset (None); these are worker_oas's own fixed sampling
   choice, applied at both the agent_config record and the Builder below.
   Named here so the two send sites cannot drift (CLAUDE.md magic-number
   rule). See also the min_p note in [agent_config_of_worker_meta]. *)
let worker_top_p = 0.95
let worker_top_k = 40

(** Derive max_turns from worker meta timeout budget.
    Worker runtime no longer stores a separate max_turns contract. *)
let effective_max_turns (meta : Worker_container_types.worker_container_meta) : int =
  let from_timeout =
    match meta.timeout_seconds with
    | Some sec -> max 2 (sec / 20)
    | None -> 8
  in
  max 2 (min worker_max_turns_cap from_timeout)
;;

(** Convert MASC worker_container_meta to OAS agent_config.
    Maps worker_name, model, thinking, max_turns, and temperature. *)
let agent_config_of_worker_meta
      (meta : Worker_container_types.worker_container_meta)
      ~(system_prompt : string)
  : Agent_sdk.Types.agent_config
  =
  let max_tokens = Worker_container_types.local_worker_max_tokens () in
  { Agent_sdk.Types.default_config with
    name = meta.worker_name
  ; model = oas_model_of_effective_model meta.effective_model
  ; system_prompt = Some system_prompt
  ; max_tokens = Some max_tokens
  ; max_turns = effective_max_turns meta
  ; temperature = Some Runtime_provider_defaults.worker_default_temperature
  ; top_p = Some worker_top_p
  ; top_k = Some worker_top_k
  ; (* min_p intentionally omitted: the constant is 0.0 (no-op) and some
       cloud providers (Groq, GLM) reject the field itself with
       "Invalid request: property 'min_p' is unsupported". OAS capability
       gate in #6653 handles this too, but keeping the send-site explicit
       avoids ambiguous_partial_commit when the gate has not propagated. *)
    min_p = None
  ; enable_thinking = Some (Option.value ~default:false meta.thinking_enabled)
  }
;;

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
(* OAS Provider from MASC model_spec                                 *)
(* ================================================================ *)

(** Re-use the existing provider mapping from worker_container. *)
let oas_provider_of_label = Worker_container.oas_provider_of_label

(* ================================================================ *)
(* gate_config                                                       *)
(* ================================================================ *)

(* Local model (Qwen3.5 Q4) — no cloud cost, so generous turn budget. *)
let local_model_gate =
  { Eval_gate.default_config with
    destructive_check_enabled = true
  ; max_tool_calls_per_turn = 30
  ; max_cost_usd = 1.00
  }
;;

(* Boundary: MASC does not impose a tool-retry budget on workers. Retrying a
   malformed tool call is the keeper's own competence — the SDK delivers the
   validation error back to the model (pipeline [None] branch) and the agent
   loop decides whether to re-emit. OAS owns retry classification, feedback
   synthesis, and loop control; runaway is bounded by token budget + idle
   turns, not a code-level retry count. *)
let default_gate_config () = { local_model_gate with denied_tools = [] }

(* ================================================================ *)
(* Build OAS Agent.t via Builder                                     *)
(* ================================================================ *)

(** Build an OAS Agent.t from MASC worker metadata using the Builder pattern.

    This is the central adapter function. It:
    1. Converts worker_meta to agent_config
    2. Attaches the MODEL provider
    3. Wires tools, hooks, guardrails, raw_trace
    4. Adds MASC heartbeat as an OAS periodic_callback
    5. Embeds MASC metadata in the agent description *)
let build_agent
      ~(net : [> `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
      ~(meta : Worker_container_types.worker_container_meta)
      ~(provider : Agent_sdk.Provider.config)
      ~(system_prompt : string)
      ~(tools : Agent_sdk.Tool.t list)
      ~(hooks : Agent_sdk.Hooks.hooks)
      ~(raw_trace : Agent_sdk.Raw_trace.t)
      ~(heartbeat_callbacks : Agent_sdk.Agent.periodic_callback list)
      ?(gate_config : Eval_gate.gate_config option)
      ?context_injector
      ?context
      ?(approval : Agent_sdk.Hooks.approval_callback =
        Approval_callbacks.reject_by_default)
      ()
  : (Agent_sdk.Agent.t, string) result
  =
  let config = agent_config_of_worker_meta meta ~system_prompt in
  let tool_names = List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) tools in
  let guardrails =
    match gate_config with
    | Some gate -> Verifier_oas.eval_gate_to_oas_guardrails gate
    | None ->
      { Agent_sdk.Guardrails.tool_filter = AllowList tool_names
      ; max_tool_calls_per_turn =
          Some 30
      }
  in
  let builder =
    Agent_sdk.Builder.create ~net ~model:config.model
    |> Agent_sdk.Builder.with_name config.name
    |> Agent_sdk.Builder.with_system_prompt system_prompt
    |> (fun b ->
    match config.max_tokens with
    | Some n -> Agent_sdk.Builder.with_max_tokens n b
    | None -> b)
    |> Agent_sdk.Builder.with_max_turns config.max_turns
    |> Agent_sdk.Builder.with_temperature Runtime_provider_defaults.worker_default_temperature
    |> Agent_sdk.Builder.with_top_p worker_top_p
    |> Agent_sdk.Builder.with_top_k worker_top_k
    (* with_min_p intentionally omitted — see agent_config_of_worker_meta
       above for the reason. min_p of 0.0 is a no-op and cloud providers
       (Groq, GLM) reject the field itself. *)
    |> Agent_sdk.Builder.with_enable_thinking
         (Option.value ~default:false meta.thinking_enabled)
    |> Agent_sdk.Builder.with_provider provider
    |> Agent_sdk.Builder.with_tools tools
    |> Agent_sdk.Builder.with_hooks hooks
    |> Agent_sdk.Builder.with_guardrails guardrails
    |> Agent_sdk.Builder.with_raw_trace raw_trace
    |> Agent_sdk.Builder.with_periodic_callbacks heartbeat_callbacks
    |> Agent_sdk.Builder.with_description (description_of_meta meta)
    (* #7883 *)
    |> Agent_sdk.Builder.with_approval approval
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

(** Convert a JSON field value into a string suitable for safety screening. *)
let string_of_screening_value (value : Yojson.Safe.t) : string =
  match value with
  | `String s -> s
  | `Int i -> string_of_int i
  | `Intlit s -> s
  | `Float f -> string_of_float f
  | `Bool b -> string_of_bool b
  | `Null -> ""
  | (`Assoc _ | `List _) as json -> Yojson.Safe.to_string json
;;

(** Extract command-like content from tool input JSON for screening.
    Reads "command", "cmd", "content", "action"/"args", or "path" keys.
    Shared pattern with keeper_hooks_oas.ml extract_command_from_input. *)
let extract_command_from_input (input : Yojson.Safe.t) : string =
  let string_member key =
    Json_util.get_string input key |> Option.value ~default:""
  in
  let member_to_string key =
    match Json_util.assoc_member_opt key input with
    | None | Some `Null -> ""
    | Some value -> string_of_screening_value value
  in
  try
    let command = string_member "command" in
    if command <> ""
    then command
    else (
      let cmd = string_member "cmd" in
      if cmd <> ""
      then cmd
      else (
        let content = string_member "content" in
        if content <> ""
        then content
        else (
          let action = string_member "action" in
          let args = member_to_string "args" in
          match action, args with
          | "", "" ->
            let path = string_member "path" in
            if path <> "" then path else ""
          | a, "" -> a
          | "", b -> b
          | a, b -> String.trim (a ^ " " ^ b))))
  with
  | Yojson.Safe.Util.Type_error _ -> ""
;;

(** Render inline skip reason for blocked tool calls.
    Returns a text block that OAS displays instead of executing the tool. *)
let render_worker_skip_reason ~tool_name ~reason_code ~reason_text =
  Printf.sprintf
    "[tool_blocked] tool=%s reason_code=%s reason=%s"
    tool_name
    reason_code
    reason_text
;;

(** Build pre_tool_use hook with optional safety gates.

    When [gate_config] is provided, adds safety defense-in-depth
    (same pattern as keeper_hooks_oas.ml):
    - Gate 0: Deny list — reject tools in [gate_config.denied_tools]
    - Gate 1: Destructive pattern detection — reject dangerous shell commands

    [gate_config.max_cost_usd] is advisory telemetry only and must not reject.

    When [gate_config] is None, only name tracking is performed (backward compat).

    @since Audit #2 — Worker safety gates *)
let make_tool_tracking_hooks
      ?gate_config
      ?(destructive_ops_policy = Destructive_ops_policy.default)
      ?context
      () =
  let tool_names_ref = ref [] in
  let tracking =
    { Agent_sdk.Hooks.empty with
      pre_tool_use =
        Some
          (fun event ->
            match event with
            | Agent_sdk.Hooks.PreToolUse { tool_name; input; _ } ->
              (* Always track tool names *)
              tool_names_ref := tool_name :: !tool_names_ref;
              (* Safety gates (when gate_config is provided) *)
              (match gate_config with
               | None -> Agent_sdk.Hooks.Continue
               | Some (gate : Eval_gate.gate_config) ->
                 (* Gate 0: Deny list *)
                 if List.mem tool_name gate.denied_tools then (
                   Log.LocalWorker.warn "worker deny list: blocked %s" tool_name;
                   Agent_sdk.Hooks.Override
                     (render_worker_skip_reason
                        ~tool_name
                        ~reason_code:"worker_deny"
                        ~reason_text:"tool is on the worker deny list"))
                 else if
                   (* Gate 1: Destructive pattern detection *)
                   gate.destructive_check_enabled
                   && Tool_capability.has Tool_capability.Destructive tool_name
                 then (
                   let cmd = extract_command_from_input input in
                   match Eval_gate.detect_destructive destructive_ops_policy cmd with
                   | Some (pattern, desc) ->
                     let reason_text = Printf.sprintf "pattern='%s' (%s)" pattern desc in
                     Log.LocalWorker.warn
                       "worker destructive pattern in %s: '%s' (%s)"
                       tool_name
                       pattern
                       desc;
                     Agent_sdk.Hooks.Override
                       (render_worker_skip_reason
                          ~tool_name
                          ~reason_code:"destructive_guard"
                          ~reason_text)
                   | None -> Agent_sdk.Hooks.Continue)
                 else Agent_sdk.Hooks.Continue)
            | Agent_sdk.Hooks.BeforeTurn _
            | Agent_sdk.Hooks.BeforeTurnParams _
            | Agent_sdk.Hooks.AfterTurn _
            | Agent_sdk.Hooks.PostToolUse _
            | Agent_sdk.Hooks.PostToolUseFailure _
            | Agent_sdk.Hooks.OnStop _
            | Agent_sdk.Hooks.OnIdle _
            | Agent_sdk.Hooks.OnIdleEscalated _
            | Agent_sdk.Hooks.OnError _
            | Agent_sdk.Hooks.OnToolError _
            | Agent_sdk.Hooks.PreCompact _
            | Agent_sdk.Hooks.PostCompact _
            | Agent_sdk.Hooks.OnContextCompacted _ -> Agent_sdk.Hooks.Continue)
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
            | Agent_sdk.Hooks.OnIdle _
            | Agent_sdk.Hooks.OnIdleEscalated _
            | Agent_sdk.Hooks.OnToolError _
            | Agent_sdk.Hooks.PreCompact _
            | Agent_sdk.Hooks.PostCompact _
            | Agent_sdk.Hooks.OnContextCompacted _ -> Agent_sdk.Hooks.Continue)
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
            | Agent_sdk.Hooks.OnIdle _
            | Agent_sdk.Hooks.OnIdleEscalated _
            | Agent_sdk.Hooks.OnError _
            | Agent_sdk.Hooks.PreCompact _
            | Agent_sdk.Hooks.PostCompact _
            | Agent_sdk.Hooks.OnContextCompacted _ -> Agent_sdk.Hooks.Continue)
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
                | Agent_sdk.Hooks.OnIdle _
                | Agent_sdk.Hooks.OnIdleEscalated _
                | Agent_sdk.Hooks.OnError _
                | Agent_sdk.Hooks.OnToolError _
                | Agent_sdk.Hooks.PreCompact _
                | Agent_sdk.Hooks.PostCompact _
                | Agent_sdk.Hooks.OnContextCompacted _ -> Agent_sdk.Hooks.Continue)
        }
      in
      Agent_sdk.Hooks.compose ~outer:temporal ~inner:tracking
    | None -> tracking
  in
  tool_names_ref, hooks
;;

let resume_model_id_of_checkpoint
      (meta : Worker_container_types.worker_container_meta)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  if checkpoint.model <> "" then checkpoint.model else meta.effective_model
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
    but constructs the agent using the Builder pattern instead of
    build_resume_config + Agent.create directly.

    Returns a run_result on success, or an error string on failure. *)
let rec run_worker_via_oas
          ~(sw : Eio.Switch.t)
          ~(net : [> `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
          ~(base_path : string)
          ~(auth_token : string option)
          ~(meta : Worker_container_types.worker_container_meta)
          ~(provider : Agent_sdk.Provider.config)
          ~(system_prompt : string)
          ~(prompt : string)
          ~(tools : Agent_sdk.Tool.t list)
          ~(raw_trace : Agent_sdk.Raw_trace.t)
          ?(gate_config : Eval_gate.gate_config option)
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
  let shared_context = Agent_sdk.Context.create ~eio:true () in
  let tool_names_ref, hooks =
    make_tool_tracking_hooks ?gate_config ~context:shared_context ()
  in
  let* agent =
    build_agent
      ~net
      ~meta
      ~provider
      ~system_prompt
      ~tools
      ~hooks
      ~raw_trace
      ~heartbeat_callbacks:heartbeat_cbs
      ?gate_config
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
      ~(checkpoint : Agent_sdk.Checkpoint.t)
      ~(prompt : string)
      ~(tools : Agent_sdk.Tool.t list)
      ~(raw_trace : Agent_sdk.Raw_trace.t)
      ?worker_run_id
      ?(approval : Agent_sdk.Hooks.approval_callback =
        Approval_callbacks.reject_by_default)
      ()
  : (Worker_container_types.run_result, string) result
  =
  Masc_runtime_events.with_turn_span
  @@ fun () ->
  let worker_name = meta.worker_name in
  let session_id = meta.mcp_session_id in
  let heartbeat_cbs = make_heartbeat_callbacks ~sw ~auth_token ~session_id ~worker_name in
  let injector_config = Masc_context_injector.default_config () in
  let context_injector = Masc_context_injector.make ~config:injector_config () in
  let shared_context = Agent_sdk.Context.copy ~eio:true checkpoint.context in
  let gate_config = default_gate_config () in
  let tool_names_ref, hooks =
    make_tool_tracking_hooks ~gate_config ~context:shared_context ()
  in
  let resume_model_id = resume_model_id_of_checkpoint meta checkpoint in
  let* resume_provider =
    oas_provider_of_label (resume_model_id)
    |> Result.map_error (fun e ->
      Printf.sprintf "checkpoint resume (model %S): %s" resume_model_id e)
  in
  let system_prompt =
    Worker_container_types.default_system_prompt
      ~worker_name
      ~model_id:resume_model_id
      ?role:meta.role
      ?selection_note:meta.selection_note
      ()
  in
  let max_turns = effective_max_turns meta in
  let thinking_enabled = Option.value ~default:false meta.thinking_enabled in
  let guardrails = Verifier_oas.eval_gate_to_oas_guardrails gate_config in
  let config, options =
    Worker_container.build_resume_config
      ~worker_name
      ~provider:resume_provider
      ~model_id:resume_model_id
      ~system_prompt
      ~tools
      ~max_turns
      ~thinking_enabled
      ~hooks
      ~raw_trace
      ~periodic_callbacks:heartbeat_cbs
      ~guardrails
      ()
  in
  let options =
    { options with
      Agent_sdk.Agent_types.context_injector = Some context_injector
    ; (* #7883 *)
      approval = Some approval
    }
  in
  let agent =
    Agent_sdk.Agent.resume
      ~net
      ~checkpoint
      ~tools
      ~options
      ~config
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
         let output =
           Agent_sdk.Types.visible_text_of_response response
         in
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
