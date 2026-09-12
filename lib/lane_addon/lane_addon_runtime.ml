open Lane_addon_types
let ( let* ) = Result.bind
type operation = Attach | Inspect | Observe | Detach | Slice | Evidence
exception Worker_detached
type connection = {
  observe : binding:Yojson.Safe.t -> sources:Yojson.Safe.t -> (output, string) result;
  stop : unit -> (unit, string) result;
  container_id : string;
}
type backend = {
  start : sw:Eio.Switch.t -> instance_id:string -> package:package ->
    on_created:(connection -> unit) -> (connection, string) result;
  acquire : store:Lane_addon_store.t -> package:package ->
    resolve_lane_output:(installation_id:string -> (Lane_addon_sources.lane_output, string) result) ->
    binding:Yojson.Safe.t ->
    (Yojson.Safe.t, string) result;
  recover_stop : instance_id:string -> container_id:string option -> max_reply_bytes:int ->
    (unit, string) result;
}
type configuration_owner = { id : string; source_path : string; revision : string }
type skill_export_owner = Declaration of string | Instance of string
type skill_export = { owner : skill_export_owner; instance_id : string; package : package }
let skill_source_id = function
  | Declaration id -> "lane-" ^ Digestif.SHA256.(to_hex (digest_string ("declaration\x00" ^ id)))
  | Instance id -> "lane-" ^ Digestif.SHA256.(to_hex (digest_string ("instance\x00" ^ id)))
let skill_export_handler = ref None
let register_skill_export_handler handler = skill_export_handler := Some handler
type entry = {
  instance_id : string; run_id : string; package : package; binding : Yojson.Safe.t;
  mutable phase : phase; mutable seq : int; mutable output : output;
  mutable connection : connection option; mutable stopping : bool;
  mutable cleanup_running : bool; mutable wake : unit Eio.Promise.t;
  mutable resolver : unit Eio.Promise.u; mutable pending : bool;
  mutable running : bool; persistence_mutex : Eio.Mutex.t;
  mutable coalesced_wakes : int;
  mutable cancel_worker : (unit -> unit) option;
  mutable configuration : configuration_owner option;
  input_installations : string list;
}
type manager = { store : Lane_addon_store.t; entries : (string, entry) Hashtbl.t;
  recovering : (string, unit) Hashtbl.t;
  configuration_mutex : Eio.Mutex.t; mutable configuration_status : Yojson.Safe.t;
  mutable configuration_nudge : unit -> unit }
let managers : (string, manager) Hashtbl.t = Hashtbl.create 4
let override : backend option ref = ref None
let delivery_handler = ref None
let register_delivery_handler handler = delivery_handler := Some handler
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
let entry_json e =
  `Assoc ["instance_id", `String e.instance_id; "run_id", `String e.run_id;
    "addon_id", `String e.package.id; "title", `String e.package.title;
    "revision", `String e.package.revision; "phase", phase_to_json e.phase;
    "observation_seq", `Int e.seq; "rows_count", `Int (List.length e.output.rows);
    "observation_pending", `Bool e.pending; "coalesced_wakes", `Int e.coalesced_wakes;
    "binding", e.binding; "package", package_to_json e.package;
    "configuration", Option.fold ~none:`Null ~some:configuration_json e.configuration;
    "container_id", (match e.connection with None -> `Null | Some c -> `String c.container_id)]
let persist m e = Eio.Mutex.use_ro e.persistence_mutex (fun () ->
  (* Capture mutable state on the owning domain after serializing writes.
     The I/O thread sees only the immutable snapshot. *)
  let json = entry_json e in
  offload (fun () -> Lane_addon_store.save_binding m.store ~instance_id:e.instance_id json))
let wake e =
  if e.pending then e.coalesced_wakes <- e.coalesced_wakes + 1
  else (e.pending <- true; Eio.Promise.resolve e.resolver ())
let clear_wake e =
  let promise, resolver = Eio.Promise.create () in
  e.wake <- promise; e.resolver <- resolver; e.pending <- false
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
let resolve_lane_output m ~run_id ~installation_id =
  let producers = entries m |> List.filter (fun e -> match e.configuration with
    | Some owner -> owner.id = installation_id | None -> false) in
  match producers with
  | [e] when e.run_id <> run_id -> Error "upstream installation belongs to another run"
  | [e] when e.stopping -> Error "upstream installation is being replaced or removed"
  | [e] when e.seq = 0 -> Error "upstream installation has no completed output"
  | [e] ->
      (match e.configuration with
       | Some owner -> Ok {Lane_addon_sources.installation_id; instance_id=e.instance_id;
           run_id=e.run_id; configuration_revision=owner.revision; package_revision=e.package.revision;
           observation_seq=e.seq; output=e.output; status=status_coverage e}
       | None -> assert false)
  | [] -> Error "upstream installation is unavailable"
  | _ -> Error "multiple workers claim the upstream installation"
let wake_dependents m producer =
  match producer.configuration with
  | None -> ()
  | Some owner -> entries m |> List.iter (fun e ->
      if e.running && not e.stopping && e.run_id = producer.run_id
        && List.mem owner.id e.input_installations then wake e)
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
        match backend.start ~sw:worker_sw ~instance_id:e.instance_id ~package:e.package ~on_created:created with
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
                clear_wake e;
                if e.stopping then loop () else (
                  e.phase <- Observing;
                  let result =
                    let* sources = backend.acquire ~store:m.store ~package:e.package ~binding:e.binding
                      ~resolve_lane_output:(resolve_lane_output m ~run_id:e.run_id) in
                    let* output = c.observe ~binding:e.binding ~sources in
                    let seq = e.seq + 1 in
                    let output = namespace e seq output in
                    let* () =
                      let bytes = Yojson.Safe.to_string (output_to_json output) in
                      if String.length bytes <= e.package.resources.max_reply_bytes then Ok ()
                      else Error "namespaced observation exceeds the package output envelope" in
                    let* () = offload (fun () -> Lane_addon_store.append_observation m.store
                      ~instance_id:e.instance_id ~seq ~sources output) in
                    Ok (seq, output) in
                  (match result with
                   | Ok (seq, output) -> e.seq <- seq; e.output <- output;
                       if not e.stopping then e.phase <- Attached;
                       (match persist m e with Ok () -> wake_dependents m e
                        | Error message -> failed m e message)
                   | Error message -> failed m e message);
                  loop ()))
            in loop ());
    with
    | Worker_detached -> ()
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> failed m e (Printexc.to_string exn)
    in
    match work () with
    | () -> e.running <- false; e.cancel_worker <- None;
        if e.stopping && e.phase <> Detached then stop_entry ~sw ~backend m e;
        release_detached m e
    | exception exn -> e.running <- false; e.cancel_worker <- None;
        release_detached m e; raise exn)
let backend () = match !override with
  | Some backend -> backend
  | None -> {
      start = (fun ~sw ~instance_id ~package ~on_created ->
        let wrap worker = {
          container_id = Lane_addon_worker.container_id worker;
          observe = (fun ~binding ~sources -> Lane_addon_worker.observe worker ~binding ~sources
            |> Result.map_error Lane_addon_worker.error_to_string);
          stop = (fun () -> Lane_addon_worker.stop worker |> Result.map_error Lane_addon_worker.error_to_string) } in
        Lane_addon_worker.start ~sw ~mgr:Posix_spawn_process_mgr.mgr ~instance_id ~package
          ~on_created:(fun worker -> on_created (wrap worker)) ()
        |> Result.map wrap |> Result.map_error Lane_addon_worker.error_to_string);
      acquire = Lane_addon_sources.acquire;
      recover_stop = (fun ~instance_id ~container_id ~max_reply_bytes ->
        Lane_addon_worker.recover_stop ~mgr:Posix_spawn_process_mgr.mgr
          ~instance_id ~container_id ~max_reply_bytes ()
        |> Result.map_error Lane_addon_worker.error_to_string) }
let manager config =
  let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
  match Hashtbl.find_opt managers root with
  | Some m -> m
  | None -> let m = { store = Lane_addon_store.create ~root; entries = Hashtbl.create 8;
                     recovering = Hashtbl.create 4; configuration_mutex = Eio.Mutex.create ();
                     configuration_status = `Null; configuration_nudge = (fun () -> ()) } in
      Hashtbl.add managers root m; m
let notify_activity ~config =
  if Eio_context.root_switch_on_current_domain () then
    let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
    match Hashtbl.find_opt managers root with
    | None -> ()
    | Some m -> Hashtbl.iter (fun _ e ->
        if e.running && not e.stopping then wake e) m.entries
let find m args = let* id = text args "instance_id" in
  match Hashtbl.find_opt m.entries id with Some e -> Ok e | None -> Error "unknown active instance"
let historical m =
  let* bindings = offload (fun () -> Lane_addon_store.bindings m.store) in
  Ok (List.filter (function
    | `Assoc fields -> (match List.assoc_opt "instance_id" fields with
        | Some (`String id) -> not (Hashtbl.mem m.entries id) | _ -> true)
    | _ -> true) bindings)
let persisted_binding m id =
  let* bindings = offload (fun () -> Lane_addon_store.bindings m.store) in
  match List.find_opt (function
    | `Assoc fields -> (match text fields "instance_id" with
        | Ok found -> String.equal found id | Error _ -> false)
    | _ -> false) bindings with
  | Some (`Assoc fields) -> Ok fields
  | _ -> Error "unknown retained instance"
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
    let backend = backend () in
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
      let json = replace_phase fields phase in
      let persisted = offload (fun () -> Lane_addon_store.save_binding m.store ~instance_id:id json) in
      Hashtbl.remove m.recovering id;
      match persisted with
      | Ok () -> if phase = Detached then m.configuration_nudge ()
      | Error message ->
        Log.Misc.error "Lane recovered cleanup persistence: %s" message);
    Ok detaching
let snapshot m ?instance_id () =
  let* past = historical m in
  let live = entries m |> List.filter (fun e ->
    Option.fold ~none:true ~some:(String.equal e.instance_id) instance_id) in
  let past = List.filter (function `Assoc fields ->
    Option.fold ~none:true ~some:(fun id -> List.assoc_opt "instance_id" fields = Some (`String id)) instance_id
    | _ -> Option.is_none instance_id) past in
  let* () = if Option.is_some instance_id && live = [] && past = [] then Error "unknown instance" else Ok () in
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
    Ok (`Assoc (("phase", phase_to_json phase)
      :: ("configuration", Option.fold ~none:`Null ~some:configuration_json owner)
      :: (fields |> List.remove_assoc "phase" |> List.remove_assoc "configuration")))
    | _ -> Error "invalid retained instance" in
  let* past = List.fold_right (fun value acc ->
    let* values = acc in let* value = retained value in Ok (value :: values)) past (Ok []) in
  let output = { rows = List.concat_map (fun e -> e.output.rows) live;
    coverage = List.concat_map (fun e -> status_coverage e :: e.output.coverage) live } in
  match output_to_json output with
  | `Assoc fields -> Ok (`Assoc (("configuration", m.configuration_status)
      :: ("instances", `List (List.map entry_json live @ past)) :: fields))
  | _ -> assert false
let slice m args =
  let optional_text key = match List.assoc_opt key args with
    | None -> Ok None | Some _ -> Result.map Option.some (text args key) in
  let optional_time key = match List.assoc_opt key args with
    | None -> Ok None | Some (`Int n) -> Ok (Some (float_of_int n))
    | Some (`Float t) when Float.is_finite t -> Ok (Some t)
    | _ -> Error (key ^ " requires a finite epoch timestamp") in
  let* run_id = optional_text "run_id" in let* lane_id = optional_text "lane_id" in
  let* since = optional_time "since" in let* until = optional_time "until" in
  let* () = match since, until with Some a, Some b when a > b -> Error "since exceeds until" | _ -> Ok () in
  let* bindings = offload (fun () -> Lane_addon_store.bindings m.store) in
  let rec read acc statuses = function
    | [] -> Ok (List.rev acc, List.rev statuses)
    | `Assoc fields :: rest ->
        let* id = text fields "instance_id" in let* run = text fields "run_id" in
        if Option.fold ~none:false ~some:(fun selected -> selected <> run) run_id then read acc statuses rest
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
  let* outputs, statuses = read [] [] bindings in
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

let attach_entry ~sw m ~run_id ~package ~binding ~configuration =
  let* input_installations = match configuration with
    | None -> Lane_addon_sources.dependencies binding
    | Some owner -> validate_connection m ~run_id ~configuration_id:owner.id ~binding in
  let promise, resolver = Eio.Promise.create () in
  let e = { instance_id = Random_id.uuid_v7 (); run_id; package; binding;
    phase = Attached; seq = 0; output = {rows=[];coverage=[]}; connection = None;
    stopping = false; cleanup_running = false; wake = promise; resolver; pending = false;
    running = true; persistence_mutex = Eio.Mutex.create (); coalesced_wakes = 0;
    cancel_worker = None; configuration; input_installations } in
  let* () = persist m e in
  Hashtbl.add m.entries e.instance_id e;
  wake e; run ~sw (backend ()) m e;
  Ok (entry_json e)

let detach_entry ~sw m e =
  (match e.phase with Detached -> () | _ ->
    e.stopping <- true; e.phase <- Detaching; wake e;
    wake_dependents m e;
    stop_entry ~sw ~backend:(backend ()) m e);
  let* () = persist m e in Ok (entry_json e)

let configuration_directory config =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path:config.Workspace.base_path in
  Filename.concat resolution.config_root.path "lane-addons"

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

let dispatch ?caller ~config ~operation json = Eio_context.run_on_owner_domain (fun () ->
  let* args = object_ json in
  let allowed = match operation with
    | Attach -> ["manifest_path"; "run_id"; "binding"]
    | Inspect -> ["instance_id"]
    | Observe | Detach -> ["instance_id"]
    | Slice -> ["run_id"; "lane_id"; "since"; "until"]
    | Evidence -> ["instance_id"; "row_ids"; "keeper_name"] in
  let names = List.map fst args in
  let* () = if List.length names <> List.length (List.sort_uniq String.compare names)
    || List.exists (fun name -> not (List.mem name allowed)) names
    then Error "duplicate or unknown Lane request field" else Ok () in
  let m = manager config in
  match operation with
  | Inspect ->
      let* instance_id = match List.assoc_opt "instance_id" args with
        | None -> Ok None | Some _ -> Result.map Option.some (text args "instance_id") in
      snapshot m ?instance_id ()
  | Slice -> slice m args
  | Evidence ->
      let* id = text args "instance_id" in
      let* binding = match Hashtbl.find_opt m.entries id with
        | Some e -> Ok (entry_json e)
        | None -> Result.map (fun fields -> `Assoc fields) (persisted_binding m id) in
      let* ids = match List.assoc_opt "row_ids" args with
        | Some (`List values) ->
            List.fold_left (fun acc -> function `String id -> let* ids = acc in Ok (id :: ids)
              | _ -> Error "row_ids must contain strings") (Ok []) values
        | _ -> Error "row_ids requires an array" in
      let* frozen = offload (fun () -> Lane_addon_store.freeze m.store ~instance_id:id ~binding ~row_ids:ids) in
      (match List.assoc_opt "keeper_name" args with
       | None -> Ok frozen
       | Some _ ->
           let deliver () =
             let* keeper_name = text args "keeper_name" in
             let* caller = match caller with
               | Some value when String.trim value <> "" -> Ok value
               | _ -> Error "evidence delivery requires an authenticated caller" in
             let* handler = match !delivery_handler with
               | Some handler -> Ok handler | None -> Error "Keeper evidence delivery is unavailable" in
             let* evidence = offload (fun () -> Lane_addon_store.publish_for_keeper
               ~base_path:config.base_path m.store frozen) in
             let* fields = object_ evidence in let* prompt = text fields "message" in
             let receipt = try handler ~config ~caller ~keeper_name ~prompt with
               | Eio.Cancel.Cancelled _ as exn -> raise exn
               | exn -> Error (Printexc.to_string exn) in
             Ok (evidence, receipt)
           in
           let published, receipt = match deliver () with
             | Ok result -> result | Error message -> frozen, Error message in
           let delivery = match receipt with
             | Ok receipt -> `Assoc ["status", `String "accepted"; "receipt", receipt]
             | Error message -> `Assoc ["status", `String "failed"; "error", `String message] in
           let* fields = object_ published in Ok (`Assoc (("delivery", delivery) :: fields)))
  | Attach ->
      let* path = text args "manifest_path" in let* run_id = text args "run_id" in
      let* binding = match List.assoc_opt "binding" args with Some (`Assoc _ as value) -> Ok value
        | _ -> Error "binding requires an object" in
      let* package = offload (fun () -> Lane_addon_manifest.load ~path) in
      let* () = Lane_addon_sources.validate binding in
      let* sw = match Eio_context.get_root_switch_opt () with
        | Some sw -> Ok sw | None -> Error "server background owner unavailable" in
      attach_entry ~sw m ~run_id ~package ~binding ~configuration:None
  | Observe ->
      let* e = find m args in
      if e.stopping then Error "instance is stopping or detached"
      else if not e.running then Error "worker stopped; detach and attach again to restart"
      else (wake e; Ok (entry_json e))
  | Detach ->
      let* id = text args "instance_id" in
      let* sw = match Eio_context.get_root_switch_opt () with
        | Some sw -> Ok sw | None -> Error "server background owner unavailable" in
      (* Each owned transition is recoverable from its binding record.
         Cancellation releases the serializer so a later pass can reconcile. *)
      Eio.Mutex.use_ro m.configuration_mutex (fun () ->
        match Hashtbl.find_opt m.entries id with
        | None ->
            let* fields = persisted_binding m id in
            let* phase = match List.assoc_opt "phase" fields with
              | Some json -> phase_of_json json | None -> Error "missing retained phase" in
            let* owner = configuration_of_fields fields in
            let* () = match phase, owner with
              | Detached, _ | _, None -> Ok ()
              | _, Some owner ->
                  let another_owner = List.exists (fun e -> match e.configuration with
                    | Some current -> current.id = owner.id | None -> false) (entries m) in
                  if another_owner then Ok () else
                    offload (fun () -> remove_configuration_file ~directory:(configuration_directory config) owner) in
            historical_detach ~sw m fields
        | Some e ->
            let* () = match e.configuration with None -> Ok () | Some owner ->
              offload (fun () -> remove_configuration_file ~directory:(configuration_directory config) owner) in
            detach_entry ~sw m e))

let reconcile_configuration ~config ~directory = Eio_context.run_on_owner_domain (fun () ->
  let m = manager config in
  Eio.Mutex.use_ro m.configuration_mutex (fun () ->
    let snapshot = offload (fun () -> Lane_addon_config.load ~directory) in
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
           match validate_connection m ~run_id:d.run_id ~configuration_id:d.id ~binding:d.binding with
           | Error message -> add_issue ~id:d.id d.source_path message
           | Ok _ -> match live_for d.id with
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
                 let owner = Some {id=d.id; source_path=d.source_path; revision=d.revision} in
                 match attach_entry ~sw m ~run_id:d.run_id ~package:d.package ~binding:d.binding ~configuration:owner with
                 | Ok _ -> () | Error message -> add_issue ~id:d.id d.source_path message)
           | _ -> add_issue ~id:d.id d.source_path "multiple workers claim this configuration identity") snapshot.declarations
     | Ok _ -> ());
    let nullable_string = function None -> `Null | Some s -> `String s in
    let exports = entries m |> List.filter_map (fun e ->
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
      `Assoc ["id", `String d.id; "source_path", `String d.source_path;
        "desired_revision", `String d.revision; "applied_revision", nullable_string applied_revision;
        "instance_id", nullable_string (Option.map (fun e -> e.instance_id) active)]) snapshot.declarations in
    let json = `Assoc ["directory", `String directory; "complete", `Bool snapshot.complete;
      "issues", `List (List.rev_map (fun (i : Lane_addon_config.issue) ->
        `Assoc ["source_path", `String i.source_path; "id", nullable_string i.id; "message", `String i.message]) !issues);
      "declarations", `List declarations] in
    m.configuration_status <- json;
    Ok json))

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
    m.configuration_nudge <- (fun () -> Pulse.nudge pulse ~reason:"owned worker released");
    Eio.Switch.on_release sw (fun () ->
      stop (); Hashtbl.remove configuration_services key;
      m.configuration_nudge <- (fun () -> ()));
    Pulse.run ~sw pulse)

module For_testing = struct
  type nonrec connection = connection = {
    observe : binding:Yojson.Safe.t -> sources:Yojson.Safe.t -> (output, string) result;
    stop : unit -> (unit, string) result;
    container_id : string;
  }
  type nonrec backend = backend = {
    start : sw:Eio.Switch.t -> instance_id:string -> package:package ->
      on_created:(connection -> unit) -> (connection, string) result;
    acquire : store:Lane_addon_store.t -> package:package ->
      resolve_lane_output:(installation_id:string -> (Lane_addon_sources.lane_output, string) result) ->
      binding:Yojson.Safe.t ->
      (Yojson.Safe.t, string) result;
    recover_stop : instance_id:string -> container_id:string option -> max_reply_bytes:int ->
      (unit, string) result;
  }
  let with_backend backend f = let previous = !override in override := Some backend;
    Fun.protect ~finally:(fun () -> override := previous) f
  let reset () =
    Hashtbl.iter (fun _ stop -> stop ()) configuration_services;
    Hashtbl.clear configuration_services; Hashtbl.clear managers;
    delivery_handler := None; skill_export_handler := None
end
