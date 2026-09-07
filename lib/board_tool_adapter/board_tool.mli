
(** Board_tool — MCP tool family for the internal board.

    Owns:
    - the {b agent-lookup callback} ({!set_agent_lookup} /
      {!set_agent_lookup_none} / {!is_agent}) wired at
      server bootstrap for optional agent-to-agent feedback hooks,
    - the {b post / comment / vote handlers} routed
      through {!handle_tool} (one entry per
      [masc_board_*] tool name),
    - the {b tools} list advertised to MCP clients
      (post/list/get, comments, votes, reactions, stats,
      search, profile, hearths, curation, cleanup/delete,
      and sub-board operations),
    - the {b sort-order parser} ({!parse_sort_order})
      shared with the dashboard board route.

    Internal helpers stay private at this boundary
    ([format_expiry],
    [agent_lookup_hook] atomic ref,
    [resolve_board_post_kind], [format_post] /
    [format_post_compact] / [format_comment] /
    [format_comment_tree], [assoc_replace],
    [judgment_arg], [normalize_board_post_meta],
    [handle_post_create] / [_list] /
    [_get] / [_comment_add] / [_vote] / [_stats] /
    [_search] / [_comment_vote] / [_profile] /
    [_hearth_list] / [_delete] / [_board_cleanup],
    [evolution_callback] type,
    [evolution_hook] atomic ref,
    [register_evolution_callback], [tool_post_list],
    [tool_post_get], [tool_comment_add], [tool_vote],
    [tool_stats], [tool_search], [tool_comment_vote],
    [tool_profile], [tool_hearth_list], [tool_delete],
    [board_tool_cleanup]). *)

open Masc_board_handlers

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

(** {1 Identity meta keys} *)

val author_raw_agent_name_meta_key : string
(** Canonical board-post meta key for the raw runtime author
    identity preserved by HTTP/MCP identity enforcement. *)

(** {1 Display formatting} *)

val format_timestamp_absolute : float -> string
(** Renders a Unix timestamp as an ISO8601 UTC instant
    (["2026-07-28T02:15:30Z"]). Used in board listing prompt
    blocks, which an LLM turn consumes: output must be a
    function of the argument alone so the payload is
    byte-stable across calls. Relative rendering is a
    human-dashboard concern and lives in
    [Dashboard_labels] / [Tempo]. *)

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
(** Wires the [is_agent_session_bound] check used by optional
    agent-to-agent feedback hooks. Installed once at
    server bootstrap from [server_state.workspace_config]. *)

val set_agent_lookup_none : unit -> unit
(** Clears the previously-installed callback.  Used by
    test isolation; production paths leave the hook set. *)

val is_agent : string -> bool
(** Returns the result of the registered hook, [false]
    when no hook is installed. *)

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
    [masc_board_list] reads the store on every call, so a
    mutation is visible to the next read with no
    invalidation step.  Returns a {!Tool_result.result}
    carrying success flag, structured payload, tool name,
    and elapsed duration. *)

(** {1 Registry installation} *)

val register : unit -> unit
(** Installs every tool from {!tools} into the global
    {!Tool_dispatch} registry and pairs the canonical
    [masc_board_*] tag with each handler.  Idempotent;
    second call is a no-op. *)
