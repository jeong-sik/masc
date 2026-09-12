(** Optional observers run in independent server-owned fibers. No Keeper tool
    set, input queue, turn switch or environment owner is replaced. *)
type operation = Attach | Inspect | Observe | Detach | Slice | Evidence
val register_delivery_handler :
  (config:Workspace.config -> caller:string -> keeper_name:string -> prompt:string ->
    (Yojson.Safe.t, string) result) -> unit
val dispatch : ?caller:string -> config:Workspace.config -> operation:operation -> Yojson.Safe.t ->
  (Yojson.Safe.t, string) result
(** Root-domain notification only: no I/O and no package callback. Existing
    activity can wake observers; repeated notifications coalesce visibly. *)
val notify_activity : config:Workspace.config -> unit

(** Reconcile a complete TOML declaration inventory with owned observers.
    Malformed declarations and incomplete reads preserve the last applied
    configuration. Confirmed declaration removal detaches its owned observer.
    The directory is explicit for isolated feature tests. *)
val reconcile_configuration : config:Workspace.config -> directory:string ->
  (Yojson.Safe.t, string) result
val configuration_directory : Workspace.config -> string
(** Start independent server-owned configuration maintenance using the existing
    maintenance cadence. Runs once at startup and after owned cleanup completes. *)
val start_configuration_service : config:Workspace.config -> sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock -> unit

module For_testing : sig
  type connection = {
    observe : binding:Yojson.Safe.t -> sources:Yojson.Safe.t ->
      (Lane_addon_types.output, string) result;
    stop : unit -> (unit, string) result;
    container_id : string;
  }
  type backend = {
    start : sw:Eio.Switch.t -> instance_id:string -> package:Lane_addon_types.package ->
      on_created:(connection -> unit) -> (connection, string) result;
    acquire : store:Lane_addon_store.t -> package:Lane_addon_types.package ->
      binding:Yojson.Safe.t -> (Yojson.Safe.t, string) result;
    recover_stop : instance_id:string -> container_id:string option -> max_reply_bytes:int ->
      (unit, string) result;
  }
  val with_backend : backend -> (unit -> 'a) -> 'a
  val reset : unit -> unit
end
