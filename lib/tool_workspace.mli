(** Tool_workspace — Workspace management MCP tools (status / init / check /
    assertion).

    Note: [join] / [leave] / [set_workspace] / [who] require state +
    registry and remain in [mcp_server_eio.ml] — those tools are
    NOT routed through this module's {!dispatch}.

    Type re-exports preserve identity with the source modules:
    - {!context} = {!Workspace_types.context}
    - {!assertion_kind} = {!Workspace_assertions.assertion_kind}

    Callers can interleave these types freely with the source
    modules' types.

    Internal: ~50+ helpers stay private — [effective_cluster_name],
    [unique_trimmed_nonblank], [credential_state],
    [safe_resolve_agent_name] / [safe_current_task] / [safe_get_agents],
    [resolve_current_binding], [planning_context_state],
    [assertion_kind_to_string], [all_assertion_kinds], plus per-tool handlers
    ([handle_status], [handle_init],
    [handle_check], [handle_assertion]).
    All consumed only inside {!dispatch}'s pipeline. *)

(** {1 Context} *)

(** Per-call context.  Concrete record — callers construct via
    [{ Tool_workspace.config; agent_name }] at the dispatch site. *)
type context = Workspace_types.context =
  { config : Workspace.config
  ; agent_name : string
  }

(** {1 Assertion kinds} *)

(** Agent_stream-state assertion targets used by the
    [masc_assert] tool.  Re-export of
    {!Workspace_assertions.assertion_kind} — type identity
    preserved.  Adding a constructor requires update in
    {!Workspace_assertions} (the SSOT) and propagates here
    automatically. *)
type assertion_kind = Workspace_assertions.assertion_kind =
  | Task_claimed
  | Current_task_set

(** [valid_assertion_strings] is the canonical list of
    assertion kind labels (one per constructor).  Used by error
    messages + the [masc_assert] schema [enum] field — adding a
    constructor automatically updates this list. *)
val valid_assertion_strings : string list

(** {1 Dispatch} *)

(** Tool names routed by {!dispatch}.  This list is derived from the
    same binding table used by runtime dispatch, so schema/registry
    tests can fail when a workspace schema is exposed without a handler
    route or a handler route is added without a schema. *)
val dispatchable_names : string list

(** [dispatch ctx ~name ~args] routes [name] to the appropriate
    private handler ([handle_status], [handle_init], [handle_check],
    [handle_assertion]).  Returns [None] when [name] is not a
    workspace tool — caller treats as "not my tool".

    Captures [start_time] at entry and threads [~tool_name:name
    ~start_time] to every handler so callers do not need to
    supply timing data.

    Status results are producer snapshots. Callers may pass [if_revision]
    to receive an [unchanged] envelope when the rendered snapshot and its
    task-list projection have not changed. *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.result option

(** Keeper-model dispatch uses Keeper-facing semantic capability names in
    rendered follow-up guidance. *)
val dispatch_for_keeper :
  context -> name:string -> args:Yojson.Safe.t -> Tool_result.result option
