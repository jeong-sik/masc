
(** Board_tool — MCP tool family for the internal board.

    Owns:
    - the {b agent-lookup callback} ({!set_agent_lookup} /
      {!set_agent_lookup_none} / {!is_agent}) wired at
      server bootstrap for callers that need namespace-bound identity
      truth,
    - the {b post / comment / vote handlers} routed
      through {!handle_tool} (one entry per
      [masc_board_*] tool name),
    - the {b tools} list advertised to MCP clients
      (13 schemas: post, list, get, comment, vote, stats,
      search, comment_vote, reaction, profile, hearth_list,
      curation_read, delete),
    - the {b truncated-markdown detector}
      ({!detect_truncated_markdown_with_reason}) used by
      the post-create path to flag chat-suffix paste
      accidents,
    - the {b sort-order parser} ({!parse_sort_order})
      shared with the dashboard board route.

    Internal helpers stay private at this boundary
    ([board_list_cache] type + the cache cell, the
    [cached_board_list] adapter, [strip_state_blocks_text],
    [format_ttl_remaining],
    [agent_lookup_hook] atomic ref,
    [resolve_board_post_kind], [format_post] /
    [format_post_compact] / [format_comment] /
    [format_comment_tree], [assoc_replace],
    [judgment_arg], [normalize_board_post_meta],
    [handle_post_create] / [_list_uncached] / [_list] /
    [_get] / [_comment_add] / [_vote] / [_stats] /
    [_search] / [_comment_vote] / [_profile] /
    [_hearth_list] / [_delete] / [_board_cleanup],
    [board_list_cache_key], [evolution_callback] type,
    [evolution_hook] atomic ref,
    [register_evolution_callback], [tool_post_list],
    [tool_post_get], [tool_comment_add], [tool_vote],
    [tool_stats], [tool_search], [tool_comment_vote],
    [tool_profile], [tool_hearth_list], [tool_delete],
    [board_tool_cleanup], [tool_spec_read_only]). *)

open Masc_board_handlers

(** {1 Truncated markdown detection} *)

type truncation_signal =
  | Odd_fence
      (** odd count of triple-backtick code fences. *)
  | Odd_inline_tick
      (** odd count of single backticks outside fences. *)
  | Unfinished_link
      (** trailing [\[text\](] with no closing [)]. *)
  | Unfinished_image
      (** trailing [\!\[alt\](] with no closing [)]. *)
  | Odd_double_asterisk
      (** odd count of [**] outside fences. *)

val truncation_signal_to_string : truncation_signal -> string

val detect_truncated_markdown_with_reason :
  string -> truncation_signal option
(** Returns the first {!truncation_signal} that fires for
    the input, [None] when the markdown looks complete.
    Used by [handle_post_create] to surface a precise
    reason in the response when a paste appears
    truncated. *)

(** {1 Sort order} *)

type sort_order = Board_dispatch.sort_order =
  | Hot
  | Trending
  | Recent
  | Updated
  | Discussed
(** Type re-export from {!Board_dispatch.sort_order}.
    Identity preserved so [Board_tool.sort_order] and
    [Board_dispatch.sort_order] are interchangeable. *)

val parse_sort_order : string -> (sort_order, string) Result.t
(** Delegates to
    {!Board_dispatch.sort_order_of_string_opt} for canonical sort names.
    Error message lists
    {!Board_dispatch.valid_sort_order_strings} so adding
    a constructor automatically updates the user-facing
    catalogue. *)

(** {1 Display formatting} *)

val format_timestamp_relative : float -> string
(** Renders a Unix timestamp as a human-readable relative
    duration (["5s ago"] / ["3h ago"] / ["2d ago"]).
    Used in board listing prompt blocks. *)

(** {1 Board error rendering} *)

val board_error_to_string : Board.board_error -> string
(** Renders a {!Board.board_error} with a leading prefix
    (["Invalid ID:"] / ["Post not found:"] / ...).  Used
    by the dispatcher to convert [Board.X] errors into
    user-visible tool response messages. *)

val visibility_of_string : string -> Board.visibility option
(** Re-export of {!Board.visibility_of_string}.  Pinned at
    this boundary so callers reach it via
    [Board_tool.visibility_of_string] without importing
    {!Board} directly. *)

(** {1 Agent lookup callback} *)

val set_agent_lookup : (string -> bool) -> unit
(** Wires the [is_agent_session_bound] check used by {!is_agent}.
    Installed once at server bootstrap from
    [server_state.workspace_config].  Board post kind selection does
    not use this callback; callers must pass explicit [post_kind]. *)

val set_agent_lookup_none : unit -> unit
(** Clears the previously-installed callback.  Used by
    test isolation; production paths leave the hook set. *)

val is_agent : string -> bool
(** Returns the result of the registered hook, [false]
    when no hook is installed. *)

(** {1 Cache invalidation} *)

val invalidate_board_list_cache : unit -> unit
(** Drops the cached [masc_board_list] result so the next
    read sees fresh state.  Called automatically by
    {!handle_tool} after every mutation
    (post / comment / vote / delete / cleanup). *)

(** {1 Tools advertised to MCP} *)

val tool_post_create : Masc_domain.tool_schema
(** Schema for [masc_board_post].  Pinned at this
    boundary because the dashboard tool inspector renders
    the schema directly (other schema registries are
    reached only through {!tools}). *)

val tools : Masc_domain.tool_schema list
(** All board tool schemas in advertisement order:
    post / list / get / comment / vote / stats / search /
    comment_vote / reaction / profile / hearth_list / delete. *)

(** {1 Board dispatcher} *)

val handle_tool : string -> Yojson.Safe.t -> Tool_result.result
(** RFC-0189 PR-1b.4 — [handle_tool] returns typed [Tool_result.result]
    end-to-end. Legacy [Tool_result.result] projection lives at the
    {!Tool_dispatch.handler} registration boundary inside {!register},
    so external callers (MCP transport) see no behavior change. *)
(** Routes [name] to the matching internal handler.
    Mutation tools (post / comment / vote / delete /
    cleanup) automatically invoke
    {!invalidate_board_list_cache} on completion so the
    next [masc_board_list] reads fresh data.  Returns a
    {!Tool_result.result} carrying success flag, structured
    payload, tool name, and elapsed duration. *)

(** {1 Registry installation} *)

val register : unit -> unit
(** Installs every tool from {!tools} into the global
    {!Tool_dispatch} registry and pairs the canonical
    [masc_board_*] tag with each handler.  Idempotent;
    second call is a no-op. *)
