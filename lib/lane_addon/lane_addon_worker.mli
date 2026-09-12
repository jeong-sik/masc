(** One optional Add-on, one Docker container. Calls yield without taking a
    Keeper or environment-owner lock. The caller owns the background fiber and
    passes a switch whose lifetime spans the binding, not a Keeper turn. *)
type t

type error =
  | Invalid_package of string
  | Docker_failed of { operation : string; detail : string }
  | Protocol_failed of string
  | Invalid_observation of string
  | Stopped

type mount = { source : string; destination : string }

(** [on_created] runs as soon as the exact created-container ID is known,
    before waiting for inspect or protocol initialization. Store the handle to
    allow concurrent detach even if either operation never responds. Packages expose
    [lane_observe] in the initial MCP tools/list page. [docker_command] is an
    executable path, also allowing hermetic control-protocol tests. *)
val start :
  sw:Eio.Switch.t ->
  mgr:_ Eio.Process.mgr ->
  instance_id:string ->
  package:Lane_addon_types.package ->
  ?mounts:mount list ->
  ?docker_command:string ->
  ?on_created:(t -> unit) ->
  unit -> (t, error) result

val observe :
  t -> binding:Yojson.Safe.t -> sources:Yojson.Safe.t ->
  (Lane_addon_types.output, error) result

(** Removes exactly this container and verifies absence. May run while an
    observation is blocked. Failure is returned without cancelling the
    caller's switch. Calling it again retries incomplete cleanup. *)
val stop : t -> (unit, error) result

(** Explicit detach after a host restart. [Some id] verifies that exact
    container's ownership label before removal. [None] recovers a lost create
    receipt using this instance's deterministic container name, then verifies
    both the name and ownership label before removing the resolved exact ID.
    In either case, absence requires a successful Docker query. *)
val recover_stop :
  mgr:_ Eio.Process.mgr ->
  instance_id:string -> container_id:string option -> max_reply_bytes:int ->
  ?docker_command:string -> unit -> (unit, error) result

val container_id : t -> string
val container_name : t -> string
val error_to_string : error -> string
