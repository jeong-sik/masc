open Base

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

type 'a context = {
  config : Coord.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
  mcp_session_id : string option;
}
(** Per-tool-call capability bundle.  Concrete record because
    callers (notably {!Mcp_server_eio_execute}) construct it
    field-by-field at the dispatch site.  Polymorphic [\\'a] on
    [clock] propagates Eio's row-typed clock through to
    {!Operator_control}'s downstream context.  {!dispatch}
    instantiates [\\'a] to [float Eio.Time.clock_ty] to match
    {!Operator_control}'s concrete-clock requirement. *)

(** {1 Result} *)

type tool_result = bool * string
(** Standard MCP tool return: [(success, body_or_error)].
    [body_or_error] is the JSON-serialised body on success or an
    error message on failure. *)

(** {1 Dispatch} *)

val dispatch :
  float Eio.Time.clock_ty context ->
  name:string ->
  args:Yojson.Safe.t ->
  tool_result option
(** [dispatch ctx ~name ~args] dispatches the named MCP tool call.
    Returns [None] for unrecognised names so callers can fall
    through to other dispatchers.

    Recognised names (full catalog — see {!schemas} for the
    schema bodies):
    - [masc_operator_snapshot] — read operator state.
    - [masc_operator_digest] — daily digest.
    - [masc_operator_action] — schedule an action (requires
      confirm via separate call).
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

val remote_schemas : Types.tool_schema list
(** Operator-remote tool schemas — the subset advertised to remote
    MCP clients.  Pinned at the .mli seam so dashboard / SDK
    consumers see a stable list ordering. *)

val remote_tool_names : string list
(** [List.map (fun s -> s.name) remote_schemas].  Pre-computed for
    O(1) membership checks in the auth gate. *)
