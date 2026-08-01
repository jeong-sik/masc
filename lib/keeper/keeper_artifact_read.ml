let default_max_bytes = Common.max_tool_output_bytes
let maximum_max_bytes = Common.max_tool_output_bytes
let minimum_max_bytes = 1

type request =
  { sha256 : string
  ; offset : int
  ; max_bytes : int
  }

type page_encoding =
  | Utf_8
  | Base64

type page =
  { sha256 : string
  ; offset : int
  ; next_offset : int
  ; total_bytes : int
  ; eof : bool
  ; encoding : page_encoding
  ; content : string
  }

let request_of_json = function
  | `Assoc fields ->
    let sha256 =
      match List.assoc_opt "sha256" fields with
      | Some (`String value) -> Some value
      | _ -> None
    in
    let offset =
      match List.assoc_opt "offset" fields with
      | None -> Some 0
      | Some (`Int value) -> Some value
      | _ -> None
    in
    let max_bytes =
      match List.assoc_opt "max_bytes" fields with
      | None -> Some default_max_bytes
      | Some (`Int value) -> Some value
      | _ -> None
    in
    (match sha256, offset, max_bytes with
     | Some sha256, Some offset, Some max_bytes
       when offset >= 0
            && max_bytes >= minimum_max_bytes
            && max_bytes <= maximum_max_bytes ->
       (match Tool_output.validate_sha256 sha256 with
        | Ok () -> Ok { sha256; offset; max_bytes }
        | Error invalid ->
          Error (Tool_output.invalid_sha256_to_string invalid))
     | _ ->
       Error
         (Printf.sprintf
            "expected sha256, non-negative offset, and max_bytes %d..%d"
            minimum_max_bytes
            maximum_max_bytes))
  | _ -> Error "expected an object"
;;

let invalid_input message =
  Keeper_tool_execution.failure
    ~class_:Tool_result.Policy_rejection
    (Yojson.Safe.to_string
       (`Assoc
          [ "ok", `Bool false
          ; "error", `String "invalid_artifact_read"
          ; "message", `String message
          ]))
;;

let storage_failure message =
  Keeper_tool_execution.failure
    ~class_:Tool_result.Runtime_failure
    (Yojson.Safe.to_string
       (`Assoc
          [ "ok", `Bool false
          ; "error", `String "artifact_read_failed"
          ; "message", `String message
          ]))
;;

let valid_utf8_prefix_length source =
  let source_length = String.length source in
  let rec loop index =
    if index = source_length
    then index
    else
      let decoded = String.get_utf_8_uchar source index in
      let decoded_length = Uchar.utf_decode_length decoded in
      if decoded_length > 0 && Uchar.utf_decode_is_valid decoded
      then loop (index + decoded_length)
      else index
  in
  loop 0
;;

let page_of_slice (request : request) ~total_bytes requested_bytes =
  if request.offset > total_bytes
  then
    Error
      (Printf.sprintf
         "offset %d exceeds artifact size %d"
         request.offset
         total_bytes)
  else
    let requested_length = String.length requested_bytes in
    let utf8_prefix_length = valid_utf8_prefix_length requested_bytes in
    let consumed_bytes, encoding, content =
      if requested_length = 0
      then 0, Utf_8, ""
      else if utf8_prefix_length > 0
      then
        ( utf8_prefix_length
        , Utf_8
        , String.sub requested_bytes 0 utf8_prefix_length )
      else requested_length, Base64, Base64.encode_string requested_bytes
    in
    let next_offset = request.offset + consumed_bytes in
    Ok
      { sha256 = request.sha256
      ; offset = request.offset
      ; next_offset
      ; total_bytes
      ; eof = next_offset = total_bytes
      ; encoding
      ; content
      }
;;

let page_to_json page =
  `Assoc
    [ "ok", `Bool true
    ; "sha256", `String page.sha256
    ; "offset", `Int page.offset
    ; "next_offset", `Int page.next_offset
    ; "total_bytes", `Int page.total_bytes
    ; "eof", `Bool page.eof
    ; ( "encoding"
      , `String
          (match page.encoding with
           | Utf_8 -> "utf-8"
           | Base64 -> "base64") )
    ; "content", `String page.content
    ]
;;

let page_of_slice_within_output_budget request ~total_bytes requested_bytes =
  let candidate length =
    page_of_slice
      request
      ~total_bytes
      (String.sub requested_bytes 0 length)
  in
  let fits page =
    page |> page_to_json |> Yojson.Safe.to_string |> String.length
    <= Common.max_tool_output_bytes
  in
  match candidate 0 with
  | Error _ as error -> error
  | Ok empty_page when not (fits empty_page) ->
    Error "artifact page metadata exceeds the model-output budget"
  | Ok empty_page ->
    let rec search low high best =
      if low > high
      then Ok best
      else
        let midpoint = low + ((high - low) / 2) in
        match candidate midpoint with
        | Error _ as error -> error
        | Ok page ->
          if fits page
          then search (midpoint + 1) high page
          else search low (midpoint - 1) best
    in
    search 1 (String.length requested_bytes) empty_page
;;

let page (request : request) bytes =
  let total_bytes = String.length bytes in
  let available = max 0 (total_bytes - request.offset) in
  let requested_length = min request.max_bytes available in
  let requested_bytes =
    if request.offset > total_bytes
    then ""
    else String.sub bytes request.offset requested_length
  in
  page_of_slice_within_output_budget request ~total_bytes requested_bytes
;;

let handle ~base_path ~args =
  match request_of_json args with
  | Error message -> invalid_input message
  | Ok request ->
    let store = Tool_blob_store.create ~base_path in
    (match
       Tool_blob_store.fetch_range
         store
         ~sha256:request.sha256
         ~offset:request.offset
         ~max_bytes:request.max_bytes
     with
     | Error error ->
       storage_failure (Tool_blob_store.fetch_error_to_string error)
     | Ok None -> invalid_input "artifact does not exist"
     | Ok (Some { content; total_bytes }) ->
       (match page_of_slice_within_output_budget request ~total_bytes content with
        | Error message -> invalid_input message
        | Ok page -> Keeper_tool_execution.success_data (page_to_json page)))
;;

module For_testing = struct
  let request_of_json = request_of_json
  let page = page
  let page_to_json = page_to_json
end
