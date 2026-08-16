(** Failover attribution for --inject-failover — pure parsing and
    classification over runtime-manifest rows (the durable per-candidate
    record: keeper_turn_driver.ml emits one Runtime_routed/Runtime_failed/
    Runtime_completed row per lane candidate). The HTTP fetch lives in
    bin/; this module only decides what the rows say.

    Two failover modes exist and the keeper_turn_id is what separates
    them: an in-turn walk retries the next candidate inside one turn
    (several routed rows under one id), while a provider-effect-fenced
    failure defers the switch to the next cycle (one turn ends failed,
    a later turn starts on the other candidate). *)

type error_kind = private Error_kind of string
(** The server's error category label, recorded verbatim as diagnostic
    text. The private wrapper keeps it opaque — it renders at the JSON
    boundary and is never matched on (same shape as
    Tool_assignment_telemetry.error_kind). *)

val error_kind_of_wire : string -> error_kind

type attempt = {
  ts : string;
  keeper_turn_id : int option;
  event : attempt_event;
  runtime_id : string;
      (** The attempted candidate: [decision.runtime_id] when the row came
          from a lane walk (the top-level id is the lane id there), the
          top-level [runtime_id] otherwise (#28871). *)
  error_kind : error_kind option;  (** Present on [Failed] rows. *)
}

and attempt_event =
  | Routed
  | Failed
  | Completed

type mode =
  | In_turn
      (** One keeper turn routed at least two distinct runtimes. *)
  | Deferred
      (** A turn failed on one runtime and a later turn completed on a
          different one, with no multi-candidate turn in between. *)
  | Not_observed
      (** The window shows no runtime switch at all. *)

val parse_manifest_rows : Yojson.Safe.t -> (attempt list, string) result
(** Extract the three attribution events from a runtime-trace response's
    [manifest_rows]. Rows with other event kinds are not attribution
    evidence and are skipped; a malformed attribution row is an error,
    not a skip. *)

val classify :
  window_start:string -> attempts:attempt list -> mode * attempt list
(** Filter to rows at or after [window_start] (ISO8601 strings compare
    chronologically) and classify. Returns the filtered rows so the
    evidence carries exactly what the verdict was computed from. *)

val attempt_to_yojson : attempt -> Yojson.Safe.t
val mode_to_string : mode -> string
