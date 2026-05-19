(** Board signal payload parser for keeper world observation. *)

type match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  ; score : int
  }

type comment_status = [ `Never | `No_new_external | `New_external of int * string * string ]

val of_stimulus_payload : string -> Board_dispatch.keeper_board_signal option

val post_id_string : Board.post -> string
val compare_cursor_token : float * string -> float * string -> int
val cursor_token_of_post : Board.post -> float * string
val list_posts_after_cursor : float * string option -> Board.post list
val text : Board_dispatch.keeper_board_signal -> string

val match_signal
  :  continuity_summary:string
  -> meta:Keeper_types.keeper_meta
  -> signal:Board_dispatch.keeper_board_signal
  -> match_result

val check_self_comment_status
  :  self_tokens:string list
  -> post_id:string
  -> comment_status

val wake_reason
  :  continuity_summary:string
  -> meta:Keeper_types.keeper_meta
  -> signal:Board_dispatch.keeper_board_signal
  -> string option
