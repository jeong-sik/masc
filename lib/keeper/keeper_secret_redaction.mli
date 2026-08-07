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

(* Chunk-streaming redaction ([create_stream_state] / [redact_stream_chunk] /
   [redact_stream_finish]) was removed. It held raw bytes until the next
   ['\n'] and re-copied plus re-scanned the whole held buffer on every 4KB
   chunk, so a stream with newlines far apart cost O(n^2): one 590MB
   subprocess capture over single-line JSON moved ~3.1TB and held a keeper's
   turn slot for 115 minutes, which stalled that keeper's event queue.

   No comparable harness redacts at this layer — claude-code, Codex,
   OpenHands, SWE-agent and Hermes have no built-in tool-output redaction,
   and the third-party Claude Code redactors run as PostToolUse hooks over
   an already-bounded result. The model- and storage-facing paths here keep
   their redaction: [Keeper_tool_execute_runtime] applies {!redact_text} to
   the final stdout/stderr, so removing the streaming pass leaves only the
   dashboard's live view unredacted until the command finishes. *)

val redact_json : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Redact all string leaves in a JSON value, preserving shape. *)

val redact_json_keys : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Redact string literals that appear as JSON object keys. Values are left
    untouched so this can be composed with {!redact_json} for full key+value
    coverage without duplicating the traversal. *)
