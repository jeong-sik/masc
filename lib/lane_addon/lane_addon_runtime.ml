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
  acquire : store:Lane_addon_store.t -> package:package -> binding:Yojson.Safe.t ->
    (Yojson.Safe.t, string) result;
  recover_stop : instance_id:string -> container_id:string -> max_reply_bytes:int ->
    (unit, string) result;
}
type entry = {
  instance_id : string; run_id : string; package : package; binding : Yojson.Safe.t;
  mutable phase : phase; mutable seq : int; mutable output : output;
  mutable connection : connection option; mutable stopping : bool;
  mutable cleanup_running : bool; mutable wake : unit Eio.Promise.t;
  mutable resolver : unit Eio.Promise.u; mutable pending : bool;
  mutable running : bool; persistence_mutex : Eio.Mutex.t;
  mutable coalesced_wakes : int;
  mutable cancel_worker : (unit -> unit) option;
}
type manager = { store : Lane_addon_store.t; entries : (string, entry) Hashtbl.t;
  recovering : (string, unit) Hashtbl.t }
let managers : (string, manager) Hashtbl.t = Hashtbl.create 4
let override : backend option ref = ref None
let delivery_handler = ref None
let register_delivery_handler handler = delivery_handler := Some handler
let uuid = Uuidm.v4_gen (Random.State.make_self_init ())
let text fields key = match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> Error (key ^ " requires a non-blank string")
let object_ = function `Assoc fields -> Ok fields | _ -> Error "expected an object"
let offload f = Eio_unix.run_in_systhread f
let entry_json e =
  `Assoc ["instance_id", `String e.instance_id; "run_id", `String e.run_id;
    "addon_id", `String e.package.id; "title", `String e.package.title;
    "revision", `String e.package.revision; "phase", phase_to_json e.phase;
    "observation_seq", `Int e.seq; "rows_count", `Int (List.length e.output.rows);
    "observation_pending", `Bool e.pending; "coalesced_wakes", `Int e.coalesced_wakes;
    "binding", e.binding; "package", package_to_json e.package;
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
let failed m e message =
  if not e.stopping then e.phase <- Failed message;
  match persist m e with Ok () -> () | Error error ->
    if not e.stopping then e.phase <- Failed (message ^ "; binding persistence: " ^ error)
    else Log.Misc.error "Lane stopped binding persistence: %s" error
let fork_isolated ~sw f = Eio.Fiber.fork ~sw (fun () ->
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Log.Misc.error "Lane Add-on background boundary: %s" (Printexc.to_string exn))
let stop_entry ~sw m e =
  if not e.cleanup_running then
    match e.connection with
    | None -> () (* start's on_created callback will resume cleanup *)
    | Some c ->
        e.cleanup_running <- true;
        fork_isolated ~sw (fun () ->
          let result = try c.stop () with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn -> Error (Printexc.to_string exn) in
          e.cleanup_running <- false;
          (match result with
           | Ok () -> e.phase <- Detached; wake e;
               Option.iter (fun cancel -> cancel ()) e.cancel_worker
           | Error message -> e.phase <- Failed ("cleanup incomplete: " ^ message));
          match persist m e with Ok () -> () | Error message ->
            e.phase <- Failed ("cleanup state persistence: " ^ message))
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
          (match persist m e with Ok () -> () | Error message ->
            e.stopping <- true; e.phase <- Failed message);
          if e.stopping then stop_entry ~sw m e in
        match backend.start ~sw:worker_sw ~instance_id:e.instance_id ~package:e.package ~on_created:created with
        | Error message ->
            if e.stopping then (
              match e.connection with None -> e.phase <- Failed ("startup/cleanup: " ^ message)
              | Some _ -> stop_entry ~sw m e)
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
                    let* sources = backend.acquire ~store:m.store ~package:e.package ~binding:e.binding in
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
                       (match persist m e with Ok () -> () | Error message -> failed m e message)
                   | Error message -> failed m e message);
                  loop ()))
            in loop ());
    with
    | Worker_detached -> ()
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> failed m e (Printexc.to_string exn)
    in
    match work () with
    | () -> e.running <- false; e.cancel_worker <- None
    | exception exn -> e.running <- false; e.cancel_worker <- None; raise exn)
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
                     recovering = Hashtbl.create 4 } in
      Hashtbl.add managers root m; m
let entries m = Hashtbl.to_seq_values m.entries |> List.of_seq
  |> List.sort (fun a b -> String.compare a.instance_id b.instance_id)
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
    let* container_id = text fields "container_id" in
    let* package = match List.assoc_opt "package" fields with
      | Some json -> object_ json | None -> Error "missing persisted package" in
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
      let json = replace_phase fields phase in
      let persisted = offload (fun () -> Lane_addon_store.save_binding m.store ~instance_id:id json) in
      Hashtbl.remove m.recovering id;
      match persisted with Ok () -> () | Error message ->
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
  let past = List.map (function `Assoc fields ->
    let phase = match List.assoc_opt "phase" fields with
      | Some json -> phase_of_json json | None -> Error "missing phase" in
    let phase = match phase with
      | Ok Detached -> Detached
      | Ok (Failed message) -> Failed message
      | Ok Detaching when (match text fields "instance_id" with
          | Ok id -> Hashtbl.mem m.recovering id | Error _ -> false) -> Detaching
      | _ -> Failed "previous process; explicit detach can verify container cleanup" in
    `Assoc (("phase", phase_to_json phase) :: List.remove_assoc "phase" fields)
    | value -> value) past in
  let output = { rows = List.concat_map (fun e -> e.output.rows) live;
    coverage = List.concat_map (fun e -> status_coverage e :: e.output.coverage) live } in
  match output_to_json output with
  | `Assoc fields -> Ok (`Assoc (("instances", `List (List.map entry_json live @ past)) :: fields))
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
             let* fields = object_ frozen in let* prompt = text fields "message" in
             try handler ~config ~caller ~keeper_name ~prompt with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn -> Error (Printexc.to_string exn)
           in
           let delivery = match deliver () with
             | Ok receipt -> `Assoc ["status", `String "accepted"; "receipt", receipt]
             | Error message -> `Assoc ["status", `String "failed"; "error", `String message] in
           let* fields = object_ frozen in Ok (`Assoc (("delivery", delivery) :: fields)))
  | Attach ->
      let* path = text args "manifest_path" in let* run_id = text args "run_id" in
      let* binding = match List.assoc_opt "binding" args with Some (`Assoc _ as value) -> Ok value
        | _ -> Error "binding requires an object" in
      let* package = offload (fun () -> Lane_addon_manifest.load ~path) in
      let* () = Lane_addon_sources.validate binding in
      let* sw = match Eio_context.get_root_switch_opt () with
        | Some sw -> Ok sw | None -> Error "server background owner unavailable" in
      let promise, resolver = Eio.Promise.create () in
      let e = { instance_id = Uuidm.to_string (uuid ()); run_id; package; binding;
        phase = Attached; seq = 0; output = {rows=[];coverage=[]}; connection = None;
        stopping = false; cleanup_running = false; wake = promise; resolver; pending = false;
        running = true; persistence_mutex = Eio.Mutex.create (); coalesced_wakes = 0;
        cancel_worker = None } in
      let* () = persist m e in
      Hashtbl.add m.entries e.instance_id e;
      wake e; run ~sw (backend ()) m e;
      Ok (entry_json e)
  | Observe ->
      let* e = find m args in
      if e.stopping then Error "instance is stopping or detached"
      else if not e.running then Error "worker stopped; detach and attach again to restart"
      else (wake e; Ok (entry_json e))
  | Detach ->
      let* id = text args "instance_id" in
      let* sw = match Eio_context.get_root_switch_opt () with
        | Some sw -> Ok sw | None -> Error "server background owner unavailable" in
      (match Hashtbl.find_opt m.entries id with
       | None -> let* fields = persisted_binding m id in historical_detach ~sw m fields
       | Some e ->
           (match e.phase with Detached -> () | _ ->
             e.stopping <- true; e.phase <- Detaching; wake e; stop_entry ~sw m e;
             if not e.running && Option.is_none e.connection then
               e.phase <- Failed "startup ended without a retained container identity; cleanup is unverified");
           let* () = persist m e in Ok (entry_json e)))
module For_testing = struct
  type nonrec connection = connection
  type nonrec backend = backend
  let with_backend backend f = let previous = !override in override := Some backend;
    Fun.protect ~finally:(fun () -> override := previous) f
  let reset () = Hashtbl.clear managers; delivery_handler := None
end
