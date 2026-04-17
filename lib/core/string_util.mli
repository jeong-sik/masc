(** Shared string utility functions. *)

val contains_substring : string -> string -> bool
(** [contains_substring haystack needle] returns [true] if [needle]
    appears anywhere inside [haystack].  Returns [true] when [needle]
    is empty. *)

val contains_substring_ci : string -> string -> bool
(** Case-insensitive version of [contains_substring].
    Returns [false] when [needle] is empty, matching the behavior
    of the original per-module [contains_ci] helpers. *)

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
