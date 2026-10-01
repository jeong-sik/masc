(** Optional observers run in independent server-owned fibers. No Keeper tool
    set, input queue, turn switch or environment owner is replaced. *)
type operation = Attach | Inspect | Observe | Detach | Slice | Evidence | Act | Action_status
type error = Request_rejected of string | Runtime_failed of string
val error_to_string : error -> string
val register_delivery_handler :
  (config:Workspace.config -> caller:string -> keeper_name:string -> prompt:string ->
    (Yojson.Safe.t, string) result) -> unit
type fleet_backend = {
  snapshot : config:Workspace.config -> caller:string -> (Lane_addon_broadcast_delivery.sender_authority * string list,string) result;
  project : config:Workspace.config -> sender_authority:Lane_addon_broadcast_delivery.sender_authority -> delivery:Workspace_broadcast.broadcast_delivery ->
    recipient:string -> (unit,string) result;
}
val register_fleet_backend : fleet_backend -> unit
(** Install trusted host roster capture and idempotent single-recipient projection.
    Snapshot is captured before durable admission, never on retry. *)
val recover_fleet : config:Workspace.config -> sw:Eio.Switch.t -> (unit,string) result
(** Scan durable intentions and schedule independent commit/recipient jobs on
    the supplied server-root switch. Returns after scheduling, without waiting
    for recipient I/O. Repeated scans share each operation/recipient's in-flight
    owner. Job failures remain durable pending obligations and are logged;
    cancellation releases ownership so the next service can retry. *)
val start_fleet_service : config:Workspace.config -> sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit
(** Server-root Pulse owns reconciliation and retry. Failed recipients remain
    pending; a committed message is only read, never republished if missing. *)
(** Omitted [access] is unauthenticated; [caller] carries attribution only. *)
val dispatch : ?caller:string -> ?access:Lane_addon_sources.access -> config:Workspace.config -> operation:operation -> Yojson.Safe.t ->
  (Yojson.Safe.t, error) result
(** No I/O and no package callback. Runs on the root-switch owner domain: a
    caller on another domain (the HTTP serving domain, a pool worker) is
    carried there and waits until the hint is recorded. Only sources
    interested in the typed activity receive a capture hint. Repeated hints
    coalesce; explicit observations take precedence over refresh hints. *)
val notify_activity : config:Workspace.config -> activity:Lane_addon_sources.activity -> unit
val notify_fusion_run : run_id:string -> unit
(** Capture hints for exact-run bindings against the process-wide Fusion registry.
    No I/O or package callback; work is carried to the owner domain. *)
val authorize_retained_read : access:Lane_addon_sources.access -> Yojson.Safe.t -> (unit, string) result
(** Pure read authorization against the strict durable visibility codec. The
    supplied access is host-owned; no request field can set it. *)

type skill_export_owner = Declaration of string | Instance of string
type skill_export = {
  owner : skill_export_owner;
  instance_id : string;
  package : Lane_addon_types.package;
}
val skill_source_id : skill_export_owner -> string
val register_skill_export_handler :
  (config:Workspace.config -> skill_export list -> (unit, string) result) -> unit
(** Server publication bridge for package-declared Skills. The callback receives
    applied package state, including manual installations. It never becomes a
    Keeper turn prerequisite. Bodies are not inserted into Keeper instructions. *)

(** Reconcile a complete TOML declaration inventory with owned observers.
    Malformed declarations and incomplete reads preserve the last applied
    configuration. Confirmed declaration removal detaches its owned observer.
    The directory is explicit for isolated feature tests. *)
val reconcile_configuration : config:Workspace.config -> directory:string ->
  (Yojson.Safe.t, string) result
val configuration_directory : Workspace.config -> string
val read_declaration : ?caller:string -> ?access:Lane_addon_sources.access -> config:Workspace.config -> Yojson.Safe.t ->
  (Yojson.Safe.t, Lane_addon_declaration.error) result
val save_declaration : ?caller:string -> ?access:Lane_addon_sources.access -> config:Workspace.config -> Yojson.Safe.t ->
  (Yojson.Safe.t, Lane_addon_declaration.error) result
(** HTTP and Keeper editors share the configuration serializer with reconcile
    and managed Detach. Saving bytes only nudges the existing maintenance owner;
    its receipt never claims that a worker has already applied the change. *)
(** Start independent server-owned configuration maintenance using the existing
    maintenance cadence. Runs once at startup and after owned cleanup completes. *)
val start_configuration_service : config:Workspace.config -> sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock -> unit

module For_testing : sig
  type connection = {
    observe : binding:Yojson.Safe.t -> sources:Yojson.Safe.t ->
      (Lane_addon_types.output, string) result;
    action_schema : unit -> Yojson.Safe.t option;
    act : arguments:Yojson.Safe.t -> (Lane_addon_action.package_result, string) result;
    stop : unit -> (unit, string) result;
    container_id : string;
  }
  type backend = {
    start : sw:Eio.Switch.t -> instance_id:string -> package:Lane_addon_types.package ->
      on_created:(connection -> unit) -> (connection, string) result;
    acquire : access:Lane_addon_sources.access -> store:Lane_addon_store.t -> package:Lane_addon_types.package ->
      resolve_lane_output:(installation_id:string -> (Lane_addon_sources.lane_output, string) result) ->
      binding:Yojson.Safe.t -> (Yojson.Safe.t, string) result;
    recover_stop : instance_id:string -> container_id:string option -> max_reply_bytes:int ->
      (unit, string) result;
    image_ready : package:Lane_addon_types.package -> (unit, string) result;
  }
  val with_backend : backend -> (unit -> 'a) -> 'a
  val with_action_writer :
    (store:Lane_addon_store.t -> instance_id:string -> request_id:string -> Yojson.Safe.t ->
      (unit, string) result) -> (unit -> 'a) -> 'a
  (** Fiber-local persistence replacement captured before filesystem offload.
      Allows the existing strict writer to inject a real post-rename failure. *)
  val reset : unit -> unit
end
