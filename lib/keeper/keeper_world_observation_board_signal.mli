(** Board signal payload parser for keeper world observation. *)

type match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  }

type board_read_operation =
  | Get_post
  | Get_comments

type board_unavailable =
  { operation : board_read_operation
  ; post_id : string
  ; error : Board.board_error
  }

type 'a board_read =
  | Available of 'a
  | Unavailable of board_unavailable

type comment_state =
  [ `Never
  | `No_new_external
  | `New_external of int * string * string
  ]

type comment_status = comment_state board_read

(** Exact source/store boundary for a failed Board read. Closed set: adding a
    new {!Board.board_error} variant forces an explicit mapping. *)
type read_failure_kind =
  | Source_rejected
      (** The source is absent or the read request itself is rejected. *)
  | Store_io_failed
      (** The Board store failed to perform the read. *)

val read_failure_kind_of_error : Board.board_error -> read_failure_kind
val read_failure_kind_of_unavailable : board_unavailable -> read_failure_kind

(* [board_read_operation_to_string] renders the operation inside
   [unavailable_to_string] below, which is this module's only use of it. *)
val unavailable_to_string : board_unavailable -> string

val board_signal_of_board_stimulus
  :  post_id:string
  -> Keeper_event_queue.board_stimulus
  -> Board_dispatch.board_signal
(** Total conversion from the typed event-queue board payload to the
    [Board_dispatch.board_signal] the matchers consume (RFC-0020). *)

val board_stimulus_of_board_signal
  :  Board_dispatch.board_signal
  -> Keeper_event_queue.board_stimulus
(** Total inverse conversion used by durable Board-signal producers. *)

(* [post_id_string] is how [cursor_token_of_post] below keys a post; that is
   its only caller. *)
val compare_cursor_token : float * string -> float * string -> int
val cursor_token_of_post : Board.post -> float * string
val list_posts_after_cursor : float * string option -> Board.post list
val text : Board_dispatch.board_signal -> string
val address_text : Board_dispatch.board_signal -> string
(** Text authored by the current signal producer and therefore allowed to
    carry addressing authority. A post uses its title/content (never the
    category [hearth]), a
    comment uses only the new comment body, and a reaction carries no textual
    address. Inherited post display fields never re-address later events. *)
val mention_ids_of_signal : Board_dispatch.board_signal -> Keeper_identity.Keeper_id.t list

val match_signal
  :  meta:Keeper_meta_contract.keeper_meta
  -> signal:Board_dispatch.board_signal
  -> match_result

val check_self_comment_status
  :  self_ids:Keeper_identity.Keeper_id.t list
  -> post_id:string
  -> comment_status

type wake_reason =
  | Explicit_mention
  | Broadcast
  | Comment_on_self_post
  | Thread_reply_after_self_comment
  | Reaction_after_self_activity
(** Closed set of reasons a keeper wakes for a board signal (RFC-0020).
    Replaces the prior [string option] contract; consumers match exhaustively
    so the previously dead ["board_activity"] generic bucket is gone. Semantic
    relatedness is intentionally absent: it must enter through an LLM/Judge
    attention boundary, not through board-publish keyword matching. *)

val wake_reason_label : wake_reason -> string
(** Stable string label for logs/metrics. *)

val wake_reason
  :  meta:Keeper_meta_contract.keeper_meta
  -> signal:Board_dispatch.board_signal
  -> wake_reason option board_read
(** [Available None] means the structural reactive pipeline found no
    deterministic address for this keeper. [Unavailable _] preserves a typed
    Board read failure so callers can retain durable work and avoid acking it. *)
