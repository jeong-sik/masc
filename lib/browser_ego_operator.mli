(** Browser worker's private operator form. These callbacks must be synchronous
    and never dispatch SDK input. The host's operator credential and original
    worker incarnation are checked before invoking this port. *)
type recovery = {
  status : unit -> Browser_ego_input.status;
  busy : unit -> bool;
  assert_reset : generation:string -> (unit, string) result;
  space_observation : unit -> Browser_ego_space_observation.t option;
}
type connection = { client_id:string; space:Browser_lane.ego_space; recovery:recovery }
val schema : Yojson.Safe.t
val invoke : connection option -> Yojson.Safe.t -> Yojson.Safe.t
(** Read a form or record the explicit assertion for its exact pending token.
    Stale/rejected assertions return a [not_applied] view, never an MCP error
    that could retire an otherwise healthy worker. No raw failure is echoed. *)
