(** Cryptographically random identifier helper.

    Wraps the process-wide [Crypto_rng] boundary + hex encoding — the same
    5-line pattern that had been copy-pasted across 6 call-sites
    (verification, board post/comment, workspace task, and transport
    correlation identifiers). Centralising removes the
    drift risk and lets lower-layer libraries (e.g. [masc_workspace])
    use the same generator without depending on [masc].

    @since 0.9.5 *)

val hex : bytes:int -> string
(** [hex ~bytes:n] returns [2 * n] hex characters sourced from
    [Crypto_rng.generate n]. Call-sites that need a prefix
    concatenate it themselves — keeping this helper prefix-agnostic
    means the "what kind of id" decision stays at the call-site,
    not here. *)

val prefixed : prefix:string -> bytes:int -> string
(** [prefixed ~prefix ~bytes:n] is [prefix ^ hex ~bytes:n].
    Convenience for the common ["kind-" ^ hex] shape. *)

val uuid_v7 : unit -> string
(** [uuid_v7 ()] returns a canonical lowercase UUIDv7. Calls serialized in
    one process are monotonic within the same millisecond. This is an opaque
    correlation identifier, not an authentication secret. *)

val parse_uuid_v7 : string -> (string, string) result
(** [parse_uuid_v7 value] validates the complete canonical UUID shape,
    RFC 9562 variant, and version 7, then returns lowercase canonical text. *)

module For_testing : sig
  val logical_ms_clock : (unit -> int64) -> (unit -> int64) * (unit -> unit)
end
