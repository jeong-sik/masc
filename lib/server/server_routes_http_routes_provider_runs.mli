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

module For_testing : sig
  type cache
  val create_cache : unit -> cache
  val cached_json :
    now:(unit -> float) -> sync_first:bool -> sw:Eio.Switch.t ->
    cache:cache -> key:string -> placeholder:Yojson.Safe.t ->
    compute:(unit -> (Yojson.Safe.t, string) result) -> Yojson.Safe.t
end
