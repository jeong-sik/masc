(** Reads the fleet scan's section of the full health snapshot as a
    {!Fleet_stream.fleet} (RFC-0477).

    The section is the server's own JSON, written for several readers, and it
    holds fields this stream does not carry. So this reader takes the fields
    the stream needs and ignores the rest, unlike {!Fleet_stream.decode}, which
    reads exactly what the stream writes. It replaces the reader the terminal
    client kept for [GET /health?full=1].

    The scan's own field names differ from the stream's ([running_keeper_fiber_count]
    for [running_count]); this module is the one place that knows both. *)

type error =
  | Not_measured of { status : string }
      (** The snapshot holds a warming placeholder with no reading yet. *)
  | Scan_failed of Fleet_stream.degraded_reason
      (** The fleet section itself failed or timed out. *)
  | Unreadable of string
      (** The section says it is a reading and cannot be read as one. This is a
          fault in the server, not a state the fleet is in. *)

val error_to_string : error -> string

val fleet_of_health_fields :
  (string * Yojson.Safe.t) list -> (Fleet_stream.fleet, error) result
(** [fleet_of_health_fields fields] reads [keeper_fleet_safety] out of the
    fields of the full health snapshot. *)
