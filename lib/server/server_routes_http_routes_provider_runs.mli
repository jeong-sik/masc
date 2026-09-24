(** Server_routes_http_routes_provider_runs — HTTP routes for the
    runtime provider run dashboard surface.

    Wires read-only operator endpoints exposing recent provider run
    samples. Daemon-side fetch fibers are spawned under [~sw]. *)

val add_routes :
  sw:Eio.Switch.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

(** The [cache] object a cached dashboard route appends. *)
val cache_metadata :
  state:Dashboard_cache_wire.state ->
  generated_at:float ->
  ?age_s:float ->
  ?error:string ->
  unit ->
  Yojson.Safe.t

(** [json] with [metadata] appended as its [cache] field. *)
val json_with_cache_metadata : Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
