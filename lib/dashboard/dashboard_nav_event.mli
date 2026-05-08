(** Dashboard surface/section open counters (RFC-0049).

    Increments aggregate Prometheus counters
    [dashboard_surface_open_total] and [dashboard_section_open_total] in
    response to a [POST /api/v1/dashboard/nav-event] from the dashboard.

    No PII, no per-event storage. The body of every accepted request is
    discarded after the counter increment.
*)

type event = {
  surface : string;
  section : string option;
  redirected_from : string option;
}

(** Strict allowlist of valid surface IDs. Mirrors [VALID_TABS] in
    [dashboard/src/types/sse.ts]. *)
val valid_surfaces : string list

(** Strict allowlist of [(surface, section)] pairs. Generated from
    [dashboard/src/config/navigation.ts]. *)
val valid_sections : (string * string list) list

(** [is_valid_surface s] returns [true] iff [s] is in [valid_surfaces]. *)
val is_valid_surface : string -> bool

(** [is_valid_section ~surface section] checks the pair against the
    allowlist. Returns [true] for known visible *and* hidden sections. *)
val is_valid_section : surface:string -> string -> bool

(** [parse_event_json json] parses the request body. Returns [Error msg]
    for any of: malformed JSON shape, missing [surface], unknown
    [surface], unknown [(surface, section)] pair, malformed
    [redirected_from], or [redirected_from] referring to an unknown pair. *)
val parse_event_json : Yojson.Safe.t -> (event, string) result

(** [record event] increments the relevant Prometheus counters.
    Idempotent w.r.t. counter registration. *)
val record : event -> unit
