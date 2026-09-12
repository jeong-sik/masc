type verdict =
  | Cached_image of { media_type : string }
  | Not_an_image of { reason : string }

let verdict_of_bytes bytes =
  match Masc.Keeper_vision_tool.sniff_image_media_type bytes with
  | Ok media_type -> Cached_image { media_type }
  | Error reason -> Not_an_image { reason }

type download_error =
  | Download_failed of string
  | Body_not_an_image of { reason : string }

let download_error_text = function
  | Download_failed detail -> detail
  | Body_not_an_image { reason } ->
      Printf.sprintf "the URL did not answer with an image: %s" reason
