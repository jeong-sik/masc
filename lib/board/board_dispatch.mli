
(** Board_dispatch — single-backend board dispatch + signal hooks.

    Wraps the JSONL-backed {!Board} store with: lazy initialisation,
    a fiber-protected flusher actor, sort-order projections, and two
    out-bound hook channels (board signals + board SSE
    events).

    Internal state and helpers ([backend_state] Atomic carrying the
    flusher-started flag inside the [Active] variant since Tier D D-7,
    [start_flusher_actor], [ensure_flusher_actor],
    [board_signal_hook] / [board_sse_hook] Atomics,
    [emit_board_signal], [backend], [sort_posts_in_memory],
    [normalize_author_filter], [agent_matches_author_filter],
    [matching_post_ids_for_comment_author_filter], the
    [all_sort_orders] convenience list, [is_initialized],
    [jsonl_forced], [sweep]) are hidden — callers consume the typed
    sort-order helpers, lifecycle entry points, post / comment /
    vote operations, and the JSON projection / hook setters
    only. *)

(** {1 Sort orders} *)

type sort_order = Hot | Trending | Recent | Updated | Discussed

val sort_order_to_string : sort_order -> string

val sort_order_of_string_opt : string -> sort_order option

val valid_sort_order_strings : string list
(** Every {!sort_order} stringified, in the canonical order used by
    the dashboard pickers. *)

(** {1 Hook events} *)

type board_signal_kind =
  | Board_post_created
  | Board_comment_added

type board_signal = {
  kind : board_signal_kind;
  post_id : string;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}

type board_sse_event =
  | Post_created of {
      post_id : string;
      author : string;
      title : string;
      content : string;
      post_kind : Board.post_kind;
      hearth : string option;
    }
  | Comment_added of {
      post_id : string;
      comment_id : string;
      author : string;
    }
  | Post_voted of {
      post_id : string;
      voter : string;
      direction : Board.vote_direction;
    }
  | Comment_voted of {
      comment_id : string;
      voter : string;
      direction : Board.vote_direction;
    }
  | Reaction_changed of {
      target_type : Board.reaction_target_type;
      target_id : string;
      user_id : string;
      emoji : string;
      reacted : bool;
    }

val set_board_signal_hook : (board_signal -> unit) -> unit
(** Replace the in-process hook invoked from {!create_post} and
    {!add_comment}. *)

val set_board_sse_hook : (board_sse_event -> unit) -> unit
(** Replace the in-process SSE hook invoked from every mutating
    operation. *)

val emit_board_sse_event : board_sse_event -> unit
(** Direct emission entry point for callers that want to broadcast
    a synthetic event without going through one of the typed
    operations. *)

(** {1 Backend lifecycle} *)

type board_backend =
  | Jsonl of Board.store
(** Currently single-variant; new backends would be added here. *)

val backend : unit -> board_backend
(** Returns the currently-active backend, lazy-initialising it on
    first call (defaulting to {!Jsonl}). Exposed so the dispatch
    test suite can reach into the underlying [Board.store] directly. *)

val init_jsonl : unit -> unit
(** Initialise the JSONL backend (idempotent). *)

val reset_for_test : unit -> unit
(** Drop the in-memory backend. Test-only. *)

val force_flusher_start_cas_conflicts_for_test : int -> unit
(** Force the next [n] flusher-start CAS attempts to lose. Test-only. *)

val flusher_started_for_test : unit -> bool
(** [true] iff the active backend has marked its flusher daemon as started.
    Test-only. *)

val flusher_start_backoff_delay_for_test : attempt:int -> float
(** Exponential backoff delay used after a flusher-start CAS loss. Test-only. *)

val backend_name : unit -> string
(** ["jsonl"] when initialised, ["uninitialized"] otherwise. *)

val jsonl_forced : unit -> bool
(** [true] iff [MASC_BOARD_BACKEND] forces the JSONL backend.
    Exposed so the dispatch test can pin the env-driven default. *)

(** {1 Posts} *)

val create_post :
  author:string ->
  content:string ->
  ?title:string ->
  ?body:string ->
  post_kind:Board.post_kind ->
  ?meta_json:Yojson.Safe.t ->
  ?visibility:Board.visibility ->
  ?ttl_hours:int ->
  ?hearth:string ->
  ?thread_id:string ->
  ?origin:Board.post_origin ->
  unit ->
  (Board.post, Board.board_error) Result.t

(** Owner-gated in-place edit of an existing post's title/body.  Returns
    [Unauthorized] when [editor] does not own the post, [Post_not_found] for a
    missing id, and [Validation_error] for empty/oversized content or invalid
    [new_author].  When provided by the current owner, [new_author] transfers
    persisted ownership. *)
val update_post :
  post_id:string ->
  editor:string ->
  content:string ->
  ?title:string ->
  ?body:string ->
  ?new_author:string ->
  unit ->
  (Board.post, Board.board_error) Result.t

val get_post : post_id:string -> (Board.post, Board.board_error) Result.t

val list_posts :
  ?visibility_filter:Board.visibility option ->
  ?hearth:string ->
  ?author_filter:string ->
  ?exclude_author_filter:string ->
  ?post_kind_filter:Board.post_kind ->
  ?sort_by:sort_order ->
  ?exclude_system:bool ->
  ?exclude_automation:bool ->
  ?limit:int ->
  unit ->
  Board.post list

val delete_post : post_id:string -> (unit, Board.board_error) Result.t

val set_thread_id :
  post_id:string ->
  thread_id:string ->
  (unit, Board.board_error) Result.t

val set_pinned :
  post_id:string ->
  pinned:bool ->
  (unit, Board.board_error) Result.t
(** Sets the [pinned] flag on a post (operator pin). Owner-gated at the
    HTTP boundary; persists across restart. *)

val search :
  query:string ->
  limit:int ->
  Board.post list

val reclassify_posts :
  ?limit:int -> ?dry_run:bool -> unit -> Board.reclassify_report

val post_to_yojson_with_karma :
  Board.post -> author_karma:int -> Yojson.Safe.t

(** {1 Comments} *)

val add_comment :
  post_id:string ->
  author:string ->
  content:string ->
  ?parent_id:string ->
  ?ttl_hours:int ->
  unit ->
  (Board.comment, Board.board_error) Result.t

val get_comments :
  post_id:string ->
  (Board.comment list, Board.board_error) Result.t

val get_post_and_comments :
  post_id:string ->
  ?comment_offset:int ->
  ?comment_limit:int ->
  unit ->
  (Board.post * Board.comment list, Board.board_error) Result.t

val list_comments : ?limit:int -> unit -> Board.comment list

(** {1 Votes} *)

val current_vote_for_post :
  voter:string ->
  post_id:string ->
  (Board.vote_direction option, Board.board_error) Result.t

val vote :
  voter:string ->
  post_id:string ->
  direction:Board.vote_direction ->
  (int, Board.board_error) Result.t

val current_vote_for_comment :
  voter:string ->
  comment_id:string ->
  (Board.vote_direction option, Board.board_error) Result.t

val vote_comment :
  voter:string ->
  comment_id:string ->
  direction:Board.vote_direction ->
  (int, Board.board_error) Result.t

val toggle_reaction :
  target_type:Board.reaction_target_type ->
  target_id:string ->
  user_id:string ->
  emoji:string ->
  (Board.reaction_toggle_result, Board.board_error) Result.t

val list_reactions :
  target_type:Board.reaction_target_type ->
  target_id:string ->
  ?user_id:string ->
  unit ->
  (Board.reaction_summary list, Board.board_error) Result.t

val list_reactions_batch :
  targets:(Board.reaction_target_type * string) list ->
  ?user_id:string ->
  unit ->
  ((Board.reaction_target_type * string) * Board.reaction_summary list) list

(** {1 Karma} *)

val karma_score_for_direction : Board.vote_direction -> int
(** Scoring contract re-export: [Up] → [+1], [Down] → [0].
    See {!Board.karma_score_for_direction}. *)

val get_karma_ledger :
  ?agent:string ->
  ?limit:int ->
  unit ->
  Board.karma_event list
(** Return attributed karma events from the active backend.

    Events are drawn from the in-memory vote log via
    {!Board.build_karma_ledger} and are sorted ascending by [ts]
    (oldest first).

    @param agent  When provided, filters to events where
                  [karma_event.recipient = agent] (case-sensitive).
    @param limit  Caps the result list (applied after filtering).
                  Default: unlimited.

    The rebuild contract: summing [delta] over the unfiltered
    result must equal [get_all_karma ()] for every recipient. *)

val get_all_karma : unit -> (string * int) list

val get_agent_karma : agent_name:string -> int

(** {1 Aggregates} *)

val list_hearths : unit -> (string * int) list

val stats : unit -> Yojson.Safe.t
(** Board snapshot ([post_count] / [comment_count] / per-author /
    per-hearth aggregates) projected to JSON. *)

(** {1 Persistence} *)

val flush : unit -> unit
(** Force-flush dirty posts/comments to disk. *)

(** {1 AI curation} *)

val submit_curation_snapshot :
  submitted_by:string ->
  ?summary:string ->
  ordering:string list ->
  highlights:string list ->
  ?tag_suggestions:Board_curation.curation_tag_suggestion list ->
  ?answer_matches:Board_curation.curation_answer_match list ->
  rationale:string ->
  ?provenance:Yojson.Safe.t ->
  unit ->
  Board_curation.curation_snapshot
(** Create a fresh {!Board_curation.curation_snapshot} and make it the
    current latest snapshot.  Returns the snapshot (including its
    generated ID and timestamp) so callers can log or forward it. *)

val latest_curation_snapshot :
  unit -> Board_curation.curation_snapshot option
(** Return the most recently submitted curation snapshot, or [None] if
    none has been submitted in this process lifetime. *)

(** {1 SubBoard operations} *)

val create_sub_board :
  slug:string ->
  name:string ->
  description:string ->
  owner:string ->
  ?members:string list ->
  ?access:Board.sub_board_access ->
  unit ->
  (Board.sub_board, Board.board_error) Result.t

val get_sub_board :
  sub_board_id:string ->
  (Board.sub_board, Board.board_error) Result.t

val list_sub_boards : unit -> Board.sub_board list

val delete_sub_board :
  sub_board_id:string ->
  (unit, Board.board_error) Result.t

val update_sub_board :
  sub_board_id:string ->
  ?name:string ->
  ?description:string ->
  ?members:string list ->
  ?access:Board.sub_board_access ->
  unit ->
  (Board.sub_board, Board.board_error) Result.t
