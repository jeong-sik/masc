(** Named input-capacity refusals from an executed Librarian provider request.
    A slot's local admission check or a measured CLI limit is not such a
    refusal. These observations alone never authorize consuming a source. *)
type t = Context_overflow | Input_capacity | Request_body_refused

val to_string : t -> string
val of_string : string -> t option
(** Exact wire tokens only; unknown causes never become size evidence. *)
val union : t list -> t list -> t list
(** Distinct causes in canonical constructor order, independent of slot order. *)
