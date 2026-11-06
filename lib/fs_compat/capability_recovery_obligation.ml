(* The record model is [Capability_recovery_record], included here. Its JSON
   codec is [Capability_recovery_record_codec], opened here. Five more
   modules are included here: [Capability_recovery_store_model], the
   directory names and the failure vocabulary;
   [Capability_recovery_store_layout], the directory layout operations;
   [Capability_recovery_store_scope], owner discovery and the scoped opening
   of one owner's store; [Capability_recovery_record_io], the file
   operations on one record; and [Capability_recovery_inventory], the
   read-only inventory of a store. *)
include Capability_recovery_record
open Capability_recovery_record_codec
include Capability_recovery_store_model
include Capability_recovery_store_layout
include Capability_recovery_store_scope
include Capability_recovery_record_io
include Capability_recovery_inventory

let ensure_input_owner ~store ~operation_id actual_owner =
  if not (equal_owner store.owner actual_owner)
  then
    raise_validation
      ~operation:Decode_record
      ~subject:(Record (Active, store.owner, operation_id))
      (Record_owner_mismatch
         { expected = store.owner; actual = actual_owner })
;;

let run_mutation ~initial_effect f =
  let observed_effect = ref initial_effect in
  try
    let value = Eio.Cancel.protect (fun () -> f observed_effect) in
    Eio.Fiber.check ();
    Ok value
  with
  | Eio.Cancel.Cancelled (Recovery_store_cancelled _) as cancellation ->
    (* An inner effect boundary knows more than this transaction's last
       completed step. Preserve its exact mutation and original authority. *)
    Printexc.raise_with_backtrace cancellation (Printexc.get_raw_backtrace ())
  | Eio.Cancel.Cancelled reason as cancellation ->
    let backtrace = Printexc.get_raw_backtrace () in
    if !observed_effect = No_record_change
    then Printexc.raise_with_backtrace cancellation backtrace
    else
      Printexc.raise_with_backtrace
        (Eio.Cancel.Cancelled
           (Recovery_store_cancelled (reason, !observed_effect, [])))
        backtrace
  | Transition_failed error -> Error error
  | Store_failure failure ->
    Error
      { store_effect = !observed_effect
      ; failure
      ; cleanup_failures = []
      }
;;

(* NDT-OK: UUID entropy names an exclusively-created obligation record;
   correctness comes from exclusive create plus exact collision handling. The
   nonce never drives recovery or publication policy. *)
let operation_id_rng = Domain.DLS.new_key Random.State.make_self_init

let fresh_operation_id () =
  Uuidm.v4_gen (Domain.DLS.get operation_id_rng) ()
;;

let prepare_with_operation_id_internal
      ~store
      ~operation_id
      ~publication
      ~locator
      ~permissions
  =
  let prepared = { owner = store.owner; operation_id; publication; locator; permissions } in
  let raw = encode_prepared prepared in
  (match record_kind ~store ~area:Owned ~operation_id with
   | `Not_found -> ()
   | _ -> raise_existing_record_mismatch ~store ~area:Owned ~operation_id);
  (match record_kind ~store ~area:Forensic ~operation_id with
   | `Not_found -> ()
   | _ -> raise_existing_record_mismatch ~store ~area:Forensic ~operation_id);
  ignore
    (ensure_exact_record
       ~store
       ~area:Active
       ~operation_id
       ~raw
       ~base_effect:No_record_change
       ~success_effect:Active_record_durable
       ~unknown_effect:Active_record_state_unknown);
  prepared
;;

let prepare ~(store : store) ~publication ~(locator : locator) ~(permissions : permissions) =
  let create_attempt () =
    let operation_id = fresh_operation_id () in
    let prepared = { owner = store.owner; operation_id; publication; locator; permissions } in
    let raw = encode_prepared prepared in
    run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
    match
      create_record_exclusive
        ~store
        ~area:Active
        ~operation_id
        ~raw
        ~base_effect:No_record_change
        ~success_effect:Active_record_durable
        ~unknown_effect:Active_record_state_unknown
    with
    | Record_exists -> `Collision
    | Record_created ->
      observed_effect := Active_record_durable;
      let cross_area_collision =
        match record_kind ~store ~area:Owned ~operation_id with
        | `Not_found ->
          (match record_kind ~store ~area:Forensic ~operation_id with
           | `Not_found -> false
           | _ -> true)
        | _ -> true
      in
      if not cross_area_collision
      then `Prepared prepared
      else (
        remove_exact_source
          ~store
          ~area:Active
          ~operation_id
          ~expected_raw:raw
          ~effect_before:Active_record_durable
          ~removal_transition:Discharge_active;
        observed_effect := Active_record_discharged;
        `Collision)
  in
  let rec retry () =
    match create_attempt () with
    | Error _ as error -> error
    | Ok (`Prepared prepared) -> Ok prepared
    | Ok `Collision ->
      (* Collision retry is intentionally outside cancellation protection. The
         loop is meaning-based and unbounded, but it remains cancellable. *)
      Eio.Fiber.check ();
      retry ()
  in
  retry ()
;;

let bind ~(store : store) ~(prepared : prepared) ~stage_identity =
  let operation_id = prepared.operation_id in
  run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
  ensure_input_owner ~store ~operation_id prepared.owner;
  let bound = { prepared; stage_identity } in
  let active_raw = encode_prepared prepared in
  let owned_raw = encode_bound bound in
  (match record_kind ~store ~area:Active ~operation_id with
   | `Not_found ->
     (match record_kind ~store ~area:Owned ~operation_id with
      | `Regular_file ->
        ignore
          (verify_exact_source
             ~store
             ~area:Owned
             ~operation_id
             ~expected_raw:owned_raw
             ~store_effect:Owned_record_durable);
        (* Under this module's sole-writer protocol, an exact destination with
           no source is reachable only after the destination barrier. Record
           that causal state before repeating either idempotency barrier. *)
        observed_effect :=
          Source_removal_durability_unknown Active_to_owned;
        sync_directory
          ~subject:(Area (Owned, store.owner))
          (area_directory store Owned);
        sync_directory
          ~subject:(Area (Active, store.owner))
          (area_directory store Active);
        observed_effect := Owned_record_durable
      | `Not_found -> raise_missing_record ~store ~area:Active ~operation_id
      | _ ->
        raise_existing_record_mismatch ~store ~area:Owned ~operation_id)
   | `Regular_file ->
     ignore
       (verify_exact_source
          ~store
          ~area:Active
          ~operation_id
          ~expected_raw:active_raw
          ~store_effect:Active_record_durable);
     observed_effect := Active_record_durable;
     ignore
       (ensure_exact_record
          ~store
          ~area:Owned
          ~operation_id
          ~raw:owned_raw
          ~base_effect:Active_record_durable
          ~success_effect:Owned_record_durable_with_active
          ~unknown_effect:Owned_record_state_unknown_with_active);
     observed_effect := Owned_record_durable_with_active;
     remove_exact_source
       ~store
       ~area:Active
       ~operation_id
       ~expected_raw:active_raw
       ~effect_before:Owned_record_durable_with_active
       ~removal_transition:Active_to_owned;
     observed_effect := Owned_record_durable
   | _ -> raise_existing_record_mismatch ~store ~area:Active ~operation_id);
  bound
;;

type discharge_outcome =
  | Discharged
  | Already_discharged

let discharge_prepared ~(store : store) ~(prepared : prepared) =
  let operation_id = prepared.operation_id in
  run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
  ensure_input_owner ~store ~operation_id prepared.owner;
  match record_kind ~store ~area:Active ~operation_id with
  | `Not_found ->
    observed_effect :=
      Source_removal_durability_unknown Discharge_active;
    sync_directory
      ~subject:(Area (Active, store.owner))
      (area_directory store Active);
    observed_effect := Active_record_discharged;
    Already_discharged
  | `Regular_file ->
    observed_effect := Active_record_durable;
    remove_exact_source
      ~store
      ~area:Active
      ~operation_id
      ~expected_raw:(encode_prepared prepared)
      ~effect_before:Active_record_durable
      ~removal_transition:Discharge_active;
    observed_effect := Active_record_discharged;
    Discharged
  | _ -> raise_existing_record_mismatch ~store ~area:Active ~operation_id
;;

let discharge_bound ~(store : store) ~(bound : bound) =
  let prepared = bound.prepared in
  let operation_id = prepared.operation_id in
  run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
  ensure_input_owner ~store ~operation_id prepared.owner;
  match record_kind ~store ~area:Owned ~operation_id with
  | `Not_found ->
    observed_effect :=
      Source_removal_durability_unknown Discharge_owned;
    sync_directory
      ~subject:(Area (Owned, store.owner))
      (area_directory store Owned);
    observed_effect := Owned_record_discharged;
    Already_discharged
  | `Regular_file ->
    observed_effect := Owned_record_durable;
    remove_exact_source
      ~store
      ~area:Owned
      ~operation_id
      ~expected_raw:(encode_bound bound)
      ~effect_before:Owned_record_durable
      ~removal_transition:Discharge_owned;
    observed_effect := Owned_record_discharged;
    Discharged
  | _ -> raise_existing_record_mismatch ~store ~area:Owned ~operation_id
;;

type forensic_transition_source =
  | Active_forensic_source
  | Owned_forensic_source

let transition_to_forensic
      ~store
      ~operation_id
      ~source
      ~source_raw
      ~forensic
  =
  let forensic_raw = encode_forensic forensic in
  let source_area, source_effect, removal_transition =
    match source with
    | Active_forensic_source ->
      Active, Active_record_durable, Active_to_forensic
    | Owned_forensic_source ->
      Owned, Owned_record_durable, Owned_to_forensic
  in
  run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
  (match record_kind ~store ~area:source_area ~operation_id with
   | `Not_found ->
     (match record_kind ~store ~area:Forensic ~operation_id with
      | `Regular_file ->
        ignore
          (verify_exact_source
             ~store
             ~area:Forensic
             ~operation_id
             ~expected_raw:forensic_raw
             ~store_effect:Forensic_record_durable);
        (* See [bind]: source removal follows the durable destination barrier,
           so the exact resumed state is known before barrier repair. *)
        observed_effect :=
          Source_removal_durability_unknown removal_transition;
        sync_directory
          ~subject:(Area (Forensic, store.owner))
          (area_directory store Forensic);
        sync_directory
          ~subject:(Area (source_area, store.owner))
          (area_directory store source_area);
        observed_effect := Forensic_record_durable
      | `Not_found ->
        raise_missing_record ~store ~area:source_area ~operation_id
      | _ ->
        raise_existing_record_mismatch ~store ~area:Forensic ~operation_id)
   | `Regular_file ->
     ignore
       (verify_exact_source
          ~store
          ~area:source_area
          ~operation_id
          ~expected_raw:source_raw
          ~store_effect:source_effect);
     observed_effect := source_effect;
     ignore
       (ensure_exact_record
          ~store
          ~area:Forensic
          ~operation_id
          ~raw:forensic_raw
          ~base_effect:source_effect
          ~success_effect:Forensic_record_durable_with_source
          ~unknown_effect:Forensic_record_state_unknown_with_source);
     observed_effect := Forensic_record_durable_with_source;
     remove_exact_source
       ~store
       ~area:source_area
       ~operation_id
       ~expected_raw:source_raw
       ~effect_before:Forensic_record_durable_with_source
       ~removal_transition;
     observed_effect := Forensic_record_durable
   | _ ->
     raise_existing_record_mismatch ~store ~area:source_area ~operation_id);
  forensic
;;

let record_forensic_prepared
      ~(store : store)
      ~(prepared : prepared)
      ~outcome
  =
  let operation_id = prepared.operation_id in
  match
    protect_result ~store_effect:No_record_change (fun () ->
      ensure_input_owner ~store ~operation_id prepared.owner;
      match validate_prepared_recovery_outcome prepared outcome with
      | Ok () -> ()
      | Error error ->
        raise_validation
          ~operation:Decode_record
          ~subject:(Record (Forensic, store.owner, operation_id))
          error)
  with
  | Error _ as error -> error
  | Ok () ->
    let forensic = { source = Prepared_source (prepared, outcome) } in
    transition_to_forensic
      ~store
      ~operation_id
      ~source:Active_forensic_source
      ~source_raw:(encode_prepared prepared)
      ~forensic
;;

let preserve_unbound
      ~(store : store)
      ~(prepared : prepared)
      ~kind
      ~stage_identity
  =
  record_forensic_prepared
    ~store
    ~prepared
    ~outcome:(Preserved_unbound_stage { kind; identity = stage_identity })
;;

let record_forensic_bound ~(store : store) ~(bound : bound) ~outcome =
  let prepared = bound.prepared in
  let operation_id = prepared.operation_id in
  match
    protect_result ~store_effect:No_record_change (fun () ->
      ensure_input_owner ~store ~operation_id prepared.owner;
      match validate_bound_recovery_outcome bound outcome with
      | Ok () -> ()
      | Error error ->
        raise_validation
          ~operation:Decode_record
          ~subject:(Record (Forensic, store.owner, operation_id))
          error)
  with
  | Error _ as error -> error
  | Ok () ->
    let forensic = { source = Bound_source (bound, outcome) } in
    transition_to_forensic
      ~store
      ~operation_id
      ~source:Owned_forensic_source
      ~source_raw:(encode_bound bound)
      ~forensic
;;

module For_testing = struct
  type nonrec discharge_record = discharge_record = Prepared_record | Bound_record
  type nonrec discharge_cancellation = discharge_cancellation

  let discharge_cancellation ~owner ~record ~reason ~backtrace =
    match owner_of_string owner with
    | Error _ as error -> error
    | Ok discharge_owner ->
      let discharge_transition = match record with
        | Prepared_record -> Discharge_active
        | Bound_record -> Discharge_owned
      in
      Ok { discharge_owner; discharge_transition;
           discharge_reason = reason; discharge_backtrace = backtrace }
  ;;

  let with_discharge_cancellation fault f =
    Eio.Fiber.with_binding discharge_cancellation_key fault f
  ;;

  type nonrec lane_scope_release_fault = lane_scope_release_fault

  let lane_scope_release_fault ~owner ~exception_ =
    match owner_of_string owner with
    | Error _ as error -> error
    | Ok fault_owner -> Ok { fault_owner; fault_exception = exception_ }
  ;;

  let with_lane_scope_release_fault fault f =
    Eio.Fiber.with_binding lane_scope_release_fault_key fault f
  ;;

  let operation_id_of_uuid operation_id = operation_id

  let prepare_with_operation_id
        ~(store : store)
        ~operation_id
        ~publication
        ~(locator : locator)
        ~(permissions : permissions)
    =
    run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
    let prepared =
      prepare_with_operation_id_internal
        ~store
        ~operation_id
        ~publication
        ~locator
        ~permissions
    in
    observed_effect := Active_record_durable;
    prepared
  ;;

  let area_directory = area_directory
end

