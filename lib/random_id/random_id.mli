(** Cryptographically random identifier helper.

    Wraps the process-wide [Crypto_rng] boundary + hex encoding — the same
    5-line pattern that had been copy-pasted across 6 call-sites
    (verification, board post/comment, workspace
    task, streamable HTTP session, ...). Centralising removes the
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
