open Result.Syntax

type request_header = {
  id : string;
  task_id : string;
  worker : string;
  created_at : float;
}

type evidence_read_failure =
  | Evidence_missing
  | Evidence_not_regular_file
  | Evidence_outside_worker_playground
  | Evidence_invalid_reference
  | Evidence_invalid_utf8
  | Evidence_symbolic_link
  | Evidence_changed_during_read
  | Evidence_read_error of string

type submitted_evidence_item =
  | Evidence_note of string
  | Evidence_artifact of
      { reference : string
      ; content : string
      ; bytes : int
      ; truncated : bool
      ; content_sha256 : string
      }
  | Evidence_artifact_unreadable of
      { reference : string
      ; reason : evidence_read_failure
      }

type evidence_access_failure =
  | Completion_authority_identity_missing
  | Request_not_found
  | Request_header_invalid of string
  | Evidence_snapshot_invalid of string
  | Request_load_error of string
  | Request_scope_mismatch

type submitted_evidence_access =
  | Evidence_available of
      { request : request_header
      ; items : submitted_evidence_item list
      }
  | Evidence_unavailable of
      { request_id : string
      ; reason : evidence_access_failure
      }

let evidence_read_failure_to_string = function
  | Evidence_missing -> "missing"
  | Evidence_not_regular_file -> "not_regular_file"
  | Evidence_outside_worker_playground -> "outside_worker_playground"
  | Evidence_invalid_reference -> "invalid_reference"
  | Evidence_invalid_utf8 -> "invalid_utf8"
  | Evidence_symbolic_link -> "symbolic_link"
  | Evidence_changed_during_read -> "changed_during_read"
  | Evidence_read_error detail -> "read_error:" ^ detail

let evidence_read_failure_code = function
  | Evidence_missing -> "missing"
  | Evidence_not_regular_file -> "not_regular_file"
  | Evidence_outside_worker_playground -> "outside_worker_playground"
  | Evidence_invalid_reference -> "invalid_reference"
  | Evidence_invalid_utf8 -> "invalid_utf8"
  | Evidence_symbolic_link -> "symbolic_link"
  | Evidence_changed_during_read -> "changed_during_read"
  | Evidence_read_error _ -> "read_error"

let evidence_read_failure_of_string = function
  | "missing" -> Ok Evidence_missing
  | "not_regular_file" -> Ok Evidence_not_regular_file
  | "outside_worker_playground" -> Ok Evidence_outside_worker_playground
  | "invalid_reference" -> Ok Evidence_invalid_reference
  | "invalid_utf8" -> Ok Evidence_invalid_utf8
  | "symbolic_link" -> Ok Evidence_symbolic_link
  | "changed_during_read" -> Ok Evidence_changed_during_read
  | raw when String.starts_with ~prefix:"read_error:" raw ->
    Ok
      (Evidence_read_error
         (String.sub raw 11 (String.length raw - 11)))
  | raw -> Error (Printf.sprintf "unknown evidence read failure %S" raw)

let content_sha256 content =
  Digestif.SHA256.(digest_string content |> to_hex)

let submitted_evidence_item_to_yojson = function
  | Evidence_note note ->
    `Assoc [ "kind", `String "note"; "content", `String note ]
  | Evidence_artifact
      { reference; content; bytes; truncated; content_sha256 } ->
    `Assoc
      [ "kind", `String "artifact"
      ; "reference", `String reference
      ; "content", `String content
      ; "bytes", `Int bytes
      ; "truncated", `Bool truncated
      ; "content_sha256", `String content_sha256
      ]
  | Evidence_artifact_unreadable { reference; reason } ->
    (match reason with
     | Evidence_invalid_reference ->
       `Assoc
         [ "kind", `String "artifact_unreadable"
         ; "reason", `String (evidence_read_failure_code reason)
         ]
     | ( Evidence_missing
       | Evidence_not_regular_file
       | Evidence_outside_worker_playground
       | Evidence_invalid_utf8
       | Evidence_symbolic_link
       | Evidence_changed_during_read
       | Evidence_read_error _ ) ->
       `Assoc
         [ "kind", `String "artifact_unreadable"
         ; "reference", `String reference
         ; "reason", `String (evidence_read_failure_to_string reason)
         ])

let request_header_to_yojson request =
  `Assoc
    [ "id", `String request.id
    ; "task_id", `String request.task_id
    ; "worker", `String request.worker
    ; "created_at", `Float request.created_at
    ]
;;

let evidence_access_failure_code = function
  | Completion_authority_identity_missing ->
    "completion_authority_identity_missing"
  | Request_not_found -> "request_not_found"
  | Request_header_invalid _ -> "request_header_invalid"
  | Evidence_snapshot_invalid _ -> "evidence_snapshot_invalid"
  | Request_load_error _ -> "request_load_error"
  | Request_scope_mismatch -> "request_scope_mismatch"

let evidence_access_failure_to_string ~request_id = function
  | Completion_authority_identity_missing -> "completion authority identity is empty"
  | Request_not_found -> Printf.sprintf "Verification %s not found" request_id
  | Request_header_invalid detail ->
    Printf.sprintf
      "Failed to decode verification %s request header: %s"
      request_id
      detail
  | Evidence_snapshot_invalid detail ->
    Printf.sprintf
      "Failed to decode verification %s evidence snapshot: %s"
      request_id
      detail
  | Request_load_error detail ->
    Printf.sprintf
      "Failed to load verification %s evidence: %s"
      request_id
      detail
  | Request_scope_mismatch ->
    "verification request does not match the awaiting task and producer"

let submitted_evidence_access_to_yojson = function
  | Evidence_available { request; items } ->
    `Assoc
      [ "access", `String "available"
      ; "request", request_header_to_yojson request
      ; "items", `List (List.map submitted_evidence_item_to_yojson items)
      ]
  | Evidence_unavailable { request_id; reason } ->
    `Assoc
      [ "access", `String "unavailable"
      ; "request_id", `String request_id
      ; "reason", `String (evidence_access_failure_to_string ~request_id reason)
      ]
;;

let submitted_evidence_item_metadata_to_yojson = function
  | Evidence_note note ->
    `Assoc
      [ "kind", `String "note"
      ; "bytes", `Int (String.length note)
      ; "content_sha256", `String (content_sha256 note)
      ]
  | Evidence_artifact { reference; bytes; truncated; content_sha256; _ } ->
    `Assoc
      [ "kind", `String "artifact"
      ; "reference", `String reference
      ; "bytes", `Int bytes
      ; "truncated", `Bool truncated
      ; "content_sha256", `String content_sha256
      ]
  | Evidence_artifact_unreadable { reference; reason } ->
    `Assoc
      [ "kind", `String "artifact_unreadable"
      ; "reference", `String reference
      ; ( "reason"
        , `String (evidence_read_failure_code reason) )
      ]
;;

let submitted_evidence_access_metadata_to_yojson = function
  | Evidence_available { request; items } ->
    `Assoc
      [ "access", `String "available"
      ; "request_id", `String request.id
      ; "task_id", `String request.task_id
      ; "worker", `String request.worker
      ; "created_at", `Float request.created_at
      ; "item_count", `Int (List.length items)
      ; ( "items"
        , `List (List.map submitted_evidence_item_metadata_to_yojson items) )
      ]
  | Evidence_unavailable { request_id; reason } ->
    `Assoc
      [ "access", `String "unavailable"
      ; "request_id", `String request_id
      ; "reason_code", `String (evidence_access_failure_code reason)
      ]
;;

let submitted_evidence_item_of_yojson = function
  | `Assoc fields ->
    let string_field key =
      match List.assoc_opt key fields with
      | Some (`String value) -> Ok value
      | Some value ->
        Error
          (Printf.sprintf
             "submitted evidence snapshot field %s must be a string, got %s"
             key
             (Json_util.excerpt value))
      | None ->
        Error
          (Printf.sprintf
             "submitted evidence snapshot is missing string field %s"
             key)
    in
    (match List.assoc_opt "kind" fields with
     | Some (`String "note") ->
       Result.map (fun note -> Evidence_note note) (string_field "content")
     | Some (`String "artifact") ->
       let open Result.Syntax in
       let* reference = string_field "reference" in
       let* content = string_field "content" in
       let* expected_content_sha256 = string_field "content_sha256" in
       let* bytes =
         match List.assoc_opt "bytes" fields with
         | Some (`Int value) when value >= 0 -> Ok value
         | Some value ->
           Error
             (Printf.sprintf
                "submitted evidence snapshot bytes must be a non-negative integer, got %s"
                (Json_util.excerpt value))
         | None -> Error "submitted evidence snapshot is missing bytes"
       in
       let* truncated =
         match List.assoc_opt "truncated" fields with
         | Some (`Bool value) -> Ok value
         | Some value ->
           Error
             (Printf.sprintf
                "submitted evidence snapshot truncated must be a boolean, got %s"
                (Json_util.excerpt value))
         | None -> Error "submitted evidence snapshot is missing truncated"
       in
       let content_bytes = String.length content in
       if
         not
           (String.equal
              expected_content_sha256
              (content_sha256 content))
       then
         Error
           "submitted evidence snapshot content_sha256 does not match persisted content"
       else if truncated && bytes <= content_bytes
       then
         Error
           "truncated submitted evidence snapshot must report more source bytes than persisted content"
       else if (not truncated) && bytes <> content_bytes
       then
         Error
           "non-truncated submitted evidence snapshot bytes must equal persisted content length"
       else
         Ok
           (Evidence_artifact
              { reference
              ; content
              ; bytes
              ; truncated
              ; content_sha256 = expected_content_sha256
              })
     | Some (`String "artifact_unreadable") ->
       let open Result.Syntax in
       let* reference = string_field "reference" in
       let* reason_raw = string_field "reason" in
       let* reason = evidence_read_failure_of_string reason_raw in
       Ok (Evidence_artifact_unreadable { reference; reason })
     | Some (`String kind) ->
       Error (Printf.sprintf "unknown submitted evidence snapshot kind %S" kind)
     | Some value ->
       Error
         (Printf.sprintf
            "submitted evidence snapshot kind must be a string, got %s"
            (Json_util.excerpt value))
     | None -> Error "submitted evidence snapshot is missing kind")
  | value ->
    Error
      (Printf.sprintf
         "submitted evidence snapshot item must be an object, got %s"
         (Json_util.excerpt value))

let project_root_of_base_path base_path =
  if Filename.basename base_path = Common.masc_dirname then
    Filename.dirname base_path
  else
    base_path

let active_verifications_dir base_path =
  let base_path = project_root_of_base_path base_path in
  Filename.concat (Workspace_utils.masc_dir_from_base_path ~base_path) "verifications"

let verifications_dir base_path =
  active_verifications_dir base_path

let request_path base_path req_id =
  Filename.concat (verifications_dir base_path) (req_id ^ ".json")

let request_header_of_yojson = function
  | `Assoc fields ->
      let required_field key =
        match List.assoc_opt key fields with
        | Some value -> Ok value
        | None ->
          Error
            (Printf.sprintf
               "verification request missing required field %s (object had keys: [%s])"
               key
               (String.concat ", " (List.map fst fields)))
      in
      let required_string key =
        let* value = required_field key in
        match value with
        | `String value when not (String.equal (String.trim value) "") -> Ok value
        | `String _ -> Error (Printf.sprintf "verification request field %s is blank" key)
        | other ->
          Error
            (Printf.sprintf
               "verification request field %s must be a non-empty string, got %s"
               key
               (Json_util.excerpt other))
      in
      let* id = required_string "id" in
      let* task_id = required_string "task_id" in
      let* worker = required_string "worker" in
      let* created_at = required_field "created_at" in
      let* created_at =
        match created_at with
        | `Float value -> Ok value
        | `Int value -> Ok (Float.of_int value)
        | other ->
          Error
            (Printf.sprintf
               "verification request field created_at must be a number, got %s"
               (Json_util.excerpt other))
      in
      (match classify_float created_at with
       | FP_nan | FP_infinite ->
         Error "verification request field created_at must be finite"
       | FP_normal | FP_subnormal | FP_zero ->
         Ok { id; task_id; worker; created_at })
  | other ->
      Error
        (Printf.sprintf
           "verification request must be a JSON object, got %s: %s"
           (Json_util.kind_name other)
           (Json_util.excerpt other))

let load_request_header base_path req_id =
  let path = request_path base_path req_id in
  if Sys.file_exists path then
    try
      let json = Safe_ops.read_json_eio path in
      request_header_of_yojson json
    with Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Error
             (Printf.sprintf "Failed to load verification %s: %s" req_id
                (Printexc.to_string exn))
  else
    Error (Printf.sprintf "Verification %s not found" req_id)

let submitted_evidence_snapshot_of_request_json = function
  | `Assoc fields ->
    (match List.assoc_opt "output" fields with
     | Some (`Assoc output_fields) ->
       (match List.assoc_opt "submitted_evidence" output_fields with
        | Some (`List values) ->
          let rec collect acc = function
            | [] -> Ok (List.rev acc)
            | value :: rest ->
              (match submitted_evidence_item_of_yojson value with
               | Ok item -> collect (item :: acc) rest
               | Error _ as error -> error)
          in
          collect [] values
        | Some other ->
          Error
            (Printf.sprintf
               "submitted_evidence must be a typed snapshot list, got %s"
               (Json_util.excerpt other))
        | None ->
          Error "verification request output has no submitted_evidence")
     | Some other ->
       Error
         (Printf.sprintf
            "verification request output must be an object, got %s"
            (Json_util.excerpt other))
     | None -> Error "verification request has no output")
  | other ->
    Error
      (Printf.sprintf
         "verification request must be an object, got %s"
         (Json_util.excerpt other))

let load_request_for_evidence base_path req_id =
  let path = request_path base_path req_id in
  if not (Sys.file_exists path) then
    Error Request_not_found
  else
    try
      let json = Safe_ops.read_json_eio path in
      match request_header_of_yojson json with
      | Error detail -> Error (Request_header_invalid detail)
      | Ok request ->
        (match submitted_evidence_snapshot_of_request_json json with
         | Error detail -> Error (Evidence_snapshot_invalid detail)
         | Ok snapshot -> Ok (request, snapshot))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Error (Request_load_error (Printexc.to_string exn))

let verification_evidence_max_bytes = 20_000

type utf8_scan =
  | Utf8_valid
  | Utf8_incomplete_at of int
  | Utf8_invalid

let scan_utf8 bytes =
  let length = String.length bytes in
  let byte index = Char.code bytes.[index] in
  let continuation index =
    index < length && byte index land 0xC0 = 0x80
  in
  let rec loop index =
    if index = length then Utf8_valid
    else
      let first = byte index in
      if first <= 0x7F then loop (index + 1)
      else
        let required, second_min, second_max =
          if first >= 0xC2 && first <= 0xDF then 2, 0x80, 0xBF
          else if first = 0xE0 then 3, 0xA0, 0xBF
          else if (first >= 0xE1 && first <= 0xEC) || (first >= 0xEE && first <= 0xEF)
          then 3, 0x80, 0xBF
          else if first = 0xED then 3, 0x80, 0x9F
          else if first = 0xF0 then 4, 0x90, 0xBF
          else if first >= 0xF1 && first <= 0xF3 then 4, 0x80, 0xBF
          else if first = 0xF4 then 4, 0x80, 0x8F
          else 0, 0, 0
        in
        if required = 0 then Utf8_invalid
        else if index + required > length then Utf8_incomplete_at index
        else
          let second = byte (index + 1) in
          if
            second < second_min
            || second > second_max
            || (required >= 3 && not (continuation (index + 2)))
            || (required = 4 && not (continuation (index + 3)))
          then Utf8_invalid
          else loop (index + required)
  in
  loop 0

let evidence_read_failure_of_owned_read_failure = function
  | Fs_compat.Ownership_boundary_rejected _ ->
    Evidence_outside_worker_playground
  | Path_is_not_regular_file { kind; _ } ->
    if kind = Unix.S_LNK then Evidence_symbolic_link else Evidence_not_regular_file
  | Filesystem_identity_changed _ ->
    Evidence_changed_during_read
  | Owned_file_operation_failed { cause; _ } ->
    Evidence_read_error (Printexc.to_string cause)

let read_regular_file_prefix ~ownership_root path =
  match
    Fs_compat.load_owned_regular_file_prefix
      ~ownership_root
      ~max_bytes:verification_evidence_max_bytes
      path
  with
  | Error error ->
    Error (evidence_read_failure_of_owned_read_failure error.failure)
  | Ok None -> Error Evidence_missing
  | Ok (Some prefix) ->
    (match scan_utf8 prefix.content with
     | Utf8_valid ->
       Ok (prefix.content, prefix.file_size, prefix.truncated)
     | Utf8_incomplete_at index when prefix.truncated ->
       Ok
         ( String.sub prefix.content 0 index
         , prefix.file_size
         , true )
     | Utf8_incomplete_at _ | Utf8_invalid ->
       Error Evidence_invalid_utf8)

let artifact_reference_prefix = "artifact:"
let note_reference_prefix = "note:"

let strip_prefix ~prefix value =
  if String.starts_with ~prefix value
  then
    Some
      (String.sub
         value
         (String.length prefix)
         (String.length value - String.length prefix))
  else None

let valid_producer_relative_path path =
  Filename.is_relative path
  && not (String.equal path "")
  && (String.split_on_char '/' path
      |> List.for_all (fun segment ->
        not
          (String.equal segment ""
           || String.equal segment "."
           || String.equal segment "..")))

let inspect_producer_relative_artifact ~base_path ~worker ~reference relative_path =
  if not (valid_producer_relative_path relative_path)
  then Evidence_artifact_unreadable { reference; reason = Evidence_invalid_reference }
  else
    let project_root = project_root_of_base_path base_path in
    let ownership_root =
      Keeper_sandbox_config.host_root_abs_of_agent
        ~base_path:project_root
        ~agent_name:worker
      |> Env_config_core.strip_trailing_slashes
    in
    let target = Filename.concat ownership_root relative_path in
    match read_regular_file_prefix ~ownership_root target with
    | Error reason ->
      Evidence_artifact_unreadable { reference; reason }
    | Ok (content, bytes, truncated) ->
      Evidence_artifact
        { reference
        ; content
        ; bytes
        ; truncated
        ; content_sha256 = content_sha256 content
        }

let snapshot_submitted_evidence_item ~base_path ~worker reference =
  match strip_prefix ~prefix:artifact_reference_prefix reference with
  | Some relative_path ->
    inspect_producer_relative_artifact
      ~base_path
      ~worker
      ~reference
      relative_path
  | None ->
    (match strip_prefix ~prefix:note_reference_prefix reference with
     | Some note when not (String.equal (String.trim note) "") ->
       Evidence_note note
     | Some _ | None ->
       Evidence_artifact_unreadable
         { reference; reason = Evidence_invalid_reference })

let snapshot_submitted_evidence_json ~base_path ~worker references =
  `List
    (List.map
       (fun reference ->
         snapshot_submitted_evidence_item ~base_path ~worker reference
         |> submitted_evidence_item_to_yojson)
       references)

let inspect_submitted_evidence_for_authority ~base_path ~request_id ~task_id
    ~task_worker ~(authority : Masc_domain.completion_authority) =
  if not (Masc_domain.completion_authority_has_identity authority)
  then
    Evidence_unavailable
      { request_id; reason = Completion_authority_identity_missing }
  else
    match load_request_for_evidence base_path request_id with
    | Error reason -> Evidence_unavailable { request_id; reason }
    | Ok (request, snapshot) ->
      if
        String.equal request.task_id task_id
        && String.equal request.worker task_worker
      then Evidence_available { request; items = snapshot }
      else
        Evidence_unavailable
          { request_id
          ; reason = Request_scope_mismatch
          }
;;

let list_request_headers base_path =
  let surface = "verification" in
  let report_drop ~reason ~path ~detail =
    Safe_ops.report_persistence_read_drop
      ~on_drop:ignore
      ~surface
      ~reason
      ~path
      ~detail
  in
  let dir = verifications_dir base_path in
  if not (Sys.file_exists dir) then
    []
  else
    match Safe_ops.list_dir_safe dir with
    | Error detail ->
        report_drop
          ~reason:Safe_ops.persistence_read_drop_reason_list_dir_error
          ~path:dir ~detail;
        []
    | Ok files ->
        files
        |> List.filter (fun f -> Filename.check_suffix f ".json")
        |> List.filter_map (fun f ->
               let id = Filename.chop_suffix f ".json" in
               Safe_ops.result_to_option_logged
                 ~on_drop:(fun () -> ())
                 ~surface
                 ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
                 ~path:(Filename.concat dir f)
                 (load_request_header base_path id))
