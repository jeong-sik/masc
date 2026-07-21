(* See board_render_slack.mli for the contract. *)

type payload = {
  content : string;
  blocks : Yojson.Safe.t list;
}

let non_empty s =
  match String.trim s with
  | "" -> None
  | trimmed -> Some trimmed

let title_or_url name url =
  match non_empty name with
  | Some name -> name
  | None -> url

let block_of_attachment = function
  | Board_render.Image { url; name; _ } ->
    Keeper_chat_slack.image_block_json ~url ~caption:(non_empty name)
  | Board_render.Video { url; name; _ } | Board_render.Youtube { url; name }
  | Board_render.External_link { url; name } ->
    Keeper_chat_slack.link_block_json ~url ~title:(title_or_url name url)
      ~description:None
  | Board_render.Invalid_attachment { detail } ->
    Keeper_chat_slack.section_block_json
      ~text:(Printf.sprintf "⚠️ invalid attachment: %s" detail)

let payload_of_document (doc : Board_render.document) : payload =
  { content = Board_render.plain_text doc
  ; blocks =
      List.filter_map
        (fun b ->
          match b with
          | Board_render.Attachment a -> Some (block_of_attachment a)
          | _ -> None)
        doc.blocks
  }
