(** Secret_patterns — structural secret masking shared by every sink.

    Pattern-based replacement of secret-shaped values with [\[REDACTED\]].
    This is masking only: patterns never classify, route, or gate behavior.
    Extracted from [Observability_redact] (which delegates here) so leaf
    sinks such as [masc_log] can mask without a dependency cycle. Exact
    secret *values* loaded from keeper secret roots are handled separately
    by [Keeper_secret_redaction]. *)

val redact_text : string -> string
(** Replace known secret-shaped substrings (a URL's [user:password@], the
    value of sensitive HTTP headers such as Authorization / X-Api-Key / Cookie,
    [sk-]/[sk_live_]/[AKIA]/[ASIA] keys, GitHub/Slack tokens, PEM private-key
    blocks) with [\[REDACTED\]]. Never truncates or trims.
    A value of no known shape is not found here: an exact value is masked
    where it is registered ([Keeper_secret_redaction]). *)

val redact_structural_values : ?replacement:string -> string -> string
(** Replace structural secret values only (PEM private-key blocks, URL
    userinfo, and word-bounded API/token prefixes) using [replacement]
    (default ["[REDACTED]"]), without rewriting HTTP header lines. Useful for
    callers that format header/Bearer contexts themselves. *)

val has_secret_token_shape : string -> bool
(** [true] when the string contains a PEM private-key block, URL userinfo
    credential, or a word-bounded structural secret token prefix. *)

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

val redact_json_with : on_string:(string -> string) -> Yojson.Safe.t -> Yojson.Safe.t
(** The structural pass behind {!redact_json_strings}; the caller supplies the
    rewrite of string values. Object keys go through {!redact_text}. The value
    of a sensitive key (judged on the key as it came) becomes [\[REDACTED\]].
    [on_string] sees only the string values outside a sensitive key. Structure,
    member order and non-string scalars are preserved; two keys that redact to
    the same text are both kept, in order. *)

val redact_json_strings : Yojson.Safe.t -> Yojson.Safe.t
(** {!redact_json_with} with {!redact_text} as the string rewrite, so string
    values are redacted without truncation. *)
