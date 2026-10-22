(** Optional observers run in independent server-owned fibers. No Keeper tool
    set, input queue, turn switch or environment owner is replaced. *)
type operation = Attach | Inspect | Observe | Detach | Retain | Slice | Evidence | Act | Action_status
(** [Retain] is the operator's alone. It takes over the resources of a native
    instance that failed because its cleanup was not confirmed, once the host
    confirms its admission and browser child claims settled. The instance
    becomes detached with [Native_retained], its leftover files stay in place,
    and its declaration may start a new instance. Any other caller, state or
    authority is refused without a change. *)
type error = Request_rejected of string | Runtime_failed of string
val error_to_string : error -> string
val register_delivery_handler :
  (config:Workspace.config -> caller:string -> keeper_name:string -> prompt:string ->
    (Yojson.Safe.t, string) result) -> unit
val register_exact_runner : authorize_request:Lane_addon_exact.execution_authority -> Lane_addon_exact.runner -> unit
(** Server-owned runner and mandatory host execution authority for packages'
    exact-output requests, registered together before
    configuration maintenance. The authority binds the pure output validator
    and typed admission class to the original request; worker data cannot select
    provider priority. Without it a declared installation's exact
    request ends its host request cycle with [no_exact_runner]. Retirement
    cancels its current exact call independently of worker cleanup; a pending
    provider outcome is not replayed and no later request is dispatched. *)
val register_github_reader : Lane_addon_records.github -> unit
(** Server-owned GitHub access for [github_pulls] record grants, registered
    before configuration maintenance. Until then such a read waits as
    [source_unavailable]. *)
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
type owner_event = Export_inventory_changed | Configuration_observed
  | Exact_result_delivered of { installation_id:string; instance_id:string; request_id:string }
val subscribe_owner_events : config:Workspace.config -> package_id:string ->
  (owner_event -> unit) -> (unit -> unit)
(** Ephemeral hints scoped to this served workspace Store root and package.
    Keeps the MCP tool-change bridge intact. The callback must synchronously
    signal its existing owner only: no I/O, yield or Runtime/worker lock entry.
    Callbacks run outside the subscription lock; lifecycle publishers can hold
    their own locks. Registration does not replay state or start a worker; the
    owner keeps its initial drain and strictly reloads original authority.
    Configuration signals follow actual matching metadata publication, not
    every reconciliation. Result signals require the original Exact request's
    accepted=true reply, after the worker RPC lock has unwound; they are not
    provider completion or domain commit receipts. Observer failure/cancellation
    is isolated; publisher's own cancellation propagates. The returned closure
    idempotently removes only this registration. Fence the original owner before
    unsubscribe, since a copied callback snapshot can still be delivered. *)

type tool_export = Lane_addon_tool_export.t = private
  { owner : Lane_addon_tool_export.owner; instance_id : string; tool : Mcp_protocol.Mcp_types.tool }
type tool_call_error = Unavailable of string | Outcome_unknown of string
  | Host_refusal of Lane_addon_call_context.host_refusal
type export_reading = { exports : tool_export list; unready : Lane_addon_unready.t list }
(** The usable exports and, from the same read, every visible non-detached
    installation that cannot serve now. A caller that finds no export for a
    name reports its declaring [unready] installations instead of absence. *)
type export_snapshot = {
  exports : tool_export list;
  conflicts : Lane_addon_tool_export.conflict list;
  unready : Lane_addon_unready.t list;
}
val tool_export_snapshot : config:Workspace.config -> access:Lane_addon_sources.access ->
  reserved:string list -> export_snapshot
(** Live export snapshot with individual name conflicts quarantined. *)
val tool_export_reading : config:Workspace.config -> access:Lane_addon_sources.access ->
  reserved:string list -> (export_reading, string) result
(** Reads initialized live workers only; does not start or recover installations.
    The caller supplies the complete reserved host namespace. Collisions fail
    explicitly. Visibility follows verified caller authority; an installation
    the caller cannot read is in neither list. *)
val retain_tool_request_owner : config:Workspace.config -> access:Lane_addon_sources.access ->
  reserved:string list -> export:tool_export -> scope:string -> request_id:string -> request:Yojson.Safe.t ->
  (unit, tool_call_error) result
(** Trusted host consumer boundary, before any RPC for an original request.
    Durably binds its scope/ID and captured request to this logical installation,
    package and tool. A restarted worker on that installation retains ownership;
    a replacement installation cannot claim absence and cause redispatch.
    Current export authority is checked here and still rechecked by each call.
    This binding neither executes work nor uses an observer receipt as authority. *)
type tool_request_destination = private {
  installation_id : string;
  package_id : string;
  tool : string;
  source_revision : string;
  configuration_revision : string;
  max_reply_bytes : int;
  (** The destination package's declared worker frame. Arguments the host
      sends this destination must measure at most this many
      {!Lane_addon_host_delivery.arguments_bytes}. *)
}
val with_tool_request_destination : config:Workspace.config -> access:Lane_addon_sources.access ->
  reserved:string list -> export:tool_export ->
  publish:(tool_request_destination -> ('a, tool_call_error) result) ->
  ('a, tool_call_error) result
(** Trusted host publication of new configured work. Hold configuration then
    action serialization; strictly reread the actual complete declaration set
    and revalidate its enabled state, semantic revision, package and live export
    before invoking [publish]. A committed Off/save cannot borrow a stale cached
    reconciliation. The callback may yield only for local original journal
    publication/recovery, never call Runtime or execute a worker/model/domain
    effect. It runs cancellation-protected after lock acquisition; exceptions
    release the locks without poisoning the shared action serializer. An error
    may follow publication, requiring strict original recovery. The destination
    is not authority for an effect after the callback returns. *)
val capture_tool_request_owner : config:Workspace.config -> access:Lane_addon_sources.access ->
  reserved:string list -> export:tool_export -> scope:string -> request_id:string ->
  capture:(tool_request_destination -> ('a * Yojson.Safe.t, string) result) ->
  ('a, tool_call_error) result
(** New configured work only. Under the shared configuration/action serializers,
    revalidate the live export and freshly read enabled declaration, invoke the pure host
    capture factory with its original destination/revisions, and durably retain
    that exact JSON before returning the host value. The callback must not yield,
    perform effects or call Runtime. A failed publication may already be visible;
    discover the original ID rather than minting another one. This does not
    dispatch, commit or authorize a later RPC. Manual/missing/conflicting
    configuration is refused rather than supplying invented revisions. *)
val call_exported_tool_with_authority : on_complete:(unit -> unit) -> on_result:(Mcp_protocol.Mcp_types.tool_result -> unit) -> authorize:Lane_addon_call_context.mediation option -> principal:Lane_addon_call_context.principal option ->
  config:Workspace.config -> access:Lane_addon_sources.access -> reserved:string list ->
  export:tool_export -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, tool_call_error) result
(** Trusted host boundary only: principal must come from host admission,
    never from caller-supplied tool arguments. [access] still controls visibility.
    [on_result] records replies under worker RPC serialization. [on_complete]
    runs on the owner domain after mediation unwinds, including cancellation;
    caller cancellation alone does not run it. Both callbacks must be synchronous
    and must not publish effects or acquire credential admission. A completed
    worker reply also schedules observation and, when this worker has host
    requests, a host cycle. This includes worker error replies that may follow
    a durable state change; host admission refusals do not trigger a cycle. *)
val call_exported_tool_with_principal : principal:Lane_addon_call_context.principal option ->
  config:Workspace.config -> access:Lane_addon_sources.access -> reserved:string list ->
  export:tool_export -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, tool_call_error) result
(** Trusted host boundary only: principal must come from verified credentials,
    never from caller-supplied tool arguments. [access] still controls visibility. *)
type browser_service = private {instance_id:string;owner:Lane_addon_tool_export.owner}
type browser_reading = { services : browser_service list; unready : Lane_addon_unready.t list }
val browser_service_reading : config:Workspace.config -> access:Lane_addon_sources.access -> browser_reading
(** Usable browser services and, from the same read, the visible browser
    installations that cannot serve now. *)
val browser_services : config:Workspace.config -> access:Lane_addon_sources.access -> browser_service list
(** The services of {!browser_service_reading}. *)
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
    no replacement lookup or retry. Pending-upload discard remains available on
    that original failed connection for settlement; staging and input do not.
    Selected tool middleware belongs at the
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
val check_retained_binding : Yojson.Safe.t -> (unit, string) result
(** The reads configuration application, Inspect and restart recovery make of
    one retained binding record (its instance id and sequence, then
    [parse_retained_binding]), judged as configuration application judges a
    fault. A record that names its declaration and is detached is [Ok] even
    when it does not parse: no declaration waits on it and its fields stay
    evidence. A per-instance read of that one instance (Inspect by id, Observe,
    Detach, the evidence freeze) still refuses it. Reads and writes nothing. *)
val check_inventory_record : path:string -> Yojson.Safe.t -> (unit, string) result
(** The record decoder {!inventory} applies to the retained binding file at
    [path], including its filename identity, with the same exemption for a
    detached record that names its declaration. Reads and writes nothing. *)
val native_claims_directory : string
(** The directory below the Lane Add-on store root that holds the native claim
    slots. *)
type native_claim_slot = Installation_slot | Chrome_child_slot | Live_bidi_child_slot
(** Who reads a native claim slot: the host recovering an installation reads
    its cleanup descriptor through {!Browser_addon_socket}; a Chrome or live
    BiDi child slot is compared with the descriptor its parent recomputes. *)
val native_claim_slot_of_name : string -> native_claim_slot option
(** The slot a directory name below {!native_claims_directory} names, as this
    module creates it; [None] for a name it never creates. *)
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
type configuration_application = {
  owner : configuration_owner;
  source_revision : string;
  enabled : bool;
  application : Lane_addon_application.t;
}
(** Application observed against the original reconciled declaration, including
    its file bytes and desired package/binding revision. A newer file must not
    borrow this observation merely because its installation ID is unchanged. *)
type inventory = {
  owner_present : bool;
  instances : inventory_instance list;
  issues : inventory_issue list;
  complete : bool;
  applications : configuration_application list;
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

val answer_installation_question :
  config:Workspace.config -> declaration_id:string -> ask_id:string ->
  submissions:(string * Keeper_ask.response) list -> responder:Keeper_ask.responder ->
  (Keeper_ask.answer list, Lane_addon_asks.answer_failure) result
(** Records the operator's answer to an installation's question (RFC
    operator-quiz §4.6) and, when it is recorded, starts a host request cycle
    of the installation's live instance. A worker that is down receives the
    answer when it lists the question again. *)

(** Why a scheduled action was not handed over (RFC operator-quiz §4.7). *)
type scheduled_act_refusal =
  | Declarations_unread
      (** This process has not read the declarations yet. *)
  | Declarations_incomplete
      (** A declaration, or a retained record that may be this declaration's,
          could not be read, so an earlier receipt may be unseen. *)
  | Declaration_missing
  | Declaration_disabled
  | No_live_instance
      (** Declared and enabled, and no worker is running. *)
  | Request_id_reused
      (** A receipt with this request id holds another requester or action. *)
  | Action_refused of string
      (** The worker's action port, its schema or the caller's access refused it. *)
type scheduled_act_error =
  | Scheduled_act_refused of scheduled_act_refusal
  | Scheduled_act_failed of string  (** A store read or write failed. *)
val scheduled_act_refusal_label : scheduled_act_refusal -> string

val scheduled_act :
  config:Workspace.config -> access:Lane_addon_sources.access -> requester:string ->
  declaration_id:string -> request_id:string -> action:Yojson.Safe.t ->
  (Lane_addon_action.receipt, scheduled_act_error) result
(** Hands [action] to the declaration's live worker through the [Act]
    operation, with [request_id] as the receipt's request id. A receipt with
    the same request id under any instance the declaration owned is returned
    instead, after the read writes its terminal when no live worker owns it. *)

val installation_questions :
  config:Workspace.config -> ((string * Lane_addon_asks.row list) list, string) result
(** Every declaration's questions, by declaration id, in the order asked. *)

type host_issue =
  | Listing_failed of string
  | Listing_refused of string
  | Relisted_delivered_request of string
  | Result_delivery_failed of { request_id : string; detail : string }
  | Exact_record_failed of { request_id : string; detail : string }
  | Ask_record_failed of { request_id : string; detail : string }
  | No_exact_runner
(** What stopped an instance's last host request cycle (RFC operator-quiz
    §4.4). A detail is the failure's own text and may be blank. *)

val host_issue_to_json : host_issue -> Yojson.Safe.t
(** The [issue] of an instance's [host_requests] in the inspect payload. *)

module For_testing : sig
  val with_tool_change_handler : (unit -> unit) -> (unit -> 'a) -> 'a
  (** Temporarily observe the original MCP bridge without replacing owner
      subscriptions; restores the preceding handler on exit. *)
  val with_cleanup_writer :
    (store:Lane_addon_store.t -> instance_id:string -> Yojson.Safe.t option ->
      (unit, string) result) -> (unit -> 'a) -> 'a
  (** Terminal historical cleanup persistence. [None] removes a never-started
      binding; [Some json] persists its final phase. Captured before offload. *)
  type host_port = {
    list_requests : unit -> (Yojson.Safe.t, string) result;
    deliver : arguments:Yojson.Safe.t -> (Yojson.Safe.t, string) result;
    await_change : (after:string option -> (Lane_addon_host_request.availability, string) result) option;
  }
  (** A worker's private host request tools and optional change-event port.
      The event port is independent of a command waiting on its model. *)
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
    resolved_image : Lane_addon_engine.image_identity option;
    (** [Some] is the pre-create container image resolution, retained separately
        from start success. [None] means this is a native host process. *)
    host : host_port option;
    (** [Some] for a package that waits on the host. *)
    browser : Browser_addon_client.t option;
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
    read_browser_document:(route:Browser_lane.route -> tab_id:int -> (Browser_lane.answer, string) result) ->
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
(** Why the observation of an export cannot be read now. *)
type export_refusal =
  | Unready_installations of Lane_addon_unready.t * Lane_addon_unready.t list
      (** The visible installation exporting the name cannot serve, or every
          one that does is detaching with no replacement serving. *)
  | Not_yet_observed of { installation : string; package_id : string }
      (** The serving installation has not completed an observation yet. *)
  | Ambiguous_installations of string list
      (** More than one visible installation serves the name. *)
val export_refusal_message : export_refusal -> string
(** The refusal for any caller; see {!Lane_addon_unready.message}. *)
val export_refusal_operator_message : export_refusal -> string
(** The refusal with each failure rendered, for a surface that serves the
    operator alone; see {!Lane_addon_unready.operator_message}. *)
val observation_for_export :
  config:Workspace.config -> access:Lane_addon_sources.access -> name:string ->
  (export_observation option, export_refusal) result
(** Read the last completed observation of the visible installation exporting
    [name], without an RPC or starting a worker. No installation is [None];
    the refusal tells a starting or failed installation from one that is
    serving and not yet observed, and from an ambiguous name. *)
