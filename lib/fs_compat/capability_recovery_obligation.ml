type owner = Capability_leaf.t
type operation_id = Uuidm.t
type permissions = int

type identity =
  { dev : int64
  ; ino : int64
  }

type entry_observation =
  | Absent
  | Present of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      }

type locator =
  { allowed_root_path : string
  ; allowed_root : identity
  ; parent_components : Capability_leaf.t list
  ; parent : identity
  ; target_leaf : Capability_leaf.t
  ; initial_target : entry_observation
  }

type prepared =
  { owner : owner
  ; operation_id : operation_id
  ; locator : locator
  ; permissions : int
  }

type bound =
  { prepared : prepared
  ; stage_identity : identity
  }

type resource_mismatch =
  { expected : identity
  ; observed : entry_observation
  }

type prepared_recovery_outcome =
  | Recovered_unmaterialized
  | Prepared_allowed_root_mismatch of resource_mismatch
  | Prepared_parent_mismatch of resource_mismatch
  | Preserved_unbound_stage of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      }

type bound_recovery_outcome =
  | Bound_stage_absent of
      { observed_target : entry_observation
      }
  | Bound_allowed_root_mismatch of resource_mismatch
  | Bound_parent_mismatch of resource_mismatch
  | Bound_stage_mismatch of
      { mismatch : resource_mismatch
      ; observed_target : entry_observation
      }
  | Preserved_bound_stage of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      ; observed_target : entry_observation
      }

type forensic_source =
  | Prepared_source of prepared * prepared_recovery_outcome
  | Bound_source of bound * bound_recovery_outcome

type forensic = { source : forensic_source }

type area =
  | Active
  | Owned
  | Forensic

type registry =
  { lanes : Eio.Fs.dir_ty Eio.Path.t }

type store =
  { owner : owner
  ; active : Eio.Fs.dir_ty Eio.Path.t
  ; owned : Eio.Fs.dir_ty Eio.Path.t
  ; forensic : Eio.Fs.dir_ty Eio.Path.t
  }

type validation_error =
  | Invalid_owner of string
  | Invalid_operation_id of string
  | Invalid_identity of identity
  | Invalid_allowed_root_path of string
  | Empty_parent_path_identity_mismatch of
      { allowed_root : identity
      ; parent : identity
      }
  | Invalid_parent_component of
      { index : int
      ; value : string
      }
  | Invalid_target_leaf of string
  | Invalid_permissions of int
  | Invalid_record_json of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Invalid_record_shape
  | Unsupported_record_version of int
  | Record_state_mismatch
  | Record_owner_mismatch of
      { expected : owner
      ; actual : owner
      }
  | Record_operation_id_mismatch of
      { expected : operation_id
      ; actual : operation_id
      }
  | Record_stage_leaf_mismatch of
      { expected : string
      ; actual : string
      }
  | Record_identity_mismatch of
      { expected : identity
      ; actual : identity
      }
  | Record_kind_mismatch of
      { expected : Eio.File.Stat.kind
      ; actual : Eio.File.Stat.kind
      }
  | Record_permissions_mismatch of
      { expected : int
      ; actual : int
      }
  | Record_outcome_observation_not_mismatch of identity
  | Record_field_invalid of
      { field : string
      ; value : Yojson.Safe.t
      }

type subject =
  | Registry_root
  | Recovery_root
  | Lanes_root
  | Lane_root of owner
  | Area of area * owner
  | Record of area * owner * operation_id

type operation =
  | Inspect_directory
  | Create_directory
  | Open_directory
  | Sync_directory
  | Read_directory
  | Inspect_record
  | Open_record
  | Read_record
  | Decode_record
  | Create_record
  | Apply_permissions
  | Write_record
  | Sync_record
  | Close_record
  | Verify_record_identity
  | Remove_record

type failure_cause =
  | Validation_failed of validation_error
  | Io_failed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Write_failed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      ; bytes_written : int
      }
  | Unexpected_resource_kind of Eio.File.Stat.kind
  | Resource_identity_changed of
      { expected : identity
      ; actual : identity
      }
  | Posix_descriptor_unavailable
  | Existing_record_does_not_match
  | Created_record_identity_unavailable
  | Missing_record

type failure =
  { operation : operation
  ; subject : subject
  ; cause : failure_cause
  }

type transition_effect =
  | No_record_change
  | Layout_may_be_incomplete
  | Layout_ready
  | Active_record_state_unknown
  | Active_record_durable
  | Active_record_discharged
  | Owned_record_state_unknown_with_active
  | Owned_record_durable_with_active
  | Owned_record_durable
  | Owned_record_discharged
  | Forensic_record_state_unknown_with_source
  | Forensic_record_durable_with_source
  | Forensic_record_durable
  | Source_removal_durability_unknown of removal_transition

and removal_transition =
  | Discharge_active
  | Discharge_owned
  | Active_to_owned
  | Active_to_forensic
  | Owned_to_forensic

type transition_error =
  { store_effect : transition_effect
  ; failure : failure
  ; cleanup_failures : failure list
  }

exception Recovery_store_cancelled of
  exn * transition_effect * failure list

exception Store_failure of failure
exception Record_validation_failed of validation_error
exception Internal_unexpected_resource_kind of Eio.File.Stat.kind
exception Internal_resource_identity_changed of identity * identity
exception Internal_posix_descriptor_unavailable
exception Internal_existing_record_does_not_match
exception Internal_created_record_identity_unavailable
exception Internal_missing_record
exception Transition_failed of transition_error

let recovery_directory_leaf = "fs-publication-recovery"
let lanes_directory_leaf = "lanes"
let active_directory_leaf = "active"
let owned_directory_leaf = "owned"
let forensic_directory_leaf = "forensic"
let directory_permissions = 0o700
let record_permissions = 0o600
let record_schema = "masc.fs-publication-recovery"
let record_version = 1
let stage_prefix = ".masc_atomic_stage_"
let stage_suffix = ".dir"

let owner_of_string value =
  match Capability_leaf.of_string value with
  | Some owner -> Ok owner
  | None -> Error (Invalid_owner value)
;;

let owner_to_string = Capability_leaf.to_string
let equal_owner = Capability_leaf.equal

let operation_id_to_string operation_id = Uuidm.to_string operation_id
let equal_operation_id = Uuidm.equal
let record_name = operation_id_to_string

let operation_id_of_string value =
  match Uuidm.of_string value with
  | Some operation_id
    when String.equal (Uuidm.to_string operation_id) value ->
    Ok operation_id
  | None | Some _ -> Error (Invalid_operation_id value)
;;

let stage_name operation_id =
  Printf.sprintf
    "%s%s%s"
    stage_prefix
    (operation_id_to_string operation_id)
    stage_suffix
;;

let equal_identity (left : identity) (right : identity) =
  Int64.equal left.dev right.dev && Int64.equal left.ino right.ino
;;

let identity_dev (identity : identity) = identity.dev
let identity_ino (identity : identity) = identity.ino

let identity ~dev ~ino =
  let value = { dev; ino } in
  if Int64.compare dev 0L < 0 || Int64.compare ino 0L < 0
  then Error (Invalid_identity value)
  else Ok value
;;

let valid_absolute_path value =
  not (String.equal value "")
  && not (Filename.is_relative value)
  && not (String.contains value '\x00')
;;

let locator
      ~allowed_root_path
      ~allowed_root
      ~parent_components
      ~parent
      ~target_leaf
      ~initial_target
  =
  if not (valid_absolute_path allowed_root_path)
  then Error (Invalid_allowed_root_path allowed_root_path)
  else
    let rec parse_components index parsed = function
      | [] -> Ok (List.rev parsed)
      | value :: rest ->
        (match Capability_leaf.of_string value with
         | None -> Error (Invalid_parent_component { index; value })
         | Some component ->
           parse_components (index + 1) (component :: parsed) rest)
    in
    (match parse_components 0 [] parent_components with
     | Error _ as error -> error
     | Ok parent_components ->
       if parent_components = [] && not (equal_identity allowed_root parent)
       then
         Error
           (Empty_parent_path_identity_mismatch { allowed_root; parent })
       else
         (match Capability_leaf.of_string target_leaf with
          | None -> Error (Invalid_target_leaf target_leaf)
          | Some target_leaf ->
            Ok
              { allowed_root_path
              ; allowed_root
              ; parent_components
              ; parent
              ; target_leaf
              ; initial_target
              }))
;;

let locator_allowed_root_path (locator : locator) = locator.allowed_root_path
let locator_allowed_root (locator : locator) = locator.allowed_root

let locator_parent_components (locator : locator) =
  List.map Capability_leaf.to_string locator.parent_components
;;

let locator_parent (locator : locator) = locator.parent

let locator_target_leaf (locator : locator) =
  Capability_leaf.to_string locator.target_leaf
;;

let locator_initial_target (locator : locator) = locator.initial_target
let prepared_owner (prepared : prepared) = prepared.owner
let prepared_operation_id (prepared : prepared) = prepared.operation_id
let prepared_locator (prepared : prepared) = prepared.locator
let prepared_permissions (prepared : prepared) = prepared.permissions
let bound_prepared (bound : bound) = bound.prepared
let bound_stage_identity (bound : bound) = bound.stage_identity
let bound_stage_name (bound : bound) = stage_name bound.prepared.operation_id
let forensic_source (forensic : forensic) = forensic.source

let forensic_owner (forensic : forensic) =
  match forensic.source with
  | Prepared_source (prepared, _) -> prepared.owner
  | Bound_source (bound, _) -> bound.prepared.owner
;;

let forensic_operation_id (forensic : forensic) =
  match forensic.source with
  | Prepared_source (prepared, _) -> prepared.operation_id
  | Bound_source (bound, _) -> bound.prepared.operation_id
;;

let store_owner (store : store) = store.owner

let permissions_of_int permissions =
  if permissions < 0 || permissions land lnot 0o7777 <> 0
  then Error (Invalid_permissions permissions)
  else Ok permissions
;;

let permissions_to_int permissions = permissions

let identity_of_stat (stat : Eio.File.Stat.t) =
  { dev = stat.dev; ino = stat.ino }
;;

let entry_observation_to_string = function
  | Absent -> "absent"
  | Present { kind; identity } ->
    Format.asprintf
      "present(kind=%a,dev=%Ld,ino=%Ld)"
      Eio.File.Stat.pp_kind
      kind
      identity.dev
      identity.ino
;;

let validation_error_to_string = function
  | Invalid_owner value -> Printf.sprintf "invalid owner component %S" value
  | Invalid_operation_id value ->
    Printf.sprintf "invalid canonical operation id %S" value
  | Invalid_identity { dev; ino } ->
    Printf.sprintf "invalid identity dev=%Ld ino=%Ld" dev ino
  | Invalid_allowed_root_path value ->
    Printf.sprintf "invalid absolute allowed-root path %S" value
  | Empty_parent_path_identity_mismatch { allowed_root; parent } ->
    Printf.sprintf
      "empty parent path identity mismatch allowed_root=%Ld:%Ld parent=%Ld:%Ld"
      allowed_root.dev
      allowed_root.ino
      parent.dev
      parent.ino
  | Invalid_parent_component { index; value } ->
    Printf.sprintf "invalid parent component index=%d value=%S" index value
  | Invalid_target_leaf value ->
    Printf.sprintf "invalid target leaf %S" value
  | Invalid_permissions permissions ->
    Printf.sprintf "invalid permissions %#o" permissions
  | Invalid_record_json { exception_; _ } ->
    Printf.sprintf "invalid record JSON: %s" (Printexc.to_string exception_)
  | Invalid_record_shape -> "record has an unexpected field set or shape"
  | Unsupported_record_version version ->
    Printf.sprintf "unsupported record version %d" version
  | Record_state_mismatch -> "record state does not match its store"
  | Record_owner_mismatch { expected; actual } ->
    Printf.sprintf
      "record owner mismatch expected=%S actual=%S"
      (owner_to_string expected)
      (owner_to_string actual)
  | Record_operation_id_mismatch { expected; actual } ->
    Printf.sprintf
      "record operation id mismatch expected=%s actual=%s"
      (operation_id_to_string expected)
      (operation_id_to_string actual)
  | Record_stage_leaf_mismatch { expected; actual } ->
    Printf.sprintf
      "record stage leaf mismatch expected=%S actual=%S"
      expected
      actual
  | Record_identity_mismatch { expected; actual } ->
    Printf.sprintf
      "record identity mismatch expected=%Ld:%Ld actual=%Ld:%Ld"
      expected.dev
      expected.ino
      actual.dev
      actual.ino
  | Record_kind_mismatch { expected; actual } ->
    Format.asprintf
      "record kind mismatch expected=%a actual=%a"
      Eio.File.Stat.pp_kind
      expected
      Eio.File.Stat.pp_kind
      actual
  | Record_permissions_mismatch { expected; actual } ->
    Printf.sprintf
      "record directory permissions mismatch expected=%#o actual=%#o"
      expected
      actual
  | Record_outcome_observation_not_mismatch identity ->
    Printf.sprintf
      "recovery outcome observation still confirms directory identity=%Ld:%Ld"
      identity.dev
      identity.ino
  | Record_field_invalid { field; value } ->
    Printf.sprintf
      "record field %S is invalid: %s"
      field
      (Yojson.Safe.to_string value)
;;

let raise_invalid error = raise (Record_validation_failed error)

let strict_fields ~expected = function
  | `Assoc fields ->
    let actual_names = List.map fst fields |> List.sort String.compare in
    let expected_names = List.sort String.compare expected in
    if actual_names = expected_names then fields else raise_invalid Invalid_record_shape
  | _ -> raise_invalid Invalid_record_shape
;;

let field fields name =
  match List.assoc_opt name fields with
  | Some value -> value
  | None -> raise_invalid Invalid_record_shape
;;

let string_field fields name =
  match field fields name with
  | `String value -> value
  | value -> raise_invalid (Record_field_invalid { field = name; value })
;;

let int_field fields name =
  match field fields name with
  | `Int value -> value
  | value -> raise_invalid (Record_field_invalid { field = name; value })
;;

let validate_header fields ~state =
  let schema = string_field fields "schema" in
  if not (String.equal schema record_schema)
  then
    raise_invalid
      (Record_field_invalid { field = "schema"; value = `String schema });
  let version = int_field fields "version" in
  if version <> record_version
  then raise_invalid (Unsupported_record_version version);
  let actual_state = string_field fields "state" in
  if not (String.equal state actual_state)
  then raise_invalid Record_state_mismatch
;;

let int64_to_json value = `String (Int64.to_string value)

let int64_of_json ~field:name = function
  | `String raw ->
    (match Int64.of_string_opt raw with
     | Some value when String.equal (Int64.to_string value) raw -> value
     | None | Some _ ->
       raise_invalid
         (Record_field_invalid { field = name; value = `String raw }))
  | value -> raise_invalid (Record_field_invalid { field = name; value })
;;

let identity_to_json (identity : identity) =
  `Assoc
    [ "dev", int64_to_json identity.dev
    ; "ino", int64_to_json identity.ino
    ]
;;

let identity_of_json ~field:name json =
  let fields = strict_fields ~expected:[ "dev"; "ino" ] json in
  let dev = int64_of_json ~field:(name ^ ".dev") (field fields "dev") in
  let ino = int64_of_json ~field:(name ^ ".ino") (field fields "ino") in
  match identity ~dev ~ino with
  | Ok identity -> identity
  | Error error -> raise_invalid error
;;

let kind_to_string = function
  | `Unknown -> "unknown"
  | `Fifo -> "fifo"
  | `Character_special -> "character_special"
  | `Directory -> "directory"
  | `Block_device -> "block_device"
  | `Regular_file -> "regular_file"
  | `Symbolic_link -> "symbolic_link"
  | `Socket -> "socket"
;;

let kind_of_json ~field:name = function
  | `String "unknown" -> `Unknown
  | `String "fifo" -> `Fifo
  | `String "character_special" -> `Character_special
  | `String "directory" -> `Directory
  | `String "block_device" -> `Block_device
  | `String "regular_file" -> `Regular_file
  | `String "symbolic_link" -> `Symbolic_link
  | `String "socket" -> `Socket
  | value -> raise_invalid (Record_field_invalid { field = name; value })
;;

let observation_to_json = function
  | Absent -> `Assoc [ "presence", `String "absent" ]
  | Present { kind; identity } ->
    `Assoc
      [ "presence", `String "present"
      ; "kind", `String (kind_to_string kind)
      ; "identity", identity_to_json identity
      ]
;;

let observation_of_json ~field:name json =
  match json with
  | `Assoc [ ("presence", `String "absent") ] -> Absent
  | _ ->
    let fields =
      strict_fields ~expected:[ "presence"; "kind"; "identity" ] json
    in
    let presence = string_field fields "presence" in
    if not (String.equal presence "present")
    then
      raise_invalid
        (Record_field_invalid
           { field = name ^ ".presence"; value = `String presence });
    let kind = kind_of_json ~field:(name ^ ".kind") (field fields "kind") in
    let identity =
      identity_of_json ~field:(name ^ ".identity") (field fields "identity")
    in
    Present { kind; identity }
;;

let mismatch_to_json (mismatch : resource_mismatch) =
  `Assoc
    [ "expected", identity_to_json mismatch.expected
    ; "observed", observation_to_json mismatch.observed
    ]
;;

let mismatch_of_json ~field:name json =
  let fields = strict_fields ~expected:[ "expected"; "observed" ] json in
  { expected =
      identity_of_json ~field:(name ^ ".expected") (field fields "expected")
  ; observed = observation_of_json ~field:(name ^ ".observed") (field fields "observed")
  }
;;

let owner_of_json fields =
  let raw = string_field fields "owner" in
  match owner_of_string raw with
  | Ok owner -> owner
  | Error error -> raise_invalid error
;;

let operation_id_of_json fields =
  let raw = string_field fields "operation_id" in
  match operation_id_of_string raw with
  | Ok operation_id -> operation_id
  | Error error -> raise_invalid error
;;

let prepared_to_json (prepared : prepared) =
  `Assoc
    [ "schema", `String record_schema
    ; "version", `Int record_version
    ; "state", `String "prepared"
    ; "owner", `String (owner_to_string prepared.owner)
    ; "operation_id", `String (operation_id_to_string prepared.operation_id)
    ; "allowed_root_path", `String prepared.locator.allowed_root_path
    ; "allowed_root", identity_to_json prepared.locator.allowed_root
    ; ( "parent_components"
      , `List
          (List.map
             (fun component -> `String (Capability_leaf.to_string component))
             prepared.locator.parent_components) )
    ; "parent", identity_to_json prepared.locator.parent
    ; "target_leaf", `String (Capability_leaf.to_string prepared.locator.target_leaf)
    ; "initial_target", observation_to_json prepared.locator.initial_target
    ; "permissions", `Int prepared.permissions
    ]
;;

let prepared_fields =
  [ "schema"
  ; "version"
  ; "state"
  ; "owner"
  ; "operation_id"
  ; "allowed_root_path"
  ; "allowed_root"
  ; "parent_components"
  ; "parent"
  ; "target_leaf"
  ; "initial_target"
  ; "permissions"
  ]
;;

let prepared_of_json json =
  let fields = strict_fields ~expected:prepared_fields json in
  validate_header fields ~state:"prepared";
  let owner = owner_of_json fields in
  let operation_id = operation_id_of_json fields in
  let allowed_root_path = string_field fields "allowed_root_path" in
  let allowed_root =
    identity_of_json ~field:"allowed_root" (field fields "allowed_root")
  in
  let parent_components =
    match field fields "parent_components" with
    | `List values ->
      List.mapi
        (fun index -> function
           | `String value -> value
           | value ->
             raise_invalid
               (Record_field_invalid
                  { field = Printf.sprintf "parent_components[%d]" index
                  ; value
                  }))
        values
    | value ->
      raise_invalid
        (Record_field_invalid { field = "parent_components"; value })
  in
  let parent = identity_of_json ~field:"parent" (field fields "parent") in
  let target_leaf = string_field fields "target_leaf" in
  let initial_target =
    observation_of_json ~field:"initial_target" (field fields "initial_target")
  in
  let permissions = int_field fields "permissions" in
  let locator =
    match
      locator
        ~allowed_root_path
        ~allowed_root
        ~parent_components
        ~parent
        ~target_leaf
        ~initial_target
    with
    | Ok locator -> locator
    | Error error -> raise_invalid error
  in
  let permissions =
    match permissions_of_int permissions with
    | Ok permissions -> permissions
    | Error error -> raise_invalid error
  in
  { owner; operation_id; locator; permissions }
;;

let bound_to_json (bound : bound) =
  let prepared_fields =
    match prepared_to_json bound.prepared with
    | `Assoc fields -> fields
    | _ -> raise_invalid Invalid_record_shape
  in
  `Assoc
    (List.map
       (fun (name, value) ->
          if String.equal name "state" then name, `String "bound" else name, value)
       prepared_fields
     @ [ "stage_name", `String (bound_stage_name bound)
       ; "stage_identity", identity_to_json bound.stage_identity
       ])
;;

let bound_fields = prepared_fields @ [ "stage_name"; "stage_identity" ]

let bound_of_json json =
  let fields = strict_fields ~expected:bound_fields json in
  validate_header fields ~state:"bound";
  let prepared_json =
    `Assoc
      (List.filter_map
         (fun name ->
            if String.equal name "state"
            then Some (name, `String "prepared")
            else Some (name, field fields name))
         prepared_fields)
  in
  let prepared = prepared_of_json prepared_json in
  let expected_stage_name = stage_name prepared.operation_id in
  let actual_stage_name = string_field fields "stage_name" in
  if not (String.equal expected_stage_name actual_stage_name)
  then
    raise_invalid
      (Record_stage_leaf_mismatch
         { expected = expected_stage_name; actual = actual_stage_name });
  let stage_identity =
    identity_of_json ~field:"stage_identity" (field fields "stage_identity")
  in
  { prepared; stage_identity }
;;

let prepared_outcome_to_json = function
  | Recovered_unmaterialized ->
    `Assoc [ "kind", `String "recovered_unmaterialized" ]
  | Prepared_allowed_root_mismatch mismatch ->
    `Assoc
      [ "kind", `String "prepared_allowed_root_mismatch"
      ; "mismatch", mismatch_to_json mismatch
      ]
  | Prepared_parent_mismatch mismatch ->
    `Assoc
      [ "kind", `String "prepared_parent_mismatch"
      ; "mismatch", mismatch_to_json mismatch
      ]
  | Preserved_unbound_stage { kind; identity } ->
    `Assoc
      [ "kind", `String "preserved_unbound_stage"
      ; "stage_kind", `String (kind_to_string kind)
      ; "stage_identity", identity_to_json identity
      ]
;;

let prepared_outcome_of_json json =
  match json with
  | `Assoc [ ("kind", `String "recovered_unmaterialized") ] ->
    Recovered_unmaterialized
  | _ ->
    (match json with
     | `Assoc fields ->
       (match List.assoc_opt "kind" fields with
        | Some (`String "prepared_allowed_root_mismatch") ->
          let fields = strict_fields ~expected:[ "kind"; "mismatch" ] json in
          Prepared_allowed_root_mismatch
            (mismatch_of_json ~field:"mismatch" (field fields "mismatch"))
        | Some (`String "prepared_parent_mismatch") ->
          let fields = strict_fields ~expected:[ "kind"; "mismatch" ] json in
          Prepared_parent_mismatch
            (mismatch_of_json ~field:"mismatch" (field fields "mismatch"))
        | Some (`String "preserved_unbound_stage") ->
          let fields =
            strict_fields
              ~expected:[ "kind"; "stage_kind"; "stage_identity" ]
              json
          in
          Preserved_unbound_stage
            { kind =
                kind_of_json ~field:"stage_kind" (field fields "stage_kind")
            ; identity =
                identity_of_json
                  ~field:"stage_identity"
                  (field fields "stage_identity")
            }
        | Some value ->
          raise_invalid (Record_field_invalid { field = "outcome.kind"; value })
        | None -> raise_invalid Invalid_record_shape)
     | _ -> raise_invalid Invalid_record_shape)
;;

let bound_outcome_to_json = function
  | Bound_stage_absent { observed_target } ->
    `Assoc
      [ "kind", `String "bound_stage_absent"
      ; "observed_target", observation_to_json observed_target
      ]
  | Bound_allowed_root_mismatch mismatch ->
    `Assoc
      [ "kind", `String "bound_allowed_root_mismatch"
      ; "mismatch", mismatch_to_json mismatch
      ]
  | Bound_parent_mismatch mismatch ->
    `Assoc
      [ "kind", `String "bound_parent_mismatch"
      ; "mismatch", mismatch_to_json mismatch
      ]
  | Bound_stage_mismatch { mismatch; observed_target } ->
    `Assoc
      [ "kind", `String "bound_stage_mismatch"
      ; "mismatch", mismatch_to_json mismatch
      ; "observed_target", observation_to_json observed_target
      ]
  | Preserved_bound_stage { kind; identity; observed_target } ->
    `Assoc
      [ "kind", `String "preserved_bound_stage"
      ; "stage_kind", `String (kind_to_string kind)
      ; "stage_identity", identity_to_json identity
      ; "observed_target", observation_to_json observed_target
      ]
;;

let bound_outcome_of_json json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "bound_stage_absent") ->
       let fields =
         strict_fields ~expected:[ "kind"; "observed_target" ] json
       in
       Bound_stage_absent
         { observed_target =
             observation_of_json
               ~field:"observed_target"
               (field fields "observed_target")
         }
     | Some (`String "bound_allowed_root_mismatch") ->
       let fields = strict_fields ~expected:[ "kind"; "mismatch" ] json in
       Bound_allowed_root_mismatch
         (mismatch_of_json ~field:"mismatch" (field fields "mismatch"))
     | Some (`String "bound_parent_mismatch") ->
       let fields = strict_fields ~expected:[ "kind"; "mismatch" ] json in
       Bound_parent_mismatch
         (mismatch_of_json ~field:"mismatch" (field fields "mismatch"))
     | Some (`String "bound_stage_mismatch") ->
       let fields =
         strict_fields
           ~expected:[ "kind"; "mismatch"; "observed_target" ]
           json
       in
       Bound_stage_mismatch
         { mismatch =
             mismatch_of_json ~field:"mismatch" (field fields "mismatch")
         ; observed_target =
             observation_of_json
               ~field:"observed_target"
               (field fields "observed_target")
         }
     | Some (`String "preserved_bound_stage") ->
       let fields =
         strict_fields
           ~expected:
             [ "kind"; "stage_kind"; "stage_identity"; "observed_target" ]
           json
       in
       Preserved_bound_stage
         { kind =
             kind_of_json
               ~field:"stage_kind"
               (field fields "stage_kind")
         ; identity =
             identity_of_json
               ~field:"stage_identity"
               (field fields "stage_identity")
         ; observed_target =
             observation_of_json
               ~field:"observed_target"
               (field fields "observed_target")
         }
     | Some value ->
       raise_invalid (Record_field_invalid { field = "outcome.kind"; value })
     | None -> raise_invalid Invalid_record_shape)
  | _ -> raise_invalid Invalid_record_shape
;;

let forensic_to_json (forensic : forensic) =
  let owner = forensic_owner forensic in
  let operation_id = forensic_operation_id forensic in
  let source_state, source, outcome =
    match forensic.source with
    | Prepared_source (prepared, outcome) ->
      "prepared", prepared_to_json prepared, prepared_outcome_to_json outcome
    | Bound_source (bound, outcome) ->
      "bound", bound_to_json bound, bound_outcome_to_json outcome
  in
  `Assoc
    [ "schema", `String record_schema
    ; "version", `Int record_version
    ; "state", `String "forensic"
    ; "owner", `String (owner_to_string owner)
    ; "operation_id", `String (operation_id_to_string operation_id)
    ; "source_state", `String source_state
    ; "source", source
    ; "outcome", outcome
    ]
;;

let forensic_fields =
  [ "schema"
  ; "version"
  ; "state"
  ; "owner"
  ; "operation_id"
  ; "source_state"
  ; "source"
  ; "outcome"
  ]
;;

let validate_directory_mismatch_observation mismatch =
  match mismatch.observed with
  | Absent -> Ok ()
  | Present { kind; identity }
    when kind <> `Directory || not (equal_identity identity mismatch.expected) ->
    Ok ()
  | Present _ ->
    Error (Record_outcome_observation_not_mismatch mismatch.expected)
;;

let validate_prepared_recovery_outcome (prepared : prepared) = function
  | Recovered_unmaterialized | Preserved_unbound_stage _ -> Ok ()
  | Prepared_allowed_root_mismatch mismatch ->
    if equal_identity mismatch.expected prepared.locator.allowed_root
    then validate_directory_mismatch_observation mismatch
    else
      Error
        (Record_identity_mismatch
           { expected = prepared.locator.allowed_root
           ; actual = mismatch.expected
           })
  | Prepared_parent_mismatch mismatch ->
    if equal_identity mismatch.expected prepared.locator.parent
    then validate_directory_mismatch_observation mismatch
    else
      Error
        (Record_identity_mismatch
           { expected = prepared.locator.parent; actual = mismatch.expected })
;;

let validate_bound_recovery_outcome (bound : bound) = function
  | Bound_stage_absent _ -> Ok ()
  | Preserved_bound_stage { kind; identity; _ } ->
    if kind <> `Directory
    then Error (Record_kind_mismatch { expected = `Directory; actual = kind })
    else if not (equal_identity identity bound.stage_identity)
    then
      Error
        (Record_identity_mismatch
           { expected = bound.stage_identity; actual = identity })
    else Ok ()
  | Bound_allowed_root_mismatch mismatch ->
    if equal_identity mismatch.expected bound.prepared.locator.allowed_root
    then validate_directory_mismatch_observation mismatch
    else
      Error
        (Record_identity_mismatch
           { expected = bound.prepared.locator.allowed_root
           ; actual = mismatch.expected
           })
  | Bound_parent_mismatch mismatch ->
    if equal_identity mismatch.expected bound.prepared.locator.parent
    then validate_directory_mismatch_observation mismatch
    else
      Error
        (Record_identity_mismatch
           { expected = bound.prepared.locator.parent
           ; actual = mismatch.expected
           })
  | Bound_stage_mismatch { mismatch; _ } ->
    if equal_identity mismatch.expected bound.stage_identity
    then validate_directory_mismatch_observation mismatch
    else
      Error
        (Record_identity_mismatch
           { expected = bound.stage_identity; actual = mismatch.expected })
;;

let forensic_of_json json =
  let fields = strict_fields ~expected:forensic_fields json in
  validate_header fields ~state:"forensic";
  let owner = owner_of_json fields in
  let operation_id = operation_id_of_json fields in
  let source =
    match string_field fields "source_state" with
    | "prepared" ->
      let prepared = prepared_of_json (field fields "source") in
      let outcome = prepared_outcome_of_json (field fields "outcome") in
      Prepared_source (prepared, outcome)
    | "bound" ->
      let bound = bound_of_json (field fields "source") in
      let outcome = bound_outcome_of_json (field fields "outcome") in
      Bound_source (bound, outcome)
    | _ -> raise_invalid Record_state_mismatch
  in
  let source_owner, source_operation_id =
    match source with
    | Prepared_source (prepared, _) -> prepared.owner, prepared.operation_id
    | Bound_source (bound, _) ->
      bound.prepared.owner, bound.prepared.operation_id
  in
  if not (equal_owner owner source_owner)
  then
    raise_invalid
      (Record_owner_mismatch { expected = owner; actual = source_owner });
  if not (equal_operation_id operation_id source_operation_id)
  then
    raise_invalid
      (Record_operation_id_mismatch
         { expected = operation_id; actual = source_operation_id });
  (match source with
   | Prepared_source (prepared, outcome) ->
     (match validate_prepared_recovery_outcome prepared outcome with
      | Ok () -> ()
      | Error error -> raise_invalid error)
   | Bound_source (bound, outcome) ->
     (match validate_bound_recovery_outcome bound outcome with
      | Ok () -> ()
      | Error error -> raise_invalid error));
  { source }
;;

let encode_json json = Yojson.Safe.to_string json ^ "\n"

let decode_json raw decoder =
  try
    let json = Yojson.Safe.from_string raw in
    Ok (decoder json)
  with
  | Record_validation_failed error -> Error error
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Error (Invalid_record_json { exception_; backtrace })
;;

let encode_prepared (prepared : prepared) =
  prepared_to_json prepared |> encode_json
;;

let encode_bound (bound : bound) = bound_to_json bound |> encode_json

let encode_forensic (forensic : forensic) =
  forensic_to_json forensic |> encode_json
;;
let decode_prepared raw = decode_json raw prepared_of_json
let decode_bound raw = decode_json raw bound_of_json
let decode_forensic raw = decode_json raw forensic_of_json

let validate_record_owner_and_id ~owner ~operation_id ~record_owner ~record_id =
  if not (equal_owner owner record_owner)
  then
    Error
      (Record_owner_mismatch { expected = owner; actual = record_owner })
  else if not (equal_operation_id operation_id record_id)
  then
    Error
      (Record_operation_id_mismatch
         { expected = operation_id; actual = record_id })
  else Ok ()
;;

let area_to_string = function
  | Active -> "active"
  | Owned -> "owned"
  | Forensic -> "forensic"
;;

let subject_to_string = function
  | Registry_root -> "registry_root"
  | Recovery_root -> "recovery_root"
  | Lanes_root -> "lanes_root"
  | Lane_root owner -> Printf.sprintf "lane(%S)" (owner_to_string owner)
  | Area (area, owner) ->
    Printf.sprintf "%s(%S)" (area_to_string area) (owner_to_string owner)
  | Record (area, owner, operation_id) ->
    Printf.sprintf
      "%s(%S)/%s"
      (area_to_string area)
      (owner_to_string owner)
      (record_name operation_id)
;;

let operation_to_string = function
  | Inspect_directory -> "inspect_directory"
  | Create_directory -> "create_directory"
  | Open_directory -> "open_directory"
  | Sync_directory -> "sync_directory"
  | Read_directory -> "read_directory"
  | Inspect_record -> "inspect_record"
  | Open_record -> "open_record"
  | Read_record -> "read_record"
  | Decode_record -> "decode_record"
  | Create_record -> "create_record"
  | Apply_permissions -> "apply_permissions"
  | Write_record -> "write_record"
  | Sync_record -> "sync_record"
  | Close_record -> "close_record"
  | Verify_record_identity -> "verify_record_identity"
  | Remove_record -> "remove_record"
;;

let transition_effect_to_string = function
  | No_record_change -> "no_record_change"
  | Layout_may_be_incomplete -> "layout_may_be_incomplete"
  | Layout_ready -> "layout_ready"
  | Active_record_state_unknown -> "active_record_state_unknown"
  | Active_record_durable -> "active_record_durable"
  | Active_record_discharged -> "active_record_discharged"
  | Owned_record_state_unknown_with_active ->
    "owned_record_state_unknown_with_active"
  | Owned_record_durable_with_active -> "owned_record_durable_with_active"
  | Owned_record_durable -> "owned_record_durable"
  | Owned_record_discharged -> "owned_record_discharged"
  | Forensic_record_state_unknown_with_source ->
    "forensic_record_state_unknown_with_source"
  | Forensic_record_durable_with_source ->
    "forensic_record_durable_with_source"
  | Forensic_record_durable -> "forensic_record_durable"
  | Source_removal_durability_unknown transition ->
    let source_area, destination =
      match transition with
      | Discharge_active -> Active, "none"
      | Discharge_owned -> Owned, "none"
      | Active_to_owned -> Active, area_to_string Owned
      | Active_to_forensic -> Active, area_to_string Forensic
      | Owned_to_forensic -> Owned, area_to_string Forensic
    in
    Printf.sprintf
      "source_removal_durability_unknown(source=%s,destination=%s)"
      (area_to_string source_area)
      destination
;;

let failure_to_string (failure : failure) =
  let cause =
    match failure.cause with
    | Validation_failed error -> validation_error_to_string error
    | Io_failed { exception_; _ } -> Printexc.to_string exception_
    | Write_failed { exception_; bytes_written; _ } ->
      Printf.sprintf
        "write failed after bytes_written=%d: %s"
        bytes_written
        (Printexc.to_string exception_)
    | Unexpected_resource_kind kind ->
      Format.asprintf "unexpected resource kind %a" Eio.File.Stat.pp_kind kind
    | Resource_identity_changed { expected; actual } ->
      Printf.sprintf
        "resource identity changed expected=%Ld:%Ld actual=%Ld:%Ld"
        expected.dev
        expected.ino
        actual.dev
        actual.ino
    | Posix_descriptor_unavailable -> "POSIX descriptor unavailable"
    | Existing_record_does_not_match -> "existing record does not match"
    | Created_record_identity_unavailable ->
      "created record identity unavailable"
    | Missing_record -> "record is missing"
  in
  Printf.sprintf
    "operation=%s subject=%s cause=%s"
    (operation_to_string failure.operation)
    (subject_to_string failure.subject)
    cause
;;

let transition_error_to_string (error : transition_error) =
  let cleanup =
    match error.cleanup_failures with
    | [] -> ""
    | failures ->
      failures
      |> List.map failure_to_string
      |> String.concat "; "
      |> Printf.sprintf " cleanup_failures=[%s]"
  in
  Printf.sprintf
    "effect=%s failure=(%s)%s"
    (transition_effect_to_string error.store_effect)
    (failure_to_string error.failure)
    cleanup
;;

let cause_of_exception exception_ backtrace =
  match exception_ with
  | Record_validation_failed error -> Validation_failed error
  | Internal_unexpected_resource_kind kind -> Unexpected_resource_kind kind
  | Internal_resource_identity_changed (expected, actual) ->
    Resource_identity_changed { expected; actual }
  | Internal_posix_descriptor_unavailable -> Posix_descriptor_unavailable
  | Internal_existing_record_does_not_match ->
    Existing_record_does_not_match
  | Internal_created_record_identity_unavailable ->
    Created_record_identity_unavailable
  | Internal_missing_record -> Missing_record
  | exception_ -> Io_failed { exception_; backtrace }
;;

let make_failure ~operation ~subject exception_ backtrace =
  { operation; subject; cause = cause_of_exception exception_ backtrace }
;;

let raise_io ~operation ~subject f =
  try f () with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Store_failure _ as failure -> raise failure
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    raise
      (Store_failure
         (make_failure ~operation ~subject exception_ backtrace))
;;

let raise_validation ~operation ~subject validation_error =
  raise
    (Store_failure
       { operation; subject; cause = Validation_failed validation_error })
;;

let transition_error ~store_effect failure =
  { store_effect; failure; cleanup_failures = [] }
;;

let protect_result ~store_effect f =
  try Ok (f ()) with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Transition_failed error -> Error error
  | Store_failure failure -> Error (transition_error ~store_effect failure)
;;

let run_layout f =
  let observed_effect = ref Layout_may_be_incomplete in
  try
    let value = Eio.Cancel.protect f in
    observed_effect := Layout_ready;
    Eio.Fiber.check ();
    Ok value
  with
  | Eio.Cancel.Cancelled reason ->
    let backtrace = Printexc.get_raw_backtrace () in
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

let sync_directory ~subject directory =
  raise_io ~operation:Sync_directory ~subject (fun () ->
    Eio.Path.with_open_in Eio.Path.(directory / ".") @@ fun file ->
    match Eio_unix.Resource.fd_opt file with
    | None -> raise Internal_posix_descriptor_unavailable
    | Some fd ->
      Eio_unix.run_in_systhread
        ~label:"fs-compat-recovery-directory-fsync"
        (fun () ->
           Eio_unix.Fd.use_exn
             "fs-compat-recovery-directory-fsync"
             fd
             Unix.fsync);
      Eio.Fiber.check ())
;;

let verify_opened_directory ~subject ~lexical_identity directory =
  raise_io ~operation:Open_directory ~subject (fun () ->
    Eio.Path.with_open_in Eio.Path.(directory / ".") @@ fun file ->
    let stat = Eio.File.stat file in
    if stat.kind <> `Directory
    then raise (Internal_unexpected_resource_kind stat.kind);
    let opened_identity = identity_of_stat stat in
    if not (equal_identity lexical_identity opened_identity)
    then
      raise
        (Internal_resource_identity_changed
           (lexical_identity, opened_identity));
    stat)
;;

let set_directory_permissions ~subject directory =
  raise_io ~operation:Apply_permissions ~subject (fun () ->
    Eio.Path.with_open_in Eio.Path.(directory / ".") @@ fun file ->
    match Eio_unix.Resource.fd_opt file with
    | None -> raise Internal_posix_descriptor_unavailable
    | Some fd ->
      Eio_unix.run_in_systhread
        ~label:"fs-compat-recovery-directory-fchmod"
        (fun () ->
           Eio_unix.Fd.use_exn
             "fs-compat-recovery-directory-fchmod"
             fd
             (fun unix_fd -> Unix.fchmod unix_fd directory_permissions));
      Eio.Fiber.check ())
;;

let verify_directory_permissions ~subject directory =
  let stat =
    raise_io ~operation:Inspect_directory ~subject (fun () ->
      Eio.Path.with_open_in Eio.Path.(directory / ".") Eio.File.stat)
  in
  let actual = stat.perm land 0o7777 in
  if actual <> directory_permissions
  then
    raise_validation
      ~operation:Inspect_directory
      ~subject
      (Record_permissions_mismatch
         { expected = directory_permissions; actual })
;;

let prepare_directory_entry ~parent ~leaf ~subject =
  let path = Eio.Path.(parent / leaf) in
  let creation =
    raise_io ~operation:Create_directory ~subject (fun () ->
      try
        Eio.Path.mkdir ~perm:directory_permissions path;
        `Created
      with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) -> `Existing)
  in
  let lexical =
    raise_io ~operation:Inspect_directory ~subject (fun () ->
      Eio.Path.stat ~follow:false path)
  in
  if lexical.kind <> `Directory
  then
    raise_validation
      ~operation:Inspect_directory
      ~subject
      (Record_kind_mismatch
         { expected = `Directory; actual = lexical.kind });
  let lexical_identity = identity_of_stat lexical in
  path, creation, lexical_identity
;;

let stabilize_directory
      ~parent
      ~parent_subject
      ~subject
      ~creation
      ~lexical_identity
      opened
  =
  let opened_stat =
    verify_opened_directory ~subject ~lexical_identity opened
  in
  let actual_permissions = opened_stat.perm land 0o7777 in
  (match creation with
   | `Created ->
     (* mkdir permissions are filtered through umask. fchmod the pinned
        directory before either directory or parent durability is acknowledged. *)
     set_directory_permissions ~subject opened
   | `Existing ->
     if actual_permissions <> directory_permissions
     then set_directory_permissions ~subject opened);
  (* Existing components receive the same barriers as newly created ones. A
     previous attempt may have reached mkdir/fchmod/child-fsync but failed
     before the parent fsync, so merely observing the path cannot prove the
     hierarchy durable. *)
  verify_directory_permissions ~subject opened;
  sync_directory ~subject opened;
  sync_directory ~subject:parent_subject parent
;;

let with_ensured_directory
      ~parent
      ~parent_subject
      ~leaf
      ~subject
      f
  =
  let path, creation, lexical_identity =
    prepare_directory_entry ~parent ~leaf ~subject
  in
  raise_io ~operation:Open_directory ~subject (fun () ->
    Eio.Path.with_open_dir path @@ fun opened ->
    let opened = (opened :> Eio.Fs.dir_ty Eio.Path.t) in
    stabilize_directory
      ~parent
      ~parent_subject
      ~subject
      ~creation
      ~lexical_identity
      opened;
    f opened)
;;

let open_ensured_directory
      ~sw
      ~parent
      ~parent_subject
      ~leaf
      ~subject
  =
  let path, creation, lexical_identity =
    prepare_directory_entry ~parent ~leaf ~subject
  in
  let opened =
    raise_io ~operation:Open_directory ~subject (fun () ->
      Eio.Path.open_dir ~sw path)
  in
  let opened = (opened :> Eio.Fs.dir_ty Eio.Path.t) in
  stabilize_directory
    ~parent
    ~parent_subject
    ~subject
    ~creation
    ~lexical_identity
    opened;
  opened
;;

let open_registry ~sw ~registry_root =
  run_layout (fun () ->
    let root_stat =
      raise_io ~operation:Inspect_directory ~subject:Registry_root (fun () ->
        Eio.Path.stat ~follow:true registry_root)
    in
    if root_stat.kind <> `Directory
    then
      raise_validation
        ~operation:Inspect_directory
        ~subject:Registry_root
        (Record_kind_mismatch
           { expected = `Directory; actual = root_stat.kind });
    with_ensured_directory
      ~parent:registry_root
      ~parent_subject:Registry_root
      ~leaf:recovery_directory_leaf
      ~subject:Recovery_root
    @@ fun recovery ->
    let lanes =
      open_ensured_directory
        ~sw
        ~parent:recovery
        ~parent_subject:Recovery_root
        ~leaf:lanes_directory_leaf
        ~subject:Lanes_root
    in
    { lanes })
;;

type owner_inventory_row =
  | Valid_owner of owner
  | Invalid_owner_name of string
  | Unexpected_owner_kind of
      { name : string
      ; kind : Eio.File.Stat.kind
      }
  | Missing_owner_entry of owner
  | Owner_entry_unavailable of
      { owner : owner
      ; error : transition_error
      }

type owner_inventory = owner_inventory_row list

let inventory_owners (registry : registry) =
  protect_result ~store_effect:No_record_change (fun () ->
    let names =
      raise_io ~operation:Read_directory ~subject:Lanes_root (fun () ->
        Eio.Path.read_dir registry.lanes)
    in
    List.map
      (fun name ->
         match owner_of_string name with
         | Error _ -> Invalid_owner_name name
         | Ok owner ->
           (try
              let kind =
                raise_io
                  ~operation:Inspect_directory
                  ~subject:(Lane_root owner)
                  (fun () ->
                     Eio.Path.kind
                       ~follow:false
                       Eio.Path.(registry.lanes / name))
              in
              match kind with
              | `Directory -> Valid_owner owner
              | `Not_found -> Missing_owner_entry owner
              | ( ( `Unknown
                  | `Fifo
                  | `Character_special
                  | `Block_device
                  | `Regular_file
                  | `Symbolic_link
                  | `Socket ) as
                  kind ) ->
                Unexpected_owner_kind { name; kind }
            with
            | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
            | Transition_failed error ->
              Owner_entry_unavailable { owner; error }
            | Store_failure failure ->
              Owner_entry_unavailable
                { owner
                ; error = transition_error ~store_effect:No_record_change failure
                }))
      names)
;;

let open_store_in_scope ~sw ~registry ~owner =
  run_layout (fun () ->
    with_ensured_directory
      ~parent:registry.lanes
      ~parent_subject:Lanes_root
      ~leaf:(owner_to_string owner)
      ~subject:(Lane_root owner)
    @@ fun lane ->
    let active =
      open_ensured_directory
        ~sw
        ~parent:lane
        ~parent_subject:(Lane_root owner)
        ~leaf:active_directory_leaf
        ~subject:(Area (Active, owner))
    in
    let owned =
      open_ensured_directory
        ~sw
        ~parent:lane
        ~parent_subject:(Lane_root owner)
        ~leaf:owned_directory_leaf
        ~subject:(Area (Owned, owner))
    in
    let forensic =
      open_ensured_directory
        ~sw
        ~parent:lane
        ~parent_subject:(Lane_root owner)
        ~leaf:forensic_directory_leaf
        ~subject:(Area (Forensic, owner))
    in
    { owner; active; owned; forensic })
;;

let with_store ~registry ~owner f =
  Eio.Switch.run @@ fun sw ->
  match open_store_in_scope ~sw ~registry ~owner with
  | Error _ as error -> error
  | Ok store -> Ok (f store)
;;

let area_directory (store : store) = function
  | Active -> store.active
  | Owned -> store.owned
  | Forensic -> store.forensic
;;

let record_path (store : store) area operation_id =
  Eio.Path.
    (area_directory store area / record_name operation_id)
;;

let record_subject (store : store) area operation_id =
  Record (area, store.owner, operation_id)
;;

let capture_failure ~operation ~subject f =
  try
    f ();
    []
  with
  | Store_failure failure -> [ failure ]
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    [ make_failure ~operation ~subject exception_ backtrace ]
;;

let close_resource_failures ~subject resource =
  capture_failure ~operation:Close_record ~subject (fun () ->
    Eio.Resource.close resource)
;;

let read_raw_record ~store ~area ~operation_id ~store_effect =
  let subject = record_subject store area operation_id in
  let path = record_path store area operation_id in
  let lexical =
    raise_io ~operation:Inspect_record ~subject (fun () ->
      Eio.Path.stat ~follow:false path)
  in
  if lexical.kind <> `Regular_file
  then
    raise_validation
      ~operation:Inspect_record
      ~subject
      (Record_kind_mismatch
         { expected = `Regular_file; actual = lexical.kind });
  let lexical_identity = identity_of_stat lexical in
  Eio.Switch.run @@ fun sw ->
  let resource = ref None in
  let cleanup () =
    match !resource with
    | None -> []
    | Some file ->
      resource := None;
      close_resource_failures ~subject file
  in
  try
    let file =
      raise_io ~operation:Open_record ~subject (fun () ->
        Eio.Path.open_in ~sw path)
    in
    resource := Some file;
    let opened =
      raise_io ~operation:Inspect_record ~subject (fun () ->
        Eio.File.stat file)
    in
    if opened.kind <> `Regular_file
    then
      raise_validation
        ~operation:Inspect_record
        ~subject
        (Record_kind_mismatch
           { expected = `Regular_file; actual = opened.kind });
    let opened_identity = identity_of_stat opened in
    if not (equal_identity lexical_identity opened_identity)
    then
      raise_validation
        ~operation:Verify_record_identity
        ~subject
        (Record_identity_mismatch
           { expected = lexical_identity; actual = opened_identity });
    let opened_permissions = opened.perm land 0o7777 in
    if opened_permissions <> record_permissions
    then
      raise_validation
        ~operation:Inspect_record
        ~subject
        (Record_permissions_mismatch
           { expected = record_permissions; actual = opened_permissions });
    let raw =
      raise_io ~operation:Read_record ~subject (fun () -> Eio.Flow.read_all file)
    in
    let after =
      raise_io ~operation:Verify_record_identity ~subject (fun () ->
        Eio.File.stat file)
    in
    let after_identity = identity_of_stat after in
    if after.kind <> `Regular_file
    then
      raise_validation
        ~operation:Verify_record_identity
        ~subject
        (Record_kind_mismatch
           { expected = `Regular_file; actual = after.kind });
    if not (equal_identity opened_identity after_identity)
    then
      raise_validation
        ~operation:Verify_record_identity
        ~subject
        (Record_identity_mismatch
           { expected = opened_identity; actual = after_identity });
    raise_io ~operation:Close_record ~subject (fun () ->
      Eio.Resource.close file);
    resource := None;
    raw, opened_identity
  with
  | Eio.Cancel.Cancelled reason as cancellation ->
    let backtrace = Printexc.get_raw_backtrace () in
    let cleanup_failures = Eio.Cancel.protect cleanup in
    if cleanup_failures = []
    then Printexc.raise_with_backtrace cancellation backtrace
    else
      Printexc.raise_with_backtrace
        (Eio.Cancel.Cancelled
           (Recovery_store_cancelled
              (reason, store_effect, cleanup_failures)))
        backtrace
  | Store_failure failure ->
    let cleanup_failures = Eio.Cancel.protect cleanup in
    if cleanup_failures = []
    then raise (Store_failure failure)
    else
      raise
        (Transition_failed
           { store_effect; failure; cleanup_failures })
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    let cleanup_failures = Eio.Cancel.protect cleanup in
    let failure =
      make_failure ~operation:Read_record ~subject exception_ backtrace
    in
    raise
      (Transition_failed
         { store_effect; failure; cleanup_failures })
;;

let decode_record ~store ~area ~operation_id ~decode ~owner_and_id raw =
  let subject = record_subject store area operation_id in
  let record =
    match decode raw with
    | Ok record -> record
    | Error error ->
      raise_validation ~operation:Decode_record ~subject error
  in
  let record_owner, record_id = owner_and_id record in
  (match
     validate_record_owner_and_id
       ~owner:store.owner
       ~operation_id
       ~record_owner
       ~record_id
   with
   | Ok () -> record
   | Error error ->
     raise_validation ~operation:Decode_record ~subject error)
;;

let read_prepared_internal ~store operation_id =
  let raw, identity =
    read_raw_record
      ~store
      ~area:Active
      ~operation_id
      ~store_effect:No_record_change
  in
  let prepared =
    decode_record
      ~store
      ~area:Active
      ~operation_id
      ~decode:decode_prepared
      ~owner_and_id:(fun prepared -> prepared.owner, prepared.operation_id)
      raw
  in
  prepared, raw, identity
;;

let read_bound_internal ~store operation_id =
  let raw, identity =
    read_raw_record
      ~store
      ~area:Owned
      ~operation_id
      ~store_effect:No_record_change
  in
  let bound =
    decode_record
      ~store
      ~area:Owned
      ~operation_id
      ~decode:decode_bound
      ~owner_and_id:(fun bound ->
        bound.prepared.owner, bound.prepared.operation_id)
      raw
  in
  bound, raw, identity
;;

let read_forensic_internal ~store operation_id =
  let raw, identity =
    read_raw_record
      ~store
      ~area:Forensic
      ~operation_id
      ~store_effect:No_record_change
  in
  let forensic =
    decode_record
      ~store
      ~area:Forensic
      ~operation_id
      ~decode:decode_forensic
      ~owner_and_id:(fun forensic ->
        forensic_owner forensic, forensic_operation_id forensic)
      raw
  in
  forensic, raw, identity
;;

type 'a lookup =
  | Missing
  | Found of 'a

let lookup_record ~store ~area ~operation_id read =
  let subject = record_subject store area operation_id in
  match
    raise_io ~operation:Inspect_record ~subject (fun () ->
      Eio.Path.kind ~follow:false (record_path store area operation_id))
  with
  | `Not_found -> Missing
  | `Regular_file -> Found (read ())
  | (#Eio.File.Stat.kind as kind) ->
    raise_validation
      ~operation:Inspect_record
      ~subject
      (Record_kind_mismatch { expected = `Regular_file; actual = kind })
;;

let read_prepared ~store operation_id =
  protect_result ~store_effect:No_record_change (fun () ->
    lookup_record ~store ~area:Active ~operation_id (fun () ->
      let prepared, _, _ = read_prepared_internal ~store operation_id in
      prepared))
;;

let read_bound ~store operation_id =
  protect_result ~store_effect:No_record_change (fun () ->
    lookup_record ~store ~area:Owned ~operation_id (fun () ->
      let bound, _, _ = read_bound_internal ~store operation_id in
      bound))
;;

let read_forensic ~store operation_id =
  protect_result ~store_effect:No_record_change (fun () ->
    lookup_record ~store ~area:Forensic ~operation_id (fun () ->
      let forensic, _, _ = read_forensic_internal ~store operation_id in
      forensic))
;;

let write_record_payload ~subject file raw =
  match
    Blocking_write.write_string
      ~label:"fs-compat-recovery-record-write"
      file
      raw
  with
  | Ok () -> Eio.Fiber.check ()
  | Error Blocking_write.Open_file_posix_descriptor_unavailable ->
    let exception_ = Internal_posix_descriptor_unavailable in
    let backtrace = Printexc.get_callstack 16 in
    raise
      (Store_failure
         (make_failure ~operation:Write_record ~subject exception_ backtrace))
  | Error
      (Blocking_write.Open_file_operation_failed
        { exception_; backtrace; bytes_written }) ->
    raise
      (Store_failure
         { operation = Write_record
         ; subject
         ; cause = Write_failed { exception_; backtrace; bytes_written }
         })
;;

let apply_record_permissions ~subject file =
  raise_io ~operation:Apply_permissions ~subject (fun () ->
    match Eio_unix.Resource.fd_opt file with
    | None -> raise Internal_posix_descriptor_unavailable
    | Some fd ->
      Eio_unix.run_in_systhread
        ~label:"fs-compat-recovery-record-fchmod"
        (fun () ->
           Eio_unix.Fd.use_exn
             "fs-compat-recovery-record-fchmod"
             fd
             (fun unix_fd -> Unix.fchmod unix_fd record_permissions));
      let stat = Eio.File.stat file in
      let actual = stat.perm land 0o7777 in
      if actual <> record_permissions
      then
        raise
          (Record_validation_failed
             (Record_permissions_mismatch
                { expected = record_permissions; actual }));
      Eio.Fiber.check ())
;;

let cleanup_created_record
      ~store
      ~area
      ~operation_id
      ~resource
      ~created_identity
      ~entry_created
  =
  let subject = record_subject store area operation_id in
  let path = record_path store area operation_id in
  let failures = ref [] in
  let add more = failures := !failures @ more in
  (match !resource with
   | None -> ()
   | Some file ->
     resource := None;
     add (close_resource_failures ~subject file));
  let removed = ref false in
  (match !entry_created, !created_identity with
   | false, _ -> ()
   | true, None ->
       let exception_ = Internal_created_record_identity_unavailable in
       let backtrace = Printexc.get_callstack 16 in
       add
         [ make_failure
             ~operation:Verify_record_identity
             ~subject
             exception_
             backtrace
         ]
   | true, Some expected ->
     let identity_failures =
       capture_failure ~operation:Verify_record_identity ~subject (fun () ->
         let actual = Eio.Path.stat ~follow:false path in
         if actual.kind <> `Regular_file
         then raise (Internal_unexpected_resource_kind actual.kind);
         let actual_identity = identity_of_stat actual in
         if not (equal_identity expected actual_identity)
         then
           raise
             (Internal_resource_identity_changed (expected, actual_identity)))
     in
     add identity_failures;
     if identity_failures = []
     then (
       let remove_failures =
         capture_failure ~operation:Remove_record ~subject (fun () ->
           Eio.Path.unlink path)
       in
       add remove_failures;
       if remove_failures = [] then removed := true));
  let removal_sync_failures =
    if not !removed
    then []
    else
      capture_failure
        ~operation:Sync_directory
        ~subject:(Area (area, store.owner))
        (fun () ->
           sync_directory
             ~subject:(Area (area, store.owner))
             (area_directory store area))
  in
  add removal_sync_failures;
  let record_absent_durable =
    (not !entry_created) || (!removed && removal_sync_failures = [])
  in
  !failures, record_absent_durable
;;

type exclusive_write_result =
  | Record_created
  | Record_exists

let create_record_exclusive
      ~store
      ~area
      ~operation_id
      ~raw
      ~base_effect
      ~unknown_effect
  =
  let subject = record_subject store area operation_id in
  let path = record_path store area operation_id in
  Eio.Cancel.protect @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let resource = ref None in
  let created_identity = ref None in
  let entry_created = ref false in
  try
    let opened =
      try
        Some
          (raise_io ~operation:Create_record ~subject (fun () ->
             Eio.Path.open_out
               ~sw
               ~create:(`Exclusive record_permissions)
               path))
      with
      | Store_failure
          { cause =
              Io_failed
                { exception_ =
                    Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _)
                ; _
                }
          ; _
          } ->
        None
    in
    match opened with
    | None -> Record_exists
    | Some file ->
      entry_created := true;
      resource := Some file;
      let stat =
        raise_io ~operation:Inspect_record ~subject (fun () ->
          Eio.File.stat file)
      in
      if stat.kind <> `Regular_file
      then
        raise_validation
          ~operation:Inspect_record
          ~subject
          (Record_kind_mismatch
             { expected = `Regular_file; actual = stat.kind });
      created_identity := Some (identity_of_stat stat);
      apply_record_permissions ~subject file;
      write_record_payload ~subject file raw;
      raise_io ~operation:Sync_record ~subject (fun () -> Eio.File.sync file);
      raise_io ~operation:Close_record ~subject (fun () ->
        Eio.Resource.close file);
      resource := None;
      sync_directory
        ~subject:(Area (area, store.owner))
        (area_directory store area);
      Record_created
  with
  | Eio.Cancel.Cancelled reason as cancellation ->
    let backtrace = Printexc.get_raw_backtrace () in
    let cleanup_failures, record_absent_durable =
      cleanup_created_record
        ~store
        ~area
        ~operation_id
        ~resource
        ~created_identity
        ~entry_created
    in
    let store_effect =
      if record_absent_durable then base_effect else unknown_effect
    in
    if store_effect = No_record_change && cleanup_failures = []
    then Printexc.raise_with_backtrace cancellation backtrace
    else
      Printexc.raise_with_backtrace
        (Eio.Cancel.Cancelled
           (Recovery_store_cancelled
              (reason, store_effect, cleanup_failures)))
        backtrace
  | Store_failure failure ->
    let cleanup_failures, record_absent_durable =
      cleanup_created_record
        ~store
        ~area
        ~operation_id
        ~resource
        ~created_identity
        ~entry_created
    in
    let store_effect =
      if record_absent_durable then base_effect else unknown_effect
    in
    raise (Transition_failed { store_effect; failure; cleanup_failures })
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    let cleanup_failures, record_absent_durable =
      cleanup_created_record
        ~store
        ~area
        ~operation_id
        ~resource
        ~created_identity
        ~entry_created
    in
    let store_effect =
      if record_absent_durable then base_effect else unknown_effect
    in
    let failure =
      make_failure ~operation:Write_record ~subject exception_ backtrace
    in
    raise (Transition_failed { store_effect; failure; cleanup_failures })
;;

type ensure_record_result =
  | Installed_record
  | Existing_exact_record

let ensure_exact_record
      ~store
      ~area
      ~operation_id
      ~raw
      ~base_effect
      ~unknown_effect
  =
  match
    create_record_exclusive
      ~store
      ~area
      ~operation_id
      ~raw
      ~base_effect
      ~unknown_effect
  with
  | Record_created -> Installed_record
  | Record_exists ->
    let existing_raw, _ =
      read_raw_record ~store ~area ~operation_id ~store_effect:base_effect
    in
    if not (String.equal raw existing_raw)
    then (
      let subject = record_subject store area operation_id in
      let exception_ = Internal_existing_record_does_not_match in
      let backtrace = Printexc.get_callstack 16 in
      raise
        (Store_failure
           (make_failure ~operation:Decode_record ~subject exception_ backtrace)));
    sync_directory
      ~subject:(Area (area, store.owner))
      (area_directory store area);
    Existing_exact_record
;;

let verify_exact_source
      ~store
      ~area
      ~operation_id
      ~expected_raw
      ~store_effect
  =
  let actual_raw, identity =
    read_raw_record ~store ~area ~operation_id ~store_effect
  in
  if not (String.equal expected_raw actual_raw)
  then (
    let subject = record_subject store area operation_id in
    let exception_ = Internal_existing_record_does_not_match in
    let backtrace = Printexc.get_callstack 16 in
    raise
      (Store_failure
         (make_failure ~operation:Decode_record ~subject exception_ backtrace)));
  identity
;;

let remove_exact_source
      ~store
      ~area
      ~operation_id
      ~expected_raw
      ~effect_before
      ~removal_transition
  =
  Eio.Cancel.protect @@ fun () ->
  let subject = record_subject store area operation_id in
  let path = record_path store area operation_id in
  let expected_identity =
    verify_exact_source
      ~store
      ~area
      ~operation_id
      ~expected_raw
      ~store_effect:effect_before
  in
  let removed = ref false in
  try
    let actual =
      raise_io ~operation:Verify_record_identity ~subject (fun () ->
        Eio.Path.stat ~follow:false path)
    in
    if actual.kind <> `Regular_file
    then
      raise_validation
        ~operation:Verify_record_identity
        ~subject
        (Record_kind_mismatch
           { expected = `Regular_file; actual = actual.kind });
    let actual_identity = identity_of_stat actual in
    if not (equal_identity expected_identity actual_identity)
    then
      raise_validation
        ~operation:Verify_record_identity
        ~subject
        (Record_identity_mismatch
           { expected = expected_identity; actual = actual_identity });
    raise_io ~operation:Remove_record ~subject (fun () -> Eio.Path.unlink path);
    removed := true;
    sync_directory
      ~subject:(Area (area, store.owner))
      (area_directory store area)
  with
  | Store_failure failure ->
    let store_effect =
      if !removed
      then Source_removal_durability_unknown removal_transition
      else effect_before
    in
    raise
      (Transition_failed
         { store_effect; failure; cleanup_failures = [] })
;;

let record_kind ~store ~area ~operation_id =
  let subject = record_subject store area operation_id in
  raise_io ~operation:Inspect_record ~subject (fun () ->
    Eio.Path.kind ~follow:false (record_path store area operation_id))
;;

let raise_missing_record ~store ~area ~operation_id =
  let subject = record_subject store area operation_id in
  let exception_ = Internal_missing_record in
  let backtrace = Printexc.get_callstack 16 in
  raise
    (Store_failure
       (make_failure ~operation:Inspect_record ~subject exception_ backtrace))
;;

let raise_existing_record_mismatch ~store ~area ~operation_id =
  let subject = record_subject store area operation_id in
  let exception_ = Internal_existing_record_does_not_match in
  let backtrace = Printexc.get_callstack 16 in
  raise
    (Store_failure
       (make_failure ~operation:Decode_record ~subject exception_ backtrace))
;;

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
      ~locator
      ~permissions
  =
  let prepared = { owner = store.owner; operation_id; locator; permissions } in
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
       ~unknown_effect:Active_record_state_unknown);
  prepared
;;

let prepare ~(store : store) ~(locator : locator) ~(permissions : permissions) =
  let create_attempt () =
    let operation_id = fresh_operation_id () in
    let prepared = { owner = store.owner; operation_id; locator; permissions } in
    let raw = encode_prepared prepared in
    run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
    match
      create_record_exclusive
        ~store
        ~area:Active
        ~operation_id
        ~raw
        ~base_effect:No_record_change
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
          store.owned;
        sync_directory
          ~subject:(Area (Active, store.owner))
          store.active;
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
      store.active;
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
      store.owned;
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
          store.forensic;
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
  let operation_id_of_uuid operation_id = operation_id

  let prepare_with_operation_id
        ~(store : store)
        ~operation_id
        ~(locator : locator)
        ~(permissions : permissions)
    =
    run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
    let prepared =
      prepare_with_operation_id_internal
        ~store
        ~operation_id
        ~locator
        ~permissions
    in
    observed_effect := Active_record_durable;
    prepared
  ;;
end

type corrupt_record =
  { area : area
  ; operation_id : operation_id
  ; raw : string
  ; validation_error : validation_error
  }

type inventory_row =
  | Active_record of prepared
  | Owned_record of bound
  | Forensic_record of forensic
  | Invalid_record_name of
      { area : area
      ; name : string
      }
  | Unexpected_record_kind of
      { area : area
      ; operation_id : operation_id
      ; kind : Eio.File.Stat.kind
      }
  | Missing_record_entry of
      { area : area
      ; operation_id : operation_id
      }
  | Record_entry_unavailable of
      { area : area
      ; operation_id : operation_id
      ; error : transition_error
      }
  | Corrupt_record of corrupt_record

type inventory = inventory_row list

let corrupt_if_identity_invalid
      ~store
      ~area
      ~operation_id
      ~raw
      ~record_owner
      ~record_id
      make_row
  =
  match
    validate_record_owner_and_id
      ~owner:store.owner
      ~operation_id
      ~record_owner
      ~record_id
  with
  | Ok () -> make_row ()
  | Error validation_error ->
    Corrupt_record { area; operation_id; raw; validation_error }
;;

let inventory_regular_record ~store ~area ~operation_id =
  let raw, _ =
    read_raw_record
      ~store
      ~area
      ~operation_id
      ~store_effect:No_record_change
  in
  match area with
  | Active ->
    (match decode_prepared raw with
     | Error validation_error ->
       Corrupt_record { area; operation_id; raw; validation_error }
     | Ok prepared ->
       corrupt_if_identity_invalid
         ~store
         ~area
         ~operation_id
         ~raw
         ~record_owner:prepared.owner
         ~record_id:prepared.operation_id
         (fun () -> Active_record prepared))
  | Owned ->
    (match decode_bound raw with
     | Error validation_error ->
       Corrupt_record { area; operation_id; raw; validation_error }
     | Ok bound ->
       corrupt_if_identity_invalid
         ~store
         ~area
         ~operation_id
         ~raw
         ~record_owner:bound.prepared.owner
         ~record_id:bound.prepared.operation_id
         (fun () -> Owned_record bound))
  | Forensic ->
    (match decode_forensic raw with
     | Error validation_error ->
       Corrupt_record { area; operation_id; raw; validation_error }
     | Ok forensic ->
       corrupt_if_identity_invalid
         ~store
         ~area
         ~operation_id
         ~raw
         ~record_owner:(forensic_owner forensic)
         ~record_id:(forensic_operation_id forensic)
         (fun () -> Forensic_record forensic))
;;

let inventory_area ~store area =
  let directory = area_directory store area in
  let subject = Area (area, store.owner) in
  let names =
    raise_io ~operation:Read_directory ~subject (fun () ->
      Eio.Path.read_dir directory)
  in
  List.map
    (fun name ->
       match operation_id_of_string name with
       | Error _ -> Invalid_record_name { area; name }
       | Ok operation_id ->
         (try
            match record_kind ~store ~area ~operation_id with
            | `Not_found -> Missing_record_entry { area; operation_id }
            | `Regular_file ->
              inventory_regular_record ~store ~area ~operation_id
            | ( ( `Unknown
                | `Fifo
                | `Character_special
                | `Directory
                | `Block_device
                | `Symbolic_link
                | `Socket ) as
                kind ) ->
              Unexpected_record_kind { area; operation_id; kind }
          with
          | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
          | Transition_failed error ->
            Record_entry_unavailable { area; operation_id; error }
          | Store_failure failure ->
            Record_entry_unavailable
              { area
              ; operation_id
              ; error = transition_error ~store_effect:No_record_change failure
              }))
    names
;;

let inventory store =
  protect_result ~store_effect:No_record_change (fun () ->
    inventory_area ~store Active
    @ inventory_area ~store Owned
    @ inventory_area ~store Forensic)
;;
