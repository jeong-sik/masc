(** Server_routes_http_routes_provider_runs — HTTP routes for the
    runtime provider run dashboard surface.

    Wires read-only operator endpoints exposing recent provider run
    samples. Daemon-side fetch fibers are spawned under [~sw]. *)

type provider_keeper_meta_scan = private
  { keepers : Keeper_meta_contract.keeper_meta list
  ; keeper_names_known : bool
  ; read_errors : Yojson.Safe.t list
  }
(** Result of provider-dashboard keeper discovery.  Exposed so focused
    regressions can prove keeper-name discovery/read failures are carried into
    dashboard feed payloads instead of being collapsed to an empty keeper list. *)

val provider_dashboard_keeper_meta_scan :
  Workspace.config -> provider_keeper_meta_scan

val provider_dashboard_json_with_keeper_meta_scan :
  provider_keeper_meta_scan -> Yojson.Safe.t -> Yojson.Safe.t

val add_routes :
  sw:Eio.Switch.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t
