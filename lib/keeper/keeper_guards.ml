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

(* -------------------------------------------------------------- *)
(* Shared utilities previously inline in [keeper_hooks_oas]        *)
(* -------------------------------------------------------------- *)

(** Percent-encode field value for structured [tool_skipped] output.
    Matches [Keeper_agent_run.escape_field_value]. *)
let escape_field s =
  let buf = Buffer.create (String.length s * 3 / 2 + 1) in
  String.iter (fun ch ->
    match ch with
    | ' ' -> Buffer.add_string buf "%20"
    | '=' -> Buffer.add_string buf "%3D"
    | '\n' -> Buffer.add_string buf "%0A"
    | '\r' -> Buffer.add_string buf "%0D"
    | '\t' -> Buffer.add_string buf "%09"
    | '%' -> Buffer.add_string buf "%25"
    | _ -> Buffer.add_char buf ch) s;
  Buffer.contents buf

(** Render structured skip reason for inline Override injection.
    The LLM sees this as the ToolResult content immediately within
    the same turn. *)
let render_inline_skip_reason ~tool_name ~reason_code ~reason_text : string =
  let replacement_hint =
    match (Tool_catalog.metadata tool_name).Tool_catalog.replacement with
    | Some replacement ->
      Printf.sprintf " replacement=%s" (escape_field replacement)
    | None -> ""
  in
  Printf.sprintf
    "[tool_skipped] tool=%s source=keeper_hook code=%s reason=%s%s"
    (escape_field tool_name)
    (escape_field reason_code)
    (escape_field reason_text)
    replacement_hint

(** Broadcast a tool skip event via SSE for dashboard visibility.
    Also records in [Dashboard_governance_metrics] for aggregation. *)
let broadcast_tool_skipped ~keeper_name ~tool_name ~reason_code =
  Dashboard_governance_metrics.record_tool_skipped
    ~keeper_name ~tool_name ~reason_code;
  (try
    Sse.broadcast
      (`Assoc [
        ("type", `String "keeper_tool_skipped");
        ("name", `String keeper_name);
        ("tool_name", `String tool_name);
        ("reason_code", `String reason_code);
        ("ts_unix", `Float (Unix.gettimeofday ()));
      ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Keeper.warn
        "tool skip SSE broadcast failed: keeper=%s tool=%s reason=%s err=%s"
        keeper_name tool_name reason_code (Printexc.to_string exn))

(** Extract command/content string from tool input JSON for screening. *)
let extract_command_from_input (input : Yojson.Safe.t) : string =
  let open Yojson.Safe.Util in
  try
    match input |> member "command" with
    | `String s -> s
    | `Null | _ ->
      (match input |> member "cmd" with
       | `String s -> s
       | `Null | _ ->
         (match input |> member "content" with
          | `String s -> s
          | _ -> ""))
  with Yojson.Safe.Util.Type_error _ -> ""

(* -------------------------------------------------------------- *)
(* Telemetry                                                       *)
(* -------------------------------------------------------------- *)

(** Emit a [masc:keeper_gate] Event_bus Custom event.

    Payload schema:
    - [stage]               snake_case stage identifier
    - [decision]            "override" | "continue" | "approval_required"
    - [reason_code]         machine-classifiable short code
    - [tool_name]           the tool the gate was evaluating
    - [agent_name]          keeper name
    - [turn]                turn index reported by OAS
    - [accumulated_cost_usd] OAS running cost total
    - [stage_latency_ms]    measured duration of this guard
    - [reason_text]         human-readable detail
    - [source]              "hook" (distinguishes from legacy paths) *)
let emit_gate_event
    ~stage ~decision ~reason_code
    ~tool_name ~agent_name ~turn
    ~accumulated_cost_usd ~stage_latency_ms ~reason_text =
  (match decision with
   | "override" | "approval_required" ->
       Keeper_registry.mark_turn_gate_rejected_by_name agent_name
   | _ -> ());
  match Keeper_event_bus.get () with
  | None -> ()
  | Some bus ->
    let payload = `Assoc [
      ("stage", `String stage);
      ("decision", `String decision);
      ("reason_code", `String reason_code);
      ("tool_name", `String tool_name);
      ("agent_name", `String agent_name);
      ("turn", `Int turn);
      ("accumulated_cost_usd", `Float accumulated_cost_usd);
      ("stage_latency_ms", `Float stage_latency_ms);
      ("reason_text", `String reason_text);
      ("source", `String "hook");
    ] in
    (try
      Agent_sdk.Event_bus.publish bus
        (Agent_sdk.Event_bus.mk_event
           (Agent_sdk.Event_bus.Custom ("masc:keeper_gate", payload)))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Keeper.warn
        "keeper_guards: event emit failed stage=%s tool=%s err=%s"
        stage tool_name (Printexc.to_string exn))

(* -------------------------------------------------------------- *)
(* Composition helpers                                             *)
(* -------------------------------------------------------------- *)

(** Build a [Hooks.hooks] record with only [pre_tool_use] filled. *)
let hooks_of_pre_tool_use (fn : Agent_sdk.Hooks.hook)
  : Agent_sdk.Hooks.hooks =
  { Agent_sdk.Hooks.empty with pre_tool_use = Some fn }

(** Compose a list of hooks via [Hooks.compose], left-to-right.
    Each slot short-circuits on the first non-[Continue] decision. *)
let compose_all (hs : Agent_sdk.Hooks.hooks list)
  : Agent_sdk.Hooks.hooks =
  List.fold_left
    (fun acc h -> Agent_sdk.Hooks.compose ~outer:acc ~inner:h)
    Agent_sdk.Hooks.empty
    hs

(* -------------------------------------------------------------- *)
(* Streak state (shared across invocations for one keeper)         *)
(* -------------------------------------------------------------- *)

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
         emit_gate_event
           ~stage:"pre_tool_use_guard" ~decision:"override"
           ~reason_code:"pre_tool_use_guard"
           ~tool_name ~agent_name:keeper_name ~turn
           ~accumulated_cost_usd
           ~stage_latency_ms:latency_ms
           ~reason_text:reason;
         Agent_sdk.Hooks.Override
           (render_inline_skip_reason
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
    ~(state : streak_state)
    ~(threshold : int)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; accumulated_cost_usd; turn; _ } ->
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
        Log.Keeper.warn
          "keeper:%s streak_gate: %s called %d times consecutively, blocking"
          keeper_name tool_name new_count;
        broadcast_tool_skipped
          ~keeper_name ~tool_name ~reason_code:"streak_gate";
        emit_gate_event
          ~stage:"streak_gate" ~decision:"override"
          ~reason_code:"streak_gate"
          ~tool_name ~agent_name:keeper_name ~turn
          ~accumulated_cost_usd
          ~stage_latency_ms:latency_ms
          ~reason_text;
        Agent_sdk.Hooks.Override
          (render_inline_skip_reason
             ~tool_name ~reason_code:"streak_gate" ~reason_text)
      end
      else Agent_sdk.Hooks.Continue
    | _ -> Agent_sdk.Hooks.Continue)

(** Keeper deny list. Block administrative / destructive tools that
    should only be invoked by operators or controlled workflows. *)
let deny_guard
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~(denied : string list)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; accumulated_cost_usd; turn; _ } ->
      let t0 = Time_compat.now () in
      let keeper_name = (!meta_ref).Keeper_types.name in
      if List.mem tool_name denied then begin
        let reason_text = "tool is on the keeper deny list" in
        let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
        Log.Keeper.warn "keeper:%s deny list: blocked %s"
          keeper_name tool_name;
        broadcast_tool_skipped
          ~keeper_name ~tool_name ~reason_code:"keeper_deny";
        emit_gate_event
          ~stage:"keeper_deny" ~decision:"override"
          ~reason_code:"keeper_deny"
          ~tool_name ~agent_name:keeper_name ~turn
          ~accumulated_cost_usd
          ~stage_latency_ms:latency_ms
          ~reason_text;
        Agent_sdk.Hooks.Override
          (render_inline_skip_reason
             ~tool_name ~reason_code:"keeper_deny" ~reason_text)
      end
      else Agent_sdk.Hooks.Continue
    | _ -> Agent_sdk.Hooks.Continue)

(** Cost budget gate: reject when the running cost meets or exceeds
    [limit]. No-op when [max_cost_usd] is [None]. *)
let cost_guard
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~(max_cost_usd : float option)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; accumulated_cost_usd; turn; _ } ->
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
         Log.Keeper.warn
           "keeper:%s cost gate: $%.4f >= $%.4f limit, skipping %s"
           keeper_name accumulated_cost_usd limit tool_name;
         broadcast_tool_skipped
           ~keeper_name ~tool_name ~reason_code:"cost_gate";
         emit_gate_event
           ~stage:"cost_gate" ~decision:"override"
           ~reason_code:"cost_gate"
           ~tool_name ~agent_name:keeper_name ~turn
           ~accumulated_cost_usd
           ~stage_latency_ms:latency_ms
           ~reason_text;
         Agent_sdk.Hooks.Override
           (render_inline_skip_reason
              ~tool_name ~reason_code:"cost_gate" ~reason_text)
       | _ -> Agent_sdk.Hooks.Continue)
    | _ -> Agent_sdk.Hooks.Continue)

(** Destructive pattern detection for bash/edit style tools.
    Only applies when [enabled] is [true] and the tool is flagged by
    [Tool_dispatch.is_destructive]. *)
let destructive_guard
    ~(meta_ref : Keeper_types.keeper_meta ref)
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
           Log.Keeper.warn
             "keeper:%s destructive pattern in %s: '%s' (%s)"
             keeper_name tool_name pattern desc;
           broadcast_tool_skipped
             ~keeper_name ~tool_name ~reason_code:"destructive_guard";
           emit_gate_event
             ~stage:"destructive_guard" ~decision:"override"
             ~reason_code:"destructive_guard"
             ~tool_name ~agent_name:keeper_name ~turn
             ~accumulated_cost_usd
             ~stage_latency_ms:latency_ms
             ~reason_text;
           Agent_sdk.Hooks.Override
             (render_inline_skip_reason
                ~tool_name ~reason_code:"destructive_guard"
                ~reason_text))
    | _ -> Agent_sdk.Hooks.Continue)

(** Governance approval gate. Escalates via [ApprovalRequired] when
    the assessed risk level meets or exceeds the configured keeper
    confirm threshold. Relies on an approval callback wired into the
    agent Builder to resolve the decision. *)
let governance_approval_guard
    ~(meta_ref : Keeper_types.keeper_meta ref)
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
        emit_gate_event
          ~stage:"governance_approval" ~decision:"approval_required"
          ~reason_code:"governance_approval"
          ~tool_name ~agent_name:keeper_name ~turn
          ~accumulated_cost_usd
          ~stage_latency_ms:latency_ms
          ~reason_text:"risk threshold reached; operator approval required";
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
    ~(pre_tool_use_guard :
        tool_name:string -> input:Yojson.Safe.t -> string option)
  : Agent_sdk.Hooks.hooks =
  compose_all [
    timing_guard ~tool_start_time;
    custom_guard ~meta_ref ~guard:pre_tool_use_guard;
    streak_guard ~meta_ref ~state:streak_state ~threshold:streak_threshold;
    deny_guard ~meta_ref ~denied;
    cost_guard ~meta_ref ~max_cost_usd;
    destructive_guard ~meta_ref ~enabled:destructive_check;
    governance_approval_guard ~meta_ref;
  ]
