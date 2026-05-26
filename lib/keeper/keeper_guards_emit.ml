(** Keeper_guards_emit — gate decision types, emission infrastructure,
    and shared guard utilities extracted from [Keeper_guards] (769 LoC).
    Guard function implementations remain in the parent.
    @since Keeper 500-line decomposition *)

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
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_guards_failures
        ~labels:[("keeper", keeper_name); ("site", "sse_broadcast")]
        ();
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

type gate_decision =
  | Gate_override
  | Gate_continue
  | Gate_approval_required

let gate_decision_to_string = function
  | Gate_override -> "override"
  | Gate_continue -> "continue"
  | Gate_approval_required -> "approval_required"

let gate_decision_is_rejection = function
  | Gate_override | Gate_approval_required -> true
  | Gate_continue -> false

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
  | "streak_gate" ->
    Printf.sprintf
      "planner_alternative=\"stop retrying %s; choose a different tool, batch remaining work, or call keeper_stay_silent\""
      tool_name
  | "keeper_deny" ->
    "planner_alternative=\"choose an allowed replacement tool, change plan, or request operator approval\""
  | "cost_gate" ->
    "planner_alternative=\"stop tool use, summarize progress, or request a budget increase before retrying\""
  | "destructive_guard" ->
    "planner_alternative=\"use a safe read-only command, narrow the path, or request operator approval\""
  | _ ->
    "planner_alternative=\"change plan, choose a different tool, or call keeper_stay_silent\""

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
  try on_gate_decision event
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_guards_failures
        ~labels:[("keeper", event.keeper_name); ("site", "gate_observer")]
        ();
      Log.Keeper.warn
        "keeper_guards: gate observer failed keeper=%s stage=%s tool=%s err=%s"
        event.keeper_name event.stage event.tool_name (Printexc.to_string exn)

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
   The two-arm match below routes Gate_override | Gate_approval_required to
   Keeper_registry.mark_turn_gate_rejected_by_name, which fires the
   decision_stage = "gate_rejected" / turn_phase = "finalizing" transition.
   The Gate_continue branch skips the spec action entirely and only emits
   the Event_bus Custom event below.

   Cycle 49 observability addition: when the gate rejects, the turn
   becomes terminal WITHOUT any cascade tier ever being attempted.  A
   dashboard reading only the final outcome ("Turn_gate_rejected") cannot
   distinguish "all gates rejected, cascade=none" from "all cascades
   exhausted" — both surface as terminal failure.  We add a Prometheus
   counter, an INFO log line, and a [cascade_attempted] payload field so
   the narrative is observable. *)

(** Prometheus metric: turns terminated by a pre_tool_use gate rejection
    (Override or ApprovalRequired) without ever attempting a cascade
    tier.  See [emit_gate_event] for the firing site.

    Labels stay bounded:
    - [keeper]   ∈ keeper agent names (finite per fleet)
    - [tool]     ∈ tool names (finite, registry-controlled)
    - [reason]   ∈ guard reason_code strings (finite, defined by guards)
    - [decision] ∈ {override, approval_required} *)
let gate_rejected_terminal_metric =
  Keeper_metrics.metric_keeper_turn_gate_rejected_terminal

let () =
  Prometheus.register_counter
    ~name:gate_rejected_terminal_metric
    ~help:
      "Total turns terminated by a pre_tool_use gate rejection \
       (Override or ApprovalRequired) without ever attempting a \
       cascade tier.  A non-zero rate on a keeper indicates \
       pre_tool_use guards short-circuit before the cascade ever \
       runs — useful for distinguishing 'all gates rejected, \
       cascade=none' from 'all cascades exhausted' in the keeper \
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
    Prometheus.inc_counter gate_rejected_terminal_metric
      ~labels:[
        ("keeper", agent_name);
        ("tool", tool_name);
        ("reason", reason_code);
        ("decision", decision_label);
      ] ();
    Log.Keeper.info
      "keeper:%s tool:%s decision=%s reason_code=%s cascade=none \
       (gate rejected before cascade attempt)"
      agent_name tool_name decision_label reason_code
  end;
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
      ("cascade_attempted", `Bool (not is_gate_rejection));
      ("source_path",
       (match source_path with Some path -> `String path | None -> `Null));
      ("source_line",
       (match source_line with Some line -> `Int line | None -> `Null));
    ] in
    (try
      Agent_sdk_metrics_bridge.publish bus
        (Agent_sdk.Event_bus.mk_event
           (Agent_sdk.Event_bus.Custom ("masc.keeper_gate", payload)))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_guards_failures
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

