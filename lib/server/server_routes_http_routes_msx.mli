(** Server_routes_http_routes_msx — the workspace MSX machine HTTP routes.

    Registers MSX control and manipulation routes (RFC-0439 §3.7, RFC #38695).
    Every mutation validates an optional [expected_workspace] binding before
    effects; the TUI supplies its captured identity on every write.
    Machine spectating is handled via
    [GET /api/v1/lane-addons/live?source_kind=msx_capture]. *)

val press_result_json :
  ok:bool -> ?message:string -> Msx_lane.observation option -> Yojson.Safe.t
(** The press response body. Exposed for the route test. *)

val press_default_hold_frames : int
(** Frames a [POST /api/v1/msx/press] holds its keys when the body names none. *)

val press_default_step_frames : int
(** Frames a [POST /api/v1/msx/press] advances in all when the body names none. *)

val press_response :
  config:Workspace.config -> who:string -> body:string ->
  [ `OK | `Conflict | `Bad_request | `Internal_server_error ] * Yojson.Safe.t
(** [expected_workspace], when present, is validated against [config] before
    any machine effect. Authenticated press body handling under [who], the actor the route's
    [with_tool_actor_auth] resolved. [keys] must be an array of strings naming
    at least one key; [hold_frames] and [frames] must be positive integers and
    [sequence] a boolean when present, each defaulting when absent. A field of
    the wrong type is a [`Bad_request] naming the field, and nothing is pressed.
    A press while the machine's activity is off or unobserved is a [`Conflict]
    carrying the same [code] the tick route sends ([activity_disabled] or
    [activity_unobserved]), so a client reads one protocol on both routes.
    An accepted press wakes the [config] workspace's Lane instances bound to the
    machine once, with [Machine_changed Msx]; a refused one wakes nothing. The wake is
    cancellation-protected, so the call must run in an Eio fiber.

    Every MSX change route (press, load, save, restore, disk) accepts an
    optional [expected_workspace] object naming the workspace the terminal
    read. A different workspace is a [`Conflict] and nothing is applied. *)

val carts_json : base_path:string -> Yojson.Safe.t
(** The load menu's inventory: [{carts:[names], loaded, cartridge}], the file
    names under [<base_path>/.masc/msx/carts] and which one is plugged in now.
    Exposed for the route test. *)

val load_result_json : ok:bool -> message:string -> Yojson.Safe.t
(** The load response body: [{ok, message}]. Exposed for the route test. *)

val load_response :
  config:Workspace.config -> agent_name:string -> body:string ->
  [ `OK | `Bad_request | `Conflict ] * Yojson.Safe.t
(** An accepted load wakes the workspace's machine watchers after the machine
    changes and before the optional Board announcement. A refusal wakes none.
    The wake is cancellation-protected, so the call must run in an Eio fiber. *)

val msx_tick_default_frames : int
(** Frames a [POST /api/v1/msx/tick] advances when the body names none. *)

val tick_response :
  body:string ->
  [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t
(** Authenticated tick body handling. An optional integer [frames] controls
    advancement. [pixel_response="retained"] requests an inline/retained pixel
    response; optional [known_pixels={revision,width,height}] advertises the
    client's exact retained pixels. Duplicate and unknown fields are refused before
    mutation. Accepted frame counts are clamped to the lane's per-call range.
    Stepping and atomic frame/ledger capture run once on the shared executor pool;
    an unavailable pool refuses the tick without running it inline.
    Activity refusal is HTTP 409 with [ok=false] and a closed [code] of
    [activity_disabled] or [activity_unobserved], before execution starts.
    The body is not bound to a workspace; see [tick_response_bound]. *)

val tick_response_bound :
  config:Workspace.config -> body:string ->
  [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t
(** [tick_response] for the route, which knows its workspace.
    [expected_workspace], when present, is validated against [config] before
    any executor submission, as for every MSX write: one naming a different
    workspace is a [`Conflict] with [code] [workspace_precondition_failed], and
    a malformed one a [`Bad_request]; nothing is stepped in either case. The
    field is removed before the strict tick decoder. *)

val activity_json : unit -> Yojson.Safe.t
(** Read the published MSX activity only. No machine is started or advanced.
    Also served by the public-read GET [/api/v1/msx/activity]. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t

val settle_checkpoint_effect :
  restore:bool ->
  persist:(Server_msx_checkpoint_receipt.state -> (unit, string) result) ->
  notify:(unit -> unit) -> Server_msx_checkpoint_receipt.state -> (unit, string) result
(** Settle completed worker evidence, then notify a committed or possibly applied
    restore even if persistence failed. Saves and proven refusals stay silent.
    A notification exception does not rewrite the stored receipt; its error
    retains any persistence failure too. Cancellation still propagates. *)

(** Save ([restore=false]) or restore the machine in the [config] workspace's
    checkpoint slot. An accepted restore wakes the Lane instances bound to the
    machine once, with [Machine_changed Msx]; a save or a refusal wakes nothing. *)
val checkpoint_response :
  config:Workspace.config -> restore:bool -> body:string ->
  [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t

(** Workspace-bound read of one admitted checkpoint operation. Missing/pending
    evidence never proves completion. Committed receipts precede a same-request
    current lane snapshot, explicitly allowed to contain later effects. *)
val checkpoint_status_response :
  config:Workspace.config -> body:string ->
  [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ] * Yojson.Safe.t
