(** Current readonly input of the Decisions rail. No retained projection,
    successful TTL, background fill, timer or provider call belongs here. *)

type read_error =
  | Roster_unavailable of string
  | Metadata_unavailable of { keeper : string; detail : string }

val read_current :
  config:Workspace.config -> limit:int -> (Yojson.Safe.t, read_error) result
(** Capture the original persisted roster, metadata and decision-log projection
    on the existing shared executor. A later call observes a completed append
    without waiting for elapsed time. Listed metadata that cannot be read or
    decoded is an error; confirmed absence after listing is skipped.

    The original decision-log tail/row decoding and limit policy are retained.
    The executor's entered-work cleanup and cancellation are not replaced by
    a new deadline or inline replay after failure. Exceptions propagate to the
    route; [Eio.Cancel.Cancelled] must remain cancellation. *)

val read_error_to_string : read_error -> string
val read_error_to_json : read_error -> Yojson.Safe.t
(** HTTP error metadata; raw filesystem diagnostics remain in logs. *)
