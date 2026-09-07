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

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
