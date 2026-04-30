(** Shared string utility functions. *)

val contains_substring : string -> string -> bool
(** [contains_substring haystack needle] returns [true] if [needle]
    appears anywhere inside [haystack].  Returns [true] when [needle]
    is empty. *)

val contains_substring_ci : string -> string -> bool
(** Case-insensitive version of [contains_substring].
    Returns [false] when [needle] is empty, matching the behavior
    of the original per-module [contains_ci] helpers. *)

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

val escape_xml : string -> string
(** Escape the five XML 1.0 predefined entities: ampersand,
    less-than, greater-than, double-quote, and apostrophe.
    Order is safe for round-trip use: ampersand is replaced first. *)
