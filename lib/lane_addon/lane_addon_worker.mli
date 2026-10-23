(** One optional Add-on, one container or microVM. Calls yield without taking a
    Keeper or environment-owner lock. The caller owns the background fiber and
    passes a switch whose lifetime spans the binding, not a Keeper turn. *)
type t
val image_identity : t -> Lane_addon_engine.image_identity
(** The local image identity resolved for this worker generation. A handle
    passed to [on_created] exposes this identity before the created container
    is verified. An [Ok] handle returned by [start] has passed that verification
    before package process start. This accessor performs no new inspection. *)

type error =
  | Invalid_package of string
  | Docker_failed of { operation : string; detail : string }
  | Engine_failed of { runtime : Lane_addon_types.runtime; operation : string; detail : string }
  | Engine_fault of { runtime : Lane_addon_types.runtime; fault : Lane_addon_lifecycle.engine_fault }
  | Lifecycle of Lane_addon_lifecycle.failure
  | Protocol_failed of string
  | Host_refusal of Lane_addon_call_context.host_refusal
  | Invalid_observation of string
  | Stopped

type mount = { source : string; destination : string }

(** [on_created] runs as soon as the exact created-container ID is known,
    before waiting for inspect or protocol initialization. Store the handle to
    allow concurrent detach even if either operation never responds. Packages expose
    [lane_observe] in the initial MCP tools/list page. [docker_command] and
    [container_command] override the executable of their respective runtime.
    [control_timeout_sec] bounds each engine control command and cancels its
    switch so the child is killed and reaped. A host sampling declaration
    requires [sampling_handler]; disabled packages refuse a supplied callback.
    Both mismatches fail before container creation.

    [on_engine] receives the engine identity before the first create and must
    persist it; an error stops the start before any create. [is_live_instance]
    says which worker incarnations are live in the calling process. A
    persistent slot held by a container of a dead incarnation of the same
    installation is removed before create; any other holder is refused with
    [Slot_foreign] and left alone. The default treats every incarnation as
    live, so nothing is removed. [scope] labels the container with the base
    path of the server that made it, which is what lets {!sweep} find it. *)
val start :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  control_timeout_sec:float ->
  mgr:_ Eio.Process.mgr ->
  instance_id:string ->
  package:Lane_addon_types.package ->
  ?state_owner:Lane_addon_worker_state.owner ->
  ?mounts:mount list ->
  ?docker_command:string ->
  ?container_command:string ->
  ?on_engine:(Lane_addon_lifecycle.engine -> (unit, string) result) ->
  ?is_live_instance:(string -> bool) ->
  ?scope:string ->
  ?on_created:(t -> unit) ->
  ?artifact_store:Lane_addon_store.t ->
  ?sampling_handler:Lane_addon_sampling.t ->
  unit -> (t, error) result

val observe :
  t -> binding:Yojson.Safe.t -> sources:Yojson.Safe.t ->
  (Lane_addon_types.output, error) result

(** Removes exactly this container and verifies absence. May run while an
    observation is blocked. Failure is returned without cancelling the
    caller's switch. Calling it again retries incomplete cleanup. *)
val stop : t -> (unit, error) result

(** Waits until this worker's MCP process has ended. It does not stop, close
    or remove anything. *)
val await_exit : t -> Eio.Process.exit_status

(** Explicit detach after a host restart. [Some id] verifies that exact
    container's ownership label before removal. [None] recovers a lost create
    receipt using this instance's deterministic container name, then verifies
    both the name and ownership label before removing the resolved exact ID.
    In either case, absence requires a successful query to the retained runtime,
    and counts only when the engine that answered is [engine], the one recorded
    when the container was created (see {!Lane_addon_slot.proven}). Each query
    is bounded by [control_timeout_sec]. [runtime] defaults to Docker
    for callers that predate runtime selection. *)
val recover_stop :
  clock:_ Eio.Time.clock -> control_timeout_sec:float ->
  mgr:_ Eio.Process.mgr ->
  instance_id:string -> container_id:string option ->
  engine:Lane_addon_lifecycle.engine ->
  ?runtime:Lane_addon_types.runtime ->
  ?state_owner:Lane_addon_worker_state.owner ->
  ?docker_command:string -> ?container_command:string -> unit -> (unit, error) result

(** Only manifest-declared tools, resolved against the initialized worker's
    MCP inventory. Empty before initialization and once shutdown begins. *)
val exported_tools : t -> Mcp_protocol.Mcp_types.tool list

val call_exported_tool : ?on_result:(Mcp_protocol.Mcp_types.tool_result -> unit) -> ?authorize:Lane_addon_call_context.mediation -> ?principal:Lane_addon_call_context.principal -> t -> name:string -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, error) result
(** Calls only a declared, initialized export. A stop revokes admission before
    resource cleanup. After dispatch, transport failure does not prove absence
    of effects and must not trigger automatic replay. Selected input hooks run
    before mediation or RPC; selected output hooks check the final target reply,
    including host-context invocation, without inspecting private control replies.
    [on_result] captures raw actual replies/effect events under RPC serialization,
    before output validation. It is not publication of a validated result. *)

val host_requests : t -> (Yojson.Safe.t, error) result
(** Calls [lane_host_requests] with no arguments and returns its structured
    content, undecoded. *)

val host_result : t -> arguments:Yojson.Safe.t -> (Yojson.Safe.t, error) result
(** Calls [lane_host_result]. After dispatch, a transport failure does not
    prove the package did not consume the result. *)

val action_schema : t -> Yojson.Safe.t option
val act : t -> arguments:Yojson.Safe.t -> (Lane_addon_action.package_result, error) result

val container_id : t -> string
val container_name : t -> string
val error_to_string : error -> string

val start_failure : error -> Lane_addon_lifecycle.failure
val cleanup_failure : error -> Lane_addon_lifecycle.failure
(** The typed failure the runtime records for a failed start, or a cleanup
    that cannot be confirmed. *)

(** Removes the containers this base path's servers left behind. See
    {!Lane_addon_slot.sweep}. [scope] is the label {!start} was given. *)
val sweep :
  clock:_ Eio.Time.clock -> control_timeout_sec:float ->
  mgr:_ Eio.Process.mgr -> runtime:Lane_addon_types.runtime -> scope:string ->
  is_live_instance:(string -> bool) ->
  ?docker_command:string -> ?container_command:string -> unit ->
  (Lane_addon_slot.sweep_item list, Lane_addon_lifecycle.failure) result

(** True when the container that made [start] or a cleanup refuse with
    [Slot_foreign] is gone or no longer carries those labels. False also when
    that cannot be read. *)
val holder_changed :
  clock:_ Eio.Time.clock -> control_timeout_sec:float ->
  mgr:_ Eio.Process.mgr -> runtime:Lane_addon_types.runtime ->
  ?docker_command:string -> ?container_command:string ->
  Lane_addon_lifecycle.holder -> bool

(** The identity of the engine the control command currently reaches. The exit
    status of [docker info] (or [container system status]) alone separates
    [Unreachable] from an identity; no error text is classified. Each query is
    bounded by [control_timeout_sec]. *)
val read_engine :
  clock:_ Eio.Time.clock -> control_timeout_sec:float ->
  mgr:_ Eio.Process.mgr -> runtime:Lane_addon_types.runtime ->
  ?docker_command:string -> ?container_command:string -> unit ->
  (Lane_addon_lifecycle.engine, error) result

(** Read-only engine inspection. Failure does not imply that the image is
    absent. [control_timeout_sec] also bounds this engine query. *)
val inspect_image :
  clock:_ Eio.Time.clock -> control_timeout_sec:float ->
  mgr:_ Eio.Process.mgr -> package:Lane_addon_types.package ->
  ?docker_command:string -> ?container_command:string -> unit ->
  (Lane_addon_engine.image_identity, error) result
