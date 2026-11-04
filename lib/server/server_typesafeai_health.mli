(** The [typesafeai] section of [/health?full=1] (RFC-0484 §3.2): the latest
    outcome of each configured TypeSafe judgment server, as this process saw
    it in {!Typesafeai_client.destination_outcomes}.

    A destination refusing for payment (402) or for its key (401, 403) is an
    operator action reason: only the operator can add credit or change a key.
    Other refusals end on the vendor's side and are status reasons only. The
    section reads process memory and decides nothing: the judgment paths walk
    their destinations exactly as before. *)

val section_json :
  configured:
    (Typesafeai_client.destination_id list, Typesafeai_config.unavailable_reason) result ->
  outcomes:(Typesafeai_client.destination_id * Typesafeai_client.destination_outcome) list ->
  Yojson.Safe.t
(** [Error] when the lane has no destination to ask: the status is
    [disabled], a state name the operator rollup does not grade. [Ok]
    destinations are graded by their outcomes: [idle] before any was asked,
    [degraded] when every one is refusing, [warning] when one refuses for
    payment or its key while another answers, [ok] otherwise. Outcomes of a
    destination the table no longer names are left out. *)

val health_json : unit -> Yojson.Safe.t
(** {!section_json} over {!Typesafeai_config.lane_destinations} and
    {!Typesafeai_client.destination_outcomes}. *)

val health_placeholder : status:Health_status.t -> Yojson.Safe.t
(** The section before the background snapshot has run: no destination
    observed, the snapshot's own grade. *)
