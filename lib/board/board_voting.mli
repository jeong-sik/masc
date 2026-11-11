(** Voting and vote-log effects for one canonical Board store.

    Cast operations hold persistence across staging, the durable append and
    fresh state publication. A snapshot cannot overwrite an appended vote
    before that vote enters the committed ledger. State locks remain separate
    from append IO; the fresh publication preserves other state-only edits.
    Vote appends and rewrites compare the exact loaded vote source. Known file
    success is acknowledged only after normal model publication. Refusal and
    uncertainty grant no mutation authority; unknown effects and interrupted
    publication require a fresh store. Canonical parent snapshots and the original reader remain guarded through
    append; a duplicate uses read-only parent/vote guards before returning.
    No closed-thread or posting-policy restriction is added. *)

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
    returns [Post_not_found]. An unavailable vote source is refused before
    consulting cached targets or vote identities. *)
val vote :
  store -> reader:Board_access.reader -> voter:string -> post_id:string -> direction:vote_direction ->
  (int, board_error) Result.t
val current_vote_for_comment :
  store -> voter:string -> comment_id:string ->
  (vote_direction option, board_error) Result.t
(** [None] means no recorded vote for an existing target. A missing target
    returns [Comment_not_found]. The vote-source rule is the same as for posts. *)
val vote_comment :
  store -> reader:Board_access.reader -> voter:string -> comment_id:string -> direction:vote_direction ->
  (int, board_error) Result.t

val vote_log_jsonl : store -> string
(** Render the committed ledger under the caller's state lock, preserving
    stored cast times. Invalid in-memory keys retain their exception. *)

val save_vote_log_jsonl : store -> string -> (unit, board_error) Result.t
(** Exact vote-source snapshot writer. The caller owns persistence, model
    capture/publication and retry selection in this same interval. Known file
    success is acknowledged before reserved cleanup is finished; unknown
    effects remain owned by the source and cannot be replayed. *)
