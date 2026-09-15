(** Exact identity of one canonical Keeper checkpoint payload. *)
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

val create
  :  trace_id:Keeper_id.Trace_id.t
  -> turn_count:int
  -> canonical_checkpoint_bytes:string
  -> (t, create_error) result
(** Hashes the supplied canonical bytes exactly; no JSON decode or re-encoding
    occurs at this identity boundary. *)

val of_persisted
  :  trace_id:Keeper_id.Trace_id.t
  -> turn_count:int
  -> sha256:string
  -> (t, create_error) result
(** Restores an identity from its canonical lowercase SHA-256 projection.
    Non-canonical or malformed digests are rejected. *)

val equal : t -> t -> bool
