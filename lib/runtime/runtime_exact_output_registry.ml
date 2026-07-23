module Exact_output = Agent_sdk.Exact_output
module String_set = Set.Make (String)
module String_map = Map.Make (String)

type admitted_slot =
  { slot_id : string
  ; admitted_target : Exact_output.admitted_target
  }

type admitted_lane =
  { id : string
  ; slots : admitted_slot list
  }

type t =
  { resolver_snapshot : Exact_output.resolver_snapshot
  ; exact_output_lanes : admitted_lane list
  ; generation : int64
  }

type publication_error =
  | Registry_not_published
  | Publication_busy
  | Generation_exhausted
  | Replacement_base_changed of
      { expected_generation : int64 option
      ; actual_generation : int64 option
      }
  | Blank_lane_id of { position : int }
  | Duplicate_lane_id of
      { position : int
      ; lane_id : string
      }
  | Empty_lane of { lane_id : string }
  | Blank_lane_slot of
      { lane_id : string
      ; position : int
      }
  | Duplicate_lane_slot of
      { lane_id : string
      ; position : int
      ; slot_id : string
      }
  | Invalid_lane_slot of
      { lane_id : string
      ; position : int
      ; slot_id : string
      ; cause : Exact_output.target_ref_error
      }
  | Unknown_lane_slot of
      { lane_id : string
      ; position : int
      ; slot_id : string
      ; target_ref : string
      }
 
type selected_slot =
  { slot_id : string
  ; target : Exact_output.selected_target
  }

type unavailable_slot =
  { position : int
  ; slot_id : string
  ; cause : Exact_output.target_selection_error
  }

type resolved_lane =
  { selected_slots : selected_slot list
  ; unavailable_slots : unavailable_slot list
  }

type lane_resolution_error =
  | Exact_lane_unconfigured of { lane_id : string }
  | No_usable_lane_slots of
      { lane_id : string
      ; unavailable_slots : unavailable_slot list
      }

type prepared_replacement =
  { base : t option
  ; candidate : t option
  }

type ('not_committed, 'committed) replacement_effect =
  | Not_committed of 'not_committed
  | Committed of 'committed

type reservation =
  { identity : unit ref
  ; candidate : t option
  }

type reservation_error = Reservation_inactive

let published : t option Atomic.t = Atomic.make None
let publication_mutex = Mutex.create ()
let active_reservation : reservation option ref = ref None

let ( let* ) = Result.bind

let admit_lane_slots resolver_snapshot admitted_by_id
    (lane : Runtime_schema.exact_output_lane_decl) =
  let rec loop position seen admitted_by_id admitted_slots = function
    | [] -> Ok (List.rev admitted_slots, admitted_by_id)
    | slot_id :: rest ->
      if String.equal (String.trim slot_id) ""
      then Error (Blank_lane_slot { lane_id = lane.id; position })
      else if String_set.mem slot_id seen
      then Error (Duplicate_lane_slot { lane_id = lane.id; position; slot_id })
      else
        let admitted = String_map.find_opt slot_id admitted_by_id in
        let* admitted_target, admitted_by_id =
          match admitted with
          | Some admitted_target -> Ok (admitted_target, admitted_by_id)
          | None ->
            (match Exact_output.admit_target_ref resolver_snapshot slot_id with
             | Error (Exact_output.Target_ref_rejected cause) ->
               Error
                 (Invalid_lane_slot
                    { lane_id = lane.id; position; slot_id; cause })
             | Error (Exact_output.Target_not_in_catalog target_ref) ->
               Error
                 (Unknown_lane_slot
                    { lane_id = lane.id; position; slot_id; target_ref })
             | Ok admitted_target ->
               Ok
                 ( admitted_target
                 , String_map.add slot_id admitted_target admitted_by_id ))
        in
        loop
          (position + 1)
          (String_set.add slot_id seen)
          admitted_by_id
          ({ slot_id; admitted_target } :: admitted_slots)
          rest
  in
  match lane.slot_ids with
  | [] -> Error (Empty_lane { lane_id = lane.id })
  | slot_ids -> loop 1 String_set.empty admitted_by_id [] slot_ids
;;

let admit_lanes ~admitted_by_id resolver_snapshot lanes =
  let rec loop position seen admitted_by_id admitted_lanes = function
    | [] -> Ok (List.rev admitted_lanes)
    | (lane : Runtime_schema.exact_output_lane_decl) :: rest ->
      if String.equal (String.trim lane.id) ""
      then Error (Blank_lane_id { position })
      else if String_set.mem lane.id seen
      then Error (Duplicate_lane_id { position; lane_id = lane.id })
      else
        let* slots, admitted_by_id =
          admit_lane_slots resolver_snapshot admitted_by_id lane
        in
        loop
          (position + 1)
          (String_set.add lane.id seen)
          admitted_by_id
          ({ id = lane.id; slots } :: admitted_lanes)
          rest
  in
  loop 1 String_set.empty admitted_by_id [] lanes
;;

let rec same_slot_ids (admitted_slots : admitted_slot list) declared_slot_ids =
  match admitted_slots, declared_slot_ids with
  | [], [] -> true
  | admitted :: admitted_rest, declared :: declared_rest ->
    String.equal admitted.slot_id declared
    && same_slot_ids admitted_rest declared_rest
  | [], _ :: _ | _ :: _, [] -> false
;;

let rec same_lane_declarations admitted_lanes declared_lanes =
  match admitted_lanes, declared_lanes with
  | [], [] -> true
  | admitted :: admitted_rest, declared :: declared_rest ->
    String.equal admitted.id declared.Runtime_schema.id
    && same_slot_ids admitted.slots declared.slot_ids
    && same_lane_declarations admitted_rest declared_rest
  | [], _ :: _ | _ :: _, [] -> false
;;

let admitted_by_id admitted_lanes =
  List.fold_left
    (fun by_id lane ->
       List.fold_left
         (fun by_id (slot : admitted_slot) ->
            String_map.add slot.slot_id slot.admitted_target by_id)
         by_id
         lane.slots)
    String_map.empty
    admitted_lanes
;;

let with_publication_lock f =
  Mutex.lock publication_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock publication_mutex) f
;;

let next_generation = function
  | None -> Ok 1L
  | Some registry ->
    if Int64.equal registry.generation Int64.max_int
    then Error Generation_exhausted
    else Ok (Int64.succ registry.generation)
;;

let publish ~lanes resolver_snapshot =
  with_publication_lock
  @@ fun () ->
  match !active_reservation with
  | Some _ -> Error Publication_busy
  | None ->
    let previous = Atomic.get published in
    let* exact_output_lanes =
      admit_lanes ~admitted_by_id:String_map.empty resolver_snapshot lanes
    in
    let* generation = next_generation previous in
    let registry = { resolver_snapshot; exact_output_lanes; generation } in
    Atomic.set published (Some registry);
    Ok registry
;;

let current () =
  with_publication_lock
  @@ fun () ->
  match !active_reservation with
  | Some _ -> Error Publication_busy
  | None ->
    (match Atomic.get published with
     | Some registry -> Ok registry
     | None -> Error Registry_not_published)
;;

let reserve candidate =
  let reservation = { identity = ref (); candidate } in
  active_reservation := Some reservation;
  Ok reservation
;;

let prepare_replacement ~lanes =
  let base = Atomic.get published in
  match base, lanes with
  | None, [] -> Ok { base; candidate = None }
  | None, _ :: _ -> Error Registry_not_published
  | Some previous, _ ->
    if same_lane_declarations previous.exact_output_lanes lanes
    then Ok { base; candidate = Some previous }
    else (
      let* exact_output_lanes =
        admit_lanes
          ~admitted_by_id:(admitted_by_id previous.exact_output_lanes)
          previous.resolver_snapshot
          lanes
      in
      let* generation = next_generation (Some previous) in
      Ok
        { base
        ; candidate =
            Some
              { resolver_snapshot = previous.resolver_snapshot
              ; exact_output_lanes
              ; generation
              }
        })
;;

let same_registry_identity left right =
  match left, right with
  | None, None -> true
  | Some left, Some right -> left == right
  | None, Some _ | Some _, None -> false
;;

let registry_generation = Option.map (fun registry -> registry.generation)

let reserve_replacement prepared =
  with_publication_lock
  @@ fun () ->
  match !active_reservation with
  | Some _ -> Error Publication_busy
  | None ->
    let actual = Atomic.get published in
    if same_registry_identity prepared.base actual
    then reserve prepared.candidate
    else
      Error
        (Replacement_base_changed
           { expected_generation = registry_generation prepared.base
           ; actual_generation = registry_generation actual
           })
;;

let same_reservation left right = left.identity == right.identity

let close_private_transaction reservation ~publish =
  with_publication_lock
  @@ fun () ->
  (* [reservation] never leaves [transact_replacement]'s closure. Other
     publication operations can only observe the active fence, so no external
     caller can consume or replace this exact token while [apply_write] runs. *)
  active_reservation := None;
  if publish
  then
    Option.iter
      (fun registry -> Atomic.set published (Some registry))
      reservation.candidate
;;

let transact_replacement prepared ~apply_write =
  let* reservation = reserve_replacement prepared in
  match apply_write () with
  | Not_committed _ as outcome ->
    close_private_transaction reservation ~publish:false;
    Ok outcome
  | Committed _ as outcome ->
    close_private_transaction reservation ~publish:true;
    Ok outcome
  | exception exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    close_private_transaction reservation ~publish:false;
    Printexc.raise_with_backtrace exception_ backtrace
;;

let finish_replacement reservation =
  with_publication_lock
  @@ fun () ->
  match !active_reservation with
  | Some active when same_reservation active reservation ->
    active_reservation := None;
    Option.iter
      (fun registry -> Atomic.set published (Some registry))
      active.candidate;
    Ok ()
  | Some _ | None -> Error Reservation_inactive
;;

let abort_replacement reservation =
  with_publication_lock
  @@ fun () ->
  match !active_reservation with
  | Some active when same_reservation active reservation ->
    active_reservation := None;
    Ok ()
  | Some _ | None -> Error Reservation_inactive
;;
let generation registry = registry.generation

let resolve_lane registry ~lane_id =
  match
    List.find_opt
      (fun lane -> String.equal lane.id lane_id)
      registry.exact_output_lanes
  with
  | None -> Error (Exact_lane_unconfigured { lane_id })
  | Some lane ->
    let rec loop position selected_slots unavailable_slots = function
      | [] ->
        let selected_slots = List.rev selected_slots in
        let unavailable_slots = List.rev unavailable_slots in
        if selected_slots = []
        then Error (No_usable_lane_slots { lane_id; unavailable_slots })
        else Ok { selected_slots; unavailable_slots }
      | slot :: rest ->
        (match Exact_output.resolve_target slot.admitted_target with
         | Ok target ->
           loop
             (position + 1)
             ({ slot_id = slot.slot_id; target } :: selected_slots)
             unavailable_slots
             rest
         | Error cause ->
           loop
             (position + 1)
             selected_slots
             ({ position; slot_id = slot.slot_id; cause } :: unavailable_slots)
             rest)
    in
    loop 1 [] [] lane.slots
;;

let publication_error_to_string = function
  | Registry_not_published -> "exact-output registry has not been published"
  | Publication_busy -> "exact-output registry publication is reserved"
  | Generation_exhausted -> "exact-output registry generation is exhausted"
  | Replacement_base_changed { expected_generation; actual_generation } ->
    let show_generation = function
      | None -> "unpublished"
      | Some generation -> Int64.to_string generation
    in
    Printf.sprintf
      "exact-output replacement base changed (expected generation %s, actual generation %s)"
      (show_generation expected_generation)
      (show_generation actual_generation)
  | Blank_lane_id { position } ->
    Printf.sprintf "exact-output lane %d has a blank id" position
  | Duplicate_lane_id { position; lane_id } ->
    Printf.sprintf "exact-output lane %d duplicates lane id %S" position lane_id
  | Empty_lane { lane_id } ->
    Printf.sprintf "exact-output lane %S has no slots" lane_id
  | Blank_lane_slot { lane_id; position } ->
    Printf.sprintf "exact-output lane %S slot %d is blank" lane_id position
  | Duplicate_lane_slot { lane_id; position; slot_id } ->
    Printf.sprintf
      "exact-output lane %S slot %d duplicates target ref %S"
      lane_id
      position
      slot_id
  | Invalid_lane_slot { lane_id; position; slot_id; cause } ->
    let detail =
      match cause with
      | Exact_output.Empty_target_ref -> "empty target ref"
      | Exact_output.Invalid_target_ref -> "invalid target ref"
    in
    Printf.sprintf
      "exact-output lane %S slot %d (%S): %s"
      lane_id
      position
      slot_id
      detail
  | Unknown_lane_slot { lane_id; position; slot_id; target_ref } ->
    Printf.sprintf
      "exact-output lane %S slot %d (%S): target %S is not in the frozen catalog"
      lane_id
      position
      slot_id
      target_ref
;;

let unavailable_slot_to_string { position; slot_id; cause } =
  let detail =
    match cause with
    | Exact_output.Missing_target_credential
        { target_ref; environment_variable } ->
      Printf.sprintf
        "target %S requires environment variable %s"
        target_ref
        environment_variable
    | Exact_output.Target_credential_invalid
        { target_ref; environment_variable } ->
      Printf.sprintf
        "target %S has an invalid credential in environment variable %s"
        target_ref
        environment_variable
    | Exact_output.Target_credential_read_failed
        { target_ref; environment_variable } ->
      Printf.sprintf
        "target %S credential environment variable %s could not be read"
        target_ref
        environment_variable
  in
  Printf.sprintf "exact-output slot %d (%S): %s" position slot_id detail
;;

let lane_resolution_error_to_string = function
  | Exact_lane_unconfigured { lane_id } ->
    Printf.sprintf "exact-output lane %S is not configured" lane_id
  | No_usable_lane_slots { lane_id; unavailable_slots } ->
    Printf.sprintf
      "exact-output lane %S has no usable slots: %s"
      lane_id
      (unavailable_slots
       |> List.map unavailable_slot_to_string
       |> String.concat "; ")
;;

let reservation_error_to_string = function
  | Reservation_inactive -> "exact-output registry reservation is inactive"
;;

module For_testing = struct
  type nonrec reservation = reservation
  type nonrec reservation_error = reservation_error = Reservation_inactive

  let reserve_replacement = reserve_replacement
  let finish_replacement = finish_replacement
  let abort_replacement = abort_replacement
  let reservation_error_to_string = reservation_error_to_string
end
