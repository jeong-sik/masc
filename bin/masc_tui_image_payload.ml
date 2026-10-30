type format = Svg | General_image
type t = { format : format; encoded : string }

let format_of_mime mime =
  match String.split_on_char ';' (String.lowercase_ascii (String.trim mime)) with
  | essence :: _ when String.equal (String.trim essence) "image/svg+xml" -> Svg
  | _ -> General_image

let of_base64 ~mime_type encoded = {format=format_of_mime mime_type;encoded}
let format payload = payload.format
let encoded payload = payload.encoded

type encoding = Base64 | Percent_encoded

let data_header source =
  let source = match String.index_opt source '#' with
    | Some fragment -> String.sub source 0 fragment
    | None -> source in
  match String.index_opt source ':', String.index_opt source ',' with
  | Some colon, Some comma when colon < comma ->
    let scheme = String.sub source 0 colon |> String.lowercase_ascii in
    let header = String.sub source (colon + 1) (comma - colon - 1) in
    (match scheme, String.split_on_char ';' header with
     | "data", mime :: parameters ->
       let encoding = match List.rev parameters with
         | marker :: _ when String.equal
             (String.lowercase_ascii (String.trim marker)) "base64" -> Base64
         | _ -> Percent_encoded in
       let body = String.sub source (comma + 1) (String.length source - comma - 1) in
       Ok (mime, encoding, body)
     | _ -> Error "image source is not a data URI")
  | _ -> Error "invalid image data URI"

let of_data_uri encoded =
  Result.bind (data_header encoded) (fun (mime, _, _) ->
    match String.split_on_char '/' (String.lowercase_ascii (String.trim mime)) with
    | ["image";subtype] when subtype <> "" -> Ok {format=format_of_mime mime;encoded}
    | _ -> Error "data URI is not an image")

let decode_wire encoded =
  let encoded = String.trim encoded in
  let decode_base64 body = Result.map_error (fun (`Msg detail) -> detail) (Base64.decode body) in
  match String.index_opt encoded ':' with
  | None -> decode_base64 encoded
  | Some _ -> Result.bind (data_header encoded) (fun (_, encoding, body) ->
    let body = Uri.pct_decode body in
    match encoding with
    | Base64 -> decode_base64 body
    | Percent_encoded -> Ok body)

let decode payload = decode_wire payload.encoded
