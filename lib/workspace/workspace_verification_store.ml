include Workspace_verification_snapshot

type artifact_payload =
  | Text_payload of string * int * bool
      (** [(content, bytes, truncated)] — [bytes] may exceed the content
          length when the read was capped. *)
  | Binary_payload of
      { data : string  (** the raw bytes as read; the store persists them as the evidence body *)
      ; bytes : int  (** the byte count, measured on the original *)
      ; sha256 : string
      ; format : string  (** derived from the reference's extension; "unknown" when bare *)
      }

type artifact_read_result = (artifact_payload, evidence_read_failure) result

let project_root_of_base_path base_path =
  if Filename.basename base_path = Common.masc_dirname then
    Filename.dirname base_path
  else
    base_path

let active_verifications_dir base_path =
  let base_path = project_root_of_base_path base_path in
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "verifications"

let verifications_dir base_path =
  active_verifications_dir base_path

let request_path base_path req_id =
  Filename.concat (verifications_dir base_path) (req_id ^ ".json")

let load_request_for_evidence base_path req_id =
  let path = request_path base_path req_id in
  if req_id="" || req_id<>String.trim req_id || Filename.basename req_id<>req_id then
    Error Request_scope_mismatch
  else if not (Sys.file_exists path) then
    Error Request_not_found
  else
    try
      let json = Safe_ops.read_json_eio path in
      match request_header_of_yojson json with
      | Error detail -> Error (Request_header_invalid detail)
      | Ok request when request.id<>req_id -> Error Request_scope_mismatch
      | Ok request ->
        (match submitted_evidence_snapshot_of_request_json json with
         | Error detail -> Error (Evidence_snapshot_invalid detail)
         | Ok snapshot -> Ok (request, snapshot))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Error (Request_load_error (Printexc.to_string exn))

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
  | Owned_path_owner_mismatch _ -> Evidence_read_error "file ownership does not match requested UID"
  | Owned_path_writable_by_others _ -> Evidence_read_error "file parent is writable by other users"
  | Filesystem_identity_changed _ ->
    Evidence_changed_during_read
  | Owned_file_operation_failed { cause; _ } ->
    Evidence_read_error (Printexc.to_string cause)

let binary_format_of_path path =
  let extension = String.lowercase_ascii (Filename.extension path) in
  if extension = "" then "unknown"
  else String.sub extension 1 (String.length extension - 1)

let image_media_type_of_binary_format = function
  | "png" -> Some "image/png"
  | "jpeg" | "jpg" -> Some "image/jpeg"
  | "gif" -> Some "image/gif"
  | "webp" -> Some "image/webp"
  | _ -> None

let payload_of_complete_bytes ~path content =
  let format = binary_format_of_path path in
  let binary_format = match format with
    | "pdf" | "wav" | "mp3" | "ogg" | "flac" | "mp4" | "zip" -> true
    | _ -> Option.is_some (image_media_type_of_binary_format format) in
  match binary_format, scan_utf8 content with
  | true, (Utf8_valid | Utf8_incomplete_at _ | Utf8_invalid) ->
    Ok (Binary_payload {data=content; bytes=String.length content; format;
      sha256=Digestif.SHA256.(digest_string content |> to_hex)})
  | false, Utf8_valid ->
    let bytes = String.length content in
    let truncated = bytes > verification_evidence_max_bytes in
    let preview = if truncated then String.sub content 0 verification_evidence_max_bytes else content in
    let preview = match scan_utf8 preview with
      | Utf8_incomplete_at index -> String.sub preview 0 index
      | Utf8_valid | Utf8_invalid -> preview in
    Ok (Text_payload (preview, bytes, truncated))
  | false, (Utf8_incomplete_at _ | Utf8_invalid) -> Error Evidence_invalid_utf8

let read_regular_file_prefix ~ownership_root path =
  match Fs_compat.load_owned_regular_file ~ownership_root path with
  | Error error -> Error (evidence_read_failure_of_owned_read_failure error.failure)
  | Ok None -> Error Evidence_missing
  | Ok (Some content) -> payload_of_complete_bytes ~path content

let artifact_reference_prefix = "artifact:"

let strip_prefix ~prefix value =
  if String.starts_with ~prefix value
  then
    Some
      (String.sub
         value
         (String.length prefix)
         (String.length value - String.length prefix))
  else None

(* The shared reference grammar. Artifact/note capture lives here;
   collaboration capture lives above Workspace so Board/Fusion dependencies
   do not form a cycle. Both persist the same closed evidence-item type. *)
type reference_form =
  | Artifact_reference of string
  | Note_reference of string
  | Collaboration_reference of collaboration_kind * string
  | Unresolvable_reference

let classify_evidence_reference reference =
  match collaboration_reference reference with
  | Some (kind, id) -> Collaboration_reference (kind, id)
  | None -> match strip_prefix ~prefix:artifact_reference_prefix reference with
  | Some relative_path -> Artifact_reference relative_path
  | None ->
    (match strip_prefix ~prefix:note_reference_prefix reference with
     | Some note when not (String.equal (String.trim note) "") ->
       Note_reference note
     | Some _ | None -> Unresolvable_reference)
;;

let artifact_reference_form =
  artifact_reference_prefix ^ "<producer-root-relative-path>"
;;

let note_reference_form = note_reference_prefix ^ "<text>"
let resolvable_reference_forms = [ artifact_reference_form; note_reference_form; "board:<post-id>"; "fusion:<run-id>" ]

let valid_producer_relative_path path =
  Filename.is_relative path
  && not (String.equal path "")
  && (String.split_on_char '/' path
      |> List.for_all (fun segment ->
        not
          (String.equal segment ""
           || String.equal segment "."
           || String.equal segment "..")))

(* A producer-relative artifact path resolves against the producer's sandbox
   root and nowhere else.

   A submitter often writes the path relative to the checkout it worked in
   ([lib/foo.ml] rather than [masc/lib/foo.ml]), and the direct concat then
   misses. This store used to guess the rest: it enumerated [repos/*] and
   accepted the read when exactly one entry held the file. That guess was
   wrong twice over. It hardcoded a [repos/] segment, which
   {!Keeper_playground_checkouts} exists to remove — a keeper puts its
   checkouts where it likes, and the ones at the top level were invisible to
   it. And where a keeper holds the same repository several times, the file
   sits in several checkouts with different content, so the arm that reads
   "exactly one match" is the arm that never fires for the layout that most
   needs it.

   Reading a file the submitter did not name is worse than not reading one:
   the judge receives content without knowing which checkout produced it.
   So the miss stays a typed [Evidence_artifact_unreadable] and travels to
   the judge, which holds Read/Grep on this same root and a [root_layout]
   naming every checkout under it. Resolving a checkout-relative path is the
   judge's call, and [verification.lookup.producer_tree] already tells it to
   make that call. *)

(* The reader is injected because where an artifact lives depends on the
   producer's sandbox profile, and that policy sits above this library: a
   Docker keeper's files sit on the host playground this code can reach, while
   a microvm/remote-ssh keeper's files sit inside the guest's work volume,
   which only the sandbox backend can read. Without a reader the direct host
   read stands (tests, host-profile keepers); with one, every artifact read --
   snapshot and size pre-check alike -- goes through it, so the two can never
   disagree about where a file is. *)
let evidence_body_directory = "evidence"

(* Where a binary artifact's bytes are filed (RFC-0436 §4.2): the
   verification-owned evidence directory, one file per item index. The path
   recorded on the item is spelled relative to the workspace's masc
   directory so the judge's side resolves it under any base_path. Returns
   [None] when no request id was given -- the hash still stands, the body
   is simply not filed. *)
let persist_binary_body ~base_path ?request_id ?index data =
  match (request_id, index) with
  | Some request_id, Some index ->
    let masc_dir = Common.masc_dir_from_base_path ~base_path in
    let dir = Filename.concat (Filename.concat masc_dir evidence_body_directory) request_id in
    Fs_compat.mkdir_p dir;
    let file = Printf.sprintf "%d.bin" index in
    Fs_compat.save_file (Filename.concat dir file) data;
    Some (Filename.concat (Filename.concat evidence_body_directory request_id) file)
  | _ -> None

(* Why a filed body did not come back as base64. Each case is a different
   posture for the judge (RFC-0436 §4.4/§4.5): the item was never an image
   block candidate, the body was never filed (decoded from persistence, not
   captured), the file is gone or unreadable, or the body is above the
   delivery ceiling and is judged on its recorded hash and size. A caller
   that reads only a string cannot tell these apart, so the sum is closed
   and carries the numbers the ceiling case is decided on. *)
type read_binary_error =
  | Not_binary
  | Body_not_filed
  | Body_unreadable of string
  | Over_delivery_ceiling of { bytes : int; ceiling : int }

(* Read the request-owned body back as base64, including after the snapshot
   was decoded from persistence. Missing bodies and bodies above the capture
   ceiling are not delivered as images; their recorded references remain in
   the review evidence. The runtime still owns model capability selection. *)
(* The shape [persist_binary_body] writes: evidence/<request id>/<n>.bin. The
   persisted snapshot is a JSON document anyone with write access to the store
   can change, and the operator route sends a body's bytes to its caller, so a
   path of any other shape is refused rather than joined to the data
   directory. *)
let filed_body_path relative =
  let is_plain_segment segment =
    not (String.equal segment "")
    && not (String.equal segment ".")
    && not (String.equal segment "..")
    && not (String.contains segment '\\')
    && not (String.contains segment '\000')
  in
  match String.split_on_char '/' relative with
  | [ directory; request_id; file ]
    when String.equal directory evidence_body_directory
         && is_plain_segment request_id
         && is_plain_segment file
         && String.ends_with ~suffix:".bin" file -> true
  | _ -> false

let read_binary_body_base64 ~base_path (item : submitted_evidence_item) =
  match item with
  | Evidence_artifact_binary { body = Some relative; _ } ->
    if not (filed_body_path relative)
    then Error (Body_unreadable "body path is not under the evidence directory")
    else
    let path =
      Filename.concat
        (Common.masc_dir_from_base_path ~base_path)
        relative
    in
    (try
       let on_disk = (Unix.stat path).Unix.st_size in
       if on_disk > verification_evidence_max_bytes
       then
         Error
           (Over_delivery_ceiling
              { bytes = on_disk; ceiling = verification_evidence_max_bytes })
       else
         let data = Fs_compat.load_file path in
         let bytes = String.length data in
         if bytes > verification_evidence_max_bytes
         then
           Error
             (Over_delivery_ceiling
                { bytes; ceiling = verification_evidence_max_bytes })
         else Ok (Base64.encode_string data)
     with
     | Sys_error reason -> Error (Body_unreadable reason)
     | Unix.Unix_error (code, _, _) -> Error (Body_unreadable (Unix.error_message code)))
  | Evidence_artifact_binary { body = None; _ } -> Error Body_not_filed
  | Evidence_collaboration _ -> Error Not_binary
  | Evidence_note _ -> Error Not_binary
  | Evidence_artifact _ -> Error Not_binary
  | Evidence_invalid_reference -> Error Not_binary
  | Evidence_artifact_unreadable _ -> Error Not_binary

let inspect_producer_relative_artifact ?artifact_read ?request_id ?index ~base_path
    ~worker ~reference relative_path =
  if not (valid_producer_relative_path relative_path)
  then Evidence_invalid_reference
  else
    match artifact_read with
    | Some read -> (
        match read ~worker ~relative:relative_path with
        | Error reason -> Evidence_artifact_unreadable { reference; reason }
        | Ok (Binary_payload { data; bytes; sha256; format }) ->
            (* Bytes that are not text are evidence too: the snapshot keeps
               the hash and the size, and the bytes are filed as the body
               (RFC-0436 §4.1). *)
            let body =
              persist_binary_body ~base_path ?request_id ?index data
            in
            Evidence_artifact_binary { reference; bytes; sha256; format; body }
        | Ok (Text_payload (content, bytes, truncated)) -> (
            (* An artifact is text evidence, and the direct host read holds
               that line with [scan_utf8]; an injected reader hands back bytes
               from another lane (a guest [cat]), so the same scan holds the
               line here too: every reader answers under one boundary, and a
               truncated read may stop mid-character the way the direct
               prefix can. *)
            match scan_utf8 content with
            | Utf8_valid ->
              Evidence_artifact { reference; content; bytes; truncated }
            | Utf8_incomplete_at at when truncated ->
              Evidence_artifact
                { reference
                ; content = String.sub content 0 at
                ; bytes
                ; truncated = true
                }
            | Utf8_incomplete_at _ | Utf8_invalid ->
              Evidence_artifact_unreadable
                { reference; reason = Evidence_invalid_utf8 }))
    | None -> (
    let project_root = project_root_of_base_path base_path in
    let ownership_root =
      Keeper_sandbox_config.host_root_abs_of_producer
        ~base_path:project_root
        ~agent_name:worker
      |> Env_config_core.strip_trailing_slashes
    in
    let target = Filename.concat ownership_root relative_path in
    match read_regular_file_prefix ~ownership_root target with
    | Ok (Text_payload (content, bytes, truncated)) ->
      Evidence_artifact { reference; content; bytes; truncated }
    | Ok (Binary_payload { data; bytes; sha256; format }) ->
      let body = persist_binary_body ~base_path ?request_id ?index data in
      Evidence_artifact_binary { reference; bytes; sha256; format; body }
    | Error (Evidence_missing as reason)
    | Error (Evidence_not_regular_file as reason)
    | Error (Evidence_outside_worker_playground as reason)
    | Error (Evidence_invalid_utf8 as reason)
    | Error (Evidence_symbolic_link as reason)
    | Error (Evidence_changed_during_read as reason)
    | Error (Evidence_read_error _ as reason) ->
      Evidence_artifact_unreadable { reference; reason } )

let snapshot_submitted_evidence_item ?artifact_read ?request_id ?index ~base_path
    ~worker reference =
  match classify_evidence_reference reference with
  | Artifact_reference relative_path ->
    inspect_producer_relative_artifact
      ?artifact_read
      ?request_id
      ?index
      ~base_path
      ~worker
      ~reference
      relative_path
  | Note_reference note -> Evidence_note note
  | Collaboration_reference _ | Unresolvable_reference -> Evidence_invalid_reference

let snapshot_submitted_evidence_json ?artifact_read ?request_id ~base_path ~worker
    references =
  `List
    (List.mapi
       (fun index reference ->
         snapshot_submitted_evidence_item
           ?artifact_read
           ?request_id
           ~index
           ~base_path
           ~worker
           reference
         |> submitted_evidence_item_to_yojson)
       references)


let submission_receipt ~base_path ~request_id ~task_id ~worker =
  let open Result.Syntax in
  let* request, items = load_request_for_evidence base_path request_id in
  if not (String.equal request.id request_id
          && String.equal request.task_id task_id
          && String.equal request.worker worker)
  then Error Request_scope_mismatch
  else
    let diagnostics = List.filter_map (function
      | (Evidence_artifact_unreadable _ | Evidence_invalid_reference) as item ->
        Some (submitted_evidence_item_to_yojson item)
      | Evidence_artifact { reference; bytes; truncated = true; _ } ->
        Some (`Assoc ["kind", `String "artifact_truncated";
          "reference", `String reference; "bytes", `Int bytes])
      | Evidence_artifact { truncated = false; _ }
      | Evidence_artifact_binary _ | Evidence_note _ | Evidence_collaboration _ -> None)
      items in
    Ok (`Assoc ["verification_id", `String request_id;
      "diagnostics", `List diagnostics])
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

let inspect_submitted_evidence_for_operator ~base_path ~request_id ~task_id ~operator_id =
  let authority=Masc_domain.Human_operator {operator_id} in
  if not (Masc_domain.completion_authority_has_identity authority) then
    Evidence_unavailable {request_id;reason=Completion_authority_identity_missing}
  else match load_request_for_evidence base_path request_id with
    | Error reason -> Evidence_unavailable {request_id;reason}
    | Ok (request,items) when request.task_id=task_id -> Evidence_available {request;items}
    | Ok _ -> Evidence_unavailable {request_id;reason=Request_scope_mismatch}
