(* Immutable snapshot values and projections; no acquisition or storage effects. *)
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

type collaboration_kind = Board_source | Fusion_source

type submitted_evidence_item =
  | Evidence_collaboration of { reference : string; content : string; sha256 : string }
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
  | Evidence_artifact_binary of
      { reference : string
      ; bytes : int
      ; sha256 : string
      ; format : string
      ; body : string option
      (* base_path-relative path of the persisted bytes; [None] when the
         caller gave no request to file the body under (RFC-0436 §4.2). *)
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

(* Reason code for a reference the store refused to materialize. Unlike the
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

let collaboration_reference reference =
  let parse prefix kind =
    if String.starts_with ~prefix reference then
      let id = String.sub reference (String.length prefix) (String.length reference - String.length prefix) in
      if id <> "" && String.trim id = id then Some (kind, id) else None
    else None in
  match parse "board:" Board_source with
  | Some _ as value -> value
  | None -> parse "fusion:" Fusion_source

let collaboration_metadata ~reference ~content ~sha256 =
  `Assoc ["kind", `String "collaboration"; "reference", `String reference;
    "sha256", `String sha256; "bytes", `Int (String.length content);
    "content_omitted", `Bool true]

let submitted_evidence_item_fields = function
  | Evidence_collaboration {reference; content; sha256} ->
    ["kind", `String "collaboration"; "reference", `String reference;
      "content", `String content; "sha256", `String sha256]
  | Evidence_note note ->
    [ "kind", `String "note"; "content", `String note ]
  | Evidence_artifact { reference; content; bytes; truncated } ->
    [ "kind", `String "artifact"
    ; "reference", `String reference
    ; "content", `String content
    ; "bytes", `Int bytes
    ; "truncated", `Bool truncated
    ]
  | Evidence_invalid_reference ->
    [ "kind", `String "artifact_unreadable"
    ; "reason", `Assoc [ "code", `String invalid_reference_code ]
    ]
  | Evidence_artifact_unreadable { reference; reason } ->
    [ "kind", `String "artifact_unreadable"
    ; "reference", `String reference
    ; "reason", evidence_read_failure_to_yojson reason
    ]
  | Evidence_artifact_binary { reference; bytes; sha256; format; body } ->
    [ "kind", `String "artifact_binary"
    ; "reference", `String reference
    ; "bytes", `Int bytes
    ; "sha256", `String sha256
    ; "format", `String format
    ]
    @ (match body with
       | Some path -> [ ("body", `String path) ]
       | None -> [])

let submitted_evidence_item_to_yojson item = `Assoc (submitted_evidence_item_fields item)

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

(* Bounded snapshot cap for producer-owned evidence artifacts. Raised from
   20_000 to 200_000 so contract artifacts in the observed 40-128KB range are
   persisted in full (truncated=false) instead of being marked unusable by the
   completion authority. The cap stays bounded to bound verifier memory and
   backlog storage.

   It is the Read ceiling, taken from the same value rather than written out
   again: the authority reads live through Read and the operator reviews the
   snapshot, so a Read allowed past this cap would let a verdict rest on bytes
   the snapshot does not hold (#27397). *)
let verification_evidence_max_bytes = Tool_shard_limits.verification_evidence_max_bytes

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

(* Judge-transport projection. The serializer above persists the truncated
   prefix so the audit record keeps what was readable at submission time. The
   review request must not carry it: the instructions already order the judge
   to treat [truncated=true] as unavailable evidence, so transmitting the
   prefix ships bytes the judgement cannot use — and one 22 MB artifact
   (200 KB prefix, listed under two references) inflated the review turn past
   every verifier_exact slot's input budget this way (#29615). The prefix
   stays in the store; the judge receives the size, the fact, and how to read
   the real file. *)
let submitted_evidence_item_transport_to_yojson = function
  | Evidence_collaboration {reference; content; sha256} ->
    collaboration_metadata ~reference ~content ~sha256
  | Evidence_note note ->
    `Assoc [ "kind", `String "note"; "content", `String note ]
  | Evidence_artifact { reference; content; bytes; truncated } ->
    if truncated
    then
      `Assoc
        [ "kind", `String "artifact"
        ; "reference", `String reference
        ; "bytes", `Int bytes
        ; "truncated", `Bool true
        ; "content_omitted", `Bool true
        ; ( "content_note"
          , `String
              (Printf.sprintf
                 "file is %d bytes; only a %d-byte prefix fits the evidence \
                  snapshot and that prefix is withheld from this request; \
                  treat the item as unavailable and read ranges of the actual \
                  file with the listed verification tools"
                 bytes
                 verification_evidence_max_bytes) )
        ]
    else
      `Assoc
        [ "kind", `String "artifact"
        ; "reference", `String reference
        ; "content", `String content
        ; "bytes", `Int bytes
        ; "truncated", `Bool false
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
  | Evidence_artifact_binary { reference; bytes; sha256; format; body } ->
    `Assoc
      ([ "kind", `String "artifact_binary"
       ; "reference", `String reference
       ; "bytes", `Int bytes
       ; "sha256", `String sha256
       ; "format", `String format
       ]
      @ (match body with
         | Some path -> [ ("body", `String path) ]
         | None -> []))
;;

(* The per-item cap above bounds one artifact. Nothing bounded their sum, so a
   submission of many sub-cap artifacts still built a request no slot could
   carry: 12 artifacts, every one [truncated=false], 204,834 bytes of content
   in one measured bundle and 1,005,015 in the atom that stalled task-465
   (2026-08-25). #29615 closed the single-22MB-artifact shape; this closes the
   many-small-artifacts shape behind it.

   The ceiling is the per-item cap itself rather than a new number. It bounds
   carried complete text-artifact content; notes and envelope metadata are
   outside this sum. A fit for every slot is not promised, because a slot's
   remaining budget also depends on the conversation in front of it — that is
   a routing concern and is not decided here. *)
let evidence_transport_max_bytes = verification_evidence_max_bytes

(* Withheld for the aggregate budget, not for its own size. The judge is given
   the same three things a per-item withholding gives it — the reference, the
   real size, and the instruction to read the file — so the shape it has to
   understand does not grow. *)
let submitted_evidence_item_withheld_to_yojson = function
  | Evidence_artifact { reference; content = _; bytes; truncated = _ } ->
    `Assoc
      [ "kind", `String "artifact"
      ; "reference", `String reference
      ; "bytes", `Int bytes
      ; "truncated", `Bool false
      ; "content_omitted", `Bool true
      ; ( "content_note"
        , `String
            (Printf.sprintf
               "file is %d bytes; the evidence block for this request is \
                capped at %d bytes and this item is past the cap, so its \
                content is withheld; read ranges of the actual file with the \
                listed verification tools"
               bytes
               evidence_transport_max_bytes) )
      ]
  | (Evidence_note _ | Evidence_invalid_reference | Evidence_artifact_unreadable _
    | Evidence_artifact_binary _
    | Evidence_collaboration _) as item ->
    (* Only a full-content artifact can be withheld for the aggregate budget;
       the rest carry no content to withhold. A binary item is already
       payload-free on the wire -- its bytes live in the evidence body. *)
    submitted_evidence_item_transport_to_yojson item
;;

(* Which artifacts keep their content, by index.

   What this buys is one thing: the same evidence set makes the same choice
   every run. Filling in submission order let one large-but-under-cap artifact
   spend the whole budget, and which items the judge saw then depended on the
   order the producer happened to list them in. Nothing declares that order —
   the contract does not ask for most-important-first, and the item type
   carries no priority — so it was incidental rather than intent.

   Smallest-first is the tiebreak, not the goal, and it is not an optimum.
   The contract requires support for every item and judges each one
   independently, so a budget that forces any drop already fails that item;
   which one is dropped changes who fails, not whether. Size is what is
   available to sort on, ties break on index, and the emitted list stays in
   submission order.

   A dropped item is not silent: it carries [content_omitted] and a note
   naming the cap and the tools that read the file directly. *)
let carried_artifact_indices items =
  let weighed =
    List.mapi (fun index item -> index, item) items
    |> List.filter_map (function
         | index, Evidence_artifact { content; truncated = false; _ } ->
           Some (index, String.length content)
         | ( _
           , ( Evidence_note _
             | Evidence_artifact _
             | Evidence_invalid_reference
             | Evidence_artifact_unreadable _
             | Evidence_artifact_binary _
             | Evidence_collaboration _ ) ) -> None)
  in
  let sorted =
    List.stable_sort
      (fun (index_a, weight_a) (index_b, weight_b) ->
        match Int.compare weight_a weight_b with
        | 0 -> Int.compare index_a index_b
        | order -> order)
      weighed
  in
  let carried, _ =
    List.fold_left
      (fun (carried, spent) (index, weight) ->
        if spent + weight > evidence_transport_max_bytes
        then carried, spent
        else index :: carried, spent + weight)
      ([], 0)
      sorted
  in
  carried
;;

let submitted_evidence_items_transport_to_yojson items =
  let carried = carried_artifact_indices items in
  List.mapi
    (fun index item ->
      match item with
      | Evidence_artifact { truncated = false; _ } ->
        if List.mem index carried
        then submitted_evidence_item_transport_to_yojson item
        else submitted_evidence_item_withheld_to_yojson item
      | Evidence_note _
      | Evidence_artifact _
      | Evidence_invalid_reference
      | Evidence_artifact_unreadable _
      | Evidence_artifact_binary _
      | Evidence_collaboration _ -> submitted_evidence_item_transport_to_yojson item)
    items
;;

let submitted_evidence_access_transport_to_yojson = function
  | Evidence_available { request; items } ->
    `Assoc
      [ "access", `String "available"
      ; "request", request_header_to_yojson request
      ; "items", `List (submitted_evidence_items_transport_to_yojson items)
      ]
  | Evidence_unavailable { request_id; reason } ->
    `Assoc
      [ "access", `String "unavailable"
      ; "request_id", `String request_id
      ; "reason", `String (evidence_access_failure_to_string ~request_id reason)
      ]
;;

let submitted_evidence_item_metadata_to_yojson = function
  | Evidence_collaboration {reference; content; sha256} ->
    collaboration_metadata ~reference ~content ~sha256
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
  | Evidence_artifact_binary { reference; bytes; sha256; format; body } ->
    `Assoc
      ([ "kind", `String "artifact_binary"
       ; "reference", `String reference
       ; "bytes", `Int bytes
       ; "sha256", `String sha256
       ; "format", `String format
       ]
      @ (match body with
         | Some path -> [ ("body", `String path) ]
         | None -> []))
;;

let submitted_evidence_access_metadata_to_yojson = function
  | Evidence_available { request; items } ->
    `Assoc
      [ "access", `String "available"
      ; "request_id", `String request.id
      ; "task_id", `String request.task_id
      ; "worker", `String request.worker
      ; "created_at", `Float request.created_at
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
     | Some (`String "collaboration") ->
       let* () = Json_util.reject_unknown_fields ~surface:"submitted collaboration"
         ~allowed:["kind";"reference";"content";"sha256"] fields in
       let* reference = string_field "reference" in
       let* content = string_field "content" in
       let* sha256 = string_field "sha256" in
       let* () = match collaboration_reference reference with
         | Some _ -> Ok () | None -> Error "invalid collaboration reference" in
       if not (String.equal sha256 Digestif.SHA256.(digest_string content |> to_hex)) then
         Error "submitted collaboration digest mismatch"
       else (match Yojson.Safe.from_string content with
         | `Assoc _ -> Ok (Evidence_collaboration {reference; content; sha256})
         | _ -> Error "submitted collaboration content must be an object"
         | exception Yojson.Json_error detail -> Error detail)
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
     | Some (`String "artifact_binary") ->
       let open Result.Syntax in
       let* () =
         Json_util.reject_unknown_fields
           ~surface:"submitted evidence binary artifact"
           ~allowed:[ "kind"; "reference"; "bytes"; "sha256"; "format"; "body" ]
           fields
       in
       let* reference = string_field "reference" in
       let* bytes =
         match List.assoc_opt "bytes" fields with
         | Some (`Int value) when value >= 0 -> Ok value
         | Some value ->
           Error
             (Printf.sprintf
                "submitted evidence binary artifact bytes must be a non-negative integer, got %s"
                (Json_util.excerpt value))
         | None -> Error "submitted evidence binary artifact is missing bytes"
       in
       let* sha256 = string_field "sha256" in
       let* format = string_field "format" in
       let* body =
         match List.assoc_opt "body" fields with
         | Some (`String path) -> Ok (Some path)
         | Some value ->
           Error
             (Printf.sprintf
                "submitted evidence binary artifact body must be a string, got %s"
                (Json_util.excerpt value))
         | None -> Ok None
       in
       Ok (Evidence_artifact_binary { reference; bytes; sha256; format; body })
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

let note_reference_prefix = "note:"

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
  | Ok (Evidence_collaboration {reference; _}) -> Ok reference
  | Ok (Evidence_note note) -> Ok (note_reference_prefix ^ note)
  | Ok (Evidence_artifact { reference; _ }) -> Ok reference
  | Ok Evidence_invalid_reference ->
    Ok (Printf.sprintf "(unreadable: %s)" invalid_reference_code)
  | Ok (Evidence_artifact_unreadable { reference; reason }) ->
    let diagnostic = match reason with
      | Evidence_read_error detail -> evidence_read_failure_code reason ^ ": " ^ detail
      | Evidence_missing | Evidence_not_regular_file
      | Evidence_outside_worker_playground | Evidence_invalid_utf8
      | Evidence_symbolic_link | Evidence_changed_during_read ->
        evidence_read_failure_code reason
    in
    Ok
      (Printf.sprintf
         "%s (unreadable: %s)"
         reference
         diagnostic)
  | Ok (Evidence_artifact_binary { reference; sha256; _ }) ->
    Ok
      (Printf.sprintf
         "%s (binary: %s)"
         reference
         (String.sub sha256 0 (min 12 (String.length sha256))))
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

(* Decoded through this module's own snapshot decoder for the same reason as
   the identity lines above: the typed value is the one truth about which
   items are truncated, so a shape change is a compile error here rather than
   a silently empty warning at the submit site. *)
let truncated_snapshot_items (json : Yojson.Safe.t) : (string * int) list =
  match json with
  | `List items ->
    List.filter_map
      (fun item ->
         match submitted_evidence_item_of_yojson item with
         | Ok (Evidence_artifact { reference; bytes; truncated = true; _ }) ->
           Some (reference, bytes)
         | Ok (Evidence_artifact { truncated = false; _ }) -> None
         | Ok (Evidence_collaboration _) -> None
         | Ok (Evidence_note _) -> None
         | Ok Evidence_invalid_reference -> None
         | Ok (Evidence_artifact_unreadable _) -> None
         | Ok (Evidence_artifact_binary _) -> None
         | Error _ -> None)
      items
  | _ -> []
;;
