(** Artifact_id — UUID v7 (time-ordered) opaque identifier.

    UUID v7 (RFC 9562 §5.7) places a 48-bit Unix-epoch-millisecond
    timestamp in the high bits, ensuring monotonic sort by creation time.
    This makes UUID v7 friendly to B-tree indexing and natural-order
    timeline rendering (Multimodal Workspace.timeline).

    The internal representation is the canonical 36-character lowercase
    string form (e.g. [01890e2a-4c8e-7b21-9f3c-...]). Construction is
    restricted to {!generate} and {!of_string}, which validates structure
    and version.

    @stability Evolving
    @since 0.18.9 *)

type t = private string
(** Private string. The only constructors are {!generate} and {!of_string}. *)

val generate : unit -> t
(** Generate a fresh UUID v7. Side-effecting: reads current wall-clock
    time and the OCaml [Random] state. The first call seeds [Random]
    via [Random.self_init] if not already seeded by the caller. *)

val of_string : string -> (t, string) result
(** Parse a 36-character UUID string. Validates dashes at positions
    8/13/18/23, version digit (must be ['7']), and variant nibble
    (must be one of [{8,9,a,b}]). Returns [Error] for malformed input. *)

val to_string : t -> string

val compare : t -> t -> int

val equal : t -> t -> bool

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
