(** Optional observers run in independent server-owned fibers. No Keeper tool
    set, input queue, turn switch or environment owner is replaced. *)
type operation = Attach | Inspect | Observe | Detach | Slice | Evidence | Act | Action_status
type error = Request_rejected of string | Runtime_failed of string
val error_to_string : error -> string
val register_delivery_handler :
  (config:Workspace.config -> caller:string -> keeper_name:string -> prompt:string ->
    (Yojson.Safe.t, string) result) -> unit
val register_exact_runner : Lane_addon_exact.runner -> unit
(** Server-owned runner for packages' exact-output requests, registered before
    configuration maintenance. Without it a declared installation's exact
    request ends its host request cycle with [no_exact_runner]. Retirement
    cancels its current exact call independently of worker cleanup; a pending
    provider outcome is not replayed and no later request is dispatched. *)
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
(** Pure read authorization of one retained record against the full binding
    snapshot. The record's own durable [visibility] and [source_access] decide;
    a record that carries neither, or an incarnation that is absent or ambiguous
    in the snapshot, is refused. The supplied access is host-owned; no request
    field can set it. No stored bytes are changed. *)

val register_tool_change_handler : (unit -> unit) -> unit
(** Server notification bridge. Callbacks signal clients to refresh their
    authorized inventories and must not acquire worker lifecycle locks. *)

type tool_export = Lane_addon_tool_export.t = private
  { owner : Lane_addon_tool_export.owner; instance_id : string; tool : Mcp_protocol.Mcp_types.tool }
type tool_call_error = Unavailable of string | Outcome_unknown of string
  | Host_refusal of Lane_addon_call_context.host_refusal
val tool_export_snapshot : config:Workspace.config -> access:Lane_addon_sources.access ->
  reserved:string list -> Lane_addon_tool_export.snapshot
(** Live export snapshot with individual name conflicts quarantined. *)
val tool_exports : config:Workspace.config -> access:Lane_addon_sources.access ->
  reserved:string list -> (tool_export list, string) result
(** Reads initialized live workers only; does not start or recover installations.
    The caller supplies the complete reserved host namespace. Collisions fail
    explicitly. Visibility follows verified caller authority. *)
val call_exported_tool_with_authority : on_complete:(unit -> unit) -> on_result:(Mcp_protocol.Mcp_types.tool_result -> unit) -> authorize:Lane_addon_call_context.mediation option -> principal:Lane_addon_call_context.principal option ->
  config:Workspace.config -> access:Lane_addon_sources.access -> reserved:string list ->
  export:tool_export -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, tool_call_error) result
(** Trusted host boundary only: principal must come from host admission,
    never from caller-supplied tool arguments. [access] still controls visibility.
    [on_result] records replies under worker RPC serialization. [on_complete]
    runs on the owner domain after mediation unwinds, including cancellation;
    caller cancellation alone does not run it. Both callbacks must be synchronous
    and must not publish effects or acquire credential admission. *)
val call_exported_tool_with_principal : principal:Lane_addon_call_context.principal option ->
  config:Workspace.config -> access:Lane_addon_sources.access -> reserved:string list ->
  export:tool_export -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, tool_call_error) result
(** Trusted host boundary only: principal must come from verified credentials,
    never from caller-supplied tool arguments. [access] still controls visibility. *)
type browser_service = private {instance_id:string;owner:Lane_addon_tool_export.owner}
val browser_services : config:Workspace.config -> access:Lane_addon_sources.access -> browser_service list
type browser_service_status = Browser_ready of browser_service
  | Browser_refresh_needed of browser_service | Browser_unavailable | Browser_retired
val browser_service_status : config:Workspace.config -> access:Lane_addon_sources.access ->
  instance_id:string -> browser_service_status
(** Inventory absence is not retirement. Failed/not-ready workers remain
    unavailable; a worker with failed observations retains its exact connection
    for result settlement. [Observe] requests recovery when its loop is running.
    Stopping/detached authority proves retirement. A retained
    record must be readable, visible and explicitly detached before it can
    retire a client after live handles are gone. *)
val call_browser_service : config:Workspace.config -> access:Lane_addon_sources.access ->
  service:browser_service -> command:Browser_addon_wire.command ->
  (Browser_addon_wire.reply, Browser_addon_client.error) result
(** Trusted host transport boundary, not a Keeper tool. The server first admits
    the caller and pins host registrations to this original handle. Every call
    revalidates visibility and exact connection ownership on the owner domain;
    no replacement lookup or retry. Selected tool middleware belongs at the
    eventual browser tool bridge, before this low-level transport boundary. *)
val call_exported_tool : config:Workspace.config -> access:Lane_addon_sources.access ->
  reserved:string list -> export:tool_export -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, tool_call_error) result
(** Revalidates the exact installation and schema at invocation. Reattachment
    cannot redirect a handle retained by an earlier Keeper turn. *)

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
    Returned declaration metadata includes the exact [source_revision] and a
    typed [application] observation. Operator Inspect recomputes this observation
    from live and retained owners without triggering reconciliation or cleanup.
    Non-operator callers receive an Unknown application observation; new worker
    identity/error details are operator-only.
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
(** Why one retained binding record cannot be read. [Store_unreadable] is a
    file or directory the store could not read; the others describe a record
    that was read and does not parse. *)
type retained_fault_reason =
  | Store_unreadable of string
  | Read_authority_absent
  | Visibility_invalid
  | Source_access_invalid
  | Record_invalid of string
val retained_fault_message : retained_fault_reason -> string
type retained_owner = Owned_by of configuration_owner | Unowned | Owner_unreadable
(** Whose record it is. [Unowned] is a manual attach, which belongs to no
    declaration. [Owner_unreadable] is a record whose configuration cannot be
    read, so it could belong to any declaration. *)
type inventory_issue = {
  issue_path : string;
  issue_owner : retained_owner;
  issue_terminal : bool;
  issue_reason : retained_fault_reason;
}
(** One retained record the inventory could not list. [issue_owner] is the
    owner the record names. [issue_terminal] is true for a detached record that
    names its declaration: it holds no worker, so nothing waits on it. *)
type inventory = {
  owner_present : bool;
  instances : inventory_instance list;
  issues : inventory_issue list;
  complete : bool;
}
val inventory : config:Workspace.config -> inventory
(** Operator-only metadata source; the HTTP caller must enforce CanAdmin.
    Runs live reads on the existing owner domain and offloads retained file reads.
    Does not create a manager/store, start workers, reconcile or clean resources.
    [owner_present=false] means no manager has been observed in this process,
    not that there are no retained bindings or declarations. *)
val read_declaration : ?access:Lane_addon_sources.access -> config:Workspace.config -> Yojson.Safe.t ->
  (Yojson.Safe.t, Lane_addon_declaration.error) result
val save_declaration : ?access:Lane_addon_sources.access -> config:Workspace.config -> Yojson.Safe.t ->
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
  val with_cleanup_writer :
    (store:Lane_addon_store.t -> instance_id:string -> Yojson.Safe.t option ->
      (unit, string) result) -> (unit -> 'a) -> 'a
  (** Terminal historical cleanup persistence. [None] removes a never-started
      binding; [Some json] persists its final phase. Captured before offload. *)
  type host_port = {
    list_requests : unit -> (Yojson.Safe.t, string) result;
    deliver : arguments:Yojson.Safe.t -> (Yojson.Safe.t, string) result;
  }
  (** A worker's two private host request tools, answers undecoded. *)
  type connection = {
    observe : binding:Yojson.Safe.t -> sources:Yojson.Safe.t ->
      (Lane_addon_types.output, string) result;
    exported_tools : unit -> Mcp_protocol.Mcp_types.tool list;
    call_exported_tool : on_result:(Mcp_protocol.Mcp_types.tool_result -> unit) -> authorize:Lane_addon_call_context.mediation option -> principal:Lane_addon_call_context.principal -> name:string -> arguments:Yojson.Safe.t ->
      (Mcp_protocol.Mcp_types.tool_result, Lane_addon_call_context.invocation_error) result;
    action_schema : unit -> Yojson.Safe.t option;
    act : arguments:Yojson.Safe.t -> (Lane_addon_action.package_result, string) result;
    stop : unit -> (Lane_addon_lifecycle.release, Lane_addon_lifecycle.failure) result;
    resource : Lane_addon_lifecycle.resource;
    browser : Browser_addon_client.t option;
    host : host_port option;
  }
  type backend = {
    start : sw:Eio.Switch.t -> state_owner:Lane_addon_worker_state.owner option -> instance_id:string -> installation_id:string -> package:Lane_addon_types.package -> binding:Yojson.Safe.t ->
      on_authority:(Lane_addon_lifecycle.authority -> (unit, string) result) ->
      is_live_instance:(string -> bool) ->
      on_created:(connection -> unit) -> (connection, Lane_addon_lifecycle.failure) result;
    (** [on_authority] durably records the container engine or the host-selected
        native admission before starting the payload. A resource observation
        cannot substitute for this authority. *)
    acquire : access:Lane_addon_sources.access -> store:Lane_addon_store.t -> package:Lane_addon_types.package ->
      resolve_machine_output:(Machine_lane.t -> (Lane_addon_sources.machine_output, string) result) ->
    resolve_lane_output:(installation_id:string -> (Lane_addon_sources.lane_output, string) result) ->
      binding:Yojson.Safe.t -> (Yojson.Safe.t, string) result;
    recover_stop : state_owner:Lane_addon_worker_state.owner option -> instance_id:string ->
      authority:Lane_addon_lifecycle.authority -> resource:Lane_addon_lifecycle.resource option ->
      (Lane_addon_lifecycle.release, Lane_addon_lifecycle.failure) result;
    (** [Ok] names the recorded container engine that confirmed release, or the
        exact native installation and incarnation whose admission settled. *)
    package_ready : package:Lane_addon_types.package -> (unit, string) result;
    condition_met : runtime:Lane_addon_types.runtime -> Lane_addon_lifecycle.condition -> bool;
    (** Whether a waiting failure's condition holds now. False also when it
        cannot be established. *)
    sweep : runtime:Lane_addon_types.runtime -> is_live_instance:(string -> bool) ->
      (Lane_addon_slot.sweep_item list, Lane_addon_lifecycle.failure) result;
    (** Removes the containers of this base path that no live incarnation
        owns; run once per runtime after its engine answers. *)
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

type export_observation = {
  instance_id : string;
  observation_seq : int;
  max_bytes : int;
  refreshing : bool;
  output : Lane_addon_types.output;
}
val observation_for_export :
  config:Workspace.config -> access:Lane_addon_sources.access -> name:string ->
  (export_observation option, string) result
(** Read the last completed observation of the visible installation exporting
    [name], without an RPC or starting a worker. No installation is [None];
    ambiguous, failed or not-yet-observed installations are errors. *)
