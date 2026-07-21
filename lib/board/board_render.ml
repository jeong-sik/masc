(* See board_render.mli for the contract. *)

type attachment_block =
  | Image of {
      url : string;
      name : string;
      width : int option;
      height : int option;
    }
  | Video of {
      url : string;
      name : string;
      mime_type : string;
    }
  | Youtube of {
      url : string;
      name : string;
    }
  | External_link of {
      url : string;
      name : string;
    }
  | Invalid_attachment of { detail : string }
[@@deriving show, eq]

type block =
  | Header of {
      title : string;
      author : string;
      hearth : string option;
    }
  | Body of string
  | Attachment of attachment_block
[@@deriving show, eq]

type document = {
  post_id : string;
  blocks : block list;
}
[@@deriving show, eq]

(* Attachments — decode through Board_attachment_meta so the wire contract
   (id/kind/payload validation) is enforced once, in the carrier module.
   Entries that fail the decode are kept as explicit [Invalid_attachment]
   blocks rather than dropped (contrast
   [Board_attachment_meta.attachments_of_post_meta], which filter_maps them
   away for callers that only want the valid subset). *)

let attachment_block_of_meta (a : Board_attachment_meta.t) : attachment_block =
  match a.kind with
  | Board_attachment_meta.Image ->
    Image
      { url = a.origin_url; name = a.origin_name
      ; width = a.width; height = a.height }
  | Board_attachment_meta.Video ->
    Video
      { url = a.origin_url; name = a.origin_name
      ; mime_type = a.mime_type }
  | Board_attachment_meta.Youtube ->
    Youtube { url = a.origin_url; name = a.origin_name }
  | Board_attachment_meta.External_link ->
    External_link { url = a.origin_url; name = a.origin_name }

let attachment_block_of_json (json : Yojson.Safe.t) : block =
  match Board_attachment_meta.of_yojson json with
  | Ok a -> Attachment (attachment_block_of_meta a)
  | Error err ->
    Attachment
      (Invalid_attachment
         { detail = Board_attachment_meta.error_to_string err })

let attachment_blocks_of_meta_json (meta : Yojson.Safe.t option) : block list =
  match meta with
  | Some (`Assoc kvs) ->
    (match List.assoc_opt Board_attachment_meta.meta_json_key kvs with
     | None -> []
     | Some (`List items) -> List.map attachment_block_of_json items
     | Some other ->
       [ Attachment
           (Invalid_attachment
              { detail =
                  Printf.sprintf "meta.%s: expected JSON array (received %s)"
                    Board_attachment_meta.meta_json_key
                    (Json_util.kind_name other)
              })
       ])
  | _ -> []

let document_of_post (post : Board.post) : document =
  let header =
    Header
      { title = post.title
      ; author = Board.Agent_id.to_string post.author
      ; hearth = post.hearth
      }
  in
  let body_blocks =
    if String.equal (String.trim post.body) "" then [] else [ Body post.body ]
  in
  { post_id = Board.Post_id.to_string post.id
  ; blocks = header :: (body_blocks @ attachment_blocks_of_meta_json post.meta_json)
  }

(* Plain-text fallback — the only text formatting this module owns, so every
   surface's fallback rendering stays identical. *)

let name_url name url =
  if String.equal (String.trim name) ""
  then url
  else Printf.sprintf "%s (%s)" name url

let attachment_line = function
  | Image { url; name; _ } -> Printf.sprintf "[image] %s" (name_url name url)
  | Video { url; name; _ } -> Printf.sprintf "[video] %s" (name_url name url)
  | Youtube { url; name } -> Printf.sprintf "[youtube] %s" (name_url name url)
  | External_link { url; name } -> Printf.sprintf "[link] %s" (name_url name url)
  | Invalid_attachment { detail } ->
    Printf.sprintf "[invalid attachment] %s" detail

let header_lines ~title ~author ~hearth =
  let byline =
    match hearth with
    | Some h when not (String.equal (String.trim h) "") ->
      Printf.sprintf "by %s in %s" author h
    | _ -> Printf.sprintf "by %s" author
  in
  [ title; byline ]

let plain_text (doc : document) : string =
  doc.blocks
  |> List.concat_map (fun b ->
    match b with
    | Header { title; author; hearth } -> header_lines ~title ~author ~hearth
    | Body body -> [ body ]
    | Attachment a -> [ attachment_line a ])
  |> String.concat "\n"
