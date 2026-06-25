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

let classify ~truncated ~content =
  let trimmed = String.trim content in
  if String.length trimmed > 0 then Ok trimmed
  else if truncated then Error Truncated_extraction
  else Error Empty_extraction
