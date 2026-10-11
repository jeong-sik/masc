(** Claude's root provider-request retry notice. This is neither a tool retry,
    a runtime fallback, nor exposed reasoning. Values describe the CLI's own
    retry; consumers must not turn them into MASC retry budgets or timers. *)
type t =
  { observation_id : string
  ; attempt : int
  ; max_retries : int
  ; retry_delay_ms : int
  ; error_status : int option
  }

type error = Invalid_field of string | Conflicting_field of string | Other_session

val decode : expected_session_id:string -> Yojson.Safe.t -> (t option, error) result
(** [None] means a different well-formed wire kind, not successful delivery.
    A retry must name the exact session and a nonblank observation UUID.
    Private error text is deliberately not retained. Duplicate protocol fields
    are rejected. Counts and delay are nonnegative observations, with no added
    upper bound or relation between attempt and max_retries. *)
