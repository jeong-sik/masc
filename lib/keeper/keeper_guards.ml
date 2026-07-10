(** Keeper_guards — composable pre_tool_use hooks for keeper agents.

    Decomposes the previously monolithic [pre_tool_use] guard chain
    (streak / deny / cost / destructive / governance) into standalone
    OAS [Hooks.hooks] records that stack via
    [Agent_sdk.Hooks.compose]. Most guards fill only the
    [pre_tool_use] slot; lifecycle-sensitive guards may also observe
    post-tool slots while still short-circuiting only from
    [pre_tool_use].

    Design principles:
    - Public SDK boundary (C0): OAS is consumed as-is. No OAS-side
      edits. All keeper-specific state lives in MASC closures.
    - MASC/OAS boundary (C1): OAS primitives do not learn about
      keepers. [meta_ref], deny lists, streak thresholds, and cost
      limits stay on the MASC side.
    - Observability (C2): every override / approval decision emits a
      [masc:keeper_gate] Event_bus Custom event in addition to the
      existing [broadcast_tool_skipped] SSE call. The dual emit lets
      downstream consumers migrate without synchronizing with this
      change. Payload carries stage/reason/latency so dashboards can
      chart per-stage firing rates and drift.

    @since T1-A — pre_tool_use guard decomposition *)

(* ─────────────────────────────────────────────────────────────────── *)
(* Spec navigation (OCaml -> TLA+) — KeeperTurnCycle composite anchor. *)
(* ─────────────────────────────────────────────────────────────────── *)
(*                                                                     *)
(* Authoritative spec mirror is                                        *)
(*   specs/keeper-state-machine/KeeperTurnCycle.tla                    *)
(* (3-axis composite — turn_phase x decision_stage x runtime_state).   *)
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
(*     runtime_state preserved at "trying" (UNCHANGED in spec).        *)
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
(*   - TerminalRuntimeRequiresFinalizing                               *)
(*                                                                     *)
(* These cross-axis invariants are why KeeperTurnCycle exists          *)
(* alongside the single-axis siblings (KeeperDecisionPipeline,         *)
(* KeeperRuntimeLifecycle, KeeperConditionsGovernPhase): no single     *)
(* axis can express the conjunction across phase x decision x runtime. *)
(* ─────────────────────────────────────────────────────────────────── *)

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
let keeper_guards_source_path = "lib/keeper/keeper_guards.ml"

let source_hint ~source_path ~source_line =
  match source_path, source_line with
  | None, None -> ""
  | Some path, None ->
    Printf.sprintf " source_path=%s" (escape_field path)
  | None, Some line ->
    Printf.sprintf " source_line=%d" line
  | Some path, Some line ->
    Printf.sprintf " source_path=%s source_line=%d"
      (escape_field path) line

let render_inline_skip_reason_impl ~source_path ~source_line
    ~tool_name ~reason_code ~reason_text : string =
  let replacement_hint =
    match (Tool_catalog.metadata tool_name).Tool_catalog.replacement with
    | Some replacement ->
      Printf.sprintf " replacement=%s" (escape_field replacement)
    | None -> ""
  in
  Printf.sprintf
    "[tool_skipped] tool=%s source=keeper_hook code=%s reason=%s%s%s"
    (escape_field tool_name)
    (escape_field reason_code)
    (escape_field reason_text)
    replacement_hint
    (source_hint ~source_path ~source_line)

let render_inline_skip_reason ~tool_name ~reason_code ~reason_text : string =
  render_inline_skip_reason_impl
    ~source_path:None
    ~source_line:None
    ~tool_name
    ~reason_code
    ~reason_text

let render_inline_skip_reason_with_source
    ~source_path ~source_line ~tool_name ~reason_code ~reason_text : string =
  render_inline_skip_reason_impl
    ~source_path:(Some source_path)
    ~source_line:(Some source_line)
    ~tool_name
    ~reason_code
    ~reason_text

(** Broadcast a tool skip event via SSE for dashboard visibility.
    Also records in [Dashboard_governance_metrics] for aggregation. *)
let broadcast_tool_skipped ~keeper_name ~tool_name ~reason_code =
  Keeper_keepalive_signal.record_tool_skipped
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
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string GuardsFailures)
        ~labels:[("keeper", keeper_name); ("site", "sse_broadcast")]
        ();
      Log.Keeper.warn
        "tool skip SSE broadcast failed: keeper=%s tool=%s reason=%s err=%s"
        keeper_name tool_name reason_code (Printexc.to_string exn))

(** Extract command/content string from tool input JSON for screening. *)
let extract_command_from_input (input : Yojson.Safe.t) : string =
  let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key input) in
  match m "command" with
  | `String s -> s
  | _ ->
    (match m "cmd" with
     | `String s -> s
     | _ ->
       (match m "content" with
        | `String s -> s
        | _ -> ""))

(* -------------------------------------------------------------- *)
(* Telemetry                                                       *)
(* -------------------------------------------------------------- *)

type gate_decision =
  | Gate_override
  | Gate_continue
  | Gate_approval_required
  | Gate_non_author_verified

let gate_decision_to_string = function
  | Gate_override -> "override"
  | Gate_continue -> "continue"
  | Gate_approval_required -> "approval_required"
  | Gate_non_author_verified -> "non_author_verified"

let gate_decision_is_rejection = function
  | Gate_override -> true
  | Gate_continue | Gate_approval_required | Gate_non_author_verified -> false

type gate_rejection_log_severity =
  | Gate_rejection_first_warn
  | Gate_rejection_repeat_info of int
  | Gate_rejection_repeat_debug of int

let gate_rejection_log_severity_to_string = function
  | Gate_rejection_first_warn -> "warn"
  | Gate_rejection_repeat_info _ -> "info"
  | Gate_rejection_repeat_debug _ -> "debug"

let gate_rejection_log_counts : (string * string * string * string, int) Hashtbl.t =
  Hashtbl.create 64

let gate_rejection_log_counts_mu = Mutex.create ()

let reset_gate_rejection_log_counts () =
  Mutex.protect gate_rejection_log_counts_mu (fun () ->
    Hashtbl.clear gate_rejection_log_counts)

let record_gate_rejection_log_severity ?reason_key
    ~keeper_name ~stage ~tool_name ~reason_code () =
  let reason_key = Option.value ~default:reason_code reason_key in
  let key = (keeper_name, stage, tool_name, reason_key) in
  Mutex.protect gate_rejection_log_counts_mu (fun () ->
    let count =
      match Hashtbl.find_opt gate_rejection_log_counts key with
      | Some n -> n + 1
      | None -> 1
    in
    Hashtbl.replace gate_rejection_log_counts key count;
    match count with
    | 1 -> Gate_rejection_first_warn
    | 2 -> Gate_rejection_repeat_info count
    | _ -> Gate_rejection_repeat_debug count)

let planner_alternative_for_gate ~stage ~tool_name =
  match stage with
  | "readonly_observation_duplicate" ->
    Printf.sprintf
      "planner_alternative=\"stop retrying %s with identical input; use the prior observation, choose a different tool/input, mutate state, or report no-work/blocker directly\""
      tool_name
  | "streak_gate" ->
    Printf.sprintf
      "planner_alternative=\"stop retrying %s; choose a different tool, batch remaining work, or report no-work/blocker directly\""
      tool_name
  | "keeper_deny" ->
    "planner_alternative=\"choose an allowed replacement tool, change plan, or request operator approval\""
  | "cost_gate" ->
    "planner_alternative=\"cost telemetry is advisory; inspect the real gate before changing plan\""
  | "destructive_guard" ->
    "planner_alternative=\"use a safe read-only command, narrow the path, or request operator approval\""
  | _ ->
    "planner_alternative=\"change plan, choose a different tool, or report no-work/blocker directly\""

let log_gate_rejection ?reason_key ~keeper_name ~stage ~tool_name ~reason_code fmt =
  Printf.ksprintf
    (fun message ->
       match
         record_gate_rejection_log_severity ?reason_key
           ~keeper_name ~stage ~tool_name ~reason_code ()
       with
       | Gate_rejection_first_warn -> Log.Keeper.warn "%s" message
       | Gate_rejection_repeat_info count ->
         Log.Keeper.info "%s repeat_count=%d %s"
           message count (planner_alternative_for_gate ~stage ~tool_name)
       | Gate_rejection_repeat_debug count ->
         Log.Keeper.debug "%s repeat_count=%d %s"
           message count (planner_alternative_for_gate ~stage ~tool_name))
    fmt

module For_testing = struct
  let reset_gate_rejection_log_counts = reset_gate_rejection_log_counts

  let record_gate_rejection_log_severity =
    record_gate_rejection_log_severity

  let planner_alternative_for_gate = planner_alternative_for_gate
end

type gate_decision_event = {
  stage : string;
  keeper_name : string;
  decision : gate_decision;
  reason_code : string;
  reason_text : string;
  tool_name : string;
  input : Yojson.Safe.t;
  turn : int;
  accumulated_cost_usd : float;
  stage_latency_ms : float;
  source_path : string option;
  source_line : int option;
}

let ignore_gate_decision (_ : gate_decision_event) = ()

let notify_gate_decision on_gate_decision (event : gate_decision_event) =
  (* RFC-0106 P0 canary: use Cancel_safe.observe so Cancelled
     propagates without per-site discipline drift. *)
  Cancel_safe.observe
    ~on_exn:(fun exn ->
      (* Keep existing GuardsFailures metric for backward compatibility
         (test_keeper_guards.ml asserts this counter). *)
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string GuardsFailures)
        ~labels:[("keeper", event.keeper_name); ("site", "gate_observer")]
        ();
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string LifecycleCallbackFailures)
        ~labels:[("keeper", event.keeper_name); ("callback", "on_gate_decision")]
        ();
      Log.Keeper.warn
        "keeper_guards: gate observer failed keeper=%s stage=%s tool=%s err=%s"
        event.keeper_name event.stage event.tool_name (Printexc.to_string exn))
    (fun () -> on_gate_decision event)

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
(* Spec mapping: GateRejected action — KeeperTurnCycle.tla lines 189-200.
   Gate_override routes to Keeper_registry.mark_turn_gate_rejected_by_name,
   which fires the decision_stage = "gate_rejected" / turn_phase =
   "finalizing" transition. Gate_approval_required is not terminal: OAS
   suspends in the approval callback and may still execute the tool after
   approval.

   Cycle 49 observability addition: when the gate rejects, the turn
   becomes terminal WITHOUT any runtime tier ever being attempted.  A
   dashboard reading only the final outcome ("Turn_gate_rejected") cannot
   distinguish "all gates rejected, runtime=none" from "all runtimes
   exhausted" — both surface as terminal failure.  We add a Otel_metric_store
   counter, an INFO log line, and a [runtime_attempted] payload field so
   the narrative is observable. *)

(** Otel_metric_store metric: turns terminated by a pre_tool_use gate rejection
    (Override or ApprovalRequired) without ever attempting a runtime
    tier.  See [emit_gate_event] for the firing site.

    Labels stay bounded:
    - [keeper]   ∈ keeper agent names (finite per fleet)
    - [tool]     ∈ tool names (finite, registry-controlled)
    - [reason]   ∈ guard reason_code strings (finite, defined by guards)
    - [decision] ∈ {override} *)
let gate_rejected_terminal_metric =
  Keeper_metrics.(to_string TurnGateRejectedTerminal)

let () =
  Otel_metric_store.register_counter
    ~name:gate_rejected_terminal_metric
    ~help:
      "Total turns terminated by a pre_tool_use gate rejection \
       (Override or ApprovalRequired) without ever attempting a \
       runtime tier.  A non-zero rate on a keeper indicates \
       pre_tool_use guards short-circuit before the runtime ever \
       runs — useful for distinguishing 'all gates rejected, \
       runtime=none' from 'all runtimes exhausted' in the keeper \
       terminal taxonomy.  Emitted with labels: keeper, tool, reason, \
       decision."
    ()

let emit_gate_event
    ~source_path ~source_line
    ~stage ~decision ~reason_code
    ~tool_name ~agent_name ~turn
    ~accumulated_cost_usd ~stage_latency_ms ~reason_text =
  let decision_label = gate_decision_to_string decision in
  let is_gate_rejection = gate_decision_is_rejection decision in
  if is_gate_rejection then begin
    Keeper_registry.mark_turn_gate_rejected_by_name agent_name;
    Otel_metric_store.inc_counter gate_rejected_terminal_metric
      ~labels:[
        ("keeper", agent_name);
        ("tool", tool_name);
        ("reason", reason_code);
        ("decision", decision_label);
      ] ();
    Log.Keeper.info ~keeper_name:agent_name
      "tool:%s decision=%s reason_code=%s runtime=none \
       (gate rejected before runtime attempt)"
      tool_name decision_label reason_code
  end
  else if decision = Gate_approval_required then
    Log.Keeper.info ~keeper_name:agent_name
      "tool:%s decision=%s reason_code=%s runtime=none \
       (approval pending before runtime attempt)"
      tool_name decision_label reason_code;
  match Masc_event_bus.get () with
  | None -> ()
  | Some bus ->
    let payload = `Assoc [
      ("stage", `String stage);
      ("decision", `String decision_label);
      ("reason_code", `String reason_code);
      ("tool_name", `String tool_name);
      ("agent_name", `String agent_name);
      ("turn", `Int turn);
      ("accumulated_cost_usd", `Float accumulated_cost_usd);
      ("stage_latency_ms", `Float stage_latency_ms);
      ("reason_text", `String reason_text);
      ("source", `String "hook");
      ( "runtime_attempted"
      , `Bool
          (match decision with
           | Gate_continue | Gate_non_author_verified -> true
           | Gate_override | Gate_approval_required -> false) );
      ("source_path", Json_util.string_opt_to_json source_path);
      ("source_line", Json_util.int_opt_to_json source_line);
    ] in
    (try
      Agent_sdk_metrics_bridge.publish bus
        (Agent_sdk.Event_bus.mk_event
           (Agent_sdk.Event_bus.Custom ("masc.keeper_gate", payload)))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string GuardsFailures)
        ~labels:[("keeper", agent_name); ("site", "event_emit")]
        ();
      Log.Keeper.warn
        "keeper_guards: event emit failed stage=%s tool=%s err=%s"
        stage tool_name (Printexc.to_string exn))

let report_gate_decision on_gate_decision
    ~source_path ~source_line
    ~stage ~decision ~reason_code ~reason_text
    ~tool_name ~keeper_name ~input ~turn
    ~accumulated_cost_usd ~stage_latency_ms =
  emit_gate_event ~source_path ~source_line ~stage ~decision ~reason_code ~tool_name
    ~agent_name:keeper_name ~turn ~accumulated_cost_usd
    ~stage_latency_ms ~reason_text;
  notify_gate_decision on_gate_decision
    { stage; keeper_name; decision; reason_code; reason_text; tool_name; input; turn;
      accumulated_cost_usd; stage_latency_ms; source_path; source_line }

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

(** Guarded read-only observation state inside one Agent.run turn.
    [previous_success] is confirmed only from a successful PostToolUse event;
    [pending] catches same-batch duplicate reads before the first result lands.
    The input is stored as canonical JSON, not a lossy digest, so equality is
    exact after object-key normalization.

    State is per keeper hook closure, not process-global. The mutex protects
    only pure state transitions and is not held across logging, event emission,
    or any other effectful hook work. *)
module Readonly_observation_key = struct
  type t = string * string

  let compare = Stdlib.compare
end

module Readonly_observation_key_set =
  Stdlib.Set.Make (Readonly_observation_key)

type readonly_observation_key = Readonly_observation_key.t

type readonly_observation_state = {
  mutex : Stdlib.Mutex.t;
  mutable previous_success : readonly_observation_key option;
  mutable pending : Readonly_observation_key_set.t;
  mutable pending_batch : (int * int) option;
}

let make_readonly_observation_state () : readonly_observation_state =
  {
    mutex = Stdlib.Mutex.create ();
    previous_success = None;
    pending = Readonly_observation_key_set.empty;
    pending_batch = None;
  }

let with_readonly_observation_state state f =
  Stdlib.Mutex.lock state.mutex;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock state.mutex)
    f

let reset_readonly_observation_state state =
  with_readonly_observation_state state (fun () ->
    state.previous_success <- None;
    state.pending <- Readonly_observation_key_set.empty;
    state.pending_batch <- None)

let rec canonical_json = function
  | `Assoc fields ->
    fields
    |> List.map (fun (key, value) -> key, canonical_json value)
    |> List.stable_sort (fun (left, _) (right, _) -> String.compare left right)
    |> fun fields -> `Assoc fields
  | `List values -> `List (List.map canonical_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as json -> json

let canonical_input_string input =
  canonical_json input |> Yojson.Safe.to_string

let read_only_snapshot_observation ~tool_name ~input =
  match
    ( Keeper_tool_descriptor_resolution.readonly_for_tool_call ~tool_name ~input
    , Keeper_tool_descriptor_resolution.effect_domain_for_tool_name tool_name )
  with
  | Some true, Some Tool_catalog.Read_only ->
    not (Keeper_tool_capability_axis.supports Keeper_tool_capability_axis.Polling_read tool_name)
  | Some false, _
  | None, _
  | _, Some (Tool_catalog.Masc_workspace
            | Tool_catalog.Playground_write
            | Tool_catalog.Host_repo_write)
  | _, None -> false

let mutating_effectful_tool ~tool_name =
  match Keeper_tool_descriptor_resolution.effect_domain_for_tool_name tool_name with
  | Some (Tool_catalog.Masc_workspace
         | Tool_catalog.Playground_write
         | Tool_catalog.Host_repo_write) -> true
  | Some Tool_catalog.Read_only
  | None -> false

let readonly_observation_key ~tool_name ~input =
  let canonical_tool_name = Keeper_tool_capability_axis.canonical_tool_name tool_name in
  canonical_tool_name, canonical_input_string input

let readonly_observation_remove_pending state key =
  state.pending <- Readonly_observation_key_set.remove key state.pending

type readonly_observation_pre_decision =
  | Readonly_observation_continue
  | Readonly_observation_duplicate

let readonly_observation_record_success state key =
  with_readonly_observation_state state (fun () ->
    readonly_observation_remove_pending state key;
    state.previous_success <- Some key)

let readonly_observation_record_failure state key =
  with_readonly_observation_state state (fun () ->
    readonly_observation_remove_pending state key)

let readonly_observation_record_pre_tool_use
      state
      ~(turn : int)
      ~(schedule : Agent_sdk.Hooks.tool_schedule)
      key
  =
  with_readonly_observation_state state (fun () ->
    let batch = Some (turn, schedule.batch_index) in
    if state.pending_batch <> batch then (
      state.pending <- Readonly_observation_key_set.empty;
      state.pending_batch <- batch);
    let duplicate_pending =
      Readonly_observation_key_set.mem key state.pending
    in
    let duplicate_success =
      match state.previous_success with
      | Some previous -> previous = key
      | None -> false
    in
    if duplicate_pending || duplicate_success
    then Readonly_observation_duplicate
    else (
      state.pending <- Readonly_observation_key_set.add key state.pending;
      Readonly_observation_continue))

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
    ~(meta_ref : Keeper_meta_contract.keeper_meta ref)
    ~on_gate_decision
    ~(guard : tool_name:string -> input:Yojson.Safe.t -> string option)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; _ } ->
      let t0 = Time_compat.now () in
      let keeper_name = (!meta_ref).name in
      (match guard ~tool_name ~input with
       | Some reason ->
         let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
         Log.Keeper.info ~keeper_name:keeper_name
           "pre_tool_use guard blocked %s"
           tool_name;
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
    ~(meta_ref : Keeper_meta_contract.keeper_meta ref)
    ~on_gate_decision
    ~(state : streak_state)
    ~(threshold : int)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; _ } ->
      let t0 = Time_compat.now () in
      let keeper_name = (!meta_ref).name in
      let prev_name, prev_count = state.entry in
      let new_count =
        if prev_name = tool_name then prev_count + 1 else 1
      in
      state.entry <- (tool_name, new_count);
      if new_count >= threshold then begin
        let reason_text =
          Printf.sprintf
            "%s called %d times consecutively. Use a DIFFERENT tool or finish with a direct no-work/blocker response"
            tool_name new_count
        in
        let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string GuardsFailures)
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

(** Consecutive duplicate read-only snapshot gate.

    Same tool + same canonical input + descriptor-proven read-only/snapshot
    semantics cannot produce new in-turn workspace progress unless an
    intervening mutation or different observation occurred. Polling tools are
    classified separately by [Keeper_tool_capability_axis.Polling_read] and are
    intentionally exempt.

    The blocking decision runs in [pre_tool_use], but completed observations are
    confirmed only by a successful [post_tool_use]. This preserves legitimate
    retry after a failed read-only call while still blocking same-batch duplicate
    pending calls. *)
let readonly_observation_duplicate_guard
    ~(meta_ref : Keeper_meta_contract.keeper_meta ref)
    ~on_gate_decision
    ~(state : readonly_observation_state)
  : Agent_sdk.Hooks.hooks =
  let pre_tool_use event =
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; schedule; _ } ->
      let t0 = Time_compat.now () in
      let keeper_name = (!meta_ref).name in
      if not (read_only_snapshot_observation ~tool_name ~input) then
        Agent_sdk.Hooks.Continue
      else begin
        let key = readonly_observation_key ~tool_name ~input in
        match readonly_observation_record_pre_tool_use state ~turn ~schedule key with
        | Readonly_observation_duplicate ->
          let reason_text =
            Printf.sprintf
              "%s repeated the same read-only observation with identical input. Use the prior observation, choose a different tool/input, mutate state, or finish with a direct no-work/blocker response"
              tool_name
          in
          let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string GuardsFailures)
            ~labels:
              [ ("keeper", keeper_name); ("site", "readonly_observation_duplicate") ]
            ();
          log_gate_rejection
            ~keeper_name ~stage:"readonly_observation_duplicate" ~tool_name
            ~reason_code:"readonly_observation_duplicate"
            "keeper:%s readonly_observation_duplicate: %s repeated identical read-only input, blocking"
            keeper_name tool_name;
          broadcast_tool_skipped
            ~keeper_name ~tool_name ~reason_code:"readonly_observation_duplicate";
          let source_path = keeper_guards_source_path in
          let source_line = __LINE__ in
          report_gate_decision on_gate_decision
            ~source_path:(Some source_path) ~source_line:(Some source_line)
            ~stage:"readonly_observation_duplicate" ~decision:Gate_override
            ~reason_code:"readonly_observation_duplicate" ~reason_text
            ~tool_name ~keeper_name ~input ~turn ~accumulated_cost_usd
            ~stage_latency_ms:latency_ms;
          Agent_sdk.Hooks.Override
            (render_inline_skip_reason_with_source
               ~source_path ~source_line
               ~tool_name ~reason_code:"readonly_observation_duplicate"
               ~reason_text)
        | Readonly_observation_continue -> Agent_sdk.Hooks.Continue
      end
    | _ -> Agent_sdk.Hooks.Continue
  in
  let post_tool_use event =
    match event with
    | Agent_sdk.Hooks.PostToolUse { tool_name; input; output; _ } ->
      (if read_only_snapshot_observation ~tool_name ~input then
        let key = readonly_observation_key ~tool_name ~input in
        (match output with
         | Ok _ -> readonly_observation_record_success state key
         | Error _ -> readonly_observation_record_failure state key)
       else
        match output with
        | Ok _ when mutating_effectful_tool ~tool_name ->
          reset_readonly_observation_state state
        | Ok _
        | Error _ -> ());
      Agent_sdk.Hooks.Continue
    | _ -> Agent_sdk.Hooks.Continue
  in
  let post_tool_use_failure event =
    match event with
    | Agent_sdk.Hooks.PostToolUseFailure { tool_name; input; _ } ->
      (if read_only_snapshot_observation ~tool_name ~input then
        let key = readonly_observation_key ~tool_name ~input in
        readonly_observation_record_failure state key);
      Agent_sdk.Hooks.Continue
    | _ -> Agent_sdk.Hooks.Continue
  in
  { Agent_sdk.Hooks.empty with
    pre_tool_use = Some pre_tool_use;
    post_tool_use = Some post_tool_use;
    post_tool_use_failure = Some post_tool_use_failure;
  }

(** Keeper deny list. Block administrative / destructive tools that
    should only be invoked by operators or controlled workflows. *)
let deny_guard
    ~(meta_ref : Keeper_meta_contract.keeper_meta ref)
    ~on_gate_decision
    ~(denied : string list)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; _ } ->
      let t0 = Time_compat.now () in
      let keeper_name = (!meta_ref).name in
      if List.mem tool_name denied then begin
        let reason_text = "tool is on the keeper deny list" in
        let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string GuardsFailures)
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

(** Cost telemetry passthrough.

    [max_cost_usd] is advisory only and must never reject tool execution. *)
let cost_guard
    ~(meta_ref : Keeper_meta_contract.keeper_meta ref)
    ~on_gate_decision
    ~(max_cost_usd : float option)
  : Agent_sdk.Hooks.hooks =
  ignore meta_ref;
  ignore on_gate_decision;
  ignore max_cost_usd;
  hooks_of_pre_tool_use (fun _event -> Agent_sdk.Hooks.Continue)

(** Destructive pattern detection for bash/edit style tools.
    Only applies when the supplied policy is enabled and descriptor/catalog
    capability lookup flags the observed tool name as destructive. *)
let destructive_guard
    ~(meta_ref : Keeper_meta_contract.keeper_meta ref)
    ~on_gate_decision
    ~(policy : Destructive_ops_policy.t)
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; _ } ->
      if not (Destructive_ops_policy.enabled policy) then Agent_sdk.Hooks.Continue
      else if
        not
          (Keeper_tool_descriptor_resolution.capability_has
             Tool_capability.Destructive
             tool_name)
      then
        Agent_sdk.Hooks.Continue
      else
        let t0 = Time_compat.now () in
        let keeper_name = (!meta_ref).name in
        let cmd = extract_command_from_input input in
        (match Eval_gate.detect_destructive policy cmd with
         | None -> Agent_sdk.Hooks.Continue
         | Some (pattern, desc) ->
           let reason_text =
             Printf.sprintf "pattern='%s' (%s)" pattern desc
           in
           let latency_ms = (Time_compat.now () -. t0) *. 1000.0 in
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string GuardsFailures)
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
    ~(meta_ref : Keeper_meta_contract.keeper_meta ref)
    ~on_gate_decision
  : Agent_sdk.Hooks.hooks =
  hooks_of_pre_tool_use (fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse
        { tool_name; input; accumulated_cost_usd; turn; _ } ->
      let t0 = Time_compat.now () in
      let keeper_name = (!meta_ref).name in
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
      timing -> custom -> read-only observation duplicate -> streak -> deny
      -> cost telemetry passthrough -> destructive -> governance_approval *)
let build_chain
    ~(meta_ref : Keeper_meta_contract.keeper_meta ref)
    ~(tool_start_time : float ref)
    ~(streak_state : streak_state)
    ~(readonly_observation_state : readonly_observation_state)
    ~(streak_threshold : int)
    ~(denied : string list)
    ~(max_cost_usd : float option)
    ~(destructive_ops_policy : Destructive_ops_policy.t)
    ~on_gate_decision
    ~(pre_tool_use_guard :
        tool_name:string -> input:Yojson.Safe.t -> string option)
  : Agent_sdk.Hooks.hooks =
  compose_all [
    timing_guard ~tool_start_time;
    custom_guard ~meta_ref ~on_gate_decision ~guard:pre_tool_use_guard;
    readonly_observation_duplicate_guard
      ~meta_ref ~on_gate_decision ~state:readonly_observation_state;
    streak_guard ~meta_ref ~on_gate_decision ~state:streak_state ~threshold:streak_threshold;
    deny_guard ~meta_ref ~on_gate_decision ~denied;
    cost_guard ~meta_ref ~on_gate_decision ~max_cost_usd;
    destructive_guard ~meta_ref ~on_gate_decision ~policy:destructive_ops_policy;
    governance_approval_guard ~meta_ref ~on_gate_decision;
  ]
