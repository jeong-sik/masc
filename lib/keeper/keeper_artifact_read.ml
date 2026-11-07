(* A page must never itself be large enough to spill. An official-client CLI
   writes an oversized tool result to a file under its own session directory,
   which a Keeper cannot open, so a page returned at that size would be an
   unreadable answer to a request for unreadable content — the loop #32748
   closed.

   Both bounds are therefore the narrower of the two lane ceilings, not the
   lane's own. The advertised schema is built once for every Keeper, before a
   turn resolves which runtime executes it, so a page bound that varied by
   lane could not be declared. [config/tools/keeper_artifact_read.toml]
   carries these same numbers as the wire contract and
   [test_keeper_runtime_schemas_toml_parity] pins it against them. *)
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
  | Contains_not_a_string of { kind : string }
  | Contains_empty
  | Contains_too_long of
      { bytes : int
      ; maximum : int
      }
  | Ignore_case_not_a_boolean of { kind : string }
  | Max_matches_invalid of invalid_integer_field
  | Search_field_without_contains of { field : string }
  | Max_bytes_with_contains

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
  | Contains_not_a_string { kind } ->
    Printf.sprintf "contains must be a string, got %s" kind
  | Contains_empty -> "contains must not be empty"
  | Contains_too_long { bytes; maximum } ->
    Printf.sprintf "contains is %d bytes, over the maximum %d" bytes maximum
  | Ignore_case_not_a_boolean { kind } ->
    Printf.sprintf "ignore_case must be a boolean, got %s" kind
  | Max_matches_invalid detail ->
    invalid_integer_field_to_string ~field:"max_matches" detail
  | Search_field_without_contains { field } ->
    Printf.sprintf "%s only applies together with contains" field
  | Max_bytes_with_contains ->
    "max_bytes sets the page size and cannot be combined with contains; a search \
     returns at most max_matches lines"
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
    let open Result.Syntax in
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

let valid_utf8_prefix_length = Keeper_artifact_search.valid_utf8_prefix_length

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

let page_of_slice_within_output_budget ?(envelope = Fun.id) request ~total_bytes requested_bytes =
  let candidate length =
    page_of_slice
      request
      ~total_bytes
      (String.sub requested_bytes 0 length)
  in
  let fits page =
    page |> page_to_json |> envelope |> Yojson.Safe.to_string |> String.length
    <= Common.max_tool_result_wire_bytes
  in
  match candidate 0 with
  | Error _ as error -> error
  | Ok empty_page when not (fits empty_page) ->
    Error "artifact page metadata exceeds the model-output budget"
  | Ok empty_page ->
    let rec search low high best =
      if low > high
      then
        if best.next_offset = best.offset && not best.eof
        then Error "page envelope leaves no room for source bytes"
        else Ok best
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

let page ?envelope (request : request) bytes =
  if request.offset < minimum_offset || request.max_bytes < minimum_max_bytes
     || request.max_bytes > maximum_max_bytes then Error "invalid page bounds"
  else
  let total_bytes = String.length bytes in
  let available = max 0 (total_bytes - request.offset) in
  let requested_length = min request.max_bytes available in
  let requested_bytes =
    if request.offset > total_bytes
    then ""
    else String.sub bytes request.offset requested_length
  in
  page_of_slice_within_output_budget ?envelope request ~total_bytes requested_bytes
;;

(* A search reads the same artifact a page does, but asks where a text occurs
   instead of for its bytes. It is declared after [page] so the record fields
   it shares with [request] and [page] do not change how their code reads. *)
type search =
  { sha256 : string
  ; offset : int
  ; needle : string
  ; ignore_case : bool
  ; max_matches : int
  }

type operation =
  | Read_page of request
  | Search_text of search

let needle_of_json = function
  | `String "" -> Error Contains_empty
  | `String needle ->
    let bytes = String.length needle in
    if bytes > Keeper_artifact_search.maximum_needle_bytes
    then
      Error
        (Contains_too_long { bytes; maximum = Keeper_artifact_search.maximum_needle_bytes })
    else Ok needle
  | other -> Error (Contains_not_a_string { kind = Json_util.kind_name other })
;;

let ignore_case_of_fields fields =
  match List.assoc_opt "ignore_case" fields with
  | None -> Ok false
  | Some (`Bool value) -> Ok value
  | Some other -> Error (Ignore_case_not_a_boolean { kind = Json_util.kind_name other })
;;

let search_of_fields fields ~contains =
  let open Result.Syntax in
  let* () = if List.mem_assoc "max_bytes" fields then Error Max_bytes_with_contains else Ok () in
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
  let* needle = needle_of_json contains in
  let* ignore_case = ignore_case_of_fields fields in
  let* max_matches =
    bounded_integer_of_fields
      fields
      ~field:"max_matches"
      ~default:Keeper_artifact_search.default_max_matches
      ~minimum:Keeper_artifact_search.minimum_max_matches
      ~maximum:Keeper_artifact_search.maximum_max_matches
    |> Result.map_error (fun detail -> Max_matches_invalid detail)
  in
  Ok (Search_text { sha256; offset; needle; ignore_case; max_matches })
;;

(* [contains] makes the request a search. Its companions without it, and
   [max_bytes] with it, are refused by name: a field that is accepted and then
   has no effect would read as an answer to a question it did not ask. *)
let operation_of_json json =
  let page_request () = Result.map (fun request -> Read_page request) (request_of_json json) in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "contains" fields with
     | Some contains -> search_of_fields fields ~contains
     | None ->
       (match
          List.find_opt (fun field -> List.mem_assoc field fields) [ "ignore_case"; "max_matches" ]
        with
        | Some field -> Error (Search_field_without_contains { field })
        | None -> page_request ()))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> page_request ()
;;

(* One line per hit: the byte offset of the line, a tab, the line. The offset
   goes straight into a page read to see what surrounds the hit. A line that
   was cut says how much was cut. *)
let search_hit_line (hit : Keeper_artifact_search.hit) =
  let cut = hit.line_bytes - String.length hit.text in
  if cut > 0
  then Printf.sprintf "%d\t%s …(+%d bytes)" hit.offset hit.text cut
  else Printf.sprintf "%d\t%s" hit.offset hit.text
;;

(* Same fields as a page, so a result that goes through the declared output
   schema reads like one. [match_count] and [skipped_lines] are the additions. *)
let search_to_json
      (search : search)
      ~total_bytes
      ~skipped_lines
      ~next_offset
      (hits : Keeper_artifact_search.hit list)
  =
  `Assoc
    ([ "ok", `Bool true
     ; "sha256", `String search.sha256
     ; "offset", `Int search.offset
     ; "next_offset", `Int next_offset
     ; "total_bytes", `Int total_bytes
     ; "eof", `Bool (next_offset >= total_bytes)
     ; "encoding", `String "utf-8"
     ; "content", `String (String.concat "\n" (List.map search_hit_line hits))
     ; "match_count", `Int (List.length hits)
     ]
     @ (if skipped_lines > 0 then [ "skipped_lines", `Int skipped_lines ] else []))
;;

(* The result must stay under the wire ceiling or it would itself spill into a
   file the Keeper cannot open. When the hits do not fit, the last ones are
   dropped and [next_offset] moves back to the first dropped line, so the next
   call finds it again and nothing is skipped. *)
let search_page (search : search) (outcome : Keeper_artifact_search.outcome) =
  let render kept_count =
    let kept = List.filteri (fun index _ -> index < kept_count) outcome.hits in
    let next_offset =
      match List.nth_opt outcome.hits kept_count with
      | Some (dropped : Keeper_artifact_search.hit) -> dropped.offset
      | None -> outcome.next_offset
    in
    search_to_json
      search
      ~total_bytes:outcome.total_bytes
      ~skipped_lines:outcome.skipped_lines
      ~next_offset
      kept
  in
  let fits json =
    String.length (Yojson.Safe.to_string json) <= Common.max_tool_result_wire_bytes
  in
  let rec fit kept_count =
    let json = render kept_count in
    if fits json
    then Ok json
    else if kept_count = 0
    then Error "search result metadata exceeds the model-output budget"
    else fit (kept_count - 1)
  in
  fit (List.length outcome.hits)
;;

type artifact_read_error =
  | Artifact_missing
  | Storage_failed of Tool_blob_store.fetch_error

(* A stored result's marker carries two hashes, and a caller that passes the
   answer fingerprint finds no artifact (#49396). The refusal names the one
   this tool reads. *)
let artifact_missing_message =
  "artifact does not exist. A stored result's marker names its artifact in \
   sha256=; its answer_sha256= value is an answer fingerprint and names no \
   artifact."

let read_page ~base_path (request : request) =
  let store = Tool_blob_store.create ~base_path in
  match
    Tool_blob_store.fetch_range
      store
      ~sha256:request.sha256
      ~offset:request.offset
      ~max_bytes:request.max_bytes
  with
  | Error error -> storage_failure (Tool_blob_store.fetch_error_to_string error), None
  | Ok None -> invalid_input artifact_missing_message, None
  | Ok (Some { content; total_bytes }) ->
    (match page_of_slice_within_output_budget request ~total_bytes content with
     | Error message -> invalid_input message, None
     | Ok page -> Keeper_tool_execution.success_data (page_to_json page), Some page)
;;

let search_artifact ~base_path (search : search) =
  let store = Tool_blob_store.create ~base_path in
  let read ~offset ~max_bytes =
    match Tool_blob_store.fetch_range store ~sha256:search.sha256 ~offset ~max_bytes with
    | Ok (Some { content; total_bytes }) -> Ok (content, total_bytes)
    | Ok None -> Error Artifact_missing
    | Error error -> Error (Storage_failed error)
  in
  let spec : Keeper_artifact_search.spec =
    { needle = search.needle
    ; ignore_case = search.ignore_case
    ; max_matches = search.max_matches
    ; start = search.offset
    }
  in
  match Keeper_artifact_search.scan ~read spec with
  | Error (Keeper_artifact_search.Read_failed Artifact_missing) ->
    invalid_input artifact_missing_message
  | Error (Keeper_artifact_search.Read_failed (Storage_failed error)) ->
    storage_failure (Tool_blob_store.fetch_error_to_string error)
  | Error (Keeper_artifact_search.Offset_past_end { offset; total_bytes }) ->
    invalid_input
      (Printf.sprintf "offset %d exceeds artifact size %d" offset total_bytes)
  | Error (Keeper_artifact_search.Short_read { offset; total_bytes }) ->
    storage_failure
      (Printf.sprintf "artifact ended early: no bytes at offset %d of %d" offset total_bytes)
  | Ok outcome ->
    (match search_page search outcome with
     | Ok json -> Keeper_tool_execution.success_data json
     | Error message -> invalid_input message)
;;

let handle_with_page ~base_path ~args =
  match operation_of_json args with
  | Error invalid -> invalid_input (invalid_request_to_string invalid), None
  | Ok (Read_page request) -> read_page ~base_path request
  | Ok (Search_text search) -> search_artifact ~base_path search, None
;;

let handle ~base_path ~args = fst (handle_with_page ~base_path ~args)
;;

module For_testing = struct
  let request_of_json = request_of_json
  let operation_of_json = operation_of_json
  let page request bytes = page request bytes
  let page_to_json = page_to_json
  let search_page = search_page
end
