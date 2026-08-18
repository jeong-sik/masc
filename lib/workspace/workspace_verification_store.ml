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
  | Evidence_invalid_utf8
  | Evidence_symbolic_link
  | Evidence_changed_during_read
  | Evidence_read_error of string

type pull_request_locator =
  { owner : string
  ; repo : string
  ; number : int
  }

type pull_request_snapshot =
  { url : string
  ; state : string
  ; merged : bool
  ; draft : bool
  ; head_sha : string
  ; title : string
  ; diff : string
  ; diff_bytes : int
  ; diff_truncated : bool
  }

type pull_request_fetch_failure =
  | Pull_request_inspector_uninstalled
  | Pull_request_transport of string
  | Pull_request_http_status of int
  | Pull_request_payload_invalid of string

type submitted_evidence_item =
  | Evidence_note of string
  | Evidence_artifact of
      { reference : string
      ; content : string
      ; bytes : int
      ; truncated : bool
      }
  | Evidence_invalid_reference
  | Evidence_artifact_unreadable of
      { reference : string
      ; reason : evidence_read_failure
      }
  | Evidence_pull_request of
      { reference : string
      ; snapshot : pull_request_snapshot
      }
  | Evidence_pull_request_unreadable of
      { reference : string
      ; reason : pull_request_fetch_failure
      }

(* The forge reader is installed by the composition root at startup; this
   store stays free of transport dependencies (masc#28989). Stdlib mutex:
   installation happens during bootstrap and reads are non-yielding. *)
let pull_request_inspector :
  (pull_request_locator ->
   (pull_request_snapshot, pull_request_fetch_failure) result)
    option
    Atomic.t
  =
  Atomic.make None

let install_pull_request_inspector inspector =
  Atomic.set pull_request_inspector (Some inspector)

let inspect_pull_request locator =
  match Atomic.get pull_request_inspector with
  | None -> Error Pull_request_inspector_uninstalled
  | Some inspector -> inspector locator

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

(* Reason code for a reference this module refused to materialize. Unlike the
   [evidence_read_failure] codes it sits beside on the wire, it has no variant:
   the rejected reference is never persisted, so there is nothing to carry. *)
let invalid_reference_code = "invalid_reference"

let evidence_read_failure_code = function
  | Evidence_missing -> "missing"
  | Evidence_not_regular_file -> "not_regular_file"
  | Evidence_outside_worker_playground -> "outside_worker_playground"
  | Evidence_invalid_utf8 -> "invalid_utf8"
  | Evidence_symbolic_link -> "symbolic_link"
  | Evidence_changed_during_read -> "changed_during_read"
  | Evidence_read_error _ -> "read_error"

let evidence_read_failure_to_yojson reason =
  match reason with
  | Evidence_read_error detail ->
    `Assoc [ "code", `String "read_error"; "detail", `String detail ]
  | ( Evidence_missing
    | Evidence_not_regular_file
    | Evidence_outside_worker_playground
    | Evidence_invalid_utf8
    | Evidence_symbolic_link
    | Evidence_changed_during_read ) ->
    `Assoc [ "code", `String (evidence_read_failure_code reason) ]

let evidence_read_failure_of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "code", `String "missing" ] -> Ok Evidence_missing
     | [ "code", `String "not_regular_file" ] -> Ok Evidence_not_regular_file
     | [ "code", `String "outside_worker_playground" ] ->
       Ok Evidence_outside_worker_playground
     | [ "code", `String "invalid_utf8" ] -> Ok Evidence_invalid_utf8
     | [ "code", `String "symbolic_link" ] -> Ok Evidence_symbolic_link
     | [ "code", `String "changed_during_read" ] -> Ok Evidence_changed_during_read
     | [ "code", `String "read_error"; "detail", `String detail ] ->
       Ok (Evidence_read_error detail)
     | _ -> Error "submitted evidence snapshot has an invalid unreadable reason")
  | _ -> Error "submitted evidence snapshot unreadable reason must be an object"

let pull_request_fetch_failure_code = function
  | Pull_request_inspector_uninstalled -> "inspector_uninstalled"
  | Pull_request_transport _ -> "transport"
  | Pull_request_http_status _ -> "http_status"
  | Pull_request_payload_invalid _ -> "payload_invalid"

let pull_request_fetch_failure_to_yojson reason =
  match reason with
  | Pull_request_inspector_uninstalled ->
    `Assoc [ "code", `String "inspector_uninstalled" ]
  | Pull_request_transport detail ->
    `Assoc [ "code", `String "transport"; "detail", `String detail ]
  | Pull_request_http_status status ->
    `Assoc [ "code", `String "http_status"; "status", `Int status ]
  | Pull_request_payload_invalid detail ->
    `Assoc [ "code", `String "payload_invalid"; "detail", `String detail ]

let pull_request_fetch_failure_of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "code", `String "inspector_uninstalled" ] ->
       Ok Pull_request_inspector_uninstalled
     | [ "code", `String "transport"; "detail", `String detail ] ->
       Ok (Pull_request_transport detail)
     | [ "code", `String "http_status"; "status", `Int status ] ->
       Ok (Pull_request_http_status status)
     | [ "code", `String "payload_invalid"; "detail", `String detail ] ->
       Ok (Pull_request_payload_invalid detail)
     | _ ->
       Error "submitted evidence snapshot has an invalid pull-request reason")
  | _ ->
    Error "submitted evidence snapshot pull-request reason must be an object"

let pull_request_snapshot_to_yojson (snapshot : pull_request_snapshot) =
  `Assoc
    [ "url", `String snapshot.url
    ; "state", `String snapshot.state
    ; "merged", `Bool snapshot.merged
    ; "draft", `Bool snapshot.draft
    ; "head_sha", `String snapshot.head_sha
    ; "title", `String snapshot.title
    ; "diff", `String snapshot.diff
    ; "diff_bytes", `Int snapshot.diff_bytes
    ; "diff_truncated", `Bool snapshot.diff_truncated
    ]

let submitted_evidence_item_to_yojson = function
  | Evidence_note note ->
    `Assoc [ "kind", `String "note"; "content", `String note ]
  | Evidence_artifact { reference; content; bytes; truncated } ->
    `Assoc
      [ "kind", `String "artifact"
      ; "reference", `String reference
      ; "content", `String content
      ; "bytes", `Int bytes
      ; "truncated", `Bool truncated
      ]
  | Evidence_invalid_reference ->
    `Assoc
      [ "kind", `String "artifact_unreadable"
      ; "reason", `Assoc [ "code", `String invalid_reference_code ]
      ]
  | Evidence_artifact_unreadable { reference; reason } ->
    `Assoc
      [ "kind", `String "artifact_unreadable"
      ; "reference", `String reference
      ; "reason", evidence_read_failure_to_yojson reason
      ]
  | Evidence_pull_request { reference; snapshot } ->
    `Assoc
      [ "kind", `String "pull_request"
      ; "reference", `String reference
      ; "snapshot", pull_request_snapshot_to_yojson snapshot
      ]
  | Evidence_pull_request_unreadable { reference; reason } ->
    `Assoc
      [ "kind", `String "pull_request_unreadable"
      ; "reference", `String reference
      ; "reason", pull_request_fetch_failure_to_yojson reason
      ]

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
    `Assoc [ "kind", `String "note"; "bytes", `Int (String.length note) ]
  | Evidence_artifact { reference; bytes; truncated; _ } ->
    `Assoc
      [ "kind", `String "artifact"
      ; "reference", `String reference
      ; "bytes", `Int bytes
      ; "truncated", `Bool truncated
      ]
  | Evidence_invalid_reference ->
    `Assoc
      [ "kind", `String "artifact_unreadable"
      ; "reason", `String invalid_reference_code
      ]
  | Evidence_artifact_unreadable { reference; reason } ->
    `Assoc
      [ "kind", `String "artifact_unreadable"
      ; "reference", `String reference
      ; "reason", `String (evidence_read_failure_code reason)
      ]
  | Evidence_pull_request { reference; snapshot } ->
    `Assoc
      [ "kind", `String "pull_request"
      ; "reference", `String reference
      ; "state", `String snapshot.state
      ; "merged", `Bool snapshot.merged
      ; "head_sha", `String snapshot.head_sha
      ; "diff_bytes", `Int snapshot.diff_bytes
      ; "diff_truncated", `Bool snapshot.diff_truncated
      ]
  | Evidence_pull_request_unreadable { reference; reason } ->
    `Assoc
      [ "kind", `String "pull_request_unreadable"
      ; "reference", `String reference
      ; "reason", `String (pull_request_fetch_failure_code reason)
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
       let open Result.Syntax in
       let* () =
         Json_util.reject_unknown_fields
           ~surface:"submitted evidence note"
           ~allowed:[ "kind"; "content" ]
           fields
       in
       Result.map (fun note -> Evidence_note note) (string_field "content")
     | Some (`String "artifact") ->
       let open Result.Syntax in
       let* () =
         Json_util.reject_unknown_fields
           ~surface:"submitted evidence artifact"
           ~allowed:[ "kind"; "reference"; "content"; "bytes"; "truncated" ]
           fields
       in
       let* reference = string_field "reference" in
       let* content = string_field "content" in
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
       Ok (Evidence_artifact { reference; content; bytes; truncated })
     | Some (`String "artifact_unreadable") ->
       let open Result.Syntax in
       let field_names =
         fields |> List.map fst |> List.sort String.compare
       in
       let* reason_json =
         match List.assoc_opt "reason" fields with
         | Some reason -> Ok reason
         | None -> Error "submitted evidence snapshot is missing unreadable reason"
       in
       (match reason_json, List.assoc_opt "reference" fields, field_names with
        | ( `Assoc [ "code", `String "invalid_reference" ]
          , None
          , [ "kind"; "reason" ] ) ->
          Ok Evidence_invalid_reference
        | `Assoc [ "code", `String "invalid_reference" ], Some _, _ ->
          Error "invalid submitted evidence references must not persist the rejected value"
        | `Assoc [ "code", `String "invalid_reference" ], None, _ ->
          Error
            "invalid submitted evidence references must be payload-free"
        | reason_json, _, [ "kind"; "reason"; "reference" ] ->
          let* reason = evidence_read_failure_of_yojson reason_json in
          let* reference = string_field "reference" in
          Ok (Evidence_artifact_unreadable { reference; reason })
        | _, _, _ ->
          Error
            "submitted evidence unreadable item has unexpected fields")
     | Some (`String "pull_request") ->
       let open Result.Syntax in
       let* () =
         Json_util.reject_unknown_fields
           ~surface:"submitted evidence pull request"
           ~allowed:[ "kind"; "reference"; "snapshot" ]
           fields
       in
       let* reference = string_field "reference" in
       let* snapshot_fields =
         match List.assoc_opt "snapshot" fields with
         | Some (`Assoc snapshot_fields) -> Ok snapshot_fields
         | Some value ->
           Error
             (Printf.sprintf
                "submitted evidence pull-request snapshot must be an object, got %s"
                (Json_util.excerpt value))
         | None ->
           Error "submitted evidence snapshot is missing pull-request snapshot"
       in
       let snapshot_string key =
         match List.assoc_opt key snapshot_fields with
         | Some (`String value) -> Ok value
         | _ ->
           Error
             (Printf.sprintf
                "submitted evidence pull-request snapshot needs string %s"
                key)
       in
       let snapshot_bool key =
         match List.assoc_opt key snapshot_fields with
         | Some (`Bool value) -> Ok value
         | _ ->
           Error
             (Printf.sprintf
                "submitted evidence pull-request snapshot needs bool %s"
                key)
       in
       let* () =
         Json_util.reject_unknown_fields
           ~surface:"submitted evidence pull request snapshot"
           ~allowed:
             [ "url"; "state"; "merged"; "draft"; "head_sha"; "title"
             ; "diff"; "diff_bytes"; "diff_truncated" ]
           snapshot_fields
       in
       let* url = snapshot_string "url" in
       let* state = snapshot_string "state" in
       let* merged = snapshot_bool "merged" in
       let* draft = snapshot_bool "draft" in
       let* head_sha = snapshot_string "head_sha" in
       let* title = snapshot_string "title" in
       let* diff = snapshot_string "diff" in
       let* diff_bytes =
         match List.assoc_opt "diff_bytes" snapshot_fields with
         | Some (`Int value) when value >= 0 -> Ok value
         | _ ->
           Error
             "submitted evidence pull-request snapshot needs non-negative diff_bytes"
       in
       let* diff_truncated = snapshot_bool "diff_truncated" in
       Ok
         (Evidence_pull_request
            { reference
            ; snapshot =
                { url; state; merged; draft; head_sha; title
                ; diff; diff_bytes; diff_truncated }
            })
     | Some (`String "pull_request_unreadable") ->
       let open Result.Syntax in
       let* () =
         Json_util.reject_unknown_fields
           ~surface:"submitted evidence pull request unreadable"
           ~allowed:[ "kind"; "reference"; "reason" ]
           fields
       in
       let* reference = string_field "reference" in
       let* reason_json =
         match List.assoc_opt "reason" fields with
         | Some reason -> Ok reason
         | None ->
           Error "submitted evidence snapshot is missing pull-request reason"
       in
       let* reason = pull_request_fetch_failure_of_yojson reason_json in
       Ok (Evidence_pull_request_unreadable { reference; reason })
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
let pull_request_reference_prefix = "pull-request:"

let strip_prefix ~prefix value =
  if String.starts_with ~prefix value
  then
    Some
      (String.sub
         value
         (String.length prefix)
         (String.length value - String.length prefix))
  else None

let pull_request_url_prefix = "https://github.com/"

(* Parse, don't validate: the reference admits exactly
   [https://github.com/<owner>/<repo>/pull/<number>] and yields the typed
   locator. Anything else is Unresolvable at submit, so a malformed URL can
   never reach the forge reader. *)
let parse_pull_request_url url =
  match strip_prefix ~prefix:pull_request_url_prefix url with
  | None -> None
  | Some rest ->
    let segment_ok segment =
      not (String.equal segment "")
      && String.for_all
           (fun ch ->
             match ch with
             | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> true
             | _ -> false)
           segment
    in
    (match String.split_on_char '/' rest with
     | [ owner; repo; "pull"; number ]
       when segment_ok owner && segment_ok repo ->
       (match int_of_string_opt number with
        | Some n when n > 0 -> Some { owner; repo; number = n }
        | Some _ | None -> None)
     | _ -> None)

let pull_request_locator_url { owner; repo; number } =
  Printf.sprintf "%s%s/%s/pull/%d" pull_request_url_prefix owner repo number

(* The shape this store can read, decided without touching the filesystem.
   [snapshot_submitted_evidence_item] below is the only producer of evidence
   snapshots and answers [Evidence_invalid_reference] for anything else, so the
   submit boundaries ask this instead of restating the prefixes: a reference
   form added here reaches every caller, and one cannot be accepted at submit
   and then be unreadable at review. *)
type reference_form =
  | Artifact_reference of string
  | Note_reference of string
  | Pull_request_reference of pull_request_locator
  | Unresolvable_reference

let classify_evidence_reference reference =
  match strip_prefix ~prefix:artifact_reference_prefix reference with
  | Some relative_path -> Artifact_reference relative_path
  | None ->
    (match strip_prefix ~prefix:note_reference_prefix reference with
     | Some note when not (String.equal (String.trim note) "") ->
       Note_reference note
     | Some _ -> Unresolvable_reference
     | None ->
       (match strip_prefix ~prefix:pull_request_reference_prefix reference with
        | Some url ->
          (match parse_pull_request_url (String.trim url) with
           | Some locator -> Pull_request_reference locator
           | None -> Unresolvable_reference)
        | None -> Unresolvable_reference))
;;

let artifact_reference_form =
  artifact_reference_prefix ^ "<producer-root-relative-path>"
;;

let note_reference_form = note_reference_prefix ^ "<text>"

let pull_request_reference_form =
  pull_request_reference_prefix
  ^ pull_request_url_prefix
  ^ "<owner>/<repo>/pull/<number>"

let resolvable_reference_forms =
  [ artifact_reference_form; note_reference_form; pull_request_reference_form ]

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
  then Evidence_invalid_reference
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
      Evidence_artifact { reference; content; bytes; truncated }

let snapshot_submitted_evidence_item ~base_path ~worker reference =
  match classify_evidence_reference reference with
  | Artifact_reference relative_path ->
    inspect_producer_relative_artifact
      ~base_path
      ~worker
      ~reference
      relative_path
  | Note_reference note -> Evidence_note note
  | Pull_request_reference locator ->
    (match inspect_pull_request locator with
     | Ok snapshot -> Evidence_pull_request { reference; snapshot }
     | Error reason -> Evidence_pull_request_unreadable { reference; reason })
  | Unresolvable_reference -> Evidence_invalid_reference

let snapshot_submitted_evidence_json ~base_path ~worker references =
  `List
    (List.map
       (fun reference ->
         snapshot_submitted_evidence_item ~base_path ~worker reference
         |> submitted_evidence_item_to_yojson)
       references)

(* Decode through this module's own snapshot decoder instead of re-reading the
   JSON fields. Both surfaces read the same persisted bytes, so they have to
   agree on which snapshots are well-formed: re-deriving the shape here let an
   artifact item with a [reference] but missing or invalid [content]/[bytes]/
   [truncated] render as an ordinary identity line while the authority-scoped
   payload route rejected the very same item. Matching on the typed value makes
   that divergence unrepresentable, and a new variant becomes a compile error
   here rather than an [unknown kind] string at runtime. *)
let submitted_evidence_identity_line (item : Yojson.Safe.t) =
  match submitted_evidence_item_of_yojson item with
  | Error detail -> Error detail
  | Ok (Evidence_note note) -> Ok (note_reference_prefix ^ note)
  | Ok (Evidence_artifact { reference; _ }) -> Ok reference
  | Ok Evidence_invalid_reference ->
    Ok (Printf.sprintf "(unreadable: %s)" invalid_reference_code)
  | Ok (Evidence_artifact_unreadable { reference; reason }) ->
    Ok
      (Printf.sprintf
         "%s (unreadable: %s)"
         reference
         (evidence_read_failure_code reason))
  | Ok (Evidence_pull_request { reference; snapshot }) ->
    Ok
      (Printf.sprintf
         "%s (%s%s, head %s)"
         reference
         snapshot.state
         (if snapshot.merged then ", merged" else "")
         snapshot.head_sha)
  | Ok (Evidence_pull_request_unreadable { reference; reason }) ->
    Ok
      (Printf.sprintf
         "%s (unreadable: %s)"
         reference
         (pull_request_fetch_failure_code reason))
;;

let submitted_evidence_identity_lines (json : Yojson.Safe.t) =
  match json with
  | `List items ->
    List.fold_left
      (fun acc item ->
        match acc, submitted_evidence_identity_line item with
        | Error _, _ -> acc
        | Ok lines, Ok line -> Ok (line :: lines)
        | Ok _, Error detail -> Error detail)
      (Ok [])
      items
    |> Result.map List.rev
  | _ -> Error "submitted evidence must be an array"
;;

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
