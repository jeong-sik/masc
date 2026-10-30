(** Dashboard surface/section open counters (RFC-0049).

    Increments aggregate Otel_metric_store counters
    [dashboard_surface_open_total] and [dashboard_section_open_total] in
    response to a [POST /api/v1/dashboard/nav-event] from the dashboard.

    No PII, no per-event storage. The body of every accepted request is
    discarded after the counter increment.
*)

type event =
  { surface : string
  ; section : string option
  }

(** [parse_event_json json] parses the request body. Returns [Error msg]
    for any of: malformed JSON shape, missing [surface], unknown
    [surface], or unknown [(surface, section)] pair. *)
val parse_event_json : Yojson.Safe.t -> (event, string) result

(** [record event] increments the relevant Otel_metric_store counters.
    Idempotent w.r.t. counter registration. *)
val record : event -> unit
