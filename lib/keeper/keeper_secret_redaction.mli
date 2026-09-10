(** Keeper-scoped secret redaction for chat and connector surfaces.

    This module is MASC-owned. It reads only the Keeper secret projection
    roots and produces redacted copies of text/JSON values before they
    cross storage or external channel boundaries. *)

type t

val empty : t

val snapshot : base_path:string -> keeper_name:string -> t
(** Snapshot exact secret values from the keeper's projected secret
    root. Missing or unreadable roots produce {!empty}; redaction must
    never fail a chat turn. *)

val redact_text : t -> string -> string
(** Replace exact projected secret values and generic sensitive patterns
    with [\[REDACTED\]], preserving message length semantics except for
    the replacements themselves. *)

type stream_state

val create_stream_state : unit -> stream_state
val redact_stream_chunk : t -> stream_state -> string -> string
val redact_stream_finish : t -> stream_state -> string
(** Incrementally redact complete output lines. Partial lines are retained so
    secrets spanning read boundaries cannot leak. Retention is bounded; an
    oversized unbroken line is replaced with a redaction marker. *)

val redact_json : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Redact all string leaves in a JSON value, preserving shape. *)

val redact_json_keys : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Redact string literals that appear as JSON object keys. Values are left
    untouched so this can be composed with {!redact_json} for full key+value
    coverage without duplicating the traversal. *)
