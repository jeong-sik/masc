
(** Dashboard_tool_host_events — typed surface for the
    `client_tool_host_failure` HTTP report and the matching
    `tool_assigned` lifecycle event.

    The dashboard exposes a small POST endpoint where MCP clients
    (codex / claude / kimi / gemini) self-report tool-host failures
    they observed locally — connection drops, timeouts, schema-mismatch
    rejections.  This module parses those JSON payloads, fans them out
    to {!Log}, {!Audit_log}, and {!Telemetry_eio}, and records the
    matching tool-assignment events for the dashboard's tool-quality
    surface card. *)

(** {1 Tool-host failure report}

    Concrete record because two consumers construct it field-by-field
    (test fixtures + the future "synthetic report" injection paths).
    The record is the operator's grep contract — every field name
    appears verbatim in audit-log JSON / dashboard cards / telemetry
    rows, so a future "let's rename agent_name to actor_name" change
    must touch this contract explicitly. *)
type report = {
  agent_name : string;
  client_name : string;
  tool_name : string;
  transport : string;
  phase : string option;
  cause : Failure_envelope.tool_host_cause;
  message : string;
  request_id : string option;
  session_id : string option;
  trace_id : string option;
  timeout_ms : int option;
}

val report_of_yojson :
  ?fallback_agent:string -> Yojson.Safe.t -> (report, string) Result.t
(** [report_of_yojson ?fallback_agent json] parses a tool-host failure
    JSON payload. Required fields: [tool_name], [message], and the current-only
    [cause_code]. The first two use stringish coercion; [cause_code] must name
    one of {!Failure_envelope.tool_host_cause} exactly.

    Optional fields default with operator-visible literals:
    - [client_name]: [fallback_agent] (trimmed) or "tool-host"
    - [agent_name]: explicit [agent_name] field, then [fallback_agent],
      then [client_name].  The three-level fallback is deliberate so a
      single-keeper deployment never reports an empty agent_name in
      audit logs.
    - [transport]: "mcp_http"

    Returns [Error] for non-object payloads, missing required fields, and
    unknown cause codes. The cause is resolved at this HTTP boundary; internal
    consumers never classify [message] prose. *)

val details_json : report -> Yojson.Safe.t
(** [details_json report] returns the JSON object suitable for
    {!Log.client_tool_host_error} `~details`.  The payload combines
    {!Failure_envelope.tool_host_failure} with a flat [`Assoc] of the
    optional fields (only present when set, never as `Null), so the
    dashboard JSON consumers can rely on "field present ⟺ field set". *)

val record :
  ?fs:'fs ->
  Workspace_utils.config ->
  report ->
  unit
(** [record ?fs config report] is the fan-out side-effect:
    1. [Log.client_tool_host_error] (file ring + stderr)
    2. [Audit_log.log_client_tool_host_failure] (durable JSONL)
    3. {!Telemetry_eio.track_error} when [fs] is provided

    The [fs] parameter is the Eio filesystem capability;
    {!Telemetry_eio.track_error} is skipped when [fs = None] because
    the telemetry pipeline writes to disk.  Operators who want
    telemetry must thread the capability through — silently skipping
    is the only correct behaviour at boot before the runtime is up. *)

(** {1 Tool-assignment lifecycle event}

    Snapshot the dashboard records when a profile is assigned
    to an agent.  Concrete record for the same reason as {!report}. *)
type assignment_snapshot = {
  agent_name : string;
  profile : string;
  tool_count : int;
  assignment_id : string;
}

