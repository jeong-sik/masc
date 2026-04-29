(** Mcp_server_eio_tool_profile — Tool profile filtering, schema
    rendering, annotations, titles, and pagination cursors for the
    MCP server endpoint.

    Three profiles ({!tool_profile}) gate which tool subset is
    advertised on a given endpoint:

    - [Full]: developer / internal MCP surface (full catalog).
    - [Managed_agent]: spawned agent surface (SDK contract +
      passthrough subset).
    - [Operator_remote]: control-plane surface (4 operator tools).

    Pagination contract: callers consume {!parse_cursor_only_params}
    / {!requested_tool_list_params} as concrete records — record
    fields are part of the contract.  Cursor values themselves are
    opaque base64 strings produced by {!page_items_with_cursor}.

    Internal: [StringSet] / [StringMap], [dedupe_tool_schemas_by_name],
    [managed_agent_passthrough_tool_names] (consumed by
    {!tool_schemas_for_profile} only), [label_words_from_identifier]
    + the [custom_tool_titles] / [custom_title_table] data tables
    (consumed by {!tool_title_of_name}), [tool_icons_for_name]
    (consumed by {!tool_json_for_profile}), the parsing helpers
    [strict_assoc_params] / [cursor_param] / [bool_param] /
    [decode_cursor_offset] / [drop_list] / [take_list] /
    [paginate_json_items] / [cursor_only_params] /
    [validate_optional_meta], and the raw cursor codec
    [encode_cursor] / [decode_cursor] (callers go through
    {!page_items_with_cursor}). *)

(** {1 Profile} *)

(** Tool surface profile.  Re-exported from {!Mcp_server_eio_types}
    so callers can match on variants without importing the types
    module directly. *)
type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

(** {1 Profile-specific instructions}

    Pinned literals served as the [instructions] field on each
    [initialize] response.  Operator-visible — drift in these
    strings changes how clients describe / discover the server. *)

val default_instructions : string
(** [Full] profile instructions.  Describes MASC project /
    cluster / read / write conventions and points clients at
    [masc_tool_help]. *)

val managed_agent_instructions : string
(** [Managed_agent] profile instructions.  Names the canonical
    task-control tools ([masc_status], [masc_tasks],
    [masc_claim_next], [masc_transition], [masc_plan_set_task])
    and warns that the public /mcp surface and managed-agent
    surface diverge in inventory. *)

val operator_remote_instructions : string
(** [Operator_remote] profile instructions.  Names the 4 operator
    tools ([masc_operator_snapshot], [masc_operator_digest],
    [masc_operator_action], [masc_operator_confirm]) and the
    confirm_token contract for [confirm_required = true]. *)

(** {1 Schema filtering} *)

val tool_schemas_for_profile :
  ?include_hidden:bool ->
  ?include_deprecated:bool ->
  ?include_keeper_internal:bool ->
  Mcp_server.server_state ->
  tool_profile ->
  Types.tool_schema list
(** [tool_schemas_for_profile ?include_hidden ?include_deprecated
      ?include_keeper_internal state profile] returns the schema
    list visible on [profile]:

    - [Full]: union of [Config.visible_tool_schemas] (gated by
      [include_hidden]/[include_deprecated]) plus optional
      keeper-internal tools when [include_keeper_internal = true],
      deduped by name.
    - [Managed_agent]: SDK tool contract +
      [managed_agent_passthrough_tool_names] subset.
    - [Operator_remote]: pinned [Tool_operator.remote_schemas].

    All defaults are [false].  [_state] is reserved for future
    state-dependent filtering; currently unused. *)

val tool_allowed_in_profile :
  ?internal_keeper_runtime:bool ->
  Mcp_server.server_state ->
  tool_profile ->
  string ->
  bool
(** [tool_allowed_in_profile ?internal_keeper_runtime state
      profile tool_name] is the call-time gate (vs the
      list-time {!tool_schemas_for_profile}):

    - [Full]: [tool_name] is in
      [Config.visible_tool_schemas].  [Tool_catalog.Keeper_internal]
      tools are gated by [internal_keeper_runtime] (default
      [false]) — see #8699 for the exhaustive-match rationale.
    - [Managed_agent]: SDK binding by name, OR present in the
      managed-agent profile schema list.
    - [Operator_remote]: in [Tool_operator.remote_tool_names]. *)

(** {1 Annotations / titles / icons / output schema} *)

val tool_annotations_for_profile :
  tool_profile -> string -> Yojson.Safe.t option
(** [tool_annotations_for_profile profile tool_name] returns the
    MCP 2025-03-26 [annotations] object — [readOnlyHint],
    [destructiveHint], [idempotentHint], [openWorldHint],
    [deprecated], [successor], [deprecationReason] — derived from
    {!Tool_catalog.metadata} with fallback to
    {!Tool_dispatch.is_read_only} / [is_destructive] /
    [is_idempotent].

    Returns [None] when the field set would be empty.
    [openWorldHint] is emitted only when the tool is unambiguously
    open (destructive) or closed (read-only) — coarse by design
    (#7480 Step 1).  [profile] currently unused; reserved for
    profile-aware annotations. *)

val tool_title_of_name : string -> string
(** [tool_title_of_name name] returns the human-readable title:

    + Custom title from the internal [custom_tool_titles] table
      when present.
    + Otherwise auto-generated Title Case from the identifier
      (drops [masc_] prefix, splits on [_], capitalises each word). *)

val tool_output_schema_field : string -> Yojson.Safe.t option
(** [tool_output_schema_field _] currently returns [None] for
    every tool — outputSchema advertising is intentionally
    disabled until handlers can guarantee structuredContent.
    Pinned at the contract seam: drift here breaks strict clients
    (Kimi/FastMCP) which reject malformed tool results.  See the
    inline rationale in the implementation. *)

val tool_json_for_profile :
  ?usage_summary:Telemetry_eio.tool_usage_summary ->
  tool_profile ->
  Types.tool_schema ->
  Yojson.Safe.t
(** [tool_json_for_profile ?usage_summary profile schema] renders
    a tool descriptor object: [name], [title], [description],
    [icons], [inputSchema], catalog metadata fields,
    [outputSchema] (currently always omitted), [annotations],
    plus optional usage telemetry from [?usage_summary]. *)

(** {1 JSON helpers} *)

val maybe_assoc_field :
  string -> Yojson.Safe.t option -> (string * Yojson.Safe.t) list
(** [maybe_assoc_field name v] returns [\[(name, value)\]] when
    [v = Some value] and [\[\]] when [v = None].  Lets callers
    build assoc lists conditionally without intermediate
    [List.filter_map]. *)

(** {1 Pagination params} *)

(** Parsed cursor-only request params.  Cursor is opaque base64;
    callers pass it back to {!page_items_with_cursor} for the
    same [~kind]. *)
type cursor_params = { cursor : string option }

(** Parsed [tools/list] request params.  Concrete record because
    callers destructure ([Ok { names; include_hidden;
    include_deprecated; include_usage; cursor }]). *)
type tools_list_params = {
  names : string list option;
  include_hidden : bool;
  include_deprecated : bool;
  include_usage : bool;
  cursor : string option;
}

val parse_cursor_only_params :
  Yojson.Safe.t option -> (cursor_params, string) result
(** [parse_cursor_only_params params] validates a cursor-only
    payload (used by [resources/list], [resources/templates/list],
    [prompts/list]).  Allowed keys: [_meta], [cursor].  Unknown
    keys / wrong types return [Error _] with operator-readable
    messages.  *)

val requested_tool_list_params :
  Yojson.Safe.t option -> (tools_list_params, string) result
(** [requested_tool_list_params params] validates the
    [tools/list] payload.  Allowed keys: [_meta], [names],
    [include_hidden], [include_deprecated], [include_usage],
    [cursor].  Unknown keys / wrong types return [Error _]. *)

(** {1 Pagination dispatch} *)

val list_page_size : unit -> int
(** [list_page_size ()] reads [Env_config.Tools.list_page_size ()]
    at call time.  Used by {!page_items_with_cursor} as the page
    cap — env mutation takes effect on next call. *)

val page_items_with_cursor :
  kind:string ->
  'a list ->
  string option ->
  ('a list * string option, string) result
(** [page_items_with_cursor ~kind items cursor] paginates [items]
    using an opaque base64 cursor:

    - [cursor = None] -> start from offset 0.
    - [cursor = Some encoded] -> decode [encoded] under [~kind]
      (cursors are kind-bound; cross-kind reuse fails).

    Returns [(page, next_cursor)] where [next_cursor = Some _]
    when more items remain, otherwise [None].  Page size comes
    from {!list_page_size}.  Returns [Error _] when the cursor
    is malformed or kind-mismatched. *)
