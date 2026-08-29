(** Mcp_server_eio_tool_profile — Tool profile filtering, schema
    rendering, annotations, titles, and pagination cursors for the
    MCP server endpoint.

    Three profiles ({!tool_profile}) gate which tool subset is
    advertised on a given endpoint:

    - [Full]: developer / internal MCP surface (full catalog).
    - [Managed_agent]: spawned agent surface (Agent Core contract +
      passthrough subset).
    - [Operator_remote]: observation and intervention surface.

    Pagination contract: callers consume {!parse_cursor_only_params}
    / {!requested_tool_list_params} as concrete records — record
    fields are part of the contract.  Cursor values themselves are
    opaque base64 strings produced by {!page_items_with_cursor}.

    Internal: [StringSet] / [StringMap],
    [managed_agent_passthrough_tool_names] (consumed by
    {!tool_schemas_for_profile} only), [label_words_from_identifier]
    + the [custom_tool_titles] / [custom_title_table] data tables
    (consumed by {!tool_title_of_name}), the parsing helpers
    [strict_assoc_params] / [cursor_param] / [bool_param] /
    [take_list] / [validate_optional_meta], and the raw cursor codec
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

val default_instructions : unit -> string
(** [default_instructions ()] returns [Full] profile instructions. Describes
    where MASC state lives (project / cluster / read / write conventions). It
    names no tool as a thing to call: the typed schema is the callable
    catalog. *)

val managed_agent_instructions : string
(** [Managed_agent] profile instructions.  States that the profile exposes
    the internal agent control surface, and warns that the public /mcp
    surface and the managed-agent surface diverge in inventory. *)

val operator_remote_instructions : string
(** [Operator_remote] profile instructions.  Names the 6 operator
    tools ([masc_operator_snapshot], [masc_operator_digest],
    [masc_operator_action],
    [masc_operator_board_attention_quarantine_requeue],
    [masc_operator_task_recovery_resolve], [masc_operator_confirm])
    and the confirm_token contract for [confirm_required = true]. *)

(** {1 Schema filtering} *)

val tool_schemas_for_profile :
  ?include_hidden:bool ->
  Mcp_server.server_state ->
  tool_profile ->
  Masc_domain.tool_schema list
(** [tool_schemas_for_profile ?include_hidden
      state profile] returns the schema
    list visible on [profile]:

    - [Full]: [Config.visible_tool_schemas] gated by [include_hidden], public
      surface membership, and [Tool_catalog.allow_direct_call].
    - [Managed_agent]: agent-core tool contract +
      [managed_agent_passthrough_tool_names] subset.
    - [Operator_remote]: pinned [Tool_operator.remote_schemas].

    All defaults are [false].  [_state] is reserved for future
    state-dependent filtering; currently unused. *)

val tool_allowed_in_profile :
  Mcp_server.server_state ->
  tool_profile ->
  string ->
  bool
(** [tool_allowed_in_profile state
      profile tool_name] is the call-time gate (vs the
      list-time {!tool_schemas_for_profile}):

    - [Full]: [tool_name] is in the raw schema inventory, remains active, and
      satisfies [Tool_catalog.allow_direct_call].
    - [Managed_agent]: Agent Core binding by name, OR present in the
      managed-agent profile schema list.
    - [Operator_remote]: in [Tool_operator.remote_tool_names]. *)

(** {1 Annotations / titles / output schema} *)

val tool_annotations_for_profile :
  tool_profile -> string -> Yojson.Safe.t option
(** [tool_annotations_for_profile profile tool_name] returns the
    MCP 2025-03-26 [annotations] object. It projects only the explicitly
    registered [readOnlyHint] and [idempotentHint] capabilities.

    Returns [None] when the field set would be empty.
    Subjective mutation severity and open-world classifications are not
    inferred. [profile] currently does not alter these exact annotations. *)

val tool_json_for_profile :
  ?usage_summary:Telemetry_eio.tool_usage_summary ->
  tool_profile ->
  Masc_domain.tool_schema ->
  Yojson.Safe.t
(** [tool_json_for_profile ?usage_summary profile schema] renders
    a tool descriptor object: [name], [title], [description],
    [inputSchema], catalog metadata fields,
    descriptor metadata fields when a descriptor owns the tool name,
    [outputSchema] (currently always omitted), [annotations], plus optional
    usage telemetry from [?usage_summary]. *)

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
    callers destructure ([Ok { names; include_hidden; include_usage;
    cursor }]). *)
type tools_list_params = {
  names : string list option;
  include_hidden : bool;
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
    [include_hidden], [include_usage], [cursor].  Unknown keys /
    wrong types return [Error _]. *)

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
