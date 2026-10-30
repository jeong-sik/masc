module Store = Workspace_verification_store

type withheld_reason =
  | Not_image_format
  | Body_not_filed
  | Body_unreadable
  | Body_identity_mismatch of Store.binary_body_identity_mismatch
  | Over_delivery_ceiling of { bytes : int; ceiling : int }
  | Over_response_budget

type preview =
  | Inline of { body_base64 : string }
  | Withheld of withheld_reason

let withheld_fields = function
  | Not_image_format -> [ "reason", `String "not_image_format" ]
  | Body_not_filed -> [ "reason", `String "body_not_filed" ]
  | Body_unreadable -> [ "reason", `String "body_unreadable" ]
  | Body_identity_mismatch { expected_bytes; actual_bytes; expected_sha256; actual_sha256 } ->
    [ "reason", `String "body_identity_mismatch"
    ; "expected_bytes", `Int expected_bytes
    ; "actual_bytes", `Int actual_bytes
    ; "expected_sha256", `String expected_sha256
    ; "actual_sha256", `String actual_sha256
    ]
  | Over_delivery_ceiling { bytes; ceiling } ->
    [ "reason", `String "over_delivery_ceiling"
    ; "bytes", `Int bytes
    ; "ceiling", `Int ceiling
    ]
  | Over_response_budget -> [ "reason", `String "over_response_budget" ]
;;

let preview_to_yojson = function
  | Inline { body_base64 } ->
    `Assoc [ "state", `String "inline"; "body_base64", `String body_base64 ]
  | Withheld reason -> `Assoc (("state", `String "withheld") :: withheld_fields reason)
;;

(* Base64 writes every 3 bytes as 4 characters and pads the last group with
   one or two [=], so the raw size of a body is known exactly from its encoded
   text without decoding it a second time. *)
let base64_group_chars = 4
let base64_group_bytes = 3

let raw_bytes_of_base64 encoded =
  let length = String.length encoded in
  let padding =
    if String.ends_with ~suffix:"==" encoded then 2
    else if String.ends_with ~suffix:"=" encoded then 1
    else 0
  in
  (length / base64_group_chars * base64_group_bytes) - padding
;;

(* One binary item's preview, given how much of the response budget is left.
   The order of the checks is the order of the causes an operator can act on:
   a format that never shows, a body that is too large, a body that is not
   there, and only then the budget, so a missing body is not reported as a
   full response. *)
let preview_of_binary ~base_path ~remaining item ~format ~bytes =
  match Store.image_media_type_of_binary_format format with
  | None -> Withheld Not_image_format
  | Some _media_type ->
    let ceiling = Store.verification_evidence_max_bytes in
    if bytes > ceiling
    then Withheld (Over_delivery_ceiling { bytes; ceiling })
    else (
      match Store.read_binary_body_base64 ~base_path item with
      | Error Store.Not_binary -> Withheld Not_image_format
      | Error Store.Body_not_filed -> Withheld Body_not_filed
      | Error (Store.Body_unreadable _) -> Withheld Body_unreadable
      | Error (Store.Body_identity_mismatch mismatch) -> Withheld (Body_identity_mismatch mismatch)
      | Error (Store.Over_delivery_ceiling { bytes; ceiling }) ->
        Withheld (Over_delivery_ceiling { bytes; ceiling })
      | Ok body_base64 ->
        if raw_bytes_of_base64 body_base64 > remaining
        then Withheld Over_response_budget
        else Inline { body_base64 })
;;

let previewed ~base_path items =
  let _remaining, rev =
    List.fold_left
      (fun (remaining, acc) (item : Store.submitted_evidence_item) ->
         match item with
         | Store.Evidence_artifact_binary { format; bytes; _ } ->
           let preview = preview_of_binary ~base_path ~remaining item ~format ~bytes in
           let remaining =
             match preview with
             | Inline { body_base64; _ } -> remaining - raw_bytes_of_base64 body_base64
             | Withheld _ -> remaining
           in
           remaining, (item, Some preview) :: acc
         | Store.Evidence_collaboration _
         | Store.Evidence_note _
         | Store.Evidence_artifact _
         | Store.Evidence_invalid_reference
         | Store.Evidence_artifact_unreadable _ -> remaining, (item, None) :: acc)
      (Tool_shard_limits.verification_operator_preview_budget_bytes, [])
      items
  in
  List.rev rev
;;

let previews ~base_path items = List.map snd (previewed ~base_path items)

let item_to_yojson (item, preview) =
  let persisted = Store.submitted_evidence_item_fields item in
  match preview with
  | Some preview -> `Assoc (persisted @ [ "preview", preview_to_yojson preview ])
  | None -> `Assoc persisted
;;

let access_to_yojson ~base_path = function
  | Store.Evidence_available { request; items } ->
    `Assoc
      [ "access", `String "available"
      ; "request", Store.request_header_to_yojson request
      ; "items", `List (List.map item_to_yojson (previewed ~base_path items))
      ]
  | Store.Evidence_unavailable _ as access -> Store.submitted_evidence_access_to_yojson access
;;

let file_to_yojson ~base_path ~index = function
  | Store.Evidence_unavailable _ -> Error "The retained evidence is unavailable"
  | Store.Evidence_available { request; items } ->
    let open Result.Syntax in
    let text ~name content =
      Ok (name, Base64.encode_string content, String.length content,
        Agent_core_sha256.(to_hex (digest_string content))) in
    let artifact_name reference =
      match Store.classify_evidence_reference reference with
      | Store.Artifact_reference relative when Store.valid_producer_relative_path relative ->
        Ok (Filename.basename relative)
      | Store.Artifact_reference _ | Store.Note_reference _
      | Store.Collaboration_reference _ | Store.Unresolvable_reference ->
        Error "The artifact does not name a valid producer-relative file" in
    let* name, body_base64, bytes, sha256 =
      match if index < 0 then None else List.nth_opt items index with
      | None -> Error "The selected evidence item does not exist"
      | Some (Store.Evidence_note content) -> text ~name:"note.txt" content
      | Some (Store.Evidence_collaboration { content; sha256; _ }) ->
        if not (String.equal sha256 Agent_core_sha256.(to_hex (digest_string content)))
        then Error "The collaboration snapshot does not match its submitted SHA-256"
        else text ~name:"source.json" content
      | Some (Store.Evidence_artifact { truncated = true; _ }) ->
        Error "Only a truncated text snapshot was retained; a complete file cannot be exported"
      | Some (Store.Evidence_artifact { reference; content; bytes; _ }) ->
        if String.length content <> bytes then Error "The text snapshot does not contain the complete recorded file"
        else let* name = artifact_name reference in text ~name content
      | Some (Store.Evidence_artifact_binary { reference; bytes; sha256; _ } as item) ->
        let* name = artifact_name reference in
        (match Store.read_binary_body_for_operator_base64 ~base_path item with
         | Ok body -> Ok (name, body, bytes, sha256)
         | Error Store.Not_binary -> Error "The evidence is not a binary file"
         | Error Store.Body_not_filed -> Error "No copy of this file was retained"
         | Error (Store.Body_unreadable detail) -> Error ("The retained file cannot be read: " ^ detail)
         | Error (Store.Body_identity_mismatch _) -> Error "The retained file does not match its submitted size or SHA-256"
         | Error (Store.Over_delivery_ceiling { bytes; ceiling }) ->
           Error (Printf.sprintf "This file is %d bytes; the delivery ceiling is %d bytes" bytes ceiling))
      | Some Store.Evidence_invalid_reference -> Error "The submitted reference is invalid"
      | Some (Store.Evidence_artifact_unreadable _) -> Error "No readable file snapshot was retained"
    in
    Ok (`Assoc [ "task_id", `String request.task_id;
      "verification_id", `String request.id; "item_index", `Int index;
      "name", `String name; "body_base64", `String body_base64;
      "bytes", `Int bytes; "sha256", `String sha256 ])
