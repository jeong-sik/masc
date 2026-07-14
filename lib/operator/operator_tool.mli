
(** Tool_operator — MCP tools for operator control plane
    (snapshot / digest / action / confirm / judgment / surface
    audit).

    Single dispatch entry: {!dispatch}.  Two schema lists exposed
    so the SDK adapter can advertise the operator-remote subset
    separately from the full tool catalog.

    Internal: 22 schema-constructor / action-enum / dispatcher
    helper functions stay private — the .mli pins {!schemas} /
    {!remote_schemas} list contents at module init, so caller
    contract is the lists, not the constructors. *)

(** {1 Per-call context} *)

type 'a context = 'a Tool_operator.context

(** Per-tool-call capability bundle.  Concrete record because
    callers (notably {!Mcp_server_eio_execute}) construct it
    field-by-field at the dispatch site.  Polymorphic [\\'a] on
    [clock] propagates Eio's row-typed clock through to
    {!Operator_control}'s downstream context.  {!dispatch}
    instantiates [\\'a] to [float Eio.Time.clock_ty] to match
    {!Operator_control}'s concrete-clock requirement. *)

(** {1 Result} *)

type tool_result = Tool_result.result
(** Re-exported from {!Tool_result}.  RFC-0062 Phase 4c-2:
    handlers return structured [Tool_result.result] records. *)

(** {1 Dispatch} *)

val dispatch :
  float Eio.Time.clock_ty context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.result option
(** [dispatch ctx ~name ~args] dispatches the named MCP tool call.
    Returns [None] for unrecognised names so callers can fall
    through to other dispatchers.

    Recognised names (full catalog — see {!schemas} for the
    schema bodies):
    - [masc_operator_snapshot] — read operator state.
    - [masc_operator_digest] — daily digest.
    - [masc_operator_action] — schedule an action (requires
      confirm via separate call).
    - [masc_operator_chat_recovery_resolve] — exact receipt recovery CAS.
    - [masc_operator_confirm] — confirm a pending action.
    - [masc_operator_judgment_write] — record a judgment (hidden
      from default catalog).
    - [masc_operator_judgment_latest] — read latest judgment.
    - [masc_surface_audit] — operator-only surface drift audit. *)

(** {1 Catalog surfaces}

    The full catalog ({!schemas}, internal) and the operator-remote
    subset ({!remote_schemas}) advertise different tool sets to
    different MCP profiles.

    {b Why split}: the operator-remote profile is the externally
    reachable seam (dashboard / SDK), so it advertises only the
    safe-to-expose subset.  The full {!schemas} is consumed inside
    the keeper-bound dispatcher only. *)

val schemas : Masc_domain.tool_schema list
(** Full operator tool schemas for local/internal MCP catalogs. *)

val remote_schemas : Masc_domain.tool_schema list
(** Operator-remote tool schemas — the subset advertised to remote
    MCP clients.  Pinned at the .mli seam so dashboard / SDK
    consumers see a stable list ordering. *)

val schemas : Masc_domain.tool_schema list
(** Full operator tool schemas — consumed by keeper-local dispatchers
    and schema coverage checks. *)

val remote_tool_names : string list
(** Operator-remote tool names from {!Tool_name.Operator_remote_name.all_strings}.
    Kept aligned with {!remote_schemas} by coverage tests. *)

val force_link : unit
