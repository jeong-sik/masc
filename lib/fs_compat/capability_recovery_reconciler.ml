(* Four modules are included here. [Capability_recovery_reconciler_model] is
   the reconciliation vocabulary,
   [Capability_recovery_reconciler_observation] the filesystem observations,
   [Capability_recovery_reconciler_text] the text form of a report, and
   [Capability_recovery_reconciler_json] its JSON form. *)
include Capability_recovery_reconciler_model
include Capability_recovery_reconciler_observation
include Capability_recovery_reconciler_text
include Capability_recovery_reconciler_json

let sha256 raw = Agent_core_sha256.(digest_string raw |> to_hex)

let digest_json json =
  let canonical = json |> Yojson.Safe.sort |> Yojson.Safe.to_string in
  { canonical_json_byte_count = String.length canonical
  ; canonical_json_sha256 = sha256 canonical
  }
;;

let digest_payload kind json =
  { kind; payload = Some (digest_json json) }
;;

let no_payload kind = { kind; payload = None }

let core_identity_json identity =
  `Assoc
    [ "device", `Intlit (Int64.to_string (Core.identity_dev identity))
    ; "inode", `Intlit (Int64.to_string (Core.identity_ino identity))
    ]
;;

let core_kind_json kind =
  `String (Format.asprintf "%a" Eio.File.Stat.pp_kind kind)
;;

let safe_validation_error = function
  | Core.Invalid_owner value ->
    digest_payload Corrupt_invalid_owner (`String value)
  | Core.Invalid_operation_id value ->
    digest_payload Corrupt_invalid_operation_id (`String value)
  | Core.Invalid_identity identity ->
    digest_payload Corrupt_invalid_identity (core_identity_json identity)
  | Core.Invalid_allowed_root_path value ->
    digest_payload Corrupt_invalid_allowed_root_path (`String value)
  | Core.Empty_parent_path_identity_mismatch { allowed_root; parent } ->
    digest_payload
      Corrupt_empty_parent_path_identity_mismatch
      (`Assoc
         [ "allowed_root", core_identity_json allowed_root
         ; "parent", core_identity_json parent
         ])
  | Core.Invalid_parent_component { index; value } ->
    digest_payload
      Corrupt_invalid_parent_component
      (`Assoc [ "index", `Int index; "value", `String value ])
  | Core.Invalid_target_leaf value ->
    digest_payload Corrupt_invalid_target_leaf (`String value)
  | Core.Invalid_permissions permissions ->
    digest_payload Corrupt_invalid_permissions (`Int permissions)
  | Core.Invalid_record_json { exception_; backtrace } ->
    digest_payload
      Corrupt_invalid_record_json
      (`Assoc
         [ "exception", `String (Printexc.to_string exception_)
         ; "backtrace", `String (Printexc.raw_backtrace_to_string backtrace)
         ])
  | Core.Invalid_record_shape -> no_payload Corrupt_invalid_record_shape
  | Core.Unsupported_record_version version ->
    digest_payload Corrupt_unsupported_record_version (`Int version)
  | Core.Record_state_mismatch -> no_payload Corrupt_record_state_mismatch
  | Core.Record_owner_mismatch { expected; actual } ->
    digest_payload
      Corrupt_record_owner_mismatch
      (`Assoc
         [ "expected", `String (Core.owner_to_string expected)
         ; "actual", `String (Core.owner_to_string actual)
         ])
  | Core.Record_operation_id_mismatch { expected; actual } ->
    digest_payload
      Corrupt_record_operation_id_mismatch
      (`Assoc
         [ "expected", `String (Core.operation_id_to_string expected)
         ; "actual", `String (Core.operation_id_to_string actual)
         ])
  | Core.Record_stage_leaf_mismatch { expected; actual } ->
    digest_payload
      Corrupt_record_stage_leaf_mismatch
      (`Assoc [ "expected", `String expected; "actual", `String actual ])
  | Core.Record_identity_mismatch { expected; actual } ->
    digest_payload
      Corrupt_record_identity_mismatch
      (`Assoc
         [ "expected", core_identity_json expected
         ; "actual", core_identity_json actual
         ])
  | Core.Record_kind_mismatch { expected; actual } ->
    digest_payload
      Corrupt_record_kind_mismatch
      (`Assoc
         [ "expected", core_kind_json expected
         ; "actual", core_kind_json actual
         ])
  | Core.Record_permissions_mismatch { expected; actual } ->
    digest_payload
      Corrupt_record_permissions_mismatch
      (`Assoc [ "expected", `Int expected; "actual", `Int actual ])
  | Core.Record_outcome_observation_not_mismatch identity ->
    digest_payload
      Corrupt_record_outcome_observation_not_mismatch
      (core_identity_json identity)
  | Core.Record_field_invalid { field; value } ->
    digest_payload
      Corrupt_record_field_invalid
      (`Assoc [ "field", `String field; "value", value ])
;;

let core_cleanup_failures failures =
  List.map (fun failure -> Core_cleanup_failure failure) failures
;;

let scope_release_failure
      scope
      ({ exception_; backtrace } : Resource_scope.raised)
  =
  Scope_release_failure { scope; exception_; backtrace }
;;

let core_scope_release_failure scope
      ({ exception_; backtrace; _ } : Core.resource_release_failure)
  =
  Scope_release_failure { scope; exception_; backtrace }
;;

let rec normalize_cancellation
          ~owner
          ~backtrace
          ~default_effect
          reason
  =
  match reason with
  | Reconciliation_cancelled cancellation -> cancellation
  | Core.Recovery_store_cancelled
      (original_reason, interrupted_store_effect, cleanup_failures) ->
    let cancellation =
      normalize_cancellation
        ~owner
        ~backtrace
        ~default_effect:interrupted_store_effect
        original_reason
    in
    { cancellation with
      cleanup_failures =
        cancellation.cleanup_failures
        @ core_cleanup_failures cleanup_failures
    }
  | original_reason ->
    { original_reason
    ; original_backtrace = backtrace
    ; owner
    ; completed_rows = []
    ; interrupted_store_effect = default_effect
    ; cleanup_failures = []
    }
;;

let raise_reconciliation_cancellation
      ~owner
      ~completed_rows
      ~default_effect
      ~cleanup_failures
      ({ reason; backtrace } : Resource_scope.cancelled)
  =
  let cancellation =
    normalize_cancellation ~owner ~backtrace ~default_effect reason
  in
  let cancellation =
    { cancellation with
      owner
    ; completed_rows = completed_rows @ cancellation.completed_rows
    ; cleanup_failures =
        cancellation.cleanup_failures @ cleanup_failures
    }
  in
  Printexc.raise_with_backtrace
    (Eio.Cancel.Cancelled (Reconciliation_cancelled cancellation))
    backtrace
;;

let record_transition_failure ~source_state ~operation_id error =
  Record_transition_failed
    { source_state
    ; operation_id = Core.operation_id_to_string operation_id
    ; error
    }
;;

let record_observation_failure ~source_state ~operation_id failure =
  Record_observation_failed
    { source_state
    ; operation_id = Core.operation_id_to_string operation_id
    ; failure
    }
;;

let release_failure_row ~source_state ~operation_id failure =
  Record_scope_release_failed { source_state; operation_id; failure }
;;

let run_record_scope
      ~store
      ~source_state
      ~operation_id
      reconcile
  =
  let owner = Core.store_owner store |> Core.owner_to_string in
  let operation_id_string = Core.operation_id_to_string operation_id in
  let scope =
    Record_scope { source_state; operation_id = operation_id_string }
  in
  let outcome =
    Resource_scope.run_resource_only @@ fun sw ->
    reconcile sw
  in
  let release_failure =
    Option.map (scope_release_failure scope) outcome.scope_failure
  in
  let cleanup_failures = Option.to_list release_failure in
  match outcome.callback with
  | None ->
    (match outcome.parent_cancellation with
     | Some cancellation ->
       raise_reconciliation_cancellation
         ~owner
         ~completed_rows:[]
         ~default_effect:Core.No_record_change
         ~cleanup_failures:[]
         cancellation
     | None ->
       (match outcome.scope_failure with
        | Some failure ->
          Printexc.raise_with_backtrace failure.exception_ failure.backtrace
        | None ->
          raise Internal_resource_scope_callback_not_entered))
  | Some (Resource_scope.Cancelled cancellation) ->
    raise_reconciliation_cancellation
      ~owner
      ~completed_rows:[]
      ~default_effect:Core.No_record_change
      ~cleanup_failures
      cancellation
  | Some (Resource_scope.Raised failure) ->
    (* A release failure alongside the callback exception has no typed home
       here. The callback exception continues with its own backtrace. *)
    Printexc.raise_with_backtrace failure.exception_ failure.backtrace
  | Some (Resource_scope.Returned row) ->
    (match outcome.parent_cancellation with
     | Some cancellation ->
       raise_reconciliation_cancellation
         ~owner
         ~completed_rows:[ row ]
         ~default_effect:Core.No_record_change
         ~cleanup_failures
         cancellation
     | None ->
       (match release_failure with
        | None -> [ row ]
        | Some failure ->
          [ row
          ; release_failure_row
              ~source_state
              ~operation_id:operation_id_string
              failure
          ]))
;;

let reconcile_prepared ~fs ~store prepared =
  let operation_id = Core.prepared_operation_id prepared in
  let operation_id_string = Core.operation_id_to_string operation_id in
  let locator = Core.prepared_locator prepared in
  run_record_scope
    ~store
    ~source_state:Prepared
    ~operation_id
  @@ fun sw ->
  match traverse_parent ~sw ~fs locator with
  | Error failure ->
    record_observation_failure ~source_state:Prepared ~operation_id failure
  | Ok (Allowed_root_mismatch mismatch) ->
    let outcome = Core.Prepared_allowed_root_mismatch mismatch.core in
    (match Core.record_forensic_prepared ~store ~prepared ~outcome with
     | Ok _ ->
       Prepared_reconciled
         { operation_id = operation_id_string
         ; outcome = Prepared_allowed_root_mismatch mismatch.public
         }
     | Error error ->
       record_transition_failure ~source_state:Prepared ~operation_id error)
  | Ok (Parent_mismatch mismatch) ->
    let outcome = Core.Prepared_parent_mismatch mismatch.core in
    (match Core.record_forensic_prepared ~store ~prepared ~outcome with
     | Ok _ ->
       Prepared_reconciled
         { operation_id = operation_id_string
         ; outcome = Prepared_parent_mismatch mismatch.public
         }
     | Error error ->
       record_transition_failure ~source_state:Prepared ~operation_id error)
  | Ok (Parent_opened parent) ->
    let stage_name = Core.stage_name operation_id in
    let subject = Stage_leaf stage_name in
    let stage = Eio.Path.(parent / stage_name) in
    (match observe_entry ~subject stage with
     | Error failure ->
       record_observation_failure ~source_state:Prepared ~operation_id failure
     | Ok { core = Core.Absent; _ } ->
       (match
          Core.record_forensic_prepared
            ~store
            ~prepared
            ~outcome:Core.Recovered_unmaterialized
        with
        | Ok _ ->
          Prepared_reconciled
            { operation_id = operation_id_string
            ; outcome = Prepared_unmaterialized
            }
        | Error error ->
          record_transition_failure
            ~source_state:Prepared
            ~operation_id
            error)
     | Ok
         { core = Core.Present { kind; identity }; public = _ } ->
       let outcome = Core.Preserved_unbound_stage { kind; identity } in
       (match Core.record_forensic_prepared ~store ~prepared ~outcome with
        | Ok _ ->
          Prepared_reconciled
            { operation_id = operation_id_string
            ; outcome =
                Prepared_unbound_stage_preserved
                  { kind; identity = identity_of_core identity }
            }
        | Error error ->
          record_transition_failure
            ~source_state:Prepared
            ~operation_id
            error)
     )
;;

let reconcile_bound ~fs ~store bound =
  let prepared = Core.bound_prepared bound in
  let operation_id = Core.prepared_operation_id prepared in
  let operation_id_string = Core.operation_id_to_string operation_id in
  let locator = Core.prepared_locator prepared in
  run_record_scope
    ~store
    ~source_state:Bound
    ~operation_id
  @@ fun sw ->
  match traverse_parent ~sw ~fs locator with
  | Error failure ->
    record_observation_failure ~source_state:Bound ~operation_id failure
  | Ok (Allowed_root_mismatch mismatch) ->
    let outcome = Core.Bound_allowed_root_mismatch mismatch.core in
    (match Core.record_forensic_bound ~store ~bound ~outcome with
     | Ok _ ->
       Bound_reconciled
         { operation_id = operation_id_string
         ; outcome = Bound_allowed_root_mismatch mismatch.public
         }
     | Error error ->
       record_transition_failure ~source_state:Bound ~operation_id error)
  | Ok (Parent_mismatch mismatch) ->
    let outcome = Core.Bound_parent_mismatch mismatch.core in
    (match Core.record_forensic_bound ~store ~bound ~outcome with
     | Ok _ ->
       Bound_reconciled
         { operation_id = operation_id_string
         ; outcome = Bound_parent_mismatch mismatch.public
         }
     | Error error ->
       record_transition_failure ~source_state:Bound ~operation_id error)
  | Ok (Parent_opened parent) ->
    let stage_name = Core.bound_stage_name bound in
    let target_name = Capability_leaf.to_string (Core.locator_target_leaf locator) in
    let stage_subject = Stage_leaf stage_name in
    let target_subject = Target_leaf target_name in
    let stage = observe_entry ~subject:stage_subject Eio.Path.(parent / stage_name) in
    let target = observe_entry ~subject:target_subject Eio.Path.(parent / target_name) in
    (match stage, target with
     | Error failure, _ | _, Error failure ->
       record_observation_failure ~source_state:Bound ~operation_id failure
     | Ok stage, Ok target ->
       let core_outcome, public_outcome =
         match stage.core with
         | Core.Absent ->
           ( Core.Bound_stage_absent { observed_target = target.core }
           , Bound_stage_absent { observed_target = target.public } )
         | Core.Present { kind; identity } ->
           if
             kind = `Directory
             && Core.equal_identity identity (Core.bound_stage_identity bound)
           then
             ( Core.Preserved_bound_stage
                 { kind; identity; observed_target = target.core }
             , Bound_stage_preserved
                 { kind
                 ; identity = identity_of_core identity
                 ; observed_target = target.public
                 } )
           else
             let mismatch =
               mismatch ~expected:(Core.bound_stage_identity bound) stage
             in
             ( Core.Bound_stage_mismatch
                 { mismatch = mismatch.core; observed_target = target.core }
             , Bound_stage_mismatch
                 { mismatch = mismatch.public
                 ; observed_target = target.public
                 } )
       in
       (match Core.record_forensic_bound ~store ~bound ~outcome:core_outcome with
        | Ok _ ->
          Bound_reconciled
            { operation_id = operation_id_string; outcome = public_outcome }
        | Error error ->
          record_transition_failure ~source_state:Bound ~operation_id error))
;;

let record_area_of_core = function
  | Core.Active -> Active
  | Core.Owned -> Owned
  | Core.Forensic -> Forensic
;;

let operation_id_of_inventory_row = function
  | Core.Unexpected_lane_entry _
  | Core.Missing_lane_entry _
  | Core.Lane_entry_unavailable _
  | Core.Area_inventory_unavailable _ -> None
  | Core.Active_record prepared ->
    Some (Core.prepared_operation_id prepared, Active)
  | Core.Owned_record bound ->
    Some
      ( Core.prepared_operation_id (Core.bound_prepared bound)
      , Owned )
  | Core.Forensic_record _ | Core.Invalid_record_name _ -> None
  | Core.Unexpected_record_kind { area; operation_id; _ }
  | Core.Missing_record_entry { area; operation_id }
  | Core.Record_entry_unavailable { area; operation_id; _ } ->
    Some (operation_id, record_area_of_core area)
  | Core.Corrupt_record corrupt ->
    Some (corrupt.operation_id, record_area_of_core corrupt.area)
;;

module Operation_map = Map.Make (String)

let conflicting_source_areas inventory =
  let add map row =
    match operation_id_of_inventory_row row with
    | None -> map
    | Some (_, Forensic) -> map
    | Some (operation_id, (Active as area))
    | Some (operation_id, (Owned as area)) ->
      let key = Core.operation_id_to_string operation_id in
      let areas = Option.value ~default:[] (Operation_map.find_opt key map) in
      Operation_map.add key (area :: areas) map
  in
  List.fold_left add Operation_map.empty inventory
  |> Operation_map.filter (fun _ areas -> List.length areas > 1)
  |> Operation_map.map List.rev
;;

let area_inventory_failures inventory =
  List.filter_map
    (function
      | Core.Area_inventory_unavailable { area; error } ->
        Some (record_area_of_core area, error)
      | Core.Unexpected_lane_entry _
      | Core.Missing_lane_entry _
      | Core.Lane_entry_unavailable _
      | Core.Active_record _
      | Core.Owned_record _
      | Core.Forensic_record _
      | Core.Invalid_record_name _
      | Core.Unexpected_record_kind _
      | Core.Missing_record_entry _
      | Core.Record_entry_unavailable _
      | Core.Corrupt_record _ -> None)
    inventory
;;

let required_area_failures required failures =
  List.filter
    (fun (area, _) -> List.exists (fun required -> required = area) required)
    failures
;;

let source_transition_capabilities_unavailable
      ~source_state
      ~operation_id
      ~required
      ~area_failures
  =
  match required_area_failures required area_failures with
  | [] -> None
  | area_failures ->
    Some
      (Source_transition_capabilities_unavailable
         { source_state; operation_id; area_failures })
;;

let row_of_inventory ~fs ~store ~conflicts ~area_failures = function
  | Core.Unexpected_lane_entry { name; kind } ->
    [ Unexpected_lane_entry { name; kind } ]
  | Core.Missing_lane_entry { name } -> [ Missing_lane_entry { name } ]
  | Core.Lane_entry_unavailable { name; error } ->
    [ Lane_entry_unavailable { name; error } ]
  | Core.Area_inventory_unavailable { area; error } ->
    [ Area_inventory_unavailable { area = record_area_of_core area; error } ]
  | Core.Active_record prepared ->
    let operation_id =
      Core.prepared_operation_id prepared |> Core.operation_id_to_string
    in
    (match Operation_map.find_opt operation_id conflicts with
     | Some areas -> [ Conflicting_source_records { operation_id; areas } ]
     | None ->
       (match
          source_transition_capabilities_unavailable
            ~source_state:Prepared
            ~operation_id
            ~required:[ Active; Owned; Forensic ]
            ~area_failures
        with
        | Some row -> [ row ]
        | None -> reconcile_prepared ~fs ~store prepared))
  | Core.Owned_record bound ->
    let operation_id =
      Core.bound_prepared bound
      |> Core.prepared_operation_id
      |> Core.operation_id_to_string
    in
    (match Operation_map.find_opt operation_id conflicts with
     | Some areas -> [ Conflicting_source_records { operation_id; areas } ]
     | None ->
       (match
          source_transition_capabilities_unavailable
            ~source_state:Bound
            ~operation_id
            ~required:[ Active; Owned; Forensic ]
            ~area_failures
        with
        | Some row -> [ row ]
        | None -> reconcile_bound ~fs ~store bound))
  | Core.Forensic_record forensic ->
    let source_state =
      match Core.forensic_source forensic with
      | Core.Prepared_source _ -> Prepared
      | Core.Bound_source _ -> Bound
    in
    [ Existing_forensic_record
        { operation_id =
            Core.forensic_operation_id forensic |> Core.operation_id_to_string
        ; source_state
        }
    ]
  | Core.Invalid_record_name { area; name } ->
    [ Invalid_record_name { area = record_area_of_core area; name } ]
  | Core.Unexpected_record_kind { area; operation_id; kind } ->
    [ Unexpected_record_kind
        { area = record_area_of_core area
        ; operation_id = Core.operation_id_to_string operation_id
        ; kind
        }
    ]
  | Core.Missing_record_entry { area; operation_id } ->
    [ Missing_record_entry
        { area = record_area_of_core area
        ; operation_id = Core.operation_id_to_string operation_id
        }
    ]
  | Core.Record_entry_unavailable { area; operation_id; error } ->
    [ Record_entry_unavailable
        { area = record_area_of_core area
        ; operation_id = Core.operation_id_to_string operation_id
        ; error
        }
    ]
  | Core.Corrupt_record corrupt ->
    [ Corrupt_record_preserved
        { area = record_area_of_core corrupt.area
        ; operation_id = Core.operation_id_to_string corrupt.operation_id
        ; raw_byte_count = String.length corrupt.raw
        ; raw_sha256 = sha256 corrupt.raw
        ; validation_error = safe_validation_error corrupt.validation_error
        }
    ]
;;

let reconcile_inventory_rows ~fs ~store ~owner inventory =
  let conflicts = conflicting_source_areas inventory in
  let area_failures = area_inventory_failures inventory in
  let rec loop completed = function
    | [] -> List.rev completed
    | inventory_row :: rest ->
      (try
         let rows =
           row_of_inventory
             ~fs
             ~store
             ~conflicts
             ~area_failures
             inventory_row
         in
         loop (List.rev_append rows completed) rest
       with
       | Eio.Cancel.Cancelled reason ->
         let backtrace = Printexc.get_raw_backtrace () in
         raise_reconciliation_cancellation
           ~owner
           ~completed_rows:(List.rev completed)
           ~default_effect:Core.No_record_change
           ~cleanup_failures:[]
           { reason; backtrace })
  in
  loop [] inventory
;;

let reconcile_owner ~fs ~registry ~owner =
  let owner_name = Core.owner_to_string owner in
  match
    Core.with_existing_store ~registry ~owner (fun store ->
      match Core.inventory store with
      | Error error -> [ Owner_inventory_unavailable error ]
      | Ok inventory ->
        reconcile_inventory_rows ~fs ~store ~owner:owner_name inventory)
  with
  | Ok (Core.Existing_store_scope_released rows) ->
    { owner = owner_name; rows }
  | Ok
      (Core.Existing_store_scope_release_failed
        { value = rows; release_failure }) ->
    let failure =
      core_scope_release_failure Owner_store_scope release_failure
    in
    { owner = owner_name; rows = rows @ [ Owner_store_release_failed failure ] }
  | Ok
      (Core.Existing_store_scope_cancelled
        { value; reason; backtrace; release_failure }) ->
    let cleanup_failures =
      release_failure
      |> Option.map (core_scope_release_failure Owner_store_scope)
      |> Option.to_list
    in
    raise_reconciliation_cancellation
      ~owner:owner_name
      ~completed_rows:(Option.value ~default:[] value)
      ~default_effect:Core.No_record_change
      ~cleanup_failures
      { reason; backtrace }
  | Error error -> { owner = owner_name; rows = [ Owner_store_unavailable error ] }
;;

module For_testing = struct
  type resource_scope_callback =
    | Return_completed_rows of string list
    | Cancel_callback of exn

  type resource_scope_evidence =
    | Returned_rows of
        { completed_rows : string list
        ; release_failure : exn option
        }
    | Cancelled_callback of
        { reason : exn
        ; release_failure : exn option
        }
    | Raised_callback of
        { exception_ : exn
        ; release_failure : exn option
        }

  let run_resource_scope ~callback ~release_failure =
    let outcome =
      Resource_scope.run_resource_only @@ fun sw ->
      Option.iter
        (fun exception_ ->
           Resource_scope.on_release sw (fun () -> raise exception_))
        release_failure;
      match callback with
      | Return_completed_rows rows -> rows
      | Cancel_callback reason -> raise (Eio.Cancel.Cancelled reason)
    in
    let release_failure =
      Option.map
        (fun (failure : Resource_scope.raised) -> failure.exception_)
        outcome.scope_failure
    in
    match outcome.callback with
    | Some (Resource_scope.Returned completed_rows) ->
      Returned_rows { completed_rows; release_failure }
    | Some (Resource_scope.Cancelled { reason; _ }) ->
      Cancelled_callback { reason; release_failure }
    | Some (Resource_scope.Raised { exception_; _ }) ->
      Raised_callback { exception_; release_failure }
    | None ->
      (match outcome.parent_cancellation with
       | Some { reason; _ } -> Cancelled_callback { reason; release_failure }
       | None ->
         (match outcome.scope_failure with
          | Some { exception_; _ } ->
            Raised_callback { exception_; release_failure = None }
          | None ->
            Raised_callback
              { exception_ = Internal_resource_scope_callback_not_entered
              ; release_failure = None
              }))
  ;;
end
