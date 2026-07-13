(** Per-keeper turn single-flight gate. See keeper_turn_admission.mli. *)

type lane =
  | Autonomous
  | Chat

type in_flight_info =
  { lane : lane
  ; started_at : float
  }

type autonomous_block =
  | Turn_busy of in_flight_info option
  | Shutdown_requested of Keeper_shutdown_types.Operation_id.t
  | Persistence_blocked of Keeper_persistence_admission.block_reason

type rejection =
  { waiting : int
  ; in_flight : in_flight_info option
  ; shutdown_operation_id : Keeper_shutdown_types.Operation_id.t option
  }

type shutdown_reservation =
  { operation_id : Keeper_shutdown_types.Operation_id.t
  ; in_flight : in_flight_info option
  ; waiting : int
  }

type begin_shutdown_result =
  | Shutdown_reserved of shutdown_reservation
  | Shutdown_already_reserved of shutdown_reservation

type rollback_shutdown_result =
  | Shutdown_rolled_back
  | Shutdown_not_reserved
  | Shutdown_reserved_by_other of Keeper_shutdown_types.Operation_id.t

type restore_shutdown_result =
  | Shutdown_restored
  | Shutdown_already_restored
  | Shutdown_restore_conflict of Keeper_shutdown_types.Operation_id.t

type 'a registration_commit_result =
  | Registration_committed of 'a
  | Registration_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type slot_snapshot =
  { snapshot_keeper_name : string
  ; snapshot_slot_created : bool
  ; snapshot_in_flight : in_flight_info option
  ; snapshot_waiting : int
  ; snapshot_waiting_since : float option
  ; snapshot_shutdown_operation_id : Keeper_shutdown_types.Operation_id.t option
  }

type fleet_snapshot =
  { fleet_keeper_count : int
  ; fleet_waiting_keeper_count : int
  ; fleet_waiting_total : int
  ; fleet_in_flight_keeper_count : int
  ; fleet_shutdown_keeper_count : int
  ; fleet_slots : slot_snapshot list
  }

let lane_to_string = function
  | Autonomous -> "autonomous"
  | Chat -> "chat"
;;

type slot =
  { base_path : string
  ; keeper_name : string
  ; turn_mu : Eio.Mutex.t
    (* Held across the whole admitted turn (possibly minutes): must be
       fiber-cooperative, hence Eio.Mutex. Manipulated with raw
       lock/try_lock/unlock — [use_rw] would poison the slot when a turn
       raises, deadlocking the keeper forever. *)
  ; state_mu : Stdlib.Mutex.t
    (* Guards [info]/[waiting]. Critical sections never yield, so the
       non-cooperative mutex is the right choice here. *)
  ; mutable info : in_flight_info option
  ; mutable waiting : int
  ; mutable waiting_entries : (int * float) list
  ; mutable next_waiter_id : int
  ; mutable shutdown_operation_id : Keeper_shutdown_types.Operation_id.t option
  }

let slots : (string, slot) Hashtbl.t = Hashtbl.create 16

(* Module-level singleton table: Stdlib.Mutex because lookup can be reached
   outside an Eio context (e.g. test setup) and the critical section never
   yields. *)
let slots_mu = Stdlib.Mutex.create ()

let slot_for ~base_path ~keeper_name =
  let base_path = Keeper_registry_types.canonical_base_path_exn base_path in
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect slots_mu (fun () ->
    match Hashtbl.find_opt slots key with
    | Some slot -> slot
    | None ->
      let slot =
        { base_path
        ; keeper_name
        ; turn_mu = Eio.Mutex.create ()
        ; state_mu = Stdlib.Mutex.create ()
        ; info = None
        ; waiting = 0
        ; waiting_entries = []
        ; next_waiter_id = 0
        ; shutdown_operation_id = None
        }
      in
      Hashtbl.add slots key slot;
      slot)
;;

let set_info slot info = Stdlib.Mutex.protect slot.state_mu (fun () -> slot.info <- info)
let peek_info slot = Stdlib.Mutex.protect slot.state_mu (fun () -> slot.info)
let peek_shutdown slot = Stdlib.Mutex.protect slot.state_mu (fun () -> slot.shutdown_operation_id)

(* Precondition: the calling fiber holds [slot.turn_mu]. There is no
   suspension point between acquiring the mutex and entering [f], so
   cancellation cannot leak the slot; the exception arm releases on every
   raise out of [f], including [Eio.Cancel.Cancelled]. *)
let run_locked slot ~lane f =
  let admission =
    Stdlib.Mutex.protect slot.state_mu (fun () ->
      match slot.shutdown_operation_id with
      | Some operation_id -> Error operation_id
      | None ->
        (* NDT-OK: admission timestamp is observability evidence only. *)
        slot.info <- Some { lane; started_at = Unix.gettimeofday () };
        Ok ())
  in
  match admission with
  | Error operation_id ->
    Eio.Mutex.unlock slot.turn_mu;
    `Shutdown_requested operation_id
  | Ok () ->
    (match f () with
     | v ->
       set_info slot None;
       Eio.Mutex.unlock slot.turn_mu;
       `Ran v
     | exception exn ->
       set_info slot None;
       Eio.Mutex.unlock slot.turn_mu;
       raise exn)
;;

let waiting_count slot = Stdlib.Mutex.protect slot.state_mu (fun () -> slot.waiting)

let oldest_waiting_since entries =
  List.fold_left
    (fun oldest (_waiter_id, since) ->
       match oldest with
       | None -> Some since
       | Some current -> Some (min current since))
    None
    entries
;;

let rejection_snapshot slot =
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    { waiting = slot.waiting
    ; in_flight = slot.info
    ; shutdown_operation_id = slot.shutdown_operation_id
    })
;;

(* Preserve the operation that actually rejected admission even if lifecycle
   rollback clears the live fence before the caller renders the result. The
   waiting/in-flight fields are still sampled together under [state_mu]. *)
let shutdown_rejection_snapshot slot operation_id =
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    { waiting = slot.waiting
    ; in_flight = slot.info
    ; shutdown_operation_id = Some operation_id
    })
;;

let run_if_free ~base_path ~keeper_name f =
  let slot = slot_for ~base_path ~keeper_name in
  (* Yield to deferred work before touching the lock. [waiting > 0] implies
     the slot is held (a waiter only parks because a turn is in flight), so
     [try_lock] would fail here anyway; the explicit check keeps the
     autonomous lane from competing for a slot a parked chat is already
     queued on. A non-empty [Keeper_chat_queue] means a busy connector
     (Slack/Discord) or dashboard message is deferred for this keeper but
     has not parked on the slot; the autonomous lane must yield for it too,
     otherwise a long or back-to-back autonomous turn starves that queue
     indefinitely (the busy-ACK loop). Reading the queue length is a
     lock-only, non-suspending peek and is the SSOT signal that closes the
     gap: the autonomous lane cooperates on the same backlog the consumer
     drains, so the consumer's [in_flight = None] window opens
     deterministically instead of racing the next autonomous cycle. A leased
     receipt remains active until its terminal decision commits, so the
     autonomous lane must also yield during the short lease-to-admission and
     admission-to-finalization windows. *)
  match Keeper_persistence_admission.block_reason ~base_path ~keeper_name with
  | Some reason -> `Busy (Persistence_blocked reason)
  | None ->
  match peek_shutdown slot with
  | Some operation_id -> `Busy (Shutdown_requested operation_id)
  | None when waiting_count slot > 0 -> `Busy (Turn_busy (peek_info slot))
  | None ->
    let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
    (* Queue persistence/read failures remain typed Chat-boundary failures.
       They are not evidence of queued work and therefore cannot close an
       otherwise independent autonomous lane. *)
    if snapshot.pending <> [] || snapshot.inflight <> []
    then `Busy (Turn_busy (peek_info slot))
    else if Eio.Mutex.try_lock slot.turn_mu
    then
      match run_locked slot ~lane:Autonomous f with
      | `Ran value -> `Ran value
      | `Shutdown_requested operation_id -> `Busy (Shutdown_requested operation_id)
    else `Busy (Turn_busy (peek_info slot))
;;

let run_serialized ~base_path ~keeper_name f =
  let slot = slot_for ~base_path ~keeper_name in
  let waiter_id =
    Stdlib.Mutex.protect slot.state_mu (fun () ->
      match slot.shutdown_operation_id with
      | Some operation_id -> `Shutdown_requested operation_id
      | None ->
        let waiter_id = slot.next_waiter_id in
        slot.next_waiter_id <- slot.next_waiter_id + 1;
        (* NDT-OK: waiter age timestamp for observability only. *)
        slot.waiting_entries <- (waiter_id, Unix.gettimeofday ()) :: slot.waiting_entries;
        slot.waiting <- slot.waiting + 1;
        `Waiting waiter_id)
  in
  match waiter_id with
  | `Shutdown_requested operation_id ->
    `Rejected (shutdown_rejection_snapshot slot operation_id)
  | `Waiting waiter_id ->
    (* [Fun.protect] rather than [Switch.on_release]: there is no ambient
       switch here, the finally never raises and never yields, and the only
       suspension point it covers is the cancellable [Eio.Mutex.lock] wait
       itself — a cancelled waiter leaves the queue, a successful one stops
       counting as waiting once it holds the slot. *)
    Fun.protect
      ~finally:(fun () ->
        Stdlib.Mutex.protect slot.state_mu (fun () ->
          slot.waiting <- max 0 (slot.waiting - 1);
          slot.waiting_entries
          <- List.filter
               (fun (entry_waiter_id, _since) -> entry_waiter_id <> waiter_id)
               slot.waiting_entries))
      (fun () -> Eio.Mutex.lock slot.turn_mu);
    (match run_locked slot ~lane:Chat f with
     | `Ran value -> `Ran value
     | `Shutdown_requested operation_id ->
       `Rejected (shutdown_rejection_snapshot slot operation_id))
;;

let run_chat_if_free ~base_path ~keeper_name f =
  let slot = slot_for ~base_path ~keeper_name in
  match peek_shutdown slot with
  | Some operation_id ->
    `Busy (shutdown_rejection_snapshot slot operation_id)
  | None when waiting_count slot > 0 -> `Busy (rejection_snapshot slot)
  | None when Eio.Mutex.try_lock slot.turn_mu ->
    let active_receipts =
      try Keeper_chat_queue.has_active_receipts ~keeper_name with
      | exn ->
        Eio.Mutex.unlock slot.turn_mu;
        raise exn
    in
    (* The outer route's queue peek is only a fast path. Recheck after the
       turn slot is acquired so a receipt committed or leased between that
       peek and admission cannot be overtaken. The queue entry lock makes a
       commit already in progress finish before this read returns; a commit
       that starts after the read is ordered after this admitted turn. The
       waiter recheck closes the equivalent increment-before-lock window for
       [run_serialized]. Queue read errors fail closed and are surfaced by the
       caller's durable-enqueue path. *)
    if waiting_count slot > 0
       || match active_receipts with Ok active -> active | Error _ -> true
    then (
      let rejection = rejection_snapshot slot in
      Eio.Mutex.unlock slot.turn_mu;
      `Busy rejection)
    else
      (match run_locked slot ~lane:Chat f with
       | `Ran value -> `Ran value
       | `Shutdown_requested operation_id ->
         `Busy (shutdown_rejection_snapshot slot operation_id))
  | None -> `Busy (rejection_snapshot slot)
;;

let in_flight ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key) with
  | None -> None
  | Some slot -> peek_info slot
;;

let reservation_of_slot slot operation_id =
  { operation_id; in_flight = slot.info; waiting = slot.waiting }
;;

let begin_shutdown ~base_path ~keeper_name ~operation_id =
  let slot = slot_for ~base_path ~keeper_name in
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    match slot.shutdown_operation_id with
    | None ->
      slot.shutdown_operation_id <- Some operation_id;
      Shutdown_reserved (reservation_of_slot slot operation_id)
    | Some existing ->
      Shutdown_already_reserved (reservation_of_slot slot existing))
;;

let rollback_shutdown ~base_path ~keeper_name ~operation_id =
  let slot = slot_for ~base_path ~keeper_name in
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    match slot.shutdown_operation_id with
    | None -> Shutdown_not_reserved
    | Some existing when Keeper_shutdown_types.Operation_id.equal existing operation_id ->
      slot.shutdown_operation_id <- None;
      Shutdown_rolled_back
    | Some existing -> Shutdown_reserved_by_other existing)
;;

let restore_shutdown ~base_path ~keeper_name ~operation_id =
  let slot = slot_for ~base_path ~keeper_name in
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    match slot.shutdown_operation_id with
    | None ->
      slot.shutdown_operation_id <- Some operation_id;
      Shutdown_restored
    | Some existing when Keeper_shutdown_types.Operation_id.equal existing operation_id ->
      Shutdown_already_restored
    | Some existing -> Shutdown_restore_conflict existing)
;;

let commit_registration_if_open ~base_path ~keeper_name commit =
  let slot = slot_for ~base_path ~keeper_name in
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    match slot.shutdown_operation_id with
    | Some operation_id -> Registration_shutdown_reserved operation_id
    | None -> Registration_committed (commit ()))
;;

let await_idle_after_shutdown ~base_path ~keeper_name =
  let slot = slot_for ~base_path ~keeper_name in
  Eio.Mutex.lock slot.turn_mu;
  Eio.Mutex.unlock slot.turn_mu
;;

let chat_waiting ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key) with
  | None -> false (* no slot yet ⇒ no turn ran ⇒ no chat can be waiting *)
  | Some slot -> waiting_count slot > 0
;;

let chat_waiting_since ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key) with
  | None -> None
  | Some slot ->
    Stdlib.Mutex.protect slot.state_mu (fun () ->
      oldest_waiting_since slot.waiting_entries)
;;

let zero_snapshot ~keeper_name =
  { snapshot_keeper_name = keeper_name
  ; snapshot_slot_created = false
  ; snapshot_in_flight = None
  ; snapshot_waiting = 0
  ; snapshot_waiting_since = None
  ; snapshot_shutdown_operation_id = None
  }
;;

let snapshot_of_slot slot =
  Stdlib.Mutex.protect slot.state_mu (fun () ->
    { snapshot_keeper_name = slot.keeper_name
    ; snapshot_slot_created = true
    ; snapshot_in_flight = slot.info
    ; snapshot_waiting = slot.waiting
    ; snapshot_waiting_since = oldest_waiting_since slot.waiting_entries
    ; snapshot_shutdown_operation_id = slot.shutdown_operation_id
    })
;;

let snapshot_for ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key) with
  | None -> zero_snapshot ~keeper_name
  | Some slot -> snapshot_of_slot slot
;;

let live_keeper_names ~base_path =
  let base_path = Keeper_registry_types.canonical_base_path_exn base_path in
  Stdlib.Mutex.protect slots_mu (fun () ->
    Hashtbl.fold
      (fun _key slot acc ->
        if String.equal slot.base_path base_path then slot.keeper_name :: acc else acc)
      slots
      [])
;;

let fleet_snapshot ~base_path ~keeper_names =
  let keeper_names =
    List.sort_uniq String.compare (keeper_names @ live_keeper_names ~base_path)
  in
  let fleet_slots =
    List.map (fun keeper_name -> snapshot_for ~base_path ~keeper_name) keeper_names
  in
  let fleet_waiting_keeper_count =
    List.fold_left
      (fun acc slot -> if slot.snapshot_waiting > 0 then acc + 1 else acc)
      0
      fleet_slots
  in
  let fleet_waiting_total =
    List.fold_left
      (fun acc slot -> acc + slot.snapshot_waiting)
      0
      fleet_slots
  in
  let fleet_in_flight_keeper_count =
    List.fold_left
      (fun acc slot ->
        match slot.snapshot_in_flight with
        | Some _ -> acc + 1
        | None -> acc)
      0
      fleet_slots
  in
  let fleet_shutdown_keeper_count =
    List.fold_left
      (fun acc slot ->
        match slot.snapshot_shutdown_operation_id with
        | Some _ -> acc + 1
        | None -> acc)
      0
      fleet_slots
  in
  { fleet_keeper_count = List.length keeper_names
  ; fleet_waiting_keeper_count
  ; fleet_waiting_total
  ; fleet_in_flight_keeper_count
  ; fleet_shutdown_keeper_count
  ; fleet_slots
  }
;;

let in_flight_to_yojson = function
  | None -> `Null
  | Some { lane; started_at } ->
    `Assoc
      [ "lane", `String (lane_to_string lane)
      ; "started_at_unix", `Float started_at
      ]
;;

let slot_snapshot_to_yojson slot =
  `Assoc
    [ "keeper_name", `String slot.snapshot_keeper_name
    ; "slot_created", `Bool slot.snapshot_slot_created
    ; "in_flight", in_flight_to_yojson slot.snapshot_in_flight
    ; "chat_waiting_count", `Int slot.snapshot_waiting
    ; ( "shutdown_operation_id"
      , match slot.snapshot_shutdown_operation_id with
        | None -> `Null
        | Some operation_id ->
          `String (Keeper_shutdown_types.Operation_id.to_string operation_id) )
    ]
;;

let fleet_health_json ~base_path ~keeper_names =
  let snapshot = fleet_snapshot ~base_path ~keeper_names in
  `Assoc
    [ "schema", `String "masc.keeper_turn_admission.v1"
    ; "status", `String "ok"
    ; "operator_action_required", `Bool false
    ; "status_reasons", `List []
    ; "keeper_count", `Int snapshot.fleet_keeper_count
    ; ( "keeper_names"
      , `List
          (List.map
             (fun slot -> `String slot.snapshot_keeper_name)
             snapshot.fleet_slots) )
    ; "chat_waiting_keeper_count", `Int snapshot.fleet_waiting_keeper_count
    ; "chat_waiting_total_count", `Int snapshot.fleet_waiting_total
    ; "in_flight_keeper_count", `Int snapshot.fleet_in_flight_keeper_count
    ; "shutdown_keeper_count", `Int snapshot.fleet_shutdown_keeper_count
    ; "keepers", `List (List.map slot_snapshot_to_yojson snapshot.fleet_slots)
    ]
;;

module For_testing = struct
  let reset () = Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.reset slots)

  let with_unpublished_turn_lock ~base_path ~keeper_name f =
    let slot = slot_for ~base_path ~keeper_name in
    Eio.Mutex.lock slot.turn_mu;
    (* fun-protect-finally-ok: Eio.Mutex.unlock is non-suspending; this helper
       acquired the raw test-only lock immediately above and the finalizer
       releases exactly that lock on normal return, exception, or cancellation. *)
    Fun.protect ~finally:(fun () -> Eio.Mutex.unlock slot.turn_mu) f
  ;;

  let peek ~base_path ~keeper_name =
    let key = Keeper_registry_types.registry_key ~base_path keeper_name in
    Stdlib.Mutex.protect slots_mu (fun () -> Hashtbl.find_opt slots key)
    |> Option.map (fun slot ->
      Stdlib.Mutex.protect slot.state_mu (fun () -> slot.info, slot.waiting))
  ;;
end
