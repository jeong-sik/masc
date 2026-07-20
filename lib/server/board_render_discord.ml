(* See board_render_discord.mli for the contract. *)

type payload = {
  content : string;
  embeds : Discord_rest_client.embed list;
}

let discord_embed_limit = 10

(* Discord rejects embed titles longer than 256 characters. Clamp with the
   same ellipsis convention as [Discord_rest_client]'s internal truncate. *)
let embed_title_limit = 256

let clamp_title s =
  if String.length s <= embed_title_limit
  then s
  else String.sub s 0 (embed_title_limit - 1) ^ "…"

let non_empty s =
  match String.trim s with
  | "" -> None
  | trimmed -> Some trimmed

let title_or_url name url =
  match non_empty name with
  | Some name -> clamp_title name
  | None -> url

let embed_of_attachment = function
  | Board_render.Image { url; name; _ } ->
    Some (Discord_rest_client.image_embed ~url ~caption:(non_empty name))
  | Board_render.Video { url; name; _ } | Board_render.Youtube { url; name }
  | Board_render.External_link { url; name } ->
    Some
      (Discord_rest_client.link_embed ~url ~title:(title_or_url name url)
         ~description:None ~image:None)
  | Board_render.Invalid_attachment _ -> None

let rec split_at n xs =
  if n <= 0
  then ([], xs)
  else
    match xs with
    | [] -> ([], [])
    | x :: tl ->
      let taken, rest = split_at (n - 1) tl in
      (x :: taken, rest)

let payload_of_document (doc : Board_render.document) : payload =
  let attachments =
    List.filter_map
      (fun b -> match b with Board_render.Attachment a -> Some a | _ -> None)
      doc.blocks
  in
  let text_blocks =
    List.filter
      (fun b -> match b with Board_render.Attachment _ -> false | _ -> true)
      doc.blocks
  in
  let valid, invalid =
    List.partition
      (fun a -> match a with
         | Board_render.Invalid_attachment _ -> false
         | _ -> true)
      attachments
  in
  let embedded, overflow = split_at discord_embed_limit valid in
  let content_blocks =
    text_blocks
    @ List.map (fun a -> Board_render.Attachment a) (overflow @ invalid)
  in
  { content = Board_render.plain_text { doc with blocks = content_blocks }
  ; embeds = List.filter_map embed_of_attachment embedded
  }
