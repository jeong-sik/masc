(** Server_routes_http_routes_provider_runs — HTTP routes for the
    runtime provider run dashboard surface.

    Wires read-only operator endpoints exposing recent provider run
    samples. Daemon-side fetch fibers are spawned under [~sw]. *)

val add_routes :
  sw:Eio.Switch.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

(** How old a cached dashboard body is; the [cache.state] word of every
    cached dashboard route. [Cache_warming] is the placeholder answered
    before anything was computed for that key. *)
type cache_state =
  | Cache_fresh
  | Cache_stale_refreshing
  | Cache_warming

val cache_state_to_string : cache_state -> string

(** The [cache] object a cached dashboard route appends. *)
val cache_metadata :
  state:cache_state ->
  generated_at:float ->
  ?age_s:float ->
  ?error:string ->
  unit ->
  Yojson.Safe.t

(** [json] with [metadata] appended as its [cache] field. *)
val json_with_cache_metadata : Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
