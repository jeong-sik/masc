module Core = Capability_recovery_obligation
module Resource_scope = Eio_resource_scope

type identity =
  { device : int64
  ; inode : int64
  }

type entry_observation =
  | Entry_absent
  | Entry_present of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      }

type resource_mismatch =
  { expected : identity
  ; observed : entry_observation
  }

type prepared_outcome =
  | Prepared_unmaterialized
  | Prepared_allowed_root_mismatch of resource_mismatch
  | Prepared_parent_mismatch of resource_mismatch
  | Prepared_unbound_stage_preserved of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      }

type bound_outcome =
  | Bound_stage_absent of { observed_target : entry_observation }
  | Bound_allowed_root_mismatch of resource_mismatch
  | Bound_parent_mismatch of resource_mismatch
  | Bound_stage_mismatch of
      { mismatch : resource_mismatch
      ; observed_target : entry_observation
      }
  | Bound_stage_preserved of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      ; observed_target : entry_observation
      }

type record_area =
  | Active
  | Owned
  | Forensic

type source_state =
  | Prepared
  | Bound

type release_scope =
  | Owner_store_scope
  | Record_scope of
      { source_state : source_state
      ; operation_id : string
      }

type cleanup_failure =
  | Core_cleanup_failure of Core.failure
  | Scope_release_failure of
      { scope : release_scope
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }

type observation_subject =
  | Allowed_root of string
  | Parent_component of
      { index : int
      ; component : string
      }
  | Stage_leaf of string
  | Target_leaf of string

type observation_cause =
  | Observation_io_failed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Observation_identity_invalid of Core.validation_error
  | Opened_resource_kind_changed of
      { observed : Eio.File.Stat.kind
      ; opened : Eio.File.Stat.kind
      }
  | Opened_resource_identity_changed of
      { observed : identity
      ; opened : identity
      }

type observation_failure =
  { subject : observation_subject
  ; cause : observation_cause
  }

type digest_evidence =
  { canonical_json_byte_count : int
  ; canonical_json_sha256 : string
  }

type corrupt_validation_error_kind =
  | Corrupt_invalid_owner
  | Corrupt_invalid_operation_id
  | Corrupt_invalid_identity
  | Corrupt_invalid_allowed_root_path
  | Corrupt_empty_parent_path_identity_mismatch
  | Corrupt_invalid_parent_component
  | Corrupt_invalid_target_leaf
  | Corrupt_invalid_permissions
  | Corrupt_invalid_record_json
  | Corrupt_invalid_record_shape
  | Corrupt_unsupported_record_version
  | Corrupt_record_state_mismatch
  | Corrupt_record_owner_mismatch
  | Corrupt_record_operation_id_mismatch
  | Corrupt_record_stage_leaf_mismatch
  | Corrupt_record_identity_mismatch
  | Corrupt_record_kind_mismatch
  | Corrupt_record_permissions_mismatch
  | Corrupt_record_outcome_observation_not_mismatch
  | Corrupt_record_field_invalid

type corrupt_validation_error =
  { kind : corrupt_validation_error_kind
  ; payload : digest_evidence option
  }

type row =
  | Unexpected_lane_entry of
      { name : string
      ; kind : Eio.File.Stat.kind
      }
  | Missing_lane_entry of { name : string }
  | Lane_entry_unavailable of
      { name : string
      ; error : Core.transition_error
      }
  | Area_inventory_unavailable of
      { area : record_area
      ; error : Core.transition_error
      }
  | Source_transition_capabilities_unavailable of
      { source_state : source_state
      ; operation_id : string
      ; area_failures : (record_area * Core.transition_error) list
      }
  | Prepared_reconciled of
      { operation_id : string
      ; outcome : prepared_outcome
      }
  | Bound_reconciled of
      { operation_id : string
      ; outcome : bound_outcome
      }
  | Existing_forensic_record of
      { operation_id : string
      ; source_state : source_state
      }
  | Conflicting_source_records of
      { operation_id : string
      ; areas : record_area list
      }
  | Invalid_record_name of
      { area : record_area
      ; name : string
      }
  | Unexpected_record_kind of
      { area : record_area
      ; operation_id : string
      ; kind : Eio.File.Stat.kind
      }
  | Missing_record_entry of
      { area : record_area
      ; operation_id : string
      }
  | Record_entry_unavailable of
      { area : record_area
      ; operation_id : string
      ; error : Core.transition_error
      }
  | Corrupt_record_preserved of
      { area : record_area
      ; operation_id : string
      ; raw_byte_count : int
      ; raw_sha256 : string
      ; validation_error : corrupt_validation_error
      }
  | Record_observation_failed of
      { source_state : source_state
      ; operation_id : string
      ; failure : observation_failure
      }
  | Record_transition_failed of
      { source_state : source_state
      ; operation_id : string
      ; error : Core.transition_error
      }
  | Record_scope_release_failed of
      { source_state : source_state
      ; operation_id : string
      ; failure : cleanup_failure
      }
  | Owner_store_release_failed of cleanup_failure
  | Owner_store_unavailable of Core.transition_error
  | Owner_inventory_unavailable of Core.transition_error

type cancellation =
  { original_reason : exn
  ; original_backtrace : Printexc.raw_backtrace
  ; owner : string
  ; completed_rows : row list
  ; interrupted_store_effect : Core.transition_effect
  ; cleanup_failures : cleanup_failure list
  }

exception Reconciliation_cancelled of cancellation
exception Internal_resource_scope_callback_not_entered

type record_scope_callback_and_release_failure =
  { callback : Eio.Exn.with_bt
  ; release : cleanup_failure
  }

exception Record_scope_callback_and_release_failed of
  record_scope_callback_and_release_failure

type report =
  { owner : string
  ; rows : row list
  }

let sha256 raw = Digestif.SHA256.(digest_string raw |> to_hex)

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

type observed_entry =
  { core : Core.entry_observation
  ; public : entry_observation
  }

type stable_directory = Eio.Fs.dir_ty Eio.Path.t

type typed_mismatch =
  { core : Core.resource_mismatch
  ; public : resource_mismatch
  }

type directory_result =
  | Directory_mismatch of typed_mismatch
  | Directory_opened of stable_directory

type parent_result =
  | Allowed_root_mismatch of typed_mismatch
  | Parent_mismatch of typed_mismatch
  | Parent_opened of stable_directory

let identity_of_core identity =
  { device = Core.identity_dev identity; inode = Core.identity_ino identity }
;;

let core_identity_of_stat ~subject (stat : Eio.File.Stat.t) =
  match Core.identity ~dev:stat.dev ~ino:stat.ino with
  | Ok identity -> Ok identity
  | Error error ->
    Error { subject; cause = Observation_identity_invalid error }
;;

let observation_of_stat ~subject stat : (observed_entry, observation_failure) result =
  match core_identity_of_stat ~subject stat with
  | Error _ as error -> error
  | Ok identity ->
    Ok
      { core = Core.Present { kind = stat.kind; identity }
      ; public =
          Entry_present
            { kind = stat.kind; identity = identity_of_core identity }
      }
;;

let absent_observation : observed_entry =
  { core = Core.Absent; public = Entry_absent }
;;

let capture_observation ~subject operation =
  try Ok (operation ()) with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Error
      { subject
      ; cause = Observation_io_failed { exception_; backtrace }
      }
;;

let observe_stat ~subject path =
  match
    capture_observation ~subject (fun () ->
      try Some (Eio.Path.stat ~follow:false path) with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> None)
  with
  | Error _ as error -> error
  | Ok observation -> Ok observation
;;

let observe_entry ~subject path =
  match observe_stat ~subject path with
  | Error _ as error -> error
  | Ok None -> Ok absent_observation
  | Ok (Some stat) -> observation_of_stat ~subject stat
;;

let mismatch ~expected (observed : observed_entry) : typed_mismatch =
  let core : Core.resource_mismatch =
    { expected; observed = observed.core }
  in
  { core
  ; public = { expected = identity_of_core expected; observed = observed.public }
  }
;;

let validate_opened_directory
      ~sw
      ~subject
      ~path
      ~(observed_stat : Eio.File.Stat.t)
  =
  match
    capture_observation ~subject (fun () ->
      let directory = Eio.Path.open_dir ~sw path in
      let directory = (directory :> Eio.Fs.dir_ty Eio.Path.t) in
      let opened_file = Eio.Path.open_in ~sw Eio.Path.(directory / ".") in
      directory, Eio.File.stat opened_file)
  with
  | Error _ as error -> error
  | Ok (directory, opened_stat) ->
    if opened_stat.kind <> `Directory
    then
      Error
        { subject
        ; cause =
            Opened_resource_kind_changed
              { observed = observed_stat.kind; opened = opened_stat.kind }
        }
    else
      (match
         core_identity_of_stat ~subject observed_stat,
         core_identity_of_stat ~subject opened_stat
       with
       | Error error, _ | _, Error error -> Error error
       | Ok observed, Ok opened ->
         if Core.equal_identity observed opened
         then Ok directory
         else
           Error
             { subject
             ; cause =
                 Opened_resource_identity_changed
                   { observed = identity_of_core observed
                   ; opened = identity_of_core opened
                   }
             })
;;

let open_expected_directory ~sw ~subject ~path ~expected =
  match observe_stat ~subject path with
  | Error _ as error -> error
  | Ok None ->
    let observed = absent_observation in
    Ok (Directory_mismatch (mismatch ~expected observed))
  | Ok (Some observed_stat) ->
    (match observation_of_stat ~subject observed_stat with
     | Error _ as error -> error
     | Ok
         ({ core = Core.Present { kind; identity }; _ } as observed) ->
       if kind <> `Directory || not (Core.equal_identity expected identity)
       then Ok (Directory_mismatch (mismatch ~expected observed))
       else
         (match
            validate_opened_directory
              ~sw
              ~subject
              ~path
              ~observed_stat
          with
          | Error _ as error -> error
          | Ok directory -> Ok (Directory_opened directory))
     | Ok { core = Core.Absent; _ } ->
       Ok (Directory_mismatch (mismatch ~expected absent_observation)))
;;

let traverse_parent ~sw ~fs locator =
  let root_path = Core.locator_allowed_root_path locator in
  let root_subject = Allowed_root root_path in
  let root = Eio.Path.(fs / root_path) in
  match
    open_expected_directory
      ~sw
      ~subject:root_subject
      ~path:root
      ~expected:(Core.locator_allowed_root locator)
  with
  | Error _ as error -> error
  | Ok (Directory_mismatch mismatch) ->
    Ok (Allowed_root_mismatch mismatch)
  | Ok (Directory_opened root) ->
    let rec traverse index parent parent_subject = function
      | [] ->
        (match
           capture_observation ~subject:parent_subject (fun () ->
             Eio.Path.with_open_in Eio.Path.(parent / ".") Eio.File.stat)
         with
         | Error _ as error -> error
         | Ok stat ->
           (match core_identity_of_stat ~subject:parent_subject stat with
            | Error _ as error -> error
            | Ok actual ->
              let expected = Core.locator_parent locator in
              if stat.kind = `Directory && Core.equal_identity expected actual
              then Ok (Parent_opened parent)
              else
                (match observation_of_stat ~subject:parent_subject stat with
                 | Error _ as error -> error
                 | Ok observed ->
                   Ok (Parent_mismatch (mismatch ~expected observed)))))
      | component :: rest ->
        let subject = Parent_component { index; component } in
        let path = Eio.Path.(parent / component) in
        (match observe_stat ~subject path with
         | Error _ as error -> error
         | Ok None ->
           Ok
             (Parent_mismatch
                (mismatch
                   ~expected:(Core.locator_parent locator)
                   absent_observation))
         | Ok (Some observed_stat) ->
           (match observation_of_stat ~subject observed_stat with
            | Error _ as error -> error
            | Ok observed when observed_stat.kind <> `Directory ->
              Ok
                (Parent_mismatch
                   (mismatch
                      ~expected:(Core.locator_parent locator)
                      observed))
            | Ok _ ->
              (match
                 validate_opened_directory
                   ~sw
                   ~subject
                   ~path
                   ~observed_stat
               with
               | Error _ as error -> error
               | Ok opened ->
                 traverse (index + 1) opened subject rest)))
    in
    traverse 0 root root_subject (Core.locator_parent_components locator)
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
    (match release_failure with
     | None ->
       Printexc.raise_with_backtrace failure.exception_ failure.backtrace
     | Some release ->
       Printexc.raise_with_backtrace
         (Record_scope_callback_and_release_failed
            { callback = failure.exception_, failure.backtrace; release })
         failure.backtrace)
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
    let target_name = Core.locator_target_leaf locator in
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

let report_owner report = report.owner
let report_rows report = report.rows

let row_is_ready = function
  | Prepared_reconciled _
  | Bound_reconciled _
  | Existing_forensic_record _ -> true
  | Unexpected_lane_entry _
  | Missing_lane_entry _
  | Lane_entry_unavailable _
  | Area_inventory_unavailable _
  | Source_transition_capabilities_unavailable _
  | Conflicting_source_records _
  | Invalid_record_name _
  | Unexpected_record_kind _
  | Missing_record_entry _
  | Record_entry_unavailable _
  | Corrupt_record_preserved _
  | Record_observation_failed _
  | Record_transition_failed _
  | Record_scope_release_failed _
  | Owner_store_release_failed _
  | Owner_store_unavailable _
  | Owner_inventory_unavailable _ -> false
;;

let report_is_ready report = List.for_all row_is_ready report.rows

let record_area_to_string = function
  | Active -> "active"
  | Owned -> "owned"
  | Forensic -> "forensic"
;;

let source_state_to_string = function
  | Prepared -> "prepared"
  | Bound -> "bound"
;;

let corrupt_validation_error_kind_to_string = function
  | Corrupt_invalid_owner -> "invalid_owner"
  | Corrupt_invalid_operation_id -> "invalid_operation_id"
  | Corrupt_invalid_identity -> "invalid_identity"
  | Corrupt_invalid_allowed_root_path -> "invalid_allowed_root_path"
  | Corrupt_empty_parent_path_identity_mismatch ->
    "empty_parent_path_identity_mismatch"
  | Corrupt_invalid_parent_component -> "invalid_parent_component"
  | Corrupt_invalid_target_leaf -> "invalid_target_leaf"
  | Corrupt_invalid_permissions -> "invalid_permissions"
  | Corrupt_invalid_record_json -> "invalid_record_json"
  | Corrupt_invalid_record_shape -> "invalid_record_shape"
  | Corrupt_unsupported_record_version -> "unsupported_record_version"
  | Corrupt_record_state_mismatch -> "record_state_mismatch"
  | Corrupt_record_owner_mismatch -> "record_owner_mismatch"
  | Corrupt_record_operation_id_mismatch ->
    "record_operation_id_mismatch"
  | Corrupt_record_stage_leaf_mismatch -> "record_stage_leaf_mismatch"
  | Corrupt_record_identity_mismatch -> "record_identity_mismatch"
  | Corrupt_record_kind_mismatch -> "record_kind_mismatch"
  | Corrupt_record_permissions_mismatch -> "record_permissions_mismatch"
  | Corrupt_record_outcome_observation_not_mismatch ->
    "record_outcome_observation_not_mismatch"
  | Corrupt_record_field_invalid -> "record_field_invalid"
;;

let digest_evidence_to_string = function
  | None -> "no_payload"
  | Some { canonical_json_byte_count; canonical_json_sha256 } ->
    Printf.sprintf
      "payload(canonical_json_bytes=%d,sha256=%s)"
      canonical_json_byte_count
      canonical_json_sha256
;;

let corrupt_validation_error_to_string error =
  Printf.sprintf
    "%s,%s"
    (corrupt_validation_error_kind_to_string error.kind)
    (digest_evidence_to_string error.payload)
;;

let release_scope_to_string = function
  | Owner_store_scope -> "owner_store"
  | Record_scope { source_state; operation_id } ->
    Printf.sprintf
      "record(%s,%s)"
      (source_state_to_string source_state)
      operation_id
;;

let cleanup_failure_to_string = function
  | Core_cleanup_failure failure ->
    Printf.sprintf "core(%s)" (Core.failure_to_string failure)
  | Scope_release_failure { scope; exception_; _ } ->
    Printf.sprintf
      "scope_release(%s,%s)"
      (release_scope_to_string scope)
      (Printexc.to_string exception_)
;;

let observation_subject_to_string = function
  | Allowed_root path -> Printf.sprintf "allowed_root(%S)" path
  | Parent_component { index; component } ->
    Printf.sprintf "parent_component(index=%d,name=%S)" index component
  | Stage_leaf name -> Printf.sprintf "stage_leaf(%S)" name
  | Target_leaf name -> Printf.sprintf "target_leaf(%S)" name
;;

let row_to_string = function
  | Unexpected_lane_entry { name; kind } ->
    Format.asprintf
      "unexpected_lane_entry(%S,%a)"
      name
      Eio.File.Stat.pp_kind
      kind
  | Missing_lane_entry { name } ->
    Printf.sprintf "missing_lane_entry(%S)" name
  | Lane_entry_unavailable { name; error } ->
    Printf.sprintf
      "lane_entry_unavailable(%S,%s)"
      name
      (Core.transition_error_to_string error)
  | Area_inventory_unavailable { area; error } ->
    Printf.sprintf
      "area_inventory_unavailable(%s,%s)"
      (record_area_to_string area)
      (Core.transition_error_to_string error)
  | Source_transition_capabilities_unavailable
      { source_state; operation_id; area_failures } ->
    let areas =
      area_failures
      |> List.map (fun (area, _) -> record_area_to_string area)
      |> String.concat ","
    in
    Printf.sprintf
      "source_transition_capabilities_unavailable(%s,%s,[%s])"
      (source_state_to_string source_state)
      operation_id
      areas
  | Prepared_reconciled { operation_id; _ } ->
    Printf.sprintf "prepared_reconciled(%s)" operation_id
  | Bound_reconciled { operation_id; _ } ->
    Printf.sprintf "bound_reconciled(%s)" operation_id
  | Existing_forensic_record { operation_id; source_state } ->
    Printf.sprintf
      "existing_forensic(%s,%s)"
      operation_id
      (source_state_to_string source_state)
  | Conflicting_source_records { operation_id; areas } ->
    Printf.sprintf
      "conflicting_sources(%s,[%s])"
      operation_id
      (String.concat "," (List.map record_area_to_string areas))
  | Invalid_record_name { area; name } ->
    Printf.sprintf
      "invalid_record_name(%s,%S)"
      (record_area_to_string area)
      name
  | Unexpected_record_kind { area; operation_id; kind } ->
    Format.asprintf
      "unexpected_record_kind(%s,%s,%a)"
      (record_area_to_string area)
      operation_id
      Eio.File.Stat.pp_kind
      kind
  | Missing_record_entry { area; operation_id } ->
    Printf.sprintf
      "missing_record(%s,%s)"
      (record_area_to_string area)
      operation_id
  | Record_entry_unavailable { area; operation_id; error } ->
    Printf.sprintf
      "record_unavailable(%s,%s,%s)"
      (record_area_to_string area)
      operation_id
      (Core.transition_error_to_string error)
  | Corrupt_record_preserved
      { area; operation_id; validation_error; _ } ->
    Printf.sprintf
      "corrupt_record(%s,%s,%s)"
      (record_area_to_string area)
      operation_id
      (corrupt_validation_error_to_string validation_error)
  | Record_observation_failed
      { source_state; operation_id; failure } ->
    Printf.sprintf
      "observation_failed(%s,%s,%s)"
      (source_state_to_string source_state)
      operation_id
      (observation_subject_to_string failure.subject)
  | Record_transition_failed { source_state; operation_id; error } ->
    Printf.sprintf
      "transition_failed(%s,%s,%s)"
      (source_state_to_string source_state)
      operation_id
      (Core.transition_error_to_string error)
  | Record_scope_release_failed
      { source_state; operation_id; failure } ->
    Printf.sprintf
      "record_scope_release_failed(%s,%s,%s)"
      (source_state_to_string source_state)
      operation_id
      (cleanup_failure_to_string failure)
  | Owner_store_release_failed failure ->
    Printf.sprintf
      "owner_store_release_failed(%s)"
      (cleanup_failure_to_string failure)
  | Owner_store_unavailable error ->
    Printf.sprintf
      "owner_store_unavailable(%s)"
      (Core.transition_error_to_string error)
  | Owner_inventory_unavailable error ->
    Printf.sprintf
      "owner_inventory_unavailable(%s)"
      (Core.transition_error_to_string error)
;;

let report_to_string report =
  Printf.sprintf
    "owner=%S ready=%b rows=[%s]"
    report.owner
    (report_is_ready report)
    (String.concat "; " (List.map row_to_string report.rows))
;;

let file_kind_to_string kind =
  Format.asprintf "%a" Eio.File.Stat.pp_kind kind
;;

let exception_to_yojson exception_ backtrace =
  `Assoc
    [ "message", `String (Printexc.to_string exception_)
    ; "backtrace", `String (Printexc.raw_backtrace_to_string backtrace)
    ]
;;

let identity_to_yojson identity =
  `Assoc
    [ "device", `Intlit (Int64.to_string identity.device)
    ; "inode", `Intlit (Int64.to_string identity.inode)
    ]
;;

let core_identity_to_yojson identity =
  identity |> identity_of_core |> identity_to_yojson
;;

let entry_observation_to_yojson = function
  | Entry_absent -> `Assoc [ "kind", `String "absent" ]
  | Entry_present { kind; identity } ->
    `Assoc
      [ "kind", `String "present"
      ; "resource_kind", `String (file_kind_to_string kind)
      ; "identity", identity_to_yojson identity
      ]
;;

let resource_mismatch_to_yojson mismatch =
  `Assoc
    [ "expected", identity_to_yojson mismatch.expected
    ; "observed", entry_observation_to_yojson mismatch.observed
    ]
;;

let prepared_outcome_to_yojson = function
  | Prepared_unmaterialized ->
    `Assoc [ "kind", `String "unmaterialized" ]
  | Prepared_allowed_root_mismatch mismatch ->
    `Assoc
      [ "kind", `String "allowed_root_mismatch"
      ; "mismatch", resource_mismatch_to_yojson mismatch
      ]
  | Prepared_parent_mismatch mismatch ->
    `Assoc
      [ "kind", `String "parent_mismatch"
      ; "mismatch", resource_mismatch_to_yojson mismatch
      ]
  | Prepared_unbound_stage_preserved { kind; identity } ->
    `Assoc
      [ "kind", `String "unbound_stage_preserved"
      ; "resource_kind", `String (file_kind_to_string kind)
      ; "identity", identity_to_yojson identity
      ]
;;

let bound_outcome_to_yojson = function
  | Bound_stage_absent { observed_target } ->
    `Assoc
      [ "kind", `String "stage_absent"
      ; "observed_target", entry_observation_to_yojson observed_target
      ]
  | Bound_allowed_root_mismatch mismatch ->
    `Assoc
      [ "kind", `String "allowed_root_mismatch"
      ; "mismatch", resource_mismatch_to_yojson mismatch
      ]
  | Bound_parent_mismatch mismatch ->
    `Assoc
      [ "kind", `String "parent_mismatch"
      ; "mismatch", resource_mismatch_to_yojson mismatch
      ]
  | Bound_stage_mismatch { mismatch; observed_target } ->
    `Assoc
      [ "kind", `String "stage_mismatch"
      ; "mismatch", resource_mismatch_to_yojson mismatch
      ; "observed_target", entry_observation_to_yojson observed_target
      ]
  | Bound_stage_preserved { kind; identity; observed_target } ->
    `Assoc
      [ "kind", `String "stage_preserved"
      ; "resource_kind", `String (file_kind_to_string kind)
      ; "identity", identity_to_yojson identity
      ; "observed_target", entry_observation_to_yojson observed_target
      ]
;;

let core_record_area_to_string = function
  | Core.Active -> "active"
  | Core.Owned -> "owned"
  | Core.Forensic -> "forensic"
;;

let core_removal_transition_to_string = function
  | Core.Discharge_active -> "discharge_active"
  | Core.Discharge_owned -> "discharge_owned"
  | Core.Active_to_owned -> "active_to_owned"
  | Core.Active_to_forensic -> "active_to_forensic"
  | Core.Owned_to_forensic -> "owned_to_forensic"
;;

let core_transition_effect_to_yojson = function
  | Core.No_record_change -> `Assoc [ "kind", `String "no_record_change" ]
  | Core.Layout_may_be_incomplete ->
    `Assoc [ "kind", `String "layout_may_be_incomplete" ]
  | Core.Layout_ready -> `Assoc [ "kind", `String "layout_ready" ]
  | Core.Active_record_state_unknown ->
    `Assoc [ "kind", `String "active_record_state_unknown" ]
  | Core.Active_record_durable ->
    `Assoc [ "kind", `String "active_record_durable" ]
  | Core.Active_record_discharged ->
    `Assoc [ "kind", `String "active_record_discharged" ]
  | Core.Owned_record_state_unknown_with_active ->
    `Assoc [ "kind", `String "owned_record_state_unknown_with_active" ]
  | Core.Owned_record_durable_with_active ->
    `Assoc [ "kind", `String "owned_record_durable_with_active" ]
  | Core.Owned_record_durable ->
    `Assoc [ "kind", `String "owned_record_durable" ]
  | Core.Owned_record_discharged ->
    `Assoc [ "kind", `String "owned_record_discharged" ]
  | Core.Forensic_record_state_unknown_with_source ->
    `Assoc
      [ "kind", `String "forensic_record_state_unknown_with_source" ]
  | Core.Forensic_record_durable_with_source ->
    `Assoc [ "kind", `String "forensic_record_durable_with_source" ]
  | Core.Forensic_record_durable ->
    `Assoc [ "kind", `String "forensic_record_durable" ]
  | Core.Source_removal_durability_unknown transition ->
    `Assoc
      [ "kind", `String "source_removal_durability_unknown"
      ; "transition", `String (core_removal_transition_to_string transition)
      ]
;;

let core_validation_error_to_yojson = function
  | Core.Invalid_owner value ->
    `Assoc [ "kind", `String "invalid_owner"; "value", `String value ]
  | Core.Invalid_operation_id value ->
    `Assoc
      [ "kind", `String "invalid_operation_id"; "value", `String value ]
  | Core.Invalid_identity identity ->
    `Assoc
      [ "kind", `String "invalid_identity"
      ; "identity", core_identity_to_yojson identity
      ]
  | Core.Invalid_allowed_root_path value ->
    `Assoc
      [ "kind", `String "invalid_allowed_root_path"
      ; "value", `String value
      ]
  | Core.Empty_parent_path_identity_mismatch { allowed_root; parent } ->
    `Assoc
      [ "kind", `String "empty_parent_path_identity_mismatch"
      ; "allowed_root", core_identity_to_yojson allowed_root
      ; "parent", core_identity_to_yojson parent
      ]
  | Core.Invalid_parent_component { index; value } ->
    `Assoc
      [ "kind", `String "invalid_parent_component"
      ; "index", `Int index
      ; "value", `String value
      ]
  | Core.Invalid_target_leaf value ->
    `Assoc
      [ "kind", `String "invalid_target_leaf"; "value", `String value ]
  | Core.Invalid_permissions value ->
    `Assoc
      [ "kind", `String "invalid_permissions"; "value", `Int value ]
  | Core.Invalid_record_json { exception_; backtrace } ->
    `Assoc
      [ "kind", `String "invalid_record_json"
      ; "exception", exception_to_yojson exception_ backtrace
      ]
  | Core.Invalid_record_shape ->
    `Assoc [ "kind", `String "invalid_record_shape" ]
  | Core.Unsupported_record_version version ->
    `Assoc
      [ "kind", `String "unsupported_record_version"
      ; "version", `Int version
      ]
  | Core.Record_state_mismatch ->
    `Assoc [ "kind", `String "record_state_mismatch" ]
  | Core.Record_owner_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_owner_mismatch"
      ; "expected", `String (Core.owner_to_string expected)
      ; "actual", `String (Core.owner_to_string actual)
      ]
  | Core.Record_operation_id_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_operation_id_mismatch"
      ; "expected", `String (Core.operation_id_to_string expected)
      ; "actual", `String (Core.operation_id_to_string actual)
      ]
  | Core.Record_stage_leaf_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_stage_leaf_mismatch"
      ; "expected", `String expected
      ; "actual", `String actual
      ]
  | Core.Record_identity_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_identity_mismatch"
      ; "expected", core_identity_to_yojson expected
      ; "actual", core_identity_to_yojson actual
      ]
  | Core.Record_kind_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_kind_mismatch"
      ; "expected", `String (file_kind_to_string expected)
      ; "actual", `String (file_kind_to_string actual)
      ]
  | Core.Record_permissions_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "record_permissions_mismatch"
      ; "expected", `Int expected
      ; "actual", `Int actual
      ]
  | Core.Record_outcome_observation_not_mismatch identity ->
    `Assoc
      [ "kind", `String "record_outcome_observation_not_mismatch"
      ; "identity", core_identity_to_yojson identity
      ]
  | Core.Record_field_invalid { field; value } ->
    `Assoc
      [ "kind", `String "record_field_invalid"
      ; "field", `String field
      ; "value", value
      ]
;;

let corrupt_validation_error_to_yojson error =
  let payload =
    match error.payload with
    | None -> `Null
    | Some { canonical_json_byte_count; canonical_json_sha256 } ->
      `Assoc
        [ "canonical_json_byte_count", `Int canonical_json_byte_count
        ; "canonical_json_sha256", `String canonical_json_sha256
        ]
  in
  `Assoc
    [ ( "kind"
      , `String (corrupt_validation_error_kind_to_string error.kind) )
    ; "payload", payload
    ]
;;

let core_subject_to_yojson = function
  | Core.Registry_root -> `Assoc [ "kind", `String "registry_root" ]
  | Core.Recovery_root -> `Assoc [ "kind", `String "recovery_root" ]
  | Core.Lanes_root -> `Assoc [ "kind", `String "lanes_root" ]
  | Core.Lane_root owner ->
    `Assoc
      [ "kind", `String "lane_root"
      ; "owner", `String (Core.owner_to_string owner)
      ]
  | Core.Lane_entry (owner, name) ->
    `Assoc
      [ "kind", `String "lane_entry"
      ; "owner", `String (Core.owner_to_string owner)
      ; "name", `String name
      ]
  | Core.Area (area, owner) ->
    `Assoc
      [ "kind", `String "area"
      ; "area", `String (core_record_area_to_string area)
      ; "owner", `String (Core.owner_to_string owner)
      ]
  | Core.Record (area, owner, operation_id) ->
    `Assoc
      [ "kind", `String "record"
      ; "area", `String (core_record_area_to_string area)
      ; "owner", `String (Core.owner_to_string owner)
      ; "operation_id", `String (Core.operation_id_to_string operation_id)
      ]
;;

let core_operation_to_string = function
  | Core.Inspect_directory -> "inspect_directory"
  | Core.Create_directory -> "create_directory"
  | Core.Open_directory -> "open_directory"
  | Core.Close_directory -> "close_directory"
  | Core.Sync_directory -> "sync_directory"
  | Core.Read_directory -> "read_directory"
  | Core.Inspect_record -> "inspect_record"
  | Core.Open_record -> "open_record"
  | Core.Read_record -> "read_record"
  | Core.Decode_record -> "decode_record"
  | Core.Create_record -> "create_record"
  | Core.Apply_permissions -> "apply_permissions"
  | Core.Write_record -> "write_record"
  | Core.Sync_record -> "sync_record"
  | Core.Close_record -> "close_record"
  | Core.Verify_record_identity -> "verify_record_identity"
  | Core.Remove_record -> "remove_record"
;;

let core_failure_cause_to_yojson = function
  | Core.Validation_failed error ->
    `Assoc
      [ "kind", `String "validation_failed"
      ; "error", core_validation_error_to_yojson error
      ]
  | Core.Io_failed { exception_; backtrace } ->
    `Assoc
      [ "kind", `String "io_failed"
      ; "exception", exception_to_yojson exception_ backtrace
      ]
  | Core.Write_failed { exception_; backtrace; bytes_written } ->
    `Assoc
      [ "kind", `String "write_failed"
      ; "exception", exception_to_yojson exception_ backtrace
      ; "bytes_written", `Int bytes_written
      ]
  | Core.Unexpected_resource_kind kind ->
    `Assoc
      [ "kind", `String "unexpected_resource_kind"
      ; "resource_kind", `String (file_kind_to_string kind)
      ]
  | Core.Resource_identity_changed { expected; actual } ->
    `Assoc
      [ "kind", `String "resource_identity_changed"
      ; "expected", core_identity_to_yojson expected
      ; "actual", core_identity_to_yojson actual
      ]
  | Core.Posix_descriptor_unavailable ->
    `Assoc [ "kind", `String "posix_descriptor_unavailable" ]
  | Core.Existing_record_does_not_match ->
    `Assoc [ "kind", `String "existing_record_does_not_match" ]
  | Core.Created_record_identity_unavailable ->
    `Assoc [ "kind", `String "created_record_identity_unavailable" ]
  | Core.Missing_record -> `Assoc [ "kind", `String "missing_record" ]
;;

let core_failure_to_yojson (failure : Core.failure) =
  `Assoc
    [ "operation", `String (core_operation_to_string failure.operation)
    ; "subject", core_subject_to_yojson failure.subject
    ; "cause", core_failure_cause_to_yojson failure.cause
    ]
;;

let core_transition_error_to_yojson (error : Core.transition_error) =
  `Assoc
    [ "store_effect", core_transition_effect_to_yojson error.store_effect
    ; "failure", core_failure_to_yojson error.failure
    ; ( "cleanup_failures"
      , `List (List.map core_failure_to_yojson error.cleanup_failures) )
    ]
;;

let release_scope_to_yojson = function
  | Owner_store_scope -> `Assoc [ "kind", `String "owner_store" ]
  | Record_scope { source_state; operation_id } ->
    `Assoc
      [ "kind", `String "record"
      ; "source_state", `String (source_state_to_string source_state)
      ; "operation_id", `String operation_id
      ]
;;

let cleanup_failure_to_yojson = function
  | Core_cleanup_failure failure ->
    `Assoc
      [ "kind", `String "core_cleanup_failure"
      ; "failure", core_failure_to_yojson failure
      ]
  | Scope_release_failure { scope; exception_; backtrace } ->
    `Assoc
      [ "kind", `String "scope_release_failure"
      ; "scope", release_scope_to_yojson scope
      ; "exception", exception_to_yojson exception_ backtrace
      ]
;;

let observation_subject_to_yojson = function
  | Allowed_root path ->
    `Assoc [ "kind", `String "allowed_root"; "path", `String path ]
  | Parent_component { index; component } ->
    `Assoc
      [ "kind", `String "parent_component"
      ; "index", `Int index
      ; "component", `String component
      ]
  | Stage_leaf name ->
    `Assoc [ "kind", `String "stage_leaf"; "name", `String name ]
  | Target_leaf name ->
    `Assoc [ "kind", `String "target_leaf"; "name", `String name ]
;;

let observation_cause_to_yojson = function
  | Observation_io_failed { exception_; backtrace } ->
    `Assoc
      [ "kind", `String "io_failed"
      ; "exception", exception_to_yojson exception_ backtrace
      ]
  | Observation_identity_invalid error ->
    `Assoc
      [ "kind", `String "identity_invalid"
      ; "error", core_validation_error_to_yojson error
      ]
  | Opened_resource_kind_changed { observed; opened } ->
    `Assoc
      [ "kind", `String "opened_resource_kind_changed"
      ; "observed", `String (file_kind_to_string observed)
      ; "opened", `String (file_kind_to_string opened)
      ]
  | Opened_resource_identity_changed { observed; opened } ->
    `Assoc
      [ "kind", `String "opened_resource_identity_changed"
      ; "observed", identity_to_yojson observed
      ; "opened", identity_to_yojson opened
      ]
;;

let observation_failure_to_yojson failure =
  `Assoc
    [ "subject", observation_subject_to_yojson failure.subject
    ; "cause", observation_cause_to_yojson failure.cause
    ]
;;

let row_to_yojson = function
  | Unexpected_lane_entry { name; kind } ->
    `Assoc
      [ "kind", `String "unexpected_lane_entry"
      ; "name", `String name
      ; "resource_kind", `String (file_kind_to_string kind)
      ]
  | Missing_lane_entry { name } ->
    `Assoc [ "kind", `String "missing_lane_entry"; "name", `String name ]
  | Lane_entry_unavailable { name; error } ->
    `Assoc
      [ "kind", `String "lane_entry_unavailable"
      ; "name", `String name
      ; "error", core_transition_error_to_yojson error
      ]
  | Area_inventory_unavailable { area; error } ->
    `Assoc
      [ "kind", `String "area_inventory_unavailable"
      ; "area", `String (record_area_to_string area)
      ; "error", core_transition_error_to_yojson error
      ]
  | Source_transition_capabilities_unavailable
      { source_state; operation_id; area_failures } ->
    `Assoc
      [ "kind", `String "source_transition_capabilities_unavailable"
      ; "source_state", `String (source_state_to_string source_state)
      ; "operation_id", `String operation_id
      ; ( "area_failures"
        , `List
            (List.map
               (fun (area, error) ->
                  `Assoc
                    [ "area", `String (record_area_to_string area)
                    ; "error", core_transition_error_to_yojson error
                    ])
               area_failures) )
      ]
  | Prepared_reconciled { operation_id; outcome } ->
    `Assoc
      [ "kind", `String "prepared_reconciled"
      ; "operation_id", `String operation_id
      ; "outcome", prepared_outcome_to_yojson outcome
      ]
  | Bound_reconciled { operation_id; outcome } ->
    `Assoc
      [ "kind", `String "bound_reconciled"
      ; "operation_id", `String operation_id
      ; "outcome", bound_outcome_to_yojson outcome
      ]
  | Existing_forensic_record { operation_id; source_state } ->
    `Assoc
      [ "kind", `String "existing_forensic_record"
      ; "operation_id", `String operation_id
      ; "source_state", `String (source_state_to_string source_state)
      ]
  | Conflicting_source_records { operation_id; areas } ->
    `Assoc
      [ "kind", `String "conflicting_source_records"
      ; "operation_id", `String operation_id
      ; ( "areas"
        , `List
            (List.map
               (fun area -> `String (record_area_to_string area))
               areas) )
      ]
  | Invalid_record_name { area; name } ->
    `Assoc
      [ "kind", `String "invalid_record_name"
      ; "area", `String (record_area_to_string area)
      ; "name", `String name
      ]
  | Unexpected_record_kind { area; operation_id; kind } ->
    `Assoc
      [ "kind", `String "unexpected_record_kind"
      ; "area", `String (record_area_to_string area)
      ; "operation_id", `String operation_id
      ; "resource_kind", `String (file_kind_to_string kind)
      ]
  | Missing_record_entry { area; operation_id } ->
    `Assoc
      [ "kind", `String "missing_record_entry"
      ; "area", `String (record_area_to_string area)
      ; "operation_id", `String operation_id
      ]
  | Record_entry_unavailable { area; operation_id; error } ->
    `Assoc
      [ "kind", `String "record_entry_unavailable"
      ; "area", `String (record_area_to_string area)
      ; "operation_id", `String operation_id
      ; "error", core_transition_error_to_yojson error
      ]
  | Corrupt_record_preserved
      { area
      ; operation_id
      ; raw_byte_count
      ; raw_sha256
      ; validation_error
      } ->
    `Assoc
      [ "kind", `String "corrupt_record_preserved"
      ; "area", `String (record_area_to_string area)
      ; "operation_id", `String operation_id
      ; "raw_byte_count", `Int raw_byte_count
      ; "raw_sha256", `String raw_sha256
      ; "validation_error", corrupt_validation_error_to_yojson validation_error
      ]
  | Record_observation_failed
      { source_state; operation_id; failure } ->
    `Assoc
      [ "kind", `String "record_observation_failed"
      ; "source_state", `String (source_state_to_string source_state)
      ; "operation_id", `String operation_id
      ; "failure", observation_failure_to_yojson failure
      ]
  | Record_transition_failed { source_state; operation_id; error } ->
    `Assoc
      [ "kind", `String "record_transition_failed"
      ; "source_state", `String (source_state_to_string source_state)
      ; "operation_id", `String operation_id
      ; "error", core_transition_error_to_yojson error
      ]
  | Record_scope_release_failed { source_state; operation_id; failure } ->
    `Assoc
      [ "kind", `String "record_scope_release_failed"
      ; "source_state", `String (source_state_to_string source_state)
      ; "operation_id", `String operation_id
      ; "failure", cleanup_failure_to_yojson failure
      ]
  | Owner_store_release_failed failure ->
    `Assoc
      [ "kind", `String "owner_store_release_failed"
      ; "failure", cleanup_failure_to_yojson failure
      ]
  | Owner_store_unavailable error ->
    `Assoc
      [ "kind", `String "owner_store_unavailable"
      ; "error", core_transition_error_to_yojson error
      ]
  | Owner_inventory_unavailable error ->
    `Assoc
      [ "kind", `String "owner_inventory_unavailable"
      ; "error", core_transition_error_to_yojson error
      ]
;;

let report_to_yojson report =
  `Assoc
    [ "owner", `String report.owner
    ; "ready", `Bool (report_is_ready report)
    ; "rows", `List (List.map row_to_yojson report.rows)
    ]
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
           Eio.Switch.on_release sw (fun () -> raise exception_))
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
