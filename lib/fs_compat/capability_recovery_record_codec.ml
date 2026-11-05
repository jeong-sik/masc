open Capability_recovery_record

let record_schema = "masc.fs-publication-recovery"
let record_version = 2

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

let publication_to_json = function
  | Replace -> `String "replace"
  | Create_exclusive -> `String "create_exclusive"
;;

let publication_of_json = function
  | `String "replace" -> Replace
  | `String "create_exclusive" -> Create_exclusive
  | value -> raise_invalid (Record_field_invalid { field = "publication"; value })
;;

let prepared_to_json (prepared : prepared) =
  `Assoc
    [ "schema", `String record_schema
    ; "version", `Int record_version
    ; "state", `String "prepared"
    ; "owner", `String (owner_to_string prepared.owner)
    ; "operation_id", `String (operation_id_to_string prepared.operation_id)
    ; "publication", publication_to_json prepared.publication
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
  ; "publication"
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
  let publication = publication_of_json (field fields "publication") in
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
  { owner; operation_id; publication; locator; permissions }
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
  | exception_ -> (* cancel-guard-ok: Yojson decoding performs no Eio operation *)
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
