(** Keeper_guards — composable pre_tool_use hooks for keeper agents.

    Decomposes the previously monolithic [pre_tool_use] guard chain
    (streak / deny / cost / destructive / governance) into standalone
    OAS [Hooks.hooks] records that stack via
    [Agent_sdk.Hooks.compose]. Each guard fills only the
    [pre_tool_use] slot; composition short-circuits on the first
    non-[Continue] decision.

    Design principles:
    - Public SDK boundary (C0): OAS is consumed as-is. No OAS-side
      edits. All keeper-specific state lives in MASC closures.
    - MASC/OAS boundary (C1): OAS primitives do not learn about
      keepers. [meta_ref], deny lists, streak thresholds, and cost
      limits stay on the MASC side.
    - Observability (C2): every override / approval decision emits a
      [masc:keeper_gate] Event_bus Custom event in addition to the
      existing [broadcast_tool_skipped] SSE call. The dual emit lets
      downstream consumers migrate without coordinating with this
      change. Payload carries stage/reason/latency so dashboards can
      chart per-stage firing rates and drift.

    @since T1-A — pre_tool_use guard decomposition *)

(* ─────────────────────────────────────────────────────────────────── *)
(* Spec navigation (OCaml -> TLA+) — KeeperTurnCycle composite anchor. *)
(* ─────────────────────────────────────────────────────────────────── *)
(*                                                                     *)
(* Authoritative spec mirror is                                        *)
(*   specs/keeper-state-machine/KeeperTurnCycle.tla                    *)
(* (3-axis composite — turn_phase x decision_stage x cascade_state).   *)
(*                                                                     *)
(* This module is one of FOUR cooperating write points; siblings are   *)
(* keeper_registry.ml (raw setters), keeper_unified_turn.ml (top-level *)
(* orchestration), and keeper_agent_run.ml (policy selection).         *)
(* keeper_guards.ml owns a SINGLE spec action:                         *)
(*                                                                     *)
(*   GateRejected — spec line 192-200                                  *)
(*     pre_tool_use override / approval_required short-circuit.        *)
(*     turn_phase: executing -> finalizing                             *)
(*     decision_stage: tool_policy_selected -> gate_rejected           *)
(*     cascade_state preserved at "trying" (UNCHANGED in spec).        *)
(*                                                                     *)
(* Spec inline citation at KeeperTurnCycle.tla:58 says "line 120" —    *)
(* current actual call site of                                         *)
(*   Keeper_registry.mark_turn_gate_rejected_by_name                   *)
(* is line 143 inside [emit_gate_event] (drift +23 since spec was      *)
(* written; spec citation list is module-coarse and survives line      *)
(* shifts within the same function).                                   *)
(*                                                                     *)
(* Cross-axis invariants (KeeperTurnCycle.tla:115-123) most relevant   *)
(* to this file:                                                       *)
(*   - GateRejectedRequiresFinalizing                                  *)
(*       (decision_stage = "gate_rejected" => turn_phase = "finalizing")*)
(*   - TerminalCascadeRequiresFinalizing                               *)
(*                                                                     *)
(* These cross-axis invariants are why KeeperTurnCycle exists          *)
(* alongside the single-axis siblings (KeeperDecisionPipeline,         *)
(* KeeperCascadeLifecycle, KeeperConditionsGovernPhase): no single     *)
(* axis can express the conjunction across phase x decision x cascade. *)
(* ─────────────────────────────────────────────────────────────────── *)

(* -------------------------------------------------------------- *)
(* Shared utilities previously inline in [keeper_hooks_oas]        *)
(* -------------------------------------------------------------- *)


(** Gate decision types, emission infrastructure, and shared utilities
    extracted to [Keeper_guards_emit].  Guard implementations below. *)

include Keeper_guards_emit

(** Mutable streak state captured by [streak_guard]. *)
type streak_state = { mutable entry : string * int }

let make_streak_state () : streak_state = { entry = ("", 0) }

(* -------------------------------------------------------------- *)
(* Timing guard — records tool_start_time for post_tool_use use    *)
(* -------------------------------------------------------------- *)

(** Record the tool start timestamp so [post_tool_use] can compute
    latency. Returns [Continue] unconditionally. Should be composed
    FIRST in the chain so the timestamp is set even when a later
    guard returns [Override]. *)
let timing_guard ~(tool_start_time : float ref)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse _ ->
      tool_start_time := Time_compat.now ();
      Agent_sdk.Hooks.Continue
    | _ -> Agent_sdk.Hooks.Continue)

(* -------------------------------------------------------------- *)
(* Individual guards                                               *)
(* -------------------------------------------------------------- *)

(** User-supplied custom guard. Short-circuits via [Override] when
    the caller's callback returns [Some reason_text]. *)
let custom_guard
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~on_gate_decision
    ~(guard : tool_name:string -> input:Yojson.Safe.t -> string option)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; _ } ->
      let t0 = Time_compat.now () in
      let keeper_name = (!meta_ref).Keeper_types.name in
      (match guard ~tool_name ~input with
       | Some reason ->
         let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
         Log.Keeper.info
           "keeper:%s pre_tool_use guard blocked %s"
           keeper_name tool_name;
         broadcast_tool_skipped
           ~keeper_name ~tool_name ~reason_code:"pre_tool_use_guard";
         let source_path = keeper_guards_source_path in
         let source_line = __LINE__ in
         report_gate_decision on_gate_decision
           ~source_path:(Some source_path) ~source_line:(Some source_line)
           ~stage:"pre_tool_use_guard" ~decision:Gate_override
           ~reason_code:"pre_tool_use_guard" ~reason_text:reason
           ~tool_name ~keeper_name ~input ~turn ~accumulated_cost_usd
           ~stage_latency_ms:latency_ms;
         Agent_sdk.Hooks.Override
           (render_inline_skip_reason_with_source
              ~source_path ~source_line
              ~tool_name ~reason_code:"pre_tool_use_guard"
              ~reason_text:reason)
       | None -> Agent_sdk.Hooks.Continue)
    | _ -> Agent_sdk.Hooks.Continue)

(** Same-name streak gate: block when the same tool name is called
    [threshold+] times consecutively, regardless of args. OAS idle
    detection requires exact name+args match, so this catches the
    "same operation, different targets" pattern (e.g. reading 20
    board posts one by one). *)
let streak_guard
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~on_gate_decision
    ~(state : streak_state)
    ~(threshold : int)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; _ } ->
      let t0 = Time_compat.now () in
      let keeper_name = (!meta_ref).Keeper_types.name in
      let prev_name, prev_count = state.entry in
      let new_count =
        if prev_name = tool_name then prev_count + 1 else 1
      in
      state.entry <- (tool_name, new_count);
      if new_count >= threshold then begin
        let reason_text =
          Printf.sprintf
            "%s called %d times consecutively. Use a DIFFERENT tool or keeper_stay_silent"
            tool_name new_count
        in
        let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_guards_failures
          ~labels:[("keeper", keeper_name); ("site", "streak_gate")]
          ();
        log_gate_rejection
          ~keeper_name ~stage:"streak_gate" ~tool_name
          ~reason_code:"streak_gate"
          "keeper:%s streak_gate: %s called %d times consecutively, blocking"
          keeper_name tool_name new_count;
        broadcast_tool_skipped
          ~keeper_name ~tool_name ~reason_code:"streak_gate";
        let source_path = keeper_guards_source_path in
        let source_line = __LINE__ in
        report_gate_decision on_gate_decision
          ~source_path:(Some source_path) ~source_line:(Some source_line)
          ~stage:"streak_gate" ~decision:Gate_override
          ~reason_code:"streak_gate" ~reason_text
          ~tool_name ~keeper_name ~input ~turn ~accumulated_cost_usd
          ~stage_latency_ms:latency_ms;
        Agent_sdk.Hooks.Override
          (render_inline_skip_reason_with_source
             ~source_path ~source_line
             ~tool_name ~reason_code:"streak_gate" ~reason_text)
      end
      else Agent_sdk.Hooks.Continue
    | _ -> Agent_sdk.Hooks.Continue)

(** Keeper deny list. Block administrative / destructive tools that
    should only be invoked by operators or controlled workflows. *)
let deny_guard
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~on_gate_decision
    ~(denied : string list)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; _ } ->
      let t0 = Time_compat.now () in
      let keeper_name = (!meta_ref).Keeper_types.name in
      if List.mem tool_name denied then begin
        let reason_text = "tool is on the keeper deny list" in
        let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_guards_failures
          ~labels:[("keeper", keeper_name); ("site", "deny_list")]
          ();
        log_gate_rejection
          ~keeper_name ~stage:"keeper_deny" ~tool_name
          ~reason_code:"keeper_deny"
          "keeper:%s deny list: blocked %s"
          keeper_name tool_name;
        broadcast_tool_skipped
          ~keeper_name ~tool_name ~reason_code:"keeper_deny";
        let source_path = keeper_guards_source_path in
        let source_line = __LINE__ in
        report_gate_decision on_gate_decision
          ~source_path:(Some source_path) ~source_line:(Some source_line)
          ~stage:"keeper_deny" ~decision:Gate_override
          ~reason_code:"keeper_deny" ~reason_text
          ~tool_name ~keeper_name ~input ~turn ~accumulated_cost_usd
          ~stage_latency_ms:latency_ms;
        Agent_sdk.Hooks.Override
          (render_inline_skip_reason_with_source
             ~source_path ~source_line
             ~tool_name ~reason_code:"keeper_deny" ~reason_text)
      end
      else Agent_sdk.Hooks.Continue
    | _ -> Agent_sdk.Hooks.Continue)

(** Cost budget gate: reject when the running cost meets or exceeds
    [limit]. No-op when [max_cost_usd] is [None]. *)
let cost_guard
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~on_gate_decision
    ~(max_cost_usd : float option)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; _ } ->
      let t0 = Time_compat.now () in
      let keeper_name = (!meta_ref).Keeper_types.name in
      (match max_cost_usd with
       | Some limit when accumulated_cost_usd >= limit ->
         let reason_text =
           Printf.sprintf
             "accumulated_cost_usd=%.4f exceeded limit=%.4f"
             accumulated_cost_usd limit
         in
         let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_guards_failures
           ~labels:[("keeper", keeper_name); ("site", "cost_gate")]
           ();
         log_gate_rejection
           ~keeper_name ~stage:"cost_gate" ~tool_name
           ~reason_code:"cost_gate"
           "keeper:%s cost gate: $%.4f >= $%.4f limit, skipping %s"
           keeper_name accumulated_cost_usd limit tool_name;
         broadcast_tool_skipped
           ~keeper_name ~tool_name ~reason_code:"cost_gate";
         let source_path = keeper_guards_source_path in
         let source_line = __LINE__ in
         report_gate_decision on_gate_decision
           ~source_path:(Some source_path) ~source_line:(Some source_line)
           ~stage:"cost_gate" ~decision:Gate_override
           ~reason_code:"cost_gate" ~reason_text
           ~tool_name ~keeper_name ~input ~turn ~accumulated_cost_usd
           ~stage_latency_ms:latency_ms;
         Agent_sdk.Hooks.Override
           (render_inline_skip_reason_with_source
              ~source_path ~source_line
              ~tool_name ~reason_code:"cost_gate" ~reason_text)
       | _ -> Agent_sdk.Hooks.Continue)
    | _ -> Agent_sdk.Hooks.Continue)

(** Destructive pattern detection for bash/edit style tools.
    Only applies when [enabled] is [true] and the tool is flagged by
    [Tool_dispatch.is_destructive]. *)
let destructive_guard
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~on_gate_decision
    ~(enabled : bool)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; _ } ->
      if not enabled then Agent_sdk.Hooks.Continue
      else if not (Tool_dispatch.is_destructive tool_name) then
        Agent_sdk.Hooks.Continue
      else
        let t0 = Time_compat.now () in
        let keeper_name = (!meta_ref).Keeper_types.name in
        let cmd = extract_command_from_input input in
        (match Eval_gate.detect_destructive cmd with
         | None -> Agent_sdk.Hooks.Continue
         | Some (pattern, desc) ->
           let reason_text =
             Printf.sprintf "pattern='%s' (%s)" pattern desc
           in
           let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_guards_failures
             ~labels:[("keeper", keeper_name); ("site", "destructive_guard")]
             ();
           log_gate_rejection
             ~keeper_name ~stage:"destructive_guard" ~tool_name
             ~reason_code:"destructive_guard" ~reason_key:pattern
             "keeper:%s destructive pattern in %s: '%s' (%s)"
             keeper_name tool_name pattern desc;
           broadcast_tool_skipped
             ~keeper_name ~tool_name ~reason_code:"destructive_guard";
           let source_path = keeper_guards_source_path in
           let source_line = __LINE__ in
           report_gate_decision on_gate_decision
             ~source_path:(Some source_path) ~source_line:(Some source_line)
             ~stage:"destructive_guard" ~decision:Gate_override
             ~reason_code:"destructive_guard" ~reason_text
             ~tool_name ~keeper_name ~input ~turn ~accumulated_cost_usd
             ~stage_latency_ms:latency_ms;
           Agent_sdk.Hooks.Override
             (render_inline_skip_reason_with_source
                ~source_path ~source_line
                ~tool_name ~reason_code:"destructive_guard"
                ~reason_text))
    | _ -> Agent_sdk.Hooks.Continue)

(** Governance approval gate. Escalates via [ApprovalRequired] when
    the assessed risk level meets or exceeds the configured keeper
    confirm threshold. Relies on an approval callback wired into the
    agent Builder to resolve the decision. *)
let governance_approval_guard
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~on_gate_decision
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; _ } ->
      let t0 = Time_compat.now () in
      let keeper_name = (!meta_ref).Keeper_types.name in
      let governance_level = Env_config_core.governance_level () in
      let risk = Governance_pipeline.assess_risk ~tool_name ~input in
      let needs_approval =
        match Governance_pipeline.keeper_confirm_threshold governance_level with
        | Some threshold ->
          Governance_pipeline.risk_level_to_int risk
          >= Governance_pipeline.risk_level_to_int threshold
        | None -> false
      in
      if needs_approval then begin
        let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
        let source_path = keeper_guards_source_path in
        let source_line = __LINE__ in
        report_gate_decision on_gate_decision
          ~source_path:(Some source_path) ~source_line:(Some source_line)
          ~stage:"governance_approval" ~decision:Gate_approval_required
          ~reason_code:"governance_approval"
          ~reason_text:"risk threshold reached; operator approval required"
          ~tool_name ~keeper_name ~input ~turn ~accumulated_cost_usd
          ~stage_latency_ms:latency_ms;
        Agent_sdk.Hooks.ApprovalRequired
      end
      else Agent_sdk.Hooks.Continue
    | _ -> Agent_sdk.Hooks.Continue)

(* -------------------------------------------------------------- *)
(* Chain assembly                                                  *)
(* -------------------------------------------------------------- *)

(** Build the full keeper pre_tool_use chain.

    Order matters: the first guard to return a non-[Continue]
    decision wins (short-circuit via [Hooks.compose]). Preserves the
    ordering of the previous monolithic implementation:
      timing -> custom -> streak -> deny -> cost -> destructive ->
      governance_approval *)
let build_chain
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~(tool_start_time : float ref)
    ~(streak_state : streak_state)
    ~(streak_threshold : int)
    ~(denied : string list)
    ~(max_cost_usd : float option)
    ~(destructive_check : bool)
    ~on_gate_decision
    ~(pre_tool_use_guard :
        tool_name:string -> input:Yojson.Safe.t -> string option)
  : Agent_sdk.Hooks.hooks =
  compose_all [
    timing_guard ~tool_start_time;
    custom_guard ~meta_ref ~on_gate_decision ~guard:pre_tool_use_guard;
    streak_guard ~meta_ref ~on_gate_decision ~state:streak_state ~threshold:streak_threshold;
    deny_guard ~meta_ref ~on_gate_decision ~denied;
    cost_guard ~meta_ref ~on_gate_decision ~max_cost_usd;
    destructive_guard ~meta_ref ~on_gate_decision ~enabled:destructive_check;
    governance_approval_guard ~meta_ref ~on_gate_decision;
  ]
