(** Cryptographically random identifier helper.

    Wraps [Mirage_crypto_rng.generate] + hex encoding — the same
    5-line pattern that had been copy-pasted across 6 call-sites
    (verification, board post/comment, autoresearch finding, coord
    task, streamable HTTP session, ...). Centralising removes the
    drift risk and lets lower-layer libraries (e.g. [masc_coord])
    use the same generator without depending on [masc_mcp].

    @since 0.9.5 *)

(** [hex ~bytes:n] returns [2 * n] hex characters sourced from
    [Mirage_crypto_rng.generate n]. Call-sites that need a prefix
    concatenate it themselves — keeping this helper prefix-agnostic
    means the "what kind of id" decision stays at the call-site,
    not here. *)
val hex : bytes:int -> string

(** [prefixed ~prefix ~bytes:n] is [prefix ^ hex ~bytes:n].
    Convenience for the common ["kind-" ^ hex] shape. *)
val prefixed : prefix:string -> bytes:int -> string
