(** Shared_audit envelope — Merkle-chained immutable audit entry.

    Each entry carries:
    - [id]: ULID-like identifier (timestamp prefix + random hex)
    - [ts]: Unix epoch seconds (UTC)
    - [category]: domain-specific string. CREW uses
      ["DeliberationTransition"]; Resilience uses ["DegradationTriggered"],
      ["RecoveryAttempted"], etc. The shared envelope leaves category
      meaning to each domain.
    - [payload]: arbitrary JSON sub-tree
    - [prev_hash]: SHA256 of previous entry's canonical JSON, or [None]
      for the genesis entry.

    The hash chain ensures tamper detection: any modification to an
    entry breaks the [prev_hash] field of the next entry, surfaced via
    {!Store.verify_chain}.

    {b Canonical JSON} is computed with deterministic field order
    ([id; ts; category; payload; prev_hash]) so that equivalent entries
    hash to the same digest regardless of input order. The shared
    envelope is the unifying storage backend per INTEGRATED §3.2.

    @stability Evolving
    @since 0.18.9 *)

type t = {
  id : string;
  ts : float;
  category : string;
  payload : Yojson.Safe.t;
  prev_hash : string option;
}

val make :
  category:string ->
  payload:Yojson.Safe.t ->
  prev_hash:string option ->
  t
(** Construct a fresh entry. Generates a new [id] and uses the current
    wall-clock time as [ts]. *)

val canonical_json : t -> string
(** Deterministic JSON serialization (canonical field order). This is
    the input to the hash function. *)

val compute_hash : t -> string
(** SHA256 hex-digest of {!canonical_json}. *)

val hash_for_chain : t -> string
(** Hash of this entry, suitable as the [prev_hash] of the next entry.
    Currently identical to {!compute_hash}; named separately to allow
    a future Merkle-tree variant without API breakage. *)

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
