(** Worker_oas — Adapter bridging MASC worker_container_meta to OAS Agent.t.

    Converts MASC worker metadata into OAS Agent configuration, using the
    OAS Builder pattern for agent construction. Wraps Agent.run with MASC
    worker lifecycle hooks (heartbeat, join/leave, board posting).

    This module demonstrates the migration path from MASC's bespoke worker
    runner (local_agent_eio_runners.ml) to the OAS Agent SDK. It does not
    replace the existing runner; instead it provides an alternative entry
    point gated by [MASC_USE_OAS_WORKERS=true].

    Key mappings:
    - worker_container_meta fields -> OAS agent_config + Builder options
    - MASC execution_scope -> OAS max_turns cap + system prompt contract
    - MASC heartbeat -> OAS periodic_callback
    - MASC tool_profile/shell_profile -> OAS Tool.t list filtering
    - MASC team_session -> OAS Builder.with_description metadata

    @since Phase 5 — OAS Agent.run adapter for workers *)

open Printf

module Oas = Agent_sdk

(* ================================================================ *)
(* Feature Flag                                                      *)
(* ================================================================ *)

let use_oas_workers () =
  match Sys.getenv_opt "MASC_USE_OAS_WORKERS" with
  | Some v ->
    let v = String.lowercase_ascii (String.trim v) in
    v = "true" || v = "1" || v = "yes"
  | None -> false

(* ================================================================ *)
(* worker_container_meta -> OAS Types.model                          *)
(* ================================================================ *)

(** Convert an effective_model string to an OAS model identifier.
    MASC workers use local Ollama/llama-server models, so all model IDs
    go through Custom. *)
let oas_model_of_effective_model (model_id : string) : Oas.Types.model =
  Oas.Types.Custom model_id

(* ================================================================ *)
(* worker_container_meta -> OAS Types.agent_config                   *)
(* ================================================================ *)

(** Map MASC execution_scope to max_turns cap.
    Mirrors the logic in local_agent_eio_runners.ml run_worker_oas. *)
let max_turns_cap_of_scope (scope : Team_session_types.execution_scope) : int =
  match scope with
  | Observe_only -> 12
  | Limited_code_change -> 20
  | Autonomous -> 30

(** Derive max_turns from worker meta, applying the scope cap.
    When max_turns_override is set, it is clamped to [1, cap].
    When absent, timeout_seconds / 20 is used as a heuristic. *)
let effective_max_turns (meta : Local_agent_eio_types.worker_container_meta) : int =
  let cap = max_turns_cap_of_scope meta.execution_scope in
  match meta.max_turns_override with
  | Some value -> max 1 (min cap value)
  | None ->
    let from_timeout =
      match meta.timeout_seconds with
      | Some sec -> max 2 (sec / 20)
      | None -> 8
    in
    max 2 (min cap from_timeout)

(** Convert MASC worker_container_meta to OAS agent_config.
    Maps worker_name, model, thinking, max_turns, and temperature. *)
let agent_config_of_worker_meta
    (meta : Local_agent_eio_types.worker_container_meta)
    ~(system_prompt : string) : Oas.Types.agent_config =
  let max_tokens = Local_agent_eio_types.local_worker_max_tokens () in
  {
    Oas.Types.default_config with
    name = meta.worker_name;
    model = oas_model_of_effective_model meta.effective_model;
    system_prompt = Some system_prompt;
    max_tokens;
    max_turns = effective_max_turns meta;
    temperature = Some 0.2;
    top_p = Some 0.95;
    top_k = Some 20;
    min_p = Some 0.0;
    enable_thinking = Some (Option.value ~default:false meta.thinking_enabled);
    tool_choice = Some Oas.Types.Auto;
  }

(* ================================================================ *)
(* Metadata -> key-value pairs for description/context               *)
(* ================================================================ *)

(** Encode MASC-specific worker metadata as a human-readable description
    string. This preserves context (role, scope, team session, worker
    class) that has no direct OAS equivalent. *)
let description_of_meta (meta : Local_agent_eio_types.worker_container_meta) : string =
  let lines = ref [] in
  let add key value =
    if String.trim value <> "" then
      lines := (sprintf "%s: %s" key value) :: !lines
  in
  add "worker_name" meta.worker_name;
  add "mcp_session_id" meta.mcp_session_id;
  (match meta.team_session_id with
   | Some sid -> add "team_session_id" sid
   | None -> ());
  add "workspace" meta.workspace_path;
  (match meta.role with
   | Some r -> add "role" r
   | None -> ());
  (match meta.selection_note with
   | Some n -> add "selection_note" n
   | None -> ());
  add "execution_scope"
    (Team_session_types.execution_scope_to_string meta.execution_scope);
  add "effective_model" meta.effective_model;
  (match meta.effective_tier with
   | Some tier -> add "effective_tier" (Team_session_types.model_tier_to_string tier)
   | None -> ());
  (match meta.worker_class with
   | Some cls -> add "worker_class" (Team_session_types.worker_class_to_string cls)
   | None -> ());
  (match meta.worker_size with
   | Some size -> add "worker_size" (Team_session_types.worker_size_to_string size)
   | None -> ());
  String.concat "\n" (List.rev !lines)

(* ================================================================ *)
(* OAS Provider from MASC model_spec                                 *)
(* ================================================================ *)

(** Re-use the existing provider mapping from local_agent_eio_container. *)
let oas_provider_of_model = Local_agent_eio_container.oas_provider_of_model

(* ================================================================ *)
(* Build OAS Agent.t via Builder                                     *)
(* ================================================================ *)

(** Build an OAS Agent.t from MASC worker metadata using the Builder pattern.

    This is the central adapter function. It:
    1. Converts worker_meta to agent_config
    2. Attaches the LLM provider
    3. Wires tools, hooks, guardrails, raw_trace
    4. Adds MASC heartbeat as an OAS periodic_callback
    5. Embeds MASC metadata in the agent description *)
let build_agent
    ~(net : [> `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(meta : Local_agent_eio_types.worker_container_meta)
    ~(model : Llm_client.model_spec)
    ~(system_prompt : string)
    ~(tools : Oas.Tool.t list)
    ~(hooks : Oas.Hooks.hooks)
    ~(raw_trace : Oas.Raw_trace.t)
    ~(heartbeat_callbacks : Oas.Agent.periodic_callback list)
    () : (Oas.Agent.t, string) result =
  let config = agent_config_of_worker_meta meta ~system_prompt in
  let provider = oas_provider_of_model model in
  let tool_names =
    List.map (fun (tool : Oas.Tool.t) -> tool.schema.name) tools
  in
  let builder =
    Oas.Builder.create ~net ~model:config.model
    |> Oas.Builder.with_name config.name
    |> Oas.Builder.with_system_prompt system_prompt
    |> Oas.Builder.with_max_tokens config.max_tokens
    |> Oas.Builder.with_max_turns config.max_turns
    |> Oas.Builder.with_temperature 0.2
    |> Oas.Builder.with_top_p 0.95
    |> Oas.Builder.with_top_k 20
    |> Oas.Builder.with_min_p 0.0
    |> Oas.Builder.with_enable_thinking
         (Option.value ~default:false meta.thinking_enabled)
    |> Oas.Builder.with_tool_choice Oas.Types.Auto
    |> Oas.Builder.with_provider provider
    |> Oas.Builder.with_tools tools
    |> Oas.Builder.with_hooks hooks
    |> Oas.Builder.with_guardrails
         {
           Oas.Guardrails.tool_filter = AllowList tool_names;
           max_tool_calls_per_turn = Some 12;
         }
    |> Oas.Builder.with_raw_trace raw_trace
    |> Oas.Builder.with_periodic_callbacks heartbeat_callbacks
    |> Oas.Builder.with_description (description_of_meta meta)
  in
  Oas.Builder.build_safe builder
  |> Result.map_error Oas.Error.to_string

(* ================================================================ *)
(* Build heartbeat callback                                          *)
(* ================================================================ *)

(** Create an OAS periodic_callback that sends MASC heartbeats.
    Returns an empty list when the heartbeat interval is 0 or negative. *)
let make_heartbeat_callbacks
    ~(sw : Eio.Switch.t)
    ~(auth_token : string option)
    ~(session_id : string)
    ~(worker_name : string) : Oas.Agent.periodic_callback list =
  let interval = Local_agent_eio_types.local_worker_heartbeat_interval_sec () in
  if interval <= 0 then []
  else
    [
      {
        Oas.Agent_types.interval_sec = float_of_int interval;
        callback =
          (fun () ->
            match
              Local_agent_eio_types.call_masc_tool ~sw ~auth_token
                ~session_id ~tool_name:"masc_heartbeat" ~args:(`Assoc [])
            with
            | Ok _ -> ()
            | Error e ->
              Log.LocalWorker.warn "heartbeat error for %s: %s"
                worker_name e);
      };
    ]

(* ================================================================ *)
(* Run Worker via OAS                                                *)
(* ================================================================ *)

(** Run a single worker through OAS Agent.run, wrapping with MASC lifecycle
    (join/leave, heartbeat, checkpoint persistence, turn log, evidence).

    This function mirrors run_worker_oas in local_agent_eio_runners.ml,
    but constructs the agent using the Builder pattern instead of
    build_oas_agent + Agent.create directly.

    Returns a run_result on success, or an error string on failure. *)
let run_worker_via_oas
    ~(sw : Eio.Switch.t)
    ~(base_path : string)
    ~(meta : Local_agent_eio_types.worker_container_meta)
    ~(model : Llm_client.model_spec)
    ~(system_prompt : string)
    ~(prompt : string)
    ~(tools : Oas.Tool.t list)
    ~(raw_trace : Oas.Raw_trace.t)
    ?worker_run_id
    () : (Local_agent_eio_types.run_result, string) result =
  let ( let* ) = Result.bind in
  let session_id = meta.mcp_session_id in
  let team_session_id = meta.team_session_id in
  let worker_name = meta.worker_name in
  let* auth_token =
    Local_agent_eio_types.worker_auth_token ~base_path ~worker_name
  in
  let* net =
    match Eio_context.get_net_opt () with
    | Some net -> Ok net
    | None -> Error "Eio net not initialized"
  in
  let heartbeat_cbs =
    make_heartbeat_callbacks ~sw ~auth_token ~session_id ~worker_name
  in
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
  let* agent =
    build_agent ~net ~meta ~model ~system_prompt ~tools ~hooks
      ~raw_trace ~heartbeat_callbacks:heartbeat_cbs ()
  in
  let* () =
    Local_agent_eio_container.save_worker_meta ~base_path
      ~team_session_id ~worker_name meta
  in
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Local_agent_eio_types.leave_worker ~sw ~auth_token
           ~session_id ~worker_name))
    (fun () ->
      let _ =
        match
          Local_agent_eio_types.join_worker ~sw ~auth_token
            ~session_id ~worker_name
        with
        | Ok _ -> ()
        | Error e -> raise (Failure ("worker join failed: " ^ e))
      in
      let result = Oas.Agent.run ~sw agent prompt in
      let raw_trace_run = Oas.Agent.last_raw_trace_run agent in
      let checkpoint =
        Oas.Agent.checkpoint ~session_id agent
      in
      let tool_names =
        List.rev !tool_names_ref
        |> Local_agent_eio_types.unique_preserve_order
      in
      let* () =
        Local_agent_eio_container.save_worker_checkpoint ~base_path
          ~team_session_id ~worker_name checkpoint
      in
      let* () =
        Local_agent_eio_container.save_worker_meta ~base_path
          ~team_session_id ~worker_name
          { meta with last_run_at = Some (Time_compat.now ()) }
      in
      let workspace_path =
        if String.trim meta.workspace_path <> "" then meta.workspace_path
        else base_path
      in
      Local_agent_eio_container.materialize_direct_evidence
        ~base_path ~worker_name ~worker_run_id ~meta ~prompt
        ~workspace_path ~agent ~raw_trace;
      Oas.Agent.close agent;
      match result with
      | Ok response ->
        let output =
          response.content
          |> List.filter_map (function
               | Oas.Types.Text text -> Some text
               | _ -> None)
          |> String.concat "\n"
        in
        let* () =
          Local_agent_eio_container.append_worker_completion_log
            ~base_path ~team_session_id ~worker_name ~prompt
            ~tool_names ~status:"ok" ~output ()
        in
        Ok
          {
            Local_agent_eio_types.output;
            model_used =
              (if String.trim response.model <> "" then response.model
               else meta.effective_model);
            input_tokens = Some checkpoint.usage.total_input_tokens;
            output_tokens = Some checkpoint.usage.total_output_tokens;
            cost_usd = Some checkpoint.usage.estimated_cost_usd;
            tool_call_count = List.length tool_names;
            tool_names;
            session_id;
            raw_trace_run;
          }
      | Error err ->
        let detail = Oas.Error.to_string err in
        let* () =
          Local_agent_eio_container.append_worker_completion_log
            ~base_path ~team_session_id ~worker_name ~prompt
            ~tool_names ~status:"error" ~output:detail ~error:detail ()
        in
        Error detail)

(* ================================================================ *)
(* Orchestrate Multiple Workers                                      *)
(* ================================================================ *)

(** Wrap OAS Orchestrator for multi-worker execution.
    Each worker is built from its MASC meta, registered with a name,
    then the orchestrator executes a plan (Sequential, Parallel, etc.).

    Returns the list of task results from the orchestrator. *)
let orchestrate_workers
    ~(sw : Eio.Switch.t)
    ~(net : [> `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(workers : (Local_agent_eio_types.worker_container_meta
                 * Llm_client.model_spec
                 * string (* system_prompt *)
                 * Oas.Tool.t list
                 * Oas.Raw_trace.t
                 * Oas.Agent.periodic_callback list) list)
    ~(plan : Oas.Orchestrator.plan)
    ?on_task_start
    ?on_task_complete
    () : (Oas.Orchestrator.task_result list, string) result =
  let ( let* ) = Result.bind in
  let rec build_agents acc = function
    | [] -> Ok (List.rev acc)
    | (meta, model, system_prompt, tools, raw_trace, heartbeat_cbs) :: rest ->
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
      let* agent =
        build_agent ~net ~meta ~model ~system_prompt ~tools ~hooks
          ~raw_trace ~heartbeat_callbacks:heartbeat_cbs ()
      in
      ignore tool_names_ref;
      build_agents ((meta.worker_name, agent) :: acc) rest
  in
  let* named_agents = build_agents [] workers in
  let config =
    {
      Oas.Orchestrator.default_config with
      max_parallel = 4;
      on_task_start;
      on_task_complete;
    }
  in
  let orch = Oas.Orchestrator.create ~config named_agents in
  Ok (Oas.Orchestrator.execute ~sw orch plan)
