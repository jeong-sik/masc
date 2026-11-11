(** Tool_workspace — Workspace management MCP tools (status / check /
    heartbeat) and the goal tools.

    Type re-exports preserve identity with the source modules:
    - {!context} = {!Workspace_types.context}
    - {!assertion_kind} = {!Workspace_assertions.assertion_kind}

    Callers can interleave these types freely with the source
    modules' types.

    Internal: ~50+ helpers stay private — [unique_trimmed_nonblank], [credential_state],
    [safe_resolve_agent_name] / [safe_current_task],
    [resolve_current_binding],
    [assertion_kind_to_string], plus per-tool handlers
    ([handle_status], [handle_check], [handle_heartbeat]).
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
    [masc_check] tool.  Re-export of
    {!Workspace_assertions.assertion_kind} — type identity
    preserved.  Adding a constructor requires update in
    {!Workspace_assertions} (the SSOT) and propagates here
    automatically. *)
type assertion_kind = Workspace_assertions.assertion_kind =
  | Task_claimed
  | Current_task_set

(** {1 Dispatch} *)

(** [dispatch ctx ~name ~args] routes [name] to the appropriate
    private handler ([handle_status], [handle_check], [handle_heartbeat],
    or a goal handler).  Returns [None] when [name] is not a
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
