module Exact_output = Agent_sdk.Exact_output
module Evidence_journal = Keeper_exact_flow_evidence_journal

type surface =
  | Compaction
  | Board_attention
  | Hitl_summary
  | Librarian

type evidence_commit_error = Evidence_journal.commit_error

type measurement_commit_stage =
  | Before_measurement_dispatch
  | Measurement_terminal

type measurement_provenance =
  { operation_id : string
  ; flow_id : string
  ; visit_ordinal : int
  ; candidate_id : string
  ; candidate_binding_sha256 : string
  ; request_body_sha256 : string
  }

type measurement_commit_error =
  { stage : measurement_commit_stage
  ; provenance : measurement_provenance
  ; cause : evidence_commit_error
  }

type setup_error =
  | Owner_not_registered of { keeper_name : string }
  | Owner_draining of { keeper_name : string }
  | Evidence_recovery_blocked of
      { surface : surface
      ; cause : Evidence_journal.load_error
      }
  | Scope_identity_invalid of { surface : surface }

type release_error =
  | Retirement_deferred
  | Retirement_commit_failed of
      { surface : surface
      ; cause : evidence_commit_error
      }
  | Retirement_in_progress of { surface : surface }
  | Retirement_conflict of { surface : surface }

type librarian_execution_slot =
  { mutable capacity : int
  ; mutable in_use : int
  }

type owner_phase =
  | Active
  | Draining
  | Retired

type owner_state =
  { base_path : string
  ; keeper_name : string
  ; lane_id : Keeper_lane.Id.t
  ; phase : owner_phase Atomic.t
  ; boundary_mu : Stdlib.Mutex.t
  ; mutable boundary_users : int
  ; mutable deferred_release : (unit -> unit) option
  ; librarian_execution_slot : librarian_execution_slot
  ; librarian_execution_slot_mu : Eio.Mutex.t
  }

type t =
  { owner : owner_state
  ; surface : surface
  ; evidence_journal : Evidence_journal.t
  ; preference_store : Exact_output.flow_preference_store
  ; scope : Exact_output.flow_scope
  }

type 'a current_boundary =
  | Current of 'a
  | Owner_unregistered_deferred

type retirement_boundary =
  | Retirement_draining
  | Retirement_not_allocated
  | Retirement_owner_replaced

type owner =
  { state : owner_state
  ; compaction : t
  ; board_attention : t
  ; hitl_summary : t
  ; librarian : t
  }

let ( let* ) = Result.bind

let surface_label = function
  | Compaction -> "compaction"
  | Board_attention -> "board_attention"
  | Hitl_summary -> "hitl_summary"
  | Librarian -> "librarian"
;;

let setup_error_to_string = function
  | Owner_not_registered { keeper_name } ->
    Printf.sprintf "exact-flow owner is not registered: keeper=%s" keeper_name
  | Owner_draining { keeper_name } ->
    Printf.sprintf "exact-flow owner is draining: keeper=%s" keeper_name
  | Evidence_recovery_blocked { surface; cause } ->
    Printf.sprintf
      "exact-flow evidence recovery blocked: surface=%s cause=%s"
      (surface_label surface)
      (Evidence_journal.load_error_to_string cause)
  | Scope_identity_invalid { surface } ->
    Printf.sprintf "exact-flow scope identity is invalid: surface=%s" (surface_label surface)
;;

let evidence_commit_error_to_string = Evidence_journal.commit_error_to_string

let measurement_commit_error_to_string error =
  let stage =
    match error.stage with
    | Before_measurement_dispatch -> "before_measurement_dispatch"
    | Measurement_terminal -> "measurement_terminal"
  in
  Printf.sprintf
    "measurement evidence commit failed stage=%s operation=%s flow=%s visit=%d candidate=%s cause=%s"
    stage
    error.provenance.operation_id
    error.provenance.flow_id
    error.provenance.visit_ordinal
    error.provenance.candidate_id
    (evidence_commit_error_to_string error.cause)
;;

let release_error_to_string = function
  | Retirement_deferred -> "exact-flow retirement is waiting for bound work"
  | Retirement_commit_failed { surface; cause } ->
    Printf.sprintf
      "exact-flow retirement commit failed: surface=%s cause=%s"
      (surface_label surface)
      (evidence_commit_error_to_string cause)
  | Retirement_in_progress { surface } ->
    Printf.sprintf
      "exact-flow retirement is already in progress: surface=%s"
      (surface_label surface)
  | Retirement_conflict { surface } ->
    Printf.sprintf
      "exact-flow retirement conflicted: surface=%s"
      (surface_label surface)
;;

let owners : (string, owner) Hashtbl.t = Hashtbl.create 16
let owners_mu = Stdlib.Mutex.create ()

let owner_key ~base_path ~keeper_name =
  Keeper_registry_types.registry_key ~base_path keeper_name
;;

let owner_fingerprint state surface =
  String.concat
    "\000"
    [ state.base_path
    ; state.keeper_name
    ; Keeper_lane.Id.to_string state.lane_id
    ; surface_label surface
    ]
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let create_scope state surface =
  let* evidence_journal, preference_store, recovery_origin =
    Evidence_journal.recover
      ~base_path:state.base_path
      ~keeper_name:state.keeper_name
      ~keeper_generation:(Keeper_lane.Id.to_string state.lane_id)
      ~surface:(surface_label surface)
      ~concurrent_scope_budget:1
    |> Result.map_error (fun cause -> Evidence_recovery_blocked { surface; cause })
  in
  (match recovery_origin with
   | Evidence_journal.Fresh_start ->
     Log.Keeper.warn
       "exact-flow current evidence was absent; initialized explicit fresh state keeper=%s generation=%s surface=%s journal=%s"
       state.keeper_name
       (Keeper_lane.Id.to_string state.lane_id)
       (surface_label surface)
       (Evidence_journal.path evidence_journal)
   | Evidence_journal.Recovered { evidence_count } ->
     Log.Keeper.info
       "exact-flow recovered authenticated current evidence keeper=%s generation=%s surface=%s evidence_count=%d journal=%s"
       state.keeper_name
       (Keeper_lane.Id.to_string state.lane_id)
       (surface_label surface)
       evidence_count
       (Evidence_journal.path evidence_journal));
  let* scope =
    Exact_output.make_flow_scope ~id:("masc:" ^ owner_fingerprint state surface)
    |> Result.map_error (fun Exact_output.Blank_flow_scope_id ->
      Scope_identity_invalid { surface })
  in
  Ok { owner = state; surface; evidence_journal; preference_store; scope }
;;

let create_owner ~base_path ~keeper_name ~lane_id =
  let state =
    { base_path
    ; keeper_name
    ; lane_id
    ; phase = Atomic.make Active
    ; boundary_mu = Stdlib.Mutex.create ()
    ; boundary_users = 0
    ; deferred_release = None
    ; librarian_execution_slot = { capacity = 0; in_use = 0 }
    ; librarian_execution_slot_mu = Eio.Mutex.create ()
    }
  in
  let* compaction = create_scope state Compaction in
  let* board_attention = create_scope state Board_attention in
  let* hitl_summary = create_scope state Hitl_summary in
  let* librarian = create_scope state Librarian in
  Ok { state; compaction; board_attention; hitl_summary; librarian }
;;

let surface_scope owner = function
  | Compaction -> owner.compaction
  | Board_attention -> owner.board_attention
  | Hitl_summary -> owner.hitl_summary
  | Librarian -> owner.librarian
;;

let commit_domain_settlement_intent scope intent =
  match Evidence_journal.commit_domain_settlement scope.evidence_journal intent with
  | Ok () -> Ok ()
  | Error cause as error ->
    Log.Keeper.error
      "exact-flow domain evidence commit blocked keeper=%s generation=%s surface=%s cause=%s"
      scope.owner.keeper_name
      (Keeper_lane.Id.to_string scope.owner.lane_id)
      (surface_label scope.surface)
      (evidence_commit_error_to_string cause);
    error
;;

let measurement_provenance snapshot =
  { operation_id =
      snapshot
      |> Exact_output.measurement_receipt_operation_id
      |> Exact_output.measurement_operation_id_to_string
  ; flow_id =
      snapshot
      |> Exact_output.measurement_receipt_flow_id
      |> Exact_output.flow_id_to_string
  ; visit_ordinal =
      snapshot
      |> Exact_output.measurement_receipt_visit_ordinal
      |> Exact_output.flow_visit_ordinal_to_int
  ; candidate_id = Exact_output.measurement_receipt_candidate_id snapshot
  ; candidate_binding_sha256 =
      Exact_output.measurement_receipt_candidate_binding_sha256 snapshot
  ; request_body_sha256 =
      Exact_output.measurement_receipt_request_body_sha256 snapshot
  }
;;

let commit_measurement stage commit scope receipt =
  let snapshot = Exact_output.flow_measurement_receipt_snapshot receipt in
  let provenance = measurement_provenance snapshot in
  match commit scope.evidence_journal snapshot with
  | Ok () -> Ok ()
  | Error cause ->
    let error = { stage; provenance; cause } in
    Log.Keeper.error
      "exact-flow measurement evidence commit blocked keeper=%s generation=%s surface=%s cause=%s"
      scope.owner.keeper_name
      (Keeper_lane.Id.to_string scope.owner.lane_id)
      (surface_label scope.surface)
      (measurement_commit_error_to_string error);
    Error error
;;

let commit_measurement_dispatch_intent scope receipt =
  commit_measurement
    Before_measurement_dispatch
    Evidence_journal.commit_measurement_dispatch_intent
    scope
    receipt
;;

let commit_measurement_terminal scope receipt =
  commit_measurement
    Measurement_terminal
    Evidence_journal.commit_measurement_terminal
    scope
    receipt
;;

let release_scope scope =
  match
    Exact_output.commit_and_retire_flow_preference_scope
      ~commit:(Evidence_journal.commit_scope_retirement scope.evidence_journal)
      scope.preference_store
      scope.scope
  with
  | Ok _ | Error Exact_output.Flow_preference_scope_not_reserved -> Ok ()
  | Error (Exact_output.Flow_preference_retirement_commit_failed cause) ->
    Error (Retirement_commit_failed { surface = scope.surface; cause })
  | Error Exact_output.Flow_preference_retirement_in_progress ->
    Error (Retirement_in_progress { surface = scope.surface })
  | Error Exact_output.Flow_preference_retirement_conflict ->
    Error (Retirement_conflict { surface = scope.surface })
;;

let release_owner_scopes owner =
  let* () = release_scope owner.compaction in
  let* () = release_scope owner.board_attention in
  let* () = release_scope owner.hitl_summary in
  release_scope owner.librarian
;;

let remove_owner_binding owner =
  let key =
    owner_key
      ~base_path:owner.state.base_path
      ~keeper_name:owner.state.keeper_name
  in
  Stdlib.Mutex.protect owners_mu (fun () ->
    match Hashtbl.find_opt owners key with
    | Some current when current == owner -> Hashtbl.remove owners key
    | Some _ | None -> ())
;;

let finish_owner_retirement owner =
  match release_owner_scopes owner with
  | Ok () ->
    Stdlib.Mutex.protect owner.state.boundary_mu (fun () ->
      Atomic.set owner.state.phase Retired);
    remove_owner_binding owner;
    Ok ()
  | Error cause as error ->
    Log.Keeper.error
      "exact-flow owner retirement blocked keeper=%s generation=%s cause=%s"
      owner.state.keeper_name
      (Keeper_lane.Id.to_string owner.state.lane_id)
      (release_error_to_string cause);
    error
;;

let retire_owner owner =
  let action =
    Stdlib.Mutex.protect owner.state.boundary_mu (fun () ->
      match Atomic.get owner.state.phase with
      | Retired -> `Released
      | Active
      | Draining ->
        Atomic.set owner.state.phase Draining;
        if owner.state.boundary_users = 0
        then `Release_now
        else (
          if Option.is_none owner.state.deferred_release
          then
            owner.state.deferred_release <-
              Some (fun () -> ignore (finish_owner_retirement owner));
          `Deferred))
  in
  match action with
  | `Released -> Ok `Released
  | `Deferred -> Ok `Deferred
  | `Release_now -> Result.map (fun () -> `Released) (finish_owner_retirement owner)
;;

let note_retirement_result = function
  | Ok _ -> ()
  | Error cause ->
    Log.Keeper.error
      "exact-flow detached owner remains blocked: %s"
      (release_error_to_string cause)
;;

let for_registered ~registered_lane_id ~base_path ~keeper_name ~surface =
  let key = owner_key ~base_path ~keeper_name in
  let unavailable () = Owner_not_registered { keeper_name } in
  let draining () = Owner_draining { keeper_name } in
  let initial =
    Keeper_lifecycle_reservation.with_key_lock
      ~base_path
      ~keeper_name
      (fun () ->
         match registered_lane_id () with
         | None -> `Error (unavailable ())
         | Some lane_id ->
           Stdlib.Mutex.protect owners_mu (fun () ->
             match Hashtbl.find_opt owners key with
             | Some owner
               when Atomic.get owner.state.phase = Active
                    && Keeper_lane.Id.equal owner.state.lane_id lane_id ->
               `Existing owner
             | Some owner
               when Keeper_lane.Id.equal owner.state.lane_id lane_id ->
               `Error (draining ())
             | Some _
             | None ->
               `Create lane_id))
  in
  match initial with
  | `Error cause -> Error cause
  | `Existing owner -> Ok (surface_scope owner surface)
  | `Create lane_id ->
    (match create_owner ~base_path ~keeper_name ~lane_id with
     | Error cause ->
       Log.Keeper.error
         "exact-flow owner recovery blocked while Keeper lifecycle remains registered keeper=%s generation=%s cause=%s"
         keeper_name
         (Keeper_lane.Id.to_string lane_id)
         (setup_error_to_string cause);
       Error cause
     | Ok candidate ->
       let installed =
         Keeper_lifecycle_reservation.with_key_lock
           ~base_path
           ~keeper_name
           (fun () ->
              match registered_lane_id () with
              | Some current_lane_id
                when Keeper_lane.Id.equal current_lane_id lane_id ->
                Stdlib.Mutex.protect owners_mu (fun () ->
                  match Hashtbl.find_opt owners key with
                  | Some owner
                    when Atomic.get owner.state.phase = Active
                         && Keeper_lane.Id.equal owner.state.lane_id lane_id ->
                    `Existing owner
                  | Some owner
                    when Keeper_lane.Id.equal owner.state.lane_id lane_id ->
                    `Error (draining ())
                  | Some stale ->
                    Hashtbl.replace owners key candidate;
                    `Installed (candidate, Some stale)
                  | None ->
                    Hashtbl.add owners key candidate;
                    `Installed (candidate, None))
              | Some _
              | None ->
                `Error (unavailable ()))
       in
       match installed with
       | `Existing owner ->
         retire_owner candidate |> note_retirement_result;
         Ok (surface_scope owner surface)
       | `Installed (owner, stale) ->
         Option.iter
           (fun stale -> retire_owner stale |> note_retirement_result)
           stale;
         Ok (surface_scope owner surface)
       | `Error cause ->
         retire_owner candidate |> note_retirement_result;
         Error cause)
;;

let preference_store scope = scope.preference_store
let scope scope = scope.scope

let release_boundary owner =
  let deferred =
    Stdlib.Mutex.protect owner.boundary_mu (fun () ->
      owner.boundary_users <- Int.max 0 (owner.boundary_users - 1);
      if owner.boundary_users = 0
      then (
        let deferred = owner.deferred_release in
        owner.deferred_release <- None;
        deferred)
      else None)
  in
  Option.iter (fun release -> release ()) deferred
;;

let with_boundary ~allow_draining scope ~registered_lane_id f =
  let claimed =
    Keeper_lifecycle_reservation.with_key_lock
      ~base_path:scope.owner.base_path
      ~keeper_name:scope.owner.keeper_name
      (fun () ->
         match registered_lane_id () with
         | Some lane_id when Keeper_lane.Id.equal scope.owner.lane_id lane_id ->
           Stdlib.Mutex.protect scope.owner.boundary_mu (fun () ->
             match Atomic.get scope.owner.phase with
             | Active ->
               scope.owner.boundary_users <- scope.owner.boundary_users + 1;
               true
             | Draining when allow_draining ->
               scope.owner.boundary_users <- scope.owner.boundary_users + 1;
               true
             | Draining
             | Retired ->
               false)
         | Some _
         | None ->
           false)
  in
  if not claimed
  then Owner_unregistered_deferred
  else
    Fun.protect
      ~finally:(fun () -> release_boundary scope.owner)
      (fun () -> Current (f ()))
;;

let with_current scope ~registered_lane_id f =
  with_boundary ~allow_draining:false scope ~registered_lane_id f
;;

let with_settlement scope ~registered_lane_id f =
  with_boundary ~allow_draining:true scope ~registered_lane_id f
;;

let with_librarian_execution_slot scope ~capacity f =
  if capacity = 0
  then Some (f ())
  else
    let slot = scope.owner.librarian_execution_slot in
    let acquired =
      Eio_guard.with_mutex scope.owner.librarian_execution_slot_mu (fun () ->
        slot.capacity <- capacity;
        if slot.in_use >= slot.capacity
        then false
        else (
          slot.in_use <- slot.in_use + 1;
          true))
    in
    if not acquired
    then None
    else
      Fun.protect
        ~finally:(fun () ->
          Eio_guard.with_mutex
            scope.owner.librarian_execution_slot_mu
            (fun () -> slot.in_use <- Int.max 0 (slot.in_use - 1)))
        (fun () -> Some (f ()))
;;

let transition_to_draining state =
  Stdlib.Mutex.protect state.boundary_mu (fun () ->
    match Atomic.get state.phase with
    | Active ->
      Atomic.set state.phase Draining;
      Retirement_draining
    | Draining -> Retirement_draining
    | Retired -> Retirement_owner_replaced)
;;

let begin_retirement ~base_path ~keeper_name ~expected_lane_id =
  Keeper_lifecycle_reservation.with_key_lock
    ~base_path
    ~keeper_name
    (fun () ->
       let key = owner_key ~base_path ~keeper_name in
       Stdlib.Mutex.protect owners_mu (fun () ->
         match Hashtbl.find_opt owners key with
         | None -> Retirement_not_allocated
         | Some owner
           when Keeper_lane.Id.equal owner.state.lane_id expected_lane_id ->
           transition_to_draining owner.state
         | Some _ -> Retirement_owner_replaced))
;;

let release_owner ~base_path ~keeper_name ~expected_lane_id =
  let key = owner_key ~base_path ~keeper_name in
  let owner =
    Stdlib.Mutex.protect owners_mu (fun () ->
      match Hashtbl.find_opt owners key with
      | Some owner
        when Keeper_lane.Id.equal owner.state.lane_id expected_lane_id ->
        Some owner
      | Some _
      | None ->
        None)
  in
  match owner with
  | None -> Ok ()
  | Some owner ->
    (match retire_owner owner with
     | Ok `Released -> Ok ()
     | Ok `Deferred -> Error Retirement_deferred
     | Error _ as error -> error)
;;

let clear () =
  let removed =
    Stdlib.Mutex.protect owners_mu (fun () ->
      let removed = Hashtbl.to_seq_values owners |> List.of_seq in
      Hashtbl.reset owners;
      removed)
  in
  List.iter
    (fun owner -> retire_owner owner |> note_retirement_result)
    removed
;;
