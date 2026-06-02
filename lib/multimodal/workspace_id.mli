(** Workspace_id — opaque identifier for a multimodal workspace.

    Cycle 25 / Tier B10.

    {1 What this is}

    A {!Workspace.t} (introduced in a follow-up cycle) is a project-level
    container holding a collection of {!Artifact.t} values plus a
    timeline / provenance graph. Each workspace has a stable
    identifier separate from the artifact ids it contains.

    The internal representation is a 36-character lowercase UUID v7
    string (RFC 9562 §5.7) — same time-ordered shape as
    {!Shared_types.Artifact_id.t}, so timeline rendering across
    workspaces and artifacts shares one sort order.

    {1 Construction}

    Direct construction is not exposed. Callers obtain a value via:
    - {!generate} for a freshly-minted workspace, or
    - {!of_string} for parsing inbound strings (DB rows, JSON, CLI
      args). Validation rejects empty strings, strings longer than
      64 characters, and non-UUID-v7 shapes.

    The 64-character upper bound is a defensive ceiling. UUID v7 is
    36 chars; the extra headroom accommodates future migration to a
    longer ID (e.g. ULID Crockford base32 = 26 chars, or a prefixed
    form like ["ws_<uuid>"]) without breaking the validator
    contract.

    {1 Comparison and hashing}

    {!compare} and {!equal} delegate to the underlying string. Two
    {!t} values produced by independent {!generate} calls are
    statistically guaranteed to differ (122-bit randomness in the
    UUID v7 tail).

    @stability Evolving
    @since 0.18.11 *)

type t = private string
(** Private string. The only constructors are {!generate} and {!of_string}. *)

val generate : unit -> t
(** Generate a fresh workspace id (UUID v7). Side-effecting: reads
    the current wall-clock time and the OCaml [Random] state. *)

val of_string : string -> (t, string) result
(** Parse and validate a workspace id string.

    Validation:
    - non-empty (rejects [""]),
    - length ≤ 64 (defensive ceiling, see module preamble),
    - structurally a UUID v7 — dashes at positions 8/13/18/23,
      version digit ['7'] at index 14, variant nibble in
      [\{8,9,a,b\}] at index 19, hex elsewhere.

    The output is normalised to lowercase. *)

val to_string : t -> string
(** Canonical lowercase 36-character form. *)

val compare : t -> t -> int
val equal : t -> t -> bool

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
