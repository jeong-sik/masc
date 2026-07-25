module Exact_output = Agent_sdk.Exact_output

type surface =
  | Compaction
  | Board_attention
  | Hitl_summary
  | Librarian

type librarian_execution_slot =
  { mutable capacity : int
  ; mutable in_use : int
  }

type owner_state =
  { base_path : string
  ; keeper_name : string
  ; lane_id : Keeper_lane.Id.t
  ; retired : bool Atomic.t
  ; librarian_execution_slot : librarian_execution_slot
  ; librarian_execution_slot_mu : Eio.Mutex.t
  ; librarian_exact_flow_mu : Eio.Mutex.t
  }

type t =
  { owner : owner_state
  ; preference_store : Exact_output.flow_preference_store
  ; scope : Exact_output.flow_scope
  }

type 'a current_boundary =
  | Current of 'a
  | Owner_unregistered_deferred

type owner =
  { state : owner_state
  ; compaction : t
  ; board_attention : t
  ; hitl_summary : t
  ; librarian : t
  }

let surface_label = function
  | Compaction -> "compaction"
  | Board_attention -> "board_attention"
  | Hitl_summary -> "hitl_summary"
  | Librarian -> "librarian"
;;

let create_scope state surface =
  let owner_fingerprint =
    String.concat
      "\000"
      [ state.base_path
      ; state.keeper_name
      ; Keeper_lane.Id.to_string state.lane_id
      ; surface_label surface
      ]
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  let preference_store =
    Exact_output.create_flow_preference_store ~capacity:1
    |> Result.get_ok
  in
  let scope =
    Exact_output.make_flow_scope ~id:("masc:" ^ owner_fingerprint)
    |> Result.get_ok
  in
  { owner = state; preference_store; scope }
;;

let create_owner ~base_path ~keeper_name ~lane_id =
  let state =
    { base_path
    ; keeper_name
    ; lane_id
    ; retired = Atomic.make false
    ; librarian_execution_slot = { capacity = 0; in_use = 0 }
    ; librarian_execution_slot_mu = Eio.Mutex.create ()
    ; librarian_exact_flow_mu = Eio.Mutex.create ()
    }
  in
  { state
  ; compaction = create_scope state Compaction
  ; board_attention = create_scope state Board_attention
  ; hitl_summary = create_scope state Hitl_summary
  ; librarian = create_scope state Librarian
  }
;;

let surface_scope owner = function
  | Compaction -> owner.compaction
  | Board_attention -> owner.board_attention
  | Hitl_summary -> owner.hitl_summary
  | Librarian -> owner.librarian
;;

let owners : (string, owner) Hashtbl.t = Hashtbl.create 16
let owners_mu = Stdlib.Mutex.create ()

let owner_key ~base_path ~keeper_name =
  Keeper_registry_types.registry_key ~base_path keeper_name
;;

let release_scope scope =
  ignore
    (Exact_output.remove_flow_preference_scope
       scope.preference_store
       scope.scope)
;;

let retire_owner owner =
  if Atomic.compare_and_set owner.state.retired false true
  then (
    release_scope owner.compaction;
    release_scope owner.board_attention;
    release_scope owner.hitl_summary;
    release_scope owner.librarian)
;;

let for_registered ~registered_lane_id ~base_path ~keeper_name ~surface =
  Keeper_lifecycle_reservation.with_key_lock
    ~base_path
    ~keeper_name
    (fun () ->
       match registered_lane_id () with
       | None ->
         Error
           (Printf.sprintf
              "exact-flow owner is not registered: keeper=%s"
              keeper_name)
       | Some lane_id ->
         let key = owner_key ~base_path ~keeper_name in
         let owner =
           Stdlib.Mutex.protect owners_mu (fun () ->
             match Hashtbl.find_opt owners key with
             | Some owner
               when (not (Atomic.get owner.state.retired))
                    && Keeper_lane.Id.equal owner.state.lane_id lane_id ->
               owner
             | Some stale ->
               retire_owner stale;
               let owner = create_owner ~base_path ~keeper_name ~lane_id in
               Hashtbl.replace owners key owner;
               owner
             | None ->
               let owner = create_owner ~base_path ~keeper_name ~lane_id in
               Hashtbl.add owners key owner;
               owner)
         in
         Ok (surface_scope owner surface))
;;

let preference_store scope = scope.preference_store
let scope scope = scope.scope

let with_current scope ~registered_lane_id f =
  Keeper_lifecycle_reservation.with_key_lock
    ~base_path:scope.owner.base_path
    ~keeper_name:scope.owner.keeper_name
    (fun () ->
       match registered_lane_id () with
       | Some lane_id
         when (not (Atomic.get scope.owner.retired))
              && Keeper_lane.Id.equal scope.owner.lane_id lane_id ->
         Current (f ())
       | Some _
       | None -> Owner_unregistered_deferred)
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

let with_librarian_exact_flow_lock scope f =
  Eio_guard.with_mutex scope.owner.librarian_exact_flow_mu f
;;

let release_owner ~base_path ~keeper_name ~expected_lane_id =
  let key = owner_key ~base_path ~keeper_name in
  let removed =
    Stdlib.Mutex.protect owners_mu (fun () ->
      match Hashtbl.find_opt owners key with
      | Some owner
        when Keeper_lane.Id.equal owner.state.lane_id expected_lane_id ->
        Hashtbl.remove owners key;
        Some owner
      | Some _
      | None ->
        None)
  in
  Option.iter retire_owner removed
;;

let clear () =
  let removed =
    Stdlib.Mutex.protect owners_mu (fun () ->
      let removed = Hashtbl.to_seq_values owners |> List.of_seq in
      Hashtbl.reset owners;
      removed)
  in
  List.iter retire_owner removed
;;
