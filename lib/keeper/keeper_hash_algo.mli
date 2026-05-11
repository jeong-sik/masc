(** RFC-0070 Phase 3b-i — Hash algorithm variant for sandbox plan
    derivation.

    Closed sum of supported hash algorithms. New algorithms are added
    by extending the variant — the compiler enforces exhaustive caller
    updates. No string-keyed indirection, no runtime catch-all.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.1, §8 Q1

    Backend: [digestif] (opam) 1.3.0. BLAKE3 deferred — digestif 1.3.0
    does not ship BLAKE3 (only BLAKE2B/2S of the BLAKE family). Adding
    BLAKE3 requires opam dependency [blake3] or a digestif version
    bump. Tracked in RFC §8 Q1. *)

(** {1 Algorithm variant} *)

type t =
  | SHA_256
  | SHA_512
[@@deriving show, eq]

(** [all] is the canonical enumeration of the variant. Use for
    property tests and config emission; the compiler does not enforce
    completeness of this list — callers that depend on completeness
    should pattern-match the variant instead. *)
val all : t list

(** [to_string] returns a stable lowercase identifier suitable for
    config emission and telemetry labels. *)
val to_string : t -> string

(** [of_string s] parses [s] case-insensitively. Returns [None] on
    unknown input — no permissive default. *)
val of_string : string -> t option

(** {1 Digest API} *)

(** [digest_hex algo s] returns the hexadecimal-encoded digest of [s]
    under [algo]. Determinism contract: same [(algo, s)] ⇒ identical
    output. No process state, no clock, no random. *)
val digest_hex : t -> string -> string

(** [digest_bytes algo s] returns the binary digest of [s] under
    [algo]. Use {!digest_hex} for human-facing identifiers; this
    function is for callers that truncate or re-encode the bytes
    themselves. *)
val digest_bytes : t -> string -> string
