(** Server_utils — shared HTTP query-param parsing, list slicing,
    timestamp rendering, and board-actor identity resolution.

    Open'd by every HTTP-route module that needs query-param
    extraction or actor-identity rendering.  Helpers are organised
    by domain (HTTP query / list ops / time / board actor /
    pagination clamps). *)

(** {1 HTTP query-param helpers} *)

val query_param : Httpun.Request.t -> string -> string option
(** [query_param request key] returns [Some value] when the
    request URL has the named query parameter, [None] otherwise.
    Empty values render as [Some ""] — callers must trim if they
    want empty-as-absent semantics. *)

val int_query_param :
  Httpun.Request.t -> string -> default:int -> int
(** [int_query_param request key ~default] returns the parsed
    integer or [default] when the param is absent or non-integer.
    No range checking — callers compose with {!clamp}. *)

val bool_query_param :
  Httpun.Request.t -> string -> default:bool -> bool
(** [bool_query_param request key ~default] parses the param as
    boolean.  Truthy: [1] / [true] / [yes] / [y]
    (case-insensitive, trimmed).  Falsy: [0] / [false] / [no] /
    [n].  Anything else (including absent) returns [default]. *)

(** {1 Generic helpers} *)

val clamp : min_v:int -> max_v:int -> int -> int
(** [clamp ~min_v ~max_v v] returns [v] bounded to
    [\[min_v, max_v\]]. *)

val evict_oldest_if_full :
  max_entries:int -> age_of:('a -> float) -> ('k, 'a) Hashtbl.t -> unit
(** [evict_oldest_if_full ~max_entries ~age_of cache] removes the single entry
    with the smallest [age_of] value when [cache] already holds [max_entries]
    or more, otherwise a no-op. Call before inserting a new key to keep a cache
    keyed partly by client input bounded over process lifetime. *)

val take : int -> 'a list -> 'a list
(** [take n xs] is [List.take n xs] re-exported so callers using
    [open Server_utils] do not need to also open Stdlib's [List]
    aliases. *)

val drop : int -> 'a list -> 'a list
(** [drop n xs] is [List.drop n xs], symmetric with {!take}. *)

(** {1 Board sort helpers} *)

val board_sort_order_of_request :
  Httpun.Request.t -> Board_dispatch.sort_order
(** [board_sort_order_of_request request] reads [sort_by] query
    param and resolves it through
    {!Board_dispatch.sort_order_of_string_opt}.  Missing or
    invalid values fall back to {!Board_dispatch.Hot} — graceful
    UI degradation, not silent data corruption. *)

val board_sort_label : Board_dispatch.sort_order -> string
(** Thin alias over {!Board_dispatch.sort_order_to_string}. *)

(** {1 Board post / comment filtering} *)

val filter_board_posts :
  exclude_system:bool ->
  exclude_automation:bool ->
  Board.post list ->
  Board.post list
(** [filter_board_posts ~exclude_system ~exclude_automation posts]
    applies {!Board.post_matches_filters} to every entry. *)

val max_filtered_board_window : int
(** [5200] — the upper bound on [base_fetch] when either filter
    flag is active.  Pinned because the dashboard pagination
    contract depends on it: the worst-case fetch fans out to 5200
    rows when both filters are on, then the page is sliced.  A
    future "let's bump the window" change must orchestrate with
    the dashboard scroll-buffer behaviour. *)

val board_fetch_limit :
  exclude_system:bool ->
  exclude_automation:bool ->
  limit:int ->
  offset:int ->
  int
(** [board_fetch_limit ~exclude_system ~exclude_automation ~limit
    ~offset] computes the underlying fetch size.  Without any
    filter, returns [limit + offset].  With either filter active,
    returns [max (limit + offset) max_filtered_board_window] so
    downstream filtering has enough rows to slice. *)

(** {1 Board actor identity}

    Resolves a raw author/voter string (which can be a keeper
    name, an agent name aliased through the keeper registry, or a
    plain agent id) into a structured identity record.  Three
    lookup tiers, all operator-visible through the [source] field:

    1. [keeper_registry_agent_name] —
       {!Keeper_registry_lookup.find_by_agent_name}
    2. [keeper_registry_name] — {!Keeper_registry_lookup.find_by_name}
    3. [keeper_alias_contract] —
       {!Keeper_identity.canonical_keeper_name_from_agent_name}

    Misses fall through as [`agent`] kind with [source: "raw_agent"]. *)

val board_actor_key : kind:string -> string -> string
(** [board_actor_key ~kind id] produces the canonical lookup key
    [<kind>:<lowercased trimmed id>].  Used by the dashboard's
    actor-aggregation pipeline. *)

val board_actor_keeper_identity :
  string -> (string * string option * string) option
(** [board_actor_keeper_identity raw] returns
    [Some (keeper_name, runtime_agent_name, source)] when [raw]
    resolves to a keeper through any of the three lookup tiers,
    [None] otherwise.  [source] is one of the three literals
    listed above — operator runbooks grep on these. *)

val board_actor_identity_json : string -> Yojson.Safe.t
(** [board_actor_identity_json raw] renders the resolved identity
    as a JSON object with fields [kind] (["keeper"] or ["agent"])
    / [id] / [key] / [display_name] / [raw] / [source].  Keeper
    matches additionally include [runtime_agent_name] when the
    runtime agent name differs from the canonical keeper name. *)

val board_actor_entity : string -> Activity_graph.entity_ref
(** [board_actor_entity raw] returns the graph entity (kind +
    id pair) for graph-API consumers — the same resolution logic
    as {!board_actor_identity_json} but in the graph-typed shape. *)

val board_actor_author_for_write : string -> string
(** [board_actor_author_for_write raw] returns the canonical
    author identifier suitable for board write operations.
    Keeper matches collapse to the canonical keeper name; agent
    matches return the trimmed [raw] string.  Used to ensure
    board posts authored by a keeper consistently surface under
    the keeper's canonical name regardless of which alias the
    write request used. *)

val board_voter_query : Httpun.Request.t -> string option
(** Reads and canonicalizes the board [voter] query parameter. *)

val board_current_vote_for_post :
  voter:string option -> post_id:string -> Board.vote_direction option option
(** [None] means no voter was supplied; [Some None] means a voter was
    supplied but has not voted on this post. *)

val board_current_vote_for_comment :
  voter:string option -> comment_id:string -> Board.vote_direction option option

val board_reactions_for_post :
  voter:string option -> post_id:string -> Board.reaction_summary list

val board_reactions_for_comment :
  voter:string option -> comment_id:string -> Board.reaction_summary list

val board_reactions_batch :
  targets:(Board.reaction_target_type * string) list ->
  voter:string option ->
  ((Board.reaction_target_type * string) * Board.reaction_summary list) list
(** [board_reactions_batch ~targets ~voter] returns dashboard reaction
    summaries for a request's target set using one board-store scan. *)

val board_reactions_lookup :
  ((Board.reaction_target_type * string) * Board.reaction_summary list) list ->
  Board.reaction_target_type * string ->
  Board.reaction_summary list

val board_contributor_quality_json :
  Reputation.agent_reputation -> Yojson.Safe.t
(** [board_contributor_quality_json rep] projects the existing agent
    reputation record into the compact board contributor-quality contract. *)

val board_contributor_quality_lookup :
  ?config:Workspace.config -> unit -> string -> Yojson.Safe.t option
(** [board_contributor_quality_lookup ?config ()] returns a request-local
    memoized lookup by author.  Without [config], it returns [None]. *)

(** {1 Dashboard helpers} *)

val board_comment_dashboard_json :
  ?include_moderation:bool ->
  ?blind_votes:bool ->
  ?current_vote:Board.vote_direction option ->
  ?reactions:Board.reaction_summary list ->
  Board.comment ->
  Yojson.Safe.t
(** [board_comment_dashboard_json c] renders a comment with the
    [author_identity] field appended for dashboard inspection.  When
    [include_moderation] is [true], it also appends operator-only
    [report_count] and [moderation_status] fields.  When [blind_votes]
    is [true], score fields are hidden until [current_vote] records a
    viewer vote. *)

val board_post_dashboard_json :
  ?include_moderation:bool ->
  ?blind_votes:bool ->
  ?contributor_quality:Yojson.Safe.t ->
  ?current_vote:Board.vote_direction option ->
  ?reactions:Board.reaction_summary list ->
  author_karma:int ->
  Board.post ->
  Yojson.Safe.t
(** [board_post_dashboard_json ~author_karma p] renders a post
    with explicit operator-visible fields:

    - [title] / [body] (raw strings, not the SDK's structured
      shape).
    - [votes] = [votes_up - votes_down] (a single net score).
    - [comment_count] = [reply_count].
    - [created_at_iso] / [updated_at_iso] via {!iso8601_of_unix}.
    - [hearth_count] = 0 or 1 (boolean-as-int for the dashboard's
      column that aggregates across multiple hearths).
    - [author_identity] from {!board_actor_identity_json}.
    - [report_count] / [moderation_status] from {!Board_moderation}
      only when [include_moderation] is [true].
    - [vote_blind] / [vote_blind_reason] and null score fields when
      [blind_votes] is [true] and the viewer has not voted yet.
    - [contributor_quality] when supplied by the route layer from
      {!Reputation}.

    The base fields [title] / [votes] / [comment_count] /
    [created_at_iso] / [updated_at_iso] / [hearth_count] are
    {b removed} from the underlying [post_to_yojson_with_karma]
    output and re-injected with the dashboard-specific shapes —
    so the dashboard never sees the SDK's structured shapes by
    accident. *)

val dashboard_compact_mode : Httpun.Request.t -> bool
(** [dashboard_compact_mode request] returns [true] iff the
    [mode] query param equals ["compact"] (case-insensitive,
    trimmed). *)

(** {1 Path-param extraction} *)

val extract_path_param : prefix:string -> string -> string option
(** [extract_path_param ~prefix path] returns [Some param] when
    [path] starts with [prefix] AND has a non-empty trimmed
    suffix, [None] otherwise.  Guards against bounds violations
    that would crash {!String.sub} — pinned because the
    pre-extraction-helper code had three independent
    String.sub callsites that all crashed on edge inputs. *)

(** {1 Standard pagination} *)

val standard_limit : Httpun.Request.t -> int
(** [standard_limit request] reads the [limit] query param,
    defaulting to [50], and clamps to [\[1, 200\]]. *)

val standard_offset : Httpun.Request.t -> int
(** [standard_offset request] reads the [offset] query param,
    defaulting to [0], with a non-negative floor.  No upper
    clamp — pagination over very large windows is the caller's
    responsibility. *)
