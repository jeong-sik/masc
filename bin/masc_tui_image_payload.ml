type format = Svg | General_image
type t = { format : format; encoded : string }

let format_of_mime mime =
  match String.split_on_char ';' (String.lowercase_ascii (String.trim mime)) with
  | essence :: _ when String.equal (String.trim essence) "image/svg+xml" -> Svg
  | _ -> General_image

let of_base64 ~mime_type encoded = {format=format_of_mime mime_type;encoded}
let format payload = payload.format
let encoded payload = payload.encoded

let data_header source =
  match String.index_opt source ':', String.index_opt source ',' with
  | Some colon, Some comma when colon < comma ->
    let scheme = String.sub source 0 colon |> String.lowercase_ascii in
    let header = String.sub source (colon + 1) (comma - colon - 1) in
    (match scheme, String.split_on_char ';' header with
     | "data", mime :: parameters ->
       (match List.rev parameters with
        | "base64" :: _ -> Ok (mime, comma)
        | _ -> Error "image data URI is not base64")
     | _ -> Error "image source is not a data URI")
  | _ -> Error "invalid image data URI"

let of_data_uri encoded =
  Result.bind (data_header encoded) (fun (mime, _) ->
    match String.split_on_char '/' (String.lowercase_ascii (String.trim mime)) with
    | ["image";subtype] when subtype <> "" -> Ok {format=format_of_mime mime;encoded}
    | _ -> Error "data URI is not an image")

let decode_wire encoded =
  let encoded = String.trim encoded in
  let body = match String.index_opt encoded ':' with
    | None -> Ok encoded
    | Some _ -> Result.map (fun (_, comma) ->
        String.sub encoded (comma + 1) (String.length encoded - comma - 1))
        (data_header encoded) in
  Result.bind body (fun body ->
    Result.map_error (fun (`Msg detail) -> detail) (Base64.decode body))

let decode payload = decode_wire payload.encoded
