(** Durable metadata from the native provider POST boundary during one owned
    explicit cycle. No request/response bodies, URLs or credentials are saved. *)
type t
val create : path:string -> now:(unit -> Yojson.Safe.t) -> t
val within : t -> (unit -> 'a) -> 'a
val snapshot : t -> Yojson.Safe.t
(** Counts are unknown when callback delivery failed or a call's actual
    entered/dispatch/header/return facts are incomplete or contradictory.
    First-dispatch Tool metadata comes from that exact client's body-bound
    serializer observation. An absent/unavailable producer is not an empty
    inventory, and a later request never replaces the first dispatch. *)
