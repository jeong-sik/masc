(** Board signal payload parser for keeper world observation. *)

type match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  }

type comment_status =
  [ `Never
  | `No_new_external
  | `New_external of int * string * string
  | `Comment_read_error of string
  ]

val board_signal_of_board_stimulus
  :  post_id:string
  -> Keeper_event_queue.board_stimulus
  -> Board_dispatch.board_signal
(** Total conversion from the typed event-queue board payload to the
    [Board_dispatch.board_signal] the matchers consume (RFC-0020). *)

val post_id_string : Board.post -> string
val compare_cursor_token : float * string -> float * string -> int
val cursor_token_of_post : Board.post -> float * string
val list_posts_after_cursor : float * string option -> Board.post list
val text : Board_dispatch.board_signal -> string

val match_signal
  :  continuity_summary:string
  -> meta:Keeper_meta_contract.keeper_meta
  -> signal:Board_dispatch.board_signal
  -> match_result

val check_self_comment_status
  :  self_ids:Keeper_identity.Keeper_id.t list
  -> post_id:string
  -> comment_status

type wake_reason =
  | Explicit_mention
  | Thread_reply_after_self_comment
  | Board_comment_read_error of string
(** Closed set of reasons a keeper wakes for a board signal (RFC-0020).
    Replaces the prior [string option] contract; consumers match exhaustively
    so the previously dead ["board_activity"] generic bucket is gone. Related
    board activity is deliberately absent until it is produced by an explicit
    LLM/Fusion judgment boundary, not local keyword scoring. *)

val wake_reason_label : wake_reason -> string
(** Stable string label for logs/metrics. *)

val wake_reason
  :  continuity_summary:string
  -> meta:Keeper_meta_contract.keeper_meta
  -> signal:Board_dispatch.board_signal
  -> wake_reason option
(** [None] means the relevance pipeline found no reason for this keeper to
    wake (counted as [BoardSignalNoWakeTotal] by the caller). *)
