type composition_coverage =
  { scope : [ `Exact_reference_latest_completed | `Unavailable ]
  ; records_read : int
  }

let composition_scope_to_string = function
  | `Exact_reference_latest_completed -> "exact_reference_latest_completed"
  | `Unavailable -> "unavailable"
;;

let composition_evidence ~config reference =
  match Keeper_skill_composition_evidence.load_latest config reference with
  | Error error ->
    ( None
    , { scope = `Unavailable; records_read = 0 }
    , [ Keeper_skill_composition_evidence.error_to_string error ] )
  | Ok None ->
    None, { scope = `Exact_reference_latest_completed; records_read = 0 }, []
  | Ok (Some evidence) ->
    ( Some (Keeper_skill_composition_evidence.to_yojson evidence)
    , { scope = `Exact_reference_latest_completed; records_read = 1 }
    , [] )
;;

let owner_source_to_string = function
  | Keeper_skill_activation_owner.Current_meta -> "current_meta"
  | Trace_history -> "trace_history"
  | Runtime_manifest -> "runtime_manifest"
;;

let owner_claim_to_yojson
      (claim : Keeper_skill_activation_owner.claim) =
  `Assoc
    [ ( "keeper"
      , `String (Keeper_id.Keeper_name.to_string claim.keeper_name) )
    ; "source", `String (owner_source_to_string claim.source)
    ]
;;

let manifest_error_to_yojson = function
  | Keeper_skill_activation_owner.Manifest_read_failed error ->
    `Assoc
      [ "code", `String "manifest_read_failed"
      ; ( "detail"
        , `String (Fs_compat.owned_regular_file_read_error_to_string error) )
      ]
  | Manifest_empty -> `Assoc [ "code", `String "manifest_empty" ]
  | Manifest_invalid_json { line_number; detail } ->
    `Assoc
      [ "code", `String "manifest_invalid_json"
      ; "line_number", `Int line_number
      ; "detail", `String detail
      ]
  | Manifest_invalid_row { line_number; detail } ->
    `Assoc
      [ "code", `String "manifest_invalid_row"
      ; "line_number", `Int line_number
      ; "detail", `String detail
      ]
  | Manifest_identity_mismatch
      { line_number; observed_keeper; observed_trace } ->
    `Assoc
      [ "code", `String "manifest_identity_mismatch"
      ; "line_number", `Int line_number
      ; "observed_keeper", `String observed_keeper
      ; "observed_trace", `String observed_trace
      ]
;;

let owner_gap_to_yojson = function
  | Keeper_skill_activation_owner.Keeper_catalog_unavailable detail ->
    `Assoc
      [ "code", `String "keeper_catalog_unavailable"
      ; "detail", `String detail
      ]
  | Keeper_catalog_changed_during_resolution ->
    `Assoc [ "code", `String "keeper_catalog_changed_during_resolution" ]
  | Invalid_persisted_keeper_name name ->
    `Assoc
      [ "code", `String "invalid_persisted_keeper_name"
      ; "keeper", `String name
      ]
  | Keeper_meta_name_mismatch { catalog_name; metadata_name } ->
    `Assoc
      [ "code", `String "keeper_meta_name_mismatch"
      ; "keeper", `String (Keeper_id.Keeper_name.to_string catalog_name)
      ; "metadata_name", `String metadata_name
      ]
  | Keeper_meta_unavailable { keeper_name; detail } ->
    `Assoc
      [ "code", `String "keeper_meta_unavailable"
      ; "keeper", `String (Keeper_id.Keeper_name.to_string keeper_name)
      ; "detail", `String detail
      ]
  | Runtime_manifest_entry_unreadable { keeper_name; cause } ->
    `Assoc
      [ "code", `String "runtime_manifest_unreadable"
      ; "keeper", `String (Keeper_id.Keeper_name.to_string keeper_name)
      ; "cause", manifest_error_to_yojson cause
      ]
;;

let owner_to_yojson (owner : Keeper_skill_activation_owner.t) =
  let status, claims =
    match owner.owner with
    | Known claim -> "known", [ claim ]
    | Not_claimed_in_retained_catalog ->
      "not_claimed_in_retained_catalog", []
    | Conflicting claims -> "conflicting", claims
    | Incomplete claims -> "incomplete", claims
    | Catalog_unavailable -> "catalog_unavailable", []
  in
  `Assoc
    [ "status", `String status
    ; "claims", `List (List.map owner_claim_to_yojson claims)
    ; "gaps", `List (List.map owner_gap_to_yojson owner.gaps)
    ]
;;

let activation_evidence_to_yojson ~config
      (evidence : Keeper_skill_activation_discovery.evidence) =
  let owner =
    Keeper_skill_activation_owner.resolve config evidence.trace_id
  in
  ( `Assoc
      [ "trace_id", `String (Keeper_id.Trace_id.to_string evidence.trace_id)
      ; "owner", owner_to_yojson owner
      ; ( "activation"
        , Keeper_skill_activation_ledger.activation_to_yojson
            evidence.activation )
      ]
  , List.length owner.gaps )
;;

let activation_projection ~config
      (discovery : Keeper_skill_activation_discovery.t) =
  match discovery.latest with
  | Not_observed -> None, 0
  | Most_recent_observed evidence ->
    let evidence, owner_gaps = activation_evidence_to_yojson ~config evidence in
    ( Some
        (`Assoc
           [ "selection", `String "most_recent_observed"
           ; "evidence", evidence
           ])
    , owner_gaps )
  | Most_recent_observed_timestamp_tie evidence ->
    let evidence, gap_counts =
      evidence
      |> List.map (activation_evidence_to_yojson ~config)
      |> List.split
    in
    ( Some
        (`Assoc
           [ "selection", `String "most_recent_observed_timestamp_tie"
           ; "evidence", `List evidence
           ])
    , List.fold_left ( + ) 0 gap_counts )
;;

let filesystem_operation_to_string = function
  | Keeper_skill_activation_discovery.Open_directory -> "open_directory"
  | Read_directory -> "read_directory"
  | Close_directory -> "close_directory"
  | Stat_entry -> "stat_entry"
;;

let file_kind_to_string = function
  | Unix.S_REG -> "regular"
  | S_DIR -> "directory"
  | S_CHR -> "character_device"
  | S_BLK -> "block_device"
  | S_LNK -> "symbolic_link"
  | S_FIFO -> "fifo"
  | S_SOCK -> "socket"
;;

let filesystem_error_to_fields
      (error : Keeper_skill_activation_discovery.filesystem_error) =
  [ "operation", `String (filesystem_operation_to_string error.operation)
  ; "path", `String error.path
  ; "detail", `String (Unix.error_message error.cause)
  ]
;;

let activation_gap_to_yojson = function
  | Keeper_skill_activation_discovery.Trace_root_unavailable error ->
    `Assoc
      (("code", `String "trace_root_unavailable")
       :: filesystem_error_to_fields error)
  | Trace_root_not_directory kind ->
    `Assoc
      [ "code", `String "trace_root_not_directory"
      ; "kind", `String (file_kind_to_string kind)
      ]
  | Trace_entry_unreadable error ->
    `Assoc
      (("code", `String "trace_entry_unreadable")
       :: filesystem_error_to_fields error)
  | Invalid_trace_directory entry ->
    `Assoc
      [ "code", `String "invalid_trace_directory"
      ; "entry", `String entry
      ]
  | Symlink_trace_entry entry ->
    `Assoc
      [ "code", `String "symlink_trace_entry"
      ; "entry", `String entry
      ]
  | Trace_entry_not_directory { trace_id; kind } ->
    `Assoc
      [ "code", `String "trace_entry_not_directory"
      ; "trace_id", `String (Keeper_id.Trace_id.to_string trace_id)
      ; "kind", `String (file_kind_to_string kind)
      ]
  | Trace_inventory_changed_during_discovery ->
    `Assoc [ "code", `String "trace_inventory_changed_during_discovery" ]
  | Trace_root_changed_during_discovery ->
    `Assoc [ "code", `String "trace_root_changed_during_discovery" ]
  | Ledger_changed_during_discovery trace_id ->
    `Assoc
      [ "code", `String "ledger_changed_during_discovery"
      ; "trace_id", `String (Keeper_id.Trace_id.to_string trace_id)
      ]
  | Ledger_unreadable { trace_id; cause } ->
    `Assoc
      [ "code", `String "ledger_unreadable"
      ; "trace_id", `String (Keeper_id.Trace_id.to_string trace_id)
      ; "cause_code", `String (Keeper_skill_activation_ledger.store_error_code cause)
      ; "detail", `String (Keeper_skill_activation_ledger.store_error_to_string cause)
      ]
;;

let activation_scope_to_string = function
  | Keeper_skill_activation_discovery.Complete_retained_trace_snapshot ->
    "complete_retained_trace_snapshot"
  | Incomplete_retained_trace_snapshot ->
    "incomplete_retained_trace_snapshot"
  | Trace_store_unavailable -> "trace_store_unavailable"
;;

let to_yojson
      ~reference
      ~composition
      ~composition_coverage
      ~composition_unavailable
      ~activation
      ~activation_scope
      ~activation_sessions_inspected
      ~activation_ledgers_loaded
      ~activation_gaps
      ~activation_owner_gap_count =
  let observed = Option.is_some activation || Option.is_some composition in
  `Assoc
    [ "schema", `String "masc.skill-evidence/v5"
    ; ( "status"
      , `String
          (if observed then "observed" else "not_observed_in_retained_coverage") )
    ; "reference", Skill_reference.to_yojson reference
    ; "activation", Option.value ~default:`Null activation
    ; "composition", Option.value ~default:`Null composition
    ; ( "coverage"
      , `Assoc
          [ ( "composition_scope"
            , `String (composition_scope_to_string composition_coverage.scope) )
          ; "composition_records_read", `Int composition_coverage.records_read
          ; ( "composition_unavailable"
            , `List
                (List.map
                   (fun value -> `String value)
                   composition_unavailable) )
          ; "coverage_complete", `Bool false
          ; "activation_scope", `String (activation_scope_to_string activation_scope)
          ; "activation_sessions_inspected", `Int activation_sessions_inspected
          ; "activation_ledgers_loaded", `Int activation_ledgers_loaded
          ; ( "activation_gaps"
            , `List (List.map activation_gap_to_yojson activation_gaps) )
          ; "activation_owner_gap_count", `Int activation_owner_gap_count
          ] )
    ]
;;

let project ~config reference =
  let discovery = Keeper_skill_activation_discovery.discover config reference in
  let activation, activation_owner_gap_count =
    activation_projection ~config discovery
  in
  let composition, composition_coverage, composition_unavailable =
    composition_evidence ~config reference
  in
  to_yojson
    ~reference
    ~composition
    ~composition_coverage
    ~composition_unavailable
    ~activation
    ~activation_scope:discovery.scope
    ~activation_sessions_inspected:discovery.sessions_inspected
    ~activation_ledgers_loaded:discovery.ledgers_loaded
    ~activation_gaps:discovery.gaps
    ~activation_owner_gap_count
;;

module For_testing = struct
  let to_yojson
        ~reference
        ~composition
        ~composition_records_read
        ~composition_scope
        ~composition_unavailable
        ~activation
        ~activation_scope
        ~activation_sessions_inspected
        ~activation_ledgers_loaded
        ~activation_gaps
        ~activation_owner_gap_count =
    to_yojson
      ~reference
      ~composition
      ~composition_coverage:
        { scope = composition_scope; records_read = composition_records_read }
      ~composition_unavailable
      ~activation
      ~activation_scope
      ~activation_sessions_inspected
      ~activation_ledgers_loaded
      ~activation_gaps
      ~activation_owner_gap_count
  ;;
end
