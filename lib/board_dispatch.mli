
(** Board_dispatch — single-backend board dispatch + signal hooks.

    Wraps the JSONL-backed {!Board} store with: lazy initialisation,
    a fiber-protected flusher actor, sort-order projections, and two
    out-bound hook channels (keeper board signals + board SSE
    events).

    Internal state and helpers ([backend_state] Atomic carrying the
    flusher-started flag inside the [Active] variant since Tier D D-7,
    [start_flusher_actor], [ensure_flusher_actor],
    [keeper_board_signal_hook] / [board_sse_hook] Atomics,
    [emit_keeper_board_signal], [backend], [sort_posts_in_memory],
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

type keeper_board_signal_kind =
  | Board_post_created
  | Board_comment_added

type keeper_board_signal = {
  kind : keeper_board_signal_kind;
  post_id : string;
  author : string;
  title : string;
  content : string;
  hearth : string option;
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

val set_keeper_board_signal_hook : (keeper_board_signal -> unit) -> unit
(** Replace the in-process hook invoked from {!create_post} and
    {!add_comment}. Used by [Keeper_board_listener] to bridge into
    the keeper signal bus. *)

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
  unit ->
  (Board.post, Board.board_error) Result.t

val get_post : post_id:string -> (Board.post, Board.board_error) Result.t

val list_posts :
  ?visibility_filter:Board.visibility option ->
  ?hearth:string ->
  ?author_filter:string ->
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

(** {1 Karma} *)

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
