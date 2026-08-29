(** Keeper-scoped secret redaction for chat and connector surfaces.

    This module is MASC-owned. It reads only the Keeper secret projection
    roots and produces redacted copies of text/JSON values before they
    cross storage or external channel boundaries. *)

type t

val empty : t

val ssh_remote_token_file : base_path:string -> keeper_name:string -> string
(** Host-side 0600 registration file for a remote keeper's GitHub token.
    The SSH bootstrap owns writes; snapshots read it only for exact-value
    redaction and never project it into a local or Docker execution env. *)

val snapshot : base_path:string -> keeper_name:string -> t
(** Snapshot exact secret values from the keeper's projected secret root. *)

val snapshot_with_additional_secret_files :
  redact_identity_scalars:bool ->
  additional_secret_files:string list ->
  base_path:string ->
  keeper_name:string ->
  t
(** Snapshot exact secret values from the keeper's projected secret root and
    caller-owned structured secret files. For additional files,
    non-empty mapping scalar values are captured as well as complete lines so
    emitting only a scalar cannot bypass redaction. Credential-shaped keys
    (token/secret/password/credential/passphrase) always mine their scalar;
    identity keys (a [user:] login) mine only when
    [~redact_identity_scalars:true] — a GitHub account name is public in
    every repo URL, so an operator may turn that layer off without
    unmasking tokens. Missing or unreadable roots/files are ignored;
    redaction must never fail a chat turn. *)

val redact_text : t -> string -> string
(** Replace exact projected secret values and generic sensitive patterns
    with [\[REDACTED\]], preserving message length semantics except for
    the replacements themselves. *)

type stream_state

val create_stream_state : t -> stream_state
val redact_stream_chunk : stream_state -> string -> string
val redact_stream_finish : stream_state -> string
(** Boundary-safe streaming redaction. Newline and carriage-return records are
    emitted immediately. Long unterminated records are emitted in bounded
    chunks while retaining a suffix large enough for every snapshotted exact
    secret (and a bounded structural-pattern overlap), so process progress does
    not require buffering an unbounded line. Call [finish] once to redact and
    emit the remaining suffix. *)

val redact_json : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Redact a JSON value's object keys as well as its string leaves, preserving
    shape. A secret can be the key -- a header name, or a parameter a tool used
    as a dict key -- so a leaves-only traversal emits it (#22941). *)
