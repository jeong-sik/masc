open Board_types

val capture : store -> author_id:Agent_id.t -> hearth:string option ->
  (sub_boards_source_observation option, board_error) result
(** Pure, while the caller owns persistence and state. Decode the exact
    authoritative policy snapshot in physical row order and check this author.
    [None] means only an unscoped post/comment; an unregistered slug still
    retains the policy snapshot proving its absence. The caller must guard the
    returned snapshot through the actual append. No model publication occurs. *)
