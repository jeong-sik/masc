
(** Tool_agent_timeline — Per-agent activity timeline + summary.

    Implements the [masc_agent_timeline] MCP tool plus the
    [/api/dashboard/agent/<name>/timeline] HTTP route.  Aggregates
    6 event sources for a single agent ([agent_events],
    [task_events], [message_events], [tool_call_events],
    [keeper_cdal_events], [turn_completed_events]), filters by
    [since_hours] cutoff, sorts chronologically, truncates to
    [limit] (most recent), and emits a JSON summary with
    cardinality counts + token/cost rollups.

    Internal: 11 helpers + 1 type stay private —
    \[parse_iso_timestamp] (Scanf-based ISO8601 parser),
    [timeline_event] type + [event_to_json], the 6 source
    extractors ([agent_events], [task_events], [message_events],
    [tool_call_events], [keeper_cdal_events],
    [turn_completed_events]), and [handle_agent_timeline] (the
    dispatch handler that reaches {!build_timeline}).  All
    consumed only inside {!build_timeline} or {!dispatch}. *)

(** {1 Tool result + context} *)

type tool_result = bool * string
(** [(success, message)] dispatch return shape. *)

type context = {
  config : Coord.config;
  agent_name : string;
}
(** Per-call context.  Concrete record because callers
    construct it field-by-field at the dispatch site
    ([{ Tool_agent_timeline.config; agent_name }]). *)

(** {1 Timeline construction} *)

val build_timeline :
  Coord.config ->
  agent_name:string ->
  since_hours:float ->
  limit:int ->
  include_tasks:bool ->
  include_board:bool ->
  include_tool_calls:bool ->
  Yojson.Safe.t
(** [build_timeline config ~agent_name ~since_hours ~limit
      ~include_tasks ~include_board ~include_tool_calls] returns a
    JSON object with two keys:

    - [events] — the truncated, chronologically-sorted event
      list (most recent [limit] events).
    - [summary] — cardinality counts ([tasks_completed],
      [tasks_claimed], [messages_sent], [tool_calls],
      [turns_completed], [total_events]) plus token/cost
      rollups ([total_input_tokens], [total_output_tokens],
      [total_cost_usd]) and [active_duration_minutes].

    The 6 event sources are gathered unconditionally except:

    - [include_tasks = false] -> [task_events] is skipped.
    - [include_tool_calls = false] -> [tool_call_events] is
      skipped.
    - [include_board] is currently unused (reserved for future
      board-event integration).

    Per-source internal limits are pinned at 200 events
    ([message_events], [tool_call_events], [keeper_cdal_events],
    [turn_completed_events]); the [~limit] argument applies to
    the merged sorted list. *)

(** {1 Dispatch + schemas} *)

val dispatch :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.t option
(** [dispatch ctx ~name ~args] routes by tool name.  Returns
    [None] when [name] is not [masc_agent_timeline] — caller
    treats that as "not my tool". *)

val schemas : Masc_domain.tool_schema list
(** [schemas] is the [Masc_domain.tool_schema list] registered with the
    MCP catalog (consumed by {!Config.visible_tool_schemas}).
    Used by the side-effect block at module load via
    {!Tool_spec.register}. *)
