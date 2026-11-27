type user_media_block = {
  attachment_id : string;
  name : string;
  mime_type : string;
  size : int option;
}

(* An image reference the provider resolves itself (#33728): an external URL
   passed through as the image_url, or a Files-API id minted by an upload tool.
   The server never fetches either; [value] rides the wire verbatim in the
   native form the serializers emit (#33669). [mime_type] is advisory — the
   openai chat surface does not carry it for a reference, the anthropic source
   object does. *)
type user_image_reference = {
  value : string;
  mime_type : string option;
}

(* The three carriers of a user image, mutually exclusive in the type so no
   downstream code re-checks field combinations: bytes this server already
   holds (an [attachments] entry), or one of the two reference forms. *)
type user_image_source =
  | Attached of user_media_block
  | Url_ref of user_image_reference
  | File_id_ref of user_image_reference

type user_input_block =
  | User_text of string
  | User_image of user_image_source
  | User_document of user_media_block
  | User_audio of user_media_block
  | User_attachment of user_media_block

let attachment_to_yojson (att : Keeper_chat_store.attachment) =
  `Assoc
    [ ("id", `String att.Keeper_chat_store.id);
      ("type", `String att.att_type);
      ("name", `String att.name);
      ("size", `Int att.size);
      ("mime_type", `String att.mime_type);
      ("data", `String att.data) ]

let attachments_to_yojson attachments =
  `List (List.map attachment_to_yojson attachments)

open Result.Syntax

let exact_object_fields ~field ~allowed = function
  | `Assoc fields ->
    let keys = List.map fst fields in
    if List.length keys <> List.length (List.sort_uniq String.compare keys)
    then Error (field ^ " must contain unique fields")
    else
      (match List.find_opt (fun key -> not (List.mem key allowed)) keys with
       | Some key ->
         Error
           (Printf.sprintf
              "%s.%s is undeclared; accepted fields: %s"
              field
              key
              (String.concat ", " allowed))
       | None -> Ok fields)
  | _ -> Error (field ^ " must be a JSON object")
;;

let required_string ~field key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" field key)
  | None -> Error (Printf.sprintf "%s.%s is required" field key)
;;

let optional_string ~field key fields =
  match List.assoc_opt key fields with
  | None -> Ok ""
  | Some (`String value) -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" field key)
;;

let optional_string_or_null ~field key fields =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok ""
  | Some (`String value) -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" field key)
;;

let optional_nonneg_int ~field key fields =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`Int n) when n >= 0 -> Ok (Some n)
  | Some (`Int _) -> Error (field ^ "." ^ key ^ " must be non-negative")
  | Some _ -> Error (field ^ "." ^ key ^ " must be an integer")
;;

let parse_attachment ~index json =
  let field = Printf.sprintf "attachments[%d]" index in
  let* fields =
    exact_object_fields
      ~field
      ~allowed:
        [ "id"
        ; "attachment_id"
        ; "type"
        ; "kind"
        ; "name"
        ; "filename"
        ; "size"
        ; "bytes"
        ; "mime_type"
        ; "data"
        ; "url"
        ; "width"
        ; "height"
        ; "sha256"
        ; "origin"
        ; "created_at_unix"
        ; "retention"
        ]
      json
  in
  let* id_raw = optional_string_or_null ~field "id" fields in
  let* att_id_raw = optional_string_or_null ~field "attachment_id" fields in
  let id =
    match String.trim id_raw, String.trim att_id_raw with
    | "", "" -> ""
    | v, "" -> v
    | "", v -> v
    | v, _ -> v
  in
  let* att_type_raw = optional_string_or_null ~field "type" fields in
  let* kind_raw = optional_string_or_null ~field "kind" fields in
  let att_type =
    match String.trim att_type_raw, String.trim kind_raw with
    | "", v -> v
    | v, _ -> v
  in
  let* name_raw = optional_string_or_null ~field "name" fields in
  let* filename_raw = optional_string_or_null ~field "filename" fields in
  let name =
    match String.trim name_raw, String.trim filename_raw with
    | "", v -> v
    | v, _ -> v
  in
  let* mime_type = optional_string_or_null ~field "mime_type" fields in
  let* data_raw = optional_string_or_null ~field "data" fields in
  let* url_raw = optional_string_or_null ~field "url" fields in
  let* size_opt = optional_nonneg_int ~field "size" fields in
  let* bytes_opt = optional_nonneg_int ~field "bytes" fields in
  let* width = optional_nonneg_int ~field "width" fields in
  let* height = optional_nonneg_int ~field "height" fields in
  let size =
    match size_opt, bytes_opt with
    | Some n, _ -> n
    | None, Some n -> n
    | None, None -> 0
  in
  let is_canonical_att_id = Result.is_ok (Attachment_store.parse_id id) in
  let data =
    if not (String.equal data_raw "")
    then data_raw
    else if is_canonical_att_id
    then
      if not (String.equal (String.trim url_raw) "")
      then String.trim url_raw
      else Attachment_store.url_of_id id
    else ""
  in
  if String.equal id "" then Error (field ^ ".id must be non-empty")
  else if String.equal data "" then Error (field ^ ".data must be non-empty")
  else
    Ok
      { Keeper_chat_store.id
      ; att_type
      ; name
      ; size
      ; mime_type = String.trim mime_type
      ; data
      ; width
      ; height
      }

(* Two attachments sharing an id both parse, but a user_blocks reference
   resolves through {!find_attachment}'s first match, so the second is
   silently shadowed -- the same silent-drop class as an unreferenced
   attachment ({!validate_attachment_references}). Reject the duplicate at
   the parse boundary, naming the id. *)
let reject_duplicate_attachment_ids (atts : Keeper_chat_store.attachment list) =
  let rec collect seen dups = function
    | [] -> List.rev dups
    | (att : Keeper_chat_store.attachment) :: rest ->
      if List.exists (String.equal att.id) dups
      then collect (att.id :: seen) dups rest
      else if List.exists (String.equal att.id) seen
      then collect (att.id :: seen) (att.id :: dups) rest
      else collect (att.id :: seen) dups rest
  in
  match collect [] [] atts with
  | [] -> Ok ()
  | first :: _ as dups ->
    Error
      (Printf.sprintf
         "duplicate attachment id %s: every attachment id must be unique; a user_blocks reference to %S would reach only one of them"
         (dups |> List.map (Printf.sprintf "%S") |> String.concat ", ")
         first)
;;

let parse_attachments json =
  match Json_util.assoc_member_opt "attachments" json with
  | None | Some `Null -> Ok []
  | Some (`List attachments) ->
    let rec loop index acc = function
      | [] -> Ok (List.rev acc)
      | attachment :: rest ->
        let* attachment = parse_attachment ~index attachment in
        loop (index + 1) (attachment :: acc) rest
    in
    let* parsed = loop 0 [] attachments in
    let* () = reject_duplicate_attachment_ids parsed in
    Ok parsed
  | Some _ -> Error "attachments must be an array"

let user_media_block_to_yojson kind (media : user_media_block) =
  let fields =
    [ ("type", `String kind);
      ("attachment_id", `String media.attachment_id);
      ("name", `String media.name);
      ("mime_type", `String media.mime_type) ]
  in
  let fields =
    match media.size with
    | Some size -> ("size", `Int size) :: fields
    | None -> fields
  in
  `Assoc (List.rev fields)

let user_image_reference_to_yojson ~key ref =
  let base = [ ("type", `String "image"); (key, `String ref.value) ] in
  match ref.mime_type with
  | None -> `Assoc base
  | Some mime_type -> `Assoc (("mime_type", `String mime_type) :: base)

let user_block_to_yojson = function
  | User_text text -> `Assoc [ ("type", `String "text"); ("text", `String text) ]
  | User_image (Attached media) -> user_media_block_to_yojson "image" media
  | User_image (Url_ref ref) -> user_image_reference_to_yojson ~key:"url" ref
  | User_image (File_id_ref ref) -> user_image_reference_to_yojson ~key:"file_id" ref
  | User_document media -> user_media_block_to_yojson "document" media
  | User_audio media -> user_media_block_to_yojson "audio" media
  | User_attachment media -> user_media_block_to_yojson "attachment" media

let user_blocks_to_yojson blocks =
  `List (List.map user_block_to_yojson blocks)

let media_block_allowed_fields =
  [ "type"
  ; "attachment_id"
  ; "id"
  ; "name"
  ; "filename"
  ; "mime_type"
  ; "size"
  ; "bytes"
  ; "kind"
  ; "url"
  ; "width"
  ; "height"
  ; "sha256"
  ; "origin"
  ; "created_at_unix"
  ; "retention"
  ]

let parse_user_media_block ~(kind : string) fields =
  let field = "user_blocks " ^ kind ^ " block" in
  let* att_id_raw = optional_string_or_null ~field "attachment_id" fields in
  let* id_raw = optional_string_or_null ~field "id" fields in
  let attachment_id =
    match String.trim att_id_raw, String.trim id_raw with
    | "", v -> v
    | v, _ -> v
  in
  let* name_raw = optional_string_or_null ~field "name" fields in
  let* filename_raw = optional_string_or_null ~field "filename" fields in
  let name =
    match String.trim name_raw, String.trim filename_raw with
    | "", v -> v
    | v, _ -> v
  in
  let* mime_type = optional_string_or_null ~field "mime_type" fields in
  let* size_opt = optional_nonneg_int ~field "size" fields in
  let* bytes_opt = optional_nonneg_int ~field "bytes" fields in
  let size =
    match size_opt, bytes_opt with
    | Some _ as s, _ -> s
    | None, s -> s
  in
  if attachment_id = "" then
    Error (Printf.sprintf "user_blocks %s block requires attachment_id" kind)
  else
    Ok
      { attachment_id
      ; name
      ; mime_type = String.trim mime_type
      ; size
      }

(* Shared body for the media block kinds. The constructor is chosen at the
   single point where the kind string is matched, so no arm can be
   unreachable and no wildcard can silently misclassify a new kind. *)
let parse_media_input_block json ~kind make =
  let* fields =
    exact_object_fields
      ~field:("user_blocks " ^ kind ^ " block")
      ~allowed:media_block_allowed_fields
      json
  in
  let* media = parse_user_media_block ~kind fields in
  Ok (make media)

(* The advisory media type a reference image may carry. Absent is fine — the
   chat surface puts nothing on the wire for a reference — so no guess is
   fabricated here; the agent-core block below names its own default. *)
let parse_user_image_reference ~(kind : string) ~value_key fields =
  let field = "user_blocks image " ^ kind ^ " block" in
  let* value = required_string ~field value_key fields in
  let* mime_type = optional_string ~field "mime_type" fields in
  let mime_type = String.trim mime_type in
  let value = String.trim value in
  if value = "" then
    Error (Printf.sprintf "user_blocks image block requires non-empty %s" value_key)
  else
    Ok
      { value
      ; mime_type = if mime_type = "" then None else Some mime_type
      }

(* An image block names exactly one carrier: [attachment_id] for bytes this
   server holds, [url] for an external location the provider fetches, or
   [file_id] for a Files-API reference an upload tool minted. Zero or more
   than one is a request error — the type above cannot hold either. *)
let parse_user_image_block json =
  let* base_fields =
    exact_object_fields
      ~field:"user_blocks image block"
      ~allowed:("file_id" :: media_block_allowed_fields)
      json
  in
  let has key = List.mem_assoc key base_fields in
  let has_attachment_id = has "attachment_id" || has "id" in
  let has_external_url =
    match List.assoc_opt "url" base_fields with
    | None -> false
    | Some (`String u)
      when has_attachment_id
           && String.starts_with ~prefix:Attachment_store.url_prefix (String.trim u) ->
      false
    | Some _ -> true
  in
  let present =
    (if has_attachment_id then [ "attachment_id" ] else [])
    @ (if has_external_url then [ "url" ] else [])
    @ (if has "file_id" then [ "file_id" ] else [])
  in
  match present with
  | [ "attachment_id" ] ->
    parse_media_input_block json ~kind:"image" (fun media -> User_image (Attached media))
  | [ "url" ] ->
    let* fields =
      exact_object_fields
        ~field:"user_blocks image url block"
        ~allowed:[ "type"; "url"; "mime_type" ]
        json
    in
    let* reference = parse_user_image_reference ~kind:"url" ~value_key:"url" fields in
    (* Scheme prefix plus a non-empty rest: the provider fetches the URL, and
       no other scheme names a fetchable image location. *)
    let scheme_rest =
      if String_util.starts_with_ci ~prefix:"https://" reference.value
      then Some (String.sub reference.value 8 (String.length reference.value - 8))
      else if String_util.starts_with_ci ~prefix:"http://" reference.value
      then Some (String.sub reference.value 7 (String.length reference.value - 7))
      else None
    in
    (match scheme_rest with
     | Some rest when rest <> "" -> Ok (User_image (Url_ref reference))
     | _ ->
         Error
           (Printf.sprintf
              "user_blocks image block url must be an http or https URL: %S"
              reference.value))
  | [ "file_id" ] ->
    let* fields =
      exact_object_fields
        ~field:"user_blocks image file_id block"
        ~allowed:[ "type"; "file_id"; "mime_type" ]
        json
    in
    let* reference = parse_user_image_reference ~kind:"file_id" ~value_key:"file_id" fields in
    Ok (User_image (File_id_ref reference))
  | [] ->
    Error
      "user_blocks image block requires exactly one of attachment_id, url, or file_id"
  | _ ->
    Error
      "user_blocks image block accepts only one of attachment_id, url, or file_id"

let parse_user_input_block json =
  let* base_fields =
    exact_object_fields
      ~field:"user_blocks entry"
      ~allowed:("text" :: "file_id" :: media_block_allowed_fields)
      json
  in
  let* block_type = required_string ~field:"user_blocks entry" "type" base_fields in
  let block_type = String.trim block_type |> String.lowercase_ascii in
  match block_type with
  | "text" ->
    let* fields =
      exact_object_fields ~field:"user_blocks text block" ~allowed:[ "type"; "text" ] json
    in
    let* text = required_string ~field:"user_blocks text block" "text" fields in
    if String.trim text = "" then Error "user_blocks text block requires non-empty text"
    else Ok (User_text text)
  | "image" -> parse_user_image_block json
  | "document" ->
    parse_media_input_block json ~kind:"document" (fun media -> User_document media)
  | "audio" -> parse_media_input_block json ~kind:"audio" (fun media -> User_audio media)
  | "attachment" ->
    parse_media_input_block json ~kind:"attachment" (fun media -> User_attachment media)
  | "" -> Error "user_blocks block requires type"
  | other ->
    Error
      (Printf.sprintf
         "unsupported user_blocks type %S: expected text, image, document, audio, or attachment"
         other)

let parse_user_blocks json =
  match Json_util.assoc_member_opt "user_blocks" json with
  | None | Some `Null -> Ok []
  | Some (`List blocks) ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | block :: rest -> (
            match parse_user_input_block block with
            | Ok parsed -> loop (parsed :: acc) rest
            | Error err -> Error err)
      in
      loop [] blocks
  | Some _ -> Error "user_blocks must be an array"

let user_media_label (kind : string) (media : user_media_block) =
  let label =
    match String.trim media.name with
    | "" -> media.attachment_id
    | name -> name
  in
  Printf.sprintf "[%s attached: %s]" kind label

let fallback_message_of_attachments attachments =
  match attachments with
  | [] -> ""
  | _ ->
      attachments
      |> List.map (fun (att : Keeper_chat_store.attachment) ->
        let kind =
          match String.trim att.att_type with
          | "" -> "file"
          | att_type -> att_type
        in
        let label =
          match String.trim att.name with
          | "" -> att.id
          | name -> name
        in
        Printf.sprintf "[%s attached: %s]" kind label)
      |> String.concat "\n"
      |> String.trim

let fallback_message ~attachments blocks =
  let text =
    blocks
    |> List.filter_map (function
      | User_text text ->
          if String.trim text = "" then None else Some text
      | User_image _ | User_document _ | User_audio _ | User_attachment _ -> None)
    |> String.concat "\n\n"
  in
  if text <> "" then
    text
  else
    let from_blocks =
      blocks
      |> List.filter_map (function
        | User_text _ -> None
        | User_image (Attached media) -> Some (user_media_label "image" media)
        (* Text-line stand-in for a reference image on the string-only turn
           path, where no block can ride. Same bracket shape as
           [user_media_label] so the prompt reads uniformly whether the image
           was bytes or a reference. *)
        | User_image (Url_ref { value; _ }) ->
            Some (Printf.sprintf "[image: %s]" value)
        | User_image (File_id_ref { value; _ }) ->
            Some (Printf.sprintf "[image: file_id %s]" value)
        | User_document media -> Some (user_media_label "document" media)
        | User_audio media -> Some (user_media_label "audio" media)
        | User_attachment media -> Some (user_media_label "attachment" media))
      |> String.concat "\n"
      |> String.trim
    in
    if from_blocks <> "" then from_blocks else fallback_message_of_attachments attachments

let referenced_attachment_ids blocks =
  List.filter_map
    (function
      | User_text _ -> None
      | User_image (Attached media) -> Some media.attachment_id
      (* A reference carrier names no attachment: it resolves at the
         provider, not through the byte store, so it neither references
         nor orphans one. *)
      | User_image (Url_ref _) | User_image (File_id_ref _) -> None
      | User_document media | User_audio media | User_attachment media ->
        Some media.attachment_id)
    blocks

let user_block_of_attachment (att : Keeper_chat_store.attachment) =
  let media : user_media_block =
    { attachment_id = att.id
    ; name = att.name
    ; mime_type = att.mime_type
    ; size = if att.size > 0 then Some att.size else None
    }
  in
  let att_type = String.lowercase_ascii (String.trim att.att_type) in
  let mime = String.lowercase_ascii (String.trim att.mime_type) in
  if String.equal att_type "image" || String.starts_with ~prefix:"image/" mime
  then User_image (Attached media)
  else if String.equal att_type "audio" || String.starts_with ~prefix:"audio/" mime
  then User_audio media
  else if String.equal att_type "document" || String.equal att_type "file" || mime <> ""
  then User_document media
  else User_attachment media

let normalize_user_blocks ~attachments blocks =
  let referenced = referenced_attachment_ids blocks in
  let missing_blocks =
    List.filter_map
      (fun (att : Keeper_chat_store.attachment) ->
         if List.exists (String.equal att.id) referenced
         then None
         else Some (user_block_of_attachment att))
      attachments
  in
  blocks @ missing_blocks

(* Attachments are a byte store: only user_blocks media blocks referencing an
   attachment_id are materialized into AGENT_CORE content blocks. An
   attachment nothing references would be silently dropped, so the request is
   rejected instead of succeeding without the media. *)
let validate_attachment_references ~attachments blocks =
  let referenced = referenced_attachment_ids blocks in
  let orphan_ids =
    List.filter_map
      (fun (att : Keeper_chat_store.attachment) ->
        if List.exists (String.equal att.id) referenced then None
        else Some att.id)
      attachments
  in
  match orphan_ids with
  | [] -> Ok ()
  | first :: _ ->
      let ids =
        orphan_ids |> List.map (Printf.sprintf "%S") |> String.concat ", "
      in
      Error
        (Printf.sprintf
           "attachments not referenced by user_blocks: %s; every attachment must be referenced by a user_blocks media block such as {\"type\":\"image\",\"attachment_id\":%S}"
           ids first)

let find_attachment ~attachments attachment_id =
  List.find_opt
    (fun (att : Keeper_chat_store.attachment) ->
       String.equal att.id attachment_id)
    attachments

let normalize_media_type value = String.trim value |> String.lowercase_ascii

let declared_media_type (media : user_media_block) (att : Keeper_chat_store.attachment) =
  match String.trim media.mime_type with
  | "" ->
      (match String.trim att.mime_type with
      | "" -> None
      | mime_type -> Some (normalize_media_type mime_type))
  | mime_type -> Some (normalize_media_type mime_type)

(* The text before and after the first occurrence of [needle], found at
   [index] in [value]. *)
let split_at ~index ~needle value =
  let after_index = index + String.length needle in
  String.sub value 0 index, String.sub value after_index (String.length value - after_index)

let split_once ~needle value =
  Option.map (fun index -> split_at ~index ~needle value) (String_util.find_substring value needle)

(* ASCII lowercasing keeps every byte offset, so the index found in the
   lowercased copy cuts the original [value]. *)
let split_once_ci ~needle value =
  Option.map
    (fun index -> split_at ~index ~needle value)
    (String_util.find_substring (String.lowercase_ascii value) (String.lowercase_ascii needle))

let data_url_scheme_prefix = "data:"

let media_type_of_data_url_header header =
  let prefix_len = String.length data_url_scheme_prefix in
  let value =
    String.sub header prefix_len (String.length header - prefix_len)
    |> normalize_media_type
  in
  match split_once ~needle:";" value with
  | Some (media_type, _) -> String.trim media_type
  | None -> value

let normalize_media_payload ~kind ~attachment_id ~declared_media_type data =
  let data = String.trim data in
  if data = "" then
    Error
      (Printf.sprintf
         "empty attachment payload for %s user block %S"
         kind attachment_id)
  else if String_util.starts_with_ci ~prefix:data_url_scheme_prefix data then
    match split_once_ci ~needle:";base64," data with
    | None ->
        Error
          (Printf.sprintf
             "malformed data URL for %s user block %S: expected data:<mime>;base64,<payload>"
             kind attachment_id)
    | Some (header, payload) ->
        let media_type = media_type_of_data_url_header header in
        let payload = String.trim payload in
        if media_type = "" then
          Error
            (Printf.sprintf
               "malformed data URL for %s user block %S: missing MIME type"
               kind attachment_id)
        else if payload = "" then
          Error
            (Printf.sprintf
               "empty attachment payload for %s user block %S"
               kind attachment_id)
        else (
          match declared_media_type with
          | Some declared when not (String_util.equals_ci declared media_type) ->
              Error
                (Printf.sprintf
                   "attachment MIME mismatch for %s user block %S: declared %s but data URL is %s"
                   kind attachment_id declared media_type)
          | Some declared -> Ok (declared, payload)
          | None -> Ok (media_type, payload))
  else
    let media_type =
      match declared_media_type with
      | Some media_type -> media_type
      | None -> "application/octet-stream"
    in
    Ok (media_type, data)

let attachment_of_store_meta ?(fallback_name = "") (meta : Attachment_store.meta)
  : Keeper_chat_store.attachment
  =
  let name =
    match meta.filename with
    | Some f when String.trim f <> "" -> f
    | Some _ | None ->
      if String.trim fallback_name <> "" then fallback_name else meta.id
  in
  { Keeper_chat_store.id = meta.id
  ; att_type = Attachment_store.media_kind_to_string meta.kind
  ; name
  ; size = meta.bytes
  ; mime_type = meta.mime_type
  ; data = Attachment_store.url_of_id meta.id
  ; width = meta.width
  ; height = meta.height
  }

let load_from_attachment_store ?base_path ~kind (media : user_media_block)
  : (Keeper_chat_store.attachment * Attachment_store.media_kind * string * string, string) result
  =
  match Attachment_store.parse_id (String.trim media.attachment_id) with
  | Error _ ->
    Error
      (Printf.sprintf
         "missing attachment payload for %s user block %S"
         kind media.attachment_id)
  | Ok _ ->
    (match base_path with
     | None ->
       Error
         (Printf.sprintf
            "attachment store unavailable to resolve %s user block %S"
            kind media.attachment_id)
     | Some bp ->
       let store = Attachment_store.create ~base_path:bp in
       let* meta =
         match Attachment_store.get_meta store ~id:media.attachment_id with
         | Ok (Some meta) ->
           ignore (Attachment_store.promote_to_durable store ~id:meta.id);
           Ok meta
         | Ok None ->
           Error
             (Printf.sprintf
                "attachment %S not found in attachment store"
                media.attachment_id)
         | Error err ->
           Error
             (Printf.sprintf
                "failed to read attachment %S metadata: %s"
                media.attachment_id
                (Attachment_store.get_error_to_string err))
       in
       let att = attachment_of_store_meta ~fallback_name:media.name meta in
       (* Never load or base64-inline raw 50MB video binaries into LLM provider prompts. *)
       match meta.kind with
       | Attachment_store.Video -> Ok (att, Attachment_store.Video, meta.mime_type, "")
       | Attachment_store.Image | Attachment_store.Audio | Attachment_store.Document ->
         let* bytes =
           match Attachment_store.get_bytes_by_sha256 store ~sha256:meta.sha256 with
           | Ok (Some raw) -> Ok raw
           | Ok None ->
             Error
               (Printf.sprintf
                  "attachment %S bytes missing from attachment store"
                  media.attachment_id)
           | Error err ->
             Error
               (Printf.sprintf
                  "failed to read attachment %S bytes: %s"
                  media.attachment_id
                  (Attachment_store.get_error_to_string err))
         in
         Ok (att, meta.kind, meta.mime_type, Base64.encode_string bytes))

let is_attachment_url_ref data =
  String.starts_with ~prefix:Attachment_store.url_prefix (String.trim data)

let resolve_media_payload ?base_path ~attachments kind media =
  match find_attachment ~attachments media.attachment_id with
  | Some att when not (String.equal (String.trim att.data) "") && not (is_attachment_url_ref att.data) ->
      let declared = declared_media_type media att in
      Result.map
        (fun (media_type, data) -> att, media_type, data)
        (normalize_media_payload ~kind ~attachment_id:media.attachment_id
           ~declared_media_type:declared att.data)
  | Some _ | None ->
      let* att, att_kind, media_type, b64 =
        load_from_attachment_store ?base_path ~kind media
      in
      (match att_kind with
       | Attachment_store.Video ->
         Error
           (Printf.sprintf
              "video attachment %S cannot be base64-inlined as %s payload; attach it as a generic attachment reference instead"
              media.attachment_id kind)
       | Attachment_store.Image | Attachment_store.Audio | Attachment_store.Document ->
         Ok (att, media_type, b64))

let media_block_to_agent_core ?base_path ~attachments kind make_block media =
  Result.map
    (fun (_att, media_type, data) -> make_block ~media_type ~data ())
    (resolve_media_payload ?base_path ~attachments kind media)

let hydrate_attachments ~base_path ~attachments blocks =
  let store = Attachment_store.create ~base_path in
  let resolve_canonical id ~fallback_name =
    match Attachment_store.parse_id (String.trim id) with
    | Error _ -> Ok None
    | Ok _ ->
      (match Attachment_store.get_meta store ~id:(String.trim id) with
       | Ok (Some meta) ->
         ignore (Attachment_store.promote_to_durable store ~id:meta.id);
         Ok (Some (attachment_of_store_meta ~fallback_name meta))
       | Ok None ->
         Error (Printf.sprintf "attachment %S not found in attachment store" id)
       | Error err ->
         Error
           (Printf.sprintf
              "failed to read attachment %S: %s"
              id
              (Attachment_store.get_error_to_string err)))
  in
  let rec hydrate_existing acc = function
    | [] -> Ok (List.rev acc)
    | (att : Keeper_chat_store.attachment) :: rest ->
      if String.equal (String.trim att.data) "" || is_attachment_url_ref att.data
      then
        let* resolved = resolve_canonical att.id ~fallback_name:att.name in
        (match resolved with
         | Some full -> hydrate_existing (full :: acc) rest
         | None -> hydrate_existing (att :: acc) rest)
      else hydrate_existing (att :: acc) rest
  in
  let* existing = hydrate_existing [] attachments in
  let block_refs =
    List.filter_map
      (function
        | User_text _ | User_image (Url_ref _) | User_image (File_id_ref _) -> None
        | User_image (Attached media)
        | User_document media
        | User_audio media
        | User_attachment media -> Some media)
      blocks
  in
  let rec add_missing acc = function
    | [] -> Ok acc
    | (media : user_media_block) :: rest ->
      if List.exists (fun (att : Keeper_chat_store.attachment) -> String.equal att.id media.attachment_id) acc
      then add_missing acc rest
      else
        let* resolved = resolve_canonical media.attachment_id ~fallback_name:media.name in
        (match resolved with
         | Some full -> add_missing (acc @ [ full ]) rest
         | None -> add_missing acc rest)
  in
  add_missing existing block_refs

type document_projection =
  | Project_as_text
  | Preserve_document

(* Catalog the text-like document kinds accepted by the dashboard composer.
   This is the one untyped MIME boundary; control flow consumes the typed
   [document_projection] below instead of branching on MIME strings. *)
let text_document_media_types =
  Set_util.StringSet.of_list
    [ "text/plain"
    ; "text/markdown"
    ; "text/html"
    ; "application/json"
    ; "text/csv"
    ]

let document_projection_of_media_type media_type =
  if Set_util.StringSet.mem media_type text_document_media_types
  then Project_as_text
  else Preserve_document

let text_block_of_document
    ~(att : Keeper_chat_store.attachment)
    ~attachment_id
    ~media_type
    data =
  match Base64.decode data with
  | Error (`Msg msg) ->
      Error
        (Printf.sprintf
           "invalid base64 payload for textual document user block %S: %s"
           attachment_id
           msg)
  | Ok text ->
      let sanitized = Safe_ops.sanitize_text_utf8 text in
      if not (String.equal text sanitized) then
        Error
          (Printf.sprintf
             "textual document user block %S is not valid UTF-8 text or contains unsupported control characters"
             attachment_id)
      else
        let name =
          match String.trim att.name with
          | "" -> attachment_id
          | name -> name
        in
        let metadata =
          Yojson.Safe.to_string
            (`Assoc
              [ "kind", `String "user_attachment"
              ; "name", `String name
              ; "media_type", `String media_type
              ])
        in
        Ok
          (Llm_provider.Types.Text
             (Printf.sprintf
                "User-provided attachment metadata: %s\n\n%s"
                metadata
                text))

let document_block_to_agent_core ?base_path ~attachments media =
  match resolve_media_payload ?base_path ~attachments "document" media with
  | Error _ as error -> error
  | Ok (att, media_type, data) ->
      (match document_projection_of_media_type media_type with
       | Project_as_text ->
           text_block_of_document
             ~att
             ~attachment_id:media.attachment_id
             ~media_type
             data
       | Preserve_document ->
           Ok
             (Llm_provider.Types.document_block ~media_type
                ~source:(Llm_provider.Types.Base64 data)))

let attachment_block_to_agent_core ?base_path ~attachments (media : user_media_block) =
  match find_attachment ~attachments media.attachment_id with
  | Some att when not (String.equal (String.trim att.data) "") && not (is_attachment_url_ref att.data) ->
    (match user_block_of_attachment att with
     | User_image (Attached m) ->
       media_block_to_agent_core ?base_path ~attachments "image"
         (fun ~media_type ~data () ->
            Llm_provider.Types.image_block ~media_type
              ~source:(Llm_provider.Types.Base64 data))
         m
     | User_audio m ->
       media_block_to_agent_core ?base_path ~attachments "audio"
         (fun ~media_type ~data () ->
            Llm_provider.Types.audio_block ~media_type
              ~source:(Llm_provider.Types.Base64 data))
         m
     | User_document m | User_attachment m ->
       document_block_to_agent_core ?base_path ~attachments m
     | User_text _ | User_image (Url_ref _) | User_image (File_id_ref _) ->
       document_block_to_agent_core ?base_path ~attachments media)
  | Some _ | None ->
    let* att, kind, media_type, data =
      load_from_attachment_store ?base_path ~kind:"attachment" media
    in
    (match kind with
     | Attachment_store.Image ->
       Ok (Llm_provider.Types.image_block ~media_type ~source:(Llm_provider.Types.Base64 data))
     | Attachment_store.Audio ->
       Ok (Llm_provider.Types.audio_block ~media_type ~source:(Llm_provider.Types.Base64 data))
     | Attachment_store.Video ->
       let label =
         if String.trim att.name <> "" then att.name else media.attachment_id
       in
       Ok
         (Llm_provider.Types.text_block
            (Printf.sprintf
               "[Video attachment: %s (%s, id=%s, url=%s). Stored for playback; raw video binary is not inlined into the model prompt (poster frame available at %s?poster=1).]"
               label
               media_type
               media.attachment_id
               att.data
               att.data))
     | Attachment_store.Document ->
       (match document_projection_of_media_type media_type with
        | Project_as_text ->
          text_block_of_document ~att ~attachment_id:media.attachment_id ~media_type data
        | Preserve_document ->
          Ok (Llm_provider.Types.document_block ~media_type ~source:(Llm_provider.Types.Base64 data))))

(* A reference image crosses as the native carrier form: the source's [Url] or
   [File_id] constructor holds the URL or file id verbatim and tells the
   serializers which wire shape to emit (#33669). [media_type] is required by the block record but carries
   nothing for a reference on the chat surface; the advisory value the request
   named is passed through, else the generic unknown this module already uses.
   Nothing here fetches the reference — the provider resolves it or visibly
   rejects it. *)
let image_reference_to_agent_core (reference : user_image_reference) source =
  Llm_provider.Types.image_block
    ~media_type:(Option.value reference.mime_type ~default:"application/octet-stream")
    ~source

type input_error =
  | Invalid_input of string
  | Media_store_unavailable of Agent_core.History.media_error

let input_error_to_string = function
  | Invalid_input detail -> detail
  | Media_store_unavailable error ->
    "attachment could not be stored: "
    ^ Agent_core.Error.to_string (Agent_core.Error.Media error)
;;

(* The blocks are checked and built in provider form first; their media then
   enter history in one step, so a payload that does not decode is the
   sender's error and a store that cannot keep the bytes is the store's. *)
let to_agent_core_blocks ?base_path ~media_store ~attachments blocks =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | User_text text :: rest ->
        let acc =
          if String.trim text = "" then acc else Llm_provider.Types.Text text :: acc
        in
        loop acc rest
    | User_image (Attached media) :: rest -> (
        match
          media_block_to_agent_core ?base_path ~attachments "image"
            (fun ~media_type ~data () ->
               Llm_provider.Types.image_block ~media_type
                 ~source:(Llm_provider.Types.Base64 data))
            media
        with
        | Ok block -> loop (block :: acc) rest
        | Error err -> Error err)
    | User_image (Url_ref reference) :: rest ->
        loop
          (image_reference_to_agent_core
             reference
             (Llm_provider.Types.Url reference.value)
           :: acc)
          rest
    | User_image (File_id_ref reference) :: rest ->
        loop
          (image_reference_to_agent_core
             reference
             (Llm_provider.Types.File_id reference.value)
           :: acc)
          rest
    | User_document media :: rest -> (
        match document_block_to_agent_core ?base_path ~attachments media with
        | Ok block -> loop (block :: acc) rest
        | Error err -> Error err)
    | User_audio media :: rest -> (
        match
          media_block_to_agent_core ?base_path ~attachments "audio"
            (fun ~media_type ~data () ->
               Llm_provider.Types.audio_block ~media_type
                 ~source:(Llm_provider.Types.Base64 data))
            media
        with
        | Ok block -> loop (block :: acc) rest
        | Error err -> Error err)
    | User_attachment media :: rest -> (
        match attachment_block_to_agent_core ?base_path ~attachments media with
        | Ok block -> loop (block :: acc) rest
        | Error err -> Error err)
  in
  match loop [] blocks with
  | Error detail -> Error (Invalid_input detail)
  | Ok wire ->
    (match Agent_core.History.of_wire_blocks media_store wire with
     | Ok blocks -> Ok blocks
     | Error (Agent_core.History.Invalid_base64 _ as error) ->
       Error (Invalid_input (Agent_core.Error.to_string (Agent_core.Error.Media error)))
     | Error
         ((Agent_core.History.Store_failed _ | Missing_bytes _ | Digest_mismatch _) as error)
       -> Error (Media_store_unavailable error))
