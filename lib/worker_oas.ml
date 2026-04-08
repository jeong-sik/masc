(** Worker_oas — Bridges MASC worker_container_meta to OAS Agent.t.

    Converts MASC worker metadata into OAS Agent configuration, using the
    OAS Builder pattern for agent construction. Wraps Agent.run with MASC
    worker lifecycle hooks (heartbeat, join/leave, board posting).

    Key mappings:
    - worker_container_meta fields -> OAS agent_config + Builder options
    - MASC execution_scope -> OAS max_turns cap + system prompt contract
    - MASC heartbeat -> OAS periodic_callback
    - MASC tool_profile/shell_profile -> OAS Tool.t list filtering
    - MASC team_session -> OAS Builder.with_description metadata

    @since Phase 5 — OAS Agent.run adapter for workers *)

open Printf
open Result_syntax

(* ================================================================ *)
(* worker_container_meta -> OAS Types.model                          *)
(* ================================================================ *)

(** Convert an effective_model string to an OAS model identifier.
    MASC workers use local Ollama/llama-server models, so all model IDs
    go through Custom. *)
let oas_model_of_effective_model (model_id : string) : string =
  model_id

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

let proof_result_status_to_string =
  Oas_worker_exec.proof_result_status_to_string

(** Derive max_turns from worker meta, applying the scope cap.
    When max_turns_override is set, it is clamped to [1, cap].
    When absent, timeout_seconds / 20 is used as a heuristic. *)
let effective_max_turns (meta : Worker_container_types.worker_container_meta) : int =
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
    (meta : Worker_container_types.worker_container_meta)
    ~(system_prompt : string) : Oas.Types.agent_config =
  let max_tokens = Worker_container_types.local_worker_max_tokens () in
  {
    Oas.Types.default_config with
    name = meta.worker_name;
    model = oas_model_of_effective_model meta.effective_model;
    system_prompt = Some system_prompt;
    max_tokens;
    max_turns = effective_max_turns meta;
    temperature = Some Oas_worker_cascade.worker_temperature;
    top_p = Some Oas_worker_cascade.worker_top_p;
    top_k = Some Oas_worker_cascade.worker_top_k;
    min_p = Some Oas_worker_cascade.worker_min_p;
    enable_thinking = Some (Option.value ~default:false meta.thinking_enabled);
    tool_choice = Some Oas.Types.Auto;
  }

(* ================================================================ *)
(* Metadata -> key-value pairs for description/context               *)
(* ================================================================ *)

(** Encode MASC-specific worker metadata as a human-readable description
    string. This preserves context (role, scope, team session, worker
    class) that has no direct OAS equivalent. *)
let description_of_meta (meta : Worker_container_types.worker_container_meta) : string =
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
  (match meta.worker_class with
   | Some cls -> add "worker_class" (Team_session_types.worker_class_to_string cls)
   | None -> ());
  String.concat "\n" (List.rev !lines)

(* ================================================================ *)
(* OAS Provider from MASC model_spec                                 *)
(* ================================================================ *)

(** Re-use the existing provider mapping from worker_container. *)
let oas_provider_of_label = Worker_container.oas_provider_of_label

(* ================================================================ *)
(* execution_scope -> gate_config                                    *)
(* ================================================================ *)

(** Derive Eval_gate.gate_config from execution_scope.
    Observe_only: strict allowlist (read-only tools), low budget.
    Limited_code_change: moderate budget, deny destructive bash.
    Autonomous: permissive, higher budget. *)
(* Destructive operations denied in all non-autonomous scopes. *)
let destructive_denied_tools =
  [ "shell_exec_dangerous"; "git_push_force"; "rm_rf" ]

(* Code mutation tools additionally denied in observe_only scope. *)
let code_mutation_denied_tools =
  [ "keeper_bash";
    "masc_code_write"; "masc_code_edit"; "masc_code_delete";
    "masc_code_shell"; "masc_code_git" ]

(* MASC state-mutating tools denied in observe_only scope.
   Observe_only workers should only read coordination state, not modify it.
   Includes SDK aliases (masc_set_current_task, masc_complete_task) to
   prevent bypass via alias routing. *)
let masc_mutating_denied_tools =
  [ "masc_add_task"; "masc_claim_next"; "masc_transition";
    "masc_complete_task";  (* alias of masc_transition *)
    "masc_board_post"; "masc_board_comment"; "masc_board_vote";
    "masc_worktree_create"; "masc_worktree_remove";
    "masc_portal_open"; "masc_portal_send"; "masc_portal_close";
    "masc_plan_set_task"; "masc_plan_clear_task";
    "masc_set_current_task";  (* alias of masc_plan_set_task *)
    "masc_run_init"; "masc_run_plan"; "masc_run_log";
    "masc_run_deliverable";
    "masc_repair_loop_start"; "masc_repair_loop_iterate";
    "masc_repair_loop_stop";
    "masc_operator_action"; "masc_operator_confirm";
    "masc_room_delete"; "masc_admin_cleanup"; "masc_admin_reset";
    "masc_gc_force"; "masc_spawn"; "masc_force_leave";
    "masc_config_set"; "masc_execute" ]

(* Local model (Qwen3.5 Q4) — no cloud cost, so generous turn budget. *)
let local_model_gate =
  { Eval_gate.default_config with
    destructive_check_enabled = true;
    max_tool_calls_per_turn = 30;
    max_cost_usd = 1.00;
  }

(* Boundary: MASC selects the internal retry policy, but OAS owns
   retry classification, feedback synthesis, and loop control. *)
let default_internal_tool_retry_policy =
  Oas.Tool_retry_policy.default_internal

let tool_policy_of_execution_scope
    (scope : Team_session_types.execution_scope) : Tool_access_policy.t =
  match scope with
  | Observe_only ->
      {
        Tool_access_policy.allow = Tool_access_policy.All;
        deny =
          Tool_access_policy.union
            [
              Tool_access_policy.Names destructive_denied_tools;
              Tool_access_policy.Names code_mutation_denied_tools;
              Tool_access_policy.Names masc_mutating_denied_tools;
            ];
      }
  | Limited_code_change ->
      {
        Tool_access_policy.allow = Tool_access_policy.All;
        deny = Tool_access_policy.Names destructive_denied_tools;
      }
  | Autonomous ->
      Tool_access_policy.allow_all

let gate_config_of_execution_scope
    (scope : Team_session_types.execution_scope) : Eval_gate.gate_config =
  let tool_policy = tool_policy_of_execution_scope scope in
  let denied_tools =
    Tool_access_policy.resolve_selector tool_policy.deny
  in
  match scope with
  | Observe_only ->
      { local_model_gate with
        denied_tools;
      }
  | Limited_code_change ->
      { local_model_gate with
        denied_tools;
      }
  | Autonomous ->
      { Eval_gate.default_config with
        max_tool_calls_per_turn = 20;
        max_cost_usd = 0.50;
      }

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
    ~(provider : Oas.Provider.config)
    ~(system_prompt : string)
    ~(tools : Oas.Tool.t list)
    ~(hooks : Oas.Hooks.hooks)
    ~(raw_trace : Oas.Raw_trace.t)
    ~(heartbeat_callbacks : Oas.Agent.periodic_callback list)
    ?(gate_config : Eval_gate.gate_config option)
    ?context_injector
    ?context
    () : (Oas.Agent.t, string) result =
  let config = agent_config_of_worker_meta meta ~system_prompt in
  let tool_names =
    List.map (fun (tool : Oas.Tool.t) -> tool.schema.name) tools
  in
  let guardrails =
    match gate_config with
    | Some gate ->
        Verifier_oas.eval_gate_to_oas_guardrails gate
    | None ->
        {
          Oas.Guardrails.tool_filter = AllowList tool_names;
          max_tool_calls_per_turn = Some Oas_worker_cascade.worker_max_tool_calls_per_turn;
        }
  in
  let builder =
    Oas.Builder.create ~net ~model:config.model
    |> Oas.Builder.with_name config.name
    |> Oas.Builder.with_system_prompt system_prompt
    |> Oas.Builder.with_max_tokens config.max_tokens
    |> Oas.Builder.with_max_turns config.max_turns
    |> Oas.Builder.with_temperature Oas_worker_cascade.worker_temperature
    |> Oas.Builder.with_top_p Oas_worker_cascade.worker_top_p
    |> Oas.Builder.with_top_k Oas_worker_cascade.worker_top_k
    |> Oas.Builder.with_min_p Oas_worker_cascade.worker_min_p
    |> Oas.Builder.with_enable_thinking
         (Option.value ~default:false meta.thinking_enabled)
    |> Oas.Builder.with_tool_choice Oas.Types.Auto
    |> Oas.Builder.with_provider provider
    |> Oas.Builder.with_tools tools
    |> Oas.Builder.with_hooks hooks
    |> Oas.Builder.with_guardrails guardrails
    |> Oas.Builder.with_tool_retry_policy default_internal_tool_retry_policy
    |> Oas.Builder.with_raw_trace raw_trace
    |> Oas.Builder.with_periodic_callbacks heartbeat_callbacks
    |> Oas.Builder.with_description (description_of_meta meta)
  in
  let builder = match context_injector with
    | Some ci -> Oas.Builder.with_context_injector ci builder
    | None -> builder
  in
  let builder = match context with
    | Some ctx -> Oas.Builder.with_context ctx builder
    | None -> builder
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
  let interval = Worker_container_types.local_worker_heartbeat_interval_sec () in
  if interval <= 0 then []
  else
    [
      {
        Oas.Agent_types.interval_sec = float_of_int interval;
        callback =
          (fun () ->
            match
              Worker_container_types.call_masc_tool ~sw ~auth_token
                ~session_id ~tool_name:"masc_heartbeat" ~args:(`Assoc [])
            with
            | Ok _ -> ()
            | Error e ->
              Log.LocalWorker.warn "heartbeat error for %s: %s"
                worker_name e);
      };
    ]


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

(** Extract command-like content from tool input JSON for screening.
    Reads "command", "cmd", "content", "action"/"args", or "path" keys.
    Shared pattern with keeper_hooks_oas.ml extract_command_from_input. *)
let extract_command_from_input (input : Yojson.Safe.t) : string =
  let open Yojson.Safe.Util in
  let string_member key =
    match input |> member key with
    | `String s -> s
    | _ -> ""
  in
  let member_to_string key =
    match input |> member key with
    | `Null -> ""
    | value -> string_of_screening_value value
  in
  try
    let command = string_member "command" in
    if command <> "" then command
    else
      let cmd = string_member "cmd" in
      if cmd <> "" then cmd
      else
        let content = string_member "content" in
        if content <> "" then content
        else
          let action = string_member "action" in
          let args = member_to_string "args" in
          (match action, args with
           | "", "" ->
             let path = string_member "path" in
             if path <> "" then path else ""
           | a, "" -> a
           | "", b -> b
           | a, b  -> String.trim (a ^ " " ^ b))
  with Yojson.Safe.Util.Type_error _ -> ""

(** Render inline skip reason for blocked tool calls.
    Returns a text block that OAS displays instead of executing the tool. *)
let render_worker_skip_reason ~tool_name ~reason_code ~reason_text =
  Printf.sprintf
    "[tool_blocked] tool=%s reason_code=%s reason=%s"
    tool_name reason_code reason_text

(** Build pre_tool_use hook with optional safety gates.

    When [gate_config] is provided, adds 3-gate defense-in-depth
    (same pattern as keeper_hooks_oas.ml):
    - Gate 0: Deny list — reject tools in [gate_config.denied_tools]
    - Gate 1: Cost budget — reject when [accumulated_cost_usd >= max_cost_usd]
    - Gate 2: Destructive pattern detection — reject dangerous shell commands

    When [gate_config] is None, only name tracking is performed (backward compat).

    @since Audit #2 — Worker safety gates *)
let make_tool_tracking_hooks ?gate_config ?context () =
  let tool_names_ref = ref [] in
  let tracking =
    {
      Oas.Hooks.empty with
      pre_tool_use =
        Some
          (fun event ->
            match event with
            | Oas.Hooks.PreToolUse { tool_name; input; accumulated_cost_usd; _ } ->
              (* Always track tool names *)
              tool_names_ref := tool_name :: !tool_names_ref;
              (* Safety gates (when gate_config is provided) *)
              (match gate_config with
               | None -> Oas.Hooks.Continue
               | Some (gate : Eval_gate.gate_config) ->
                 (* Gate 0: Deny list *)
                 if Tool_access_policy.selector_matches_name
                      (Tool_access_policy.Names gate.denied_tools)
                      tool_name
                 then begin
                   Log.LocalWorker.warn "worker deny list: blocked %s"
                     tool_name;
                   Oas.Hooks.Override
                     (render_worker_skip_reason
                        ~tool_name
                        ~reason_code:"worker_deny"
                        ~reason_text:"tool is on the worker deny list")
                 end
                 else
                 (* Gate 1: Cost budget *)
                 if accumulated_cost_usd >= gate.max_cost_usd then begin
                   let reason_text =
                     Printf.sprintf
                       "accumulated_cost_usd=%.4f exceeded limit=%.4f"
                       accumulated_cost_usd gate.max_cost_usd
                   in
                   Log.LocalWorker.warn
                     "worker cost gate: $%.4f >= $%.4f limit, skipping %s"
                     accumulated_cost_usd gate.max_cost_usd tool_name;
                   Oas.Hooks.Override
                     (render_worker_skip_reason
                        ~tool_name ~reason_code:"cost_gate" ~reason_text)
                 end
                 else
                 (* Gate 2: Destructive pattern detection *)
                 if gate.destructive_check_enabled
                    && Tool_dispatch.is_destructive tool_name
                 then
                   let cmd = extract_command_from_input input in
                   (match Eval_gate.detect_destructive cmd with
                    | Some (pattern, desc) ->
                      let reason_text =
                        Printf.sprintf "pattern='%s' (%s)" pattern desc
                      in
                      Log.LocalWorker.warn
                        "worker destructive pattern in %s: '%s' (%s)"
                        tool_name pattern desc;
                      Oas.Hooks.Override
                        (render_worker_skip_reason
                           ~tool_name
                           ~reason_code:"destructive_guard"
                           ~reason_text)
                    | None -> Oas.Hooks.Continue)
                 else
                   Oas.Hooks.Continue)
            | _ -> Oas.Hooks.Continue);
      on_error = Some (function
        | Oas.Hooks.OnError { detail; context = err_ctx } ->
          Log.LocalWorker.warn "worker on_error: %s (context: %s)"
            detail err_ctx;
          Oas.Hooks.Continue
        | _ -> Oas.Hooks.Continue);
      on_tool_error = Some (function
        | Oas.Hooks.OnToolError { tool_name; error } ->
          Log.LocalWorker.warn "worker tool_error: %s — %s"
            tool_name error;
          Oas.Hooks.Continue
        | _ -> Oas.Hooks.Continue);
    }
  in
  let hooks = match context with
    | Some ctx ->
      let temporal =
        { Oas.Hooks.empty with
          before_turn_params =
            Some (function
              | Oas.Hooks.BeforeTurnParams { current_params; _ } ->
                (match Masc_context_injector.render_temporal_summary ctx with
                 | None -> Oas.Hooks.Continue
                 | Some summary ->
                   let ctx_str = match current_params.Oas.Hooks.extra_system_context with
                     | None -> summary
                     | Some prev -> prev ^ "\n\n" ^ summary
                   in
                   Oas.Hooks.AdjustParams { current_params with
                     extra_system_context = Some ctx_str })
              | _ -> Oas.Hooks.Continue);
        }
      in
      Oas.Hooks.compose ~outer:temporal ~inner:tracking
    | None -> tracking
  in
  (tool_names_ref, hooks)

let resume_model_id_of_checkpoint
    (meta : Worker_container_types.worker_container_meta)
    (checkpoint : Oas.Checkpoint.t) =
  if checkpoint.model <> "" then checkpoint.model else meta.effective_model

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
    ~(meta : Worker_container_types.worker_container_meta)
    ~(provider : Oas.Provider.config)
    ~(system_prompt : string)
    ~(prompt : string)
    ~(tools : Oas.Tool.t list)
    ~(raw_trace : Oas.Raw_trace.t)
    ?(gate_config : Eval_gate.gate_config option)
    ?contract
    ?worker_run_id
    () : (Worker_container_types.run_result, string) result =
  let session_id = meta.mcp_session_id in
  let team_session_id = meta.team_session_id in
  let worker_name = meta.worker_name in
  let* auth_token =
    Worker_container_types.worker_auth_token ~base_path ~worker_name
  in
  let heartbeat_cbs =
    make_heartbeat_callbacks ~sw ~auth_token ~session_id ~worker_name
  in
  let injector_config = Masc_context_injector.default_config () in
  let context_injector = Masc_context_injector.make ~config:injector_config () in
  let shared_context = Oas.Context.create () in
  let tool_names_ref, hooks = make_tool_tracking_hooks ?gate_config ~context:shared_context () in
  let* agent =
    build_agent ~net ~meta ~provider ~system_prompt ~tools ~hooks
      ~raw_trace ~heartbeat_callbacks:heartbeat_cbs ?gate_config
      ~context_injector ~context:shared_context ()
  in
  let* () =
    Worker_container.save_worker_meta ~base_path
      ~team_session_id ~worker_name meta
  in
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Worker_container_types.leave_worker ~sw ~auth_token
           ~session_id ~worker_name))
    (fun () ->
      let _ =
        match
          Worker_container_types.join_worker ~sw ~auth_token
            ~session_id ~worker_name
        with
        | Ok _ -> ()
        | Error e -> raise (Failure ("worker join failed: " ^ e))
      in
      let workspace_path =
        if String.trim meta.workspace_path <> "" then meta.workspace_path
        else base_path
      in
      run_existing_worker_agent ~sw ~base_path ~meta ~prompt ~workspace_path
        ~raw_trace ?worker_run_id ?contract ~tool_names_ref agent)

and resume_worker_via_oas
    ~(sw : Eio.Switch.t)
    ~(net : [> `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(base_path : string)
    ~(meta : Worker_container_types.worker_container_meta)
    ~(checkpoint : Oas.Checkpoint.t)
    ~(prompt : string)
    ~(tools : Oas.Tool.t list)
    ~(raw_trace : Oas.Raw_trace.t)
    ?contract
    ?worker_run_id
    () : (Worker_container_types.run_result, string) result =
  let worker_name = meta.worker_name in
  let session_id = meta.mcp_session_id in
  let* auth_token =
    Worker_container_types.worker_auth_token ~base_path ~worker_name
  in
  let heartbeat_cbs =
    make_heartbeat_callbacks ~sw ~auth_token ~session_id ~worker_name
  in
  let injector_config = Masc_context_injector.default_config () in
  let context_injector = Masc_context_injector.make ~config:injector_config () in
  let shared_context = Oas.Context.copy checkpoint.context in
  let gate_config = gate_config_of_execution_scope meta.execution_scope in
  let tool_names_ref, hooks = make_tool_tracking_hooks ~gate_config ~context:shared_context () in
  let resume_model_id = resume_model_id_of_checkpoint meta checkpoint in
  let* resume_provider =
    oas_provider_of_label (Provider_adapter.make_local_label resume_model_id)
    |> Result.map_error (fun e ->
      Printf.sprintf "checkpoint resume (model %S): %s" resume_model_id e)
  in
  let system_prompt =
    Worker_container_types.default_system_prompt ~worker_name
      ~model_id:resume_model_id ?session_id:meta.team_session_id ?role:meta.role
      ?selection_note:meta.selection_note ()
  in
  let max_turns = effective_max_turns meta in
  let thinking_enabled =
    Option.value ~default:false meta.thinking_enabled
  in
  let guardrails =
    Verifier_oas.eval_gate_to_oas_guardrails gate_config
  in
  let config, options =
    Worker_container.build_resume_config ~worker_name
      ~provider:resume_provider ~model_id:resume_model_id ~system_prompt ~tools
      ~max_turns ~thinking_enabled ~hooks ~raw_trace
      ~periodic_callbacks:heartbeat_cbs ~guardrails
      ~tool_retry_policy:default_internal_tool_retry_policy ()
  in
  let options = { options with
    Oas.Agent_types.context_injector = Some context_injector } in
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Worker_container_types.leave_worker ~sw ~auth_token ~session_id
           ~worker_name))
    (fun () ->
      let _ =
        match
          Worker_container_types.join_worker ~sw ~auth_token ~session_id
            ~worker_name
        with
        | Ok _ -> ()
        | Error e -> raise (Failure ("worker join failed: " ^ e))
      in
      let agent =
        Oas.Agent.resume ~net ~checkpoint ~tools ~options ~config
          ~context:shared_context ()
      in
      let workspace_path =
        if String.trim meta.workspace_path <> "" then meta.workspace_path
        else base_path
      in
      run_existing_worker_agent ~sw ~base_path ~meta ~prompt ~workspace_path
        ~raw_trace ?worker_run_id ?contract ~tool_names_ref agent)

and run_existing_worker_agent
    ~(sw : Eio.Switch.t)
    ~(base_path : string)
    ~(meta : Worker_container_types.worker_container_meta)
    ~(prompt : string)
    ~(workspace_path : string)
    ~(raw_trace : Oas.Raw_trace.t)
    ?worker_run_id
    ?contract
    ~(tool_names_ref : string list ref)
    (agent : Oas.Agent.t)
  : (Worker_container_types.run_result, string) result =
  let team_session_id = meta.team_session_id in
  let worker_name = meta.worker_name in
  let session_id = meta.mcp_session_id in
  Fun.protect
    ~finally:(fun () ->
      try Oas.Agent.close agent
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          Log.LocalWorker.warn "agent close failed for %s: %s" worker_name
            (Printexc.to_string exn))
    (fun () ->
      let result, proof = match contract with
        | Some c ->
          let cr = Oas.Contract_runner.run ~sw ~contract:c agent prompt in
          (cr.response, Some cr.proof)
        | None ->
          (Oas.Agent.run ~sw agent prompt, None)
      in
      let raw_trace_run = Oas.Agent.last_raw_trace_run agent in
      let checkpoint = Oas.Agent.checkpoint ~session_id agent in
      let tool_names =
        List.rev !tool_names_ref
        |> Worker_container_types.unique_preserve_order
      in
      let* () =
        Worker_container.save_worker_checkpoint ~base_path
          ~team_session_id ~worker_name checkpoint
      in
      let* () =
        Worker_container.save_worker_meta ~base_path
          ~team_session_id ~worker_name
          { meta with last_run_at = Some (Time_compat.now ()) }
      in
      Worker_container.materialize_direct_evidence
        ~base_path ~worker_name ~worker_run_id ~meta ~prompt ~workspace_path
        ~agent ~raw_trace;
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
            Worker_container.append_worker_completion_log
              ~base_path ~team_session_id ~worker_name ~prompt ~tool_names
              ~status:"ok" ~output ()
          in
          Ok
            {
              Worker_container_types.output;
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
              api_response = Some response;
              proof;
            }
      | Error err ->
          let detail = Oas.Error.to_string err in
          (match proof with
           | Some p ->
             Log.LocalWorker.warn
               "worker %s errored with CDAL proof: run_id=%s status=%s error=%s"
               worker_name p.run_id
               (proof_result_status_to_string p.result_status)
               detail
           | None ->
             Log.LocalWorker.warn "worker %s errored (no proof): %s" worker_name detail);
          let* () =
            Worker_container.append_worker_completion_log
              ~base_path ~team_session_id ~worker_name ~prompt ~tool_names
              ~status:"error" ~output:detail ~error:detail ()
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
    ~(workers : (Worker_container_types.worker_container_meta
                 * Oas.Provider.config
                 * string (* system_prompt *)
                 * Oas.Tool.t list
                 * Oas.Raw_trace.t
                 * Oas.Agent.periodic_callback list) list)
    ~(plan : Oas.Orchestrator.plan)
    ?on_task_start
    ?on_task_complete
    () : (Oas.Orchestrator.task_result list, string) result =
  let rec build_agents acc = function
    | [] -> Ok (List.rev acc)
    | ((meta : Worker_container_types.worker_container_meta), provider, system_prompt, tools, raw_trace, heartbeat_cbs) :: rest ->
      let gate_config = gate_config_of_execution_scope meta.execution_scope in
      let tool_names_ref, hooks = make_tool_tracking_hooks ~gate_config () in
      let* agent =
        build_agent ~net ~meta ~provider ~system_prompt ~tools ~hooks
          ~raw_trace ~heartbeat_callbacks:heartbeat_cbs
          ~gate_config ()
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
