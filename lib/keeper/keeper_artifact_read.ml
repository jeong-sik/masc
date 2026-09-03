let default_max_bytes = Common.max_tool_result_wire_bytes
let maximum_max_bytes = Common.max_tool_result_wire_bytes
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

let minimum_offset = 0

(** Why an integer-typed request field could not be read. [Yojson.Safe]
    parses an integer literal that does not fit a native [int] into
    [`Intlit], which this parser has always rejected — naming that case
    keeps it distinguishable from "not an integer at all". *)
type invalid_integer_field =
  | Not_an_integer of { kind : string }
  | Literal_out_of_int_range of { literal : string }
  | Literal_not_a_json_integer of { literal : string }
  | Below_minimum of
      { value : int
      ; minimum : int
      }
  | Above_maximum of
      { value : int
      ; maximum : int
      }

(** Which field of an artifact-read request failed, and why. Every
    rejection carries its own field so the caller is never told to fix
    [sha256] when [sha256] was correct. *)
type invalid_request =
  | Not_an_object of { kind : string }
  | Sha256_missing
  | Sha256_not_a_string of { kind : string }
  | Sha256_malformed of Tool_output.invalid_sha256
  | Offset_invalid of invalid_integer_field
  | Max_bytes_invalid of invalid_integer_field

let invalid_integer_field_to_string ~field = function
  | Not_an_integer { kind } ->
    Printf.sprintf "%s must be an integer, got %s" field kind
  | Literal_out_of_int_range { literal } ->
    Printf.sprintf
      "%s integer literal %s is outside the native integer range"
      field
      literal
  | Literal_not_a_json_integer { literal } ->
    Printf.sprintf
      "%s must be a JSON integer, got the unparsed integer literal %s"
      field
      literal
  | Below_minimum { value; minimum } ->
    Printf.sprintf "%s %d is below minimum %d" field value minimum
  | Above_maximum { value; maximum } ->
    Printf.sprintf "%s %d exceeds maximum %d" field value maximum
;;

let invalid_request_to_string = function
  | Not_an_object { kind } -> Printf.sprintf "expected an object, got %s" kind
  | Sha256_missing -> "sha256 is required"
  | Sha256_not_a_string { kind } ->
    Printf.sprintf "sha256 must be a string, got %s" kind
  | Sha256_malformed invalid ->
    Printf.sprintf
      "sha256 is malformed: %s"
      (Tool_output.invalid_sha256_to_string invalid)
  | Offset_invalid detail -> invalid_integer_field_to_string ~field:"offset" detail
  | Max_bytes_invalid detail ->
    invalid_integer_field_to_string ~field:"max_bytes" detail
;;

let sha256_of_fields fields =
  match List.assoc_opt "sha256" fields with
  | None -> Error Sha256_missing
  | Some (`String value) ->
    (match Tool_output.validate_sha256 value with
     | Ok () -> Ok value
     | Error invalid -> Error (Sha256_malformed invalid))
  | Some other -> Error (Sha256_not_a_string { kind = Json_util.kind_name other })
;;

(** Read one bounded integer field. [`Intlit] is matched explicitly rather
    than swept into a wildcard: it is a distinct condition (an integer the
    wire carried but OCaml cannot hold natively), and it stays rejected. *)
let bounded_integer_of_fields fields ~field ~default ~minimum ~maximum =
  let bounded value =
    if value < minimum
    then Error (Below_minimum { value; minimum })
    else if value > maximum
    then Error (Above_maximum { value; maximum })
    else Ok value
  in
  match List.assoc_opt field fields with
  | None -> Ok default
  | Some (`Int value) -> bounded value
  | Some (`Intlit literal) ->
    (match int_of_string_opt literal with
     | None -> Error (Literal_out_of_int_range { literal })
     | Some _ -> Error (Literal_not_a_json_integer { literal }))
  | Some other -> Error (Not_an_integer { kind = Json_util.kind_name other })
;;

let request_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* sha256 = sha256_of_fields fields in
    let* offset =
      bounded_integer_of_fields
        fields
        ~field:"offset"
        ~default:minimum_offset
        ~minimum:minimum_offset
        ~maximum:max_int
      |> Result.map_error (fun detail -> Offset_invalid detail)
    in
    let* max_bytes =
      bounded_integer_of_fields
        fields
        ~field:"max_bytes"
        ~default:default_max_bytes
        ~minimum:minimum_max_bytes
        ~maximum:maximum_max_bytes
      |> Result.map_error (fun detail -> Max_bytes_invalid detail)
    in
    Ok { sha256; offset; max_bytes }
  | other -> Error (Not_an_object { kind = Json_util.kind_name other })
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
    <= Common.max_tool_result_wire_bytes
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
  | Error invalid -> invalid_input (invalid_request_to_string invalid)
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
