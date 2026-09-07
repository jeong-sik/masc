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

let ( let* ) = Result.bind

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

let parse_attachment ~index json =
  let field = Printf.sprintf "attachments[%d]" index in
  let* fields =
    exact_object_fields
      ~field
      ~allowed:[ "id"; "type"; "name"; "size"; "mime_type"; "data" ]
      json
  in
  let* id = required_string ~field "id" fields in
  let* att_type = optional_string ~field "type" fields in
  let* name = optional_string ~field "name" fields in
  let* mime_type = optional_string ~field "mime_type" fields in
  let* data = required_string ~field "data" fields in
  let* size =
    match List.assoc_opt "size" fields with
    | None -> Ok 0
    | Some (`Int size) when size >= 0 -> Ok size
    | Some (`Int _) -> Error (field ^ ".size must be non-negative")
    | Some _ -> Error (field ^ ".size must be an integer")
  in
  let id = String.trim id in
  if String.equal id "" then Error (field ^ ".id must be non-empty")
  else if String.equal data "" then Error (field ^ ".data must be non-empty")
  else
    Ok
      { Keeper_chat_store.id
      ; att_type = String.trim att_type
      ; name = String.trim name
      ; size
      ; mime_type = String.trim mime_type
      ; data
      ; width = None
      ; height = None
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

let user_blocks_to_yojson blocks =
  `List (List.map user_block_to_yojson blocks)

let parse_user_media_block ~(kind : string) fields =
  let field = "user_blocks " ^ kind ^ " block" in
  let* attachment_id = required_string ~field "attachment_id" fields in
  let* name = optional_string ~field "name" fields in
  let* mime_type = optional_string ~field "mime_type" fields in
  let size =
    match List.assoc_opt "size" fields with
    | None -> Ok None
    | Some (`Int size) when size >= 0 -> Ok (Some size)
    | Some (`Int _) -> Error (field ^ ".size must be non-negative")
    | Some _ -> Error (field ^ ".size must be an integer")
  in
  let attachment_id = String.trim attachment_id in
  if attachment_id = "" then
    Error (Printf.sprintf "user_blocks %s block requires attachment_id" kind)
  else
    match size with
    | Error err -> Error err
    | Ok size ->
      Ok
        { attachment_id
        ; name = String.trim name
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
      ~allowed:[ "type"; "attachment_id"; "name"; "mime_type"; "size" ]
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
      ~allowed:[ "type"; "attachment_id"; "name"; "mime_type"; "size"; "url"; "file_id" ]
      json
  in
  let has key = List.mem_assoc key base_fields in
  let present = List.filter (fun key -> has key) [ "attachment_id"; "url"; "file_id" ] in
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
      ~allowed:
        [ "type"; "text"; "attachment_id"; "name"; "mime_type"; "size"; "url"; "file_id" ]
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
    let text = String.trim text in
    if text = "" then Error "user_blocks text block requires non-empty text"
    else Ok (User_text text)
  | "image" -> parse_user_image_block json
  | "document" ->
    parse_media_input_block json ~kind:"document" (fun media -> User_document media)
  | "audio" -> parse_media_input_block json ~kind:"audio" (fun media -> User_audio media)
  | "" -> Error "user_blocks block requires type"
  | other ->
    Error
      (Printf.sprintf
         "unsupported user_blocks type %S: expected text, image, document, or audio"
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
          let text = String.trim text in
          if text = "" then None else Some text
      | User_image _ | User_document _ | User_audio _ -> None)
    |> String.concat "\n\n"
    |> String.trim
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
        | User_audio media -> Some (user_media_label "audio" media))
      |> String.concat "\n"
      |> String.trim
    in
    if from_blocks <> "" then from_blocks else fallback_message_of_attachments attachments

(* Attachments are a byte store: only user_blocks media blocks referencing an
   attachment_id are materialized into AGENT_CORE content blocks. An
   attachment nothing references would be silently dropped, so the request is
   rejected instead of succeeding without the media. *)
let validate_attachment_references ~attachments blocks =
  let referenced =
    List.filter_map
      (function
        | User_text _ -> None
        | User_image (Attached media) -> Some media.attachment_id
        (* A reference carrier names no attachment: it resolves at the
           provider, not through the byte store, so it neither references
           nor orphans one. *)
        | User_image (Url_ref _) | User_image (File_id_ref _) -> None
        | User_document media | User_audio media -> Some media.attachment_id)
      blocks
  in
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

let split_once ~needle value =
  let needle_len = String.length needle in
  let value_len = String.length value in
  let rec loop index =
    if index + needle_len > value_len then
      None
    else if String.sub value index needle_len = needle then
      let before = String.sub value 0 index in
      let after_index = index + needle_len in
      let after =
        String.sub value after_index (value_len - after_index)
      in
      Some (before, after)
    else
      loop (index + 1)
  in
  loop 0

let split_once_ci ~needle value =
  let needle_lower = String.lowercase_ascii needle in
  let value_lower = String.lowercase_ascii value in
  let needle_len = String.length needle in
  let value_len = String.length value in
  let rec loop index =
    if index + needle_len > value_len then
      None
    else if String.sub value_lower index needle_len = needle_lower then
      let before = String.sub value 0 index in
      let after_index = index + needle_len in
      let after =
        String.sub value after_index (value_len - after_index)
      in
      Some (before, after)
    else
      loop (index + 1)
  in
  loop 0

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

let resolve_media_payload ~attachments kind media =
  match find_attachment ~attachments media.attachment_id with
  | None ->
      Error
        (Printf.sprintf
           "missing attachment payload for %s user block %S"
           kind media.attachment_id)
  | Some att ->
      let declared = declared_media_type media att in
      Result.map
        (fun (media_type, data) -> att, media_type, data)
        (normalize_media_payload ~kind ~attachment_id:media.attachment_id
           ~declared_media_type:declared att.data)

let media_block_to_agent_core ~attachments kind make_block media =
  Result.map
    (fun (_att, media_type, data) -> make_block ~media_type ~data ())
    (resolve_media_payload ~attachments kind media)

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
          (Agent_core.Types.Text
             (Printf.sprintf
                "User-provided attachment metadata: %s\n\n%s"
                metadata
                text))

let document_block_to_agent_core ~attachments media =
  match resolve_media_payload ~attachments "document" media with
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
           Ok (Agent_core.Types.document_block ~media_type ~data ()))

(* A reference image crosses as the native carrier form: [data] holds the URL
   or file id verbatim and [source_type] tells the serializers which wire shape
   to emit (#33669). [media_type] is required by the block record but carries
   nothing for a reference on the chat surface; the advisory value the request
   named is passed through, else the generic unknown this module already uses.
   Nothing here fetches the reference — the provider resolves it or visibly
   rejects it. *)
let image_reference_to_agent_core ~source_type (reference : user_image_reference) =
  Agent_core.Types.image_block
    ~source_type
    ~media_type:(Option.value reference.mime_type ~default:"application/octet-stream")
    ~data:reference.value
    ()

let to_agent_core_blocks ~attachments blocks =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | User_text text :: rest ->
        let text = String.trim text in
        let acc =
          if text = "" then acc else Agent_core.Types.Text text :: acc
        in
        loop acc rest
    | User_image (Attached media) :: rest -> (
        match
          media_block_to_agent_core ~attachments "image"
            (fun ~media_type ~data () ->
               Agent_core.Types.image_block ~media_type ~data ())
            media
        with
        | Ok block -> loop (block :: acc) rest
        | Error err -> Error err)
    | User_image (Url_ref reference) :: rest ->
        loop
          (image_reference_to_agent_core
             ~source_type:Agent_core.Types.Url
             reference
           :: acc)
          rest
    | User_image (File_id_ref reference) :: rest ->
        loop
          (image_reference_to_agent_core
             ~source_type:Agent_core.Types.File_id
             reference
           :: acc)
          rest
    | User_document media :: rest -> (
        match document_block_to_agent_core ~attachments media with
        | Ok block -> loop (block :: acc) rest
        | Error err -> Error err)
    | User_audio media :: rest -> (
        match
          media_block_to_agent_core ~attachments "audio"
            (fun ~media_type ~data () ->
               Agent_core.Types.audio_block ~media_type ~data ())
            media
        with
        | Ok block -> loop (block :: acc) rest
        | Error err -> Error err)
  in
  loop [] blocks
