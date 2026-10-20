open Lane_addon_types
module Fleet_ledger = Lane_addon_broadcast_delivery
module Lifecycle = Lane_addon_lifecycle
let ( let* ) = Result.bind
type operation = Attach | Inspect | Observe | Detach | Slice | Evidence | Act | Action_status
type error = Request_rejected of string | Runtime_failed of string
type evidence_destination = Preserve_only | To_keeper of string | To_broadcast
type evidence_delivery = Delivery_receipt of Yojson.Safe.t | Delivery_failed of string
  | Delivery_outcome_unknown of string | Delivery_pending_commit of string
let error_to_string = function Request_rejected detail | Runtime_failed detail -> detail
let request_result result = Result.map_error (fun detail -> Request_rejected detail) result
let runtime_result result = Result.map_error (fun detail -> Runtime_failed detail) result
exception Fleet_commit_uncertain of string
exception Fleet_commit_pending of string
exception Worker_detached
exception Action_persistence_failed of string
type tool_export = Lane_addon_tool_export.t = private
  { owner : Lane_addon_tool_export.owner; instance_id : string; tool : Mcp_protocol.Mcp_types.tool }
type tool_call_error = Unavailable of string | Outcome_unknown of string
  | Host_refusal of Lane_addon_call_context.host_refusal
let tool_change_handler = ref (fun () -> ())
let register_tool_change_handler handler = tool_change_handler := handler
let notify_tool_change (package : package) =
  if package.exported_tools <> [] then !tool_change_handler ()
(* The two private tools of a worker whose package waits on the host (RFC
   operator-quiz §4.4). Their answers are decoded by the cycle. *)
type host_port = {
  list_requests : unit -> (Yojson.Safe.t, string) result;
  deliver : arguments:Yojson.Safe.t -> (Yojson.Safe.t, string) result;
}
type connection = {
  observe : binding:Yojson.Safe.t -> sources:Yojson.Safe.t -> (output, string) result;
  exported_tools : unit -> Mcp_protocol.Mcp_types.tool list;
  call_exported_tool : on_result:(Mcp_protocol.Mcp_types.tool_result -> unit) -> authorize:Lane_addon_call_context.mediation option -> principal:Lane_addon_call_context.principal -> name:string -> arguments:Yojson.Safe.t ->
    (Mcp_protocol.Mcp_types.tool_result, Lane_addon_call_context.invocation_error) result;
  action_schema : unit -> Yojson.Safe.t option;
  act : arguments:Yojson.Safe.t -> (Lane_addon_action.package_result, string) result;
  stop : unit -> (Lifecycle.release, Lifecycle.failure) result;
  resource : Lifecycle.resource;
  host : host_port option;
}
type backend = {
  start : sw:Eio.Switch.t -> state_owner:Lane_addon_worker_state.owner option -> instance_id:string -> installation_id:string -> package:package -> binding:Yojson.Safe.t ->
    on_authority:(Lifecycle.authority -> (unit, string) result) ->
    is_live_instance:(string -> bool) ->
    on_created:(connection -> unit) -> (connection, Lifecycle.failure) result;
  (* [is_live_instance] names incarnations still owned by this process.
     [on_authority] persists the exact container engine or native installation
     admission before payload creation. *)
  acquire : access:Lane_addon_sources.access -> store:Lane_addon_store.t -> package:package ->
    resolve_machine_output:(Machine_lane.t -> (Lane_addon_sources.machine_output, string) result) ->
    resolve_lane_output:(installation_id:string -> (Lane_addon_sources.lane_output, string) result) ->
    binding:Yojson.Safe.t ->
    (Yojson.Safe.t, string) result;
  recover_stop : state_owner:Lane_addon_worker_state.owner option -> instance_id:string ->
    authority:Lifecycle.authority -> resource:Lifecycle.resource option -> (Lifecycle.release, Lifecycle.failure) result;
  (* The release receipt must match the original recorded execution authority. *)
  package_ready : package:package -> (unit, string) result;
  condition_met : runtime:runtime -> Lifecycle.condition -> bool;
  (* A waiting failure is re-examined through this one cheap read. False also
     when the condition cannot be established. *)
  sweep : runtime:runtime -> is_live_instance:(string -> bool) ->
    (Lane_addon_slot.sweep_item list, Lifecycle.failure) result;
  (* Removes the containers of this base path that no live incarnation owns. *)
}
type owned_connection =
  { export_owner : Lane_addon_tool_export.owner
  ; worker : connection
  }
type configuration_owner = { id : string; source_path : string; revision : string }
type inventory_presence = Live | Retained
type inventory_instance = {
  instance_id : string; incarnation : string; run_id : string;
  package_id : string; title : string; package_revision : string;
  configuration : configuration_owner option;
  presence : inventory_presence; phase : phase;
}
(* Why one retained binding record cannot be read. [Store_unreadable] is a
   file or directory the store could not read; the others describe a record
   that was read and does not parse. *)
type retained_fault_reason =
  | Store_unreadable of string
  | Read_authority_absent
  | Visibility_invalid
  | Source_access_invalid
  | Record_invalid of string
(* Whose record it is, as far as the record says. [Unowned] is a record whose
   configuration is null: a manual attach, which belongs to no declaration.
   [Owner_unreadable] is a record whose configuration cannot be read, so it
   could belong to any declaration. *)
type retained_owner = Owned_by of configuration_owner | Unowned | Owner_unreadable
(* One retained record the inventory could not list. [issue_owner] is the
   owner the record names. *)
type inventory_issue = {
  issue_path : string;
  issue_owner : retained_owner;
  issue_terminal : bool;
  issue_reason : retained_fault_reason;
}
type inventory = {
  owner_present : bool; instances : inventory_instance list;
  issues : inventory_issue list; complete : bool;
}
type visibility = Shared | Operator_only | Keeper_only of string
type skill_export_owner = Declaration of string | Instance of string
type skill_export = { owner : skill_export_owner; instance_id : string; package : package }
let skill_source_id = function
  | Declaration id -> "lane-" ^ Digestif.SHA256.(to_hex (digest_string ("declaration\x00" ^ id)))
  | Instance id -> "lane-" ^ Digestif.SHA256.(to_hex (digest_string ("instance\x00" ^ id)))
let skill_export_handler = ref None
let register_skill_export_handler handler = skill_export_handler := Some handler
(* [Run_actions] serves the action queue only. An action commits the
   package's own result output; it does not stand in for an observation
   request, so a wake raised for an action never schedules a second capture
   of the same state. *)
type observation_request = Idle | Run_actions | Refresh_sources | Observe_now
(* Why the last host request cycle stopped before its listing settled. *)
type host_issue =
  | Listing_failed of string
  | Listing_refused of string
  | Relisted_delivered_request of string
  | Result_delivery_failed of { request_id : string; detail : string }
  | Exact_record_failed of { request_id : string; detail : string }
  | Ask_record_failed of { request_id : string; detail : string }
  | No_exact_runner
(* A projection of the last cycle; no decision reads it. *)
type host_status = { cycles : int; waiting : (string * Yojson.Safe.t) list; issue : host_issue option }
type entry = {
  instance_id : string; run_id : string; package : package; binding : Yojson.Safe.t;
  mutable state : Lifecycle.state; mutable authority : Lifecycle.authority option;
  mutable seq : int; mutable output : output;
  mutable connection : owned_connection option; mutable stopping : bool;
  mutable cleanup_running : bool; changed : Eio.Condition.t; mutable wake : unit Eio.Promise.t;
  mutable resolver : unit Eio.Promise.u; mutable pending : observation_request;
  refresh_interest : Lane_addon_sources.refresh_interest;
  source_access : Lane_addon_sources.access;
  visibility : visibility;
  mutable last_committed_sources : string option;
  mutable unchanged_source_refreshes : int;
  mutable running : bool; mutable started : bool; mutable active_tool_calls : int; persistence_mutex : Eio.Mutex.t;
  mutable coalesced_wakes : int;
  mutable cancel_worker : (unit -> unit) option;
  mutable configuration : configuration_owner option;
  input_installations : string list;
  action_queue : Lane_addon_action.receipt Queue.t;
  mutable current_action : Lane_addon_action.receipt option;
  mutable host_due : bool;
  mutable host_status : host_status;
}
type configuration_reading = {
  directory : string;
  snapshot : Lane_addon_config.snapshot;
  issues : Lane_addon_config.issue list;
}
type cleanup_publication = {
  fields : (string * Yojson.Safe.t) list;
  terminal : Yojson.Safe.t option;
  terminal_state : Lifecycle.state;
}
type recovery =
  | Cleaning of (string * Yojson.Safe.t) list
  | Cleanup_request_failed of (string * Yojson.Safe.t) list * string
  | Cleanup_unconfirmed of (string * Yojson.Safe.t) list * string
  | Publishing_cleanup of cleanup_publication
  | Cleanup_commit_failed of cleanup_publication * string
let phase_of (e : entry) = Lifecycle.project e.state
let is_detached = function
  | Lifecycle.Detached _ -> true
  | Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Failed _ | Lifecycle.Detaching _ -> false

type sweep_retry = {
  container_id : string;
  instance : string option;
  failure : Lifecycle.failure;
  first_refused_at : string;
}

type manager = { store : Lane_addon_store.t; base_path : string; entries : (string, entry) Hashtbl.t;
  recovering : (string, recovery) Hashtbl.t;
  configuration_mutex : Eio.Mutex.t; action_mutex : Eio.Mutex.t; broadcast_mutex : Eio.Mutex.t;
  fleet_journals : (string, unit) Hashtbl.t;
  fleet_operations : ((string * string), unit) Hashtbl.t;
  fleet_recipients : (((string * string) * string), unit) Hashtbl.t; mutable fleet_nudge : unit -> unit; mutable configuration_status : configuration_reading option;
  mutable configuration_nudge : unit -> unit;
  mutable configuration_visibility : (string * visibility) list;
  mutable swept : runtime list;
  sweep_retries : (runtime, sweep_retry list) Hashtbl.t;
  sweep_warned : (runtime, (string * string option * Lifecycle.failure) list) Hashtbl.t }
let managers : (string, manager) Hashtbl.t = Hashtbl.create 4
let override : backend option ref = ref None
type fleet_backend = {
  snapshot : config:Workspace.config -> caller:string -> access:Lane_addon_sources.access -> (Lane_addon_broadcast_delivery.sender_authority * string list,string) result;
  project : config:Workspace.config -> sender_authority:Lane_addon_broadcast_delivery.sender_authority -> delivery:Workspace_broadcast.broadcast_delivery ->
    recipient:string -> (unit,string) result;
}
let fleet_backend = ref None
let register_fleet_backend backend = fleet_backend := Some backend
let delivery_handler = ref None
let register_delivery_handler handler = delivery_handler := Some handler
let sampling_factory = ref None
let register_sampling_factory factory = sampling_factory := Some factory
let exact_runner : Lane_addon_exact.runner option ref = ref None
let register_exact_runner runner = exact_runner := Some runner
let github_reader : Lane_addon_records.github ref = ref (fun ~repository_id:_ -> Error "this host has no GitHub reader")
let register_github_reader reader = github_reader := reader
let prepare_sampling_handler ~sw ~store ~instance_id ~(package : package) ~binding =
  match package.model_access with
  | Model_disabled -> Ok None
  | Host_sampling ->
      let* factory = match !sampling_factory with Some factory -> Ok factory
        | None -> Error "host sampling runtime is unavailable" in
      factory ~sw ~store ~instance_id ~package ~binding |> Result.map Option.some
let text fields key = match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> Error (key ^ " requires a non-blank string")
let object_ = function `Assoc fields -> Ok fields | _ -> Error "expected an object"
let retained_runtime fields = match List.assoc_opt "runtime" fields with
  | Some (`String "host_process") -> Ok None
  | Some (`String value) -> Option.to_result ~none:"invalid retained runtime" (runtime_of_string value) |> Result.map Option.some
  | None -> Ok (Some Docker)
  | Some _ -> Error "invalid retained runtime"
let offload f = Eio_unix.run_in_systhread f
let configuration_owner_json (owner : configuration_owner) =
  `Assoc ["id", `String owner.id; "source_path", `String owner.source_path;
    "revision", `String owner.revision]
let configuration_of_fields fields =
  match List.assoc_opt "configuration" fields with
  | None | Some `Null -> Ok None
  | Some value ->
      let* fields = object_ value in
      let* id = text fields "id" in let* source_path = text fields "source_path" in
      let* revision = text fields "revision" in Ok (Some {id; source_path; revision})
let state_owner_for ~store ~instance_id ~package_id ~configuration state_storage =
  match state_storage with
  | Ephemeral -> Ok None
  | Persistent ->
      let installation_id = Yojson.Safe.to_string (match configuration with
        | Some (owner : configuration_owner) -> `List [`String "configuration"; `String owner.id]
        | None -> `List [`String "manual"; `String instance_id]) in
      offload (fun () -> Lane_addon_worker_state.create_owner
        ~workspace_root:(Lane_addon_store.root store) ~installation_id ~package_id)
      |> Result.map Option.some

let state_owner_for_entry m (e : entry) =
  state_owner_for ~store:m.store ~instance_id:e.instance_id ~package_id:e.package.id
    ~configuration:e.configuration e.package.state_storage

let visibility_to_json = function
  | Shared -> `Assoc ["kind", `String "shared"]
  | Operator_only -> `Assoc ["kind", `String "operator"]
  | Keeper_only keeper -> `Assoc ["kind", `String "keeper"; "keeper", `String keeper]
let visibility_of_fields fields =
  let* () = if List.length (List.filter (fun (key, _) -> String.equal key "visibility") fields) = 1
    then Ok () else Error "missing or duplicate retained read visibility" in
  let* value = match List.assoc_opt "visibility" fields with
    | Some value -> object_ value | None -> Error "missing retained read visibility" in
  match List.sort (fun (a, _) (b, _) -> String.compare a b) value with
  | ["kind", `String "shared"] -> Ok Shared
  | ["kind", `String "operator"] -> Ok Operator_only
  | ["keeper", `String keeper; "kind", `String "keeper"] when String.trim keeper <> "" -> Ok (Keeper_only keeper)
  | _ -> Error "invalid retained read visibility"
let can_read access = function
  | Shared -> true
  | Operator_only -> (match access with Lane_addon_sources.Operator_configuration -> true
      | Keeper _ | Unauthenticated -> false)
  | Keeper_only owner -> (match access with
      | Lane_addon_sources.Operator_configuration -> true
      | Keeper keeper -> String.equal owner keeper | Unauthenticated -> false)
let require_read access visibility =
  if can_read access visibility then Ok () else Error "Lane instance is unavailable to this caller"
let rec unique_json = function
  | `Assoc fields ->
      let* () = Json_util.reject_unknown_fields ~surface:"retained binding" ~allowed:(List.map fst fields) fields in
      List.fold_left (fun result (_, value) -> let* () = result in unique_json value) (Ok ()) fields
  | `List values -> List.fold_left (fun result value -> let* () = result in unique_json value) (Ok ()) values
  | _ -> Ok ()
(* A retained binding names its own readers: [visibility] and [source_access]
   are written together by [entry_json]. A record that carries neither names
   no reader and is not read, retired or cleaned up. One unreadable record is
   a fault of that record; it never changes what any other record means. *)
let retained_fault_message = function
  | Store_unreadable detail | Record_invalid detail -> detail
  | Read_authority_absent -> "retained binding records neither read visibility nor source access"
  | Visibility_invalid -> "retained binding read visibility is missing, duplicated or unrecognized"
  | Source_access_invalid -> "retained binding source access is missing or unrecognized"
type retained_binding = {
  binding_fields : (string * Yojson.Safe.t) list;
  read_visibility : visibility;
  binding_owner : configuration_owner option;
}
(* [fault_fields] are the record's own fields, empty when the file was not an
   object. They stay readable so a record that is a terminal history of a
   declaration can still be checked for persistent state. *)
type retained_fault = {
  fault_instance : string option;
  fault_owner : retained_owner;
  fault_fields : (string * Yojson.Safe.t) list;
  fault_reason : retained_fault_reason;
}
type retained_reading = { readable : retained_binding list; faults : retained_fault list }
(* The lifecycle field is the typed state the runtime acts on; "phase" beside
   it is only its display projection. A record without the current lifecycle
   shape cannot be read as detached or as anything else. *)
let lifecycle_of_fields fields = match List.assoc_opt "lifecycle" fields with
  | Some json -> Lifecycle.state_of_json json
  | None -> Error "missing retained lifecycle"
let record_is_detached fields = match lifecycle_of_fields fields with
  | Ok (Lifecycle.Detached _) -> true
  | Ok (Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Failed _ | Lifecycle.Detaching _) | Error _ -> false
(* Cleanup authority is persisted before creating a container or starting a
   native payload. An observation of a resource does not grant authority. *)
let authority_of_fields fields = match List.assoc_opt "execution_authority" fields with
  | Some `Null -> Ok None
  | Some json -> Result.map Option.some (Lifecycle.authority_of_json json)
  | None -> Error "missing retained execution authority"
let resource_of_fields fields = match List.assoc_opt "resource" fields with
  | Some `Null -> Ok None
  | Some json -> Lifecycle.resource_of_json json |> Result.map Option.some
  | None -> Error "missing retained execution resource"
let retained_execution fields =
  let* authority = authority_of_fields fields in
  let* resource = resource_of_fields fields in
  let* () = match authority,resource with
    | None,None | Some _,None
    | Some (Lifecycle.Container_authority _),Some (Lifecycle.Container_resource _)
    | Some (Lifecycle.Native_admission _),Some (Lifecycle.Native_resource _) -> Ok ()
    | None,Some _ -> Error "retained resource has no execution authority"
    | Some (Lifecycle.Container_authority _),Some (Lifecycle.Native_resource _)
    | Some (Lifecycle.Native_admission _),Some (Lifecycle.Container_resource _) ->
        Error "retained resource differs from its execution authority" in
  Ok (authority,resource)
let failed_in fields = match lifecycle_of_fields fields with
  | Ok (Lifecycle.Failed failed) | Ok (Lifecycle.Detaching (Some failed)) -> Some failed
  | Ok (Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching None | Lifecycle.Detached _)
  | Error _ -> None
(* A record's next failure keeps the earliest different cause it already named. *)
let failed_after fields cause = Lifecycle.Failed (match failed_in fields with
  | Some previous -> Lifecycle.fail_again previous cause
  | None -> Lifecycle.failed cause)
let replace_state fields state =
  `Assoc (("phase", phase_to_json (Lifecycle.project state))
    :: ("lifecycle", Lifecycle.state_to_json state)
    :: List.remove_assoc "phase" (List.remove_assoc "lifecycle" fields))
(* A record belongs to a declaration when it names that installation id or
   that declaration file, the same identity [configuration_json] uses to
   attribute a worker. A record whose owner cannot be read could belong to any
   declaration; a record with no owner belongs to none. *)
let owner_concerns ~id ~source_path = function
  | Owned_by owner -> String.equal owner.id id || String.equal owner.source_path source_path
  | Owner_unreadable -> true
  | Unowned -> false
(* A record that names its declaration and is detached holds no worker and no
   container, so nothing waits on it even when it cannot be read. *)
let owner_is_terminal owner fields = match owner with
  | Owned_by _ -> record_is_detached fields
  | Unowned | Owner_unreadable -> false
let read_authority fields =
  match List.mem_assoc "visibility" fields, List.mem_assoc "source_access" fields with
  | false, false -> Error Read_authority_absent
  | true, true | true, false | false, true ->
      (match visibility_of_fields fields with
       | Error _ -> Error Visibility_invalid
       | Ok visibility ->
           (match List.assoc_opt "source_access" fields with
            | None -> Error Source_access_invalid
            | Some json -> (match Lane_addon_sources.access_of_json json with
                | Ok _ -> Ok visibility
                | Error _ -> Error Source_access_invalid)))
(* The owner of an unreadable record is read only to say whose declaration it
   belongs to. A configuration that is absent or null names no declaration; one
   that cannot be parsed could name any. *)
let owner_of_fields fields = match configuration_of_fields fields with
  | Ok (Some owner) -> Owned_by owner
  | Ok None -> Unowned
  | Error _ -> Owner_unreadable
let fault_of_fields fields reason = { fault_instance = Result.to_option (text fields "instance_id");
  fault_owner = owner_of_fields fields; fault_fields = fields; fault_reason = reason }
let parse_retained_binding = function
  | `Assoc fields ->
      (match read_authority fields with
       | Error reason -> Error (fault_of_fields fields reason)
       | Ok read_visibility ->
           (match configuration_of_fields fields with
            | Error detail -> Error (fault_of_fields fields (Record_invalid detail))
            | Ok binding_owner ->
                (match lifecycle_of_fields fields, retained_execution fields with
                 | Error detail, _ | _, Error detail -> Error (fault_of_fields fields (Record_invalid detail))
                 | Ok _, Ok _ -> Ok { binding_fields = fields; read_visibility; binding_owner })))
  | _ -> Error { fault_instance = None; fault_owner = Owner_unreadable; fault_fields = [];
      fault_reason = Record_invalid "expected an object" }
let fault_of_unreadable (unreadable : Lane_addon_store.unreadable_binding) =
  let located = unreadable.path ^ ": " ^ unreadable.detail in
  let unattributed reason = { fault_instance = None; fault_owner = Owner_unreadable;
    fault_fields = []; fault_reason = reason } in
  match unreadable.contents with
  | Some (`Assoc fields) -> fault_of_fields fields (Record_invalid located)
  | Some _ -> unattributed (Record_invalid located)
  | None -> unattributed (Store_unreadable located)
let split_retained values =
  let readable, faults = List.fold_left (fun (readable, faults) value ->
    match parse_retained_binding value with
    | Ok binding -> binding :: readable, faults
    | Error fault -> readable, fault :: faults) ([], []) values in
  { readable = List.rev readable; faults = List.rev faults }
let authorize_retained_read ~bindings ~access json =
  let* fields = object_ json in
  let* id = text fields "instance_id" in
  match List.filter (function `Assoc f -> List.assoc_opt "instance_id" f = Some (`String id) | _ -> false) bindings with
  | [`Assoc stored] ->
      (match read_authority stored with
       | Ok visibility -> require_read access visibility
       | Error reason -> Error (retained_fault_message reason))
  | _ -> Error "retained instance identity is ambiguous or absent"
let entry_json e =
  `Assoc ["instance_id", `String e.instance_id; "incarnation", `String e.instance_id;
    "action_schema", (match e.connection with None -> `Null
      | Some c -> Option.fold ~none:`Null ~some:Fun.id (c.worker.action_schema ()));
    "run_id", `String e.run_id;
    "addon_id", `String e.package.id; "title", `String e.package.title;
    "revision", `String e.package.revision; "phase", phase_to_json (phase_of e);
    "lifecycle", Lifecycle.state_to_json e.state;
    "execution_authority", (match e.authority with None -> `Null | Some authority -> Lifecycle.authority_to_json authority);
    "observation_seq", `Int e.seq; "rows_count", `Int (List.length e.output.rows);
    "observation_pending", `Bool (match e.pending with
      | Observe_now | Refresh_sources -> true | Run_actions | Idle -> false); "coalesced_wakes", `Int e.coalesced_wakes;
    "unchanged_source_refreshes", `Int e.unchanged_source_refreshes;
    "binding", e.binding; "source_access", Lane_addon_sources.access_to_json e.source_access;
    "package", package_to_json e.package;
    "visibility", visibility_to_json e.visibility;
    "configuration", Option.fold ~none:`Null ~some:configuration_owner_json e.configuration;
    "resource", (match e.connection with None -> `Null | Some c -> Lifecycle.resource_to_json c.worker.resource)]
(* A detached worker that acquired no execution authority or resource and
   never committed an observation leaves nothing for Inspect, Slice or Evidence.  When
   its start returned [Error], the masc:lane:resource:acquire_failed event in
   the agent-core event journal records why it did not start; a start that
   raised keeps its reason only in the [Failed] phase until it is retired.
   Its binding would only add a record that every reconciliation reads
   again, and a startup that keeps failing adds one per maintenance beat, so
   its durable form is no file. [persist] and the restart recovery in
   [historical_detach] both decide with this one rule. *)
let never_started ~seq ~authority ~resource = seq=0 && Option.is_none authority && Option.is_none resource
let retains_history e =
  not (never_started ~seq:e.seq ~authority:e.authority ~resource:(Option.map (fun c -> c.worker.resource) e.connection))
let persist m e = Eio.Mutex.use_ro e.persistence_mutex (fun () ->
  (* Capture mutable state on the owning domain after serializing writes.
     The I/O thread sees only the immutable snapshot. Every write, including
     a late one after detach, derives the file from the same state under this
     mutex, so the last write leaves the record that state calls for. *)
  if is_detached e.state && not (retains_history e)
  then offload (fun () -> Lane_addon_store.remove_binding m.store ~instance_id:e.instance_id)
  else
    let json = entry_json e in
    offload (fun () -> Lane_addon_store.save_binding m.store ~instance_id:e.instance_id json))
(* [e.wake] is resolved exactly while [e.pending <> Idle || e.host_due]. *)
let signalled e = e.pending<>Idle || e.host_due
let wake ?(request=Observe_now) e =
  let was_signalled = signalled e in
  let previous = e.pending in
  e.pending <- (match previous,request with
    | Observe_now,_ | _,Observe_now -> Observe_now
    | Refresh_sources,_ | _,Refresh_sources -> Refresh_sources
    | Run_actions,_ | _,Run_actions -> Run_actions
    | Idle,Idle -> Idle);
  if previous<>Idle then e.coalesced_wakes <- e.coalesced_wakes + 1
  else if not was_signalled && e.pending<>Idle then Eio.Promise.resolve e.resolver ()
(* One of the five host events (RFC operator-quiz §4.4). An event that arrives
   during a cycle becomes one more cycle. *)
let wake_host e =
  if e.host_due then e.coalesced_wakes <- e.coalesced_wakes + 1
  else (
    let was_signalled = signalled e in
    e.host_due <- true;
    if not was_signalled then Eio.Promise.resolve e.resolver ())
let clear_wake e =
  let promise, resolver = Eio.Promise.create () in
  e.wake <- promise; e.resolver <- resolver; e.pending <- Idle; e.host_due <- false
let entries m = Hashtbl.to_seq_values m.entries |> List.of_seq
  |> List.sort (fun a b -> String.compare a.instance_id b.instance_id)
let status_coverage e = {
  source_id = e.instance_id; incarnation = e.instance_id;
  cursor = Some (string_of_int e.seq);
  complete = (match phase_of e with
    | Attached | Detached -> e.seq > 0
    | Observing | Failed _ | Detaching -> false);
  detail = (match phase_of e with
    | Attached when e.seq > 0 -> None
    | Attached -> Some "no completed observation"
    | Observing -> Some "observation pending; showing last completed rows"
    | Failed message -> Some message
    | Detaching -> Some "cleanup pending; environment owners continue"
    | Detached -> Some "detached; history retained") }
let visibility_covers consumer producer = match consumer, producer with
  | Operator_only, _ | _, Shared -> true
  | Keeper_only a, Keeper_only b -> String.equal a b
  | Shared, (Operator_only | Keeper_only _) | Keeper_only _, Operator_only -> false
let machine_export_name = function
  | Machine_lane.Msx -> "masc_msx_screen"
  | Machine_lane.Dos -> "masc_dos_screen"
let depends_on ~(consumer : entry) ~(producer : entry) =
  let lane_changed = match producer.configuration with
    | Some owner -> consumer.run_id = producer.run_id && List.mem owner.id consumer.input_installations
    | None -> false in
  let machine_changed = producer.visibility = Shared && List.exists (fun machine ->
    List.mem (machine_export_name machine) producer.package.exported_tools
    && Lane_addon_sources.interested consumer.refresh_interest (Lane_addon_sources.Machine_changed machine))
    Machine_lane.all in
  lane_changed || machine_changed
let resolve_machine_output m ~consumer_id machine =
  let name = machine_export_name machine in
  let candidates = entries m |> List.filter (fun (e : entry) ->
    e.visibility = Shared
    && List.mem name e.package.exported_tools
    && match phase_of e with Detached | Detaching -> false | Attached | Observing | Failed _ -> true) in
  match candidates with
  | [e] when e.instance_id = consumer_id -> Error "a machine cannot capture its own output"
  | [e] when e.state = Lifecycle.Attached && e.started && not e.stopping && e.seq > 0
      && e.pending = Idle && e.active_tool_calls = 0 && Option.is_none e.current_action ->
      Ok {Lane_addon_sources.worker_instance=e.instance_id;worker_seq=e.seq;
        worker_max_bytes=(Lane_addon_types.max_reply_bytes e.package);worker_output=e.output}
  | [_] -> Error "machine worker observation is unavailable or refreshing"
  | [] -> Error "no shared machine worker is attached"
  | _ -> Error "multiple shared workers provide the machine"
let resolve_lane_output m ~access ~visibility ~run_id ~installation_id =
  let producers = entries m |> List.filter (fun e -> match e.configuration with
    | Some owner -> owner.id = installation_id | None -> false) in
  match producers with
  | [e] when not (can_read access e.visibility) -> Error "upstream installation is unavailable to this caller"
  | [e] when not (visibility_covers visibility e.visibility) ->
      Error "upstream read visibility changed; reattach this consumer before capturing new output"
  | [e] when e.run_id <> run_id -> Error "upstream installation belongs to another run"
  | [e] when e.stopping -> Error "upstream installation is being replaced or removed"
  | [e] when e.seq = 0 -> Error "upstream installation has no completed output"
  | [e] ->
      (match e.configuration with
       | Some owner -> Ok {Lane_addon_sources.installation_id; instance_id=e.instance_id;
           run_id=e.run_id; configuration_revision=owner.revision; package_revision=e.package.revision;
           outputs=e.package.outputs;
           observation_seq=e.seq; output=e.output; status=status_coverage e}
       | None -> assert false)
  | [] -> Error "upstream installation is unavailable"
  | _ -> Error "multiple workers claim the upstream installation"
let wake_dependents m producer =
  entries m |> List.iter (fun e ->
    if e.instance_id <> producer.instance_id && e.running && not e.stopping
      && depends_on ~consumer:e ~producer then wake ~request:Refresh_sources e)
(* The failure replaces the current one and keeps the earliest different cause,
   so a cleanup that fails afterwards does not erase why the worker failed. *)
let fail_state (e : entry) cause = match e.state with
  | Lifecycle.Failed previous | Lifecycle.Detaching (Some previous) ->
      Lifecycle.Failed (Lifecycle.fail_again previous cause)
  | Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching None | Lifecycle.Detached _ ->
      Lifecycle.Failed (Lifecycle.failed cause)
let failed m e cause =
  if not e.stopping then (e.state <- fail_state e cause; notify_tool_change e.package);
  match persist m e with Ok () -> wake_dependents m e | Error error ->
    if not e.stopping then
      e.state <- fail_state e (Lifecycle.Persistence_failed (Lifecycle.failure_to_string cause ^ "; binding persistence: " ^ error))
    else Log.Misc.error "Lane stopped binding persistence: %s" error
(* A detached worker is settled once a cleanup attempt has ended, whichever
   way. Its fiber may still be winding down or waiting for a retry; what the
   declaration depends on is the verdict on the container. Detach waits for
   this before it touches the declaration. *)
let settled (e : entry) =
  not e.cleanup_running
  (* A start that is still running owns the create it has not resolved, the
     same rule [stop_entry] follows. When that start fails, the state turns
     Failed before the run fiber ends and before the cleanup is forked, so the
     state alone would let a waiting Detach report a failure of its own. *)
  && not (e.running && Option.is_none e.connection)
  && (match e.state with
      | Lifecycle.Detached _ | Lifecycle.Failed _ -> true
      | Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching _ -> false)
let rec await_settled (e : entry) =
  if settled e then
    (match e.state with
     | Lifecycle.Failed failed -> Error (Lifecycle.failed_to_string failed)
     | Lifecycle.Detached _ | Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching _ -> Ok ())
  else (Eio.Condition.await_no_mutex e.changed; await_settled e)
let fork_isolated ~sw f = Eio.Fiber.fork ~sw (fun () ->
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Log.Misc.error "Lane Add-on background boundary: %s" (Printexc.to_string exn))
let release_detached m e =
  if is_detached e.state && not e.running && not e.cleanup_running
  then (Hashtbl.remove m.entries e.instance_id; wake_dependents m e; m.configuration_nudge ())
let publish_resource lifecycle e resource detail =
  Lane_addon_resource_events.publish lifecycle
    { instance_id = e.instance_id; run_id = e.run_id;
      package_id = e.package.id; package_revision = e.package.revision;
      resource; detail }
(* A release must name the same persisted authority and observed resource.
   Absence of authority and resource is the only never-created proof. *)
let check_release ~instance_id ~authority ~resource release =
  let refused () = Error (Lifecycle.Cleanup_unconfirmed "release does not match retained execution authority/resource") in
  match release with
  | Lifecycle.Never_created ->
      if Option.is_none authority && Option.is_none resource then Ok release else refused ()
  | Lifecycle.Released {engine;container_id} ->
      (match authority with
       | Some (Lifecycle.Container_authority owned) when Lifecycle.engine_equal engine owned.engine ->
           (match resource with
            | None -> Ok release
            | Some (Lifecycle.Container_resource id) when container_id=Some id -> Ok release
            | Some (Lifecycle.Container_resource _ | Lifecycle.Native_resource _) -> refused ())
       | None | Some (Lifecycle.Container_authority _ | Lifecycle.Native_admission _) -> refused ())
  | Lifecycle.Native_released receipt ->
      (match authority with
       | Some (Lifecycle.Native_admission owned) when receipt.installation_id=owned.installation_id
           && receipt.instance_id=instance_id ->
           (match resource with None | Some (Lifecycle.Native_resource _) -> Ok release
            | Some (Lifecycle.Container_resource _) -> refused ())
       | None | Some (Lifecycle.Container_authority _ | Lifecycle.Native_admission _) -> refused ())
(* A cleanup that does not confirm the release is an event an operator needs
   in the server log, not only in the resource event stream. *)
let log_cleanup_failure instance_id package_id resource failure =
  Log.Misc.warn "Lane Add-on cleanup was not confirmed for instance %s (package %s, resource %s): %s"
    instance_id package_id (Option.fold ~none:"none" ~some:Lifecycle.resource_to_string resource) (Lifecycle.failure_to_string failure)

let stop_entry ~sw ~backend m e =
  if not e.cleanup_running then
    let cleanup = match e.connection, e.authority with
      | Some c, _ -> Some (Some c.worker.resource, c.worker.stop)
      | None, None when not e.running -> Some (None, fun () -> Ok Lifecycle.Never_created)
      | None, Some authority when not e.running -> Some (None, fun () ->
          let* state_owner = state_owner_for_entry m e
            |> Result.map_error (fun message -> Lifecycle.Cleanup_unconfirmed message) in
          backend.recover_stop ~state_owner ~instance_id:e.instance_id ~authority ~resource:None)
      | None, (None | Some _) -> None (* startup still owns the unresolved create operation *) in
    match cleanup with
    | None -> ()
    | Some (resource, stop) ->
        e.cleanup_running <- true;
        fork_isolated ~sw (fun () ->
          Fun.protect
            ~finally:(fun () ->
              (* Every way out of the cleanup passes here, a raised log call or
                 a cancellation included, because Detach waits on this flag and
                 [fork_isolated] swallows the exception. The finally only sets
                 the flag and wakes the waiters. It does not yield and cannot
                 raise, so it cannot replace the exception it follows. *)
              e.cleanup_running <- false;
              Eio.Condition.broadcast e.changed)
            (fun () ->
              let result = try stop () with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn -> Error (Lifecycle.Cleanup_unconfirmed (Printexc.to_string exn)) in
              (match result with
               | Ok release ->
                   (match check_release ~instance_id:e.instance_id ~authority:e.authority ~resource release with
                    | Ok release ->
                        let already_detached = is_detached e.state in
                        e.state <- Lifecycle.Detached release; wake e;
                        Option.iter (fun cancel -> cancel ()) e.cancel_worker;
                        (* start-hang can run stop twice; the release is announced
                           once, at the transition into Detached. *)
                        if not already_detached then
                          publish_resource Lane_addon_resource_events.Release_confirmed e
                            resource None
                    | Error failure ->
                        e.state <- fail_state e failure;
                        log_cleanup_failure e.instance_id e.package.id resource failure;
                        publish_resource Lane_addon_resource_events.Release_incomplete e
                          resource (Some (Lifecycle.failure_detail failure)))
               | Error failure ->
                   e.state <- fail_state e failure;
                   log_cleanup_failure e.instance_id e.package.id resource failure;
                   publish_resource Lane_addon_resource_events.Release_incomplete e
                     resource (Some (Lifecycle.failure_detail failure)));
              (match persist m e with Ok () -> () | Error message ->
                e.state <- fail_state e (Lifecycle.Persistence_failed ("cleanup state persistence: " ^ message)));
              wake_dependents m e);
          release_detached m e)
let namespace e seq output =
  let prefix value = e.instance_id ^ "/" ^ string_of_int seq ^ "/" ^ value in
  { output with rows = List.map (fun (row : row) -> { row with
      id = prefix row.id; lane_id = e.instance_id ^ "/" ^ row.lane_id;
      related_ids = List.map prefix row.related_ids }) output.rows }
let add_output_bytes left right =
  if left > Int64.sub Int64.max_int right
  then Error "namespaced observation size overflow"
  else Ok (Int64.add left right)
let namespace_allowance e seq output =
  let escaped_bytes value =
    Int64.of_int (String.length (Yojson.Safe.to_string (`String value)) - 2) in
  let lane_prefix = escaped_bytes (e.instance_id ^ "/") in
  let row_prefix = escaped_bytes (e.instance_id ^ "/" ^ string_of_int seq ^ "/") in
  List.fold_left (fun total (row : row) ->
    let* total = total in
    let* total = add_output_bytes total lane_prefix in
    let* total = add_output_bytes total row_prefix in
    List.fold_left (fun total _ -> let* total = total in add_output_bytes total row_prefix)
      (Ok total) row.related_ids) (Ok 0L) output.rows
type action_writer = store:Lane_addon_store.t -> instance_id:string -> request_id:string ->
  Yojson.Safe.t -> (unit, string) result
let action_writer_key : action_writer Eio.Fiber.key = Eio.Fiber.create_key ()
let save_action_unlocked m (receipt : Lane_addon_action.receipt) =
  let write = match Eio.Fiber.get action_writer_key with
    | None -> (fun ~store ~instance_id ~request_id json ->
        Lane_addon_store.save_action store ~instance_id ~request_id json)
    | Some write -> write in
  offload (fun () -> write ~store:m.store ~instance_id:receipt.instance_id
    ~request_id:receipt.request_id (Lane_addon_action.to_json receipt))
let save_action m receipt = Eio.Mutex.use_ro m.action_mutex (fun () -> save_action_unlocked m receipt)
let finalize_actions m e =
  (* The worker's lifetime owns dispatch. Cleanup never replays work against a
     replacement incarnation. Remaining queued work is known not to have run. *)
  let finish (receipt : Lane_addon_action.receipt) state detail =
    let detail = match receipt.detail with None -> detail | Some previous -> previous ^ "; " ^ detail in
    let receipt = {receipt with Lane_addon_action.state; detail = Some detail} in
    match save_action m receipt with
    | Ok () -> None
    | Error message ->
        Log.Misc.error "Lane action finalization persistence: %s" message;
        Some receipt in
  (match e.current_action with
   | None -> ()
   | Some receipt ->
       let state, detail = match receipt.state with
         | Lane_addon_action.Queued -> Lane_addon_action.Failed_before_effect,
             "worker lifetime ended before dispatch"
         | Lane_addon_action.Running | Lane_addon_action.Confirmed
         | Lane_addon_action.Failed_before_effect | Lane_addon_action.Outcome_unknown ->
             Lane_addon_action.Outcome_unknown,
             "worker lifetime ended before a durable action result; no automatic retry" in
       (* A failed fallback cannot erase knowledge of an unconfirmed terminal
          rename. Keep the exact received result until repair is durable. *)
       e.current_action <- finish receipt state detail);
  Queue.iter (fun receipt -> ignore (finish receipt Lane_addon_action.Failed_before_effect
    "worker lifetime ended while request was queued")) e.action_queue;
  Queue.clear e.action_queue
type observation_writer = store:Lane_addon_store.t -> instance_id:string -> seq:int ->
  sources:Yojson.Safe.t -> output -> (unit, Lane_addon_store.observation_write_error) result
let observation_writer_key : observation_writer Eio.Fiber.key = Eio.Fiber.create_key ()
let commit_output m e ~sources output =
  let seq = e.seq + 1 in
  (* The declared observation envelope also bounds the host representation:
     package-controlled relation lists cannot manufacture extra retained
     capacity. The allowance is never negative, so this one check also covers
     the package's own bytes. *)
  let* allowance = namespace_allowance e seq output in
  let* namespaced_bytes = add_output_bytes
    (Int64.of_int (String.length (Yojson.Safe.to_string (output_to_json output)))) allowance in
  let* () =
    if namespaced_bytes <= Int64.of_int (Lane_addon_types.max_reply_bytes e.package)
    then Ok () else Error "namespaced observation exceeds the declared host observation envelope" in
  let output = namespace e seq output in
  let write = match Eio.Fiber.get observation_writer_key with
    | Some write -> write
    | None -> (fun ~store ~instance_id ~seq ~sources output ->
        Lane_addon_store.append_observation store ~instance_id ~seq ~sources output) in
  let published = offload (fun () -> write ~store:m.store
    ~instance_id:e.instance_id ~seq ~sources output) in
  let converge () = e.seq <- seq; e.output <- output in
  match published with
  | Ok () ->
    converge ();
    if not e.stopping then e.state <- Lifecycle.Attached;
    (* The output is published and converged, and dependents read it from the
       entry, not from the binding file. Wake them in the same step that makes
       [refreshing] false: persisting yields, and a reader that saw the
       producer settled could otherwise act before its dependents were told,
       so one commit reached them after the reader's next action. *)
    wake_dependents m e;
    persist m e
  | Error (Lane_addon_store.Observation_rejected detail) -> Error detail
  | Error (Lane_addon_store.Publication_failed {failure;verification_error}) ->
    let cause=Lane_addon_store.observation_write_error_to_string
      (Lane_addon_store.Publication_failed {failure;verification_error}) in
    (match failure.Fs_compat.stage with
     | Fs_compat.Before_rename -> ()
     | Fs_compat.After_rename ->
       converge ();
       if not e.stopping then e.state <- fail_state e
         (Lifecycle.Persistence_failed ("observation published with unconfirmed durability: " ^ cause)));
    let detail = match failure.stage with
      | Fs_compat.Before_rename -> cause
      | Fs_compat.After_rename -> "observation published with unconfirmed durability: " ^ cause in
    let saved = match failure.stage with
      | Fs_compat.Before_rename -> Ok ()
      | Fs_compat.After_rename -> persist m e in
    wake_dependents m e;
    (match failure.exception_ with
     | Eio.Cancel.Cancelled _ -> Printexc.raise_with_backtrace failure.exception_ failure.backtrace
     | _ -> match saved with
       | Ok () -> Error detail
       | Error error -> Error (detail ^ "; binding persistence: " ^ error))
let perform_action m e (c : connection) (queued : Lane_addon_action.receipt) =
  e.current_action <- Some queued;
  let running = {queued with state = Lane_addon_action.Running; executor = Some c.resource} in
  match save_action m running with
  | Error message ->
      let receipt = {queued with state = Lane_addon_action.Failed_before_effect;
        detail = Some ("dispatch record could not be persisted: " ^ message)} in
      (match save_action m receipt with Ok () -> e.current_action <- None
       | Error error -> raise (Action_persistence_failed error))
  | Ok () ->
      e.current_action <- Some running;
      let arguments = Lane_addon_action.arguments ~instance_id:e.instance_id
        ~request_id:running.request_id ~action:running.action in
      let result = try c.act ~arguments with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn) in
      let finished = match result with
        | Error message -> {running with state = Lane_addon_action.Outcome_unknown;
            detail = Some ("dispatched action has no valid package result: " ^ message)}
        | Ok package_result ->
            let received = {running with state = Lane_addon_action.Outcome_unknown;
              result = Some package_result.result;
              detail = Some "package result received; evidence and receipt durability not yet established"} in
            (* Filesystem publication can fail after rename. Preserve the
               received payload before either evidence or receipt writes yield. *)
            e.current_action <- Some received;
            let sources = `Assoc ["kind", `String "lane_action";
              "request", Lane_addon_action.to_json running;
              "package_status", `String (match package_result.Lane_addon_action.status with
                | Package_confirmed -> "confirmed" | Package_failed_before_effect -> "failed_before_effect"
                | Package_outcome_unknown -> "outcome_unknown")] in
            (match commit_output m e ~sources package_result.output with
             | Error message -> {received with
                 detail = Some ("package returned a result but its evidence was not committed: " ^ message)}
             | Ok () ->
                 let state = match package_result.status with
                   | Package_confirmed -> Lane_addon_action.Confirmed
                   | Package_failed_before_effect -> Lane_addon_action.Failed_before_effect
                   | Package_outcome_unknown -> Lane_addon_action.Outcome_unknown in
                 {received with state;
                   detail = Some "outcome reported by the package; interpret its result and retained evidence"}) in
      e.current_action <- Some finished;
      let uncertain message =
        let detail = match finished.detail with
          | None -> "action result persistence failed: " ^ message
          | Some previous -> previous ^ "; action result persistence failed: " ^ message in
        e.current_action <- Some {finished with state = Lane_addon_action.Outcome_unknown;
          detail = Some detail} in
      (* Publish the save outcome to readers before releasing their serializer.
         A post-rename fsync error must not expose its visible terminal JSON as
         a confirmed result while failure handling yields to other fibers. *)
      let saved = Eio.Mutex.use_ro m.action_mutex (fun () ->
        match save_action_unlocked m finished with
        | Ok () -> e.current_action <- None; Ok ()
        | Error message -> uncertain message; Error message
        | exception exn ->
            let backtrace = Printexc.get_raw_backtrace () in
            uncertain (Printexc.to_string exn);
            Printexc.raise_with_backtrace exn backtrace) in
      (match saved with
       | Ok () -> ()
       | Error message -> raise (Action_persistence_failed ("action result persistence: " ^ message)))

(* Only an operator-owned TOML declaration may hold record grants. *)
let operator_owned ~configuration ~source_access = match configuration, source_access with
  | Some _, Lane_addon_sources.Operator_configuration -> true
  | Some _, (Lane_addon_sources.Keeper _ | Lane_addon_sources.Unauthenticated) | None, _ -> false

let host_issue_to_json = function
  | Listing_failed detail -> `Assoc ["kind", `String "listing_failed"; "detail", `String detail]
  | Listing_refused detail -> `Assoc ["kind", `String "listing_refused"; "detail", `String detail]
  | Relisted_delivered_request request_id ->
      `Assoc ["kind", `String "relisted_delivered_request"; "request_id", `String request_id]
  | Result_delivery_failed {request_id; detail} ->
      `Assoc ["kind", `String "result_delivery_failed"; "request_id", `String request_id; "detail", `String detail]
  | Exact_record_failed {request_id; detail} ->
      `Assoc ["kind", `String "exact_record_failed"; "request_id", `String request_id; "detail", `String detail]
  | Ask_record_failed {request_id; detail} ->
      `Assoc ["kind", `String "ask_record_failed"; "request_id", `String request_id; "detail", `String detail]
  | No_exact_runner -> `Assoc ["kind", `String "no_exact_runner"]

let host_status_json status =
  `Assoc ["cycles", `Int status.cycles;
    "waiting", `List (List.map (fun (request_id, reason) ->
      `Assoc ["request_id", `String request_id; "reason", reason]) status.waiting);
    "issue", Option.fold ~none:`Null ~some:host_issue_to_json status.issue]

(* The frame the worker connection accepts is the package's [max_reply_bytes]
   (RFC-0471 row 1). What is measured is the arguments object the host sends;
   the JSON-RPC envelope around it is not counted. *)
(* One cycle (RFC operator-quiz §4.4): list, deliver what is final or try each
   request once, list again until a listing delivers nothing. The host keeps
   no list of pending requests; [host_status] only shows the last cycle. *)
(* What one try of a request gives: a final result body to deliver, or the
   reason it waits for the next event. *)
type host_attempt = Deliver of Yojson.Safe.t | Restore of Yojson.Safe.t | Wait of Yojson.Safe.t

let run_host_cycle m e (port : host_port) =
  let delivered = Hashtbl.create 8 and tried = Hashtbl.create 8 in
  let waiting = ref [] in
  let current_owner () : Lane_addon_host_delivery.owner = {
    instance_id=e.instance_id;
    authority=`Assoc ["configuration", Option.fold ~none:`Null ~some:configuration_owner_json e.configuration;
      "source_access", Lane_addon_sources.access_to_json e.source_access; "binding", e.binding];
  } in
  let owner = current_owner () in
  let not_allowed reason = Deliver (`Assoc ["status", `String "not_allowed"; "reason", `String reason]) in
  (* The asker is the installation: a declaration that declares [world.asks]. *)
  let asker = match e.package.operator_asks, e.configuration with
    | false, _ -> Error "the package manifest does not declare [world.asks] operator = true"
    | true, None -> Error "a manual Attach has no installation to ask from"
    | true, Some owner -> Ok owner.id in
  let read_answer = function
    | Lane_addon_records.Page body -> Ok (Deliver body)
    | Lane_addon_records.Not_allowed reason -> Ok (not_allowed reason)
    | Lane_addon_records.Unavailable detail ->
        Ok (Wait (`Assoc ["reason", `String "source_unavailable"; "detail", `String detail])) in
  let produce = function
    | Lane_addon_host_request.Exact_output exact ->
        let attempt = match e.configuration, !exact_runner with
          | None, _ ->
              (* A manual Attach has no declaration id, so it owns no add-on lane. *)
              Ok (Lane_addon_exact.Not_final (Lane_addon_exact.Lane_unavailable Lane_addon_exact.Lane_unconfigured))
          | Some _, None -> Error No_exact_runner
          | Some owner, Some runner ->
              Lane_addon_exact.run ~store:m.store ~declaration_id:owner.id ~package:e.package ~runner exact
              |> Result.map_error (fun detail ->
                Exact_record_failed {request_id = exact.Lane_addon_exact.request_id; detail}) in
        Result.map (function
          | Lane_addon_exact.Final final -> Deliver (Lane_addon_exact.final_to_json final)
          | Lane_addon_exact.Not_final reason -> Wait (Lane_addon_exact.not_final_to_json reason)) attempt
    | Lane_addon_host_request.Read_records {request_id; source_id; start} ->
        (match Lane_addon_records.grants ~operator_owned:(operator_owned ~configuration:e.configuration
            ~source_access:e.source_access) e.binding with
         | Error reason -> Ok (not_allowed reason)
         | Ok grants ->
             let measure result = String.length (Yojson.Safe.to_string
               (Lane_addon_host_request.result_arguments ~request_id ~result)) in
             read_answer (Lane_addon_records.read_records ~base_path:m.base_path ~store:m.store ~grants
               ~github:!github_reader ~measure
               ~max_bytes:(Lane_addon_types.max_reply_bytes e.package) ~source_id ~start))
    | Lane_addon_host_request.Ask {request_id; questions; context} ->
        (match asker with
         | Error reason -> Ok (not_allowed reason)
         | Ok declaration_id ->
             match Lane_addon_asks.ask ~ask_id:request_id ~declaration_id ~title:e.package.title ~questions
                 ?context ~asked_at:(Time_compat.now ()) () with
             | Error reason -> Ok (not_allowed reason)
             | Ok asked ->
                 let failed detail = Ask_record_failed {request_id; detail} in
                 let* recorded = offload (fun () -> Lane_addon_asks.record m.store asked) |> Result.map_error failed in
                 match recorded with
                 | Lane_addon_asks.Id_reused -> Ok (Deliver (`Assoc ["status", `String "request_id_reused"]))
                 | Lane_addon_asks.Recorded | Lane_addon_asks.Already_recorded ->
                     let* rows = offload (fun () -> Lane_addon_asks.rows m.store ~declaration_id)
                       |> Result.map_error failed in
                     (* The answer is delivered only once the operator answered or
                        the package withdrew (RFC operator-quiz §4.4). *)
                     match List.assoc_opt request_id rows with
                     | None -> Error (failed "the recorded question has no row")
                     | Some (_, Keeper_ask.Open) -> Ok (Wait (`Assoc ["reason", `String "awaiting_operator"]))
                     | Some (_, Keeper_ask.Answered_by {answers; responder; answered_at}) ->
                         Ok (Deliver (`Assoc ["status", `String "answered";
                           "answers", `List (List.map Keeper_ask.answer_to_json answers);
                           "responder", Keeper_ask.responder_to_json responder;
                           "answered_at", `Float answered_at]))
                     | Some (_, Keeper_ask.Withdrawn_because {reason; withdrawn_at}) ->
                         Ok (Deliver (`Assoc ["status", `String "withdrawn"; "reason", `String reason;
                           "withdrawn_at", `Float withdrawn_at])))
    | Lane_addon_host_request.Withdraw_ask {request_id; ask_id; reason} ->
        (match asker with
         | Error reason -> Ok (not_allowed reason)
         | Ok declaration_id ->
             let* outcome = offload (fun () ->
                 Lane_addon_asks.withdraw m.store ~declaration_id ~ask_id ~reason ~now:(Time_compat.now ()))
               |> Result.map_error (fun detail -> Ask_record_failed {request_id; detail}) in
             match outcome with
             | Lane_addon_asks.Withdrawn | Lane_addon_asks.Was_withdrawn ->
                 Ok (Deliver (`Assoc ["status", `String "withdrawn"]))
             | Lane_addon_asks.Was_answered -> Ok (Deliver (`Assoc ["status", `String "already_answered"]))
             | Lane_addon_asks.Not_asked -> Ok (not_allowed ("the package asked no question " ^ ask_id)))
    | Lane_addon_host_request.Read_file {request_id = _; source_id; commit; path} ->
        (match Lane_addon_records.grants ~operator_owned:(operator_owned ~configuration:e.configuration
            ~source_access:e.source_access) e.binding with
         | Error reason -> Ok (not_allowed reason)
         | Ok grants ->
             read_answer (Lane_addon_records.read_file ~base_path:m.base_path ~store:m.store ~grants
               ~source_id ~commit ~path))
    | Lane_addon_host_request.Read_result {request_id; original_request_id; source_id; sha256; offset} ->
        (match offload (fun () -> Lane_addon_host_delivery.read ~store:m.store ~owner ~request_id
            ~original_request_id ~source_id ~sha256 ~offset ~max_bytes:(Lane_addon_types.max_reply_bytes e.package)) with
         | Ok body -> Ok (Deliver body)
         | Error (Lane_addon_host_delivery.Refused reason) -> Ok (not_allowed reason)
         | Error (Storage_failed detail) -> Error (Result_delivery_failed {request_id; detail})) in
  let try_request request =
    let request_id = Lane_addon_host_request.request_id request in
    let* retained = offload (fun () -> Lane_addon_host_delivery.restore ~store:m.store ~owner ~request
        ~max_bytes:(Lane_addon_types.max_reply_bytes e.package))
      |> Result.map_error (function
        | Lane_addon_host_delivery.Refused detail | Storage_failed detail -> Result_delivery_failed {request_id; detail}) in
    match retained with Some arguments -> Ok (Restore arguments) | None -> produce request in
  let deliver_arguments ~request_id arguments =
    let* () = if e.stopping || (current_owner ()).authority <> owner.authority then
        Error (Result_delivery_failed {request_id; detail="installation authority changed before result delivery"})
      else Ok () in
    let* answer = port.deliver ~arguments
      |> Result.map_error (fun detail -> Result_delivery_failed {request_id; detail}) in
    Lane_addon_host_request.accepted_of_json answer
    |> Result.map (fun (_accepted : bool) -> ())
    |> Result.map_error (fun detail -> Result_delivery_failed {request_id; detail}) in
  let deliver request result =
    let request_id = Lane_addon_host_request.request_id request in
    let* arguments = offload (fun () -> Lane_addon_host_delivery.arguments ~store:m.store ~owner ~request
        ~max_bytes:(Lane_addon_types.max_reply_bytes e.package) ~result)
      |> Result.map_error (function
        | Lane_addon_host_delivery.Refused detail | Storage_failed detail -> Result_delivery_failed {request_id; detail}) in
    deliver_arguments ~request_id arguments in
  let rec pass () =
    let* listing = port.list_requests () |> Result.map_error (fun detail -> Listing_failed detail) in
    let* requests = Lane_addon_host_request.listing_of_json listing
      |> Result.map_error (fun detail -> Listing_refused detail) in
    let rec each delivered_any = function
      | [] -> Ok delivered_any
      | request :: rest ->
          let request_id = Lane_addon_host_request.request_id request in
          if Hashtbl.mem delivered request_id then Error (Relisted_delivered_request request_id)
          else if Hashtbl.mem tried request_id then each delivered_any rest
          else
            let* attempt = try_request request in
            match attempt with
            | Restore arguments ->
                let* () = deliver_arguments ~request_id arguments in
                Hashtbl.replace delivered request_id ();
                each true rest
            | Deliver result ->
                let* () = deliver request result in
                Hashtbl.replace delivered request_id ();
                each true rest
            | Wait reason ->
                (* Tried at most once per cycle, so it cannot keep a cycle running. *)
                Hashtbl.replace tried request_id ();
                waiting := (request_id, reason) :: !waiting;
                each delivered_any rest in
    let* delivered_any = each false requests in
    if delivered_any then pass () else Ok () in
  let outcome = pass () in
  e.host_status <- { cycles = e.host_status.cycles + 1; waiting = List.rev !waiting;
    issue = (match outcome with Ok () -> None | Error issue -> Some issue) }

let observing e =
  let recovering = match e.state with Lifecycle.Failed _ -> true
    | Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching _ | Lifecycle.Detached _ -> false in
  e.state <- Lifecycle.Observing;
  if recovering then notify_tool_change e.package

(* An incarnation is live in this process while it has an entry or a cleanup
   in progress. A container of any other incarnation of the same installation
   was left by a process that died, which is the only server on this base path. *)
let is_live_instance m id = Hashtbl.mem m.entries id || Hashtbl.mem m.recovering id

let run ~sw backend m e =
  fork_isolated ~sw (fun () ->
    let work () = try
      Eio.Switch.run (fun worker_sw ->
        e.cancel_worker <- Some (fun () -> Eio.Switch.fail worker_sw Worker_detached);
        let export_owner = Lane_addon_tool_export.create_owner ~instance_id:e.instance_id in
        let on_authority authority =
          e.authority <- Some authority;
          persist m e in
        let created c = e.connection <- Some {export_owner;worker=c};
          publish_resource Lane_addon_resource_events.Acquired e (Some c.resource) None;
          (match persist m e with Ok () -> () | Error message ->
            e.stopping <- true; e.state <- fail_state e (Lifecycle.Persistence_failed message));
          if e.stopping then stop_entry ~sw ~backend m e in
        let started = let* state_owner = state_owner_for_entry m e
            |> Result.map_error (fun message -> Lifecycle.Worker_failed message) in
          backend.start ~state_owner ~sw:worker_sw ~instance_id:e.instance_id
            ~installation_id:(match e.configuration with Some owner -> owner.id | None -> e.instance_id)
            ~package:e.package ~binding:e.binding ~on_authority
            ~is_live_instance:(is_live_instance m) ~on_created:created in
        match started with
        | Error failure ->
            publish_resource Lane_addon_resource_events.Acquire_failed e
              (Option.map (fun c -> c.worker.resource) e.connection) (Some (Lifecycle.failure_detail failure));
            if e.stopping then (
              match e.connection with None -> e.state <- fail_state e failure
              | Some _ -> stop_entry ~sw ~backend m e)
            else failed m e failure
        | Ok c ->
            e.connection <- Some {export_owner;worker=c}; e.started <- true;
            notify_tool_change e.package;
            (match c.host, e.configuration with
             | Some _, Some owner ->
                 (* A publication that changes one of this installation's add-on
                    lanes is a host event. The callback only signals. *)
                 let unsubscribes = List.filter_map (fun (output : exact_output) ->
                   match Runtime_schema.addon_lane ~declaration_id:owner.id ~output:output.name with
                   | Ok lane ->
                       Some (Runtime_exact_output_registry.subscribe_lane_changes
                         ~lane_id:(Runtime_schema.exact_lane_key (Runtime_schema.Addon lane))
                         (fun () -> Eio_context.run_on_owner_domain (fun () -> wake_host e)))
                   | Error detail ->
                       Log.Misc.error "Lane Add-on %s cannot own exact output %s: %s" owner.id output.name detail;
                       None) e.package.exact_outputs in
                 Eio.Switch.on_release worker_sw (fun () -> List.iter (fun unsubscribe -> unsubscribe ()) unsubscribes)
             | Some _, None | None, (Some _ | None) -> ());
            (* A worker that finished initializing is the first host event. *)
            if Option.is_some c.host then wake_host e;
            let rec loop () =
              if e.stopping then (
                match e.state with Lifecycle.Detached _ -> () | Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching _ | Lifecycle.Failed _ -> let pending = e.wake in
                  Eio.Promise.await pending; clear_wake e; loop ())
              else (
                let pending = e.wake in
                Eio.Promise.await pending;
                let request = e.pending in
                let host_due = e.host_due in
                clear_wake e;
                if e.stopping then loop () else (
                  if not (Queue.is_empty e.action_queue) then (
                    let queued = Queue.take e.action_queue in
                    perform_action m e c queued;
                    (* The package result is committed with its own output.
                       Carry forward only what this wake still owes: the next
                       queued action, or an observation request that arrived
                       beside the action. No Keeper turn waits on this queue. *)
                    let follow_up = match request, Queue.is_empty e.action_queue with
                      | (Observe_now | Refresh_sources), _ -> Some request
                      | (Run_actions | Idle), false -> Some Run_actions
                      | (Run_actions | Idle), true -> None in
                    Option.iter (fun request -> wake ~request e) follow_up;
                    (* A terminal action receipt is a host event, and a cycle
                       owed before the action is still owed. *)
                    if host_due || Option.is_some c.host then wake_host e)
                  else if host_due then (
                    Option.iter (run_host_cycle m e) c.host;
                    (* The cycle ends with one ordinary observation, so the
                       package's rows show what it received. *)
                    wake e)
                  else if request = Run_actions || request = Idle then
                    (* The queue was drained before this wake was served
                       (finalize on stop); nothing is owed. *)
                    ()
                  else (
                    let previous_state = e.state in
                    if request=Observe_now then observing e;
                    let result =
                      let* sources = backend.acquire ~access:e.source_access ~store:m.store ~package:e.package ~binding:e.binding
                        ~resolve_machine_output:(resolve_machine_output m ~consumer_id:e.instance_id)
                        ~resolve_lane_output:(resolve_lane_output m ~access:e.source_access ~visibility:e.visibility ~run_id:e.run_id) in
                      if e.stopping then Ok () else
                      let* fingerprint = match e.package.refresh_policy with
                        | Source_changes -> Lane_addon_sources.refresh_fingerprint e.refresh_interest sources
                        | Every_hint -> Ok None in
                      if request=Refresh_sources && previous_state=Lifecycle.Attached
                        && Option.is_some fingerprint && fingerprint=e.last_committed_sources
                      then (
                        e.unchanged_source_refreshes <- e.unchanged_source_refreshes + 1;
                        Ok ())
                      else (
                        observing e;
                        let* output = c.observe ~binding:e.binding ~sources in
                        let* () = commit_output m e ~sources output in
                        e.last_committed_sources <- fingerprint;
                        Ok ()) in
                    match result with Ok () -> () | Error message -> failed m e (Lifecycle.Worker_failed message));
                  loop ()))
            in loop ());
    with
    | Worker_detached -> ()
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> failed m e (Lifecycle.Worker_failed (Printexc.to_string exn))
    in
    match work () with
    | () -> e.running <- false; e.cancel_worker <- None;
        Eio.Cancel.protect (fun () -> finalize_actions m e);
        if e.stopping && not (is_detached e.state) then stop_entry ~sw ~backend m e;
        Eio.Condition.broadcast e.changed;
        release_detached m e
    | exception exn -> e.running <- false; e.cancel_worker <- None;
        Eio.Cancel.protect (fun () -> finalize_actions m e);
        Eio.Condition.broadcast e.changed;
        release_detached m e; raise exn)
let native_claim_root store = Filename.concat (Lane_addon_store.root store) "native-claims"
let native_directories store installation_id =
  [Filename.concat (native_claim_root store) (Lane_addon_store.digest installation_id)]
let native_result result = Result.map_error (fun error ->
  Lifecycle.Cleanup_unconfirmed (Native_addon_lease.error_to_string error)) result
let native_settled claim =
  let* status = offload (fun () -> Native_addon_lease.status claim) |> native_result in
  match status with
  | Native_addon_lease.Settled -> Ok ()
  | Awaiting_exec | Live _ | Cleanup_pending _ ->
      Error (Lifecycle.Cleanup_unconfirmed "native claim has not settled")
let native_recover ~store ~installation_id ~instance_id =
  let* claim = offload (fun () -> Native_addon_lease.reopen
    ~directories:(native_directories store installation_id) ~instance_id) |> native_result in
  let* () = offload (fun () -> Native_addon_lease.request_termination claim) |> native_result in
  let* () = native_settled claim in
  Ok (Lifecycle.Native_released {installation_id;instance_id})
let prepare_native ~store ~installation_id ~instance_id ~is_live_instance =
  let* () = offload (fun () ->
    try
      let root = native_claim_root store in
      (try Unix.mkdir root 0o700 with Unix.Unix_error (Unix.EEXIST,_,_) -> ());
      let stat = Unix.lstat root in
      if stat.Unix.st_kind=Unix.S_DIR && stat.st_uid=Unix.geteuid () && stat.st_perm land 0o077=0
      then Ok () else Error (Lifecycle.Worker_failed "native claim root must be a private host-owned directory")
    with (Unix.Unix_error _ | Sys_error _) as exn -> Error (Lifecycle.Worker_failed (Printexc.to_string exn))) in
  let directories = native_directories store installation_id in
  let* old = offload (fun () ->
    match directories with
    | [directory] -> (match Unix.lstat directory with
        | _ -> Native_addon_lease.current ~directories |> Result.map Option.some
        | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None)
    | [] | _::_::_ -> Error (Native_addon_lease.Invalid_claim "native installation must have one host-selected slot"))
    |> native_result in
  let* () = match old with
    | None -> Ok ()
    | Some claim ->
        if is_live_instance (Native_addon_lease.instance_id claim) then
          Error (Lifecycle.Worker_failed "native installation still belongs to a live incarnation")
        else
          (* This also recovers an orphan reservation if the server stopped
             between preparing it and saving its binding. Never re-admit it. *)
          let* () = offload (fun () -> Native_addon_lease.request_termination claim) |> native_result in
          native_settled claim in
  offload (fun () -> Native_addon_lease.prepare ~directories ~instance_id) |> native_result
let native_launcher () =
  try
    let name = "masc-native-addon-launcher" in
    let siblings = if Filename.is_relative Sys.executable_name then [] else
      [Filename.concat (Filename.dirname (Unix.realpath Sys.executable_name)) name;
       Filename.concat (Filename.dirname Sys.executable_name) name] in
    let paths = match Sys.getenv_opt "PATH" with
      | None -> []
      | Some raw -> Executable_path.split_search_path raw
          |> List.filter (fun directory -> directory<>"")
          |> List.map (fun directory -> Filename.concat directory name) in
    match List.find_opt Executable_path.command_available (siblings @ paths) with
    | Some path -> Ok (Unix.realpath path)
    | None -> Error "masc-native-addon-launcher is not installed beside MASC or on PATH"
  with (Unix.Unix_error _ | Sys_error _) as exn -> Error (Printexc.to_string exn)
let native_package_ready (package : package) =
  let* () = match package.state_storage with
    | Ephemeral -> Ok ()
    | Persistent -> Error "native persistent state requires a host state-directory contract" in
  let* () = match package.model_access with
    | Model_disabled -> Ok ()
    | Host_sampling -> Error "native observation sampling is not connected to the host broker" in
  let* _launcher = native_launcher () in
  let* () = match Eio_context.get_clock_opt (),Fs_compat.get_fs_opt () with
    | Some _,Some _ -> Ok ()
    | None,_ | _,None -> Error "native Add-ons require the server Eio clock and filesystem" in
  match package.command with
  | [] -> Error "native Add-on command is empty"
  | command::_ ->
      let candidate = if Filename.is_relative command && String.contains command '/'
        then Filename.concat package.directory command else command in
      if Executable_path.command_available candidate then Ok () else Error "native Add-on executable is unavailable"
let backend ~store () = match !override with
  | Some backend -> backend
  | None ->
    let clock = Eio_context.get_clock_opt () in
    let control_timeout_sec = Env_config_runtime.Sidecar.control_command_timeout_sec in
    let scope = Lane_addon_store.digest (Lane_addon_store.root store) in
    {
      start = (fun ~sw ~state_owner ~instance_id ~installation_id ~package ~binding ~on_authority ~is_live_instance ~on_created ->
        match package.execution with
        | Host_process _ ->
            let* () = native_package_ready package |> Result.map_error (fun detail -> Lifecycle.Worker_failed detail) in
            let* launcher = native_launcher () |> Result.map_error (fun detail -> Lifecycle.Worker_failed detail) in
            let* clock = Option.to_result ~none:(Lifecycle.Worker_failed "native clock is unavailable") clock in
            let* fs = Option.to_result ~none:(Lifecycle.Worker_failed "native filesystem is unavailable") (Fs_compat.get_fs_opt ()) in
            let* contract = Lane_addon_worker_protocol.contract_of_package package
              |> Result.map_error (fun _ -> Lifecycle.Worker_failed "invalid native MCP contract") in
            let* command = match package.command with
              | [] -> Error (Lifecycle.Worker_failed "native command is empty")
              | executable::arguments -> Ok {Lane_addon_native_worker.executable;arguments} in
            let* admission = prepare_native ~store ~installation_id ~instance_id ~is_live_instance in
            let retire () = offload (fun () -> Native_addon_lease.retire admission) |> native_result in
            let* () = match on_authority (Lifecycle.Native_admission {installation_id}) with
              | Ok () -> Ok ()
              | Error detail ->
                  let* () = retire () in Error (Lifecycle.Persistence_failed detail) in
            let wrap worker =
              let* resource = Option.to_result ~none:"native child identity is unavailable"
                (Lane_addon_native_worker.process_identity worker) in
              Ok {
                resource;
                exported_tools=(fun () -> Lane_addon_native_worker.exported_tools worker);
                action_schema=(fun () -> Lane_addon_native_worker.action_schema worker);
                call_exported_tool=(fun ~on_result ~authorize ~principal ~name ~arguments ->
                  Lane_addon_native_worker.call_exported_tool ~on_result ?authorize ~principal worker ~name ~arguments
                  |> Result.map_error (function
                    | Lane_addon_native_worker.Protocol (Lane_addon_worker_protocol.Host_refusal refusal) -> Lane_addon_call_context.Host_refusal refusal
                    | (Lane_addon_native_worker.Invalid_specification _ | Start_failed _ | Admission _
                      | Protocol (Lane_addon_worker_protocol.Invalid_contract _ | Protocol_failed _ | Invalid_observation _ | Stopped)
                      | Cleanup_unconfirmed _ | Stopped) as error ->
                        Lane_addon_call_context.Transport_error (Lane_addon_native_worker.error_to_string error)));
                act=(fun ~arguments -> Lane_addon_native_worker.act worker ~arguments |> Result.map_error Lane_addon_native_worker.error_to_string);
                observe=(fun ~binding ~sources -> Lane_addon_native_worker.observe worker ~binding ~sources |> Result.map_error Lane_addon_native_worker.error_to_string);
                host=(if not (uses_host_requests package) then None else Some {
                  list_requests=(fun () -> Lane_addon_native_worker.host_requests worker |> Result.map_error Lane_addon_native_worker.error_to_string);
                  deliver=(fun ~arguments -> Lane_addon_native_worker.host_result worker ~arguments |> Result.map_error Lane_addon_native_worker.error_to_string) });
                stop=(fun () ->
                  let* _receipt = Lane_addon_native_worker.stop worker
                    |> Result.map_error (fun error -> Lifecycle.Cleanup_unconfirmed (Lane_addon_native_worker.error_to_string error)) in
                  Ok (Lifecycle.Native_released {installation_id;instance_id}));
              } in
            (try
               match Lane_addon_native_worker.start ~sw ~clock ~admission ~launcher ~contract ~command
                 ~grace_seconds:Process_eio.child_exit_grace_seconds ~cwd:Eio.Path.(fs / package.directory)
                 ~artifact_store:store ~on_created:(fun worker ->
                   let* connection = wrap worker in on_created connection;Ok ()) () with
               | Ok worker -> wrap worker |> Result.map_error (fun detail -> Lifecycle.Worker_failed detail)
               | Error error -> let* () = retire () in
                   Error (match error with
                    | Lane_addon_native_worker.Cleanup_unconfirmed detail -> Lifecycle.Cleanup_unconfirmed detail
                    | (Invalid_specification _ | Start_failed _ | Admission _ | Protocol _ | Stopped) as error ->
                        Lifecycle.Worker_failed (Lane_addon_native_worker.error_to_string error))
             with Eio.Cancel.Cancelled _ as exn ->
               Eio.Cancel.protect (fun () -> ignore (retire () : (unit,Lifecycle.failure) result));raise exn)
        | Container container ->
          let* sampling_handler = prepare_sampling_handler ~sw ~store ~instance_id ~package ~binding
            |> Result.map_error (fun detail -> Lifecycle.Worker_failed detail) in
          let recorded = ref None in
          let on_engine engine =
            let* () = on_authority (Lifecycle.Container_authority {runtime=container.runtime;engine}) in
            recorded := Some engine;Ok () in
          let wrap worker = {
            resource=Lifecycle.Container_resource (Lane_addon_worker.container_id worker);
            exported_tools=(fun () -> Lane_addon_worker.exported_tools worker);
            call_exported_tool=(fun ~on_result ~authorize ~principal ~name ~arguments ->
              Lane_addon_worker.call_exported_tool ~on_result ?authorize ~principal worker ~name ~arguments
              |> Result.map_error (function
                | Lane_addon_worker.Host_refusal refusal -> Lane_addon_call_context.Host_refusal refusal
                | (Lane_addon_worker.Stopped | Invalid_package _ | Docker_failed _ | Engine_failed _ | Engine_fault _ | Lifecycle _ | Protocol_failed _ | Invalid_observation _) as error ->
                    Lane_addon_call_context.Transport_error (Lane_addon_worker.error_to_string error)));
            action_schema=(fun () -> Lane_addon_worker.action_schema worker);
            act=(fun ~arguments -> Lane_addon_worker.act worker ~arguments |> Result.map_error Lane_addon_worker.error_to_string);
            observe=(fun ~binding ~sources -> Lane_addon_worker.observe worker ~binding ~sources |> Result.map_error Lane_addon_worker.error_to_string);
            host=(if not (uses_host_requests package) then None else Some {
              list_requests=(fun () -> Lane_addon_worker.host_requests worker |> Result.map_error Lane_addon_worker.error_to_string);
              deliver=(fun ~arguments -> Lane_addon_worker.host_result worker ~arguments |> Result.map_error Lane_addon_worker.error_to_string) });
            stop=(fun () ->
              let* () = Lane_addon_worker.stop worker |> Result.map_error Lane_addon_worker.cleanup_failure in
              match !recorded with
              | Some engine -> Ok (Lifecycle.Released {engine;container_id=Some (Lane_addon_worker.container_id worker)})
              | None -> Error (Lifecycle.Cleanup_unconfirmed "container has no recorded engine")) } in
          let* clock = Option.to_result ~none:(Lifecycle.Worker_failed "container clock is unavailable") clock in
          Lane_addon_worker.start ~sw ~clock ~control_timeout_sec ~mgr:Posix_spawn_process_mgr.mgr
            ~instance_id ~package ?state_owner ~on_engine ~is_live_instance ~scope
            ~on_created:(fun worker -> on_created (wrap worker)) ~artifact_store:store ?sampling_handler ()
          |> Result.map wrap |> Result.map_error Lane_addon_worker.start_failure);
      acquire=Lane_addon_sources.acquire;
      package_ready=(fun ~package -> match package.execution with
        | Host_process _ -> native_package_ready package
        | Container _ ->
            let* clock = Option.to_result ~none:"container clock is unavailable" clock in
            Lane_addon_worker.inspect_image ~clock ~control_timeout_sec ~mgr:Posix_spawn_process_mgr.mgr ~package ()
            |> Result.map (fun (_ : string) -> ()) |> Result.map_error Lane_addon_worker.error_to_string);
      recover_stop=(fun ~state_owner ~instance_id ~authority ~resource -> match authority with
        | Lifecycle.Native_admission {installation_id} -> native_recover ~store ~installation_id ~instance_id
        | Container_authority {runtime;engine} ->
            let* container_id = match resource with
              | None -> Ok None | Some (Lifecycle.Container_resource id) -> Ok (Some id)
              | Some (Lifecycle.Native_resource _) -> Error (Lifecycle.Cleanup_unconfirmed "native identity cannot authorize container cleanup") in
            let* clock = Option.to_result ~none:(Lifecycle.Cleanup_unconfirmed "container clock is unavailable") clock in
            let* () = Lane_addon_worker.recover_stop ~clock ~control_timeout_sec ~mgr:Posix_spawn_process_mgr.mgr
              ~runtime ~instance_id ~container_id ~engine ?state_owner () |> Result.map_error Lane_addon_worker.cleanup_failure in
            Ok (Lifecycle.Released {engine;container_id}));
      condition_met=(fun ~runtime condition -> match clock with
        | None -> false
        | Some clock -> match condition with
          | Lifecycle.Engine_reachable -> Result.is_ok (Lane_addon_worker.read_engine ~clock ~control_timeout_sec ~mgr:Posix_spawn_process_mgr.mgr ~runtime ())
          | Engine_is expected -> (match Lane_addon_worker.read_engine ~clock ~control_timeout_sec ~mgr:Posix_spawn_process_mgr.mgr ~runtime () with
              | Ok actual -> Lifecycle.engine_equal actual expected | Error _ -> false)
          | Holder_changes holder -> Lane_addon_worker.holder_changed ~clock ~control_timeout_sec ~mgr:Posix_spawn_process_mgr.mgr ~runtime holder);
      sweep=(fun ~runtime ~is_live_instance ->
        let* clock = Option.to_result ~none:(Lifecycle.Worker_failed "container clock is unavailable") clock in
        Lane_addon_worker.sweep ~clock ~control_timeout_sec ~mgr:Posix_spawn_process_mgr.mgr ~runtime ~scope ~is_live_instance ()) }
let manager config =
  let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
  match Hashtbl.find_opt managers root with
  | Some m -> m
  | None -> let m = { store = Lane_addon_store.create ~root; base_path = config.base_path; entries = Hashtbl.create 8;
                     recovering = Hashtbl.create 4; configuration_mutex = Eio.Mutex.create ();
                     action_mutex = Eio.Mutex.create (); broadcast_mutex = Eio.Mutex.create ();
                     fleet_journals=Hashtbl.create 8;
                     fleet_operations=Hashtbl.create 8; fleet_recipients=Hashtbl.create 16; fleet_nudge=(fun () -> ());
                     configuration_status = None; configuration_nudge = (fun () -> ()); configuration_visibility=[];
                     swept = []; sweep_retries = Hashtbl.create 2; sweep_warned = Hashtbl.create 2 } in
      Hashtbl.add managers root m; m
let live_exports m access =
  entries m |> List.concat_map (fun (e : entry) ->
    if not e.started || e.stopping || not (can_read access e.visibility) then []
    else match phase_of e, e.connection with
      | (Attached | Observing), Some connection ->
          connection.worker.exported_tools () |> List.filter_map (fun (tool : Mcp_protocol.Mcp_types.tool) ->
            if List.mem tool.Mcp_protocol.Mcp_types.name e.package.exported_tools
            then Some (Lane_addon_tool_export.create ~owner:connection.export_owner ~tool) else None)
      | (Attached | Observing), None | (Failed _ | Detaching | Detached), _ -> [])

let unique_exports ~reserved exports =
  let names = List.map (fun export -> export.tool.Mcp_protocol.Mcp_types.name) exports in
  if List.exists (fun name -> List.mem name reserved) names then
    Error "Add-on export collides with a host tool"
  else if List.length names <> List.length (List.sort_uniq String.compare names) then
    Error "Add-on tool name is provided by multiple visible installations"
  else Ok exports

let tool_export_snapshot ~config ~access ~reserved = Eio_context.run_on_owner_domain (fun () ->
  let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
  let exports = match Hashtbl.find_opt managers root with
    | None -> [] | Some m -> live_exports m access in
  Lane_addon_tool_export.isolate ~reserved exports)

let tool_exports ~config ~access ~reserved = Eio_context.run_on_owner_domain (fun () ->
  let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
  match Hashtbl.find_opt managers root with
  | None -> Ok []
  | Some m -> unique_exports ~reserved (live_exports m access))

type export_observation = {
  instance_id : string;
  observation_seq : int;
  max_bytes : int;
  refreshing : bool;
  output : output;
}

let observation_for_export ~config ~access ~name = Eio_context.run_on_owner_domain (fun () ->
  let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
  match Hashtbl.find_opt managers root with
  | None -> Ok None
  | Some m ->
      let candidates = entries m |> List.filter (fun (e : entry) ->
        can_read access e.visibility && List.mem name e.package.exported_tools
        && match phase_of e with Detached | Detaching -> false | Attached | Observing | Failed _ -> true) in
      match candidates with
      | [] -> Ok None
      | [e] ->
          (match phase_of e with
           | Failed detail -> Error detail
           | Detaching | Detached -> Ok None
           | Attached | Observing ->
               if e.seq = 0 || not e.started || e.stopping then Error "machine worker observation is not available yet"
               else Ok (Some {instance_id=e.instance_id;observation_seq=e.seq;max_bytes=(Lane_addon_types.max_reply_bytes e.package);
                 refreshing=e.state = Lifecycle.Observing || e.pending <> Idle || e.active_tool_calls > 0 || Option.is_some e.current_action;output=e.output}))
      | _ -> Error "multiple visible installations provide this machine")

let with_tool_call_owner work =
  let cancelled, signal_cancelled = Eio.Promise.create () in
  try Eio_context.run_on_owner_domain (fun () ->
    (* The general owner dispatcher deliberately outlives its waiter. Tool
       invocations explicitly carry their caller's cancellation across domains. *)
    match Eio.Promise.peek cancelled with
    | Some exn -> raise exn
    | None -> Eio.Fiber.first work (fun () -> raise (Eio.Promise.await cancelled)))
  with Eio.Cancel.Cancelled _ as exn ->
    ignore (Eio.Promise.try_resolve signal_cancelled exn);
    raise exn

let call_exported_tool_with_authority ~on_complete ~on_result ~authorize ~principal ~config ~access ~reserved ~(export : tool_export) ~arguments =
  with_tool_call_owner (fun () ->
    Fun.protect ~finally:on_complete (fun () ->
    let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
    let* m = match Hashtbl.find_opt managers root with
      | Some m -> Ok m | None -> Error (Unavailable "Add-on owner is unavailable") in
    let snapshot = Lane_addon_tool_export.isolate ~reserved (live_exports m access) in
    let exports = snapshot.exports in
    let* () = if List.exists (fun (current : tool_export) ->
        Lane_addon_tool_export.equal_owner current.owner export.owner && current.tool = export.tool) exports then Ok ()
      else Error (Unavailable "Add-on tool installation is no longer available") in
    let* e, connection = match Hashtbl.find_opt m.entries export.instance_id with
      | Some ({connection=Some connection; _} as e)
        when Lane_addon_tool_export.equal_owner connection.export_owner export.owner -> Ok (e, connection.worker)
      | _ -> Error (Unavailable "Add-on tool connection is unavailable") in
    let* sw = match Eio_context.get_root_switch_opt () with
      | Some sw -> Ok sw | None -> Error (Unavailable "Add-on background owner is unavailable") in
    let worker_backend = backend ~store:m.store () in
    e.active_tool_calls <- e.active_tool_calls + 1;
    Fun.protect ~finally:(fun () -> e.active_tool_calls <- e.active_tool_calls - 1) (fun () ->
    try
      let principal = match principal with
        | Some principal -> principal
        | None -> match access with
          | Lane_addon_sources.Keeper name -> Lane_addon_call_context.Keeper name
          | Lane_addon_sources.Operator_configuration -> Lane_addon_call_context.Operator
          | Lane_addon_sources.Unauthenticated -> Lane_addon_call_context.Anonymous in
      let result = connection.call_exported_tool ~on_result ~authorize ~principal ~name:export.tool.name ~arguments in
      (* Worker-owned state is not an input source, so source-change hints alone
         cannot reveal a tool's effect. Refresh its observation after a completed
         reply, including a worker error that may have changed machine state. *)
      (match result with
       | Ok _ -> if not e.stopping then wake e
       | Error (Lane_addon_call_context.Host_refusal _) -> ()
       | Error (Lane_addon_call_context.Transport_error detail) ->
           if not e.stopping then (
             failed m e (Lifecycle.Effect_outcome_unknown ("tool outcome unknown: " ^ detail));
             wake e));
      result |> Result.map_error (function
        | Lane_addon_call_context.Host_refusal refusal -> Host_refusal refusal
        | Transport_error detail -> Outcome_unknown detail)
    with Eio.Cancel.Cancelled _ as exn ->
      (* This caller has a shorter lifetime than the observer. Retire both
         projections before handing cleanup to the server-owned switch. *)
      Eio.Cancel.protect (fun () ->
        e.stopping <- true;
        e.state <- fail_state e (Lifecycle.Effect_outcome_unknown "exported tool call cancelled; effect outcome unknown");
        notify_tool_change e.package;
        (match persist m e with Ok () -> () | Error detail ->
          Log.Misc.error "Cancelled Add-on tool state persistence: %s" detail);
        stop_entry ~sw ~backend:worker_backend m e);
      raise exn)))

let call_exported_tool_with_principal = call_exported_tool_with_authority ~on_complete:(fun () -> ()) ~on_result:(fun _ -> ()) ~authorize:None

let call_exported_tool = call_exported_tool_with_principal ~principal:None

(* Entries and their wake promises belong to the root-switch owner domain. A
   caller on the HTTP serving domain or a pool worker is carried there, like
   [dispatch], instead of being dropped. *)
let notify_activity ~config ~activity = Eio_context.run_on_owner_domain (fun () ->
  let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
  match Hashtbl.find_opt managers root with
  | None -> ()
  | Some m -> Hashtbl.iter (fun _ e ->
      if e.running && not e.stopping
        && Lane_addon_sources.interested e.refresh_interest activity
      then wake ~request:Refresh_sources e) m.entries)
let notify_fusion_run ~run_id = Eio_context.run_on_owner_domain (fun () ->
  Hashtbl.iter (fun _ m ->
    Hashtbl.iter (fun _ e ->
      if e.running && not e.stopping
        && Lane_addon_sources.interested e.refresh_interest
             (Lane_addon_sources.Fusion_changed run_id)
      then wake ~request:Refresh_sources e) m.entries) managers)
let find m args = let* id = text args "instance_id" in
  match Hashtbl.find_opt m.entries id with Some e -> Ok e | None -> Error "unknown active instance"
let recovery_bindings m bindings =
  let retained = List.filter (function
    | `Assoc fields -> (match List.assoc_opt "instance_id" fields with
        | Some (`String id) -> not (Hashtbl.mem m.recovering id) | _ -> true)
    | _ -> true) bindings in
  let pending = Hashtbl.to_seq_values m.recovering |> List.of_seq |> List.map (fun recovery ->
    let fields,state = match recovery with
      | Cleaning fields -> fields,Lifecycle.Detaching (failed_in fields)
      | Publishing_cleanup publication -> publication.fields,Lifecycle.Detaching (failed_in publication.fields)
      | Cleanup_request_failed (fields,message) ->
          fields,failed_after fields (Lifecycle.Persistence_failed ("cleanup request persistence: " ^ message))
      | Cleanup_unconfirmed (fields,message) ->
          fields,failed_after fields (Lifecycle.Cleanup_unconfirmed message)
      | Cleanup_commit_failed (publication,message) ->
          publication.fields,failed_after publication.fields (Lifecycle.Persistence_failed ("cleanup state persistence: " ^ message)) in
    replace_state fields state) in
  retained @ pending
let read_retained_bindings m =
  let* stored = offload (fun () -> Lane_addon_store.read_bindings m.store) in
  let parsed = split_retained (recovery_bindings m stored.readable) in
  Ok { parsed with faults = parsed.faults @ List.map fault_of_unreadable stored.unreadable }
let is_live m (binding : retained_binding) =
  match List.assoc_opt "instance_id" binding.binding_fields with
  | Some (`String id) -> Hashtbl.mem m.entries id
  | _ -> false
let historical m =
  let* reading = read_retained_bindings m in
  Ok { reading with readable = List.filter (fun binding -> not (is_live m binding)) reading.readable }
let inventory_at_root ~root =
  let stored = offload (fun () -> Lane_addon_store.binding_inventory ~root) in
  let manager = Hashtbl.find_opt managers root in
  let live = match manager with
    | None -> []
    | Some m -> entries m |> List.map (fun (e : entry) ->
        { instance_id=e.instance_id; incarnation=e.instance_id; run_id=e.run_id;
          package_id=e.package.id; title=e.package.title; package_revision=e.package.revision;
          configuration=e.configuration; presence=Live; phase=phase_of e }) in
  let pending = match manager with None -> [] | Some m -> recovery_bindings m [] in
  let records = List.filter (fun (_,json) -> match manager,json with
    | Some m,`Assoc fields -> (match text fields "instance_id" with
        | Ok id -> not (Hashtbl.mem m.recovering id) | Error _ -> true)
    | None,_ | Some _,_ -> true) stored.records in
  let decode path json =
    let invalid result = Result.map_error (fun detail -> Record_invalid detail) result in
    let* () = invalid (unique_json json) in
    let* fields = match json with
      | `Assoc fields -> Ok fields
      | _ -> invalid (Error "expected an object") in
    let* _visibility = read_authority fields in
    let* instance_id = invalid (text fields "instance_id") in
    let* () = match path with
      | None -> Ok () (* In-process cleanup owns this already-admitted record. *)
      | Some path when Filename.basename path = Lane_addon_store.digest instance_id ^ ".json" -> Ok ()
      | Some _ -> invalid (Error "binding filename does not match its instance identity") in
    let* incarnation = invalid (text fields "incarnation") in
    let* () = if incarnation=instance_id then Ok ()
      else invalid (Error "retained incarnation does not match its instance identity") in
    let* run_id = invalid (text fields "run_id") in
    let* package_id = invalid (text fields "addon_id") in
    let* title = invalid (text fields "title") in
    let* package_revision = invalid (text fields "revision") in
    let* configuration = match List.assoc_opt "configuration" fields with
      | None -> invalid (Error "missing retained configuration owner")
      | Some _ -> invalid (configuration_of_fields fields) in
    let* state = invalid (lifecycle_of_fields fields) in
    let state = match state with
      | Lifecycle.Detached release -> Lifecycle.Detached release
      | Lifecycle.Failed failed -> Lifecycle.Failed failed
      | Lifecycle.Detaching previous when Option.exists (fun m -> Hashtbl.mem m.recovering instance_id) manager ->
          Lifecycle.Detaching previous
      | Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching _ ->
          Lifecycle.Failed (Lifecycle.failed Lifecycle.Previous_process) in
    Ok {instance_id;incarnation;run_id;package_id;title;package_revision;
        configuration;presence=Retained;phase=Lifecycle.project state} in
  let owner_of_json = function `Assoc fields -> owner_of_fields fields | _ -> Owner_unreadable in
  let stored_issues = List.map (fun (path, detail) ->
    { issue_path = path; issue_owner = Owner_unreadable; issue_terminal = false;
      issue_reason = Store_unreadable detail }) stored.issues in
  let retained,issues = List.fold_left (fun (values,issues) (path,json) ->
    match decode path json with
    | Error reason ->
        let owner = owner_of_json json in
        let terminal = match json with `Assoc fields -> owner_is_terminal owner fields | _ -> false in
        values,{ issue_path = Option.value ~default:root path; issue_owner = owner;
                 issue_terminal = terminal; issue_reason = reason }::issues
    | Ok value when List.exists (fun (current : inventory_instance) ->
        current.instance_id=value.instance_id) live -> values,issues
    | Ok value -> value::values,issues) ([],stored_issues) (List.map (fun (path,json) -> Some path,json) records
      @ List.map (fun json -> None,json) pending) in
  {owner_present=Option.is_some manager;
   instances=List.sort (fun (a : inventory_instance) b -> String.compare a.instance_id b.instance_id) (live @ retained);
   issues=List.sort_uniq Stdlib.compare issues; complete=stored.complete && issues=[]}
let inventory_issue_message (issue : inventory_issue) =
  issue.issue_path ^ ": " ^ retained_fault_message issue.issue_reason
let inventory ~config = Eio_context.run_on_owner_domain (fun () ->
  inventory_at_root ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons"))
let persisted_binding m id =
  let* reading = runtime_result (read_retained_bindings m) in
  let named (binding : retained_binding) = match text binding.binding_fields "instance_id" with
    | Ok found -> String.equal found id | Error _ -> false in
  match List.find_opt named reading.readable with
  | Some binding -> Ok binding.binding_fields
  | None ->
      (match List.find_opt (fun fault -> fault.fault_instance = Some id) reading.faults with
       | Some fault -> Error (Runtime_failed (retained_fault_message fault.fault_reason))
       | None -> Error (Request_rejected "Lane instance is unavailable to this caller"))
type cleanup_writer = store:Lane_addon_store.t -> instance_id:string -> Yojson.Safe.t option -> (unit,string) result
let cleanup_writer_key : cleanup_writer Eio.Fiber.key = Eio.Fiber.create_key ()
let default_cleanup_writer ~store ~instance_id = function
  | None -> Lane_addon_store.remove_binding store ~instance_id
  | Some json -> Lane_addon_store.save_binding store ~instance_id json
let publish_cleanup m ~id ~writer publication =
  Hashtbl.replace m.recovering id (Publishing_cleanup publication);
  let persisted =
    try offload (fun () -> writer ~store:m.store ~instance_id:id publication.terminal) with
    | Eio.Cancel.Cancelled _ as exn ->
        Hashtbl.replace m.recovering id (Cleanup_commit_failed (publication,"publication cancelled"));
        raise exn
    | exn -> Error (Printexc.to_string exn) in
  match persisted with
  | Ok () ->
      Hashtbl.remove m.recovering id;
      if is_detached publication.terminal_state then m.configuration_nudge ()
  | Error message ->
      (* Keep the owner even after rename/unlink. The next maintenance beat
         retries only publication: successful resource release is not replayed. *)
      Hashtbl.replace m.recovering id (Cleanup_commit_failed (publication,message));
      Log.Misc.error "Lane recovered cleanup persistence: %s" message
let fork_recovery ~sw m ~id ~on_failure work =
  (* Cancellation can occur while scheduling, before the child starts. Keep
     the same retry obligation as a cancellation inside its work. *)
  try fork_isolated ~sw work with
  | Eio.Cancel.Cancelled _ as exn ->
      Hashtbl.replace m.recovering id (on_failure (Printexc.to_string exn)); raise exn
  | exn -> Hashtbl.replace m.recovering id (on_failure (Printexc.to_string exn)); raise exn
(* [wait] runs the work in the caller's fiber, so the caller can read how the
   cleanup ended. *)
let run_recovery ~sw ~wait m ~id ~on_failure work =
  if wait then
    (try work () with exn ->
       Hashtbl.replace m.recovering id (on_failure (Printexc.to_string exn)); raise exn)
  else fork_recovery ~sw m ~id ~on_failure work

(* What a retained record's cleanup came to by the time the call returned. *)
type detach_outcome =
  | Already_detached
  | In_progress  (* another cleanup of this record is still running *)
  | Started      (* forked; its result is published later *)
  | Finished of Lifecycle.state

let historical_detach ~sw ?(wait = false) m fields =
  let* id = text fields "instance_id" in
  let* previous = lifecycle_of_fields fields in
  let writer = Option.value ~default:default_cleanup_writer (Eio.Fiber.get cleanup_writer_key) in
  match Hashtbl.find_opt m.recovering id with
  | Some (Cleaning _ | Publishing_cleanup _) ->
      Ok (replace_state fields (Lifecycle.Detaching (failed_in fields)), In_progress)
  | Some (Cleanup_commit_failed (publication,_)) ->
      Hashtbl.replace m.recovering id (Publishing_cleanup publication);
      run_recovery ~sw ~wait m ~id ~on_failure:(fun detail -> Cleanup_commit_failed (publication,detail))
        (fun () -> publish_cleanup m ~id ~writer publication);
      Ok (replace_state fields (Lifecycle.Detaching (failed_in fields)),
          if wait then Finished publication.terminal_state else Started)
  | None when is_detached previous -> Ok (`Assoc fields, Already_detached)
  | None | Some (Cleanup_request_failed _ | Cleanup_unconfirmed _) ->
    let* authority,resource = retained_execution fields in
    let* seq = match List.assoc_opt "observation_seq" fields with
      | Some (`Int n) when n >= 0 -> Ok n
      | _ -> Error "missing persisted observation sequence" in
    let* package = match List.assoc_opt "package" fields with
      | Some json -> object_ json | None -> Error "missing persisted package" in
    let* run_id = text fields "run_id" in
    let* retained_runtime = retained_runtime package in
    let* package_id = text package "id" in
    let* package_revision = text package "revision" in
    let* configuration = configuration_of_fields fields in
    let* state_storage = match List.assoc_opt "state_storage" package with
      | None | Some (`String "ephemeral") -> Ok Ephemeral
      | Some (`String "persistent") -> Ok Persistent
      | Some _ -> Error "invalid retained state storage" in
    let* state_owner = state_owner_for ~store:m.store ~instance_id:id ~package_id
        ~configuration state_storage in
    let* () = match authority,retained_runtime with
      | None,_ -> Ok ()
      | Some (Lifecycle.Container_authority owned),Some runtime when owned.runtime=runtime -> Ok ()
      | Some (Lifecycle.Native_admission owned),None ->
          let expected = match configuration with Some owner -> owner.id | None -> id in
          if owned.installation_id=expected then Ok () else Error "native installation authority mismatch"
      | Some (Lifecycle.Container_authority _ | Lifecycle.Native_admission _),(None | Some _) ->
          Error "retained execution authority differs from package runtime" in
    let detaching = replace_state fields (Lifecycle.Detaching (failed_in fields)) in
    Hashtbl.replace m.recovering id (Cleaning fields);
    let intent =
      try offload (fun () -> Lane_addon_store.save_binding m.store ~instance_id:id detaching) with
      | Eio.Cancel.Cancelled _ as exn ->
          Hashtbl.replace m.recovering id (Cleanup_request_failed (fields,"publication cancelled"));
          raise exn
      | exn -> Error (Printexc.to_string exn) in
    let* () = match intent with
      | Ok () -> Ok ()
      | Error message -> Hashtbl.replace m.recovering id (Cleanup_request_failed (fields,message)); Error message in
    let backend = backend ~store:m.store () in
    let finished = ref None in
    run_recovery ~sw ~wait m ~id ~on_failure:(fun detail -> Cleanup_unconfirmed (fields,detail)) (fun () ->
      let result = match authority with
        | None -> check_release ~instance_id:id ~authority ~resource Lifecycle.Never_created
        | Some owner ->
            (try backend.recover_stop ~state_owner ~instance_id:id ~authority:owner ~resource with
             | Eio.Cancel.Cancelled _ as exn ->
                 Hashtbl.replace m.recovering id (Cleanup_unconfirmed (fields,"cleanup cancelled before its result was confirmed"));raise exn
             | exn -> Error (Lifecycle.Cleanup_unconfirmed (Printexc.to_string exn)))
            |> fun result -> let* release = result in check_release ~instance_id:id ~authority ~resource release in
      let state = match result with
        | Ok release -> Lifecycle.Detached release | Error failure -> failed_after fields failure in
      finished := Some state;
      let terminal =
        if is_detached state && never_started ~seq ~authority ~resource
        then None else Some (replace_state fields state) in
      let publication = {fields;terminal;terminal_state=state} in
      (* Event publication can yield. The cleanup result already exists, so
         preserve its storage obligation before reporting the resource event. *)
      Hashtbl.replace m.recovering id (Publishing_cleanup publication);
      (try
         (* A log call that raises is a publication failure like the rest of
            this block: the obligation is kept and the next beat retries it. *)
         (match result with
          | Ok _ -> ()
          | Error failure -> log_cleanup_failure id package_id resource failure);
         Lane_addon_resource_events.publish
           (match result with
            | Ok _ -> Lane_addon_resource_events.Release_confirmed
            | Error _ -> Lane_addon_resource_events.Release_incomplete)
           { instance_id = id; run_id; package_id; package_revision;
             resource;
             detail = (match result with Ok _ -> None | Error failure -> Some (Lifecycle.failure_detail failure)) };
         publish_cleanup m ~id ~writer publication
       with
       | Eio.Cancel.Cancelled _ as exn ->
           Hashtbl.replace m.recovering id (Cleanup_commit_failed (publication,"result publication cancelled"));
           raise exn
       | exn ->
           Hashtbl.replace m.recovering id (Cleanup_commit_failed (publication,Printexc.to_string exn));
           raise exn));
    Ok (detaching, if not wait then Started else
          match !finished with Some state -> Finished state | None -> In_progress)
let configuration_json m ~access =
  match m.configuration_status with
  | None -> `Null
  | Some reading ->
      let operator = match access with
        | Lane_addon_sources.Operator_configuration -> true
        | Keeper _ | Unauthenticated -> false in
      let visible id = operator || List.exists (fun (known, visibility) ->
        known = id && can_read access visibility) m.configuration_visibility in
      (* This read observes durable cleanup and current live owners. It never
         reconciles or nudges a retry. Read after the filesystem offload so that
         live state is captured back on its owner domain. *)
      let inventory = if operator then Some (inventory_at_root ~root:(Lane_addon_store.root m.store)) else None in
      let nullable = function None -> `Null | Some value -> `String value in
      let declaration (d : Lane_addon_config.declaration) =
        let live = entries m |> List.filter (fun e -> match e.configuration with
          | Some owner -> owner.id = d.id | None -> false) in
        let active = match live with [e] -> Some e | [] | _ :: _ -> None in
        let application = match inventory with
          | None -> Lane_addon_application.Unknown ["Application tracking requires operator access"]
          | Some inventory ->
              let workers = inventory.instances |> List.filter_map (fun (item : inventory_instance) ->
                match item.configuration with
                | None -> None
                | Some owner when owner.id <> d.id && owner.source_path <> d.source_path -> None
                | Some owner ->
                    let activity = match item.presence with
                      | Retained -> (match item.phase with
                          | Detached -> Lane_addon_application.Stopped
                          | Detaching -> Stopping
                          | Failed detail -> Worker_failed detail
                          | Attached | Observing -> Starting)
                      | Live -> (match Hashtbl.find_opt m.entries item.instance_id with
                          | None -> Lane_addon_application.Stopping
                          | Some e -> match phase_of e with
                              | Failed detail -> Worker_failed detail
                              | Detached when not e.running && not e.cleanup_running -> Stopped
                              | Detached | Detaching -> Stopping
                              | Attached | Observing when e.stopping -> Stopping
                              | Attached | Observing ->
                                  if e.running && e.started then Running else Starting) in
                    Some {Lane_addon_application.instance_id=item.instance_id;
                      matches_desired=owner.id=d.id && owner.source_path=d.source_path && owner.revision=d.revision;
                      activity}) in
              let issues = reading.issues |> List.filter_map (fun (issue : Lane_addon_config.issue) ->
                if issue.source_path=reading.directory || issue.source_path=d.source_path || issue.id=Some d.id
                then Some issue.message else None) in
              (* A record that names another declaration says nothing about
                 this one. A record whose owner cannot be read could be any
                 declaration's worker, so it leaves every reading incomplete.
                 A detached record that names this one holds no worker; it is
                 listed for the operator and leaves the reading complete. *)
              let concerns = List.filter (fun (issue : inventory_issue) ->
                owner_concerns ~id:d.id ~source_path:d.source_path issue.issue_owner
                && not issue.issue_terminal) inventory.issues in
              let unattributed = List.exists (fun (issue : inventory_issue) ->
                match issue.issue_owner with
                | Owner_unreadable -> true
                | Owned_by _ | Unowned -> false) inventory.issues in
              Lane_addon_application.observe ~enabled:d.enabled
                ~complete:(reading.snapshot.complete && not unattributed)
                ~issues:(issues @ List.map inventory_issue_message concerns) ~workers in
        `Assoc ["id", `String d.id; "source_path", `String d.source_path; "enabled", `Bool d.enabled;
          "source_revision", `String d.source_revision;
          "desired_revision", `String d.revision;
          "applied_revision", nullable (Option.bind active (fun e -> Option.map (fun owner -> owner.revision) e.configuration));
          "instance_id", nullable (Option.map (fun (e : entry) -> e.instance_id) active);
          "application", Lane_addon_application.to_json application] in
      (* Unreadable retained records are read at this call, not at the last
         reconciliation, and are listed for the operator beside the
         reconciliation's own issues. *)
      let unreadable = match inventory with
        | None -> []
        | Some inventory -> List.map (fun (issue : inventory_issue) ->
            let source_path, id = match issue.issue_owner with
              | Owned_by owner -> owner.source_path, `String owner.id
              | Unowned | Owner_unreadable -> issue.issue_path, `Null in
            `Assoc ["source_path", `String source_path; "id", id;
              "message", `String (inventory_issue_message issue)]) inventory.issues in
      `Assoc ["directory", `String reading.directory; "complete", `Bool reading.snapshot.complete;
        "issues", `List (reading.issues |> List.filter (fun (issue : Lane_addon_config.issue) ->
          operator || Option.exists visible issue.id) |> List.map (fun (issue : Lane_addon_config.issue) ->
            `Assoc ["source_path", `String issue.source_path; "id", nullable issue.id; "message", `String issue.message])
          |> fun listed -> listed @ unreadable);
        "declarations", `List (reading.snapshot.declarations |> List.filter (fun (d : Lane_addon_config.declaration) -> visible d.id)
          |> List.map declaration)]
let snapshot m ~access ?instance_id () =
  let* reading = historical m in
  let live = entries m |> List.filter (fun e ->
    can_read access e.visibility && Option.fold ~none:true ~some:(String.equal e.instance_id) instance_id) in
  let past = List.filter (fun (binding : retained_binding) ->
    Option.fold ~none:true ~some:(fun id ->
      List.assoc_opt "instance_id" binding.binding_fields = Some (`String id)) instance_id
    && can_read access binding.read_visibility) reading.readable in
  let* () = if Option.is_some instance_id && live = [] && past = []
    then
      (* An operator asking for one instance is told its record is unreadable;
         any other caller learns nothing about an unreadable record. *)
      match access, List.find_opt (fun fault -> fault.fault_instance = instance_id) reading.faults with
      | Lane_addon_sources.Operator_configuration, Some fault -> Error (retained_fault_message fault.fault_reason)
      | Lane_addon_sources.Operator_configuration, None
      | Keeper _, _ | Unauthenticated, _ -> Error "Lane instance is unavailable to this caller"
    else Ok () in
  let retained (binding : retained_binding) =
    let fields = binding.binding_fields in
    let state = match lifecycle_of_fields fields with
      | Ok (Lifecycle.Detached release) -> Lifecycle.Detached release
      | Ok (Lifecycle.Failed failed) -> Lifecycle.Failed failed
      | Ok (Lifecycle.Detaching previous) when (match text fields "instance_id" with
          | Ok id -> Hashtbl.mem m.recovering id | Error _ -> false) -> Lifecycle.Detaching previous
      | Ok (Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching _) | Error _ ->
          Lifecycle.Failed (Lifecycle.failed Lifecycle.Previous_process) in
    `Assoc (("runtime_presence", `String "retained")
      :: ("phase", phase_to_json (Lifecycle.project state))
      :: ("lifecycle", Lifecycle.state_to_json state)
      :: ("configuration", Option.fold ~none:`Null ~some:configuration_owner_json binding.binding_owner)
      :: (fields |> List.remove_assoc "runtime_presence"
          |> List.remove_assoc "phase" |> List.remove_assoc "lifecycle"
          |> List.remove_assoc "configuration")) in
  let past = List.map retained past in
  let output = { rows = List.concat_map (fun (e : entry) -> e.output.rows) live;
    coverage = List.concat_map (fun e -> status_coverage e :: e.output.coverage) live } in
  let live_json entry = match entry_json entry with
    | `Assoc fields -> `Assoc (("runtime_presence", `String "live")
        :: ("host_requests", host_status_json entry.host_status) :: fields)
    | _ -> assert false in
  match output_to_json output with
  | `Assoc fields -> Ok (`Assoc (("configuration", configuration_json m ~access)
      :: ("instances", `List (List.map live_json live @ past)) :: fields))
  | _ -> assert false
(* An unreadable record has no recorded reader, so it cannot be shown to
   anyone but the operator. Every caller still learns that the reading is
   incomplete. *)
let unreadable_coverage ~access faults =
  match access, faults with
  | (Lane_addon_sources.Operator_configuration | Keeper _ | Unauthenticated), [] -> []
  | Lane_addon_sources.Operator_configuration, _ :: _ ->
      List.map (fun fault ->
        let source_id = Option.value ~default:"unnamed-retained-binding" fault.fault_instance in
        { source_id; incarnation = source_id; cursor = None; complete = false;
          detail = Some (retained_fault_message fault.fault_reason) }) faults
  | (Keeper _ | Unauthenticated), _ :: _ ->
      [{ source_id = "unreadable-retained-bindings"; incarnation = "unreadable-retained-bindings";
         cursor = None; complete = false;
         detail = Some (Printf.sprintf "%d retained bindings cannot be read" (List.length faults)) }]
let slice m ~access args =
  let optional_text key = match List.assoc_opt key args with
    | None -> Ok None | Some _ -> Result.map Option.some (text args key) in
  let optional_time key = match List.assoc_opt key args with
    | None -> Ok None | Some (`Int n) -> Ok (Some (float_of_int n))
    | Some (`Float t) when Float.is_finite t -> Ok (Some t)
    | _ -> Error (key ^ " requires a finite epoch timestamp") in
  let* run_id = request_result (optional_text "run_id") in let* lane_id = request_result (optional_text "lane_id") in
  let* since = request_result (optional_time "since") in let* until = request_result (optional_time "until") in
  let* () = match since, until with Some a, Some b when a > b -> Error (Request_rejected "since exceeds until") | _ -> Ok () in
  let* reading = runtime_result (read_retained_bindings m) in
  let rec read acc statuses = function
    | [] -> Ok (List.rev acc, List.rev statuses)
    | (binding : retained_binding) :: rest ->
        let fields = binding.binding_fields in
        let* id = text fields "instance_id" in let* run = text fields "run_id" in
        if not (can_read access binding.read_visibility)
          || Option.fold ~none:false ~some:(fun selected -> selected <> run) run_id then read acc statuses rest
        else
          let* package = match List.assoc_opt "package" fields with Some json -> object_ json | None -> Error "missing retained package" in
          let* resources = match List.assoc_opt "resources" package with Some json -> object_ json | None -> Error "missing retained resources" in
          let* max_bytes = match List.assoc_opt "max_reply_bytes" resources with
            | Some (`Int value) when value > 0 -> Ok value | _ -> Error "missing retained query byte envelope" in
          let* expected_seq = match List.assoc_opt "observation_seq" fields with
            | Some (`Int value) when value >= 0 -> Ok value | _ -> Error "missing retained sequence" in
          let* output = offload (fun () -> Lane_addon_store.query_observations m.store
            ~instance_id:id ~expected_seq ~max_bytes ~since ~until ~lane_id) in
          let status = match Hashtbl.find_opt m.entries id with
            | Some e -> status_coverage e
            | None ->
                let detached = record_is_detached fields in
                { source_id = id; incarnation = id; cursor = Some (string_of_int expected_seq);
                  complete = detached && expected_seq > 0;
                  detail = Some (if detached then "detached; retained range only"
                    else "previous process; current observation and cleanup state are unknown") } in
          read (output :: acc) (status :: statuses) rest in
  let* outputs, statuses = runtime_result (read [] [] reading.readable) in
  (* Each instance response is bounded by its own declared resource envelope.
     File parsing and filtering happened outside the owner domain. *)
  let rows = List.concat_map (fun output -> output.rows) outputs in
  let coverage = List.concat_map (fun output -> output.coverage) outputs @ statuses
    @ unreadable_coverage ~access reading.faults in
  let complete = outputs <> [] && List.for_all (fun (c : coverage) -> c.complete) coverage in
  match output_to_json { rows; coverage } with
  | `Assoc fields -> Ok (`Assoc (("complete", `Bool complete) :: fields))
  | _ -> assert false

let validate_connection m ~run_id ~configuration_id ~binding =
  let* input_installations = Lane_addon_sources.dependencies binding in
  let graph = entries m |> List.filter_map (fun e -> match e.configuration with
    | Some o when not e.stopping && e.run_id = run_id -> Some (o.id, e.input_installations)
    | _ -> None) in
  let graph = (configuration_id, input_installations) :: List.remove_assoc configuration_id graph in
  let rec visit trail id =
    if List.mem id trail then Error ("cyclic lane_output connection: " ^ String.concat " -> " (List.rev (id :: trail)))
    else match List.assoc_opt id graph with
      | None -> Ok () (* An unavailable upstream has no active dependency edges. *)
      | Some dependencies -> List.fold_left (fun result dependency ->
          let* () = result in visit (id :: trail) dependency) (Ok ()) dependencies in
  let* () = visit [] configuration_id in
  Ok input_installations

let validate_live_connections m candidate =
  let nodes = candidate :: List.filter (fun (e : entry) -> not e.stopping) (entries m) in
  let complete = Hashtbl.create (List.length nodes) in
  let rec visit trail (node : entry) =
    if List.mem node.instance_id trail then Error "cyclic Lane source connection, including implicit machine inputs"
    else if Hashtbl.mem complete node.instance_id then Ok ()
    else
      let* () = List.fold_left (fun result producer ->
        let* () = result in
        if depends_on ~consumer:node ~producer then visit (node.instance_id::trail) producer else Ok ())
        (Ok ()) nodes in
      Hashtbl.add complete node.instance_id (); Ok () in
  List.fold_left (fun result node -> let* () = result in visit [] node) (Ok ()) nodes

let binding_visibility m ~access ?resolve_visibility binding =
  let* sources = Lane_addon_sources.parse binding in
  let merge left right = match left, right with
    | Shared, value | value, Shared -> value
    | Keeper_only a, Keeper_only b when String.equal a b -> Keeper_only a
    | Operator_only, _ | _, Operator_only | Keeper_only _, Keeper_only _ -> Operator_only in
  List.fold_left (fun result source ->
    let* current = result in
    let* restriction = match source with
      | Lane_addon_sources.Fusion_run {run_id;_} ->
          Lane_addon_sources.fusion_owner ~access ~run_id |> Result.map (fun keeper -> Keeper_only keeper)
      | Lane_output {installation_id;_} ->
          let* visibility = match resolve_visibility with
            | Some resolve -> resolve installation_id
            | None -> (match entries m |> List.filter (fun e -> match e.configuration with
                | Some owner -> String.equal owner.id installation_id | None -> false) with
              | [producer] -> Ok producer.visibility
              | [] -> (match List.assoc_opt installation_id m.configuration_visibility with
                  | Some visibility -> Ok visibility
                  | None -> Error "upstream installation is unavailable to this caller")
              | _ -> Error "upstream installation identity is ambiguous") in
          let* () = require_read access visibility
            |> Result.map_error (fun _ -> "upstream installation is unavailable to this caller") in
          Ok visibility
      | Snapshot_file _ | Msx_capture _ | Dos_capture _ | Browser_document _ -> Ok Shared in
    Ok (merge current restriction)) (Ok Shared) sources
let preserve_state_runtime ~configuration ~(package : package) bindings =
  match configuration, package.state_storage with
  | None, _ | Some _, Ephemeral -> Ok ()
  | Some (owner : configuration_owner), Persistent ->
      List.fold_left (fun result value ->
        let* () = result in
        let* fields = object_ value in
        let* previous_owner = configuration_of_fields fields in
        match previous_owner with
        | Some previous when previous.id = owner.id ->
            let* previous_package = match List.assoc_opt "package" fields with
              | Some value -> object_ value | None -> Error "missing retained package" in
            let* previous_id = text previous_package "id" in
            if previous_id <> package.id
               || List.assoc_opt "state_storage" previous_package <> Some (`String "persistent")
            then Ok ()
            else
              let* previous_runtime = retained_runtime previous_package in
              if previous_runtime = Lane_addon_types.container_runtime package then Ok ()
              else Error "Persistent state belongs to a different runtime; use a new installation id"
        | None | Some _ -> Ok ()) (Ok ()) bindings

(* A terminal fault holds no worker, but its own fields still say which
   runtime wrote persistent state, so [preserve_state_runtime] reads them. *)
let fault_is_terminal fault = owner_is_terminal fault.fault_owner fault.fault_fields
(* Unreadable records that may hold this declaration's worker or its privacy
   owner and cannot be checked. *)
let blocking_faults ~id ~source_path faults =
  List.filter (fun fault -> owner_concerns ~id ~source_path fault.fault_owner
    && not (fault_is_terminal fault)) faults
let terminal_fault_records ~id ~source_path faults =
  List.filter_map (fun fault ->
    if owner_concerns ~id ~source_path fault.fault_owner && fault_is_terminal fault
    then Some (`Assoc fault.fault_fields) else None) faults

let attach_entry ~sw m ~run_id ~package ~binding ~configuration ~source_access ~visibility =
  (* An image that is not on the host is not a worker that failed. Creating one
     would fail the same way on every attempt and leave an instance behind each
     time (#37897). Every caller looks first, so a declaration and a direct
     Attach both stop before an instance exists. *)
  let* () = (backend ~store:m.store ()).package_ready ~package in
  (* Record grants are checked before an instance exists (RFC operator-quiz
     §4.5): only an operator-owned declaration may hold them. *)
  let* (_ : Lane_addon_records.grant list) =
    Lane_addon_records.grants ~operator_owned:(operator_owned ~configuration ~source_access) binding in
  let* () = match configuration, package.state_storage with
    | None, _ | Some _, Ephemeral -> Ok ()
    | Some owner, Persistent ->
        let* reading = read_retained_bindings m in
        let* () = match blocking_faults ~id:owner.id ~source_path:owner.source_path reading.faults with
          | [] -> Ok ()
          | _ :: _ -> Error "Persistent state cannot be checked while this installation has unreadable retained bindings" in
        preserve_state_runtime ~configuration ~package
          (List.map (fun (binding : retained_binding) -> `Assoc binding.binding_fields) reading.readable
           @ terminal_fault_records ~id:owner.id ~source_path:owner.source_path reading.faults) in
  let* refresh_interest = Lane_addon_sources.refresh_interest binding in
  let* input_installations = match configuration with
    | None -> Lane_addon_sources.dependencies binding
    | Some owner -> validate_connection m ~run_id ~configuration_id:owner.id ~binding in
  let promise, resolver = Eio.Promise.create () in
  let e = { instance_id = Random_id.uuid_v7 (); run_id; package; binding;
    state = Lifecycle.Attached; authority = None; seq = 0; output = {rows=[];coverage=[]}; connection = None;
    stopping = false; cleanup_running = false; changed = Eio.Condition.create (); wake = promise; resolver; pending = Idle;
    refresh_interest; source_access; visibility; last_committed_sources=None; unchanged_source_refreshes=0;
    running = true; started = false; active_tool_calls = 0; persistence_mutex = Eio.Mutex.create (); coalesced_wakes = 0;
    action_queue = Queue.create (); current_action = None;
    host_due = false; host_status = { cycles = 0; waiting = []; issue = None };
    cancel_worker = None; configuration; input_installations } in
  let* () = validate_live_connections m e in
  (* Construction only validates the registered host boundary. Discard this
     root-switch closure: backend.start constructs the actual callback with
     the worker switch, so provider work cannot outlive its worker. *)
  let* _prepared = prepare_sampling_handler ~sw ~store:m.store
    ~instance_id:e.instance_id ~package ~binding in
  let* () = persist m e in
  Hashtbl.add m.entries e.instance_id e;
  wake e; run ~sw (backend ~store:m.store ()) m e;
  Ok (entry_json e)

let detach_entry ~sw m e =
  (match e.state with
   | Lifecycle.Detached _ -> ()
   | Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching _ | Lifecycle.Failed _ ->
    let earlier = match e.state with
      | Lifecycle.Failed failed | Lifecycle.Detaching (Some failed) -> Some failed
      | Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching None | Lifecycle.Detached _ -> None in
    e.stopping <- true; e.state <- Lifecycle.Detaching earlier; notify_tool_change e.package; wake e;
    wake_dependents m e;
    stop_entry ~sw ~backend:(backend ~store:m.store ()) m e);
  let* () = persist m e in Ok (entry_json e)

let configuration_directory config =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path:config.Workspace.base_path in
  Filename.concat resolution.config_root.path "lane-addons"

let edit_directory config =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path:config.Workspace.base_path in
  match resolution.status with
  | Config_dir_resolver.Invalid_env_status -> Error {Lane_addon_declaration.code=Io_error;
      message=String.concat "; " resolution.warnings; current=None}
  | Ready | Warn | Missing_status -> Ok (Filename.concat resolution.config_root.path "lane-addons")

let authorize_document m ~access (document : Lane_addon_declaration.document) =
  match access with
  | Lane_addon_sources.Operator_configuration -> Ok ()
  | Keeper _ | Unauthenticated ->
      let* ownership = offload (fun () -> Lane_addon_document_owner.read
        ~root:(Lane_addon_store.root m.store) ~source_path:document.source_path)
        |> Result.map_error (fun message -> {Lane_addon_declaration.code=Io_error;message;current=None}) in
      match ownership with
      | Some owner ->
          (match access with
           | Keeper keeper when Lane_addon_document_owner.permits owner ~keeper
               ~source_revision:document.source_revision -> Ok ()
           | Keeper _ | Unauthenticated | Operator_configuration ->
               Error {Lane_addon_declaration.code=Invalid_request;
                 message="Lane declaration is unavailable to this caller";current=None})
      | None ->
      let* declaration = offload (fun () -> Lane_addon_config.load_source
        ~source_path:document.source_path ~source_text:document.source_text)
        |> Result.map_error (fun _ -> {Lane_addon_declaration.code=Invalid_request;
            message="Lane declaration is unavailable to this caller";current=None}) in
      let* () = Lane_addon_sources.authorize ~access declaration.binding
        |> Result.map_error (fun message -> {Lane_addon_declaration.code=Invalid_request;message;current=None}) in
      let* visibility = binding_visibility m ~access declaration.binding
        |> Result.map_error (fun message -> {Lane_addon_declaration.code=Invalid_request;message;current=None}) in
      require_read access visibility
        |> Result.map_error (fun message -> {Lane_addon_declaration.code=Invalid_request;message;current=None})

let read_declaration ?(access = Lane_addon_sources.Unauthenticated) ~config json = Eio_context.run_on_owner_domain (fun () ->
  let* source_path = Lane_addon_declaration.read_request json in
  let* directory = edit_directory config in
  let m = manager config in
  Eio.Mutex.use_ro m.configuration_mutex (fun () ->
    let denied = {Lane_addon_declaration.code=Invalid_request;
      message="Lane declaration is unavailable to this caller";current=None} in
    let* document = offload (fun () -> Lane_addon_declaration.read ~directory ~source_path)
      |> Result.map_error (fun error -> match access, error.Lane_addon_declaration.code with
        | (Keeper _ | Unauthenticated), Not_found -> denied
        | ((Lane_addon_sources.Keeper _ | Lane_addon_sources.Unauthenticated), (Lane_addon_declaration.Invalid_request | (Lane_addon_declaration.Revision_conflict | (Lane_addon_declaration.Invalid_declaration | Lane_addon_declaration.Io_error))))
        | (Lane_addon_sources.Operator_configuration, _) -> error) in
    let* () = authorize_document m ~access document
      |> Result.map_error (fun error -> match access with
        | Lane_addon_sources.Operator_configuration -> error
        | Keeper _ | Unauthenticated -> denied) in
    Ok (Lane_addon_declaration.document_to_json document)))

let declaration_writer_key = Eio.Fiber.create_key ()
let save_declaration ?(access = Lane_addon_sources.Unauthenticated) ~config json = Eio_context.run_on_owner_domain (fun () ->
  let write = Option.value ~default:Lane_addon_declaration.write
    (Eio.Fiber.get declaration_writer_key) in
  let* request = Lane_addon_declaration.write_request json in
  let* directory = edit_directory config in
  let m = manager config in
  Eio.Mutex.use_ro m.configuration_mutex (fun () ->
    let* current = match offload (fun () -> Lane_addon_declaration.read ~directory
      ~source_path:(Filename.concat directory request.file_name)) with
      | Ok current ->
          let* () = match access with
            | Keeper keeper ->
                let* ownership = offload (fun () -> Lane_addon_document_owner.read
                  ~root:(Lane_addon_store.root m.store) ~source_path:current.source_path)
                  |> Result.map_error (fun message -> {Lane_addon_declaration.code=Io_error;message;current=None}) in
                (match ownership with
                 | Some owner when Lane_addon_document_owner.repair_permits owner ~keeper -> Ok ()
                 | Some _ | None -> authorize_document m ~access current)
            | Operator_configuration | Unauthenticated -> authorize_document m ~access current in
          Ok (Some current)
      | Error {Lane_addon_declaration.code=Not_found;_} -> Ok None
      | Error ({Lane_addon_declaration.code=Invalid_request | Revision_conflict | Invalid_declaration | Io_error;_} as error) -> Error error in
    let* candidate_owner = match access with
      | Lane_addon_sources.Operator_configuration -> Ok None
      | Keeper _ | Unauthenticated ->
          let* declaration = offload (fun () -> Lane_addon_config.load_source
            ~source_path:(Filename.concat directory request.file_name) ~source_text:request.source_text)
            |> Result.map_error (fun message -> {Lane_addon_declaration.code=Invalid_declaration;message;current=None}) in
          let* () = Lane_addon_sources.authorize ~access declaration.binding
            |> Result.map_error (fun message -> {Lane_addon_declaration.code=Invalid_request;message;current=None}) in
          let* visibility = binding_visibility m ~access declaration.binding
            |> Result.map_error (fun message -> {Lane_addon_declaration.code=Invalid_request;message;current=None}) in
          (match access, visibility with
           | Keeper keeper, Keeper_only owner when String.equal keeper owner -> Ok (Some keeper)
           | (Keeper _ | Unauthenticated), Shared -> Ok None
           | (Lane_addon_sources.Keeper _, Operator_only)
           | (Lane_addon_sources.Unauthenticated, (Operator_only | Keeper_only _))
           | (Lane_addon_sources.Operator_configuration, _) | (Keeper _, Keeper_only _) -> Error {Lane_addon_declaration.code=Invalid_request;
               message="verified declaration owner required";current=None}) in
    let source_path = Filename.concat directory request.file_name in
    let ownership_error message = {Lane_addon_declaration.code=Io_error;message;current=None} in
    let* () = match candidate_owner with
      | None -> Ok ()
      | Some keeper ->
          offload (fun () ->
            Lane_addon_document_owner.prepare ~root:(Lane_addon_store.root m.store)
              ~source_path ~keeper
              ~prior_revision:(Option.map (fun (d : Lane_addon_declaration.document) -> d.source_revision) current)
              ~proposed_revision:(Lane_addon_store.digest request.source_text))
          |> Result.map_error ownership_error in
    let* receipt = offload (fun () -> write ~directory request)
      |> Result.map_error (fun error -> match access with
          | Lane_addon_sources.Operator_configuration -> error
          | Keeper _ | Unauthenticated -> {error with Lane_addon_declaration.current=None}) in
    let* () = match candidate_owner, receipt.durability with
      | Some keeper, Lane_addon_declaration.Durable ->
          offload (fun () ->
            let* observed = Lane_addon_declaration.read ~directory ~source_path in
            if observed.source_revision <> receipt.document.source_revision
            then Error (ownership_error "declaration changed before ownership admission completed")
            else Lane_addon_document_owner.complete ~root:(Lane_addon_store.root m.store)
              ~source_path ~keeper ~source_revision:observed.source_revision
              |> Result.map_error ownership_error)
      | None, (Durable | Unconfirmed _) ->
          offload (fun () ->
            let* observed = Lane_addon_declaration.read ~directory ~source_path in
            if observed.source_revision <> receipt.document.source_revision
            then Error (ownership_error "declaration changed before shared ownership withdrawal")
            else Lane_addon_document_owner.revoke ~root:(Lane_addon_store.root m.store) ~source_path
              |> Result.map_error ownership_error)
      | Some _, Unconfirmed _ -> Ok () in
    let* () = authorize_document m ~access receipt.document in
    m.configuration_nudge ();
    Ok (Lane_addon_declaration.receipt_to_json receipt)))

(* Explicit removal edits the desired configuration. Otherwise the next
   reconciliation would legitimately create the just-detached observer again. *)
(* Reads the directory and says which file removes this installation's
   declaration, if any. Detach asks this before it stops anything, so a
   declaration that changed or became invalid since it was applied is refused
   while the worker still runs. *)
let removable_declaration ~directory (owner : configuration_owner) =
  let snapshot = Lane_addon_config.load ~directory in
  if not snapshot.complete then Error "Lane configuration directory could not be read; removal was not applied"
  else
    let matches = List.filter (fun (d : Lane_addon_config.declaration) -> d.id = owner.id) snapshot.declarations in
    let conflicts = List.filter (fun (i : Lane_addon_config.issue) -> i.id = Some owner.id) snapshot.issues in
    match matches, conflicts with
    | [d], [] when d.revision = owner.revision -> Ok (Some d.source_path)
    | [_], [] -> Error "Lane configuration changed; refresh before removing its current installation"
    | [], [] when List.mem owner.source_path snapshot.paths ->
        Error "Lane declaration is invalid; correct or remove the declaration before detaching"
    | [], [] -> Ok None
    | _ -> Error "Lane configuration identity is ambiguous; remove its duplicate declarations"

let check_configuration_removable ~directory owner =
  Result.map (fun (_ : string option) -> ()) (removable_declaration ~directory owner)

let remove_configuration_file ~directory (owner : configuration_owner) =
    let* path = removable_declaration ~directory owner in
    match path with
    | None -> Ok ()
    | Some path ->
        (* Take ownership of the directory entry before validating the bytes
           to remove. An editor can replace it while the inventory is read.
           The staged name is outside the *.toml inventory and stays in the
           same directory so relative manifest/source paths retain meaning. *)
        let staged = Filename.concat (Filename.dirname path)
          (".lane-removal-" ^ Random_id.uuid_v7 ()) in
        let restore message =
          try
            (* A hard link restores only an absent destination. A newer save
               at [path] is never overwritten; retain both files on conflict. *)
            Unix.link staged path; Unix.unlink staged; Error message
          with Unix.Unix_error (error, call, _) ->
            Error (message ^ "; declaration retained at " ^ staged ^ "; "
              ^ call ^ ": " ^ Unix.error_message error) in
        (try
           Unix.rename path staged;
           match Lane_addon_config.load_file ~path:staged with
           | Ok current when current.id = owner.id && current.revision = owner.revision ->
               Unix.unlink staged; Ok ()
           | Ok _ -> restore "Lane configuration changed during removal; detach was not applied"
           | Error message -> restore ("Lane declaration could not be verified during removal: " ^ message)
         with
         | Unix.Unix_error (Unix.ENOENT, _, _) when not (Sys.file_exists staged) -> Ok ()
         | Unix.Unix_error (error, call, _) -> Error (call ^ ": " ^ Unix.error_message error))

let retained_action_unlocked m ~instance_id ~request_id =
  (* Never durably reconfirm a visible terminal file while the live worker
     retains a failed-publication outcome. Persist that knowledge first. *)
  let* () = match Hashtbl.find_opt m.entries instance_id with
    | Some e -> (match e.current_action with
        | Some current when current.request_id = request_id
            && current.state = Lane_addon_action.Outcome_unknown ->
            let* () = save_action_unlocked m current in
            if not e.running then e.current_action <- None;
            Ok ()
        | _ -> Ok ())
    | None -> Ok () in
  let* json = offload (fun () -> Lane_addon_store.load_action m.store ~instance_id ~request_id) in
  match json with
  | None -> Ok None
  | Some json ->
      let* receipt = Lane_addon_action.of_json json in
      let* () = if receipt.instance_id = instance_id && receipt.request_id = request_id then Ok ()
        else Error "retained receipt belongs to a different request" in
      let active = match Hashtbl.find_opt m.entries instance_id with
        | Some e when e.running ->
            let owns (queued : Lane_addon_action.receipt) = queued.request_id = request_id in
            Option.fold ~none:false ~some:owns e.current_action
              || Queue.fold (fun owned queued -> owned || owns queued) false e.action_queue
        | _ -> false in
      let recovered = match active, receipt.state with
        | false, Lane_addon_action.Running -> Some {receipt with state = Outcome_unknown;
            detail = Some "original worker no longer runs; dispatched outcome is unknown and will not be replayed"}
        | false, Lane_addon_action.Queued -> Some {receipt with state = Failed_before_effect;
            detail = Some "original worker no longer runs; queued request was not dispatched"}
        | (false, (Lane_addon_action.Confirmed | (Lane_addon_action.Failed_before_effect | Lane_addon_action.Outcome_unknown)))
        | (true, _) -> None in
      (match recovered with None -> Ok (Some receipt)
       | Some receipt -> let* () = save_action_unlocked m receipt in Ok (Some receipt))
let action_status m args =
  let* instance_id = request_result (text args "instance_id") in let* request_id = request_result (text args "request_id") in
  Eio.Mutex.use_ro m.action_mutex (fun () ->
    let* receipt = runtime_result (retained_action_unlocked m ~instance_id ~request_id) in
    match receipt with None -> Error (Request_rejected "unknown action request")
    | Some receipt -> Ok (Lane_addon_action.to_json receipt))
let enqueue_action ?caller m args =
  let* instance_id = request_result (text args "instance_id") in
  let* incarnation = request_result (text args "expected_incarnation") in let* request_id = request_result (text args "request_id") in
  let* requester = match caller with Some value when String.trim value <> "" -> Ok value
    | _ -> Error (Request_rejected "Lane action requires an authenticated caller") in
  let* () = if incarnation = instance_id then Ok () else Error (Request_rejected "stale action incarnation") in
  let* action = match List.assoc_opt "action" args with Some (`Assoc _ as action) -> Ok action
    | _ -> Error (Request_rejected "action requires an object") in
  let* action = request_result (Lane_addon_action.canonical action) in
  let* arguments = request_result (Lane_addon_action.canonical (Lane_addon_action.arguments ~instance_id ~request_id ~action)) in
  let input_sha256 = Lane_addon_action.input_digest arguments in
  Eio.Mutex.use_ro m.action_mutex (fun () ->
    let* previous = runtime_result (retained_action_unlocked m ~instance_id ~request_id) in
    match previous with
    | Some receipt ->
        if receipt.requester <> requester then Error (Request_rejected "request identity belongs to a different authenticated caller")
        else if receipt.input_sha256 <> input_sha256 then Error (Request_rejected "request_id already names different action input")
        else Ok (Lane_addon_action.to_json receipt)
    | None ->
        let* e = request_result (find m args) in
        let* () = if not e.running || e.stopping then Error (Request_rejected "action worker is stopped or detaching") else Ok () in
        let* c = match e.connection with Some c -> Ok c.worker | None -> Error (Request_rejected "action worker initialization pending") in
        let* name, schema = match e.package.action_tool, c.action_schema () with
          | Some name, Some schema -> Ok (name, schema)
          | _ -> Error (Request_rejected "worker has no available advertised action port") in
        (* The input is bounded where it enters (the HTTP body limit), by the
           package's declared action schema, and by the worker's memory limit.
           The package's reply bound measures what a worker sends back. *)
        let* () = runtime_result (Lane_addon_action.validate_schema schema) in
        let* _ = request_result (Lane_addon_action.validate_input ~schema ~name arguments) in
        let receipt : Lane_addon_action.receipt = {instance_id; incarnation; request_id; requester;
          executor = None; input_sha256; action; state = Queued; result = None; detail = None} in
        let* () = runtime_result (save_action_unlocked m receipt) in
        (* Persistence yields. Detach and host shutdown may have completed while
           the file was written; do not queue against a retired owner. *)
        if not e.running || e.stopping then (
          let receipt = {receipt with state = Failed_before_effect;
            detail = Some "worker retired before the queued request entered its dispatch loop"} in
          let* () = runtime_result (save_action_unlocked m receipt) in Ok (Lane_addon_action.to_json receipt))
        else (
          Queue.add receipt e.action_queue;
          wake ~request:Run_actions e;
          Ok (Lane_addon_action.to_json receipt)))

type scheduled_act_refusal =
  | Declarations_unread
  | Declarations_incomplete
  | Declaration_missing
  | Declaration_disabled
  | No_live_instance
  | Request_id_reused
  | Action_refused of string
type scheduled_act_error =
  | Scheduled_act_refused of scheduled_act_refusal
  | Scheduled_act_failed of string
let scheduled_act_refusal_label = function
  | Declarations_unread -> "declarations_unread"
  | Declarations_incomplete -> "declarations_incomplete"
  | Declaration_missing -> "declaration_missing"
  | Declaration_disabled -> "declaration_disabled"
  | No_live_instance -> "no_live_instance"
  | Request_id_reused -> "request_id_reused"
  | Action_refused _ -> "action_refused"
(* RFC operator-quiz §4.7. A redelivered occurrence names the same request id,
   and its receipt may sit under an instance that has since gone away. Every
   instance the declaration owned is read before a new receipt is queued: the
   read writes the receipt's terminal when no live worker owns it, so the
   action is never queued twice. *)
let scheduled_act ~config ~access ~requester ~declaration_id ~request_id ~action =
  Eio_context.run_on_owner_domain (fun () ->
    let m = manager config in
    let refused reason = Error (Scheduled_act_refused reason) in
    match m.configuration_status with
    | None -> refused Declarations_unread
    | Some reading ->
      match List.find_opt (fun (d : Lane_addon_config.declaration) -> String.equal d.id declaration_id)
              reading.snapshot.declarations with
      | None when not reading.snapshot.complete -> refused Declarations_incomplete
      | None -> refused Declaration_missing
      | Some d when not d.enabled -> refused Declaration_disabled
      | Some d ->
        let inventory = inventory_at_root ~root:(Lane_addon_store.root m.store) in
        let unreadable = List.exists (fun (issue : inventory_issue) ->
          owner_concerns ~id:declaration_id ~source_path:d.source_path issue.issue_owner
          && not issue.issue_terminal) inventory.issues in
        let owned = List.filter_map (fun (instance : inventory_instance) ->
          match instance.configuration with
          | Some owner when String.equal owner.id declaration_id -> Some instance.instance_id
          | Some _ | None -> None) inventory.instances in
        match unreadable, Lane_addon_action.canonical action with
        | true, _ -> refused Declarations_incomplete
        | false, Error detail -> refused (Action_refused detail)
        | false, Ok action ->
          let previous = Eio.Mutex.use_ro m.action_mutex (fun () ->
            List.fold_left (fun found instance_id -> match found with
              | Ok (Some _) | Error _ -> found
              | Ok None -> retained_action_unlocked m ~instance_id ~request_id) (Ok None) owned) in
          match previous with
          | Error detail -> Error (Scheduled_act_failed detail)
          | Ok (Some (receipt : Lane_addon_action.receipt)) ->
            if String.equal receipt.requester requester && Yojson.Safe.equal receipt.action action
            then Ok receipt else refused Request_id_reused
          | Ok None ->
            let live = List.find_opt (fun (e : entry) ->
              e.running && not e.stopping
              && match e.configuration with
                 | Some owner -> String.equal owner.id declaration_id
                 | None -> false) (entries m) in
            match live with
            | None -> refused No_live_instance
            | Some e ->
              match require_read access e.visibility with
              | Error detail -> refused (Action_refused detail)
              | Ok () ->
                let args = [ "instance_id", `String e.instance_id; "expected_incarnation", `String e.instance_id
                           ; "request_id", `String request_id; "action", action ] in
                match enqueue_action ~caller:requester m args with
                | Error (Request_rejected detail) -> refused (Action_refused detail)
                | Error (Runtime_failed detail) -> Error (Scheduled_act_failed detail)
                | Ok json ->
                  Lane_addon_action.of_json json
                  |> Result.map_error (fun detail -> Scheduled_act_failed detail))

let rec fleet_error_to_string = function
  | Fleet_ledger.Invalid_input e | Corrupt e | Io_error e -> e
  | Conflict -> "Broadcast operation contradicts its durable intention"
  | Unknown_operation -> "Broadcast operation was not admitted"
  | Settlement_failed {primary;cleanup} -> fleet_error_to_string primary ^ "; " ^ cleanup
let fleet_result value = Result.map_error fleet_error_to_string value
let fleet_store m = Fleet_ledger.create ~root:(Filename.concat (Lane_addon_store.root m.store) "fleet-delivery")
let observe_fleet_settlement (receipt : Fleet_ledger.receipt) =
  Option.iter (fun detail -> Log.Misc.warn "Lane Fleet durable result has descriptor settlement failure: %s" detail)
    receipt.settlement_error
let admit_fleet m ~config ~caller ~access ~request_id evidence =
  let* backend = match !fleet_backend with Some value -> Ok value
    | None -> Error "Fleet delivery host boundary is unavailable" in
  let* fields=object_ evidence in let* content=text fields "message" in
  let* ()=Workspace_broadcast.validate_deferred_fleet_content content
    |> Result.map_error Workspace_broadcast.broadcast_error_to_string in
  let* artifact_sha256=match List.assoc_opt "keeper_artifact" fields with
    | Some value -> (match Tool_output.normalized_artifact_ref_of_json value with
        | Tool_output.Decoded_normalized_artifact_ref reference -> Ok reference.sha256
        | Not_normalized_artifact_ref | Invalid_normalized_artifact_ref _ -> Error "published evidence artifact is invalid")
    | None -> Error "published evidence artifact is missing" in
  let* operation_id=Fleet_ledger.Request_id.of_string request_id in
  let ledger=fleet_store m in
  let* previous=offload (fun () -> Fleet_ledger.find ledger ~caller ~operation_id) |> fleet_result in
  let* sender_authority,recipients=match previous with
    | Some receipt -> Ok (receipt.record.payload.sender_authority,receipt.record.payload.recipients)
    | None -> backend.snapshot ~config ~caller ~access in
  let payload : Fleet_ledger.payload = {sender_authority;caller;operation_id;artifact_sha256;content;recipients} in
  let* receipt=offload (fun () -> Fleet_ledger.admit ledger payload) |> fleet_result in
  observe_fleet_settlement receipt;
  Ok receipt.record
type fleet_commit_error = Fleet_pending_commit of string | Fleet_uncertain_commit of string
let fleet_commit_error_to_string = function Fleet_pending_commit e | Fleet_uncertain_commit e -> e
let commit_fleet m ~config (record : Fleet_ledger.record) =
  let payload=record.payload in
  let request_id=Fleet_ledger.Request_id.to_string record.workspace_request_id in
  let* delivery=match record.workspace with
    | Uncommitted -> Workspace_broadcast.broadcast_once ~fleet_delivery:Workspace_broadcast.Deferred_fleet ~request_id
        config ~from_agent:payload.caller ~content:payload.content
        |> Result.map_error (function
          | Workspace_broadcast.Broadcast_not_persisted e | Broadcast_policy_rejected e -> Fleet_pending_commit e
          | Broadcast_dependency_unavailable e -> Fleet_uncertain_commit e)
    | Committed seq ->
        let* found=Workspace_broadcast.find_broadcast ~request_id config
          ~from_agent:payload.caller ~content:payload.content
          |> Result.map_error (fun e -> Fleet_uncertain_commit (Workspace_broadcast.broadcast_error_to_string e)) in
        (match found with
         | Some delivery when delivery.seq=seq -> Ok delivery
         | Some _ -> Error (Fleet_uncertain_commit "Fleet workspace sequence contradicts durable receipt")
         | None -> Error (Fleet_uncertain_commit "Fleet committed workspace message is unavailable; it was not republished")) in
  let* receipt=offload (fun () -> Fleet_ledger.commit (fleet_store m)
    ~caller:payload.caller ~operation_id:payload.operation_id ~seq:delivery.seq) |> fleet_result
    |> Result.map_error (fun e -> Fleet_uncertain_commit e) in
  observe_fleet_settlement receipt;
  (* The ledger now owns recovery independently of the requesting client. *)
  Ok {delivery with Workspace_broadcast.fanout_state=Fanout_durable_admitted}
(* These tables are owned by the Eio owner domain. Claim before forking and
   retain the claim through the durable acknowledgement, not just projection.
   No shared I/O lock or recipient await belongs to the Pulse consumer. *)
let fork_fleet_job ~sw ~owners ~key ~label work =
  if not (Hashtbl.mem owners key) then begin
    Hashtbl.add owners key ();
    try
      Eio.Fiber.fork_daemon ~sw (fun () ->
        Fun.protect ~finally:(fun () -> Hashtbl.remove owners key) (fun () ->
          let result = try work () with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn -> Error (Printexc.to_string exn) in
          match result with
          | Ok () -> ()
          | Error detail -> Log.Misc.warn "Lane Fleet %s remains pending: %s" label detail);
        `Stop_daemon)
    with
    | Eio.Cancel.Cancelled _ as exn -> Hashtbl.remove owners key; raise exn
    | exn -> Hashtbl.remove owners key; raise exn
  end

let recover_fleet ~config ~sw = Eio_context.run_on_owner_domain (fun () ->
  let m=manager config in
  let* backend=match !fleet_backend with Some backend -> Ok backend
    | None -> Error "Fleet delivery host boundary is unavailable" in
  let ledger=fleet_store m in
  let* names=offload (fun () -> Fleet_ledger.pending_markers ledger) |> fleet_result in
  let current payload =
    let* found=offload (fun () -> Fleet_ledger.find ledger
      ~caller:payload.Fleet_ledger.caller ~operation_id:payload.operation_id) |> fleet_result in
    match found with
    | Some receipt -> observe_fleet_settlement receipt; Ok receipt.record
    | None -> Error "Fleet admitted operation is unavailable" in
  List.iter (fun marker ->
    fork_fleet_job ~sw ~owners:m.fleet_journals ~key:marker
      ~label:("journal " ^ marker) (fun () ->
        let outcome=offload (fun () -> Fleet_ledger.reconcile ledger marker) |> fleet_result in
        match outcome with
        | Error error ->
            Log.Misc.warn "Lane Fleet journal %s isolated: %s"
              marker error;
            Ok ()
        | Ok Fleet_ledger.Retired -> Ok ()
        | Ok (Fleet_ledger.Settled_with_cleanup receipt) ->
            observe_fleet_settlement receipt;
            Ok ()
        | Ok (Fleet_ledger.Pending receipt) ->
            observe_fleet_settlement receipt;
            let payload=receipt.record.payload in
            let operation=payload.caller,Fleet_ledger.Request_id.to_string payload.operation_id in
            fork_fleet_job ~sw ~owners:m.fleet_operations ~key:operation
              ~label:("operation " ^ snd operation) (fun () ->
                let* record=current payload in
                let* delivery=commit_fleet m ~config record |> Result.map_error fleet_commit_error_to_string in
                List.iter (fun (recipient,state) -> match state with
                  | Fleet_ledger.Accepted -> ()
                  | Pending _ ->
                    fork_fleet_job ~sw ~owners:m.fleet_recipients ~key:(operation,recipient)
                      ~label:("recipient " ^ recipient ^ " operation " ^ snd operation) (fun () ->
                        (* A scan may predate another job's durable acceptance. Read
                           again after claiming this recipient before projecting it. *)
                        let* latest=current payload in
                        match List.assoc_opt recipient latest.recipients with
                        | Some Fleet_ledger.Accepted -> Ok ()
                        | None -> Error "Fleet recipient is outside the admitted audience"
                        | Some (Pending _) ->
                          let result=try backend.project ~config ~sender_authority:payload.sender_authority
                            ~delivery ~recipient with
                            | Eio.Cancel.Cancelled _ as exn -> raise exn
                            | exn -> Error (Printexc.to_string exn) in
                          let next=match result with Ok () -> Fleet_ledger.Accepted
                            | Error detail -> Fleet_ledger.Pending (Some detail) in
                          let* receipt=offload (fun () -> Fleet_ledger.recipient_result ledger
                            ~caller:payload.caller ~operation_id:payload.operation_id ~recipient next)
                            |> fleet_result in
                          observe_fleet_settlement receipt;
                          result)) record.recipients;
                Ok ());
            Ok ())) names;
  Ok ())

let prepare_broadcast m ~base_path ~caller ~access ~instance_id ~request_id ~row_ids ~freeze =
  let* () = match access with
    | Lane_addon_sources.Operator_configuration -> Ok ()
    | Keeper keeper when String.equal keeper caller -> Ok ()
    | Keeper _ | Unauthenticated -> Error "Broadcast request is unavailable to this caller" in
  let identity = `Assoc ["caller",`String caller;"instance_id",`String instance_id;
    "row_ids",`List (List.sort String.compare row_ids |> List.map (fun id -> `String id))] in
  let input_digest = Lane_addon_store.digest (Yojson.Safe.to_string identity) in
  let request_digest = Lane_addon_store.digest (Yojson.Safe.to_string
    (`List [`String caller;`String request_id])) in
  (* Workspace request IDs carry 16 bytes, encoded as 32 lowercase hex digits. *)
  let broadcast_id = "wmsg-" ^ String.sub request_digest 0 32 in
  Eio.Mutex.use_ro m.broadcast_mutex (fun () ->
    let* previous = offload (fun () -> Lane_addon_store.load_broadcast m.store ~instance_id ~request_id:broadcast_id) in
    match previous with
    | Some previous ->
        let* fields = object_ previous in
        let* visibility = visibility_of_fields fields in
        let* () = require_read access visibility in
        let* digest = text fields "input_digest" in
        let* saved_request = text fields "request_id" in
        if not (String.equal digest input_digest && String.equal saved_request request_id
          && List.assoc_opt "identity" fields = Some identity)
        then Error "Broadcast identity belongs to different evidence"
        else (match List.assoc_opt "evidence" fields with
          | Some (`Assoc _ as evidence) -> Ok (broadcast_id, evidence)
          | _ -> Error "retained Broadcast record has no exact published evidence")
    | None ->
        let* frozen, visibility = freeze () in
        let* evidence = offload (fun () -> Lane_addon_store.publish_for_keeper
          ~base_path m.store frozen) in
        let record = `Assoc ["request_id",`String request_id;"input_digest",`String input_digest;
          "identity",identity;"visibility",visibility_to_json visibility;"evidence",evidence] in
        let* () = offload (fun () -> Lane_addon_store.save_broadcast m.store
          ~instance_id ~request_id:broadcast_id record) in
        Ok (broadcast_id, evidence))

let dispatch ?caller ?(access = Lane_addon_sources.Unauthenticated) ~config ~operation json = Eio_context.run_on_owner_domain (fun () ->
  let* args = request_result (object_ json) in
  let allowed = match operation with
    | Attach -> ["manifest_path"; "run_id"; "binding"]
    | Inspect -> ["instance_id"]
    | Observe | Detach -> ["instance_id"]
    | Slice -> ["run_id"; "lane_id"; "since"; "until"]
    | Evidence -> ["instance_id"; "row_ids"; "keeper_name"; "broadcast"; "request_id"]
    | Act -> ["instance_id"; "expected_incarnation"; "request_id"; "action"]
    | Action_status -> ["instance_id"; "request_id"] in
  let names = List.map fst args in
  let* () = if List.length names <> List.length (List.sort_uniq String.compare names)
    || List.exists (fun name -> not (List.mem name allowed)) names
    then Error (Request_rejected "duplicate or unknown Lane request field") else Ok () in
  let m = manager config in
  (* A durable delivery retry must authorize its saved caller before this
     lookup: its original source binding may already be gone. *)
  let* () = match operation with
    | Inspect | Slice | Attach | Evidence -> Ok ()
    | Observe | Detach | Act | Action_status ->
        let* id = request_result (text args "instance_id") in
        let* visibility = match Hashtbl.find_opt m.entries id with
          | Some e -> Ok e.visibility
          | None -> let* fields = persisted_binding m id in runtime_result (visibility_of_fields fields) in
        request_result (require_read access visibility) in
  match operation with
  | Act -> enqueue_action ?caller m args
  | Action_status -> action_status m args
  | Inspect ->
      let* instance_id = match List.assoc_opt "instance_id" args with
        | None -> Ok None | Some _ -> Result.map Option.some (request_result (text args "instance_id")) in
      runtime_result (snapshot m ~access ?instance_id ())
  | Slice -> slice m ~access args
  | Evidence ->
      let* broadcast = match List.assoc_opt "broadcast" args with
        | None | Some (`Bool false) -> Ok false
        | Some (`Bool true) -> Ok true
        | Some _ -> Error (Request_rejected "broadcast requires a boolean") in
      let* destination = match broadcast, List.assoc_opt "keeper_name" args with
        | true, Some _ -> Error (Request_rejected "choose Broadcast or one Keeper, not both")
        | true, None -> Ok To_broadcast
        | false, None -> Ok Preserve_only
        | false, Some _ -> request_result (text args "keeper_name") |> Result.map (fun name -> To_keeper name) in
      let* broadcast_request_id = match destination, List.assoc_opt "request_id" args with
        | To_broadcast, _ ->
            let* value=request_result (text args "request_id") in
            let* _valid=request_result (Fleet_ledger.Request_id.of_string value) in Ok (Some value)
        | (Preserve_only | To_keeper _), None -> Ok None
        | (Preserve_only | To_keeper _), Some _ -> Error (Request_rejected "request_id is only used with Broadcast") in
      let* id = request_result (text args "instance_id") in
      let* ids = match List.assoc_opt "row_ids" args with
        | Some (`List values) ->
            List.fold_left (fun acc -> function `String id -> let* ids = acc in Ok (id :: ids)
              | _ -> Error (Request_rejected "row_ids must contain strings")) (Ok []) values
        | _ -> Error (Request_rejected "row_ids requires an array") in
      let freeze_with_visibility () =
        let* binding = match Hashtbl.find_opt m.entries id with
          | Some e -> Ok (entry_json e)
          | None -> Result.map (fun fields -> `Assoc fields) (persisted_binding m id) in
        let* fields = runtime_result (object_ binding) in
        let* visibility = runtime_result (visibility_of_fields fields) in
        let* () = request_result (require_read access visibility) in
        let* frozen = runtime_result (offload (fun () -> Lane_addon_store.freeze m.store
          ~instance_id:id ~binding ~row_ids:ids)) in
        Ok (frozen, visibility) in
      let freeze () = Result.map fst (freeze_with_visibility ()) in
      (match destination with
       | Preserve_only -> freeze ()
       | To_keeper _ | To_broadcast ->
           let destination_name = match destination with
             | To_keeper _ -> "keeper" | To_broadcast -> "broadcast" | Preserve_only -> "preserve" in
           let deliver () =
             let* caller = match caller with
               | Some value when String.trim value <> "" -> Ok value
               | _ -> Error "evidence delivery requires an authenticated caller" in
             let* broadcast_request, evidence = match destination with
               | To_broadcast ->
                   let* request_id = Option.to_result ~none:"Broadcast request identity is missing" broadcast_request_id in
                   prepare_broadcast m ~base_path:config.base_path ~caller ~access
                     ~instance_id:id ~request_id ~row_ids:ids
                     ~freeze:(fun () -> freeze_with_visibility () |> Result.map_error error_to_string)
                   |> Result.map (fun (id,evidence) -> Some id,evidence)
               | To_keeper _ | Preserve_only ->
                   let* frozen = freeze () |> Result.map_error error_to_string in
                   offload (fun () -> Lane_addon_store.publish_for_keeper
                     ~base_path:config.base_path m.store frozen)
                   |> Result.map (fun evidence -> None,evidence) in
             let* fields = object_ evidence in let* prompt = text fields "message" in
             let receipt = try (match destination with
               | To_keeper keeper_name ->
                   let* handler = match !delivery_handler with
                     | Some handler -> Ok handler | None -> Error "Keeper evidence delivery is unavailable" in
                   handler ~config ~caller ~keeper_name ~prompt
               | To_broadcast ->
                   let* request_id = match broadcast_request with
                     | Some id -> Ok id | None -> Error "Broadcast request identity is missing" in
                   let* operation=match broadcast_request_id with
                     | Some value -> Ok value | None -> Error "Broadcast operation identity is missing" in
                   let* record=admit_fleet m ~config ~caller ~access ~request_id:operation evidence in
                   let* () = if Fleet_ledger.Request_id.to_string record.workspace_request_id<>request_id then
                     Error "Fleet durable identity contradicts prepared evidence" else Ok () in
                   m.fleet_nudge ();
                   let delivery=match commit_fleet m ~config record with
                     | Ok delivery -> delivery
                     | Error (Fleet_pending_commit e) -> raise (Fleet_commit_pending e)
                     | Error (Fleet_uncertain_commit e) -> raise (Fleet_commit_uncertain e) in
                   Ok (Workspace_broadcast.broadcast_delivery_to_yojson delivery)
               | Preserve_only -> Error "evidence preservation has no delivery destination")
                 |> (function Ok receipt -> Delivery_receipt receipt | Error detail -> Delivery_failed detail) with
               | Eio.Cancel.Cancelled _ as exn -> raise exn
               | Fleet_commit_pending detail -> Delivery_pending_commit detail
               | Fleet_commit_uncertain detail -> Delivery_outcome_unknown detail
               | exn -> Delivery_outcome_unknown (Printexc.to_string exn) in
             Ok (evidence, receipt)
           in
           let* published, receipt = match deliver () with
             | Ok result -> Ok result
             | Error message ->
                 let* frozen = freeze () in Ok (frozen, Delivery_failed message) in
           let recipient_fields = match destination with
             | To_keeper name -> ["keeper_name", `String name]
             | To_broadcast | Preserve_only -> [] in
           let delivery_fields = match receipt with
             | Delivery_receipt receipt -> ["status", `String (match destination with To_broadcast -> "committed"
                   | To_keeper _ | Preserve_only -> "accepted"); "receipt", receipt]
             | Delivery_failed message -> ["status", `String "failed"; "error", `String message]
             | Delivery_pending_commit message -> ["status",`String "pending_commit";"detail",`String message]
             | Delivery_outcome_unknown message -> ["status",`String "outcome_unknown";"error",`String message] in
           let delivery = `Assoc (("destination",`String destination_name) :: recipient_fields @ delivery_fields) in
           let delivery = match broadcast_request_id, delivery with
             | Some request_id, `Assoc fields -> `Assoc (("request_id",`String request_id) :: fields)
             | _ -> delivery in
           let* fields = runtime_result (object_ published) in Ok (`Assoc (("delivery", delivery) :: fields)))
  | Attach ->
      let* path = request_result (text args "manifest_path") in let* run_id = request_result (text args "run_id") in
      let* binding = match List.assoc_opt "binding" args with Some (`Assoc _ as value) -> Ok value
        | _ -> Error (Request_rejected "binding requires an object") in
      let* package = offload (fun () -> Lane_addon_manifest.load ~path)
        |> Result.map_error (function
          | Lane_addon_manifest.Invalid_manifest detail -> Request_rejected detail
          | Io_failure detail -> Runtime_failed detail) in
      let* () = request_result (Lane_addon_sources.validate binding) in
      let* () = request_result (match package.binding_schema with
        | None -> Ok ()
        | Some schema -> Lane_addon_action.validate_value ~schema ~name:"lane binding" binding |> Result.map (fun _ -> ())) in
      let* sw = match Eio_context.get_root_switch_opt () with
        | Some sw -> Ok sw | None -> Error (Runtime_failed "server background owner unavailable") in
      Eio.Mutex.use_ro m.configuration_mutex (fun () ->
      let source_access = match caller, access with
        | None, Lane_addon_sources.Operator_configuration -> Lane_addon_sources.Unauthenticated
        | None, ((Keeper _ | Unauthenticated) as access)
        | Some _, ((Operator_configuration | Keeper _ | Unauthenticated) as access) -> access in
      let* () = request_result (Lane_addon_sources.authorize ~access:source_access binding) in
      let* visibility = request_result (binding_visibility m ~access:source_access binding) in
      (* A private attachment keeps its source owner for every later wake.
         Operator authority may discover the binding, but must not remain the
         worker's acquisition authority after its Fusion owner changes. *)
      let source_access = match visibility with
        | Keeper_only keeper -> Lane_addon_sources.Keeper keeper
        | Shared | Operator_only -> source_access in
      let* () = request_result (Lane_addon_sources.authorize ~access:source_access binding) in
      runtime_result (attach_entry ~sw m ~run_id ~package ~binding ~configuration:None ~source_access ~visibility))
  | Observe ->
      let* e = request_result (find m args) in
      if e.stopping then Error (Request_rejected "instance is stopping or detached")
      else if not e.running then Error (Request_rejected "worker stopped; detach and attach again to restart")
      else (wake e; Ok (entry_json e))
  | Detach ->
      let* id = request_result (text args "instance_id") in
      let* sw = match Eio_context.get_root_switch_opt () with
        | Some sw -> Ok sw | None -> Error (Runtime_failed "server background owner unavailable") in
      (* Each owned transition is recoverable from its binding record.
         Cancellation releases the serializer so a later pass can reconcile. *)
      Eio.Mutex.use_ro m.configuration_mutex (fun () ->
        let directory = configuration_directory config in
        (* The declaration is what keeps the worker wanted. It is checked before
           anything stops, so a change made since it was applied is refused with
           the worker still running, and it is removed only after the cleanup is
           confirmed. A cleanup that fails leaves the declaration in place and
           returns the failure. *)
        let check owner = runtime_result (offload (fun () -> check_configuration_removable ~directory owner)) in
        let remove owner = runtime_result (offload (fun () -> remove_configuration_file ~directory owner)) in
        match Hashtbl.find_opt m.entries id with
        | None ->
            let* fields = persisted_binding m id in
            let* state = runtime_result (lifecycle_of_fields fields) in
            let* owner = runtime_result (configuration_of_fields fields) in
            let removing = match state, owner with
              | (Lifecycle.Detached _, _) | (Lifecycle.Attached, None) | (Lifecycle.Observing, None)
              | (Lifecycle.Failed _, None) | (Lifecycle.Detaching _, None) -> None
              | (Lifecycle.Attached, Some owner) | (Lifecycle.Observing, Some owner)
              | (Lifecycle.Failed _, Some owner) | (Lifecycle.Detaching _, Some owner) ->
                  let another_owner = List.exists (fun e -> match e.configuration with
                    | Some current -> current.id = owner.id | None -> false) (entries m) in
                  if another_owner then None else Some owner in
            let* () = match removing with None -> Ok () | Some owner -> check owner in
            let* detaching, outcome = runtime_result (historical_detach ~sw ~wait:true m fields) in
            let remove_declaration () = match removing with None -> Ok () | Some owner -> remove owner in
            (match outcome with
             | Already_detached | Finished (Lifecycle.Detached _) ->
                 let* () = remove_declaration () in Ok detaching
             | Finished (Lifecycle.Failed failed) ->
                 Error (Runtime_failed (Lifecycle.failed_to_string failed))
             | Finished (Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching _) | Started ->
                 Error (Runtime_failed "cleanup did not finish; the declaration was kept")
             | In_progress ->
                 Error (Request_rejected "cleanup of this instance is already in progress; repeat Detach once it ends"))
        | Some e ->
            let* () = match e.configuration with None -> Ok () | Some owner -> check owner in
            let* _ = runtime_result (detach_entry ~sw m e) in
            let* () = runtime_result (await_settled e) in
            let* () = match e.configuration with None -> Ok () | Some owner -> remove owner in
            Ok (entry_json e)))

let retain_configured_document_owner m (d : Lane_addon_config.declaration) visibility =
  match visibility with
  | Shared | Operator_only -> offload (fun () ->
      Lane_addon_document_owner.revoke ~root:(Lane_addon_store.root m.store) ~source_path:d.source_path)
  | Keeper_only keeper -> offload (fun () ->
      let root = Lane_addon_store.root m.store in
      let read () = Lane_addon_declaration.read ~directory:(Filename.dirname d.source_path)
        ~source_path:d.source_path |> Result.map_error (fun error -> error.Lane_addon_declaration.message) in
      let* document = read () in
      if document.desired_revision <> Some d.revision
      then Error "declaration changed before ownership admission"
      else
        let* () = Lane_addon_document_owner.reassign ~root ~source_path:d.source_path ~keeper
          ~source_revision:document.source_revision in
        let* current = read () in
        if current.source_revision <> document.source_revision
        then Error "declaration changed before ownership admission completed"
        else Lane_addon_document_owner.complete ~root ~source_path:d.source_path ~keeper
          ~source_revision:current.source_revision)

let reconcile_configuration ~config ~directory = Eio_context.run_on_owner_domain (fun () ->
  let m = manager config in
  Eio.Mutex.use_ro m.configuration_mutex (fun () ->
    let snapshot = offload (fun () -> Lane_addon_config.load ~directory) in
    let rec desired_visibility visiting (d : Lane_addon_config.declaration) =
      if List.mem d.id visiting then Error "Lane output connection cycle"
      else binding_visibility m ~access:Lane_addon_sources.Operator_configuration
        ~resolve_visibility:(fun id ->
          match List.filter (fun (candidate : Lane_addon_config.declaration) -> String.equal candidate.id id)
            snapshot.declarations with
          | [producer] -> desired_visibility (d.id :: visiting) producer
          | [] -> Error "upstream installation is unavailable"
          | _ -> Error "upstream installation identity is ambiguous") d.binding in
    m.configuration_visibility <- List.filter_map (fun (d : Lane_addon_config.declaration) ->
      match desired_visibility [] d with Ok visibility -> Some (d.id, visibility) | Error _ -> None) snapshot.declarations;
    let issues = ref snapshot.issues in
    let add_issue ?id source_path message =
      issues := { Lane_addon_config.source_path; id; message } :: !issues in
    let owned e id = match e.configuration with
      | Some owner -> String.equal owner.id id | None -> false in
    let live_for id = List.filter (fun e -> owned e id) (entries m) in
    let root_switch = match Eio_context.get_root_switch_opt () with
      | Some sw -> Ok sw | None -> Error "server background owner unavailable" in
    (* A store whose directory cannot be listed stops reconciliation. A record
       that cannot be read is a fault that holds back the declarations it may
       belong to; every other declaration proceeds. *)
    let past = historical m in
    let histories, faults = match past with
      | Error message -> add_issue directory message; [], []
      | Ok reading ->
          List.filter_map (fun (binding : retained_binding) ->
            Option.map (fun owner -> (owner, binding.binding_fields)) binding.binding_owner) reading.readable,
          reading.faults in
    let own_faults (d : Lane_addon_config.declaration) =
      blocking_faults ~id:d.id ~source_path:d.source_path faults in
    let can_apply = Result.is_ok past && snapshot.complete in
    if not can_apply then
      List.iter (fun (d : Lane_addon_config.declaration) ->
        if not d.enabled then add_issue ~id:d.id d.source_path
          "Off requested; worker cleanup waits for a complete declaration and retained-binding reading") snapshot.declarations;
    (* A failure whose variant says the attempt would only repeat the refusal
       is left alone until its condition holds. That is one cheap read, not a
       cleanup, a persisted write or an event per beat. *)
    let engine_control = backend ~store:m.store () in
    let waiting ~runtime = function
      | Lifecycle.Failed failed ->
          (match Lifecycle.heal failed.cause with
           | Lifecycle.Retry -> false
           | Lifecycle.Wait_until condition -> not (engine_control.condition_met ~runtime condition))
      | Lifecycle.Attached | Lifecycle.Observing | Lifecycle.Detaching _ | Lifecycle.Detached _ -> false in
    let record_waiting fields =
      let runtime = let* package = match List.assoc_opt "package" fields with
        | Some json -> object_ json | None -> Error "missing persisted package" in
        retained_runtime package in
      match lifecycle_of_fields fields, runtime with
      | Ok state, Ok (Some runtime) -> waiting ~runtime state
      | Ok _,Ok None -> false
      | Error _, _ | _, Error _ -> false in
    let retire sw e =
      let blocked = match e.package.execution with
        | Container container -> waiting ~runtime:container.runtime e.state
        | Host_process _ -> false in
      if blocked then () else
      match detach_entry ~sw m e with
      | Ok _ -> ()
      | Error message ->
          let path = Option.fold ~none:directory ~some:(fun o -> o.source_path) e.configuration in
          add_issue path message in
    let retire_past sw (owner, fields) =
      if record_waiting fields then () else
      match historical_detach ~sw m fields with
      | Ok _ -> () | Error message -> add_issue ~id:owner.id owner.source_path message in
    (* Containers a dead server left behind are found by their labels, not by
       a record. Each engine runtime that a declaration or a retained record
       uses is swept on the first beat its engine answers, and again on later
       beats while a refusal in it is one [Lifecycle.heal] says to retry (the
       removal itself failed). A refusal that waits for a condition, such as a
       foreign holder, ends the sweep for this process. An engine that does
       not answer is an issue of this beat. *)
    let runtimes_in_use =
      let declared = List.filter_map (fun (d : Lane_addon_config.declaration) ->
        Lane_addon_types.container_runtime d.package) snapshot.declarations in
      let retained = List.filter_map (fun (_, fields) ->
        Option.bind (List.assoc_opt "package" fields) (fun json ->
          (let* package = object_ json in retained_runtime package) |> Result.to_option |> Option.join)) histories in
      List.sort_uniq Stdlib.compare (declared @ retained) in
    if can_apply then
      List.iter (fun runtime ->
        if not (List.mem runtime m.swept) then
          match engine_control.sweep ~runtime ~is_live_instance:(is_live_instance m) with
          | Ok items ->
              let now = Masc_domain.now_iso () in
              let previous_retries =
                Hashtbl.find_opt m.sweep_retries runtime |> Option.value ~default:[]
              in
              let previous_warned =
                Hashtbl.find_opt m.sweep_warned runtime |> Option.value ~default:[]
              in
              let current_refused =
                List.filter_map
                  (fun (item : Lane_addon_slot.sweep_item) ->
                    match item.verdict with
                    | Lane_addon_slot.Refused failure ->
                        Some (item.container_id, item.instance, failure, item)
                    | Lane_addon_slot.Removed | Lane_addon_slot.Live -> None)
                  items
              in
              let refused_signature =
                current_refused
                |> List.map (fun (id, inst, failure, _) -> (id, inst, failure))
                |> List.sort Stdlib.compare
              in
              if refused_signature = [] then
                Hashtbl.remove m.sweep_warned runtime
              else
                Hashtbl.replace m.sweep_warned runtime refused_signature;
              let next_retries =
                List.filter_map
                  (fun (container_id, instance, failure, _) ->
                    match Lifecycle.heal failure with
                    | Lifecycle.Retry ->
                        let first_refused_at =
                          match
                            List.find_opt
                              (fun (prev : sweep_retry) ->
                                String.equal prev.container_id container_id)
                              previous_retries
                          with
                          | Some prev -> prev.first_refused_at
                          | None -> now
                        in
                        Some { container_id; instance; failure; first_refused_at }
                    | Lifecycle.Wait_until _ -> None)
                  current_refused
              in
              if next_retries = [] then (
                Hashtbl.remove m.sweep_retries runtime;
                m.swept <- runtime :: m.swept)
              else (
                Hashtbl.replace m.sweep_retries runtime next_retries;
                List.iter
                  (fun (retry : sweep_retry) ->
                    add_issue directory
                      (Printf.sprintf
                         "Orphan container sweep retrying container %s (incarnation %s, first refused at %s): %s"
                         retry.container_id
                         (Option.value ~default:"none" retry.instance)
                         retry.first_refused_at
                         (Lifecycle.failure_to_string retry.failure)))
                  next_retries);
              List.iter
                (fun (item : Lane_addon_slot.sweep_item) ->
                  match item.verdict with
                  | Lane_addon_slot.Live -> ()
                  | Lane_addon_slot.Removed ->
                      (match
                         List.find_opt
                           (fun (prev : sweep_retry) ->
                             String.equal prev.container_id item.container_id)
                           previous_retries
                       with
                       | None ->
                           Log.Misc.info "%s" (Lane_addon_slot.sweep_item_to_string item)
                       | Some prev ->
                           Log.Misc.info
                             "%s (resolved after retry since %s)"
                             (Lane_addon_slot.sweep_item_to_string item)
                             prev.first_refused_at)
                  | Lane_addon_slot.Refused failure ->
                      if
                        not
                          (List.mem
                             (item.container_id, item.instance, failure)
                             previous_warned)
                      then
                        Log.Misc.warn "%s" (Lane_addon_slot.sweep_item_to_string item))
                items;
              List.iter
                (fun (prev : sweep_retry) ->
                  let still_present =
                    List.exists
                      (fun (item : Lane_addon_slot.sweep_item) ->
                        String.equal item.container_id prev.container_id)
                      items
                  in
                  if not still_present then
                    Log.Misc.info
                      "Lane Add-on sweep retry resolved for container %s (incarnation %s, first refused at %s): container is gone"
                      prev.container_id
                      (Option.value ~default:"none" prev.instance)
                      prev.first_refused_at)
                previous_retries
          | Error failure ->
              add_issue directory ("Orphan container sweep did not run: " ^ Lifecycle.failure_to_string failure);
              (match Hashtbl.find_opt m.sweep_retries runtime with
               | None -> ()
               | Some retries ->
                   List.iter
                     (fun (retry : sweep_retry) ->
                       add_issue directory
                         (Printf.sprintf
                            "Orphan container sweep retrying container %s (incarnation %s, first refused at %s): %s"
                            retry.container_id
                            (Option.value ~default:"none" retry.instance)
                            retry.first_refused_at
                            (Lifecycle.failure_to_string retry.failure)))
                     retries))
        runtimes_in_use;
    let protected owner =
      List.exists (fun (d : Lane_addon_config.declaration) -> d.id = owner.id) snapshot.declarations
      || List.exists (fun (i : Lane_addon_config.issue) ->
        i.id = Some owner.id || i.source_path = owner.source_path) snapshot.issues in
    (match root_switch with
     | Error message -> add_issue directory message
     | Ok sw when snapshot.complete && can_apply ->
         List.iter (fun e -> match e.configuration with
           | Some owner when not (protected owner) -> retire sw e
           | Some _ | None -> ()) (entries m);
         List.iter (fun ((owner, fields) as history) ->
           if not (protected owner) && not (record_is_detached fields) then retire_past sw history) histories
     | Ok _ -> ());
    (match root_switch with
     | Error _ -> ()
     | Ok sw when can_apply ->
         List.iter (fun (d : Lane_addon_config.declaration) ->
           (* A record that may belong to this declaration and cannot be read
              may hold its running worker or its privacy owner, and neither can
              be checked. The declaration waits for the record to be repaired
              or moved away; a declaration no such record may belong to does
              not wait. A detached record that names this declaration holds no
              worker and does not make it wait. *)
           match d.enabled, own_faults d with
           | true, (_ :: _ as unreadable) ->
               add_issue ~id:d.id d.source_path
                 (Printf.sprintf "Not applied while %d retained bindings that may belong to this declaration cannot be read"
                    (List.length unreadable))
           | false, (_ :: _) ->
               (* A disabled declaration with an unreadable record that may
                  belong to it leaves its privacy owner untouched: the
                  retention decision cannot be made, so nothing is revoked,
                  while the worker cleanup still runs. *)
               List.iter (retire sw) (live_for d.id);
               List.iter (retire_past sw)
                 (List.filter (fun (owner, fields) -> owner.id = d.id && not (record_is_detached fields)) histories)
           | true, [] | false, [] ->
           let retained_visibility =
             let same (owner : configuration_owner) = owner.id = d.id
               && owner.source_path = d.source_path && owner.revision = d.revision in
             let live = live_for d.id |> List.filter_map (fun e ->
               match e.configuration with Some owner when same owner -> Some e.visibility | _ -> None) in
             let past = histories |> List.filter_map (fun (owner, fields) ->
               if same owner then Result.to_option (visibility_of_fields fields) else None) in
             (* An unreadable record that names this same declaration may
                hold its privacy owner, detached records included: they hold
                no worker, but the visibility they would name cannot be
                checked. A record whose read authority is present but cannot
                be read holds the decision; a record with no read authority
                at all holds no privacy owner and passes. *)
             let unreadable, unreadable_hold =
               List.fold_left
                 (fun (visibilities, hold) (fault : retained_fault) ->
                   match fault.fault_owner with
                   | Owned_by owner when same owner && fault.fault_reason <> Read_authority_absent -> (
                       match visibility_of_fields fault.fault_fields with
                       | Ok visibility -> (visibility :: visibilities, hold)
                       | Error _ -> (visibilities, true))
                   | Owned_by _ | Owner_unreadable | Unowned -> (visibilities, hold))
                 ([], false) faults in
             if unreadable_hold then Error "declaration retains a binding whose read visibility cannot be read"
             else
             match List.sort_uniq Stdlib.compare (live @ past @ unreadable) with
             | [visibility] -> Ok visibility
             | [] -> desired_visibility [] d
             | _ -> Error "declaration has ambiguous retained ownership" in
           let document_owner =
             let* visibility = retained_visibility in
             let* () = retain_configured_document_owner m d visibility in
             Ok visibility in
           if not d.enabled then (
             (* Disabling keeps the document and its privacy owner. Cleanup
                must not depend on an upstream connection or an available image. *)
             (match document_owner with
              | Ok _ -> () | Error message -> add_issue ~id:d.id d.source_path message);
             List.iter (retire sw) (live_for d.id);
             List.iter (retire_past sw)
               (List.filter (fun (owner, fields) -> owner.id = d.id && not (record_is_detached fields)) histories))
           else
           let admitted =
             let* visibility = document_owner in
             let* () = preserve_state_runtime
               ~configuration:(Some {id=d.id; source_path=d.source_path; revision=d.revision})
               ~package:d.package
               (List.map entry_json (entries m) @ List.map (fun (_,fields) -> `Assoc fields) histories
                @ terminal_fault_records ~id:d.id ~source_path:d.source_path faults) in
             let* _ = validate_connection m ~run_id:d.run_id ~configuration_id:d.id ~binding:d.binding in
             Ok visibility in
           match admitted with
           | Error message -> add_issue ~id:d.id d.source_path message
           | Ok visibility -> match live_for d.id with
           | [e] ->
               let owner = {id=d.id; source_path=d.source_path; revision=d.revision} in
               (match e.configuration with
                | Some applied when applied.revision = d.revision && e.running && not e.stopping ->
                    if applied.source_path <> d.source_path then (
                      e.configuration <- Some owner;
                      match persist m e with Ok () -> ()
                      | Error message -> add_issue ~id:d.id d.source_path message)
                | Some _ | None -> retire sw e)
           | [] ->
               let pending = List.filter (fun (owner, fields) -> owner.id = d.id && not (record_is_detached fields)) histories in
               if pending <> [] then List.iter (retire_past sw) pending
               else (
                 (* A missing image is reported by [attach_entry] as this
                    declaration's issue, and looked for again on the next beat,
                    so an image built later attaches without a TOML edit. *)
                 let owner = Some {id=d.id; source_path=d.source_path; revision=d.revision} in
                 let attached =
                   let source_access = match visibility with
                     | Keeper_only keeper -> Lane_addon_sources.Keeper keeper
                     | Shared | Operator_only -> Lane_addon_sources.Operator_configuration in
                   attach_entry ~sw m ~run_id:d.run_id ~package:d.package ~binding:d.binding ~configuration:owner
                     ~source_access ~visibility in
                 match attached with
                 | Ok _ -> () | Error message -> add_issue ~id:d.id d.source_path message)
           | _ -> add_issue ~id:d.id d.source_path "multiple workers claim this configuration identity") snapshot.declarations
     | Ok _ -> ());
    let exports = entries m |> List.filter_map (fun e ->
      let configured_off = snapshot.complete && match e.configuration with
        | None -> false
        | Some owner -> List.exists (fun (d : Lane_addon_config.declaration) ->
            d.id = owner.id && not d.enabled) snapshot.declarations in
      (* Cleanup failures retain their worker and evidence for retry, but a
         retiring owner cannot supply a usable Skill. An incomplete reading
         does not authorize inferring desired activity for a running owner. *)
      if e.stopping || configured_off then None else
      match e.package.skills_directory, phase_of e with
      | None, _ | Some _, Detached -> None
      | Some _, (Attached | Observing | Failed _ | Detaching) ->
          let owner = match e.configuration with
            | Some owner -> Declaration owner.id | None -> Instance e.instance_id in
          Some {owner; instance_id=e.instance_id; package=e.package})
      |> List.sort (fun a b -> String.compare (skill_source_id a.owner) (skill_source_id b.owner)) in
    (match !skill_export_handler with
     | None when exports <> [] -> add_issue directory "package Skill publisher is unavailable"
     | None -> ()
     | Some publish ->
         (match publish ~config exports with
          | Ok () -> () | Error message -> add_issue directory message));
    m.configuration_status <- Some {directory;snapshot;issues=List.rev !issues};
    Ok (configuration_json m ~access:Lane_addon_sources.Operator_configuration)))

let fleet_services : (string,unit -> unit) Hashtbl.t = Hashtbl.create 4
let start_fleet_service ~config ~sw ~clock =
  let key=Workspace.masc_dir config in
  if not (Hashtbl.mem fleet_services key) then (
    let active=ref true in
    let consumer : (module Pulse.Consumer) = (module struct
      let name="lane-addon-fleet-delivery"
      let should_act _ = !active
      let on_beat _ = recover_fleet ~config ~sw
    end) in
    let interval=Env_config_runtime_services.Timeouts.maintenance_pulse_interval_sec in
    let pulse=Pulse.create ~clock
      ~rhythm:{Pulse.base_s=interval;min_s=interval;max_s=interval;quiet=(0,0)}
      ~consumers:[consumer] in
    let stop ()=active:=false;Pulse.shutdown pulse in
    Hashtbl.add fleet_services key stop;
    let m=manager config in
    m.fleet_nudge<-(fun () -> Pulse.nudge pulse ~reason:"durable Fleet delivery admitted");
    Eio.Switch.on_release sw (fun () -> stop ();Hashtbl.remove fleet_services key;
      m.fleet_nudge<-(fun () -> ()));
    Pulse.run ~sw pulse)

let configuration_services : (string, unit -> unit) Hashtbl.t = Hashtbl.create 4
let start_configuration_service ~config ~sw ~clock =
  let key = Workspace.masc_dir config in
  if not (Hashtbl.mem configuration_services key) then (
    let directory = configuration_directory config in
    let active = ref true in
    let consumer : (module Pulse.Consumer) = (module struct
      let name = "lane-addon-configuration"
      let should_act _ = !active
      let on_beat _ =
        let resolution = Config_dir_resolver.resolve_for_base_path ~base_path:config.Workspace.base_path in
        match resolution.status with
        | Config_dir_resolver.Invalid_env_status ->
            let issue = {Lane_addon_config.source_path=directory; id=None;
              message=String.concat "; " resolution.warnings} in
            let snapshot = {Lane_addon_config.declarations=[];issues=[issue];paths=[];complete=false} in
            (manager config).configuration_status <- Some {directory;snapshot;issues=[issue]};
            Ok ()
        | Ready | Warn | Missing_status ->
            Result.map (fun _ -> ()) (reconcile_configuration ~config ~directory)
    end) in
    (* Configuration is maintenance work. Reuse the existing maintenance
       cadence on an independent Pulse, outside Keeper sweeps and turns. *)
    let interval = Env_config_runtime_services.Timeouts.maintenance_pulse_interval_sec in
    let pulse = Pulse.create ~clock
      ~rhythm:{Pulse.base_s=interval; min_s=interval; max_s=interval; quiet=(0,0)}
      ~consumers:[consumer] in
    let stop () = active := false; Pulse.shutdown pulse in
    Hashtbl.add configuration_services key stop;
    let m = manager config in
    m.configuration_nudge <- (fun () -> Pulse.nudge pulse ~reason:"configuration reconciliation requested");
    Eio.Switch.on_release sw (fun () ->
      stop (); Hashtbl.remove configuration_services key;
      m.configuration_nudge <- (fun () -> ()));
    Pulse.run ~sw pulse)

(* RFC operator-quiz §4.6. An answer is a host event (§4.4, event 3); a worker
   that is down lists the question again when it starts and receives the
   answer then. *)
let answer_installation_question ~config ~declaration_id ~ask_id ~submissions ~responder =
  Eio_context.run_on_owner_domain (fun () ->
    let m = manager config in
    let result = offload (fun () ->
      Lane_addon_asks.answer m.store ~declaration_id ~ask_id ~submissions ~responder ~now:(Time_compat.now ())) in
    (match result with
     | Ok _ ->
         List.iter (fun e -> match e.configuration with
           | Some owner when String.equal owner.id declaration_id && uses_host_requests e.package -> wake_host e
           | Some _ | None -> ()) (entries m)
     | Error _ -> ());
    result)

let installation_questions ~config =
  Eio_context.run_on_owner_domain (fun () ->
    let m = manager config in
    offload (fun () ->
      let* ids = Lane_addon_asks.declarations m.store in
      List.fold_right (fun declaration_id acc ->
        let* acc = acc in
        let* rows = Lane_addon_asks.rows m.store ~declaration_id in
        Ok ((declaration_id, rows) :: acc)) ids (Ok [])))

module For_testing = struct
  let with_cleanup_writer writer f = Eio.Fiber.with_binding cleanup_writer_key writer f
  let with_declaration_writer writer f = Eio.Fiber.with_binding declaration_writer_key writer f
  type nonrec host_port = host_port = {
    list_requests : unit -> (Yojson.Safe.t, string) result;
    deliver : arguments:Yojson.Safe.t -> (Yojson.Safe.t, string) result;
  }
  type nonrec connection = connection = {
    observe : binding:Yojson.Safe.t -> sources:Yojson.Safe.t -> (output, string) result;
    exported_tools : unit -> Mcp_protocol.Mcp_types.tool list;
    call_exported_tool : on_result:(Mcp_protocol.Mcp_types.tool_result -> unit) -> authorize:Lane_addon_call_context.mediation option -> principal:Lane_addon_call_context.principal -> name:string -> arguments:Yojson.Safe.t ->
      (Mcp_protocol.Mcp_types.tool_result, Lane_addon_call_context.invocation_error) result;
    action_schema : unit -> Yojson.Safe.t option;
    act : arguments:Yojson.Safe.t -> (Lane_addon_action.package_result, string) result;
    stop : unit -> (Lifecycle.release, Lifecycle.failure) result;
    resource : Lifecycle.resource;
    host : host_port option;
  }
  type nonrec backend = backend = {
    start : sw:Eio.Switch.t -> state_owner:Lane_addon_worker_state.owner option -> instance_id:string -> installation_id:string -> package:package -> binding:Yojson.Safe.t ->
      on_authority:(Lifecycle.authority -> (unit, string) result) ->
      is_live_instance:(string -> bool) ->
      on_created:(connection -> unit) -> (connection, Lifecycle.failure) result;
    acquire : access:Lane_addon_sources.access -> store:Lane_addon_store.t -> package:package ->
      resolve_machine_output:(Machine_lane.t -> (Lane_addon_sources.machine_output, string) result) ->
    resolve_lane_output:(installation_id:string -> (Lane_addon_sources.lane_output, string) result) ->
      binding:Yojson.Safe.t ->
      (Yojson.Safe.t, string) result;
    recover_stop : state_owner:Lane_addon_worker_state.owner option -> instance_id:string ->
      authority:Lifecycle.authority -> resource:Lifecycle.resource option -> (Lifecycle.release, Lifecycle.failure) result;
    package_ready : package:package -> (unit, string) result;
    condition_met : runtime:runtime -> Lifecycle.condition -> bool;
    sweep : runtime:runtime -> is_live_instance:(string -> bool) ->
      (Lane_addon_slot.sweep_item list, Lifecycle.failure) result;
  }
  let with_backend backend f = let previous = !override in override := Some backend;
    Fun.protect ~finally:(fun () -> override := previous) f
  let with_action_writer write f = Eio.Fiber.with_binding action_writer_key write f
  let with_observation_writer write f = Eio.Fiber.with_binding observation_writer_key write f
  let reset () =
    Hashtbl.iter (fun _ stop -> stop ()) configuration_services;
    Hashtbl.clear configuration_services; Hashtbl.clear managers;
    Hashtbl.iter (fun _ stop -> stop ()) fleet_services; Hashtbl.clear fleet_services;
    fleet_backend := None; delivery_handler := None; sampling_factory := None; skill_export_handler := None
end
