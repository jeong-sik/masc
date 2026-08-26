open Result.Syntax

type ledger_revision = string
type workspace_key = string

type origin =
  | Task_instruction of { task_id : Keeper_id.Task_id.t }
  | Session_instruction
  | Task_composition of
      { task_id : Keeper_id.Task_id.t
      ; tool_name : string
      }
  | Session_composition of { tool_name : string }

type activation =
  { identity : Skill_reference.identity
  ; content_revision : Skill_reference.content_revision
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; turn_ref : Ids.Turn_ref.t
  ; activated_at : string
  ; origin : origin
  }

type t =
  { workspace_key : workspace_key
  ; session_id : Keeper_id.Trace_id.t
  ; activations : activation list
  ; revision : ledger_revision
  }

type record_outcome =
  | Recorded of activation
  | Already_recorded of activation

type decode_error =
  | Expected_object of { field : string }
  | Missing_string of { field : string }
  | Duplicate_field of
      { object_name : string
      ; field : string
      }
  | Unexpected_field of
      { object_name : string
      ; field : string
      }
  | Unsupported_schema of string
  | Invalid_source_id of string
  | Invalid_skill_name of string
  | Invalid_package_id of Skill_reference.package_id_error
  | Invalid_content_revision of Skill_reference.revision_error
  | Invalid_snapshot_revision of Skill_catalog_snapshot.revision_error
  | Invalid_origin_kind of string
  | Invalid_task_id of string
  | Invalid_tool_name of string
  | Invalid_turn_ref of string
  | Turn_ref_session_mismatch
  | Invalid_activated_at of string
  | Duplicate_exact_activation
  | Session_id_mismatch
  | Workspace_key_mismatch
  | Invalid_ledger_revision of Skill_catalog_snapshot.revision_error
  | Ledger_revision_mismatch

type store_error =
  | Lock_failed of string
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Decode_failed of decode_error
  | Write_failed of Keeper_fs.durable_write_error
  | Readback_mismatch

let decode_error_code = function
  | Expected_object _ -> "expected_object"
  | Missing_string _ -> "missing_string"
  | Duplicate_field _ -> "duplicate_field"
  | Unexpected_field _ -> "unexpected_field"
  | Unsupported_schema _ -> "unsupported_schema"
  | Invalid_source_id _ -> "invalid_source_id"
  | Invalid_skill_name _ -> "invalid_skill_name"
  | Invalid_package_id _ -> "invalid_package_id"
  | Invalid_content_revision _ -> "invalid_content_revision"
  | Invalid_snapshot_revision _ -> "invalid_snapshot_revision"
  | Invalid_origin_kind _ -> "invalid_origin_kind"
  | Invalid_task_id _ -> "invalid_task_id"
  | Invalid_tool_name _ -> "invalid_tool_name"
  | Invalid_turn_ref _ -> "invalid_turn_ref"
  | Turn_ref_session_mismatch -> "turn_ref_session_mismatch"
  | Invalid_activated_at _ -> "invalid_activated_at"
  | Duplicate_exact_activation -> "duplicate_exact_activation"
  | Session_id_mismatch -> "session_id_mismatch"
  | Workspace_key_mismatch -> "workspace_key_mismatch"
  | Invalid_ledger_revision _ -> "invalid_ledger_revision"
  | Ledger_revision_mismatch -> "ledger_revision_mismatch"
;;

let store_error_code = function
  | Lock_failed _ -> "lock_failed"
  | Read_failed _ -> "read_failed"
  | Decode_failed error -> "decode_failed." ^ decode_error_code error
  | Write_failed _ -> "write_failed"
  | Readback_mismatch -> "readback_mismatch"
;;

let store_error_to_string = function
  | Lock_failed detail -> "lock failed: " ^ detail
  | Read_failed error ->
    "read failed: " ^ Fs_compat.owned_regular_file_read_error_to_string error
  | Decode_failed _ -> "decode failed"
  | Write_failed error ->
    "write failed: " ^ Keeper_fs.durable_write_error_to_string error
  | Readback_mismatch -> "readback mismatch"
;;

let schema = "masc.skill-activations/v1"
let filename = "skill-activations.json"
let activations ledger = ledger.activations
let revision ledger = ledger.revision
let ledger_revision_to_string revision = revision

let make_activation
      ~(identity : Skill_reference.identity)
      ~content_revision
      ~snapshot_revision
      ~turn_ref
      ~activated_at
      ~origin
  =
  let trace_id = Ids.Turn_ref.trace_id turn_ref in
  let* canonical_name =
    Agent_core.Skill_document.canonical_name identity.name
    |> Result.map_error (fun _ -> Invalid_skill_name identity.name)
  in
  let* () =
    if String.equal canonical_name identity.name
    then Ok ()
    else Error (Invalid_skill_name identity.name)
  in
  let origin_valid =
    match origin with
    | Task_instruction _ | Session_instruction -> Ok ()
    | Task_composition { tool_name; _ }
    | Session_composition { tool_name } ->
      if Safe_identifier.is_portable_name tool_name
      then Ok ()
      else Error (Invalid_tool_name tool_name)
  in
  let* () = origin_valid in
  let* () =
    if String.equal trace_id "" || Ids.Turn_ref.absolute_turn turn_ref <= 0
    then Error (Invalid_turn_ref (Ids.Turn_ref.to_string turn_ref))
    else Ok ()
  in
  let* () =
    Time_codec.parse_rfc3339 activated_at
    |> Result.map ignore
    |> Result.map_error (fun _ -> Invalid_activated_at activated_at)
  in
  Ok
    { identity
    ; content_revision
    ; snapshot_revision
    ; turn_ref
    ; activated_at
    ; origin
    }
;;

let origin_to_yojson = function
  | Task_instruction { task_id } ->
    `Assoc
      [ "kind", `String "task_instruction"
      ; "task_id", `String (Keeper_id.Task_id.to_string task_id)
      ]
  | Session_instruction ->
    `Assoc [ "kind", `String "session_instruction" ]
  | Task_composition { task_id; tool_name } ->
    `Assoc
      [ "kind", `String "task_composition"
      ; "task_id", `String (Keeper_id.Task_id.to_string task_id)
      ; "tool_name", `String tool_name
      ]
  | Session_composition { tool_name } ->
    `Assoc
      [ "kind", `String "session_composition"
      ; "tool_name", `String tool_name
      ]
;;

let activation_to_yojson activation =
  `Assoc
    [ "identity", Skill_reference.identity_to_yojson activation.identity
    ; ( "content_revision"
      , `String
          (Skill_reference.content_revision_to_string activation.content_revision) )
    ; ( "snapshot_revision"
      , `String
          (Skill_catalog_snapshot.snapshot_revision_to_string
             activation.snapshot_revision) )
    ; "turn_ref", Ids.Turn_ref.to_yojson activation.turn_ref
    ; "activated_at", `String activation.activated_at
    ; "origin", origin_to_yojson activation.origin
    ]
;;

let workspace_key_of_root root =
  Digestif.SHA256.(digest_string root |> to_hex)
;;

let revision_of_ledger ~workspace_key ~session_id activations =
  let canonical =
    `Assoc
      [ "workspace_key", `String workspace_key
      ; "session_id", `String (Keeper_id.Trace_id.to_string session_id)
      ; "activations", `List (List.map activation_to_yojson activations)
      ]
  in
  Digestif.SHA256.(digest_string (Yojson.Safe.to_string canonical) |> to_hex)
;;

let make ~workspace_key ~session_id activations =
  { workspace_key
  ; session_id
  ; activations
  ; revision = revision_of_ledger ~workspace_key ~session_id activations
  }
;;

let empty ~workspace_root ~trace_id =
  make ~workspace_key:(workspace_key_of_root workspace_root) ~session_id:trace_id []
;;

let to_yojson ledger =
  `Assoc
    [ "schema", `String schema
    ; "workspace_key", `String ledger.workspace_key
    ; "session_id", `String (Keeper_id.Trace_id.to_string ledger.session_id)
    ; "revision", `String ledger.revision
    ; "activations", `List (List.map activation_to_yojson ledger.activations)
    ]
;;

let object_field field = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Expected_object { field })
;;

let string_field field fields =
  match List.assoc_opt field fields with
  | Some (`String value) -> Ok value
  | Some _ | None -> Error (Missing_string { field })
;;

let exact_fields ~object_name ~allowed fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (field, _) :: rest ->
      if List.mem field seen
      then Error (Duplicate_field { object_name; field })
      else if not (List.mem field allowed)
      then Error (Unexpected_field { object_name; field })
      else loop (field :: seen) rest
  in
  loop [] fields
;;

let decode_identity json =
  let* fields = object_field "identity" json in
  let* () =
    exact_fields
      ~object_name:"identity"
      ~allowed:[ "source_id"; "package_id"; "name" ]
      fields
  in
  let* source = string_field "source_id" fields in
  let* package = string_field "package_id" fields in
  let* name = string_field "name" fields in
  let* canonical_name =
    Agent_core.Skill_document.canonical_name name
    |> Result.map_error (fun _ -> Invalid_skill_name name)
  in
  let* () =
    if String.equal canonical_name name
    then Ok ()
    else Error (Invalid_skill_name name)
  in
  let* source_id =
    Skill_source_config.source_id_of_string source
    |> Result.map_error (fun _ -> Invalid_source_id source)
  in
  let* package_id =
    Skill_reference.package_id_of_directory package
    |> Result.map_error (fun error -> Invalid_package_id error)
  in
  Ok (Skill_reference.make_identity ~source_id ~package_id ~name)
;;

let decode_origin json =
  let* fields = object_field "origin" json in
  let* kind = string_field "kind" fields in
  let* () =
    match kind with
    | "task_instruction" ->
      exact_fields
        ~object_name:"origin"
        ~allowed:[ "kind"; "task_id" ]
        fields
    | "session_instruction" ->
      exact_fields ~object_name:"origin" ~allowed:[ "kind" ] fields
    | "task_composition" ->
      exact_fields
        ~object_name:"origin"
        ~allowed:[ "kind"; "task_id"; "tool_name" ]
        fields
    | "session_composition" ->
      exact_fields
        ~object_name:"origin"
        ~allowed:[ "kind"; "tool_name" ]
        fields
    | kind -> Error (Invalid_origin_kind kind)
  in
  match kind with
  | "task_instruction" ->
    let* task_id_text = string_field "task_id" fields in
    let* task_id =
      Keeper_id.Task_id.of_string task_id_text
      |> Result.map_error (fun _ -> Invalid_task_id task_id_text)
    in
    Ok (Task_instruction { task_id })
  | "session_instruction" -> Ok Session_instruction
  | "task_composition" ->
    let* task_id_text = string_field "task_id" fields in
    let* task_id =
      Keeper_id.Task_id.of_string task_id_text
      |> Result.map_error (fun _ -> Invalid_task_id task_id_text)
    in
    let* tool_name = string_field "tool_name" fields in
    Ok (Task_composition { task_id; tool_name })
  | "session_composition" ->
    let* tool_name = string_field "tool_name" fields in
    Ok (Session_composition { tool_name })
  | kind -> Error (Invalid_origin_kind kind)
;;

let decode_activation ~expected_trace_id json =
  let* fields = object_field "activation" json in
  let* () =
    exact_fields
      ~object_name:"activation"
      ~allowed:
        [ "identity"
        ; "content_revision"
        ; "snapshot_revision"
        ; "turn_ref"
        ; "activated_at"
        ; "origin"
        ]
      fields
  in
  let* identity_json =
    match List.assoc_opt "identity" fields with
    | Some value -> Ok value
    | None -> Error (Expected_object { field = "identity" })
  in
  let* identity = decode_identity identity_json in
  let* content = string_field "content_revision" fields in
  let* content_revision =
    Skill_reference.content_revision_of_string content
    |> Result.map_error (fun error -> Invalid_content_revision error)
  in
  let* snapshot = string_field "snapshot_revision" fields in
  let* snapshot_revision =
    Skill_catalog_snapshot.snapshot_revision_of_string snapshot
    |> Result.map_error (fun error -> Invalid_snapshot_revision error)
  in
  let* turn_ref = string_field "turn_ref" fields in
  let* turn_ref =
    match Ids.Turn_ref.of_string turn_ref with
    | Some turn_ref -> Ok turn_ref
    | None -> Error (Invalid_turn_ref turn_ref)
  in
  let* () =
    if
      String.equal
        (Ids.Turn_ref.trace_id turn_ref)
        (Keeper_id.Trace_id.to_string expected_trace_id)
    then Ok ()
    else Error Turn_ref_session_mismatch
  in
  let* activated_at = string_field "activated_at" fields in
  let* () =
    Time_codec.parse_rfc3339 activated_at
    |> Result.map ignore
    |> Result.map_error (fun _ -> Invalid_activated_at activated_at)
  in
  let* origin_json =
    match List.assoc_opt "origin" fields with
    | Some value -> Ok value
    | None -> Error (Expected_object { field = "origin" })
  in
  let* origin = decode_origin origin_json in
  make_activation
    ~identity
    ~content_revision
    ~snapshot_revision
    ~turn_ref
    ~activated_at
    ~origin
;;

let exact_key_equal left right =
  Skill_reference.equal_identity left.identity right.identity
  && Skill_reference.equal_content_revision
       left.content_revision
       right.content_revision
;;

let of_yojson ~expected_workspace_root ~expected_trace_id json =
  let* fields = object_field "ledger" json in
  let* () =
    exact_fields
      ~object_name:"ledger"
      ~allowed:[ "schema"; "workspace_key"; "session_id"; "revision"; "activations" ]
      fields
  in
  let* observed_schema = string_field "schema" fields in
  let* () =
    if String.equal observed_schema schema
    then Ok ()
    else Error (Unsupported_schema observed_schema)
  in
  let* session_id = string_field "session_id" fields in
  let* () =
    if String.equal session_id (Keeper_id.Trace_id.to_string expected_trace_id)
    then Ok ()
    else Error Session_id_mismatch
  in
  let expected_workspace_key = workspace_key_of_root expected_workspace_root in
  let* workspace_key = string_field "workspace_key" fields in
  let* () =
    if String.equal workspace_key expected_workspace_key
    then Ok ()
    else Error Workspace_key_mismatch
  in
  let* declared_revision = string_field "revision" fields in
  let* () =
    Skill_catalog_snapshot.snapshot_revision_of_string declared_revision
    |> Result.map ignore
    |> Result.map_error (fun error -> Invalid_ledger_revision error)
  in
  let* activations =
    match List.assoc_opt "activations" fields with
    | Some (`List values) ->
      List.fold_left
        (fun result value ->
           let* reversed = result in
           let* activation = decode_activation ~expected_trace_id value in
           Ok (activation :: reversed))
        (Ok [])
        values
      |> Result.map List.rev
    | Some _ | None -> Error (Expected_object { field = "activations" })
  in
  let rec ensure_unique = function
    | [] -> Ok ()
    | activation :: rest ->
      if List.exists (exact_key_equal activation) rest
      then Error Duplicate_exact_activation
      else ensure_unique rest
  in
  let* () = ensure_unique activations in
  let ledger =
    make
      ~workspace_key:expected_workspace_key
      ~session_id:expected_trace_id
      activations
  in
  if String.equal ledger.revision declared_revision
  then Ok ledger
  else Error Ledger_revision_mismatch
;;

let ledger_path session_dir = Filename.concat session_dir filename

let read_locked ~ownership_root ~expected_trace_id session_dir =
  let path = ledger_path session_dir in
  match Fs_compat.load_owned_regular_file ~ownership_root path with
  | Error error -> Error (Read_failed error)
  | Ok None -> Ok (empty ~workspace_root:ownership_root ~trace_id:expected_trace_id)
  | Ok (Some contents) ->
    (match Yojson.Safe.from_string contents with
     | json ->
       of_yojson
         ~expected_workspace_root:ownership_root
         ~expected_trace_id
         json
       |> Result.map_error (fun error -> Decode_failed error)
     | exception Yojson.Json_error _ ->
       Error (Decode_failed (Expected_object { field = "ledger" })))
;;

let with_lock ~config ~trace_id operation =
  let session_dir =
    Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace_id)
  in
  match
    Keeper_checkpoint_store.with_session_lock ~session_dir (fun canonical_session_dir ->
      let ownership_root = Filename.dirname canonical_session_dir in
      operation ~ownership_root canonical_session_dir)
  with
  | Error detail -> Error (Lock_failed detail)
  | Ok result -> result
;;

let load ~config ~trace_id =
  with_lock ~config ~trace_id (fun ~ownership_root session_dir ->
    read_locked ~ownership_root ~expected_trace_id:trace_id session_dir)
;;

let record ~config ~trace_id activation =
  with_lock ~config ~trace_id (fun ~ownership_root session_dir ->
    let* () =
      if
        String.equal
          (Ids.Turn_ref.trace_id activation.turn_ref)
          (Keeper_id.Trace_id.to_string trace_id)
      then Ok ()
      else Error (Decode_failed Turn_ref_session_mismatch)
    in
    let* current = read_locked ~ownership_root ~expected_trace_id:trace_id session_dir in
    match List.find_opt (exact_key_equal activation) current.activations with
    | Some existing -> Ok (current, Already_recorded existing)
    | None ->
      let next =
        make
          ~workspace_key:(workspace_key_of_root ownership_root)
          ~session_id:trace_id
          (current.activations @ [ activation ])
      in
      let path = ledger_path session_dir in
      let* () =
        Keeper_fs.save_json_durable_atomic
          ~ownership_root
          ~pretty:false
          path
          (to_yojson next)
        |> Result.map_error (fun error -> Write_failed error)
      in
      let* readback =
        read_locked ~ownership_root ~expected_trace_id:trace_id session_dir
      in
      if String.equal readback.revision next.revision
      then Ok (readback, Recorded activation)
      else Error Readback_mismatch)
;;
