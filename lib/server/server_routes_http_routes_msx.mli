(** Server_routes_http_routes_msx — the workspace MSX machine's frame.

    Registers [GET /api/v1/msx/frame], a read-only view of the single machine
    [Msx_lane] holds, for the TUI spectator (RFC-0439 §3.7). The serializer is
    hidden; the wired route is the surface. *)

val frame_json : unit -> Yojson.Safe.t
(** The frame payload: [{loaded:false}] when no machine is loaded, else
    [{loaded:true, number, width, height, mode, cartridge, rgb_base64}].
    Exposed for the route test. *)

val press_result_json :
  ok:bool -> ?message:string -> Msx_lane.observation option -> Yojson.Safe.t
(** The press response body. Exposed for the route test. *)

val carts_json : base_path:string -> Yojson.Safe.t
(** The load menu's inventory: [{carts:[names], loaded, cartridge}], the file
    names under [<base_path>/.masc/msx/carts] and which one is plugged in now.
    Exposed for the route test. *)

val load_result_json : ok:bool -> message:string -> Yojson.Safe.t
(** The load response body: [{ok, message}]. Exposed for the route test. *)

val msx_tick_default_frames : int
(** Frames a [POST /api/v1/msx/tick] advances when the body names none. *)

val tick_response :
  body:string ->
  [ `OK | `Bad_request | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t
(** Authenticated tick body handling. Only an object with an optional integer
    [frames] is accepted; duplicate and unknown fields are refused before
    mutation. Accepted frame counts are clamped to the lane's per-call range.
    Stepping and frame serialization run once on the shared executor pool;
    an unavailable pool refuses the tick without running it inline. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t

val checkpoint_response :
  base_path:string -> restore:bool -> body:string ->
  [ `OK | `Bad_request | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t
