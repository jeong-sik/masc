(** Server_routes_http_routes_msx — the workspace MSX machine HTTP routes.

    Registers MSX control and manipulation routes (RFC-0439 §3.7, RFC #38695).
    Machine spectating is handled via
    [GET /api/v1/lane-addons/live?source_kind=msx_capture]. *)

val press_result_json :
  ok:bool -> ?message:string -> Yojson.Safe.t option -> Yojson.Safe.t
(** The press response body. Exposed for the route test. *)

val press_default_hold_frames : int
(** Frames a [POST /api/v1/msx/press] holds its keys when the body names none. *)

val press_default_step_frames : int
(** Frames a [POST /api/v1/msx/press] advances in all when the body names none. *)

val press_response :
  config:Workspace.config -> who:string -> body:string ->
  [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t
(** Authorized HTTP actor is passed to the shared worker. Input is checked
    against its declared tool contract, with the HTTP tap defaults above.
    Missing workers return 503; worker activity refusals retain their 409 code. *)

val carts_response : config:Workspace.config ->
  [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t
(** Worker-owned inventory [{carts; loaded; cartridge; disk}]. Missing shared
    installations are unavailable; the host filesystem is never a fallback. *)

val load_result_json : ok:bool -> message:string -> Yojson.Safe.t
(** The load response body: [{ok, message}]. Exposed for the route test. *)

val load_response :
  config:Workspace.config -> agent_name:string -> body:string ->
  [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t
(** Load through the shared worker, preserving [{ok; message}]. *)

val msx_tick_default_frames : int
(** Frames a [POST /api/v1/msx/tick] advances when the body names none. *)

val tick_response :
  config:Workspace.config -> body:string ->
  [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t
(** Authenticated tick body handling. An optional integer [frames] controls
    advancement. [pixel_response="retained"] requests an inline/retained pixel
    response; optional [known_pixels={revision,width,height}] advertises the
    client's exact retained pixels. Duplicate and unknown fields are refused before
    mutation. Accepted frame counts are clamped to the lane's per-call range.
    Stepping and atomic frame/ledger capture run once in the attached worker;
    an unavailable worker refuses the tick without a local fallback.
    Activity refusal is HTTP 409 with [ok=false] and a closed [code] of
    [activity_disabled] or [activity_unobserved], before execution starts. *)

val activity_json : config:Workspace.config -> Yojson.Safe.t
(** Read the published MSX activity only. No machine is started or advanced.
    Also served by the public-read GET [/api/v1/msx/activity]. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t

(** Save or restore through the shared worker. *)
val checkpoint_response :
  config:Workspace.config -> restore:bool -> body:string ->
  [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t
