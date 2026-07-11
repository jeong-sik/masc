(** Shared string utility functions. *)

val contains_substring : string -> string -> bool
(** [contains_substring haystack needle] returns [true] if [needle]
    appears anywhere inside [haystack].  Returns [true] when [needle]
    is empty. *)

val contains_substring_ci : string -> string -> bool
(** Case-insensitive version of [contains_substring].
    Returns [false] when [needle] is empty, matching the behavior
    of the original per-module [contains_ci] helpers. *)

val string_contains_substring : needle:string -> string -> bool
(** Labeled-arg wrapper around [contains_substring].
    [string_contains_substring ~needle haystack] is equivalent to
    [contains_substring haystack needle]. *)

val string_contains_substring_ci : needle:string -> string -> bool
(** Labeled-arg wrapper around [contains_substring_ci].
    [string_contains_substring_ci ~needle haystack] is equivalent to
    [contains_substring_ci haystack needle]. *)

val query_tokens : string -> string list
(** [query_tokens query] splits a free-text query on ASCII whitespace
    (space, tab, CR, LF) into non-empty tokens. UTF-8 bytes pass
    through opaquely. *)

val ascii_punctuation_tokens : string -> string list
(** [ascii_punctuation_tokens text] splits on ASCII punctuation and whitespace,
    lowercases ASCII token bytes, and keeps UTF-8 bytes inside tokens. It is the
    shared tokenizer for anti-rationalization-style contract-token matching,
    where punctuation is a token boundary. *)

val contains_contiguous_token_sequence
  :  haystack:string list
  -> needle:string list
  -> bool
(** [contains_contiguous_token_sequence ~haystack ~needle] is true when [needle]
    appears as a contiguous token sequence inside [haystack]. Empty [needle]
    returns [false]. *)

val contains_all_tokens_ci : string -> string -> bool
(** [contains_all_tokens_ci haystack query] — token-AND containment:
    every token of [query_tokens query] appears in [haystack] as a
    case-insensitive substring, in any order. A query with no tokens
    yields [false], matching [contains_substring_ci]'s empty-needle
    behavior. *)

val count_matched_tokens_ci : string -> string -> int
(** [count_matched_tokens_ci haystack query] — how many tokens of [query]
    appear in [haystack] as case-insensitive substrings. 0 for an empty
    query. Used for partial-match scoring (token-AND was too strict for
    natural-language queries). *)

val matched_token_ratio_ci : string -> string -> float
(** [matched_token_ratio_ci haystack query] — [count_matched_tokens_ci]
    divided by the total token count, in [0.0, 1.0]. 0.0 for an empty query. *)

val starts_with_ci : prefix:string -> string -> bool
(** [starts_with_ci ~prefix s] is the ASCII case-insensitive variant of
    [String.starts_with]. Performs no allocation; lowercases each byte
    of [prefix] and [s] inline during the compare. Returns [true] when
    [prefix] is empty. *)

val equals_ci : string -> string -> bool
(** [equals_ci a b] is the ASCII case-insensitive equality. Performs
    no allocation; equivalent to [String.lowercase_ascii a =
    String.lowercase_ascii b] but short-circuits on length mismatch and
    first differing byte. Hot for HTTP header / case-insensitive flag
    lookup. *)

val find_substring : ?pos:int -> string -> string -> int option
(** [find_substring ?pos haystack needle] returns the byte index of the
    first occurrence of [needle] in [haystack] at or after [pos]
    (default 0), or [None] if absent. Empty needle returns [Some pos],
    matching [Re.exec_opt (Re.str "" |> Re.compile)] semantics. Raises
    [Invalid_argument] when [pos] is negative. *)

val replace_substring : needle:string -> by:string -> string -> string
(** [replace_substring ~needle ~by haystack] substitutes [by] for every
    non-overlapping occurrence of [needle] in [haystack]. Returns
    [haystack] unchanged when [needle] is empty or longer than the
    haystack. Matches [Re.replace_string (Re.str needle |> Re.compile)]
    semantics for ASCII / byte-equal patterns. *)

type truncation =
  | Untouched of string
  | Truncated of { prefix : string; suffix : string; dropped_bytes : int }
(** Result of a UTF-8-aware truncation attempt.
    - [Untouched s]: input fit within the byte budget; [s] returned as-is.
    - [Truncated \{prefix; suffix; dropped_bytes\}]: input exceeded budget.
      [prefix] ends at a UTF-8 character boundary, [suffix] is the
      caller-supplied ellipsis/marker, [dropped_bytes] counts how much
      of the original was removed (useful for observability/metrics). *)

val utf8_char_boundary : string -> int -> int
(** [utf8_char_boundary s idx]: returns the largest [k <= idx] such that
    [String.sub s 0 k] ends at a valid UTF-8 character boundary.
    Exposed for callers that want boundary-only behavior without the
    [truncation] variant wrapper. Invalid UTF-8 uses best-effort:
    complete ASCII bytes are preserved, incomplete leads are excluded. *)

val utf8_safe : max_bytes:int -> suffix:string -> string -> truncation
(** [utf8_safe ~max_bytes ~suffix s]: if [s] fits within [max_bytes],
    returns [Untouched s]. Otherwise returns [Truncated \{...\}] where
    [prefix] is at most [max_bytes - String.length suffix] bytes and
    ends at a UTF-8 character boundary. Invalid UTF-8 in [s] triggers
    best-effort boundary detection. *)

val to_string : truncation -> string
(** Materialize a [truncation] as a single string.
    For [Untouched s] returns [s]; for [Truncated \{prefix; suffix; _\}]
    returns [prefix ^ suffix]. Use when the metadata isn't needed. *)

val was_truncated : truncation -> bool
(** [true] iff the argument is the [Truncated] constructor. *)

val utf8_prefix : max_bytes:int -> string -> string
(** [utf8_prefix ~max_bytes s]: returns at most [max_bytes] bytes of [s],
    cutting at a UTF-8 character boundary. Returns [""] when
    [max_bytes <= 0]. Lighter than {!utf8_safe} when the caller does not
    need the [truncation] metadata or suffix. *)

val trim_nonempty : string -> string option
(** [trim_nonempty s] trims whitespace and returns [Some s] if non-empty,
    [None] otherwise. SSOT for the per-module [trim_nonempty] helpers. *)

val normalize_mention_target : string -> string option
(** [normalize_mention_target target] trims whitespace, strips any leading
    ['@'] characters, and lowercases the result for case-insensitive
    matching. [None] when the target normalizes to empty. SSOT for
    normalizing keeper board-mention targets at both write time
    ([Keeper_turn_up_args.resolve_mention_targets]) and read time
    ([Keeper_world_observation_board_signal.match_signal]) so a target
    stored pre-prefixed with ['@'] cannot desync from the '@'-free names
    the board-signal matcher extracts from post text. *)

val trim_to_option : string -> string option
(** [trim_to_option s] is an alias for [trim_nonempty]. Both are identical;
    [trim_to_option] is kept for migration compatibility. *)

val option_trim : string option -> string option
(** [option_trim opt] maps [trim_nonempty] over an option.
    [None] stays [None]; [Some s] becomes [None] if all whitespace. *)

val compact_text : ?max_len:int -> string -> string
(** [compact_text ~max_len raw] normalizes [raw]: trims, joins lines,
    filters empty lines, then truncates to [max_len] characters (UTF-8 safe).
    Default [max_len] is 160. Returns [""] for empty/whitespace-only input. *)

val strip_trailing_cr : string -> string
(** [strip_trailing_cr s] removes a trailing ['\\r'] character if present. *)
val escape_xml : string -> string
(** Escape the five XML 1.0 predefined entities: ampersand,
    less-than, greater-than, double-quote, and apostrophe.
    Order is safe for round-trip use: ampersand is replaced first. *)
