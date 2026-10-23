(** Immutable host observer intents. Payload interpretation and fresh matching
    against the actual registry belong to the original domain owner. *)
type receipt = private {
  observed_at : float;
  payload : Yojson.Safe.t;
  digest : string;
}
val make : observed_at:float -> payload:Yojson.Safe.t -> (receipt, string) result
(** Canonical object payload and finite nonnegative first observer wall time.
    This time is not an inferred model start or measured provider duration. *)
val to_json : receipt -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (receipt, string) result
(** Exact fields and a digest recomputed from the entire time/payload pair. *)
type stage = Registration | Completion
type event = Intended of stage * receipt | Recorded of stage * string
type publication = Unobserved | Pending of receipt | Acknowledged of receipt
type t = private { registration : publication; completion : publication }
val empty : t
val append : t -> event -> (t, string) result
(** Retain each immutable intent once, then acknowledge only its exact digest.
    An [Intended] event reuses the opaque receipt already validated by [make]
    or [of_json]; it does not serialize and hash that receipt again.
    Completion may be retained while registration is pending, but cannot be
    acknowledged until registration is acknowledged. Duplicate/changed intents,
    unknown acknowledgements and out-of-order facts are refused. No I/O occurs;
    an ACK is a trusted host fact, not evidence manufactured by this module.
    Neither intent nor ACK permits any model, worker or domain effect. *)
val event_to_json : event -> Yojson.Safe.t
val event_of_json : Yojson.Safe.t -> (event, string) result
