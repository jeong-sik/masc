
(** Tool_autoresearch — public surface for the autoresearch
    MCP tool family.

    The .ml is a 613-line module that splits into three
    layers:

    - {b Loop registry / hypothesis queue / generator state},
      re-exported from {!Tool_autoresearch_registry} via
      [include] so the dashboard handler and the test suite
      can reach the underlying [Hashtbl]s by their canonical
      [Tool_autoresearch.X] name without duplicating
      modules.
    - {b SSE broadcasters}, re-exported from
      {!Tool_autoresearch_broadcast} via [include] for the
      same reason — {!Tool_autoresearch_cycle} is the other
      consumer and reaches them via [open
      Tool_autoresearch_broadcast].
    - {b Tool dispatcher} (this module's only locally-defined
      public surface): {!handle_start} kicks off a research
      run, {!dispatch} routes every [masc_autoresearch_*]
      tool name to its handler.

    Many internal helpers stay private at this boundary
    ([persisted_summary_json], [resolve_loop_id],
    [prepare_start_params], [register_loop],
    [prepare_managed_target_file], [setup_running_loop],
    [status_json], [build_swarm_goal], [parse_operation_id],
    [check_concurrency_limit], the [handle_status] /
    [handle_stop] / [handle_inject] /
    [handle_record_finding] / [handle_search_findings]
    handlers (reached only through {!dispatch}),
    [wrap_result], the arg-parser family, and the internal
    [start_params] record). *)

include module type of struct
  include Tool_autoresearch_registry
end

include module type of struct
  include Tool_autoresearch_broadcast
end

(** {1 Tool dispatcher context} *)

type context = Tool_autoresearch_context.t
(** Alias of {!Tool_autoresearch_context.t}.  Pinned at this
    boundary so external callers reach the per-handler
    dependency bundle as [Tool_autoresearch.context] without
    importing the source module.  Type identity is preserved
    — the two names are interchangeable. *)

(** {1 Tool schemas} *)

val schemas : Types.tool_schema list
(** Re-export of {!Tool_autoresearch_schemas.schemas}.  The
    list of tool schemas advertised to the MCP transport for
    the [masc_autoresearch_*] family. *)

(** {1 Public handlers} *)

val handle_start : context -> Yojson.Safe.t -> Yojson.Safe.t
(** Handler for [masc_autoresearch_start].  Kicks off a new
    autoresearch loop after running concurrency-limit
    checks ({!check_concurrency_limit}) and parsing the
    arg payload via [prepare_start_params].  Returns a JSON
    [`Assoc] either describing the started loop or an
    [error] field on validation / setup failure. *)

(** {1 Tool dispatcher} *)

type tool_result = bool * string
(** [(success, json_message)] returned by every tool
    handler routed through {!dispatch}.  [success = false]
    means the JSON contains an [error] field; the
    transport surfaces it as an MCP error response. *)

val persisted_summary_target_reached :
  Autoresearch.persisted_summary -> bool
(** Target-score projection used when rendering persisted status.
    Non-finite scores fail closed so malformed metric output cannot report
    [target_reached = true] while the core loop remains incomplete. *)

val dispatch :
  context -> name:string -> args:Yojson.Safe.t -> tool_result option
(** Routes every [masc_autoresearch_*] tool name to its
    internal handler:
    - [masc_autoresearch_start] → {!handle_start}
    - [masc_autoresearch_status]
    - [masc_autoresearch_stop]
    - [masc_autoresearch_inject]
    - [masc_autoresearch_cycle] → delegates to
      {!Tool_autoresearch_cycle.handle_cycle}
    - [masc_autoresearch_record_finding]
    - [masc_autoresearch_search_findings]

    Returns [None] when [name] does not match any of the
    above so the parent dispatcher can fall through to the
    next family. *)
