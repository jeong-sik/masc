(** Keeper-scoped secret redaction for chat and connector surfaces.

    This module is MASC-owned. It reads only the Keeper secret projection
    roots and produces redacted copies of text/JSON values before they
    cross storage or external channel boundaries. *)

type t

val empty : t

val copy_for_current_domain : t -> t
(** Recompile the captured exact values on the calling domain. No secret files
    are reread and no mutable compiled pattern is shared with the source. *)

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
    redaction must never fail a chat turn.

    Every call stats the source files; the values are read and compiled
    again only when a file's identity, size or mtime differs from the
    snapshot memoised on the calling domain for the same arguments. *)

val redact_text : t -> string -> string
(** Replace exact projected secret values and generic sensitive patterns
    with [\[REDACTED\]], preserving message length semantics except for
    the replacements themselves. *)

val redact_text_mapped : t -> string -> Secret_patterns.source_piece list
(** Same policy as {!redact_text}, with half-open original input byte spans.
    No output-text comparison is used to recover replacement positions. *)

type stream_state

val create_stream_state : t -> stream_state

type stream_release =
  { pieces : Secret_patterns.source_piece list
  ; consumed : int
  }
(** [consumed] is the absolute, exclusive safe-consumed source byte watermark
    since this stream state was created, not the rendered output length.
    [pieces] cover exactly the newly consumed range, in those same absolute
    coordinates. An empty release leaves the watermark unchanged. A replacement
    crossing input chunks is one [Masked] span; consumers place it only at its
    first source-byte owner. [Copied] spans may cross input chunk boundaries,
    including a boundary inside a UTF-8 code point. Do not split their output
    into invalid UTF-8 when assigning it back to source chunks. *)

val redact_stream_chunk_mapped : stream_state -> string -> stream_release
val redact_stream_finish_mapped : stream_state -> stream_release
(** Mapped forms of the string APIs below. A bounded release uses the actual
    consumed cursor, which can extend past the nominal cut to cover an entire
    exact secret. Repeated finish calls return no pieces and the same cursor. *)

val redact_stream_chunk : stream_state -> string -> string
val redact_stream_finish : stream_state -> string
(** Boundary-safe streaming redaction. Newline and carriage-return records are
    emitted immediately. Long unterminated records are emitted in bounded
    chunks, each ending on a UTF-8 character boundary when the record is
    UTF-8, while retaining a suffix large enough for every snapshotted exact
    secret (and a bounded structural-pattern overlap), so process progress does
    not require buffering an unbounded line. Call [finish] once to redact and
    emit the remaining suffix. *)

val redact_json : t -> Yojson.Safe.t -> Yojson.Safe.t
(** Redact a JSON value's object keys as well as its string leaves, preserving
    shape. A secret can be the key -- a header name, or a parameter a tool used
    as a dict key -- so a leaves-only traversal emits it (#22941). *)

module For_testing : sig
  val shares_compiled_patterns : t -> t -> bool
  (** Physical equality of the two snapshots' compiled pattern lists: true
      when the second call served the first call's memoised snapshot. *)
end
