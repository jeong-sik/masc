(** Publication evidence owned by the operation that attempted the write.
    A staged ID alone is never exposed as a committed receipt. *)

type cause = Board_error of Board_types.board_error | Raised of exn
type t

val before_effect : cause -> t
val unknown : cause -> t
val after_commit : Board_types.post_creation -> cause -> t

val with_cause : t -> cause -> t
(** Replace the reported cause while preserving the producer's publication
    evidence and exact committed receipt. *)
val cause : t -> cause
val effect_disposition : t -> Failure_effect.t
val committed : t -> Board_types.post_creation option
(** [Some] exists only for a proven committed creation. *)
val to_string : t -> string
