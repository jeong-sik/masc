(** Secret_patterns — structural secret masking shared by every sink.

    Pattern-based replacement of secret-shaped values with [\[REDACTED\]].
    This is masking only: patterns never classify, route, or gate behavior.
    Extracted from [Observability_redact] (which delegates here) so leaf
    sinks such as [masc_log] can mask without a dependency cycle. Exact
    secret *values* loaded from keeper secret roots are handled separately
    by [Keeper_secret_redaction]. *)

val redact_text : string -> string
(** Replace known secret-shaped substrings (URL credentials, [Bearer]
    values, HTTP Authorization fields, sensitive-key assignments, [sk-]/[AKIA]
    keys, GitHub tokens, PEM private-key blocks)
    with [\[REDACTED\]]. Never truncates or trims. *)

type source_span = { first_byte : int; past_byte : int }
(** Half-open byte coordinates in the original input, before any replacement. *)

type source_piece =
  | Copied of { source : source_span; text : string }
  | Masked of { source : source_span; replacement : string }
(** [Copied] preserves its source bytes exactly. [Masked] is an actual
    replacement, not a guess based on its rendered spelling. Its replacement
    belongs to the first covered source byte; later covered bytes produce no
    additional text. Pieces are ordered and cover their consumed source range
    without gaps or overlaps. Literal [[REDACTED]] remains [Copied]. *)

val render_pieces : source_piece list -> string
val redact_text_mapped : string -> source_piece list
(** The same ordered masking policy as {!redact_text}, retaining actual match
    provenance through all replacement passes. Coordinates start at zero. *)

val redact_pieces : source_piece list -> source_piece list
(** Apply structural masking to already mapped text, composing match offsets
    with its original source intervals. Used after Keeper exact-value masking. *)

val mask_matches : Re.re -> source_piece list -> source_piece list
(** Replace nonempty matches with [[REDACTED]], preserving mapped provenance.
    This shares the replacement engine with structural masking; Keeper exact
    values supply their existing compiled patterns in the existing order. *)

val is_sensitive_key : string -> bool
(** Case-insensitive exact match against the sensitive JSON key list
    (token, api_key, password, secret_key, access_key, ...). A key that
    matches here has its whole value masked, whatever the value's shape. *)

val key_suggests_secret : string -> bool
(** Case-insensitive fragment match: [true] when the key name contains a
    secret-bearing fragment (secret, token, passwd, credential, apikey,
    ...). A fallback for spellings the exact list never enumerated
    ([session_token], [api_secret], ...). Reference-shaped keys
    ([*_env] naming an environment variable, [*_type] naming a value
    kind, the runtime inventory's [credential_kind]/[credential_file], and
    the collision event's exact [token_hash_prefix] correlation field)
    answer [false] so safe metadata stays readable. Callers mask
    every string value and object member name in the subtree under such a
    key while non-string
    scalars keep their shape, so counts and flags survive while no
    secret-shaped string passes in clear. *)

val redact_json_strings : Yojson.Safe.t -> Yojson.Safe.t
(** Recursively apply {!redact_text} to string leaves and to object keys,
    and replace the value of a sensitive key (judged on the key as it came)
    with [\[REDACTED\]], preserving structure and without truncation. Two
    keys that redact to the same text are both kept, in order. *)
