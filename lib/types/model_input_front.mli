(** A request's start in the durable history. Empty transmission is a
    witnessed boundary, distinct from a missing observation. *)
type t =
  | At_atom of string
      (** Opening-message digest of the oldest carried atom. *)
  | After_history of string
      (** No atom was carried. Digest of the last atom of the offered history;
          the next request may start after it while that atom still matches. *)
  | Empty_history
      (** No atom was carried: the offered history itself held no atoms,
          or the response reached the floor (#39013) and carried none of a
          history it made untenable. A floor seed stands at a past-end
          position; [Keeper_carried_front.for_history] drops it. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val validate : transmitted_atoms:int -> total_atoms:int -> t -> (unit, string) result
val permits_empty : t -> bool
