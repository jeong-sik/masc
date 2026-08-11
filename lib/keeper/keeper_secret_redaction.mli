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

val create_stream_state : t -> stream_state
val redact_stream_chunk : stream_state -> string -> string
val redact_stream_finish : stream_state -> string
(** Boundary-safe streaming redaction. Input is accumulated one byte at a
    time only until a newline, then redacted once and emitted. This preserves
    secrets split across process chunks without the old O(n^2) behavior that
    recopied the full pending buffer on every chunk. Call [finish] once to
    redact and emit the final unterminated line. *)

val redact_json : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Redact all string leaves in a JSON value, preserving shape. *)

val redact_json_keys : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Redact string literals that appear as JSON object keys. Values are left
    untouched so this can be composed with {!redact_json} for full key+value
    coverage without duplicating the traversal. *)
