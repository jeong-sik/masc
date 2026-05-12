(** RFC-0070 Phase 3b-ii — Deterministic docker container name.

    Pure derivation: same [(algo, turn_id, attempt, suffix)] ⇒ identical
    {!t}. No wall-clock, no Random, no process state.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.1

    Wire format:
    {v "masc-keeper-" ^ hex(Keeper_hash_algo.digest_bytes algo input)[0..31] v}

    The 32-hex-char (16-byte / 128-bit) slice gives a direct collision
    probability of 1/2^128 and birthday bound ~2^64 — effectively zero
    under any realistic fleet load.

    Docker container-name constraints satisfied:
    - regex [a-zA-Z0-9][a-zA-Z0-9_.-]* (hex chars + "-" prefix segment OK)
    - length <= 64 (this format is 44 chars: 12 prefix + 32 hex) *)

(** Abstract container-name type. The underlying string is the
    serialised wire form. *)
type t

(** [derive ~algo ~turn_id ~attempt ~suffix] derives the
    container name. Pure function of declared inputs.

    [suffix] is the keeper-derived disambiguator (typically the keeper
    name or a config-derived identifier) folded into the hash so two
    keepers running the same [turn_id]/[attempt] still get distinct
    names. The implementation hashes the raw bytes so any string is
    accepted, including the empty string (uncommon but not rejected
    — the caller is expected to pass a meaningful identifier). *)
val derive
  :  algo:Keeper_hash_algo.t
  -> turn_id:int
  -> attempt:int
  -> suffix:string
  -> t

(** [to_string t] returns the wire form, suitable for direct passing
    to [docker run --name <to_string t> ...]. *)
val to_string : t -> string

(** [of_external_string s] wraps an arbitrary [string] as a
    {!t} *without validation*. Intended for parsing output emitted by
    an external source (e.g. [docker ps] [Names] field) where the
    consumer treats the value as opaque and never decomposes the
    format. **Not** suitable for callers that construct names — they
    must use {!derive} so the format invariant is enforced.

    The unchecked wrap is acceptable here because:
    - Phase 3b-iv.2.4 reads docker's container [Names] field and the
      caller (cleanup / quarantine) only round-trips the value back
      into [docker rm <name>] without parsing.
    - Wrapping at the type-system level still segregates "name from
      docker" from "arbitrary string" in caller code. *)
val of_external_string : string -> t

(** [equal] / [pp] for property tests and dashboards. *)
val equal : t -> t -> bool

val pp : Format.formatter -> t -> unit
