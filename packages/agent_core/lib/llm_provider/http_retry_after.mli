(** Parse an HTTP [Retry-After] header value (RFC 9110 S10.2.3) into a
    delay in seconds. Accepts either grammar the spec allows:
    - [delay-seconds]: a non-negative integer, returned as-is.
    - [HTTP-date] (IMF-fixdate, e.g. ["Sun, 06 Nov 1994 08:49:37 GMT"]):
      converted to a delay relative to [now] (a Unix timestamp in
      seconds); a date at or before [now] yields [0.0] rather than a
      negative delay.

    Obsolete HTTP-date forms (RFC 850, asctime) and any value that is
    neither a bare non-negative integer nor IMF-fixdate are malformed and
    return [None]. Never raises. *)
val parse_seconds : now:float -> string -> float option
