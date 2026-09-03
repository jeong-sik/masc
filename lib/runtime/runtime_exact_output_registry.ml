module Exact_output = Agent_core.Exact_output
module String_set = Set.Make (String)
module String_map = Map.Make (String)

type admitted_slot =
  { slot_id : string
  ; admitted_target : Exact_output.admitted_target
  }

type admitted_lane =
  { id : string
  ; slots : admitted_slot list
  ; cli_slots : string list
    (* Official-client runtime ids walked as one-shot fallbacks after every
       catalog slot is exhausted. Carried verbatim from the declaration:
       whether an id resolves to a live official-client runtime is an
       execution-time question the lane runner answers with a typed error,
       and the projection shows the declaration either way. *)
  }

type rejected_slot =
  { lane_id : string
  ; position : int
  ; slot_id : string
  }

type rejected_slot_diagnosis =
  | Declared_target_binding_rejected
  | Configured_runtime_only of
      { provider_id : string
      ; api_name : string
      }
  | Unknown_to_both_registries

(* An exact lane admits overlay [[targets]] ids; a runtime.toml runtime id
   is invisible to it even when both name the same model, and the two
   registries share a naming scheme, so an operator can write the wrong one
   and read "absent from the frozen catalog" as the catalog having moved on
   (verifier_exact, 2026-09-02). A declared target whose provider binding was
   rejected also lands here, since the resolver drops it from the admitted
   set; that case is named first so it is not mistaken for a runtime id that
   happens to share the string. The runtime lookup is injected because the
   registry sits below [Runtime]; the binding verdict comes from the
   snapshot the registry already holds. *)
let classify_rejected_slot (slot : rejected_slot) ~declared_target_rejected ~configured_runtime =
  if declared_target_rejected slot.slot_id
  then Declared_target_binding_rejected
  else (
    match configured_runtime slot.slot_id with
    | Some (provider_id, api_name) -> Configured_runtime_only { provider_id; api_name }
    | None -> Unknown_to_both_registries)
;;

type t =
  { resolver_snapshot : Exact_output.resolver_snapshot
  ; declared_lanes : Runtime_schema.exact_output_lane_decl list
  ; exact_output_lanes : admitted_lane list
  ; rejected_slots : rejected_slot list
  ; required_lane_ids : string list
  }

type publication_error =
  | Registry_not_published
  | Publication_busy
  | Replacement_base_changed
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
  | Required_lane_unavailable of { lane_id : string }
 
type selected_slot =
  { slot_id : string
  ; admitted_target : Exact_output.admitted_target
  }

type resolved_lane =
  { selected_slots : selected_slot list
  ; cli_slots : string list
  }

type lane_resolution_error =
  | Exact_lane_unconfigured of { lane_id : string }
  | No_admitted_lane_slots of { lane_id : string }

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
  let rec loop position seen admitted_by_id admitted_slots rejected_slots = function
    | [] ->
      Ok (List.rev admitted_slots, admitted_by_id, List.rev rejected_slots)
    | slot_id :: rest ->
      if String.equal (String.trim slot_id) ""
      then Error (Blank_lane_slot { lane_id = lane.id; position })
      else if String_set.mem slot_id seen
      then Error (Duplicate_lane_slot { lane_id = lane.id; position; slot_id })
      else
        let admitted = String_map.find_opt slot_id admitted_by_id in
        (match admitted with
         | Some admitted_target ->
           loop
             (position + 1)
             (String_set.add slot_id seen)
             admitted_by_id
             (({ slot_id; admitted_target } : admitted_slot) :: admitted_slots)
             rejected_slots
             rest
         | None ->
           (match Exact_output.admit_target_ref resolver_snapshot slot_id with
            | Error (Exact_output.Target_ref_rejected cause) ->
              Error
                (Invalid_lane_slot
                   { lane_id = lane.id; position; slot_id; cause })
            | Error (Exact_output.Target_not_in_catalog _) ->
              loop
                (position + 1)
                (String_set.add slot_id seen)
                admitted_by_id
                admitted_slots
                ({ lane_id = lane.id; position; slot_id } :: rejected_slots)
                rest
            | Ok admitted_target ->
              loop
                (position + 1)
                (String_set.add slot_id seen)
                (String_map.add slot_id admitted_target admitted_by_id)
                (({ slot_id; admitted_target } : admitted_slot) :: admitted_slots)
                rejected_slots
                rest))
  in
  match lane.slot_ids with
  | [] -> Error (Empty_lane { lane_id = lane.id })
  | slot_ids -> loop 1 String_set.empty admitted_by_id [] [] slot_ids
;;

let admit_lanes ~admitted_by_id resolver_snapshot lanes =
  let rec loop position seen admitted_by_id admitted_lanes rejected_slots = function
    | [] -> Ok (List.rev admitted_lanes, List.rev rejected_slots)
    | (lane : Runtime_schema.exact_output_lane_decl) :: rest ->
      if String.equal (String.trim lane.id) ""
      then Error (Blank_lane_id { position })
      else if String_set.mem lane.id seen
      then Error (Duplicate_lane_id { position; lane_id = lane.id })
      else
        let* slots, admitted_by_id, lane_rejected_slots =
          admit_lane_slots resolver_snapshot admitted_by_id lane
        in
        loop
          (position + 1)
          (String_set.add lane.id seen)
          admitted_by_id
          ({ id = lane.id; slots; cli_slots = lane.cli_slot_ids }
           :: admitted_lanes)
          (List.rev_append lane_rejected_slots rejected_slots)
          rest
  in
  loop 1 String_set.empty admitted_by_id [] [] lanes
;;

let rec same_slot_ids left_slot_ids right_slot_ids =
  match left_slot_ids, right_slot_ids with
  | [], [] -> true
  | left :: left_rest, right :: right_rest ->
    String.equal left right && same_slot_ids left_rest right_rest
  | [], _ :: _ | _ :: _, [] -> false
;;

let rec same_lane_declarations left_lanes right_lanes =
  match left_lanes, right_lanes with
  | [], [] -> true
  | left :: left_rest, right :: right_rest ->
    String.equal left.Runtime_schema.id right.Runtime_schema.id
    && same_slot_ids left.slot_ids right.slot_ids
    && same_lane_declarations left_rest right_rest
  | [], _ :: _ | _ :: _, [] -> false
;;

let validate_required_lanes required_lane_ids admitted_lanes =
  let rec loop = function
    | [] -> Ok ()
    | lane_id :: rest ->
      (match
         List.find_opt
           (fun (lane : admitted_lane) -> String.equal lane.id lane_id)
           admitted_lanes
       with
       | Some { slots = _ :: _; _ } -> loop rest
       | Some { slots = []; _ } | None ->
         Error (Required_lane_unavailable { lane_id }))
  in
  loop required_lane_ids
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

let publish ?(required_lane_ids = []) ~lanes resolver_snapshot =
  with_publication_lock
  @@ fun () ->
  match !active_reservation with
  | Some _ -> Error Publication_busy
  | None ->
    let* exact_output_lanes, rejected_slots =
      admit_lanes ~admitted_by_id:String_map.empty resolver_snapshot lanes
    in
    let* () = validate_required_lanes required_lane_ids exact_output_lanes in
    let registry =
      { resolver_snapshot
      ; declared_lanes = lanes
      ; exact_output_lanes
      ; rejected_slots
      ; required_lane_ids
      }
    in
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
    if same_lane_declarations previous.declared_lanes lanes
    then Ok { base; candidate = Some previous }
    else (
      let* exact_output_lanes, rejected_slots =
        admit_lanes
          ~admitted_by_id:(admitted_by_id previous.exact_output_lanes)
          previous.resolver_snapshot
          lanes
      in
      let* () =
        validate_required_lanes previous.required_lane_ids exact_output_lanes
      in
      Ok
        { base
        ; candidate =
            Some
              { resolver_snapshot = previous.resolver_snapshot
              ; declared_lanes = lanes
              ; exact_output_lanes
              ; rejected_slots
              ; required_lane_ids = previous.required_lane_ids
              }
        })
;;

let same_registry_identity left right =
  match left, right with
  | None, None -> true
  | Some left, Some right -> left == right
  | None, Some _ | Some _, None -> false
;;


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
      Error Replacement_base_changed
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
let rejected_slots registry = registry.rejected_slots

let diagnose_rejected_slot registry (slot : rejected_slot) ~configured_runtime =
  let rejected_bindings =
    Exact_output.resolver_rejected_target_bindings registry.resolver_snapshot
    |> List.map (fun (binding : Exact_output.rejected_target_binding) -> binding.target_ref)
  in
  classify_rejected_slot
    slot
    ~declared_target_rejected:(fun slot_id -> List.mem slot_id rejected_bindings)
    ~configured_runtime
;;

(* Keeper assignments whose target left the frozen catalog. These do not
   reject a lane slot — the assignment just silently stops resolving and the
   keeper falls through to the default runtime — which is exactly why they
   need their own report: on 2026-08-28 three keepers ran on retired targets
   for days with no log line naming them, only measured fallback traffic. *)
let catalog_absent_assignments resolver_snapshot ~(assignments :
    (string * string) list) : (string * string) list =
  List.filter_map
    (fun (keeper_name, target_ref) ->
       match Exact_output.admit_target_ref resolver_snapshot target_ref with
       | Error (Exact_output.Target_not_in_catalog _) -> Some (keeper_name, target_ref)
       | Error (Exact_output.Target_ref_rejected _)
       | Ok _ -> None)
    assignments
;;

let resolve_lane registry ~lane_id =
  match
    List.find_opt
      (fun lane -> String.equal lane.id lane_id)
      registry.exact_output_lanes
  with
  | None -> Error (Exact_lane_unconfigured { lane_id })
  | Some lane ->
    let selected_slots =
      List.map
        (fun (slot : admitted_slot) ->
           ({ slot_id = slot.slot_id
            ; admitted_target = slot.admitted_target
            }
             : selected_slot))
        lane.slots
    in
    (* A lane is empty only when it has NOTHING to run: cli fallbacks keep a
       lane alive even when every catalog slot was dropped (and a cli-only
       judge lane is a supported shape — RFC cli-runtimes-as-lane-slots). *)
    if selected_slots = [] && lane.cli_slots = []
    then Error (No_admitted_lane_slots { lane_id })
    else Ok { selected_slots; cli_slots = lane.cli_slots }
;;

let publication_error_to_string = function
  | Registry_not_published -> "exact-output registry has not been published"
  | Publication_busy -> "exact-output registry publication is reserved"
  | Replacement_base_changed ->
    "exact-output replacement base changed since it was prepared"
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
  | Required_lane_unavailable { lane_id } ->
    Printf.sprintf
      "required exact-output lane %S has no admitted target in the frozen catalog"
      lane_id
;;

let lane_resolution_error_to_string = function
  | Exact_lane_unconfigured { lane_id } ->
    Printf.sprintf "exact-output lane %S is not configured" lane_id
  | No_admitted_lane_slots { lane_id } ->
    Printf.sprintf "exact-output lane %S has no admitted slots" lane_id
;;

let reservation_error_to_string = function
  | Reservation_inactive -> "exact-output registry reservation is inactive"
;;

module For_testing = struct
  let classify_rejected_slot = classify_rejected_slot
  type nonrec reservation = reservation
  type nonrec reservation_error = reservation_error = Reservation_inactive

  let reserve_replacement = reserve_replacement
  let finish_replacement = finish_replacement
  let abort_replacement = abort_replacement
  let reservation_error_to_string = reservation_error_to_string
end
