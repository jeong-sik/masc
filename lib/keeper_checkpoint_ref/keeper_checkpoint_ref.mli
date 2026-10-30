(** Exact identity of one Keeper checkpoint: its trace, its turn and its
    content digest (RFC-0476 §3.2), which a value and every head written for it
    share. The Keeper checkpoint store computes the digest. *)
type t = private
  { trace_id : Keeper_id.Trace_id.t
  ; turn_count : int
  ; sha256 : string
  }

type create_error =
  | Negative_turn_count of int
  | Invalid_sha256 of string

val sha256_of_canonical_bytes : string -> string
(** Lowercase hex SHA-256 of the bytes, fed to the digest one bounded slice at
    a time so the hashing domain reaches OCaml poll points between slices and
    never holds another domain's stop-the-world barrier for a whole
    checkpoint. Equal to the one-shot digest of the same bytes. *)

val of_persisted
  :  trace_id:Keeper_id.Trace_id.t
  -> turn_count:int
  -> sha256:string
  -> (t, create_error) result
(** Builds an identity from a lowercase SHA-256. Non-canonical or malformed
    digests are rejected. *)

val equal : t -> t -> bool
