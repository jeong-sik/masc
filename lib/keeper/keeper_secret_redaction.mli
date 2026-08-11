(** Keeper-scoped secret redaction for chat and connector surfaces.

    This module is MASC-owned. It reads only the Keeper secret projection
    roots and produces redacted copies of text/JSON values before they
    cross storage or external channel boundaries. *)

type t

val empty : t

val snapshot : base_path:string -> keeper_name:string -> t
(** Snapshot exact secret values from the keeper's projected secret root. *)

val snapshot_with_additional_secret_files :
  additional_secret_files:string list -> base_path:string -> keeper_name:string -> t
(** Snapshot exact secret values from the keeper's projected secret root and
    caller-owned structured secret files. For additional files,
    non-empty mapping scalar values are captured as well as complete lines so
    emitting only a scalar cannot bypass redaction. Missing or unreadable
    roots/files are ignored; redaction must never fail a chat turn. *)

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
    secret. When an unbounded structural prefix (URL credential, Bearer token,
    or [sk-] token) reaches a bounded cut, the prefix is replaced immediately
    and the state machine consumes the remaining token until its delimiter;
    an incomplete structural prefix is never emitted as raw text. Call
    [finish] once to redact and emit the remaining suffix. *)

val redact_json : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Redact all string leaves in a JSON value, preserving shape. *)

val redact_json_keys : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Redact string literals that appear as JSON object keys. Values are left
    untouched so this can be composed with {!redact_json} for full key+value
    coverage without duplicating the traversal. *)
