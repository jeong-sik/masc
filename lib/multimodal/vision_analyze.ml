type request =
  { query : string
  ; image_media_type : string
  ; image_bytes : string
  }

let make_request ~query ~image_media_type ~image_bytes =
  if String.length (String.trim query) = 0 then Error "analyze_image: empty query"
  else if String.length image_bytes = 0 then
    Error "analyze_image: empty image bytes"
  else if String.length (String.trim image_media_type) = 0 then
    Error "analyze_image: empty image media type"
  else Ok { query; image_media_type; image_bytes }

type extraction_error =
  | Empty_extraction
  | Truncated_extraction

let string_of_error = function
  | Empty_extraction -> "empty_extraction"
  | Truncated_extraction -> "truncated_extraction"

type done_reason =
  | Stop
  | Length
  | Other of string

let done_reason_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "stop" | "end_turn" -> Stop
  | "length" | "max_tokens" -> Length
  | other -> Other other

let classify ~done_reason ~content =
  let trimmed = String.trim content in
  if String.length trimmed > 0 then Ok trimmed
  else (
    match done_reason with
    | Length -> Error Truncated_extraction
    | Stop | Other _ -> Error Empty_extraction)
