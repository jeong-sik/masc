module Request_id = Keeper_chat_delivery_identity.Request_id

type accepted_payload =
  { keeper_name : string
  ; submitted_by : string
  ; user_content : string
  ; user_attachments : Keeper_chat_store.attachment list
  ; surface : Surface_ref.t
  ; conversation_id : string option
  ; external_message_id : string option
  ; speaker : Keeper_chat_store.speaker
  }

type request_result =
  { ok : bool
  ; body : string
  ; data : Yojson.Safe.t option
  }

type transcript_effect =
  | Assistant_reply of
      { content : string
      ; blocks : Keeper_chat_store.chat_block list option
      ; turn_ref : Ids.Turn_ref.t option
      }
  | Transport_failure of { content : string }
  | No_assistant_reply

type staged_effect =
  { request_result : request_result
  ; transcript_effect : transcript_effect
  }

type phase =
  | Prepared
  | User_row_committed of { user_row_id : string }
  | Running of { user_row_id : string }
  | Effect_staged of
      { user_row_id : string
      ; staged : staged_effect
      }
  | Transcript_committed of
      { user_row_id : string
      ; staged : staged_effect
      ; transcript_row_id : string
      }

type t =
  { schema_version : int
  ; revision : int64
  ; request_id : Request_id.t
  ; payload : accepted_payload
  ; phase : phase
  ; created_at : float
  ; updated_at : float
  }

type phase_kind =
  | Prepared_phase
  | User_row_committed_phase
  | Running_phase
  | Effect_staged_phase
  | Transcript_committed_phase

type mutation_operation =
  | Prepare
  | Commit_user_row
  | Mark_running
  | Stage_effect
  | Commit_transcript

type publication =
  | Not_published
  | Published_indeterminate

type persistence_failure =
  { operation : mutation_operation
  ; request_id : Request_id.t
  ; target_revision : int64
  ; publication : publication
  ; detail : string
  }

type transcript_slot =
  | User_transcript
  | Assistant_transcript

type removal_failure =
  { removed : bool
  ; detail : string
  }

type error =
  | Invalid_base_path of string
  | Invalid_keeper_name of string
  | Invalid_request_id of string
  | Invalid_payload of string
  | Already_exists of string
  | Not_found of string
  | Read_failed of string
  | Decode_failed of string
  | Record_not_regular of string
  | Record_identity_changed of string
  | Record_grew_during_read of string
  | Record_too_large_for_runtime of string
  | Identity_mismatch
  | Revision_conflict of
      { expected : int64
      ; actual : int64
      }
  | Revision_exhausted
  | Invalid_transition of
      { expected : phase_kind
      ; actual : phase_kind
      }
  | Invalid_effect of string
  | Transcript_failed of
      { slot : transcript_slot
      ; detail : string
      }
  | Persistence_failed of persistence_failure
  | Async_terminal_rejected of Keeper_msg_async.canonical_terminal_error
  | Async_terminal_identity_mismatch
  | Removal_requires_transcript_commit of phase_kind
  | Removal_failed of removal_failure

type lane_area =
  | Active_records
  | Atomic_staging

type quarantine_reason =
  | Directory_boundary_rejected of string
  | Directory_inventory_failed of string
  | Unexpected_staging_entry
  | Invalid_active_filename of string
  | Active_entry_not_regular
  | Active_entry_unreadable of error
  | Filename_request_mismatch
  | Keeper_payload_mismatch

type quarantine_artifact =
  { area : lane_area
  ; path : string
  ; reason : quarantine_reason
  }

type lane_inventory =
  | Ready of t list
  | Quarantined of
      { recoverable : t list
      ; artifacts : quarantine_artifact list
      }

type async_terminal_proof =
  { canonical_terminal : Keeper_msg_async.durable_terminal_proof
  ; checkpoint : t
  }

let schema_version = 1
let active_directory_name = ".chat-direct-active-v1"
let staging_directory_name = ".chat-direct-staging-v1"
let ( let* ) = Result.bind

let phase_kind = function
  | Prepared -> Prepared_phase
  | User_row_committed _ -> User_row_committed_phase
  | Running _ -> Running_phase
  | Effect_staged _ -> Effect_staged_phase
  | Transcript_committed _ -> Transcript_committed_phase
;;

let phase_kind_to_string = function
  | Prepared_phase -> "prepared"
  | User_row_committed_phase -> "user_row_committed"
  | Running_phase -> "running"
  | Effect_staged_phase -> "effect_staged"
  | Transcript_committed_phase -> "transcript_committed"
;;

let operation_to_string = function
  | Prepare -> "prepare"
  | Commit_user_row -> "commit_user_row"
  | Mark_running -> "mark_running"
  | Stage_effect -> "stage_effect"
  | Commit_transcript -> "commit_transcript"
;;

let error_to_string = function
  | Invalid_base_path detail -> "invalid direct delivery base path: " ^ detail
  | Invalid_keeper_name detail -> "invalid direct delivery Keeper name: " ^ detail
  | Invalid_request_id detail -> "invalid direct delivery request id: " ^ detail
  | Invalid_payload detail -> "invalid direct delivery payload: " ^ detail
  | Already_exists path -> "direct delivery checkpoint already exists: " ^ path
  | Not_found path -> "direct delivery checkpoint not found: " ^ path
  | Read_failed detail -> "direct delivery checkpoint read failed: " ^ detail
  | Decode_failed detail -> "direct delivery checkpoint decode failed: " ^ detail
  | Record_not_regular path ->
    "direct delivery checkpoint is not a regular file: " ^ path
  | Record_identity_changed path ->
    "direct delivery checkpoint identity changed while opening: " ^ path
  | Record_grew_during_read path ->
    "direct delivery checkpoint grew while reading: " ^ path
  | Record_too_large_for_runtime path ->
    "direct delivery checkpoint exceeds the runtime string bound: " ^ path
  | Identity_mismatch -> "direct delivery checkpoint identity mismatch"
  | Revision_conflict { expected; actual } ->
    Printf.sprintf
      "direct delivery revision conflict: expected %Ld, actual %Ld"
      expected
      actual
  | Revision_exhausted -> "direct delivery checkpoint revision exhausted"
  | Invalid_transition { expected; actual } ->
    Printf.sprintf
      "direct delivery transition rejected: expected %s, actual %s"
      (phase_kind_to_string expected)
      (phase_kind_to_string actual)
  | Invalid_effect detail -> "invalid direct delivery effect: " ^ detail
  | Transcript_failed { slot; detail } ->
    let slot =
      match slot with
      | User_transcript -> "user"
      | Assistant_transcript -> "assistant"
    in
    Printf.sprintf "direct delivery %s transcript append failed: %s" slot detail
  | Persistence_failed failure ->
    let publication =
      match failure.publication with
      | Not_published -> "not_published"
      | Published_indeterminate -> "published_indeterminate"
    in
    Printf.sprintf
      "direct delivery persistence failed: operation=%s request_id=%s revision=%Ld publication=%s detail=%s"
      (operation_to_string failure.operation)
      (Request_id.to_string failure.request_id)
      failure.target_revision
      publication
      failure.detail
  | Async_terminal_rejected error ->
    "direct delivery canonical async lookup failed: "
    ^ Keeper_msg_async.canonical_terminal_error_to_string error
  | Async_terminal_identity_mismatch ->
    "direct delivery canonical async identity mismatch"
  | Removal_requires_transcript_commit actual ->
    "direct delivery removal requires transcript_committed, actual "
    ^ phase_kind_to_string actual
  | Removal_failed { removed; detail } ->
    Printf.sprintf
      "direct delivery removal failed: removed=%b detail=%s"
      removed
      detail
;;

let validate_utf8 field value =
  if String.is_valid_utf_8 value
  then Ok ()
  else Error (Invalid_payload (field ^ " contains malformed UTF-8"))
;;

let validate_optional_utf8 field = function
  | None -> Ok ()
  | Some value -> validate_utf8 field value
;;

let validate_nonblank field value =
  let* () = validate_utf8 field value in
  let trimmed = String.trim value in
  if String.equal trimmed ""
  then Error (Invalid_payload (field ^ " must not be blank"))
  else if not (String.equal trimmed value)
  then Error (Invalid_payload (field ^ " must not have surrounding whitespace"))
  else Ok ()
;;

let rec validate_json_text field = function
  | `Null | `Bool _ | `Int _ | `Intlit _ -> Ok ()
  | `String text -> validate_utf8 field text
  | `Float value ->
    if Float.is_finite value
    then Ok ()
    else Error (Invalid_payload (field ^ " contains a non-finite number"))
  | `List values ->
    List.fold_left
      (fun result value ->
         let* () = result in
         validate_json_text field value)
      (Ok ())
      values
  | `Assoc fields ->
    let rec validate_object seen = function
      | [] -> Ok ()
      | (key, value) :: rest ->
        let* () = validate_utf8 (field ^ " key") key in
        if List.mem key seen
        then Error (Invalid_payload (field ^ " contains a duplicate object key"))
        else
          let* () = validate_json_text field value in
          validate_object (key :: seen) rest
    in
    validate_object [] fields
  | `Tuple _ | `Variant _ ->
    Error (Invalid_payload (field ^ " must use canonical JSON values"))
;;

let validate_attachment index (attachment : Keeper_chat_store.attachment) =
  let prefix = Printf.sprintf "user_attachments[%d]." index in
  let* () = validate_utf8 (prefix ^ "id") attachment.id in
  let* () = validate_utf8 (prefix ^ "type") attachment.att_type in
  let* () = validate_utf8 (prefix ^ "name") attachment.name in
  let* () = validate_utf8 (prefix ^ "mime_type") attachment.mime_type in
  let* () = validate_utf8 (prefix ^ "data") attachment.data in
  if attachment.size < 0
  then Error (Invalid_payload (prefix ^ "size must be non-negative"))
  else Ok ()
;;

let validate_payload (payload : accepted_payload) =
  let* _keeper_name =
    Keeper_id.Keeper_name.of_string payload.keeper_name
    |> Result.map_error (fun detail -> Invalid_keeper_name detail)
  in
  let* () = validate_nonblank "submitted_by" payload.submitted_by in
  let* () = validate_utf8 "user_content" payload.user_content in
  let* () =
    List.mapi (fun index attachment -> index, attachment) payload.user_attachments
    |> List.fold_left
         (fun result (index, attachment) ->
            let* () = result in
            validate_attachment index attachment)
         (Ok ())
  in
  let* () = validate_json_text "surface" (Surface_ref.to_json payload.surface) in
  let* () = validate_optional_utf8 "conversation_id" payload.conversation_id in
  let* () =
    validate_optional_utf8 "external_message_id" payload.external_message_id
  in
  let* () = validate_optional_utf8 "speaker_id" payload.speaker.speaker_id in
  validate_optional_utf8 "speaker_name" payload.speaker.speaker_name
;;

let validate_row_id field row_id = validate_nonblank field row_id

let validate_effect (staged : staged_effect) =
  let* () = validate_utf8 "request_result.body" staged.request_result.body in
  let* () =
    match staged.request_result.data with
    | None -> Ok ()
    | Some data -> validate_json_text "request_result.data" data
  in
  match staged.request_result.ok, staged.transcript_effect with
  | true, Assistant_reply { content; blocks; _ } ->
    let* () = validate_utf8 "assistant_reply.content" content in
    (match blocks with
     | None -> Ok ()
     | Some blocks ->
       validate_json_text
         "assistant_reply.blocks"
         (Keeper_chat_blocks.blocks_to_yojson blocks))
  | false, Transport_failure { content } ->
    validate_utf8 "transport_failure.content" content
  | true, No_assistant_reply -> Ok ()
  | true, Transport_failure _ ->
    Error
      (Invalid_effect
         "a successful request result cannot carry a transport failure")
  | false, (Assistant_reply _ | No_assistant_reply) ->
    Error
      (Invalid_effect
         "a failed request result must carry a transport failure")
;;

let validate_phase = function
  | Prepared -> Ok ()
  | User_row_committed { user_row_id }
  | Running { user_row_id } -> validate_row_id "user_row_id" user_row_id
  | Effect_staged { user_row_id; staged } ->
    let* () = validate_row_id "user_row_id" user_row_id in
    validate_effect staged
  | Transcript_committed { user_row_id; staged; transcript_row_id } ->
    let* () = validate_row_id "user_row_id" user_row_id in
    let* () = validate_row_id "transcript_row_id" transcript_row_id in
    validate_effect staged
;;

let validate_record record =
  if record.schema_version <> schema_version
  then
    Error
      (Decode_failed
         (Printf.sprintf "unsupported schema version %d" record.schema_version))
  else if Int64.compare record.revision 0L < 0
  then Error (Decode_failed "revision must be non-negative")
  else if not (Float.is_finite record.created_at)
  then Error (Decode_failed "created_at must be finite")
  else if not (Float.is_finite record.updated_at)
  then Error (Decode_failed "updated_at must be finite")
  else
    let* () =
      Request_id.of_string (Request_id.to_string record.request_id)
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun detail -> Invalid_request_id detail)
    in
    let* () = validate_payload record.payload in
    validate_phase record.phase
;;

let validate_now now =
  if Float.is_finite now
  then Ok ()
  else Error (Invalid_payload "checkpoint timestamp must be finite")
;;

let canonical_base_path base_path =
  let normalized = Workspace_utils_backend_setup.normalize_base_path base_path in
  if String.equal normalized ""
  then Error (Invalid_base_path "base_path is empty")
  else
    try Ok (Fs_compat.realpath normalized) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Invalid_base_path (Printexc.to_string exn))
;;

let keeper_name_id keeper_name =
  Keeper_id.Keeper_name.of_string keeper_name
  |> Result.map_error (fun detail -> Invalid_keeper_name detail)
;;

let keeper_root ~base_path keeper_name =
  Filename.concat
    (Common.keepers_runtime_dir_of_base ~base_path)
    (Keeper_id.Keeper_name.to_string keeper_name)
;;

let active_dir_resolved ~base_path keeper_name =
  Filename.concat (keeper_root ~base_path keeper_name) active_directory_name
;;

let staging_dir_resolved ~base_path keeper_name =
  Filename.concat (keeper_root ~base_path keeper_name) staging_directory_name
;;

let active_path_resolved ~base_path keeper_name request_id =
  Filename.concat
    (active_dir_resolved ~base_path keeper_name)
    (Request_id.to_string request_id)
;;

let resolve_paths ~base_path ~keeper_name request_id =
  let* base_path = canonical_base_path base_path in
  let* keeper_name = keeper_name_id keeper_name in
  let request_id_wire = Request_id.to_string request_id in
  let* request_id =
    Request_id.of_string request_id_wire
    |> Result.map_error (fun detail -> Invalid_request_id detail)
  in
  Ok
    ( base_path
    , keeper_name
    , active_path_resolved ~base_path keeper_name request_id
    , staging_dir_resolved ~base_path keeper_name )
;;

let string_option_to_yojson = function
  | None -> `Null
  | Some value -> `String value
;;

let attachment_to_yojson (attachment : Keeper_chat_store.attachment) =
  `Assoc
    [ "id", `String attachment.id
    ; "type", `String attachment.att_type
    ; "name", `String attachment.name
    ; "size", `Int attachment.size
    ; "mime_type", `String attachment.mime_type
    ; "data", `String attachment.data
    ]
;;

let speaker_to_yojson (speaker : Keeper_chat_store.speaker) =
  `Assoc
    [ "speaker_id", string_option_to_yojson speaker.speaker_id
    ; "speaker_name", string_option_to_yojson speaker.speaker_name
    ; "authority", `String (Keeper_chat_store.authority_label speaker.speaker_authority)
    ]
;;

let payload_to_yojson (payload : accepted_payload) =
  `Assoc
    [ "keeper_name", `String payload.keeper_name
    ; "submitted_by", `String payload.submitted_by
    ; "user_content", `String payload.user_content
    ; "user_attachments", `List (List.map attachment_to_yojson payload.user_attachments)
    ; "surface", Surface_ref.to_json payload.surface
    ; "conversation_id", string_option_to_yojson payload.conversation_id
    ; "external_message_id", string_option_to_yojson payload.external_message_id
    ; "speaker", speaker_to_yojson payload.speaker
    ]
;;

let request_result_to_yojson (result : request_result) =
  `Assoc
    [ "ok", `Bool result.ok
    ; "body", `String result.body
    ; "data", Option.value result.data ~default:`Null
    ]
;;

let transcript_effect_to_yojson = function
  | Assistant_reply { content; blocks; turn_ref } ->
    `Assoc
      [ "kind", `String "assistant_reply"
      ; "content", `String content
      ; ( "blocks"
        , match blocks with
          | None -> `Null
          | Some blocks -> Keeper_chat_blocks.blocks_to_yojson blocks )
      ; ( "turn_ref"
        , string_option_to_yojson (Option.map Ids.Turn_ref.to_string turn_ref) )
      ]
  | Transport_failure { content } ->
    `Assoc [ "kind", `String "transport_failure"; "content", `String content ]
  | No_assistant_reply -> `Assoc [ "kind", `String "no_assistant_reply" ]
;;

let staged_effect_to_yojson (staged : staged_effect) =
  `Assoc
    [ "request_result", request_result_to_yojson staged.request_result
    ; "transcript_effect", transcript_effect_to_yojson staged.transcript_effect
    ]
;;

let phase_to_yojson = function
  | Prepared -> `Assoc [ "kind", `String "prepared" ]
  | User_row_committed { user_row_id } ->
    `Assoc
      [ "kind", `String "user_row_committed"
      ; "user_row_id", `String user_row_id
      ]
  | Running { user_row_id } ->
    `Assoc [ "kind", `String "running"; "user_row_id", `String user_row_id ]
  | Effect_staged { user_row_id; staged } ->
    `Assoc
      [ "kind", `String "effect_staged"
      ; "user_row_id", `String user_row_id
      ; "effect", staged_effect_to_yojson staged
      ]
  | Transcript_committed { user_row_id; staged; transcript_row_id } ->
    `Assoc
      [ "kind", `String "transcript_committed"
      ; "user_row_id", `String user_row_id
      ; "effect", staged_effect_to_yojson staged
      ; "transcript_row_id", `String transcript_row_id
      ]
;;

let to_yojson record =
  `Assoc
    [ "schema_version", `Int record.schema_version
    ; "revision", `String (Int64.to_string record.revision)
    ; "request_id", `String (Request_id.to_string record.request_id)
    ; "payload", payload_to_yojson record.payload
    ; "phase", phase_to_yojson record.phase
    ; "created_at", `Float record.created_at
    ; "updated_at", `Float record.updated_at
    ]
;;

let validate_fields ~context ~expected fields =
  let rec loop seen = function
    | [] ->
      (match List.find_opt (fun name -> not (List.mem name seen)) expected with
       | None -> Ok ()
       | Some name ->
         Error
           (Decode_failed
              (Printf.sprintf "%s is missing field %S" context name)))
    | (name, _) :: rest ->
      if List.mem name seen
      then
        Error
          (Decode_failed
             (Printf.sprintf "%s has duplicate field %S" context name))
      else if not (List.mem name expected)
      then
        Error
          (Decode_failed
             (Printf.sprintf "%s has unknown field %S" context name))
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let assoc name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Decode_failed (Printf.sprintf "missing field %S" name))
;;

let json_string name fields =
  let* value = assoc name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Decode_failed (Printf.sprintf "field %S must be a string" name))
;;

let json_string_option name fields =
  let* value = assoc name fields in
  match value with
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ ->
    Error
      (Decode_failed (Printf.sprintf "field %S must be a string or null" name))
;;

let json_int name fields =
  let* value = assoc name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Decode_failed (Printf.sprintf "field %S must be an integer" name))
;;

let json_bool name fields =
  let* value = assoc name fields in
  match value with
  | `Bool value -> Ok value
  | _ -> Error (Decode_failed (Printf.sprintf "field %S must be a boolean" name))
;;

let json_float name fields =
  let* value = assoc name fields in
  match value with
  | `Float value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | `Intlit value ->
    (try Ok (Float.of_string value) with
     | Failure _ ->
       Error (Decode_failed (Printf.sprintf "field %S must be numeric" name)))
  | _ -> Error (Decode_failed (Printf.sprintf "field %S must be numeric" name))
;;

let attachment_of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"attachment"
        ~expected:[ "id"; "type"; "name"; "size"; "mime_type"; "data" ]
        fields
    in
    let* id = json_string "id" fields in
    let* att_type = json_string "type" fields in
    let* name = json_string "name" fields in
    let* size = json_int "size" fields in
    let* mime_type = json_string "mime_type" fields in
    let* data = json_string "data" fields in
    Ok ({ id; att_type; name; size; mime_type; data } : Keeper_chat_store.attachment)
  | _ -> Error (Decode_failed "attachment must be an object")
;;

let attachments_of_yojson = function
  | `List values ->
    List.fold_right
      (fun value result ->
         let* rest = result in
         let* attachment = attachment_of_yojson value in
         Ok (attachment :: rest))
      values
      (Ok [])
  | _ -> Error (Decode_failed "user_attachments must be a list")
;;

let speaker_of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"speaker"
        ~expected:[ "speaker_id"; "speaker_name"; "authority" ]
        fields
    in
    let* speaker_id = json_string_option "speaker_id" fields in
    let* speaker_name = json_string_option "speaker_name" fields in
    let* authority = json_string "authority" fields in
    let* speaker_authority =
      match Keeper_chat_store.authority_of_label authority with
      | Some authority -> Ok authority
      | None ->
        Error
          (Decode_failed (Printf.sprintf "unknown speaker authority %S" authority))
    in
    Ok
      ({ speaker_id; speaker_name; speaker_authority } : Keeper_chat_store.speaker)
  | _ -> Error (Decode_failed "speaker must be an object")
;;

let payload_of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"accepted payload"
        ~expected:
          [ "keeper_name"
          ; "submitted_by"
          ; "user_content"
          ; "user_attachments"
          ; "surface"
          ; "conversation_id"
          ; "external_message_id"
          ; "speaker"
          ]
        fields
    in
    let* keeper_name = json_string "keeper_name" fields in
    let* submitted_by = json_string "submitted_by" fields in
    let* user_content = json_string "user_content" fields in
    let* attachments_json = assoc "user_attachments" fields in
    let* user_attachments = attachments_of_yojson attachments_json in
    let* surface_json = assoc "surface" fields in
    let* surface =
      Surface_ref.of_json surface_json
      |> Result.map_error (fun detail -> Decode_failed detail)
    in
    let* () =
      if Surface_ref.to_json surface = surface_json
      then Ok ()
      else Error (Decode_failed "surface is not in canonical persisted form")
    in
    let* conversation_id = json_string_option "conversation_id" fields in
    let* external_message_id = json_string_option "external_message_id" fields in
    let* speaker_json = assoc "speaker" fields in
    let* speaker = speaker_of_yojson speaker_json in
    Ok
      { keeper_name
      ; submitted_by
      ; user_content
      ; user_attachments
      ; surface
      ; conversation_id
      ; external_message_id
      ; speaker
      }
  | _ -> Error (Decode_failed "payload must be an object")
;;

let request_result_of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"request result"
        ~expected:[ "ok"; "body"; "data" ]
        fields
    in
    let* ok = json_bool "ok" fields in
    let* body = json_string "body" fields in
    let* data_json = assoc "data" fields in
    let data =
      match data_json with
      | `Null -> None
      | value -> Some value
    in
    Ok { ok; body; data }
  | _ -> Error (Decode_failed "request_result must be an object")
;;

let transcript_effect_of_yojson = function
  | `Assoc fields ->
    let* kind = json_string "kind" fields in
    (match kind with
     | "assistant_reply" ->
       let* () =
         validate_fields
           ~context:"assistant reply effect"
           ~expected:[ "kind"; "content"; "blocks"; "turn_ref" ]
           fields
       in
       let* content = json_string "content" fields in
       let* blocks_json = assoc "blocks" fields in
       let* blocks =
         match blocks_json with
         | `Null -> Ok None
         | `List raw_blocks as json ->
           (match Keeper_chat_blocks.blocks_of_yojson json with
           | Some blocks
             when List.length blocks = List.length raw_blocks
                  && Keeper_chat_blocks.blocks_to_yojson blocks = json ->
              Ok (Some blocks)
            | Some _ | None ->
              Error (Decode_failed "assistant reply blocks are invalid"))
         | _ -> Error (Decode_failed "assistant reply blocks must be a list or null")
       in
       let* turn_ref_wire = json_string_option "turn_ref" fields in
       let* turn_ref =
         match turn_ref_wire with
         | None -> Ok None
         | Some wire ->
           (match Ids.Turn_ref.of_string wire with
            | Some turn_ref -> Ok (Some turn_ref)
            | None -> Error (Decode_failed "assistant reply turn_ref is invalid"))
       in
       Ok (Assistant_reply { content; blocks; turn_ref })
     | "transport_failure" ->
       let* () =
         validate_fields
           ~context:"transport failure effect"
           ~expected:[ "kind"; "content" ]
           fields
       in
       let* content = json_string "content" fields in
       Ok (Transport_failure { content })
     | "no_assistant_reply" ->
       let* () =
         validate_fields
           ~context:"no assistant reply effect"
           ~expected:[ "kind" ]
           fields
       in
       Ok No_assistant_reply
     | _ ->
       Error (Decode_failed (Printf.sprintf "unknown transcript effect %S" kind)))
  | _ -> Error (Decode_failed "transcript_effect must be an object")
;;

let staged_effect_of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"staged effect"
        ~expected:[ "request_result"; "transcript_effect" ]
        fields
    in
    let* request_result_json = assoc "request_result" fields in
    let* request_result = request_result_of_yojson request_result_json in
    let* transcript_effect_json = assoc "transcript_effect" fields in
    let* transcript_effect = transcript_effect_of_yojson transcript_effect_json in
    let staged = { request_result; transcript_effect } in
    let* () = validate_effect staged in
    Ok staged
  | _ -> Error (Decode_failed "effect must be an object")
;;

let phase_of_yojson = function
  | `Assoc fields ->
    let* kind = json_string "kind" fields in
    (match kind with
     | "prepared" ->
       let* () =
         validate_fields ~context:"prepared phase" ~expected:[ "kind" ] fields
       in
       Ok Prepared
     | "user_row_committed" ->
       let* () =
         validate_fields
           ~context:"user row committed phase"
           ~expected:[ "kind"; "user_row_id" ]
           fields
       in
       let* user_row_id = json_string "user_row_id" fields in
       Ok (User_row_committed { user_row_id })
     | "running" ->
       let* () =
         validate_fields
           ~context:"running phase"
           ~expected:[ "kind"; "user_row_id" ]
           fields
       in
       let* user_row_id = json_string "user_row_id" fields in
       Ok (Running { user_row_id })
     | "effect_staged" ->
       let* () =
         validate_fields
           ~context:"effect staged phase"
           ~expected:[ "kind"; "user_row_id"; "effect" ]
           fields
       in
       let* user_row_id = json_string "user_row_id" fields in
       let* effect_json = assoc "effect" fields in
       let* staged = staged_effect_of_yojson effect_json in
       Ok (Effect_staged { user_row_id; staged })
     | "transcript_committed" ->
       let* () =
         validate_fields
           ~context:"transcript committed phase"
           ~expected:[ "kind"; "user_row_id"; "effect"; "transcript_row_id" ]
           fields
       in
       let* user_row_id = json_string "user_row_id" fields in
       let* effect_json = assoc "effect" fields in
       let* staged = staged_effect_of_yojson effect_json in
       let* transcript_row_id = json_string "transcript_row_id" fields in
       Ok (Transcript_committed { user_row_id; staged; transcript_row_id })
     | _ -> Error (Decode_failed (Printf.sprintf "unknown phase %S" kind)))
  | _ -> Error (Decode_failed "phase must be an object")
;;

let of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"direct delivery checkpoint"
        ~expected:
          [ "schema_version"
          ; "revision"
          ; "request_id"
          ; "payload"
          ; "phase"
          ; "created_at"
          ; "updated_at"
          ]
        fields
    in
    let* decoded_schema_version = json_int "schema_version" fields in
    let* revision_wire = json_string "revision" fields in
    let* revision =
      try
        let revision = Int64.of_string revision_wire in
        if String.equal (Int64.to_string revision) revision_wire
        then Ok revision
        else Error (Decode_failed "revision is not a canonical int64")
      with
      | Failure _ -> Error (Decode_failed "revision is not an int64")
    in
    let* request_id_wire = json_string "request_id" fields in
    let* request_id =
      Request_id.of_string request_id_wire
      |> Result.map_error (fun detail -> Invalid_request_id detail)
    in
    let* payload_json = assoc "payload" fields in
    let* payload = payload_of_yojson payload_json in
    let* phase_json = assoc "phase" fields in
    let* phase = phase_of_yojson phase_json in
    let* created_at = json_float "created_at" fields in
    let* updated_at = json_float "updated_at" fields in
    let record =
      { schema_version = decoded_schema_version
      ; revision
      ; request_id
      ; payload
      ; phase
      ; created_at
      ; updated_at
      }
    in
    let* () = validate_record record in
    Ok record
  | _ -> Error (Decode_failed "direct delivery checkpoint must be an object")
;;

type operation_lock =
  { mutex : Eio.Mutex.t
  ; mutable users : int
  }

let operation_locks : (string, operation_lock) Hashtbl.t = Hashtbl.create 16
let operation_locks_mutex = Stdlib.Mutex.create ()

let acquire_operation_lock key =
  Stdlib.Mutex.protect operation_locks_mutex (fun () ->
    match Hashtbl.find_opt operation_locks key with
    | Some lock ->
      lock.users <- lock.users + 1;
      lock
    | None ->
      let lock = { mutex = Eio.Mutex.create (); users = 1 } in
      Hashtbl.add operation_locks key lock;
      lock)
;;

let release_operation_lock key lock =
  Stdlib.Mutex.protect operation_locks_mutex (fun () ->
    lock.users <- lock.users - 1;
    if lock.users = 0
    then
      match Hashtbl.find_opt operation_locks key with
      | Some current when current == lock -> Hashtbl.remove operation_locks key
      | Some _ | None -> ())
;;

let with_operation_lock key f =
  let lock = acquire_operation_lock key in
  match Eio.Mutex.use_rw ~protect:true lock.mutex f with
  | value ->
    release_operation_lock key lock;
    value
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    release_operation_lock key lock;
    Printexc.raise_with_backtrace exn backtrace
;;

type io =
  { save_json :
      ownership_root:string ->
      temp_dir:string ->
      path:string ->
      Yojson.Safe.t ->
      (unit, Keeper_fs.durable_write_error) result
  ; remove_file :
      ownership_root:string ->
      path:string ->
      (unit, Keeper_fs.durable_remove_error) result
  }

let production_io =
  { save_json =
      (fun ~ownership_root ~temp_dir ~path json ->
         Keeper_fs.save_json_durable_atomic
           ~ownership_root
           ~temp_dir
           path
           json)
  ; remove_file =
      (fun ~ownership_root ~path ->
         Keeper_fs.remove_file_durable ~ownership_root path)
  }
;;

let persistence_error ~operation ~request_id ~target_revision error =
  Persistence_failed
    { operation
    ; request_id
    ; target_revision
    ; publication =
        (if error.Keeper_fs.renamed
         then Published_indeterminate
         else Not_published)
    ; detail = Keeper_fs.durable_write_error_to_string error
    }
;;

let save_record
      io
      ~base_path
      ~staging_dir
      ~record_path
      ~operation
      (record : t)
  =
  io.save_json
    ~ownership_root:base_path
    ~temp_dir:staging_dir
    ~path:record_path
    (to_yojson record)
  |> Result.map_error
       (persistence_error
          ~operation
          ~request_id:record.request_id
          ~target_revision:record.revision)
;;

type file_read_failure =
  | Missing_file
  | Not_regular_file
  | File_identity_changed
  | File_grew
  | File_too_large
  | File_io_failed of string

let read_regular_file_no_follow path =
  let read () =
    let initial =
      try Ok (Unix.lstat path) with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Missing_file
      | exn -> Error (File_io_failed (Printexc.to_string exn))
    in
    match initial with
    | Error _ as error -> error
    | Ok initial when initial.Unix.st_kind <> Unix.S_REG -> Error Not_regular_file
    | Ok initial ->
      let opened =
        try
          Ok
            (Unix.openfile
               path
               [ Unix.O_RDONLY; Unix.O_CLOEXEC; Unix.O_NONBLOCK ]
               0)
        with
        | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Missing_file
        | exn -> Error (File_io_failed (Printexc.to_string exn))
      in
      (match opened with
       | Error _ as error -> error
       | Ok fd ->
         let read_result =
           try
             let current = Unix.fstat fd in
             if
               current.Unix.st_kind <> Unix.S_REG
               || current.Unix.st_dev <> initial.Unix.st_dev
               || current.Unix.st_ino <> initial.Unix.st_ino
             then Error File_identity_changed
             else if
               current.Unix.st_size < 0
               || current.Unix.st_size > Sys.max_string_length - 1
             then Error File_too_large
             else (
               let content = Bytes.create (current.Unix.st_size + 1) in
               let rec read_at offset =
                 if offset = Bytes.length content
                 then Error File_grew
                 else
                   try
                     match
                       Unix.read fd content offset (Bytes.length content - offset)
                     with
                     | 0 -> Ok (Bytes.sub_string content 0 offset)
                     | count -> read_at (offset + count)
                   with
                   | Unix.Unix_error (Unix.EINTR, _, _) -> read_at offset
               in
               read_at 0)
           with
           | exn -> Error (File_io_failed (Printexc.to_string exn))
         in
         let close_result =
           try
             Unix.close fd;
             Ok ()
           with
           | exn -> Error (File_io_failed (Printexc.to_string exn))
         in
         match read_result, close_result with
         | Ok content, Ok () -> Ok content
         | Error failure, Ok () -> Error failure
         | Ok _, Error failure -> Error failure
         | Error primary, Error (File_io_failed close_detail) ->
           let primary_detail =
             match primary with
             | Missing_file -> "file disappeared"
             | Not_regular_file -> "file is not regular"
             | File_identity_changed -> "file identity changed"
             | File_grew -> "file grew during read"
             | File_too_large -> "file exceeds runtime string bound"
             | File_io_failed detail -> detail
           in
           Error
             (File_io_failed
                (Printf.sprintf
                   "%s; close also failed: %s"
                   primary_detail
                   close_detail))
         | Error _, Error failure -> Error failure)
  in
  let result = Eio_guard.run_in_systhread read in
  Eio_guard.check_if_ready ();
  result
;;

let load_path_unlocked path =
  match read_regular_file_no_follow path with
  | Error Missing_file -> Error (Not_found path)
  | Error Not_regular_file -> Error (Record_not_regular path)
  | Error File_identity_changed -> Error (Record_identity_changed path)
  | Error File_grew -> Error (Record_grew_during_read path)
  | Error File_too_large -> Error (Record_too_large_for_runtime path)
  | Error (File_io_failed detail) ->
    Error (Read_failed (Printf.sprintf "%s: %s" path detail))
  | Ok content ->
    (try Yojson.Safe.from_string content |> of_yojson with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Yojson.Json_error detail -> Error (Decode_failed detail)
     | exn -> Error (Decode_failed (Printexc.to_string exn)))
;;

let ensure_exact_record ~keeper_name ~request_id (record : t) =
  if not (Request_id.equal request_id record.request_id)
  then Error Identity_mismatch
  else if not (String.equal keeper_name record.payload.keeper_name)
  then Error Identity_mismatch
  else Ok record
;;

let load_resolved ~record_path ~keeper_name ~request_id =
  with_operation_lock record_path (fun () ->
    let* record = load_path_unlocked record_path in
    ensure_exact_record ~keeper_name ~request_id record)
;;

let load ~base_path ~keeper_name ~request_id =
  let* _base_path, _keeper_name_id, record_path, _staging_dir =
    resolve_paths ~base_path ~keeper_name request_id
  in
  load_resolved ~record_path ~keeper_name ~request_id
;;

let redact_attachment redaction (attachment : Keeper_chat_store.attachment) =
  { attachment with
    name = Keeper_secret_redaction.redact_text redaction attachment.name
  ; data = Keeper_secret_redaction.redact_text redaction attachment.data
  }
;;

let redact_payload ~base_path (payload : accepted_payload) =
  let redaction =
    Keeper_secret_redaction.snapshot
      ~base_path
      ~keeper_name:payload.keeper_name
  in
  let payload =
    { payload with
      user_content =
        Keeper_secret_redaction.redact_text redaction payload.user_content
    ; user_attachments =
        List.map (redact_attachment redaction) payload.user_attachments
    }
  in
  redaction, payload
;;

let redact_effect redaction (staged : staged_effect) =
  let request_result =
    { staged.request_result with
      body =
        Keeper_secret_redaction.redact_text
          redaction
          staged.request_result.body
    ; data =
        Option.map
          (fun data ->
             Keeper_secret_redaction.redact_json redaction data)
          staged.request_result.data
    }
  in
  let* transcript_effect =
    match staged.transcript_effect with
    | Assistant_reply { content; blocks; turn_ref } ->
      let content = Keeper_secret_redaction.redact_text redaction content in
      let* blocks =
        match blocks with
        | None -> Ok None
        | Some blocks ->
          let json = Keeper_chat_blocks.blocks_to_yojson blocks in
          let redacted = Keeper_secret_redaction.redact_json redaction json in
          (match Keeper_chat_blocks.blocks_of_yojson redacted with
           | Some redacted_blocks when List.length redacted_blocks = List.length blocks ->
             Ok (Some redacted_blocks)
           | Some _ | None ->
             Error
               (Invalid_effect
                  "secret redaction could not preserve assistant block structure"))
      in
      Ok (Assistant_reply { content; blocks; turn_ref })
    | Transport_failure { content } ->
      Ok
        (Transport_failure
           { content = Keeper_secret_redaction.redact_text redaction content })
    | No_assistant_reply -> Ok No_assistant_reply
  in
  Ok { request_result; transcript_effect }
;;

let path_presence path =
  let result =
    Eio_guard.run_in_systhread (fun () ->
      try Ok (Some (Unix.lstat path)) with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
      | exn -> Error (Printexc.to_string exn))
  in
  Eio_guard.check_if_ready ();
  result
;;

let prepare_with_io io ~base_path ~request_id ~payload ~now =
  let* () = validate_now now in
  let* () = validate_payload payload in
  let* base_path, _keeper_name, record_path, staging_dir =
    resolve_paths ~base_path ~keeper_name:payload.keeper_name request_id
  in
  with_operation_lock record_path (fun () ->
    let* presence =
      path_presence record_path
      |> Result.map_error (fun detail -> Read_failed detail)
    in
    match presence with
    | Some _ -> Error (Already_exists record_path)
    | None ->
      let _redaction, payload = redact_payload ~base_path payload in
      let record =
        { schema_version
        ; revision = 0L
        ; request_id
        ; payload
        ; phase = Prepared
        ; created_at = now
        ; updated_at = now
        }
      in
      let* () = validate_record record in
      let* () =
        save_record
          io
          ~base_path
          ~staging_dir
          ~record_path
          ~operation:Prepare
          record
      in
      Ok record)
;;

let prepare = prepare_with_io production_io

let same_stable_identity (left : t) (right : t) =
  Request_id.equal left.request_id right.request_id
  && String.equal left.payload.keeper_name right.payload.keeper_name
  && String.equal left.payload.submitted_by right.payload.submitted_by
  && Float.equal left.created_at right.created_at
  && payload_to_yojson left.payload = payload_to_yojson right.payload
;;

let next_revision revision =
  if Int64.equal revision Int64.max_int
  then Error Revision_exhausted
  else Ok (Int64.succ revision)
;;

let replace_with_io
      io
      ~operation
      ~expected_phase
      ~base_path
      ~identity
      ~now
      next_phase
  =
  let* () = validate_now now in
  let* base_path, _keeper_name, record_path, staging_dir =
    resolve_paths
      ~base_path
      ~keeper_name:identity.payload.keeper_name
      identity.request_id
  in
  with_operation_lock record_path (fun () ->
    let* existing = load_path_unlocked record_path in
    let* existing =
      ensure_exact_record
        ~keeper_name:identity.payload.keeper_name
        ~request_id:identity.request_id
        existing
    in
    if not (same_stable_identity existing identity)
    then Error Identity_mismatch
    else if not (Int64.equal existing.revision identity.revision)
    then
      Error
        (Revision_conflict
           { expected = identity.revision; actual = existing.revision })
    else if to_yojson existing <> to_yojson identity
    then Error Identity_mismatch
    else if phase_kind existing.phase <> expected_phase
    then
      Error
        (Invalid_transition
           { expected = expected_phase; actual = phase_kind existing.phase })
    else
      let* phase = next_phase ~canonical_base_path:base_path existing in
      let* revision = next_revision existing.revision in
      let updated = { existing with revision; phase; updated_at = now } in
      let* () = validate_record updated in
      let* () =
        save_record
          io
          ~base_path
          ~staging_dir
          ~record_path
          ~operation
          updated
      in
      Ok updated)
;;

let row_id_of_append_once = function
  | Keeper_chat_store.Appended { row_id }
  | Keeper_chat_store.Already_present { row_id } -> row_id
;;

let direct_delivery_key request_id =
  Keeper_chat_delivery_identity.Direct_request request_id
;;

let commit_user_row_with_io io ~base_path ~identity ~now =
  replace_with_io
    io
    ~operation:Commit_user_row
    ~expected_phase:Prepared_phase
    ~base_path
    ~identity
    ~now
    (fun ~canonical_base_path existing ->
       let result =
         Keeper_chat_store.append_user_message_once
           ~base_dir:canonical_base_path
           ~keeper_name:existing.payload.keeper_name
           ~delivery_key:(direct_delivery_key existing.request_id)
           ~content:existing.payload.user_content
           ~attachments:existing.payload.user_attachments
           ~surface:existing.payload.surface
           ?conversation_id:existing.payload.conversation_id
           ?external_message_id:existing.payload.external_message_id
           ~speaker:existing.payload.speaker
           ()
       in
       let* appended =
         result
         |> Result.map_error (fun detail ->
           Transcript_failed { slot = User_transcript; detail })
       in
       let user_row_id = row_id_of_append_once appended in
       let* () = validate_row_id "user_row_id" user_row_id in
       Ok (User_row_committed { user_row_id }))
;;

let commit_user_row = commit_user_row_with_io production_io

let mark_running_with_io io ~base_path ~identity ~now =
  replace_with_io
    io
    ~operation:Mark_running
    ~expected_phase:User_row_committed_phase
    ~base_path
    ~identity
    ~now
    (fun ~canonical_base_path:_ existing ->
       match existing.phase with
       | User_row_committed { user_row_id } -> Ok (Running { user_row_id })
       | phase ->
         Error
           (Invalid_transition
              { expected = User_row_committed_phase; actual = phase_kind phase }))
;;

let mark_running = mark_running_with_io production_io

let stage_effect_with_io io ~base_path ~identity ~staged ~now =
  let* () = validate_effect staged in
  replace_with_io
    io
    ~operation:Stage_effect
    ~expected_phase:Running_phase
    ~base_path
    ~identity
    ~now
    (fun ~canonical_base_path existing ->
       match existing.phase with
       | Running { user_row_id } ->
         let redaction =
           Keeper_secret_redaction.snapshot
             ~base_path:canonical_base_path
             ~keeper_name:existing.payload.keeper_name
         in
         let* staged = redact_effect redaction staged in
         let* () = validate_effect staged in
         Ok (Effect_staged { user_row_id; staged })
       | phase ->
         Error
           (Invalid_transition
              { expected = Running_phase; actual = phase_kind phase }))
;;

let stage_effect = stage_effect_with_io production_io

let append_staged_transcript ~base_path existing ~user_row_id staged =
  match staged.transcript_effect with
  | Assistant_reply { content; blocks; turn_ref } ->
    Keeper_chat_store.append_assistant_message_once
      ~base_dir:base_path
      ~keeper_name:existing.payload.keeper_name
      ~delivery_key:(direct_delivery_key existing.request_id)
      ~content
      ~surface:existing.payload.surface
      ?conversation_id:existing.payload.conversation_id
      ?blocks
      ?turn_ref
      ~stream_lifecycle:
        [ Keeper_chat_store.Run_started
        ; Keeper_chat_store.Text_message_start
        ; Keeper_chat_store.Text_message_end
        ; Keeper_chat_store.Run_finished
        ]
      ()
    |> Result.map row_id_of_append_once
    |> Result.map_error (fun detail ->
      Transcript_failed { slot = Assistant_transcript; detail })
  | Transport_failure { content } ->
    Keeper_chat_store.append_assistant_message_once
      ~base_dir:base_path
      ~keeper_name:existing.payload.keeper_name
      ~delivery_key:(direct_delivery_key existing.request_id)
      ~content
      ~surface:existing.payload.surface
      ?conversation_id:existing.payload.conversation_id
      ~assistant_kind:Keeper_chat_store.Row_kind.Transport_failure
      ~stream_lifecycle:
        [ Keeper_chat_store.Run_started
        ; Keeper_chat_store.Text_message_start
        ; Keeper_chat_store.Text_message_end
        ; Keeper_chat_store.Run_error
        ]
      ()
    |> Result.map row_id_of_append_once
    |> Result.map_error (fun detail ->
      Transcript_failed { slot = Assistant_transcript; detail })
  | No_assistant_reply -> Ok user_row_id
;;

let commit_transcript_with_io io ~base_path ~identity ~now =
  replace_with_io
    io
    ~operation:Commit_transcript
    ~expected_phase:Effect_staged_phase
    ~base_path
    ~identity
    ~now
    (fun ~canonical_base_path existing ->
       match existing.phase with
       | Effect_staged { user_row_id; staged } ->
         let* transcript_row_id =
           append_staged_transcript
             ~base_path:canonical_base_path
             existing
             ~user_row_id
             staged
         in
         let* () = validate_row_id "transcript_row_id" transcript_row_id in
         Ok (Transcript_committed { user_row_id; staged; transcript_row_id })
       | phase ->
         Error
           (Invalid_transition
              { expected = Effect_staged_phase; actual = phase_kind phase }))
;;

let commit_transcript = commit_transcript_with_io production_io

let request_matches_payload request payload =
  String.equal
    (Keeper_invocation_types.request_target_name request)
    payload.keeper_name
  && String.equal (Keeper_invocation_types.request_prompt request) payload.user_content
;;

let observe_async_terminal ~base_path ~(identity : t) =
  let* base_path = canonical_base_path base_path in
  let request_id_wire = Request_id.to_string identity.request_id in
  let* proof =
    Keeper_msg_async.load_canonical_durable_terminal
      ~base_path
      ~caller:identity.payload.submitted_by
      request_id_wire
    |> Result.map_error (fun error -> Async_terminal_rejected error)
  in
  let entry = Keeper_msg_async.durable_terminal_entry proof in
  if
    String.equal entry.request_id request_id_wire
    && request_matches_payload entry.request identity.payload
    && String.equal entry.base_path base_path
    && String.equal entry.submitted_by identity.payload.submitted_by
  then Ok { canonical_terminal = proof; checkpoint = identity }
  else Error Async_terminal_identity_mismatch
;;

let proof_matches ~base_path (identity : t) proof =
  let entry =
    Keeper_msg_async.durable_terminal_entry proof.canonical_terminal
  in
  to_yojson proof.checkpoint = to_yojson identity
  && String.equal entry.base_path base_path
  && String.equal entry.request_id (Request_id.to_string identity.request_id)
  && request_matches_payload entry.request identity.payload
  && String.equal entry.submitted_by identity.payload.submitted_by
;;

let remove_after_async_terminal_with_io
      io
      ~base_path
      ~(identity : t)
      ~proof
  =
  let* base_path, _keeper_name, record_path, _staging_dir =
    resolve_paths
      ~base_path
      ~keeper_name:identity.payload.keeper_name
      identity.request_id
  in
  with_operation_lock record_path (fun () ->
    let* existing = load_path_unlocked record_path in
    let* existing =
      ensure_exact_record
        ~keeper_name:identity.payload.keeper_name
        ~request_id:identity.request_id
        existing
    in
    if not (same_stable_identity existing identity)
    then Error Identity_mismatch
    else if not (Int64.equal existing.revision identity.revision)
    then
      Error
        (Revision_conflict
           { expected = identity.revision; actual = existing.revision })
    else if to_yojson existing <> to_yojson identity
    then Error Identity_mismatch
    else
      match existing.phase with
      | Transcript_committed _ ->
        if not (proof_matches ~base_path existing proof)
        then Error Async_terminal_identity_mismatch
        else
          io.remove_file ~ownership_root:base_path ~path:record_path
          |> Result.map_error (fun error ->
            Removal_failed
              { removed = error.Keeper_fs.removed
              ; detail = Keeper_fs.durable_remove_error_to_string error
              })
      | phase -> Error (Removal_requires_transcript_commit (phase_kind phase)))
;;

let remove_after_async_terminal =
  remove_after_async_terminal_with_io production_io
;;

type directory_observation =
  | Directory_missing
  | Directory_ready
  | Directory_rejected of string

let inspect_directory ~base_path path =
  let observation =
    Eio_guard.run_in_systhread (fun () ->
      try
        match Fs_compat.inspect_owned_directory_chain ~ownership_root:base_path path with
        | Ok Fs_compat.Owned_directory_missing -> Directory_missing
        | Ok (Fs_compat.Owned_directory _) -> Directory_ready
        | Error rejection ->
          Directory_rejected
            (Fs_compat.owned_directory_chain_rejection_to_string rejection)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Directory_rejected (Printexc.to_string exn))
  in
  Eio_guard.check_if_ready ();
  observation
;;

let inventory_names ~area path =
  try Ok (Fs_compat.read_dir path) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      { area
      ; path
      ; reason = Directory_inventory_failed (Printexc.to_string exn)
      }
;;

let inspect_staging ~base_path staging_dir =
  match inspect_directory ~base_path staging_dir with
  | Directory_missing -> []
  | Directory_rejected detail ->
    [ { area = Atomic_staging
      ; path = staging_dir
      ; reason = Directory_boundary_rejected detail
      }
    ]
  | Directory_ready ->
    (match inventory_names ~area:Atomic_staging staging_dir with
     | Error artifact -> [ artifact ]
     | Ok names ->
       List.map
         (fun name ->
            { area = Atomic_staging
            ; path = Filename.concat staging_dir name
            ; reason = Unexpected_staging_entry
            })
         names)
;;

let artifact_of_load_error path error =
  let reason =
    match error with
    | Record_not_regular _ -> Active_entry_not_regular
    | _ -> Active_entry_unreadable error
  in
  { area = Active_records; path; reason }
;;

let inspect_active_entry ~keeper_name active_dir filename =
  let path = Filename.concat active_dir filename in
  match Request_id.of_string filename with
  | Error detail ->
    Error
      { area = Active_records
      ; path
      ; reason = Invalid_active_filename detail
      }
  | Ok filename_request_id ->
    (match with_operation_lock path (fun () -> load_path_unlocked path) with
     | Error error -> Error (artifact_of_load_error path error)
     | Ok record ->
       if not (Request_id.equal filename_request_id record.request_id)
       then
         Error
           { area = Active_records
           ; path
           ; reason = Filename_request_mismatch
           }
       else if not (String.equal keeper_name record.payload.keeper_name)
       then
         Error
           { area = Active_records
           ; path
           ; reason = Keeper_payload_mismatch
           }
       else Ok record)
;;

let inspect_active ~base_path ~keeper_name active_dir =
  match inspect_directory ~base_path active_dir with
  | Directory_missing -> [], []
  | Directory_rejected detail ->
    ( []
    , [ { area = Active_records
        ; path = active_dir
        ; reason = Directory_boundary_rejected detail
        }
      ] )
  | Directory_ready ->
    (match inventory_names ~area:Active_records active_dir with
     | Error artifact -> [], [ artifact ]
     | Ok names ->
       List.fold_left
         (fun (records, artifacts) filename ->
            Eio_guard.fair_yield ();
            match inspect_active_entry ~keeper_name active_dir filename with
            | Ok record -> record :: records, artifacts
            | Error artifact -> records, artifact :: artifacts)
         ([], [])
         names
       |> fun (records, artifacts) -> List.rev records, List.rev artifacts)
;;

let inspect_lane ~base_path ~keeper_name =
  let* base_path = canonical_base_path base_path in
  let* keeper_name_id = keeper_name_id keeper_name in
  let active_dir = active_dir_resolved ~base_path keeper_name_id in
  let staging_dir = staging_dir_resolved ~base_path keeper_name_id in
  let records, active_artifacts =
    inspect_active ~base_path ~keeper_name active_dir
  in
  let artifacts = active_artifacts @ inspect_staging ~base_path staging_dir in
  match artifacts with
  | [] -> Ok (Ready records)
  | _ -> Ok (Quarantined { recoverable = records; artifacts })
;;

module For_testing = struct
  type nonrec io = io

  let make_io ?before_durable_write ?before_durable_remove () =
    let save_json =
      match before_durable_write with
      | None -> production_io.save_json
      | Some before_stage ->
        (fun ~ownership_root ~temp_dir ~path json ->
           Keeper_fs.For_testing.save_json_durable_atomic
             ~before_stage
             ~ownership_root
             ~temp_dir
             path
             json)
    in
    let remove_file =
      match before_durable_remove with
      | None -> production_io.remove_file
      | Some before_stage ->
        (fun ~ownership_root ~path ->
           Keeper_fs.For_testing.remove_file_durable
             ~before_stage
             ~ownership_root
             path)
    in
    { save_json; remove_file }
  ;;

  let prepare = prepare_with_io
  let commit_user_row = commit_user_row_with_io
  let mark_running = mark_running_with_io
  let stage_effect = stage_effect_with_io
  let commit_transcript = commit_transcript_with_io
  let remove_after_async_terminal = remove_after_async_terminal_with_io
  let to_yojson = to_yojson
  let of_yojson = of_yojson

  let active_path ~base_path ~keeper_name ~request_id =
    let* _base_path, _keeper_name, path, _staging_dir =
      resolve_paths ~base_path ~keeper_name request_id
    in
    Ok path
  ;;

  let active_dir ~base_path ~keeper_name =
    let* base_path = canonical_base_path base_path in
    let* keeper_name = keeper_name_id keeper_name in
    Ok (active_dir_resolved ~base_path keeper_name)
  ;;

  let staging_dir ~base_path ~keeper_name =
    let* base_path = canonical_base_path base_path in
    let* keeper_name = keeper_name_id keeper_name in
    Ok (staging_dir_resolved ~base_path keeper_name)
  ;;
end
