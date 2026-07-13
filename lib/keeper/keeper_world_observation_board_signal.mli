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

exception Board_unavailable of board_unavailable

val board_read_operation_to_string : board_read_operation -> string
val unavailable_to_string : board_unavailable -> string
val raise_unavailable : board_unavailable -> 'a

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

val post_id_string : Board.post -> string
val compare_cursor_token : float * string -> float * string -> int
val cursor_token_of_post : Board.post -> float * string
val list_posts_after_cursor : float * string option -> Board.post list
val text : Board_dispatch.board_signal -> string
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
