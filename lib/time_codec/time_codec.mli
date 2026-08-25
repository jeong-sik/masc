(** Canonical RFC 3339 timestamp boundary — both directions.

    Production adapters consume Unix seconds, while syntax and civil-time
    validation remain owned by Ptime. Callers must opt in explicitly to
    Ptime's non-strict ISO-8601 compatibility mode.

    #26561 converged the readers here and left the writers alone, so the
    same format string was hand-written at eight sites. {!rfc3339_of_unix}
    is the one implementation those sites now call. *)

type parse_error = Invalid_rfc3339

val rfc3339_of_unix_ms : float -> string
(** Same shape as {!rfc3339_of_unix} with millisecond precision. Callers that
    need sub-second timestamps used to spell this out themselves. *)

val rfc3339_of_unix : float -> string
(** [rfc3339_of_unix seconds] renders UTC Unix seconds as
    ["YYYY-MM-DDTHH:MM:SSZ"]. Whole seconds only — a fractional part is
    dropped, not rounded.

    This signature claims totality it does not have. Three input classes
    behave badly and did so identically at all eight former copies; #27131
    owns the decision about changing the type:

    - [nan] is bad in a platform-dependent way: Darwin's [gmtime] accepts it
      and yields the epoch, so it becomes indistinguishable from a genuine
      1970 timestamp, while glibc raises [EOVERFLOW]
    - past year 9999 it emits a five-digit year that {!parse_rfc3339}
      rejects, so the value cannot be read back
    - past roughly [1e18] the platform's [gmtime] gives up; on Darwin and
      Linux that surfaces as [Unix.Unix_error (EOVERFLOW, "gmtime", _)]

    Everything inside those bounds round-trips through
    [parse_rfc3339 ~strict:true], including negative (pre-1970) input. *)

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
