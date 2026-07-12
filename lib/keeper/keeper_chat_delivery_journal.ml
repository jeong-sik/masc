module Identity = Keeper_chat_delivery_identity

type user_row_origin =
  | Needs_append
  | Already_persisted of { row_id : string }

type accepted_payload =
  { keeper_name : string
  ; submitted_by : string
  ; user_content : string
  ; user_attachments : Keeper_chat_store.attachment list
  ; surface : Surface_ref.t
  ; conversation_id : string option
  ; external_message_id : string option
  ; speaker : Keeper_chat_store.speaker
  ; user_row_origin : user_row_origin
  }

type terminal_delivery =
  | Assistant_reply of
      { content : string
      ; blocks : Keeper_chat_store.chat_block list option
      ; turn_ref : Ids.Turn_ref.t option
      }
  | Transport_failure of { content : string }
  | No_assistant_reply of { reason : no_assistant_reply_reason }

and no_assistant_reply_reason = Continuation_checkpoint

type terminal_result =
  { ok : bool
  ; poll_body : string
  ; delivery : terminal_delivery
  }

type phase =
  | Prepared
  | Accepted of { user_row_id : string }
  | Running of { user_row_id : string }
  | Terminal_pending of
      { terminal : terminal_result
      ; user_row_id : string
      }
  | Transcript_committed of
      { terminal : terminal_result
      ; transcript_row_id : string
      }
  | Final of
      { terminal : terminal_result
      ; transcript_row_id : string
      }

type t =
  { schema_version : int
  ; revision : int
  ; delivery_key : Identity.delivery_key
  ; payload : accepted_payload
  ; phase : phase
  ; created_at : float
  ; updated_at : float
  }

type error =
  | Already_exists of string
  | Not_found of string
  | Invalid_keeper_name of string
  | Io_error of string
  | Decode_error of string
  | Identity_mismatch
  | Revision_conflict of
      { expected : int
      ; actual : int
      }
  | Invalid_transition of
      { expected : string
      ; actual : string
      }
  | Transcript_error of string

let schema_version = 1
let ( let* ) = Result.bind

let phase_to_string = function
  | Prepared -> "prepared"
  | Accepted _ -> "accepted"
  | Running _ -> "running"
  | Terminal_pending _ -> "terminal_pending"
  | Transcript_committed _ -> "transcript_committed"
  | Final _ -> "final"
;;

let error_to_string = function
  | Already_exists path -> "chat delivery journal already exists: " ^ path
  | Not_found path -> "chat delivery journal not found: " ^ path
  | Invalid_keeper_name keeper_name ->
    Printf.sprintf "invalid Keeper name for delivery journal: %S" keeper_name
  | Io_error detail -> "chat delivery journal I/O failed: " ^ detail
  | Decode_error detail -> "chat delivery journal decode failed: " ^ detail
  | Identity_mismatch -> "chat delivery journal identity mismatch"
  | Revision_conflict { expected; actual } ->
    Printf.sprintf
      "chat delivery journal revision conflict: expected %d, actual %d"
      expected
      actual
  | Invalid_transition { expected; actual } ->
    Printf.sprintf
      "chat delivery journal transition rejected: expected %s, actual %s"
      expected
      actual
  | Transcript_error detail ->
    "chat delivery transcript persistence failed: " ^ detail
;;

type operation_lock =
  { mutex : Stdlib.Mutex.t
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
      let lock = { mutex = Stdlib.Mutex.create (); users = 1 } in
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
  Fun.protect
    ~finally:(fun () -> release_operation_lock key lock)
    (fun () -> Stdlib.Mutex.protect lock.mutex f)
;;

let valid_keeper_name name =
  let valid_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  (not (String.equal name ""))
  && not (String.equal name ".")
  && not (String.equal name "..")
  && String.for_all valid_char name
;;

let records_dir ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    ".chat-deliveries"
;;

let path ~base_path ~keeper_name delivery_key =
  if not (valid_keeper_name keeper_name)
  then Error (Invalid_keeper_name keeper_name)
  else
    Ok
      (Filename.concat
         (records_dir ~base_path ~keeper_name)
         (Identity.delivery_key_file_stem delivery_key ^ ".json"))
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
    ; ( "authority"
      , `String (Keeper_chat_store.authority_label speaker.speaker_authority) )
    ]
;;

let user_row_origin_to_yojson = function
  | Needs_append -> `Assoc [ "kind", `String "needs_append" ]
  | Already_persisted { row_id } ->
    `Assoc
      [ "kind", `String "already_persisted"; "row_id", `String row_id ]
;;

let payload_to_yojson payload =
  `Assoc
    [ "keeper_name", `String payload.keeper_name
    ; "submitted_by", `String payload.submitted_by
    ; "user_content", `String payload.user_content
    ; ( "user_attachments"
      , `List (List.map attachment_to_yojson payload.user_attachments) )
    ; "surface", Surface_ref.to_json payload.surface
    ; "conversation_id", string_option_to_yojson payload.conversation_id
    ; "external_message_id", string_option_to_yojson payload.external_message_id
    ; "speaker", speaker_to_yojson payload.speaker
    ; "user_row_origin", user_row_origin_to_yojson payload.user_row_origin
    ]
;;

let terminal_delivery_to_yojson = function
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
    `Assoc
      [ "kind", `String "transport_failure"; "content", `String content ]
  | No_assistant_reply { reason = Continuation_checkpoint } ->
    `Assoc
      [ "kind", `String "no_assistant_reply"
      ; "reason", `String "continuation_checkpoint"
      ]
;;

let terminal_to_yojson terminal =
  `Assoc
    [ "ok", `Bool terminal.ok
    ; "poll_body", `String terminal.poll_body
    ; "delivery", terminal_delivery_to_yojson terminal.delivery
    ]
;;

let phase_to_yojson = function
  | Prepared -> `Assoc [ "kind", `String "prepared" ]
  | Accepted { user_row_id } ->
    `Assoc
      [ "kind", `String "accepted"; "user_row_id", `String user_row_id ]
  | Running { user_row_id } ->
    `Assoc
      [ "kind", `String "running"; "user_row_id", `String user_row_id ]
  | Terminal_pending { terminal; user_row_id } ->
    `Assoc
      [ "kind", `String "terminal_pending"
      ; "terminal", terminal_to_yojson terminal
      ; "user_row_id", `String user_row_id
      ]
  | Transcript_committed { terminal; transcript_row_id } ->
    `Assoc
      [ "kind", `String "transcript_committed"
      ; "terminal", terminal_to_yojson terminal
      ; "transcript_row_id", `String transcript_row_id
      ]
  | Final { terminal; transcript_row_id } ->
    `Assoc
      [ "kind", `String "final"
      ; "terminal", terminal_to_yojson terminal
      ; "transcript_row_id", `String transcript_row_id
      ]
;;

let to_yojson journal =
  `Assoc
    [ "schema_version", `Int journal.schema_version
    ; "revision", `Int journal.revision
    ; "delivery_key", Identity.delivery_key_to_yojson journal.delivery_key
    ; "payload", payload_to_yojson journal.payload
    ; "phase", phase_to_yojson journal.phase
    ; "created_at", `Float journal.created_at
    ; "updated_at", `Float journal.updated_at
    ]
;;

let assoc name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Decode_error (Printf.sprintf "missing field %S" name))
;;

let validate_fields ~context ~expected fields =
  let rec loop seen = function
    | [] ->
      (match List.find_opt (fun name -> not (List.mem name seen)) expected with
       | Some name ->
         Error (Decode_error (Printf.sprintf "%s is missing field %S" context name))
       | None -> Ok ())
    | (name, _) :: rest ->
      if List.mem name seen
      then
        Error
          (Decode_error (Printf.sprintf "%s has duplicate field %S" context name))
      else if not (List.mem name expected)
      then
        Error
          (Decode_error (Printf.sprintf "%s has unknown field %S" context name))
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let string name fields =
  let* value = assoc name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Decode_error (Printf.sprintf "field %S must be a string" name))
;;

let int name fields =
  let* value = assoc name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Decode_error (Printf.sprintf "field %S must be an integer" name))
;;

let float name fields =
  let* value = assoc name fields in
  match value with
  | `Float value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | _ -> Error (Decode_error (Printf.sprintf "field %S must be numeric" name))
;;

let bool name fields =
  let* value = assoc name fields in
  match value with
  | `Bool value -> Ok value
  | _ -> Error (Decode_error (Printf.sprintf "field %S must be boolean" name))
;;

let string_option name fields =
  let* value = assoc name fields in
  match value with
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error (Decode_error (Printf.sprintf "field %S must be string or null" name))
;;

let attachment_of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"attachment"
        ~expected:[ "id"; "type"; "name"; "size"; "mime_type"; "data" ]
        fields
    in
    let* id = string "id" fields in
    let* att_type = string "type" fields in
    let* name = string "name" fields in
    let* size = int "size" fields in
    let* mime_type = string "mime_type" fields in
    let* data = string "data" fields in
    Ok ({ id; att_type; name; size; mime_type; data } : Keeper_chat_store.attachment)
  | _ -> Error (Decode_error "attachment must be an object")
;;

let attachments_of_yojson = function
  | `List values ->
    List.fold_right
      (fun value result ->
         let* rest = result in
         let* value = attachment_of_yojson value in
         Ok (value :: rest))
      values
      (Ok [])
  | _ -> Error (Decode_error "user_attachments must be a list")
;;

let speaker_of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"speaker"
        ~expected:[ "speaker_id"; "speaker_name"; "authority" ]
        fields
    in
    let* speaker_id = string_option "speaker_id" fields in
    let* speaker_name = string_option "speaker_name" fields in
    let* authority = string "authority" fields in
    let* speaker_authority =
      match Keeper_chat_store.authority_of_label authority with
      | Some value -> Ok value
      | None -> Error (Decode_error (Printf.sprintf "unknown authority %S" authority))
    in
    Ok ({ speaker_id; speaker_name; speaker_authority } : Keeper_chat_store.speaker)
  | _ -> Error (Decode_error "speaker must be an object")
;;

let user_row_origin_of_yojson = function
  | `Assoc fields ->
    let* kind = string "kind" fields in
    (match kind with
     | "needs_append" ->
       let* () =
         validate_fields
           ~context:"needs-append user row origin"
           ~expected:[ "kind" ]
           fields
       in
       Ok Needs_append
     | "already_persisted" ->
       let* () =
         validate_fields
           ~context:"persisted user row origin"
           ~expected:[ "kind"; "row_id" ]
           fields
       in
       let* row_id = string "row_id" fields in
       Ok (Already_persisted { row_id })
     | _ -> Error (Decode_error (Printf.sprintf "unknown user row origin %S" kind)))
  | _ -> Error (Decode_error "user_row_origin must be an object")
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
          ; "user_row_origin"
          ]
        fields
    in
    let* keeper_name = string "keeper_name" fields in
    let* submitted_by = string "submitted_by" fields in
    let* user_content = string "user_content" fields in
    let* attachments_json = assoc "user_attachments" fields in
    let* user_attachments = attachments_of_yojson attachments_json in
    let* surface_json = assoc "surface" fields in
    let* surface =
      Surface_ref.of_json surface_json |> Result.map_error (fun e -> Decode_error e)
    in
    let* conversation_id = string_option "conversation_id" fields in
    let* external_message_id = string_option "external_message_id" fields in
    let* speaker_json = assoc "speaker" fields in
    let* speaker = speaker_of_yojson speaker_json in
    let* user_row_origin_json = assoc "user_row_origin" fields in
    let* user_row_origin = user_row_origin_of_yojson user_row_origin_json in
    Ok
      { keeper_name
      ; submitted_by
      ; user_content
      ; user_attachments
      ; surface
      ; conversation_id
      ; external_message_id
      ; speaker
      ; user_row_origin
      }
  | _ -> Error (Decode_error "payload must be an object")
;;

let terminal_delivery_of_yojson = function
  | `Assoc fields ->
    let* kind = string "kind" fields in
    (match kind with
     | "assistant_reply" ->
       let* () =
         validate_fields
           ~context:"assistant terminal delivery"
           ~expected:[ "kind"; "content"; "blocks"; "turn_ref" ]
           fields
       in
       let* content = string "content" fields in
       let* blocks_json = assoc "blocks" fields in
       let* blocks =
         match blocks_json with
         | `Null -> Ok None
         | json ->
           (match Keeper_chat_blocks.blocks_of_yojson json with
            | Some blocks -> Ok (Some blocks)
            | None -> Error (Decode_error "invalid assistant blocks"))
       in
       let* turn_ref_wire = string_option "turn_ref" fields in
       let* turn_ref =
         match turn_ref_wire with
         | None -> Ok None
         | Some value ->
           (match Ids.Turn_ref.of_string value with
            | Some value -> Ok (Some value)
            | None -> Error (Decode_error "invalid terminal turn_ref"))
       in
       Ok (Assistant_reply { content; blocks; turn_ref })
     | "transport_failure" ->
       let* () =
         validate_fields
           ~context:"transport failure terminal delivery"
           ~expected:[ "kind"; "content" ]
           fields
       in
       let* content = string "content" fields in
       Ok (Transport_failure { content })
     | "no_assistant_reply" ->
       let* () =
         validate_fields
           ~context:"no-assistant terminal delivery"
           ~expected:[ "kind"; "reason" ]
           fields
       in
       let* reason = string "reason" fields in
       (match reason with
        | "continuation_checkpoint" ->
          Ok (No_assistant_reply { reason = Continuation_checkpoint })
        | _ ->
          Error
            (Decode_error
               (Printf.sprintf "unknown no-assistant reason %S" reason)))
     | _ -> Error (Decode_error (Printf.sprintf "unknown terminal delivery %S" kind)))
  | _ -> Error (Decode_error "terminal delivery must be an object")
;;

let terminal_of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"terminal result"
        ~expected:[ "ok"; "poll_body"; "delivery" ]
        fields
    in
    let* ok = bool "ok" fields in
    let* poll_body = string "poll_body" fields in
    let* delivery_json = assoc "delivery" fields in
    let* delivery = terminal_delivery_of_yojson delivery_json in
    Ok { ok; poll_body; delivery }
  | _ -> Error (Decode_error "terminal result must be an object")
;;

let phase_of_yojson = function
  | `Assoc fields ->
    let* kind = string "kind" fields in
    (match kind with
     | "prepared" ->
       let* () =
         validate_fields ~context:"prepared phase" ~expected:[ "kind" ] fields
       in
       Ok Prepared
     | "accepted" ->
       let* () =
         validate_fields
           ~context:"accepted phase"
           ~expected:[ "kind"; "user_row_id" ]
           fields
       in
       let* user_row_id = string "user_row_id" fields in
       Ok (Accepted { user_row_id })
     | "running" ->
       let* () =
         validate_fields
           ~context:"running phase"
           ~expected:[ "kind"; "user_row_id" ]
           fields
       in
       let* user_row_id = string "user_row_id" fields in
       Ok (Running { user_row_id })
     | "terminal_pending" ->
       let* () =
         validate_fields
           ~context:"terminal pending phase"
           ~expected:[ "kind"; "terminal"; "user_row_id" ]
           fields
       in
       let* terminal_json = assoc "terminal" fields in
       let* terminal = terminal_of_yojson terminal_json in
       let* user_row_id = string "user_row_id" fields in
       Ok (Terminal_pending { terminal; user_row_id })
     | "transcript_committed" | "final" ->
       let* () =
         validate_fields
           ~context:(kind ^ " phase")
           ~expected:[ "kind"; "terminal"; "transcript_row_id" ]
           fields
       in
       let* terminal_json = assoc "terminal" fields in
       let* terminal = terminal_of_yojson terminal_json in
       let* transcript_row_id = string "transcript_row_id" fields in
       if String.equal kind "transcript_committed"
       then Ok (Transcript_committed { terminal; transcript_row_id })
       else Ok (Final { terminal; transcript_row_id })
     | _ -> Error (Decode_error (Printf.sprintf "unknown journal phase %S" kind)))
  | _ -> Error (Decode_error "phase must be an object")
;;

let of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"journal record"
        ~expected:
          [ "schema_version"
          ; "revision"
          ; "delivery_key"
          ; "payload"
          ; "phase"
          ; "created_at"
          ; "updated_at"
          ]
        fields
    in
    let* decoded_schema_version = int "schema_version" fields in
    if decoded_schema_version <> schema_version
    then
      Error
        (Decode_error
           (Printf.sprintf
              "unsupported schema version %d"
              decoded_schema_version))
    else
      let* revision = int "revision" fields in
      let* delivery_key_json = assoc "delivery_key" fields in
      let* delivery_key =
        Identity.delivery_key_of_yojson delivery_key_json
        |> Result.map_error (fun e -> Decode_error e)
      in
      let* payload_json = assoc "payload" fields in
      let* payload = payload_of_yojson payload_json in
      let* phase_json = assoc "phase" fields in
      let* phase = phase_of_yojson phase_json in
      let* created_at = float "created_at" fields in
      let* updated_at = float "updated_at" fields in
      Ok
        { schema_version = decoded_schema_version
        ; revision
        ; delivery_key
        ; payload
        ; phase
        ; created_at
        ; updated_at
        }
  | _ -> Error (Decode_error "journal record must be an object")
;;

let load_path_unlocked record_path =
  if not (Fs_compat.file_exists record_path)
  then Error (Not_found record_path)
  else
    try
      Fs_compat.load_file record_path |> Yojson.Safe.from_string |> of_yojson
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Yojson.Json_error detail -> Error (Decode_error detail)
    | exn -> Error (Io_error (Printexc.to_string exn))
;;

let same_identity left right =
  Identity.delivery_key_equal left.delivery_key right.delivery_key
  && String.equal left.payload.keeper_name right.payload.keeper_name
  && String.equal left.payload.submitted_by right.payload.submitted_by
;;

let save record_path journal =
  Keeper_fs.save_json_atomic record_path (to_yojson journal)
  |> Result.map_error (fun detail -> Io_error detail)
;;

let prepare ~base_path ~delivery_key ~payload ~now =
  let* record_path = path ~base_path ~keeper_name:payload.keeper_name delivery_key in
  with_operation_lock record_path (fun () ->
    if Fs_compat.file_exists record_path
    then Error (Already_exists record_path)
    else
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
            List.map
              (fun (attachment : Keeper_chat_store.attachment) ->
                 { attachment with
                   data =
                     Keeper_secret_redaction.redact_text redaction attachment.data
                 })
              payload.user_attachments
        }
      in
      let journal =
        { schema_version
        ; revision = 0
        ; delivery_key
        ; payload
        ; phase = Prepared
        ; created_at = now
        ; updated_at = now
        }
      in
      save record_path journal |> Result.map (fun () -> journal))
;;

let replace
      ~base_path
      ~expected_revision
      ~identity
      ~expected_phase
      ~next_phase
      ~now
  =
  let* record_path =
    path
      ~base_path
      ~keeper_name:identity.payload.keeper_name
      identity.delivery_key
  in
  with_operation_lock record_path (fun () ->
    let* existing = load_path_unlocked record_path in
    if not (same_identity existing identity)
    then Error Identity_mismatch
    else if existing.revision <> expected_revision
    then
      Error
        (Revision_conflict
           { expected = expected_revision; actual = existing.revision })
    else if not (expected_phase existing.phase)
    then
      Error
        (Invalid_transition
           { expected = phase_to_string identity.phase
           ; actual = phase_to_string existing.phase
           })
    else
      let* phase = next_phase existing.phase in
      let updated =
        { existing with
          revision = existing.revision + 1
        ; phase
        ; updated_at = now
        }
      in
      save record_path updated |> Result.map (fun () -> updated))
;;

let mark_accepted
      ~base_path
      ~expected_revision
      ~identity
      ~user_row_id
      ~now
  =
  replace
    ~base_path
    ~expected_revision
    ~identity
    ~expected_phase:(function Prepared -> true | _ -> false)
    ~next_phase:(fun _ -> Ok (Accepted { user_row_id }))
    ~now
;;

let mark_running ~base_path ~expected_revision ~identity ~now =
  replace
    ~base_path
    ~expected_revision
    ~identity
    ~expected_phase:(function Accepted _ -> true | _ -> false)
    ~next_phase:(function
      | Accepted { user_row_id } -> Ok (Running { user_row_id })
      | phase ->
        Error
          (Invalid_transition
             { expected = "accepted"; actual = phase_to_string phase }))
    ~now
;;

let mark_terminal_pending
      ~base_path
      ~expected_revision
      ~identity
      ~terminal
      ~now
  =
  replace
    ~base_path
    ~expected_revision
    ~identity
    ~expected_phase:(function Running _ -> true | _ -> false)
    ~next_phase:(function
      | Running { user_row_id } -> Ok (Terminal_pending { terminal; user_row_id })
      | phase ->
        Error
          (Invalid_transition
             { expected = "running"; actual = phase_to_string phase }))
    ~now
;;

let mark_transcript_committed
      ~base_path
      ~expected_revision
      ~identity
      ~transcript_row_id
      ~now
  =
  replace
    ~base_path
    ~expected_revision
    ~identity
    ~expected_phase:(function Terminal_pending _ -> true | _ -> false)
    ~next_phase:(function
      | Terminal_pending { terminal; _ } ->
        Ok (Transcript_committed { terminal; transcript_row_id })
      | phase ->
        Error
          (Invalid_transition
             { expected = "terminal_pending"; actual = phase_to_string phase }))
    ~now
;;

let mark_final ~base_path ~expected_revision ~identity ~now =
  replace
    ~base_path
    ~expected_revision
    ~identity
    ~expected_phase:(function Transcript_committed _ -> true | _ -> false)
    ~next_phase:(function
      | Transcript_committed { terminal; transcript_row_id } ->
        Ok (Final { terminal; transcript_row_id })
      | phase ->
        Error
          (Invalid_transition
             { expected = "transcript_committed"; actual = phase_to_string phase }))
    ~now
;;

let mark_recovery_terminal_pending
      ~base_path
      ~expected_revision
      ~identity
      ~terminal
      ~now
  =
  replace
    ~base_path
    ~expected_revision
    ~identity
    ~expected_phase:(function Accepted _ | Running _ -> true | _ -> false)
    ~next_phase:(function
      | Accepted { user_row_id } | Running { user_row_id } ->
        Ok (Terminal_pending { terminal; user_row_id })
      | phase ->
        Error
          (Invalid_transition
             { expected = "accepted_or_running"; actual = phase_to_string phase }))
    ~now
;;

let row_id_of_append_once = function
  | Keeper_chat_store.Appended { row_id }
  | Keeper_chat_store.Already_present { row_id } -> row_id
;;

let append_accepted_user ~base_path journal =
  match journal.payload.user_row_origin with
  | Already_persisted { row_id } -> Ok row_id
  | Needs_append ->
    Keeper_chat_store.append_user_message_once
      ~base_dir:base_path
      ~keeper_name:journal.payload.keeper_name
      ~delivery_key:journal.delivery_key
      ~content:journal.payload.user_content
      ~attachments:journal.payload.user_attachments
      ~surface:journal.payload.surface
      ?conversation_id:journal.payload.conversation_id
      ?external_message_id:journal.payload.external_message_id
      ~speaker:journal.payload.speaker
      ()
    |> Result.map row_id_of_append_once
    |> Result.map_error (fun detail -> Transcript_error detail)
;;

let append_terminal ~base_path journal ~user_row_id terminal =
  match terminal.delivery with
  | Assistant_reply { content; blocks; turn_ref } ->
    Keeper_chat_store.append_assistant_message_once
      ~base_dir:base_path
      ~keeper_name:journal.payload.keeper_name
      ~delivery_key:journal.delivery_key
      ~content
      ~surface:journal.payload.surface
      ?conversation_id:journal.payload.conversation_id
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
    |> Result.map_error (fun detail -> Transcript_error detail)
  | Transport_failure { content } ->
    Keeper_chat_store.append_assistant_message_once
      ~base_dir:base_path
      ~keeper_name:journal.payload.keeper_name
      ~delivery_key:journal.delivery_key
      ~content
      ~surface:journal.payload.surface
      ?conversation_id:journal.payload.conversation_id
      ~assistant_kind:Keeper_chat_store.Row_kind.Transport_failure
      ~stream_lifecycle:
        [ Keeper_chat_store.Run_started
        ; Keeper_chat_store.Text_message_start
        ; Keeper_chat_store.Text_message_end
        ; Keeper_chat_store.Run_error
        ]
      ()
    |> Result.map row_id_of_append_once
    |> Result.map_error (fun detail -> Transcript_error detail)
  | No_assistant_reply { reason = Continuation_checkpoint } -> Ok user_row_id
;;

let interrupted_terminal journal =
  let request_label = Identity.delivery_key_file_stem journal.delivery_key in
  let poll_body =
    Yojson.Safe.to_string
      (`Assoc
          [ "error", `String "keeper_chat_delivery_interrupted"
          ; "message", `String "request lost its worker before terminal delivery"
          ; "delivery_ref", `String request_label
          ])
  in
  { ok = false
  ; poll_body
  ; delivery =
      Transport_failure
        { content =
            "Keeper request failed: the server restarted before terminal delivery completed."
        }
  }
;;

let rec recover_record ~base_path ~now journal =
  match journal.phase with
  | Prepared ->
    let* user_row_id = append_accepted_user ~base_path journal in
    let* accepted =
      mark_accepted
        ~base_path
        ~expected_revision:journal.revision
        ~identity:journal
        ~user_row_id
        ~now
    in
    recover_record ~base_path ~now accepted
  | Accepted _ | Running _ ->
    let* pending =
      mark_recovery_terminal_pending
        ~base_path
        ~expected_revision:journal.revision
        ~identity:journal
        ~terminal:(interrupted_terminal journal)
        ~now
    in
    recover_record ~base_path ~now pending
  | Terminal_pending { terminal; user_row_id } ->
    let* transcript_row_id =
      append_terminal ~base_path journal ~user_row_id terminal
    in
    let* committed =
      mark_transcript_committed
        ~base_path
        ~expected_revision:journal.revision
        ~identity:journal
        ~transcript_row_id
        ~now
    in
    recover_record ~base_path ~now committed
  | Transcript_committed _ ->
    mark_final
      ~base_path
      ~expected_revision:journal.revision
      ~identity:journal
      ~now
  | Final _ -> Ok journal
;;

type recovery_failure =
  { keeper_name : string
  ; delivery_ref : string
  ; error : error
  }

type recovery_report =
  { recovered : int
  ; already_final : int
  ; failures : recovery_failure list
  }

let load ~base_path ~keeper_name delivery_key =
  let* record_path = path ~base_path ~keeper_name delivery_key in
  with_operation_lock record_path (fun () ->
    let* journal = load_path_unlocked record_path in
    if
      Identity.delivery_key_equal journal.delivery_key delivery_key
      && String.equal journal.payload.keeper_name keeper_name
    then Ok journal
    else Error Identity_mismatch)
;;

let list_for_keeper ~base_path ~keeper_name =
  if not (valid_keeper_name keeper_name)
  then Error (Invalid_keeper_name keeper_name)
  else
    let directory = records_dir ~base_path ~keeper_name in
    if not (Fs_compat.file_exists directory)
    then Ok []
    else
      try
        Sys.readdir directory
        |> Array.to_list
        |> List.sort String.compare
        |> List.fold_left
             (fun result filename ->
                let* records = result in
                let record_path = Filename.concat directory filename in
                if Sys.is_directory record_path
                then Ok records
                else
                  let* journal =
                    with_operation_lock record_path (fun () ->
                      load_path_unlocked record_path)
                  in
                  if String.equal journal.payload.keeper_name keeper_name
                  then Ok (journal :: records)
                  else Error Identity_mismatch)
             (Ok [])
        |> Result.map List.rev
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Io_error (Printexc.to_string exn))
;;

let recover_all ~base_path ~now =
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  if not (Fs_compat.file_exists keepers_dir)
  then { recovered = 0; already_final = 0; failures = [] }
  else
    try
      Sys.readdir keepers_dir
      |> Array.to_list
      |> List.sort String.compare
      |> List.fold_left
           (fun report keeper_name ->
              let keeper_path = Filename.concat keepers_dir keeper_name in
              if not (Sys.is_directory keeper_path)
              then report
              else
                match list_for_keeper ~base_path ~keeper_name with
                | Error error ->
                  { report with
                    failures =
                      { keeper_name; delivery_ref = "inventory"; error }
                      :: report.failures
                  }
                | Ok records ->
                  List.fold_left
                    (fun report journal ->
                       let delivery_ref =
                         Identity.delivery_key_file_stem journal.delivery_key
                       in
                       match journal.phase with
                       | Final _ ->
                         { report with already_final = report.already_final + 1 }
                       | _ ->
                         (match recover_record ~base_path ~now journal with
                          | Ok _ -> { report with recovered = report.recovered + 1 }
                          | Error error ->
                            { report with
                              failures =
                                { keeper_name; delivery_ref; error }
                                :: report.failures
                            }))
                    report
                    records)
           { recovered = 0; already_final = 0; failures = [] }
      |> fun report -> { report with failures = List.rev report.failures }
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      { recovered = 0
      ; already_final = 0
      ; failures =
          [ { keeper_name = "<inventory>"
            ; delivery_ref = "inventory"
            ; error = Io_error (Printexc.to_string exn)
            }
          ]
      }
;;

module For_testing = struct
  let to_yojson = to_yojson
  let of_yojson = of_yojson
  let path = path
end
