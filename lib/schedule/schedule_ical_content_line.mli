(** Schedule_ical_content_line — RFC 5545 §3.1 content lines.

    The lexical layer under every iCalendar property parser: unfolding and
    the [name *( ";" param ) ":" value] split. Pure and total: any input
    string yields a typed result, never an exception. Property-specific value
    decoding (DATE-TIME, RECUR, ...) lives in the property layers above
    ({!Schedule_ical_recur} and later leaves).

    Exactness stance, matching {!Schedule_ical_recur}:
    - Line delimiters are CRLF; a bare LF is also accepted (documented
      leniency for non-compliant producers), but a lone CR is a typed error.
    - Folding is exactly §3.1: a CRLF followed by SPACE or HTAB is removed
      with the whitespace character. A continuation without a preceding line
      is a typed error.
    - Property and parameter names are case-insensitive and normalized to
      uppercase; nothing else is normalized. Name characters must satisfy
      [iana-token] / [x-name].
    - [":"] and [";"] inside quoted parameter values do not split. An
      unterminated quoted-string is a typed error.
    - CONTROL characters (except HTAB) are rejected, not sanitized.

    Records are [private]: external code can read and pattern-match but
    cannot construct, so the uppercase-name invariant cannot be forged
    outside {!parse}. *)

type param = private
  { name : string  (** Uppercase-normalized parameter name. *)
  ; values : string list
    (** COMMA-separated parameter values in wire order; surrounding DQUOTEs
        are stripped from quoted-strings. *)
  }

type t = private
  { name : string  (** Uppercase-normalized property name. *)
  ; params : param list
  ; value : string  (** Raw value text; property layers decode it. *)
  }

type parse_error =
  | Lone_carriage_return of { position : int }
  | Orphan_continuation of { line : int }
      (** A folded continuation (leading SPACE/HTAB) with no preceding
          content line. *)
  | Empty_name of { line : int }
  | Invalid_name_char of { line : int; name : string }
  | Missing_colon of { line : int }
  | Invalid_param_name_char of { line : int; name : string }
  | Missing_param_equals of { line : int; param : string }
  | Unterminated_quoted_string of { line : int; param : string }
  | Control_character of { line : int; position : int; code : int }

val parse_error_to_string : parse_error -> string

val unfold : string -> (string list, parse_error) result
(** Split an iCalendar stream into logical content lines: CRLF/LF delimited,
    §3.1 folding rejoined. Empty physical lines carry no content and are
    skipped (this is what makes a trailing newline at end of stream legal).
    [line] numbers in errors are 1-based physical line numbers. *)

val parse : line:int -> string -> (t, parse_error) result
(** Parse one logical content line. [line] is the physical line number the
    logical line started on, used only for error reporting. *)

val parse_many : string -> (t list, parse_error) result
(** [unfold] then [parse] for every logical line, in order. *)

val find_param : name:string -> param list -> param option
(** Case-insensitive lookup helper for property layers. *)
