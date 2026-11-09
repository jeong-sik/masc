(** Voting and vote-log effects for one canonical Board store.

    Cast operations stage under the state lock, append under persistence,
    release persistence, then commit under a fresh state lock. The primary
    posts source must be authoritative before the vote append is admitted. *)

open Board_types

val vote_direction_to_string : vote_direction -> string
val valid_vote_direction_strings : string list
val vote_direction_of_string_opt : string -> vote_direction option
(** Lowercases and trims input; unknown or empty input returns [None]. *)

val vote_log_path : store -> string

val current_vote_for_post :
  store -> voter:string -> post_id:string ->
  (vote_direction option, board_error) Result.t
(** [None] means no recorded vote for an existing target. A missing target
    returns [Post_not_found]. *)
val vote :
  store -> voter:string -> post_id:string -> direction:vote_direction ->
  (int, board_error) Result.t
val current_vote_for_comment :
  store -> voter:string -> comment_id:string ->
  (vote_direction option, board_error) Result.t
(** [None] means no recorded vote for an existing target. A missing target
    returns [Comment_not_found]. *)
val vote_comment :
  store -> voter:string -> comment_id:string -> direction:vote_direction ->
  (int, board_error) Result.t

val vote_log_jsonl : store -> string
(** Render the committed ledger under the caller's state lock, preserving
    stored cast times. Invalid in-memory keys retain their exception. *)

val save_vote_log_jsonl : store -> string -> (unit, board_error) Result.t
(** Existing snapshot writer. The caller owns persistence, source admission,
    snapshot selection and retry settlement. *)
