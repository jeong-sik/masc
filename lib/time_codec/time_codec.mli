(** Canonical RFC 3339 timestamp parsing boundary.

    Production adapters consume Unix seconds, while syntax and civil-time
    validation remain owned by Ptime. Callers must opt in explicitly to
    Ptime's non-strict ISO-8601 compatibility mode. *)

type parse_error = Invalid_rfc3339

val parse_rfc3339 : ?strict:bool -> string -> (float, parse_error) result
(** [parse_rfc3339 ~strict value] parses [value] onto the UTC timeline and
    returns Unix seconds. [strict] defaults to [true]. When [strict=false],
    Ptime additionally accepts its documented ISO-8601 compatibility forms,
    including compact numeric offsets such as [+0900]. *)

val parse_rfc3339_whole_seconds :
  ?strict:bool -> string -> (float, parse_error) result
(** Parses with the same contract as {!parse_rfc3339}, but truncates fractional
    seconds in Ptime's exact timestamp domain before converting to [float].
    This prevents float rounding from advancing a value just below a whole
    second into the next second. *)

val parse_rfc3339_opt : ?strict:bool -> string -> float option
(** Option projection of {!parse_rfc3339} for existing optional timestamp
    fields. Invalid input is [None]; no default timestamp is invented. *)
