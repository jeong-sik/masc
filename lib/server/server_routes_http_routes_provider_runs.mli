(** Server_routes_http_routes_provider_runs — HTTP routes for the
    cascade provider run dashboard surface.

    Wires read-only operator endpoints exposing recent provider run
    samples. Daemon-side fetch fibers are spawned under [~sw]. *)

val add_routes :
  sw:Eio.Switch.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val dashboard_heuristics_json : Httpun.Request.t -> Yojson.Safe.t
(** Shared HTTP/1 + H2 response builder for O5 heuristic feeds. *)

val dashboard_heuristics_coverage_json : Httpun.Request.t -> Yojson.Safe.t
(** Shared HTTP/1 + H2 response builder for heuristic coverage. *)

val dashboard_stress_json :
  config:Coord.config -> Httpun.Request.t -> Yojson.Safe.t
(** Shared HTTP/1 + H2 response builder for O5 agent stress feeds. *)
