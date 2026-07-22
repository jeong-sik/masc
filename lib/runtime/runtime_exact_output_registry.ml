module Exact_output = Agent_sdk.Exact_output
module String_set = Set.Make (String)

type t =
  { resolver_snapshot : Exact_output.resolver_snapshot
  ; exact_output_lanes : Runtime_schema.exact_output_lane_decl list
  ; generation : int64
  }

type publication_error =
  | Registry_not_published
  | Publication_busy
  | Generation_exhausted
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
 
type lane_lookup_error = Exact_lane_unconfigured of { lane_id : string }

type slot_resolution_error =
  | Blank_slot_id of { position : int }
  | Duplicate_slot_id of
      { position : int
      ; slot_id : string
      }
  | Invalid_slot_id of
      { position : int
      ; slot_id : string
      ; cause : Exact_output.target_ref_error
      }
  | Slot_target_unavailable of
      { position : int
      ; slot_id : string
      ; cause : Exact_output.target_selection_error
      }

type selected_slot =
  { slot_id : string
  ; target : Exact_output.selected_target
  }

type reservation =
  { identity : unit ref
  ; candidate : t option
  }

type reservation_error = Reservation_inactive

let published : t option Atomic.t = Atomic.make None
let publication_mutex = Mutex.create ()
let active_reservation : reservation option ref = ref None

let ( let* ) = Result.bind

let validate_lane_slots resolver_snapshot
    (lane : Runtime_schema.exact_output_lane_decl) =
  let rec loop position seen = function
    | [] -> Ok ()
    | slot_id :: rest ->
      if String.equal (String.trim slot_id) ""
      then Error (Blank_lane_slot { lane_id = lane.id; position })
      else if String_set.mem slot_id seen
      then Error (Duplicate_lane_slot { lane_id = lane.id; position; slot_id })
      else (
        match Exact_output.admit_target_ref resolver_snapshot slot_id with
        | Error (Exact_output.Target_ref_rejected cause) ->
          Error (Invalid_lane_slot { lane_id = lane.id; position; slot_id; cause })
        | Error (Exact_output.Target_not_in_catalog target_ref) ->
          Error
            (Unknown_lane_slot
               { lane_id = lane.id; position; slot_id; target_ref })
        | Ok _ -> loop (position + 1) (String_set.add slot_id seen) rest)
  in
  match lane.slot_ids with
  | [] -> Error (Empty_lane { lane_id = lane.id })
  | slot_ids -> loop 1 String_set.empty slot_ids
;;

let validate_lanes resolver_snapshot lanes =
  let rec loop position seen = function
    | [] -> Ok ()
    | (lane : Runtime_schema.exact_output_lane_decl) :: rest ->
      if String.equal (String.trim lane.id) ""
      then Error (Blank_lane_id { position })
      else if String_set.mem lane.id seen
      then Error (Duplicate_lane_id { position; lane_id = lane.id })
      else
        let* () = validate_lane_slots resolver_snapshot lane in
        loop (position + 1) (String_set.add lane.id seen) rest
  in
  loop 1 String_set.empty lanes
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
    let* () = validate_lanes resolver_snapshot lanes in
    let* generation = next_generation previous in
    let registry = { resolver_snapshot; exact_output_lanes = lanes; generation } in
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
  with_publication_lock
  @@ fun () ->
  match !active_reservation with
  | Some _ -> Error Publication_busy
  | None ->
    (match Atomic.get published, lanes with
     | None, [] -> reserve None
     | None, _ :: _ -> Error Registry_not_published
     | Some previous, _ ->
       let* () = validate_lanes previous.resolver_snapshot lanes in
       if previous.exact_output_lanes = lanes
       then reserve (Some previous)
       else (
         let* generation = next_generation (Some previous) in
         reserve
           (Some
              { resolver_snapshot = previous.resolver_snapshot
              ; exact_output_lanes = lanes
              ; generation
              })))
;;

let same_reservation left right = left.identity == right.identity

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

let lane_slots registry ~lane_id =
  match
    List.find_opt
      (fun (lane : Runtime_schema.exact_output_lane_decl) ->
         String.equal lane.id lane_id)
      registry.exact_output_lanes
  with
  | None -> Error (Exact_lane_unconfigured { lane_id })
  | Some lane -> Ok lane.slot_ids
;;

let resolve_slots registry slot_ids =
  let rec loop position seen outcomes = function
    | [] -> List.rev outcomes
    | slot_id :: rest ->
      let outcome =
        if String.equal (String.trim slot_id) ""
        then Error (Blank_slot_id { position })
        else if String_set.mem slot_id seen
        then Error (Duplicate_slot_id { position; slot_id })
        else (
          match Exact_output.target_ref slot_id with
          | Error cause -> Error (Invalid_slot_id { position; slot_id; cause })
          | Ok target_ref ->
            (match Exact_output.resolve_target registry.resolver_snapshot target_ref with
             | Error cause ->
               Error (Slot_target_unavailable { position; slot_id; cause })
             | Ok target -> Ok { slot_id; target }))
      in
      let seen =
        if String.equal (String.trim slot_id) ""
        then seen
        else String_set.add slot_id seen
      in
      loop (position + 1) seen (outcome :: outcomes) rest
  in
  loop 1 String_set.empty [] slot_ids
;;

let publication_error_to_string = function
  | Registry_not_published -> "exact-output registry has not been published"
  | Publication_busy -> "exact-output registry publication is reserved"
  | Generation_exhausted -> "exact-output registry generation is exhausted"
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

let lane_lookup_error_to_string = function
  | Exact_lane_unconfigured { lane_id } ->
    Printf.sprintf "exact-output lane %S is not configured" lane_id
;;

let slot_resolution_error_to_string = function
  | Blank_slot_id { position } ->
    Printf.sprintf "exact-output slot %d is blank" position
  | Duplicate_slot_id { position; slot_id } ->
    Printf.sprintf "exact-output slot %d duplicates target ref %S" position slot_id
  | Invalid_slot_id { position; slot_id; cause } ->
    let detail =
      match cause with
      | Exact_output.Empty_target_ref -> "empty target ref"
      | Exact_output.Invalid_target_ref -> "invalid target ref"
    in
    Printf.sprintf "exact-output slot %d (%S): %s" position slot_id detail
  | Slot_target_unavailable { position; slot_id; cause } ->
    let detail =
      match cause with
      | Exact_output.Unknown_target target_ref ->
        Printf.sprintf "unknown target %S" target_ref
      | Exact_output.Missing_target_credential
          { target_ref; environment_variable } ->
        Printf.sprintf
          "target %S requires environment variable %s"
          target_ref
          environment_variable
    in
    Printf.sprintf "exact-output slot %d (%S): %s" position slot_id detail
;;

let reservation_error_to_string = function
  | Reservation_inactive -> "exact-output registry reservation is inactive"
;;
