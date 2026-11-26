type failure =
  | Binding_changed
  | Discord_unconfigured
  | Original_unavailable
  | Original_mismatch
  | Attachment_missing
  | Invalid_attachment
  | Byte_budget_exceeded
  | Download_failed
  | Deadline_exceeded

type loaded = {
  images : Keeper_chat_store.attachment list;
  failures : (string * failure) list;
}

let reason = function
  | Binding_changed -> "Discord channel binding changed"
  | Discord_unconfigured -> "Discord bot is not configured"
  | Original_unavailable -> "the original Discord message could not be read"
  | Original_mismatch -> "Discord returned a different message or author"
  | Attachment_missing -> "the attachment is no longer present on the original message"
  | Invalid_attachment -> "Discord did not return a supported image matching the attachment"
  | Byte_budget_exceeded -> "the image exceeds the turn's attachment byte budget"
  | Download_failed -> "Discord could not deliver the image bytes"
  | Deadline_exceeded -> "the Discord image read timed out"

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_field name value =
  match field name value with Some (`String value) -> Some value | _ -> None

let attachment_url ~channel_id ~attachment_id url =
  let uri = Uri.of_string url in
  let path = Uri.path uri in
  let exact_path =
    match String.split_on_char '/' path with
    | [ ""; "attachments"; channel; attachment; filename ] ->
      let filename = Uri.pct_decode filename in
      String.equal channel channel_id && String.equal attachment attachment_id
      && filename <> "" && filename <> "." && filename <> ".."
      && not (String.contains filename '/' || String.contains filename '\\')
    | _ -> false
  in
  String.for_all (fun c -> Char.code c > 32 && Char.code c <> 127) url
  && Uri.scheme uri = Some "https"
  && Uri.host uri = Some "cdn.discordapp.com"
  && (Uri.port uri = None || Uri.port uri = Some 443)
  && Uri.userinfo uri = None && Uri.fragment uri = None && exact_path
;;

let unavailable attachment_ids failure =
  { images = []; failures = List.map (fun id -> id, failure) attachment_ids }
;;

let resolve ~max_bytes ~is_bound ~fetch_original ~fetch_bytes
      ~channel_id ~message_id ~author_id ~attachment_ids =
  let open Result.Syntax in
  let original =
    if not (is_bound ()) then Error Binding_changed
    else
      let* message = fetch_original () in
      let observed_author = Option.bind (field "author" message) (string_field "id") in
      if string_field "channel_id" message <> Some channel_id
         || string_field "id" message <> Some message_id
         || observed_author <> Some author_id then Error Original_mismatch
      else
        match field "attachments" message with
        | Some (`List attachments) -> Ok attachments
        | _ -> Error Original_mismatch
  in
  match original with
  | Error failure -> unavailable attachment_ids failure
  | Ok attachments ->
    let download ~budget id =
      let* attachment =
        match List.filter (fun a -> string_field "id" a = Some id) attachments with
        | [] -> Error Attachment_missing
        | [ item ] -> Ok item
        | _ -> Error Invalid_attachment
      in
      let* name, size, url =
        match string_field "filename" attachment, field "size" attachment, string_field "url" attachment with
        | Some name, Some (`Int size), Some url
          when name <> "" && size > 0 && attachment_url ~channel_id ~attachment_id:id url ->
          Ok (name, size, url)
        | _ -> Error Invalid_attachment
      in
      let* () =
        if size > budget then Error Byte_budget_exceeded
        else if not (is_bound ()) then Error Binding_changed
        else Ok ()
      in
      let* bytes = fetch_bytes ~max_bytes:size url in
      let* mime_type =
        if String.length bytes <> size then Error Invalid_attachment
        else Keeper_vision_tool.sniff_image_media_type bytes
             |> Result.map_error (fun _ -> Invalid_attachment)
      in
      let* () =
        match string_field "content_type" attachment with
        | None -> Ok ()
        | Some declared ->
          (match Keeper_vision_tool.validate_media_type declared with
           | Ok normalized when String.equal normalized mime_type -> Ok ()
           | Ok _ | Error _ -> Error Invalid_attachment)
      in
      let width, height =
        match Keeper_image_dimensions.image_dimensions bytes with
        | None -> None, None
        | Some (width, height) -> Some width, Some height
      in
      Ok ({ Keeper_chat_store.id; att_type = "image"; name; size; mime_type;
            data = Base64.encode_exn bytes; width; height }
          : Keeper_chat_store.attachment)
    in
    let rec collect budget images failures = function
      | [] ->
        if not (is_bound ()) then unavailable attachment_ids Binding_changed
        else { images = List.rev images; failures = List.rev failures }
      | id :: rest ->
        match download ~budget id with
        | Ok image -> collect (budget - image.size) (image :: images) failures rest
        | Error failure -> collect budget images ((id, failure) :: failures) rest
    in
    collect max_bytes [] [] attachment_ids
;;

let load ~base_path ~clock ~keeper_name (source : Keeper_chat_operation_payload.decoded_source) =
  let attachment_ids =
    List.map
      (fun (Keeper_chat_operation_payload.Discord_image { attachment_id }) -> attachment_id)
      source.connector_attachments
  in
  match attachment_ids, source.continuation_channel with
  | [], _ -> { images = []; failures = [] }
  | _, Keeper_continuation_channel.Discord
      { channel_id; parent_channel_id; reply_to_message_id = Some message_id; user_id = author_id; _ } ->
    (match Env_config_discord.bot_token_opt () with
     | None -> unavailable attachment_ids Discord_unconfigured
     | Some token ->
       let same_workspace =
         try String.equal (Unix.realpath base_path) (Unix.realpath (Env_config_core.base_path ()))
         with Unix.Unix_error _ -> false
       in
       let deadline = Eio.Time.now clock +. Masc_http_client.default_request_timeout_sec in
       let within_deadline run =
         let remaining = deadline -. Eio.Time.now clock in
         if remaining <= 0. then Error Deadline_exceeded
         else
           try Eio.Time.with_timeout_exn clock remaining run
           with Eio.Time.Timeout -> Error Deadline_exceeded
       in
       let fetch_original () = within_deadline (fun () ->
         let open Result.Syntax in
         let snowflake id =
           Discord_rest_client.snowflake_of_string id
           |> Result.map_error (fun _ -> Original_mismatch)
         in
         let* channel_id = snowflake channel_id in
         let* message_id = snowflake message_id in
         Discord_rest_client.get_message ~clock ~token ~channel_id ~message_id ()
         |> Result.map_error (fun _ -> Original_unavailable))
       in
       let fetch_bytes ~max_bytes url = within_deadline (fun () ->
         match Masc_http_client.get_sync ~clock ~max_body_bytes:max_bytes ~url ~headers:[] () with
         | Ok (200, bytes) -> Ok bytes
         | Ok _ | Error _ -> Error Download_failed)
       in
       let is_bound () =
         same_workspace
         && match Channel_gate_discord_state.resolve_keeper_for_recorded_channel_result
                    ~channel_id ~parent_channel_id with
            | Ok (Some binding) -> String.equal binding.keeper_name keeper_name
            | Ok None | Error _ -> false
       in
       resolve ~max_bytes:(Keeper_vision_tool.max_image_bytes ())
         ~is_bound ~fetch_original ~fetch_bytes ~channel_id ~message_id ~author_id ~attachment_ids)
  (* Only a Discord continuation that names its original message can be read
     back. Every other connector is named so a new one must decide here
     whether its attachments can be read. *)
  | _, ( Keeper_continuation_channel.Discord { reply_to_message_id = None; _ }
       | Keeper_continuation_channel.Dashboard _
       | Keeper_continuation_channel.Slack _
       | Keeper_continuation_channel.Telegram _
       | Keeper_continuation_channel.Imessage _
       | Keeper_continuation_channel.Gate _
       | Keeper_continuation_channel.Keeper _
       | Keeper_continuation_channel.Unrouted _ ) ->
    unavailable attachment_ids Original_mismatch
;;

module For_testing = struct
  let resolve = resolve
end
