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

val redact_pieces_with_lookbehind :
  prev_ended_word:bool -> source_piece list -> source_piece list
(** Like {!redact_pieces}, preserving whether the immediately preceding emitted
    output byte was a word character so [Re.bow] at byte 0 does not fire inside
    a word split across incremental stream releases (e.g. ["ta"] + ["sk-1234"]). *)

val is_word_char : char -> bool
(** Whether [Re.bow]/[Re.eow] classifies this byte as a word character. *)

val has_unclosed_pem_block : string -> bool
(** [true] when the string has a complete PEM private-key [BEGIN] header with no
    following matching [END] footer. *)

val find_pem_footer_end : string -> int option
(** Exclusive end byte offset of the first complete PEM private-key [END] footer
    in the string, or [None] when absent. *)

val safe_stream_prefix_len : prev_ended_word:bool -> string -> int
(** Largest byte offset [k] ([0 <= k <= String.length s]) such that no
    structural secret pattern starting at any byte [< k] can be completed or
    extended by future bytes appended after [s], given whether the immediately
    preceding emitted output byte was a word character. *)

type stream_owner =
  | Sk_token_body  (** [sk-] and Slack token bodies: alnum and [-] *)
  | Stripe_token_body  (** Stripe key bodies: alnum and [_] *)
  | Dotted_token_body  (** GitHub and MASC credential bodies: alnum, [_], [-], [.] *)
  | Url_userinfo  (** a URL credential's userinfo, up to its last [@] *)
  | Header_value  (** a sensitive header's value, up to the line end *)
(** The unbounded body a structural pattern continues with. A stream that has
    released the start of such a pattern as [[REDACTED]] uses it to keep the
    rest of the body masked. *)

val stream_owner_continues : stream_owner -> char -> bool
(** Whether the byte can continue a body of this owner. *)

type stream_hold = { start : int; owner : stream_owner option }

val first_stream_hold : prev_ended_word:bool -> string -> stream_hold option
(** The first byte offset at which a non-PEM structural pattern starts that
    bytes appended after the string could still complete or extend, and the
    unbounded body it continues with ([None] for the fixed-length AWS keys).
    PEM blocks are not reported here. *)

val cut_before_straddling_match : prev_ended_word:bool -> string -> int -> int
(** Tighten [cut] ([0 <= cut <= String.length s]) when [cut < String.length s]
    so no structural match in [s] straddles [cut] and no [Re.eow]-anchored
    pattern ([AKIA]/[ASIA]) ends ambiguously right at [cut]. *)

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
