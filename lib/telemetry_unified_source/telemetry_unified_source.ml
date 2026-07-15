(** Telemetry unified source variant + total string bijection.

    SSOT for the 9-variant [Telemetry_unified.source] enum that names
    each durable telemetry stream (keeper_metric, agent_event,
    tool_call_io, trajectory_tool_call, tool_usage, oas_event,
    execution_receipt, tool_metric).

    Pure variant + total bijection (modulo unknown-string → None on
    parse). Verbatim extract from the head of [Telemetry_unified];
    the parent retains a transparent variant alias so existing
    exhaustive matches at ~20 qualified call sites continue to
    type-check unchanged. *)

type source =
  | Keeper_metric  (** Per-keeper turn/heartbeat metrics *)
  | Agent_event    (** Agent lifecycle, task, handoff events *)
  | Tool_call_io   (** Keeper tool calls with full input/output *)
  | Trajectory_tool_call  (** Keeper trajectory-backed tool call rows *)
  | Tool_usage     (** Non-public registered tool invocations *)
  | Oas_event      (** Durable OAS native/custom event bus relays *)
  | Execution_receipt  (** Keeper execution receipt rows *)
  | Tool_metric    (** Tool duration and success metrics *)

let source_to_string = function
  | Keeper_metric -> "keeper_metric"
  | Agent_event -> "agent_event"
  | Tool_call_io -> "tool_call_io"
  | Trajectory_tool_call -> "trajectory_tool_call"
  | Tool_usage -> "tool_usage"
  | Oas_event -> "oas_event"
  | Execution_receipt -> "execution_receipt"
  | Tool_metric -> "tool_metric"

let source_of_string = function
  | "keeper_metric" -> Some Keeper_metric
  | "agent_event" -> Some Agent_event
  | "tool_call_io" -> Some Tool_call_io
  | "trajectory_tool_call" -> Some Trajectory_tool_call
  | "tool_usage" -> Some Tool_usage
  | "oas_event" -> Some Oas_event
  | "execution_receipt" -> Some Execution_receipt
  | "tool_metric" -> Some Tool_metric
  | _ -> None

let all_sources =
  [ Keeper_metric
  ; Agent_event
  ; Tool_call_io
  ; Trajectory_tool_call
  ; Tool_usage
  ; Oas_event
  ; Execution_receipt
  ; Tool_metric
  ]
