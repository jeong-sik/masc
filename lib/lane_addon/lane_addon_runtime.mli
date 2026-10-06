(** Optional observers run in independent server-owned fibers. No Keeper tool
    set, input queue, turn switch or environment owner is replaced. *)
type operation = Attach | Inspect | Observe | Detach | Slice | Evidence | Act | Action_status
type error = Request_rejected of string | Runtime_failed of string
val error_to_string : error -> string
val register_delivery_handler :
  (config:Workspace.config -> caller:string -> keeper_name:string -> prompt:string ->
    (Yojson.Safe.t, string) result) -> unit
val register_sampling_factory :
  (sw:Eio.Switch.t -> store:Lane_addon_store.t -> instance_id:string ->
    package:Lane_addon_types.package -> binding:Yojson.Safe.t ->
    (Lane_addon_sampling.t, string) result) -> unit
(** Server-owned model boundary, registered before configuration maintenance.
    Construction must perform no I/O, credential resolution, provider call or
    store write: it validates the exact instance, package, binding and host route
    and returns a closure. It is called before the entry is persisted with the
    root switch; that validation closure is discarded. Worker startup constructs
    its actual callback again with the worker lifetime switch. Disabled packages
    do not request a callback. Construction refuses stores outside the registered
    workspace. Invocation must retain model requests before invoking a provider. *)
type fleet_backend = {
  snapshot : config:Workspace.config -> caller:string -> access:Lane_addon_sources.access ->
    (Lane_addon_broadcast_delivery.sender_authority * string list,string) result;
  project : config:Workspace.config ->
    sender_authority:Lane_addon_broadcast_delivery.sender_authority ->
    delivery:Workspace_broadcast.broadcast_delivery -> recipient:string -> (unit,string) result;
}
val register_fleet_backend : fleet_backend -> unit
val recover_fleet : config:Workspace.config -> sw:Eio.Switch.t -> (unit,string) result
val start_fleet_service : config:Workspace.config -> sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit
val dispatch : ?caller:string -> ?access:Lane_addon_sources.access ->
  config:Workspace.config -> operation:operation -> Yojson.Safe.t ->
  (Yojson.Safe.t, error) result
(** [caller] is provenance. An omitted [access] is [Unauthenticated]. *)
val notify_activity : config:Workspace.config -> activity:Lane_addon_sources.activity -> unit
val notify_fusion_run : run_id:string -> unit
(** Capture hints for exact-run bindings against the process-wide Fusion registry.
    No I/O or package callback; work is carried to the owner domain. *)
val authorize_retained_read : bindings:Yojson.Safe.t list -> access:Lane_addon_sources.access -> Yojson.Safe.t -> (unit, string) result
(** Pure read authorization against one authoritative full binding snapshot.
    Explicit durable visibility remains required for current records. The exact
    published v0.48.0 envelope is readable only after its complete retained
    producer graph proves shared visibility. Cycles, absent or ambiguous
    incarnations and private dependencies fail closed. The supplied access is
    host-owned; no request field can set it. No stored bytes are changed. *)

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
type configuration_owner = { id : string; source_path : string; revision : string }
type inventory_presence = Live | Retained
type inventory_instance = {
  instance_id : string; incarnation : string; run_id : string;
  package_id : string; title : string; package_revision : string;
  configuration : configuration_owner option;
  presence : inventory_presence; phase : Lane_addon_types.phase;
}
type inventory = {
  owner_present : bool;
  instances : inventory_instance list;
  issues : (string * string) list;
  complete : bool;
}
val inventory : config:Workspace.config -> inventory
(** Operator-only metadata source; the HTTP caller must enforce CanAdmin.
    Runs live reads on the existing owner domain and offloads retained file reads.
    Does not create a manager/store, start workers, reconcile or clean resources.
    [owner_present=false] means no manager has been observed in this process,
    not that there are no retained bindings or declarations. *)
val read_declaration : ?caller:string -> ?access:Lane_addon_sources.access -> config:Workspace.config -> Yojson.Safe.t ->
  (Yojson.Safe.t, Lane_addon_declaration.error) result
val save_declaration : ?caller:string -> ?access:Lane_addon_sources.access -> config:Workspace.config -> Yojson.Safe.t ->
  (Yojson.Safe.t, Lane_addon_declaration.error) result
(** Declaration reads and writes use the same explicit authority boundary as
    [dispatch]; an omitted [access] grants no private authority. *)
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
    start : sw:Eio.Switch.t -> instance_id:string -> package:Lane_addon_types.package -> binding:Yojson.Safe.t ->
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
  val with_declaration_writer :
    (directory:string -> Lane_addon_declaration.write_request ->
      (Lane_addon_declaration.receipt, Lane_addon_declaration.error) result) ->
    (unit -> 'a) -> 'a
  val with_observation_writer :
    (store:Lane_addon_store.t -> instance_id:string -> seq:int ->
      sources:Yojson.Safe.t -> Lane_addon_types.output ->
      (unit, Lane_addon_store.observation_write_error) result) -> (unit -> 'a) -> 'a
  (** Fiber-local staged publication injection captured before offload. *)
  val reset : unit -> unit
end
