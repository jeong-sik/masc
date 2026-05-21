(** HTTP route for keeper shell counter snapshots. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  Http_server_eio.Router.t ->
  Http_server_eio.Router.t

val snapshot_response : unit -> Yojson.Safe.t
(** Build the [GET /api/v1/legendary_bash/counters] response payload. *)
