open Lane_addon_types
module Fleet_ledger = Lane_addon_broadcast_delivery
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
type connection = {
  observe : binding:Yojson.Safe.t -> sources:Yojson.Safe.t -> (output, string) result;
  action_schema : unit -> Yojson.Safe.t option;
  act : arguments:Yojson.Safe.t -> (Lane_addon_action.package_result, string) result;
  stop : unit -> (unit, string) result;
  container_id : string;
}
type backend = {
  start : sw:Eio.Switch.t -> instance_id:string -> package:package -> binding:Yojson.Safe.t ->
    on_created:(connection -> unit) -> (connection, string) result;
  acquire : access:Lane_addon_sources.access -> store:Lane_addon_store.t -> package:package ->
    resolve_lane_output:(installation_id:string -> (Lane_addon_sources.lane_output, string) result) ->
    binding:Yojson.Safe.t ->
    (Yojson.Safe.t, string) result;
  recover_stop : instance_id:string -> container_id:string option -> max_reply_bytes:int ->
    (unit, string) result;
  image_ready : package:package -> (unit, string) result;
}
type configuration_owner = { id : string; source_path : string; revision : string }
type inventory_presence = Live | Retained
type inventory_instance = {
  instance_id : string; incarnation : string; run_id : string;
  package_id : string; title : string; package_revision : string;
  configuration : configuration_owner option;
  presence : inventory_presence; phase : phase;
}
type inventory = {
  owner_present : bool; instances : inventory_instance list;
  issues : (string * string) list; complete : bool;
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
type entry = {
  instance_id : string; run_id : string; package : package; binding : Yojson.Safe.t;
  mutable phase : phase; mutable seq : int; mutable output : output;
  mutable connection : connection option; mutable stopping : bool;
  mutable cleanup_running : bool; mutable wake : unit Eio.Promise.t;
  mutable resolver : unit Eio.Promise.u; mutable pending : observation_request;
  refresh_interest : Lane_addon_sources.refresh_interest;
  source_access : Lane_addon_sources.access;
  visibility : visibility;
  mutable last_committed_sources : string option;
  mutable unchanged_source_refreshes : int;
  mutable running : bool; persistence_mutex : Eio.Mutex.t;
  mutable coalesced_wakes : int;
  mutable cancel_worker : (unit -> unit) option;
  mutable configuration : configuration_owner option;
  input_installations : string list;
  action_queue : Lane_addon_action.receipt Queue.t;
  mutable current_action : Lane_addon_action.receipt option;
}
type manager = { store : Lane_addon_store.t; entries : (string, entry) Hashtbl.t;
  recovering : (string, unit) Hashtbl.t;
  configuration_mutex : Eio.Mutex.t; action_mutex : Eio.Mutex.t; broadcast_mutex : Eio.Mutex.t;
  fleet_journals : (string, unit) Hashtbl.t;
  fleet_operations : ((string * string), unit) Hashtbl.t;
  fleet_recipients : (((string * string) * string), unit) Hashtbl.t; mutable fleet_nudge : unit -> unit; mutable configuration_status : Yojson.Safe.t;
  mutable configuration_nudge : unit -> unit;
  mutable configuration_visibility : (string * visibility) list }
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
let offload f = Eio_unix.run_in_systhread f
let configuration_json (owner : configuration_owner) =
  `Assoc ["id", `String owner.id; "source_path", `String owner.source_path;
    "revision", `String owner.revision]
let configuration_of_fields fields =
  match List.assoc_opt "configuration" fields with
  | None | Some `Null -> Ok None
  | Some value ->
      let* fields = object_ value in
      let* id = text fields "id" in let* source_path = text fields "source_path" in
      let* revision = text fields "revision" in Ok (Some {id; source_path; revision})
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
let caller_access ?access _caller =
  Option.value access ~default:Lane_addon_sources.Unauthenticated
let can_read access = function
  | Shared -> true
  | Operator_only -> (match access with Lane_addon_sources.Operator_configuration -> true
      | Keeper _ | Unauthenticated -> false)
  | Keeper_only owner -> (match access with
      | Lane_addon_sources.Operator_configuration -> true
      | Keeper keeper -> String.equal owner keeper | Unauthenticated -> false)
let require_read access visibility =
  if can_read access visibility then Ok () else Error "Lane instance is unavailable to this caller"
(* v0.48.0 published this exact binding envelope before private Fusion sources.
   Recognition proves the whole retained producer graph; missing authority on
   any other shape remains an error. This reader never modifies stored bytes. *)
let exact_fields expected fields =
  if List.sort String.compare (List.map fst fields) = List.sort String.compare expected
  then Ok () else Error "invalid released binding shape"
let rec unique_json = function
  | `Assoc fields ->
      let* () = Json_util.reject_unknown_fields ~surface:"retained binding" ~allowed:(List.map fst fields) fields in
      List.fold_left (fun result (_, value) -> let* () = result in unique_json value) (Ok ()) fields
  | `List values -> List.fold_left (fun result value -> let* () = result in unique_json value) (Ok ()) values
  | _ -> Ok ()
let released_binding_fields = ["instance_id";"incarnation";"action_schema";"run_id";
  "addon_id";"title";"revision";"phase";"observation_seq";"rows_count";
  "observation_pending";"coalesced_wakes";"unchanged_source_refreshes";
  "binding";"package";"configuration";"container_id"]
type retained_package_shape = Released_package | Current_package
let validate_released_binding ~package_shape fields =
  let* () = unique_json (`Assoc fields) in
  let* () = exact_fields released_binding_fields fields in
  let* id = text fields "instance_id" in
  let* incarnation = text fields "incarnation" in
  let* () = if id = incarnation then Ok () else Error "retained incarnation mismatch" in
  let* _ = text fields "run_id" in
  let* () = List.fold_left (fun result key -> let* () = result in
    match List.assoc key fields with `Int n when n >= 0 -> Ok () | _ -> Error "invalid retained counter")
    (Ok ()) ["observation_seq";"rows_count";"coalesced_wakes";"unchanged_source_refreshes"] in
  let* () = match List.assoc "observation_pending" fields with `Bool _ -> Ok () | _ -> Error "invalid retained pending state" in
  let* _ = phase_of_json (List.assoc "phase" fields) in
  let* _ = configuration_of_fields fields in
  let* () = match List.assoc "configuration" fields with
    | `Null -> Ok () | `Assoc owner -> exact_fields ["id";"source_path";"revision"] owner
    | _ -> Error "invalid retained configuration" in
  let* () = match List.assoc "container_id" fields with `Null -> Ok () | _ -> text fields "container_id" |> Result.map (fun _ -> ()) in
  let* () = match List.assoc "action_schema" fields with `Null | `Assoc _ -> Ok () | _ -> Error "invalid retained action schema" in
  let* package = object_ (List.assoc "package" fields) in
  let package_fields = ["id";"revision";"title";"contributions";"image";"command";
    "directory";"action_tool";"outputs";"refresh_policy";"binding_schema";
    "presentation";"skills_directory";"resources"] in
  let* () = match package_shape with
    | Released_package -> exact_fields package_fields package
    | Current_package ->
        (match List.assoc_opt "model_access" package with
         | None -> exact_fields package_fields package
         | Some (`String ("disabled" | "host_sampling")) ->
             exact_fields ("model_access" :: package_fields) package
         | Some _ -> Error "invalid current model access") in
  let* () = List.fold_left (fun result key -> let* () = result in text package key |> Result.map (fun _ -> ()))
    (Ok ()) ["id";"revision";"title";"image";"directory"] in
  let* () = List.fold_left (fun result (outer,inner) -> let* () = result in
    if List.assoc outer fields = List.assoc inner package then Ok () else Error "retained package identity mismatch")
    (Ok ()) ["addon_id","id";"revision","revision";"title","title"] in
  let strings = function `List values -> List.for_all (function `String s -> String.trim s <> "" | _ -> false) values | _ -> false in
  let* () = match List.assoc "command" package with `List (_::_) as v when strings v -> Ok () | _ -> Error "invalid retained command" in
  let* () = match List.assoc "contributions" package with
    | `List (_::_ as values) when List.for_all (function `String ("observe"|"derive"|"act") -> true | _ -> false) values -> Ok ()
    | _ -> Error "invalid retained contributions" in
  let* () = List.fold_left (fun result key -> let* () = result in match List.assoc key package with
    | `Null -> Ok () | _ -> text package key |> Result.map (fun _ -> ())) (Ok ()) ["action_tool";"skills_directory"] in
  let* () = match List.assoc "refresh_policy" package with `String ("every_hint"|"source_changes") -> Ok () | _ -> Error "invalid retained refresh policy" in
  let* outputs = object_ (List.assoc "outputs" package) in
  let* () = if List.for_all (fun (name,selection) -> String.trim name <> "" && match selection with
    | `Assoc ["all_lanes",`Bool true] -> true | `Assoc ["lanes",values] -> strings values | _ -> false) outputs
    then Ok () else Error "invalid retained output ports" in
  let* _ = Lane_addon_presentation.of_json (List.assoc "presentation" package) in
  let* resources = object_ (List.assoc "resources" package) in
  let* () = exact_fields ["cpus";"memory_bytes";"pids";"max_reply_bytes"] resources in
  let* () = match List.assoc "cpus" resources with `Float f when Float.is_finite f && f > 0. -> Ok () | _ -> Error "invalid retained CPU bound" in
  let* () = match List.assoc "memory_bytes" resources with
    | `Intlit s -> (match Int64.of_string_opt s with Some n when n > 0L -> Ok () | _ -> Error "invalid retained memory bound")
    | `Int n when n > 0 -> Ok () | _ -> Error "invalid retained memory bound" in
  let* () = List.fold_left (fun result key -> let* () = result in match List.assoc key resources with
    | `Int n when n > 0 -> Ok () | _ -> Error "invalid retained resource bound") (Ok ()) ["pids";"max_reply_bytes"] in
  let binding = List.assoc "binding" fields in
  let* () = match List.assoc "binding_schema" package with
    | `Null -> Ok () | `Assoc _ as schema -> Lane_addon_action.validate_value ~schema ~name:"retained binding" binding |> Result.map (fun _ -> ())
    | _ -> Error "invalid retained binding schema" in
  let* binding_fields = object_ binding in
  let* () = match List.assoc_opt "sources" binding_fields with
    | Some (`List sources) -> List.fold_left (fun result source -> let* () = result in let* f = object_ source in
        let* allowed = match List.assoc_opt "kind" f with
          | Some (`String "snapshot_file") -> Ok ["source_id";"kind";"path"]
          | Some (`String ("msx_capture"|"dos_capture")) -> Ok ["source_id";"kind"]
          | Some (`String "lane_output") -> Ok ["source_id";"kind";"installation_id";"selection";"output_id"]
          | Some (`String "browser_document") -> Ok ["source_id";"kind";"lane";"client_id";"tab_id";"target_id";"environment";"request_id"]
          | _ -> Error "source not present in published binding schema" in
        Json_util.reject_unknown_fields ~surface:"retained source" ~allowed f) (Ok ()) sources
    | _ -> Error "invalid retained sources" in
  Lane_addon_sources.parse binding
let prove_released_shared ~bindings fields =
  let rec prove package_shape visiting fields =
    let* sources = validate_released_binding ~package_shape fields in
    let* id = text fields "instance_id" in
    let* run = text fields "run_id" in
    let* () = if List.mem id visiting then Error "retained producer cycle" else Ok () in
    let* () = if List.length (List.filter (function `Assoc f -> List.assoc_opt "instance_id" f = Some (`String id) | _ -> false) bindings) = 1
      then Ok () else Error "ambiguous retained incarnation" in
    List.fold_left (fun result source -> let* () = result in match source with
      | Lane_addon_sources.Fusion_run _ -> Error "private source requires retained authority"
      | Snapshot_file _ | Msx_capture _ | Dos_capture _ | Browser_document _ -> Ok ()
      | Lane_output {installation_id;output_id;_} ->
          let candidates = List.filter_map (function `Assoc f when List.assoc_opt "run_id" f = Some (`String run) ->
            (match configuration_of_fields f with Ok (Some owner) when owner.id = installation_id -> Some f | _ -> None)
            | _ -> None) bindings in
          (match candidates with
           | [producer] ->
               let* () = match output_id with
                 | None -> Ok ()
                 | Some output ->
                     let* package = match List.assoc_opt "package" producer with
                       | Some json -> object_ json | None -> Error "missing retained producer package" in
                     let* outputs = match List.assoc_opt "outputs" package with
                       | Some json -> object_ json | None -> Error "missing retained producer outputs" in
                     if List.mem_assoc output outputs then Ok () else Error "unknown retained producer output" in
               if List.mem_assoc "visibility" producer || List.mem_assoc "source_access" producer
               then let* visibility = visibility_of_fields producer in
                 if visibility <> Shared then Error "private retained producer"
                 else let* _ = match List.assoc_opt "source_access" producer with
                   | Some json -> Lane_addon_sources.access_of_json json | None -> Error "missing retained source access" in
                   prove Current_package (id::visiting) (List.remove_assoc "visibility" (List.remove_assoc "source_access" producer))
               else prove Released_package (id::visiting) producer
           | [] -> Error "missing retained producer" | _ -> Error "ambiguous retained producer")) (Ok ()) sources
  in prove Released_package [] fields
let normalize_retained_binding ~bindings value =
  let* fields = object_ value in
  if List.mem_assoc "visibility" fields || List.mem_assoc "source_access" fields
  then let* _ = visibility_of_fields fields in
    let* _ = match List.assoc_opt "source_access" fields with
      | Some json -> Lane_addon_sources.access_of_json json | None -> Error "missing retained source access" in Ok value
  else let* () = prove_released_shared ~bindings fields in
    Ok (`Assoc (("visibility",visibility_to_json Shared)::
      ("source_access",Lane_addon_sources.access_to_json Lane_addon_sources.Unauthenticated)::fields))
let normalized_retained_bindings bindings =
  List.fold_right (fun value result ->
    let* values = result in let* value = normalize_retained_binding ~bindings value in
    Ok (value::values)) bindings (Ok [])
let authorize_retained_read ~bindings ~access json =
  let* normalized = normalized_retained_bindings bindings in
  let* fields = object_ json in
  let* id = text fields "instance_id" in
  match List.filter (function `Assoc f -> List.assoc_opt "instance_id" f = Some (`String id) | _ -> false) normalized with
  | [`Assoc fields] -> let* visibility = visibility_of_fields fields in require_read access visibility
  | _ -> Error "retained instance identity is ambiguous or absent"
let entry_json e =
  `Assoc ["instance_id", `String e.instance_id; "incarnation", `String e.instance_id;
    "action_schema", (match e.connection with None -> `Null
      | Some c -> Option.fold ~none:`Null ~some:Fun.id (c.action_schema ()));
    "run_id", `String e.run_id;
    "addon_id", `String e.package.id; "title", `String e.package.title;
    "revision", `String e.package.revision; "phase", phase_to_json e.phase;
    "observation_seq", `Int e.seq; "rows_count", `Int (List.length e.output.rows);
    "observation_pending", `Bool (match e.pending with
      | Observe_now | Refresh_sources -> true | Run_actions | Idle -> false); "coalesced_wakes", `Int e.coalesced_wakes;
    "unchanged_source_refreshes", `Int e.unchanged_source_refreshes;
    "binding", e.binding; "source_access", Lane_addon_sources.access_to_json e.source_access;
    "package", package_to_json e.package;
    "visibility", visibility_to_json e.visibility;
    "configuration", Option.fold ~none:`Null ~some:configuration_json e.configuration;
    "container_id", (match e.connection with None -> `Null | Some c -> `String c.container_id)]
(* A detached worker that never created a container and never committed an
   observation leaves nothing for Inspect, Slice or Evidence to read. When
   its start returned [Error], the masc:lane:resource:acquire_failed event in
   the agent-core event journal records why it did not start; a start that
   raised keeps its reason only in the [Failed] phase until it is retired.
   Its binding would only add a record that every reconciliation reads
   again, and a startup that keeps failing adds one per maintenance beat, so
   its durable form is no file. [persist] and the restart recovery in
   [historical_detach] both decide with this one rule. *)
let never_started ~seq ~has_container = seq = 0 && not has_container
let retains_history e =
  not (never_started ~seq:e.seq ~has_container:(Option.is_some e.connection))
let persist m e = Eio.Mutex.use_ro e.persistence_mutex (fun () ->
  (* Capture mutable state on the owning domain after serializing writes.
     The I/O thread sees only the immutable snapshot. Every write, including
     a late one after detach, derives the file from the same state under this
     mutex, so the last write leaves the record that state calls for. *)
  if e.phase = Detached && not (retains_history e)
  then offload (fun () -> Lane_addon_store.remove_binding m.store ~instance_id:e.instance_id)
  else
    let json = entry_json e in
    offload (fun () -> Lane_addon_store.save_binding m.store ~instance_id:e.instance_id json))
let wake ?(request=Observe_now) e =
  let previous = e.pending in
  e.pending <- (match previous,request with
    | Observe_now,_ | _,Observe_now -> Observe_now
    | Refresh_sources,_ | _,Refresh_sources -> Refresh_sources
    | Run_actions,_ | _,Run_actions -> Run_actions
    | Idle,Idle -> Idle);
  if previous<>Idle then e.coalesced_wakes <- e.coalesced_wakes + 1
  else if e.pending<>Idle then Eio.Promise.resolve e.resolver ()
let clear_wake e =
  let promise, resolver = Eio.Promise.create () in
  e.wake <- promise; e.resolver <- resolver; e.pending <- Idle
let entries m = Hashtbl.to_seq_values m.entries |> List.of_seq
  |> List.sort (fun a b -> String.compare a.instance_id b.instance_id)
let status_coverage e = {
  source_id = e.instance_id; incarnation = e.instance_id;
  cursor = Some (string_of_int e.seq);
  complete = (match e.phase with Attached | Detached -> e.seq > 0 | _ -> false);
  detail = (match e.phase with
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
  match producer.configuration with
  | None -> ()
  | Some owner -> entries m |> List.iter (fun e ->
      if e.running && not e.stopping && e.run_id = producer.run_id
        && List.mem owner.id e.input_installations then wake ~request:Refresh_sources e)
let failed m e message =
  if not e.stopping then e.phase <- Failed message;
  match persist m e with Ok () -> wake_dependents m e | Error error ->
    if not e.stopping then e.phase <- Failed (message ^ "; binding persistence: " ^ error)
    else Log.Misc.error "Lane stopped binding persistence: %s" error
let fork_isolated ~sw f = Eio.Fiber.fork ~sw (fun () ->
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Log.Misc.error "Lane Add-on background boundary: %s" (Printexc.to_string exn))
let release_detached m e =
  if e.phase = Detached && not e.running && not e.cleanup_running
  then (Hashtbl.remove m.entries e.instance_id; wake_dependents m e; m.configuration_nudge ())
let publish_resource lifecycle e container_id detail =
  Lane_addon_resource_events.publish lifecycle
    { instance_id = e.instance_id; run_id = e.run_id;
      package_id = e.package.id; package_revision = e.package.revision;
      container_id; detail }
let stop_entry ~sw ~backend m e =
  if not e.cleanup_running then
    let cleanup = match e.connection with
      | Some c -> Some (Some c.container_id, c.stop)
      | None when not e.running -> Some (None, fun () ->
          backend.recover_stop ~instance_id:e.instance_id ~container_id:None
            ~max_reply_bytes:e.package.resources.max_reply_bytes)
      | None -> None (* startup still owns the unresolved create operation *) in
    match cleanup with
    | None -> ()
    | Some (container_id, stop) ->
        e.cleanup_running <- true;
        fork_isolated ~sw (fun () ->
          let result = try stop () with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn -> Error (Printexc.to_string exn) in
          (match result with
           | Ok () ->
               let already_detached = (e.phase = Detached) in
               e.phase <- Detached; wake e;
               Option.iter (fun cancel -> cancel ()) e.cancel_worker;
               (* start-hang can run stop twice; the release is announced
                  once, at the transition into Detached. *)
               if not already_detached then
                 publish_resource Lane_addon_resource_events.Release_confirmed e
                   container_id None
           | Error message ->
               e.phase <- Failed ("cleanup incomplete: " ^ message);
               publish_resource Lane_addon_resource_events.Release_incomplete e
                 container_id (Some message));
          (match persist m e with Ok () -> () | Error message ->
            e.phase <- Failed ("cleanup state persistence: " ^ message));
          wake_dependents m e;
          e.cleanup_running <- false;
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
  (* The declared observation envelope also bounds the host representation.
     Check prefix expansion before allocating it: package-controlled relation
     lists cannot manufacture extra retained capacity. *)
  let* () =
    if String.length (Yojson.Safe.to_string (output_to_json output)) <= e.package.resources.max_reply_bytes
    then Ok () else Error "observation exceeds the package output envelope" in
  let* allowance = namespace_allowance e seq output in
  let* namespaced_bytes = add_output_bytes
    (Int64.of_int (String.length (Yojson.Safe.to_string (output_to_json output)))) allowance in
  let* () =
    if namespaced_bytes <= Int64.of_int e.package.resources.max_reply_bytes
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
    if not e.stopping then e.phase <- Attached;
    let* () = persist m e in wake_dependents m e; Ok ()
  | Error (Lane_addon_store.Observation_rejected detail) -> Error detail
  | Error (Lane_addon_store.Publication_failed {failure;verification_error}) ->
    let cause=Lane_addon_store.observation_write_error_to_string
      (Lane_addon_store.Publication_failed {failure;verification_error}) in
    (match failure.Fs_compat.stage with
     | Fs_compat.Before_rename -> ()
     | Fs_compat.After_rename ->
       converge ();
       if not e.stopping then e.phase <- Failed
         ("observation published with unconfirmed durability: " ^
           cause));
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
let perform_action m e c (queued : Lane_addon_action.receipt) =
  e.current_action <- Some queued;
  let running = {queued with state = Lane_addon_action.Running; executor = Some c.container_id} in
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

let run ~sw backend m e =
  fork_isolated ~sw (fun () ->
    let work () = try
      Eio.Switch.run (fun worker_sw ->
        e.cancel_worker <- Some (fun () -> Eio.Switch.fail worker_sw Worker_detached);
        let created c = e.connection <- Some c;
          publish_resource Lane_addon_resource_events.Acquired e (Some c.container_id) None;
          (match persist m e with Ok () -> () | Error message ->
            e.stopping <- true; e.phase <- Failed message);
          if e.stopping then stop_entry ~sw ~backend m e in
        match backend.start ~sw:worker_sw ~instance_id:e.instance_id ~package:e.package ~binding:e.binding ~on_created:created with
        | Error message ->
            publish_resource Lane_addon_resource_events.Acquire_failed e
              (Option.map (fun c -> c.container_id) e.connection) (Some message);
            if e.stopping then (
              match e.connection with None -> e.phase <- Failed ("startup/cleanup: " ^ message)
              | Some _ -> stop_entry ~sw ~backend m e)
            else failed m e message
        | Ok c ->
            e.connection <- Some c;
            let rec loop () =
              if e.stopping then (
                match e.phase with Detached -> () | _ ->
                  let pending = e.wake in
                  Eio.Promise.await pending; clear_wake e; loop ())
              else (
                let pending = e.wake in
                Eio.Promise.await pending;
                let request = e.pending in
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
                    Option.iter (fun request -> wake ~request e) follow_up)
                  else if request = Run_actions then
                    (* The queue was drained before this wake was served
                       (finalize on stop); nothing is owed. *)
                    ()
                  else (
                    let previous_phase = e.phase in
                    if request=Observe_now then e.phase <- Observing;
                    let result =
                      let* sources = backend.acquire ~access:e.source_access ~store:m.store ~package:e.package ~binding:e.binding
                        ~resolve_lane_output:(resolve_lane_output m ~access:e.source_access ~visibility:e.visibility ~run_id:e.run_id) in
                      if e.stopping then Ok () else
                      let* fingerprint = match e.package.refresh_policy with
                        | Source_changes -> Lane_addon_sources.refresh_fingerprint e.refresh_interest sources
                        | Every_hint -> Ok None in
                      if request=Refresh_sources && previous_phase=Attached
                        && Option.is_some fingerprint && fingerprint=e.last_committed_sources
                      then (
                        e.unchanged_source_refreshes <- e.unchanged_source_refreshes + 1;
                        Ok ())
                      else (
                        e.phase <- Observing;
                        let* output = c.observe ~binding:e.binding ~sources in
                        let* () = commit_output m e ~sources output in
                        e.last_committed_sources <- fingerprint;
                        Ok ()) in
                    match result with Ok () -> () | Error message -> failed m e message);
                  loop ()))
            in loop ());
    with
    | Worker_detached -> ()
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> failed m e (Printexc.to_string exn)
    in
    match work () with
    | () -> e.running <- false; e.cancel_worker <- None;
        Eio.Cancel.protect (fun () -> finalize_actions m e);
        if e.stopping && e.phase <> Detached then stop_entry ~sw ~backend m e;
        release_detached m e
    | exception exn -> e.running <- false; e.cancel_worker <- None;
        Eio.Cancel.protect (fun () -> finalize_actions m e);
        release_detached m e; raise exn)
let backend ~store () = match !override with
  | Some backend -> backend
  | None ->
    let clock = Eio_context.get_clock_opt () in
    (* Docker create/inspect/list/remove are the same short host-control class
       as connector sidecar housekeeping. Reuse its operator knob rather than
       adding a second timeout with the same meaning. *)
    let control_timeout_sec = Env_config_runtime.Sidecar.control_command_timeout_sec in
    {
      start = (fun ~sw ~instance_id ~package ~binding ~on_created ->
        let* sampling_handler = prepare_sampling_handler
          ~sw ~store ~instance_id ~package ~binding in
        let wrap worker = {
          container_id = Lane_addon_worker.container_id worker;
          action_schema = (fun () -> Lane_addon_worker.action_schema worker);
          act = (fun ~arguments -> Lane_addon_worker.act worker ~arguments
            |> Result.map_error Lane_addon_worker.error_to_string);
          observe = (fun ~binding ~sources -> Lane_addon_worker.observe worker ~binding ~sources
            |> Result.map_error Lane_addon_worker.error_to_string);
          stop = (fun () -> Lane_addon_worker.stop worker |> Result.map_error Lane_addon_worker.error_to_string) } in
        match clock with
        | None -> Error "Lane Add-on Docker control requires the server Eio clock"
        | Some clock ->
            Lane_addon_worker.start ~sw ~clock ~control_timeout_sec
              ~mgr:Posix_spawn_process_mgr.mgr ~instance_id ~package
              ~on_created:(fun worker -> on_created (wrap worker)) ~artifact_store:store ?sampling_handler ()
            |> Result.map wrap |> Result.map_error Lane_addon_worker.error_to_string);
      acquire = Lane_addon_sources.acquire;
      image_ready = (fun ~package ->
        match clock with
        | None -> Error "Lane Add-on Docker control requires the server Eio clock"
        | Some clock ->
            Lane_addon_worker.inspect_image ~clock ~control_timeout_sec
              ~mgr:Posix_spawn_process_mgr.mgr ~package ()
            |> Result.map (fun (_ : string) -> ())
            |> Result.map_error Lane_addon_worker.error_to_string);
      recover_stop = (fun ~instance_id ~container_id ~max_reply_bytes ->
        match clock with
        | None -> Error "Lane Add-on Docker control requires the server Eio clock"
        | Some clock ->
            Lane_addon_worker.recover_stop ~clock ~control_timeout_sec
              ~mgr:Posix_spawn_process_mgr.mgr
              ~instance_id ~container_id ~max_reply_bytes ()
            |> Result.map_error Lane_addon_worker.error_to_string) }
let manager config =
  let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
  match Hashtbl.find_opt managers root with
  | Some m -> m
  | None -> let m = { store = Lane_addon_store.create ~root; entries = Hashtbl.create 8;
                     recovering = Hashtbl.create 4; configuration_mutex = Eio.Mutex.create ();
                     action_mutex = Eio.Mutex.create (); broadcast_mutex = Eio.Mutex.create ();
                     fleet_journals=Hashtbl.create 8;
                     fleet_operations=Hashtbl.create 8; fleet_recipients=Hashtbl.create 16; fleet_nudge=(fun () -> ());
                     configuration_status = `Null; configuration_nudge = (fun () -> ()); configuration_visibility=[] } in
      Hashtbl.add managers root m; m
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
let read_retained_bindings m =
  let* bindings = offload (fun () -> Lane_addon_store.bindings m.store) in
  normalized_retained_bindings bindings
let without_live_bindings m bindings =
  List.filter (function
    | `Assoc fields -> (match List.assoc_opt "instance_id" fields with
        | Some (`String id) -> not (Hashtbl.mem m.entries id) | _ -> true)
    | _ -> true) bindings
let historical m =
  let* bindings = read_retained_bindings m in
  Ok (without_live_bindings m bindings)
let historical_inventory m =
  let* bindings = offload (fun () -> Lane_addon_store.bindings m.store) in
  (* Omit unreadable inventory entries only after proving each against the
     complete stored graph. Filtering producers first could grant authority. *)
  let visible = List.filter_map (fun value ->
    match normalize_retained_binding ~bindings value with
    | Ok value -> Some value
    | Error detail ->
        Log.Misc.warn "Lane retained binding omitted from inventory: %s" detail;
        None) bindings in
  Ok (without_live_bindings m visible)
let inventory ~config = Eio_context.run_on_owner_domain (fun () ->
  let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
  let stored = offload (fun () -> Lane_addon_store.binding_inventory ~root) in
  let manager = Hashtbl.find_opt managers root in
  let live = match manager with
    | None -> []
    | Some m -> entries m |> List.map (fun (e : entry) ->
        { instance_id=e.instance_id; incarnation=e.instance_id; run_id=e.run_id;
          package_id=e.package.id; title=e.package.title; package_revision=e.package.revision;
          configuration=e.configuration; presence=Live; phase=e.phase }) in
  let bindings = List.map snd stored.records in
  let decode path json =
    let* () = unique_json json in
    let* json = normalize_retained_binding ~bindings json in
    let* fields = object_ json in
    let* instance_id = text fields "instance_id" in
    let* () = if Filename.basename path = Lane_addon_store.digest instance_id ^ ".json"
      then Ok () else Error "binding filename does not match its instance identity" in
    let* incarnation = text fields "incarnation" in
    let* () = if incarnation=instance_id then Ok ()
      else Error "retained incarnation does not match its instance identity" in
    let* run_id = text fields "run_id" in
    let* package_id = text fields "addon_id" in
    let* title = text fields "title" in
    let* package_revision = text fields "revision" in
    let* configuration = match List.assoc_opt "configuration" fields with
      | None -> Error "missing retained configuration owner"
      | Some _ -> configuration_of_fields fields in
    let* phase = match List.assoc_opt "phase" fields with
      | Some value -> phase_of_json value | None -> Error "missing retained phase" in
    let phase = match phase with
      | Detached -> Detached
      | Failed detail -> Failed detail
      | Detaching when Option.exists (fun m -> Hashtbl.mem m.recovering instance_id) manager -> Detaching
      | Attached | Observing | Detaching ->
          Failed "previous process; explicit detach can verify container cleanup" in
    Ok {instance_id;incarnation;run_id;package_id;title;package_revision;
        configuration;presence=Retained;phase} in
  let retained,issues = List.fold_left (fun (values,issues) (path,json) ->
    match decode path json with
    | Error detail -> values,(path,detail)::issues
    | Ok value when List.exists (fun (current : inventory_instance) ->
        current.instance_id=value.instance_id) live -> values,issues
    | Ok value -> value::values,issues) ([],stored.issues) stored.records in
  {owner_present=Option.is_some manager;
   instances=List.sort (fun (a : inventory_instance) b -> String.compare a.instance_id b.instance_id) (live @ retained);
   issues=List.sort_uniq Stdlib.compare issues; complete=stored.complete && issues=[]})
let persisted_binding m id =
  let* bindings = runtime_result (read_retained_bindings m) in
  match List.find_opt (function
    | `Assoc fields -> (match text fields "instance_id" with
        | Ok found -> String.equal found id | Error _ -> false)
    | _ -> false) bindings with
  | Some (`Assoc fields) -> Ok fields
  | _ -> Error (Request_rejected "Lane instance is unavailable to this caller")
let replace_phase fields phase =
  `Assoc (("phase", phase_to_json phase) :: List.remove_assoc "phase" fields)
let historical_detach ~sw m fields =
  let* id = text fields "instance_id" in
  let* previous = match List.assoc_opt "phase" fields with
    | Some json -> phase_of_json json | None -> Error "missing persisted phase" in
  if previous = Detached then Ok (`Assoc fields)
  else if Hashtbl.mem m.recovering id then Ok (replace_phase fields Detaching)
  else
    let* container_id = match List.assoc_opt "container_id" fields with
      | Some `Null -> Ok None
      | Some _ -> Result.map Option.some (text fields "container_id")
      | None -> Error "missing persisted container identity" in
    let* seq = match List.assoc_opt "observation_seq" fields with
      | Some (`Int n) when n >= 0 -> Ok n
      | _ -> Error "missing persisted observation sequence" in
    let* package = match List.assoc_opt "package" fields with
      | Some json -> object_ json | None -> Error "missing persisted package" in
    let* run_id = text fields "run_id" in
    let* package_id = text package "id" in
    let* package_revision = text package "revision" in
    let* resources = match List.assoc_opt "resources" package with
      | Some json -> object_ json | None -> Error "missing persisted resource settings" in
    let* max_reply_bytes = match List.assoc_opt "max_reply_bytes" resources with
      | Some (`Int value) when value > 0 -> Ok value
      | _ -> Error "missing positive persisted reply bound" in
    let detaching = replace_phase fields Detaching in
    Hashtbl.add m.recovering id ();
    let* () = match offload (fun () -> Lane_addon_store.save_binding m.store ~instance_id:id detaching) with
      | Ok () -> Ok ()
      | Error message -> Hashtbl.remove m.recovering id; Error message in
    let backend = backend ~store:m.store () in
    fork_isolated ~sw (fun () ->
      let result = try backend.recover_stop ~instance_id:id ~container_id ~max_reply_bytes with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn) in
      let phase = match result with
        | Ok () -> Detached | Error message -> Failed ("cleanup incomplete: " ^ message) in
      Lane_addon_resource_events.publish
        (match result with
         | Ok () -> Lane_addon_resource_events.Release_confirmed
         | Error _ -> Lane_addon_resource_events.Release_incomplete)
        { instance_id = id; run_id; package_id; package_revision;
          container_id;
          detail = (match result with Ok () -> None | Error message -> Some message) };
      let persisted =
        if phase = Detached && never_started ~seq ~has_container:(Option.is_some container_id)
        then offload (fun () -> Lane_addon_store.remove_binding m.store ~instance_id:id)
        else
          let json = replace_phase fields phase in
          offload (fun () -> Lane_addon_store.save_binding m.store ~instance_id:id json) in
      Hashtbl.remove m.recovering id;
      match persisted with
      | Ok () -> if phase = Detached then m.configuration_nudge ()
      | Error message ->
        Log.Misc.error "Lane recovered cleanup persistence: %s" message);
    Ok detaching
let visible_configuration m ~access =
  match access, m.configuration_status with
  | Lane_addon_sources.Operator_configuration, json -> json
  | (Keeper _ | Unauthenticated), `Assoc fields ->
      let visible_ids = m.configuration_visibility |> List.filter_map (fun (id, visibility) ->
        if can_read access visibility then Some id else None) in
      let selected key = match List.assoc_opt key fields with
        | Some (`List values) -> `List (List.filter (function
            | `Assoc value -> (match List.assoc_opt "id" value with
                | Some (`String id) -> List.mem id visible_ids | _ -> false)
            | _ -> false) values)
        | Some _ | None -> `List [] in
      `Assoc (("issues", selected "issues") :: ("declarations", selected "declarations")
        :: List.remove_assoc "issues" (List.remove_assoc "declarations" fields))
  | (Keeper _ | Unauthenticated), json -> json
let snapshot m ~access ?instance_id () =
  let* past = historical_inventory m in
  let live = entries m |> List.filter (fun e ->
    can_read access e.visibility && Option.fold ~none:true ~some:(String.equal e.instance_id) instance_id) in
  let past = List.filter (function `Assoc fields ->
    Option.fold ~none:true ~some:(fun id -> List.assoc_opt "instance_id" fields = Some (`String id)) instance_id
    | _ -> Option.is_none instance_id) past in
  let past = List.filter (fun value ->
    match Result.bind (object_ value) visibility_of_fields with
    | Ok visibility -> can_read access visibility
    | Error detail ->
        Log.Misc.warn "Lane retained binding omitted from inventory: %s" detail;
        false) past in
  let* () = if Option.is_some instance_id && live = [] && past = []
    then Error "Lane instance is unavailable to this caller" else Ok () in
  let retained = function `Assoc fields ->
    let* owner = configuration_of_fields fields in
    let phase = match List.assoc_opt "phase" fields with
      | Some json -> phase_of_json json | None -> Error "missing phase" in
    let phase = match phase with
      | Ok Detached -> Detached
      | Ok (Failed message) -> Failed message
      | Ok Detaching when (match text fields "instance_id" with
          | Ok id -> Hashtbl.mem m.recovering id | Error _ -> false) -> Detaching
      | _ -> Failed "previous process; explicit detach can verify container cleanup" in
    Ok (`Assoc (("runtime_presence", `String "retained")
      :: ("phase", phase_to_json phase)
      :: ("configuration", Option.fold ~none:`Null ~some:configuration_json owner)
      :: (fields |> List.remove_assoc "runtime_presence"
          |> List.remove_assoc "phase" |> List.remove_assoc "configuration")))
    | _ -> Error "invalid retained instance" in
  let* past = List.fold_right (fun value acc ->
    let* values = acc in let* value = retained value in Ok (value :: values)) past (Ok []) in
  let output = { rows = List.concat_map (fun e -> e.output.rows) live;
    coverage = List.concat_map (fun e -> status_coverage e :: e.output.coverage) live } in
  let live_json entry = match entry_json entry with
    | `Assoc fields -> `Assoc (("runtime_presence", `String "live") :: fields)
    | _ -> assert false in
  match output_to_json output with
  | `Assoc fields -> Ok (`Assoc (("configuration", visible_configuration m ~access)
      :: ("instances", `List (List.map live_json live @ past)) :: fields))
  | _ -> assert false
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
  let* bindings = runtime_result (read_retained_bindings m) in
  let rec read acc statuses = function
    | [] -> Ok (List.rev acc, List.rev statuses)
    | `Assoc fields :: rest ->
        let* id = text fields "instance_id" in let* run = text fields "run_id" in
        let* visibility = visibility_of_fields fields in
        if not (can_read access visibility)
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
                let detached = match List.assoc_opt "phase" fields with
                  | Some json -> phase_of_json json = Ok Detached | None -> false in
                { source_id = id; incarnation = id; cursor = Some (string_of_int expected_seq);
                  complete = detached && expected_seq > 0;
                  detail = Some (if detached then "detached; retained range only"
                    else "previous process; current observation and cleanup state are unknown") } in
          read (output :: acc) (status :: statuses) rest
    | _ -> Error "invalid persisted binding" in
  let* outputs, statuses = runtime_result (read [] [] bindings) in
  (* Each instance response is bounded by its own declared resource envelope.
     File parsing and filtering happened outside the owner domain. *)
  let rows = List.concat_map (fun output -> output.rows) outputs in
  let coverage = List.concat_map (fun output -> output.coverage) outputs @ statuses in
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
let attach_entry ~sw m ~run_id ~package ~binding ~configuration ~source_access ~visibility =
  let* refresh_interest = Lane_addon_sources.refresh_interest binding in
  let* input_installations = match configuration with
    | None -> Lane_addon_sources.dependencies binding
    | Some owner -> validate_connection m ~run_id ~configuration_id:owner.id ~binding in
  let promise, resolver = Eio.Promise.create () in
  let e = { instance_id = Random_id.uuid_v7 (); run_id; package; binding;
    phase = Attached; seq = 0; output = {rows=[];coverage=[]}; connection = None;
    stopping = false; cleanup_running = false; wake = promise; resolver; pending = Idle;
    refresh_interest; source_access; visibility; last_committed_sources=None; unchanged_source_refreshes=0;
    running = true; persistence_mutex = Eio.Mutex.create (); coalesced_wakes = 0;
    action_queue = Queue.create (); current_action = None;
    cancel_worker = None; configuration; input_installations } in
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
  (match e.phase with Detached -> () | _ ->
    e.stopping <- true; e.phase <- Detaching; wake e;
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

let read_declaration ?caller ?access ~config json = Eio_context.run_on_owner_domain (fun () ->
  let* source_path = Lane_addon_declaration.read_request json in
  let* directory = edit_directory config in
  let m = manager config in let access = caller_access ?access caller in
  Eio.Mutex.use_ro m.configuration_mutex (fun () ->
    let denied = {Lane_addon_declaration.code=Invalid_request;
      message="Lane declaration is unavailable to this caller";current=None} in
    let* document = offload (fun () -> Lane_addon_declaration.read ~directory ~source_path)
      |> Result.map_error (fun error -> match access, error.Lane_addon_declaration.code with
        | (Keeper _ | Unauthenticated), Not_found -> denied
        | _ -> error) in
    let* () = authorize_document m ~access document
      |> Result.map_error (fun error -> match access with
        | Lane_addon_sources.Operator_configuration -> error
        | Keeper _ | Unauthenticated -> denied) in
    Ok (Lane_addon_declaration.document_to_json document)))

let declaration_writer_key = Eio.Fiber.create_key ()
let save_declaration ?caller ?access ~config json = Eio_context.run_on_owner_domain (fun () ->
  let write = Option.value ~default:Lane_addon_declaration.write
    (Eio.Fiber.get declaration_writer_key) in
  let* request = Lane_addon_declaration.write_request json in
  let* directory = edit_directory config in
  let m = manager config in let access = caller_access ?access caller in
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
      | Error error -> Error error in
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
           | _ -> Error {Lane_addon_declaration.code=Invalid_request;
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
let remove_configuration_file ~directory (owner : configuration_owner) =
  let snapshot = Lane_addon_config.load ~directory in
  if not snapshot.complete then Error "Lane configuration directory could not be read; removal was not applied"
  else
    let matches = List.filter (fun (d : Lane_addon_config.declaration) -> d.id = owner.id) snapshot.declarations in
    let conflicts = List.filter (fun (i : Lane_addon_config.issue) -> i.id = Some owner.id) snapshot.issues in
    let path = match matches, conflicts with
      | [d], [] when d.revision = owner.revision -> Ok (Some d.source_path)
      | [_], [] -> Error "Lane configuration changed; refresh before removing its current installation"
      | [], [] when List.mem owner.source_path snapshot.paths ->
          Error "Lane declaration is invalid; correct or remove the declaration before detaching"
      | [], [] -> Ok None
      | _ -> Error "Lane configuration identity is ambiguous; remove its duplicate declarations" in
    let* path = path in
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
        | _ -> None in
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
        let* c = match e.connection with Some c -> Ok c | None -> Error (Request_rejected "action worker initialization pending") in
        let* name, schema = match e.package.action_tool, c.action_schema () with
          | Some name, Some schema -> Ok (name, schema)
          | _ -> Error (Request_rejected "worker has no available advertised action port") in
        let* () = if String.length (Yojson.Safe.to_string arguments) <= e.package.resources.max_reply_bytes then Ok ()
          else Error (Request_rejected "action input exceeds the package message envelope") in
        let* () = runtime_result (Lane_addon_action.validate_schema schema) in
        let* _ = request_result (Lane_addon_action.validate ~schema ~name arguments) in
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

let dispatch ?caller ?access ~config ~operation json = Eio_context.run_on_owner_domain (fun () ->
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
  let access = caller_access ?access caller in
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
      let source_access = match caller, access with
        | None, Lane_addon_sources.Operator_configuration -> Lane_addon_sources.Unauthenticated
        | _, access -> access in
      let* () = request_result (Lane_addon_sources.authorize ~access:source_access binding) in
      let* visibility = request_result (binding_visibility m ~access:source_access binding) in
      (* A private attachment keeps its source owner for every later wake.
         Operator authority may discover the binding, but must not remain the
         worker's acquisition authority after its Fusion owner changes. *)
      let source_access = match visibility with
        | Keeper_only keeper -> Lane_addon_sources.Keeper keeper
        | Shared | Operator_only -> source_access in
      let* () = request_result (Lane_addon_sources.authorize ~access:source_access binding) in
      runtime_result (attach_entry ~sw m ~run_id ~package ~binding ~configuration:None ~source_access ~visibility)
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
        match Hashtbl.find_opt m.entries id with
        | None ->
            let* fields = persisted_binding m id in
            let* phase = match List.assoc_opt "phase" fields with
              | Some json -> runtime_result (phase_of_json json) | None -> Error (Runtime_failed "missing retained phase") in
            let* owner = runtime_result (configuration_of_fields fields) in
            let* () = match phase, owner with
              | Detached, _ | _, None -> Ok ()
              | _, Some owner ->
                  let another_owner = List.exists (fun e -> match e.configuration with
                    | Some current -> current.id = owner.id | None -> false) (entries m) in
                  if another_owner then Ok () else
                    runtime_result (offload (fun () -> remove_configuration_file ~directory:(configuration_directory config) owner)) in
            runtime_result (historical_detach ~sw m fields)
        | Some e ->
            let* () = match e.configuration with None -> Ok () | Some owner ->
              runtime_result (offload (fun () -> remove_configuration_file ~directory:(configuration_directory config) owner)) in
            runtime_result (detach_entry ~sw m e)))

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
    let past = historical m in
    let histories_readable = ref true in
    let histories = match past with
      | Error message -> add_issue directory message; []
      | Ok values -> List.filter_map (fun json ->
          match object_ json with
          | Error message -> histories_readable := false; add_issue directory message; None
          | Ok fields ->
              match configuration_of_fields fields with
              | Ok None -> None
              | Ok (Some owner) -> Some (owner, fields)
              | Error message -> histories_readable := false; add_issue directory message; None) values in
    let can_apply = Result.is_ok past && !histories_readable && snapshot.complete in
    if not can_apply then
      List.iter (fun (d : Lane_addon_config.declaration) ->
        if not d.enabled then add_issue ~id:d.id d.source_path
          "Off requested; worker cleanup waits for a complete declaration and retained-binding reading") snapshot.declarations;
    let retire sw e =
      match detach_entry ~sw m e with
      | Ok _ -> ()
      | Error message ->
          let path = Option.fold ~none:directory ~some:(fun o -> o.source_path) e.configuration in
          add_issue path message in
    let retire_past sw (owner, fields) =
      match historical_detach ~sw m fields with
      | Ok _ -> () | Error message -> add_issue ~id:owner.id owner.source_path message in
    let detached fields =
      match List.assoc_opt "phase" fields with
      | Some json -> phase_of_json json = Ok Detached | None -> false in
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
           if not (protected owner) && not (detached fields) then retire_past sw history) histories
     | Ok _ -> ());
    (match root_switch with
     | Error _ -> ()
     | Ok sw when can_apply ->
         List.iter (fun (d : Lane_addon_config.declaration) ->
           let retained_visibility =
             let same (owner : configuration_owner) = owner.id = d.id
               && owner.source_path = d.source_path && owner.revision = d.revision in
             let live = live_for d.id |> List.filter_map (fun e ->
               match e.configuration with Some owner when same owner -> Some e.visibility | _ -> None) in
             let past = histories |> List.filter_map (fun (owner, fields) ->
               if same owner then Result.to_option (visibility_of_fields fields) else None) in
             match List.sort_uniq Stdlib.compare (live @ past) with
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
               (List.filter (fun (owner, fields) -> owner.id = d.id && not (detached fields)) histories))
           else
           let admitted =
             let* visibility = document_owner in
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
               let pending = List.filter (fun (owner, fields) -> owner.id = d.id && not (detached fields)) histories in
               if pending <> [] then List.iter (retire_past sw) pending
               else (
                 (* An image that is not on the host is not a worker that failed.
                    Creating one would fail the same way on every beat and leave
                    an instance behind each time (#37897). Look first, report the
                    missing image as this declaration's issue, and look again on
                    the next beat, so an image built later attaches without a
                    TOML edit. *)
                 match (backend ~store:m.store ()).image_ready ~package:d.package with
                 | Error message -> add_issue ~id:d.id d.source_path message
                 | Ok () ->
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
    let nullable_string = function None -> `Null | Some s -> `String s in
    let exports = entries m |> List.filter_map (fun e ->
      let configured_off = snapshot.complete && match e.configuration with
        | None -> false
        | Some owner -> List.exists (fun (d : Lane_addon_config.declaration) ->
            d.id = owner.id && not d.enabled) snapshot.declarations in
      (* Cleanup failures retain their worker and evidence for retry, but a
         retiring owner cannot supply a usable Skill. An incomplete reading
         does not authorize inferring desired activity for a running owner. *)
      if e.stopping || configured_off then None else
      match e.package.skills_directory, e.phase with
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
    let declarations = List.map (fun (d : Lane_addon_config.declaration) ->
      let active = match live_for d.id with [e] -> Some e | _ -> None in
      let applied_revision = Option.bind active (fun e -> Option.map (fun o -> o.revision) e.configuration) in
      `Assoc ["id", `String d.id; "source_path", `String d.source_path; "enabled", `Bool d.enabled;
        "desired_revision", `String d.revision; "applied_revision", nullable_string applied_revision;
        "instance_id", nullable_string (Option.map (fun e -> e.instance_id) active)]) snapshot.declarations in
    let json = `Assoc ["directory", `String directory; "complete", `Bool snapshot.complete;
      "issues", `List (List.rev_map (fun (i : Lane_addon_config.issue) ->
        `Assoc ["source_path", `String i.source_path; "id", nullable_string i.id; "message", `String i.message]) !issues);
      "declarations", `List declarations] in
    m.configuration_status <- json;
    Ok json))

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
      ~lifecycle:Always_on ~consumers:[consumer] in
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
            let issue = `Assoc ["source_path", `String directory; "id", `Null;
              "message", `String (String.concat "; " resolution.warnings)] in
            (manager config).configuration_status <- `Assoc [
              "directory", `String directory; "complete", `Bool false;
              "issues", `List [issue]; "declarations", `List []];
            Ok ()
        | Ready | Warn | Missing_status ->
            Result.map (fun _ -> ()) (reconcile_configuration ~config ~directory)
    end) in
    (* Configuration is maintenance work. Reuse the existing maintenance
       cadence on an independent Pulse, outside Keeper sweeps and turns. *)
    let interval = Env_config_runtime_services.Timeouts.maintenance_pulse_interval_sec in
    let pulse = Pulse.create ~clock
      ~rhythm:{Pulse.base_s=interval; min_s=interval; max_s=interval; quiet=(0,0)}
      ~lifecycle:Always_on ~consumers:[consumer] in
    let stop () = active := false; Pulse.shutdown pulse in
    Hashtbl.add configuration_services key stop;
    let m = manager config in
    m.configuration_nudge <- (fun () -> Pulse.nudge pulse ~reason:"configuration reconciliation requested");
    Eio.Switch.on_release sw (fun () ->
      stop (); Hashtbl.remove configuration_services key;
      m.configuration_nudge <- (fun () -> ()));
    Pulse.run ~sw pulse)

module For_testing = struct
  let with_declaration_writer writer f = Eio.Fiber.with_binding declaration_writer_key writer f
  type nonrec connection = connection = {
    observe : binding:Yojson.Safe.t -> sources:Yojson.Safe.t -> (output, string) result;
    action_schema : unit -> Yojson.Safe.t option;
    act : arguments:Yojson.Safe.t -> (Lane_addon_action.package_result, string) result;
    stop : unit -> (unit, string) result;
    container_id : string;
  }
  type nonrec backend = backend = {
    start : sw:Eio.Switch.t -> instance_id:string -> package:package -> binding:Yojson.Safe.t ->
      on_created:(connection -> unit) -> (connection, string) result;
    acquire : access:Lane_addon_sources.access -> store:Lane_addon_store.t -> package:package ->
      resolve_lane_output:(installation_id:string -> (Lane_addon_sources.lane_output, string) result) ->
      binding:Yojson.Safe.t ->
      (Yojson.Safe.t, string) result;
    recover_stop : instance_id:string -> container_id:string option -> max_reply_bytes:int ->
      (unit, string) result;
    image_ready : package:package -> (unit, string) result;
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
