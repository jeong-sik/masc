type user_media_block = {
  attachment_id : string;
  name : string;
  mime_type : string;
  size : int option;
}

type user_input_block =
  | User_text of string
  | User_image of user_media_block
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

let parse_attachment json =
  match json with
  | `Assoc _ ->
      let id =
        Json_util.get_string_with_default json ~key:"id" ~default:""
        |> String.trim
      in
      let att_type =
        Json_util.get_string_with_default json ~key:"type" ~default:""
        |> String.trim
      in
      let name =
        Json_util.get_string_with_default json ~key:"name" ~default:""
        |> String.trim
      in
      let size =
        match Json_util.assoc_member_opt "size" json with
        | Some (`Int n) when n >= 0 -> n
        | _ -> 0
      in
      let mime_type =
        Json_util.get_string_with_default json ~key:"mime_type" ~default:""
        |> String.trim
      in
      let data =
        Json_util.get_string_with_default json ~key:"data" ~default:""
      in
      if id = "" || data = "" then None
      else
        Some { Keeper_chat_store.id; att_type; name; size; mime_type; data }
  | _ -> None

let parse_attachments json =
  match Json_util.assoc_member_opt "attachments" json with
  | Some (`List attachments) -> List.filter_map parse_attachment attachments
  | _ -> []

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

let user_block_to_yojson = function
  | User_text text -> `Assoc [ ("type", `String "text"); ("text", `String text) ]
  | User_image media -> user_media_block_to_yojson "image" media
  | User_document media -> user_media_block_to_yojson "document" media
  | User_audio media -> user_media_block_to_yojson "audio" media

let user_blocks_to_yojson blocks =
  `List (List.map user_block_to_yojson blocks)

let parse_user_media_block ~(kind : string) json =
  let attachment_id =
    Json_util.get_string_with_default json ~key:"attachment_id" ~default:""
    |> String.trim
  in
  let name =
    Json_util.get_string_with_default json ~key:"name" ~default:""
    |> String.trim
  in
  let mime_type =
    Json_util.get_string_with_default json ~key:"mime_type" ~default:""
    |> String.trim
  in
  let size =
    match Json_util.assoc_member_opt "size" json with
    | None | Some `Null -> Ok None
    | Some (`Int size) when size >= 0 -> Ok (Some size)
    | Some (`Int _) -> Error "user_blocks media size must be non-negative"
    | Some _ -> Error "user_blocks media size must be an integer"
  in
  if attachment_id = "" then
    Error (Printf.sprintf "user_blocks %s block requires attachment_id" kind)
  else
    match size with
    | Error err -> Error err
    | Ok size -> Ok { attachment_id; name; mime_type; size }

let parse_user_input_block json =
  match json with
  | `Assoc _ ->
      let block_type =
        Json_util.get_string_with_default json ~key:"type" ~default:""
        |> String.trim
        |> String.lowercase_ascii
      in
      (match block_type with
       | "text" ->
           let text =
             Json_util.get_string_with_default json ~key:"text" ~default:""
             |> String.trim
           in
           if text = "" then
             Error "user_blocks text block requires non-empty text"
           else Ok (User_text text)
       | "image" ->
           Result.map
             (fun media -> User_image media)
             (parse_user_media_block ~kind:"image" json)
       | "document" ->
           Result.map
             (fun media -> User_document media)
             (parse_user_media_block ~kind:"document" json)
       | "audio" ->
           Result.map
             (fun media -> User_audio media)
             (parse_user_media_block ~kind:"audio" json)
       | "" -> Error "user_blocks block requires type"
       | other ->
           Error
             (Printf.sprintf
                "unsupported user_blocks type %S: expected text, image, document, or audio"
                other))
  | _ -> Error "user_blocks entries must be JSON objects"

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
        | User_image media -> Some (user_media_label "image" media)
        | User_document media -> Some (user_media_label "document" media)
        | User_audio media -> Some (user_media_label "audio" media))
      |> String.concat "\n"
      |> String.trim
    in
    if from_blocks <> "" then from_blocks else fallback_message_of_attachments attachments

let add_unique label labels =
  if List.exists (String.equal label) labels then labels else labels @ [ label ]

let modalities blocks =
  List.fold_left
    (fun acc -> function
       | User_text _ -> add_unique "text" acc
       | User_image _ -> add_unique "image" acc
       | User_document _ -> add_unique "document" acc
       | User_audio _ -> add_unique "audio" acc)
    [] blocks

let find_attachment ~attachments attachment_id =
  List.find_opt
    (fun (att : Keeper_chat_store.attachment) ->
       String.equal att.id attachment_id)
    attachments

let media_type_for media (att : Keeper_chat_store.attachment) =
  match String.trim media.mime_type with
  | "" -> (
      match String.trim att.mime_type with
      | "" -> "application/octet-stream"
      | mime_type -> mime_type)
  | mime_type -> mime_type

let media_block_to_oas ~attachments kind make_block media =
  match find_attachment ~attachments media.attachment_id with
  | None ->
      Error
        (Printf.sprintf
           "missing attachment payload for %s user block %S"
           kind media.attachment_id)
  | Some att ->
      let data = String.trim att.data in
      if data = "" then
        Error
          (Printf.sprintf
             "empty attachment payload for %s user block %S"
             kind media.attachment_id)
      else
        Ok (make_block ~media_type:(media_type_for media att) ~data ())

let to_oas_blocks ~attachments blocks =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | User_text text :: rest ->
        let text = String.trim text in
        let acc =
          if text = "" then acc else Agent_sdk.Types.Text text :: acc
        in
        loop acc rest
    | User_image media :: rest -> (
        match
          media_block_to_oas ~attachments "image"
            (fun ~media_type ~data () ->
               Agent_sdk.Types.image_block ~media_type ~data ())
            media
        with
        | Ok block -> loop (block :: acc) rest
        | Error err -> Error err)
    | User_document media :: rest -> (
        match
          media_block_to_oas ~attachments "document"
            (fun ~media_type ~data () ->
               Agent_sdk.Types.document_block ~media_type ~data ())
            media
        with
        | Ok block -> loop (block :: acc) rest
        | Error err -> Error err)
    | User_audio media :: rest -> (
        match
          media_block_to_oas ~attachments "audio"
            (fun ~media_type ~data () ->
               Agent_sdk.Types.audio_block ~media_type ~data ())
            media
        with
        | Ok block -> loop (block :: acc) rest
        | Error err -> Error err)
  in
  loop [] blocks
