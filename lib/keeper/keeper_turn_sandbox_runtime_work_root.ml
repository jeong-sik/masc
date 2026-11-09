(* Guests whose keeper root on the work volume this server process has made.
   Names have a shortened workspace hash and are shared across backend stores,
   so readiness also carries the full normalized base and selected backend.
   The volume outlives the guest, so the [mkdir] is paid once per guest per
   process, at boot. A guest whose boot could not make the root and could
   not be taken down either is still running and still registered, so the
   next start adopts it: its readiness stays false, and the endpoint request
   makes the root before handing the guest out rather than handing out a
   guest every call fails in. *)
type microvm_work_root_key = string * Keeper_microvm_backend.t * string

let microvm_work_root_key ~base_path ~backend ~container_name : microvm_work_root_key =
  Keeper_sandbox_runtime_setup.normalize_base_path_for_hash base_path, backend, container_name
;;

type microvm_build_links_state =
  | Build_links_not_prepared
  | Build_links_effect_unverified
  | Build_links_prepared

type microvm_build_cleanup_state =
  | Build_cleanup_available
  | Build_cleanup_skipped_not_sent
  | Build_cleanup_effect_unverified
  | Build_cleanup_confirmed
  | Build_cleanup_finished_incomplete

let microvm_build_cleanup_outcome outcome receipt =
  match outcome, receipt with
  | Masc_exec.Sandbox_target.Ran {status; _},
    Some (Keeper_sandbox_remote.Execution_observed (_, trailer)) ->
    (match status, trailer.exit, trailer.signal, trailer.timed_out, trailer.shim_error with
     | Unix.WEXITED code, Some actual, None, false, None when code = actual ->
       if code = 0 then Build_cleanup_confirmed else Build_cleanup_finished_incomplete
     | Unix.WSIGNALED signal, None, Some actual, false, None when signal = actual ->
       Build_cleanup_finished_incomplete
     | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _, _, _ ->
       Build_cleanup_effect_unverified)
  | Masc_exec.Sandbox_target.Transport_failed {failure=Payload_timed_out; _},
    Some (Keeper_sandbox_remote.Execution_observed (_, {timed_out=true; _})) ->
    Build_cleanup_finished_incomplete
  | Masc_exec.Sandbox_target.Transport_failed {failure=Lane_unavailable; _},
    Some (Keeper_sandbox_remote.Execution_observed (receipt, trailer)) ->
    (match receipt.boundary, trailer.exit, trailer.signal, trailer.timed_out, trailer.shim_error with
     | Refused, None, None, false, Some _ -> Build_cleanup_finished_incomplete
     | (Sandbox_applied | Setup_failed | Exec_failed | Child_ack_unavailable
       | Refused | Refused_socket | Refused_write), _, _, _, _ -> Build_cleanup_effect_unverified)
  | Masc_exec.Sandbox_target.Transport_failed {failure=(Payload_timed_out | Lane_unavailable); _},
    Some (Keeper_sandbox_remote.Execution_unavailable Keeper_sandbox_remote.Request_not_sent) ->
    Build_cleanup_skipped_not_sent
  | Masc_exec.Sandbox_target.Transport_failed {failure=(Payload_timed_out | Lane_unavailable); _},
    (Some (Keeper_sandbox_remote.Execution_observed _
       | Keeper_sandbox_remote.Execution_unavailable
           (Keeper_sandbox_remote.Transport_unavailable _
           | Keeper_sandbox_remote.Peer_receipt_missing
           | Keeper_sandbox_remote.Invalid_receipt _
           | Keeper_sandbox_remote.Shim_refused_without_receipt)) | None)
  | Masc_exec.Sandbox_target.Ran _,
    (Some (Keeper_sandbox_remote.Execution_unavailable _) | None)
    -> Build_cleanup_effect_unverified
;;

(* Work/build volume names are Keeper-scoped, not workspace/guest-scoped.
   Group effects by that same nominal backend resource. This is not proof of
   a physical mount identity or authority over another server's guest. *)
type microvm_maintenance_attempt =
  { operation_id : string
  ; container_name : string
  ; observation : Keeper_sandbox_remote.execution_observation option
  }

type microvm_maintenance_state =
  | Maintenance_idle
  | Maintenance_unverified of microvm_maintenance_attempt

type microvm_work_effects =
  { resource : Keeper_microvm_backend.t * string
  ; cleanup_state : microvm_build_cleanup_state
  ; links_unverified : bool
  ; maintenance : microvm_maintenance_state
  }

let microvm_work_effects : microvm_work_effects list Atomic.t = Atomic.make []

let rec register_microvm_work_effects ~backend ~keeper_name =
  let resource = backend, keeper_name in
  let current = Atomic.get microvm_work_effects in
  match List.find_opt (fun entry -> entry.resource = resource) current with
  | Some entry -> entry
  | None ->
    let entry = {resource; cleanup_state=Build_cleanup_available; links_unverified=false;
      maintenance=Maintenance_idle} in
    if Atomic.compare_and_set microvm_work_effects current (entry :: current) then entry
    else register_microvm_work_effects ~backend ~keeper_name
;;

let rec update_microvm_work_effects ~backend ~keeper_name update =
  let entry = register_microvm_work_effects ~backend ~keeper_name in
  let current = Atomic.get microvm_work_effects in
  match List.find_opt (fun candidate -> candidate.resource = entry.resource) current with
  | None -> update_microvm_work_effects ~backend ~keeper_name update
  | Some entry ->
    match update entry with
    | None -> false
    | Some replacement ->
    let updated = List.map (fun candidate ->
      if candidate == entry then replacement else candidate) current in
    if Atomic.compare_and_set microvm_work_effects current updated then true
    else update_microvm_work_effects ~backend ~keeper_name update
;;

let set_microvm_build_cleanup_state ~backend ~keeper_name ~expected state =
  update_microvm_work_effects ~backend ~keeper_name (fun entry ->
    if entry.cleanup_state = expected then Some {entry with cleanup_state=state} else None)
;;

let microvm_build_cleanup_unresolved_message ~keeper_name =
  Printf.sprintf
    "microvm_build_cleanup_effect_unverified: keeper %s has an unresolved cleanup on its shared work volume; it may still rename build output, so a new execution handoff is unavailable; inspect the original command outcome before recovery"
    keeper_name
;;

let microvm_build_cleanup_admission ~backend ~keeper_name =
  let effects = register_microvm_work_effects ~backend ~keeper_name in
  match effects.maintenance with
  | Maintenance_unverified attempt ->
    Error (Printf.sprintf
      "microvm_build_maintenance_effect_unverified: keeper %s has unresolved maintenance %s on guest %s; inspect its audit receipts before a new mutation handoff"
      keeper_name attempt.operation_id attempt.container_name)
  | Maintenance_idle ->
  match effects.cleanup_state with
  | Build_cleanup_effect_unverified ->
    Error (microvm_build_cleanup_unresolved_message ~keeper_name)
  | Build_cleanup_available | Build_cleanup_skipped_not_sent
  | Build_cleanup_confirmed | Build_cleanup_finished_incomplete -> Ok ()
;;

let microvm_build_link_effect_admission ~backend ~keeper_name =
  if (register_microvm_work_effects ~backend ~keeper_name).links_unverified then
    Error (Printf.sprintf
      "microvm_build_link_effect_unverified: keeper %s has an unresolved symlink application; a read-only scan does not prove it stopped, so a new execution handoff is unavailable"
      keeper_name)
  else Ok ()
;;

let reserve_microvm_maintenance ~backend ~keeper_name attempt =
  update_microvm_work_effects ~backend ~keeper_name (fun effects ->
    match effects.maintenance with
    | Maintenance_idle -> Some {effects with maintenance=Maintenance_unverified attempt}
    | Maintenance_unverified _ -> None)
;;

let settle_microvm_maintenance ~backend ~keeper_name ~operation_id ~observation ~resolved =
  update_microvm_work_effects ~backend ~keeper_name (fun effects ->
    match effects.maintenance with
    | Maintenance_unverified attempt when String.equal attempt.operation_id operation_id ->
      let maintenance = if resolved then Maintenance_idle
        else Maintenance_unverified {attempt with observation} in
      Some {effects with maintenance}
    | Maintenance_idle | Maintenance_unverified _ -> None)
;;

type microvm_work_root_ready =
  { key : microvm_work_root_key
  ; generation : unit ref
  ; root_ready : bool
  ; build_links_state : microvm_build_links_state
  }

(* Readiness can be invalidated without erasing attempted effects on the
   persistent work volume. A fresh generation rejects an older completion;
   neither a guest name nor its absence proves that an effect was not sent.
   These records belong to this server process, not to a durable journal. *)
let microvm_work_roots_ready : microvm_work_root_ready list Atomic.t = Atomic.make []

let microvm_work_root_entry ~base_path ~backend ~container_name =
  let key = microvm_work_root_key ~base_path ~backend ~container_name in
  Atomic.get microvm_work_roots_ready
  |> List.find_opt (fun entry -> entry.key = key)
;;

let microvm_work_root_ready ~base_path ~backend ~container_name =
  match microvm_work_root_entry ~base_path ~backend ~container_name with
  | Some entry -> entry.root_ready
  | None -> false
;;

let rec register_microvm_work_root ~base_path ~backend ~container_name =
  let key = microvm_work_root_key ~base_path ~backend ~container_name in
  let current = Atomic.get microvm_work_roots_ready in
  match List.find_opt (fun entry -> entry.key = key) current with
  | Some entry -> entry
  | None ->
    let entry = { key; generation = ref (); root_ready = false;
      build_links_state = Build_links_not_prepared } in
    if Atomic.compare_and_set microvm_work_roots_ready current (entry :: current)
    then entry
    else register_microvm_work_root ~base_path ~backend ~container_name
;;

let rec complete_microvm_work_root ~base_path ~backend ~container_name generation =
  let key = microvm_work_root_key ~base_path ~backend ~container_name in
  let current = Atomic.get microvm_work_roots_ready in
  match List.find_opt (fun entry -> entry.key = key) current with
  | Some entry when entry.generation == generation ->
    let updated = List.map (fun candidate ->
      if candidate == entry then { candidate with root_ready = true } else candidate) current in
    if Atomic.compare_and_set microvm_work_roots_ready current updated then true
    else complete_microvm_work_root ~base_path ~backend ~container_name generation
  | Some _ | None -> false
;;

let mark_microvm_work_root_ready ~base_path ~backend ~container_name =
  let entry = register_microvm_work_root ~base_path ~backend ~container_name in
  ignore (complete_microvm_work_root ~base_path ~backend ~container_name entry.generation)
;;

let rec set_microvm_build_links_state ~base_path ~backend ~container_name generation ~expected state =
  let key = microvm_work_root_key ~base_path ~backend ~container_name in
  let current = Atomic.get microvm_work_roots_ready in
  match List.find_opt (fun entry -> entry.key = key) current with
  | Some entry when entry.root_ready && entry.generation == generation && entry.build_links_state = expected ->
    let updated = List.map (fun candidate ->
      if candidate == entry then { candidate with build_links_state = state } else candidate) current in
    if not (Atomic.compare_and_set microvm_work_roots_ready current updated)
    then set_microvm_build_links_state ~base_path ~backend ~container_name generation ~expected state
    else true
  | Some _ | None -> false
;;

let microvm_build_links_admission ~base_path ~backend ~keeper_name ~container_name =
  let open Result.Syntax in
  let* () = microvm_build_link_effect_admission ~backend ~keeper_name in
  match microvm_work_root_entry ~base_path ~backend ~container_name with
  | Some {root_ready=true; build_links_state=Build_links_prepared; _} -> Ok ()
  | Some {build_links_state=(Build_links_not_prepared | Build_links_effect_unverified | Build_links_prepared); _}
  | None ->
    Error "microvm_build_preparation_unverified: the current guest link scan and target preparation are incomplete; execution handoff is unavailable"
;;

let rec forget_microvm_work_root ~backend ~container_name =
  let current = Atomic.get microvm_work_roots_ready in
  let updated = List.map (fun entry ->
    let _, other_backend, other_name = entry.key in
    if backend = other_backend && String.equal container_name other_name then
      (* The disposable build disk can now be empty. Persistent link attempts
         live in [microvm_work_effects]; target mkdir is idempotent and must
         be prepared again from the current read-only scan. *)
      { entry with root_ready = false; generation = ref ();
        build_links_state = Build_links_not_prepared }
    else entry) current in
  if not (Atomic.compare_and_set microvm_work_roots_ready current updated)
  then forget_microvm_work_root ~backend ~container_name
;;
