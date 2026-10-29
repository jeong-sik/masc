module P = Llm_provider.Types

(* ================================================================ *)
(* Stored media reference                                           *)
(* ================================================================ *)

type stored =
  { sha256 : string
  ; bytes : int
  }
[@@deriving show]

type stored_error =
  | Sha256_not_lowercase_hex of string
  | Negative_byte_count of int
[@@deriving show]

let sha256_hex_length = 64

let is_lowercase_hex_digit = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false
;;

let stored ~sha256 ~bytes =
  if String.length sha256 <> sha256_hex_length
     || not (String.for_all is_lowercase_hex_digit sha256)
  then Error (Sha256_not_lowercase_hex sha256)
  else if bytes < 0
  then Error (Negative_byte_count bytes)
  else Ok { sha256; bytes }
;;

let stored_error_to_string = function
  | Sha256_not_lowercase_hex sha256 ->
    Printf.sprintf "sha256 %S is not 64 lowercase hex characters" sha256
  | Negative_byte_count bytes -> Printf.sprintf "byte count %d is negative" bytes
;;

let stored_of_raw raw =
  { sha256 = Agent_core_sha256.to_hex (Agent_core_sha256.digest_string raw)
  ; bytes = String.length raw
  }
;;

let stored_equal left right =
  String.equal left.sha256 right.sha256 && Int.equal left.bytes right.bytes
;;

(* ================================================================ *)
(* Content                                                          *)
(* ================================================================ *)

type media_source =
  | Stored of stored
  | Url of string
  | File_id of string
[@@deriving show]

(* The provider's block and message over this source: one constructor set. *)
type content_block = media_source P.content_block_with [@@deriving show]
type message = media_source P.message_with [@@deriving show]

(* ================================================================ *)
(* Media store                                                      *)
(* ================================================================ *)

type media_error =
  | Store_failed of { detail : string }
  | Missing_bytes of stored
  | Invalid_base64 of
      { media_type : string
      ; detail : string
      }
  | Digest_mismatch of
      { expected : stored
      ; actual : stored
      }
[@@deriving show]

type media_store =
  { put : media_type:string -> raw:string -> (stored, media_error) result
  ; get : stored -> (string, media_error) result
  }

(* ================================================================ *)
(* Provider conversions                                             *)
(* ================================================================ *)

let map_list f items =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      (match f item with
       | Ok value -> loop (value :: acc) rest
       | Error _ as error -> error)
  in
  loop [] items
;;

let map_option f = function
  | None -> Ok None
  | Some value -> Result.map Option.some (f value)
;;

let source_of_wire store ~media_type (source : P.media_source) =
  match source with
  | P.Base64 encoded ->
    (match Base64.decode encoded with
     | Ok raw -> Result.map (fun stored -> Stored stored) (store.put ~media_type ~raw)
     | Error (`Msg detail) -> Error (Invalid_base64 { media_type; detail }))
  | P.Url url -> Ok (Url url)
  | P.File_id file_id -> Ok (File_id file_id)
;;

let source_to_wire store = function
  | Stored stored ->
    Result.map (fun raw -> P.Base64 (Base64.encode_string raw)) (store.get stored)
  | Url url -> Ok (P.Url url)
  | File_id file_id -> Ok (P.File_id file_id)
;;

(* [block] with each media source replaced by [f ~media_type source], ToolResult
   [content_blocks] included, left to right, stopping at the first error. The
   two conversions below are this traversal with the two source maps. *)
let rec map_block_sources f (block : _ P.content_block_with) =
  let open Result_syntax in
  match block with
  | P.Text text -> Ok (P.Text text)
  | P.Thinking { content; signature } -> Ok (P.Thinking { content; signature })
  | P.ReasoningDetails { reasoning_content; details } ->
    Ok (P.ReasoningDetails { reasoning_content; details })
  | P.RedactedThinking data -> Ok (P.RedactedThinking data)
  | P.ToolUse { id; name; input } -> Ok (P.ToolUse { id; name; input })
  | P.ToolResult { tool_use_id; content; outcome; json; content_blocks } ->
    let+ content_blocks = map_option (map_list (map_block_sources f)) content_blocks in
    P.ToolResult { tool_use_id; content; outcome; json; content_blocks }
  | P.Image { media_type; source } ->
    let+ source = f ~media_type source in
    P.Image { media_type; source }
  | P.Document { media_type; source } ->
    let+ source = f ~media_type source in
    P.Document { media_type; source }
  | P.Audio { media_type; source } ->
    let+ source = f ~media_type source in
    P.Audio { media_type; source }
;;

let map_message_sources f (message : _ P.message_with) =
  Result.map
    (fun content -> { message with P.content })
    (map_list (map_block_sources f) message.content)
;;

let of_wire_block store block = map_block_sources (source_of_wire store) block
let to_wire_block store block = map_block_sources (fun ~media_type:_ -> source_to_wire store) block
let of_wire_message store message = map_message_sources (source_of_wire store) message

let to_wire_message store message =
  map_message_sources (fun ~media_type:_ -> source_to_wire store) message
;;

let of_wire_blocks store blocks = map_list (of_wire_block store) blocks
let to_wire_blocks store blocks = map_list (to_wire_block store) blocks
let to_wire_messages store messages = map_list (to_wire_message store) messages

(* ================================================================ *)
(* Byte accounting                                                  *)
(* ================================================================ *)

let media_source_bytes = function
  | Stored { bytes; _ } -> bytes
  | Url payload | File_id payload -> String.length payload
;;

let media_source_wire_length = function
  | Stored { bytes; _ } -> 4 * ((bytes + 2) / 3)
  | Url payload | File_id payload -> String.length payload
;;

let rec media_bytes = function
  | P.Image { source; _ } | P.Document { source; _ } | P.Audio { source; _ } ->
    media_source_bytes source
  | P.ToolResult { content_blocks = Some blocks; _ } ->
    List.fold_left (fun total block -> total + media_bytes block) 0 blocks
  | P.ToolResult { content_blocks = None; _ }
  | P.Text _
  | P.Thinking _
  | P.ReasoningDetails _
  | P.RedactedThinking _
  | P.ToolUse _ -> 0
;;

let rec media_wire_length = function
  | P.Image { source; _ } | P.Document { source; _ } | P.Audio { source; _ } ->
    media_source_wire_length source
  | P.ToolResult { content_blocks = Some blocks; _ } ->
    List.fold_left (fun total block -> total + media_wire_length block) 0 blocks
  | P.ToolResult { content_blocks = None; _ }
  | P.Text _
  | P.Thinking _
  | P.ReasoningDetails _
  | P.RedactedThinking _
  | P.ToolUse _ -> 0
;;

(* ================================================================ *)
(* JSON encoding                                                    *)
(* ================================================================ *)

let stored_source_tag = "stored"

let stored_media_json ~block_type ~media_type { sha256; bytes } =
  `Assoc
    [ "type", `String block_type
    ; ( "source"
      , `Assoc
          [ "type", `String stored_source_tag
          ; "media_type", `String media_type
          ; "sha256", `String sha256
          ; "bytes", `Int bytes
          ] )
    ]
;;

(* [Url] and [File_id] go through the provider encoder so their bytes stay
   the provider's; only [Stored] has a shape of its own. *)
let media_json ~block_type ~media_type ~wire_block = function
  | Stored stored -> stored_media_json ~block_type ~media_type stored
  | Url url -> Llm_provider.Api_common.content_block_to_json (wire_block (P.Url url))
  | File_id file_id ->
    Llm_provider.Api_common.content_block_to_json (wire_block (P.File_id file_id))
;;

let tool_result_provenance_fields = function
  | P.Tool_succeeded -> []
  | P.Tool_failed { failure_kind; error_class } ->
    ("failure_kind", P.tool_failure_kind_to_yojson failure_kind)
    ::
    (match error_class with
     | Some error_class -> [ "error_class", P.tool_error_class_to_yojson error_class ]
     | None -> [])
;;

let rec content_block_to_json block =
  let wire = Llm_provider.Api_common.content_block_to_json in
  match block with
  | P.Text text -> wire (P.Text text)
  | P.Thinking { content; signature } -> wire (P.Thinking { content; signature })
  | P.ReasoningDetails { reasoning_content; details } ->
    wire (P.ReasoningDetails { reasoning_content; details })
  | P.RedactedThinking data -> wire (P.RedactedThinking data)
  | P.ToolUse { id; name; input } -> wire (P.ToolUse { id; name; input })
  | P.ToolResult { tool_use_id; content; outcome; json = _; content_blocks } ->
    (* Field order of the journal codec's ToolResult: the provider fields,
       then provenance, then [text_content] when [content] is an array. *)
    let wire_fields =
      Llm_provider.Api_common.tool_result_wire_fields ~tool_use_id ~content ~outcome
    in
    let fields, text_content_fields =
      match content_blocks with
      | None -> wire_fields, []
      | Some blocks ->
        let blocks_json = `List (List.map content_block_to_json blocks) in
        ( List.map
            (fun (field, value) ->
               if String.equal field "content" then field, blocks_json else field, value)
            wire_fields
        , [ "text_content", `String content ] )
    in
    `Assoc (fields @ tool_result_provenance_fields outcome @ text_content_fields)
  | P.Image { media_type; source } ->
    media_json ~block_type:"image" ~media_type source ~wire_block:(fun source ->
      P.Image { media_type; source })
  | P.Document { media_type; source } ->
    media_json ~block_type:"document" ~media_type source ~wire_block:(fun source ->
      P.Document { media_type; source })
  | P.Audio { media_type; source } ->
    media_json ~block_type:"audio" ~media_type source ~wire_block:(fun source ->
      P.Audio { media_type; source })
;;

let message_to_json message =
  let { P.role; origin; content; name; tool_call_id; metadata } = message in
  let optional_fields =
    (match name with
     | Some name -> [ "name", `String name ]
     | None -> [])
    @ (match tool_call_id with
       | Some tool_call_id -> [ "tool_call_id", `String tool_call_id ]
       | None -> [])
    @
    match metadata with
    | [] -> []
    | _ :: _ -> [ "metadata", `Assoc metadata ]
  in
  `Assoc
    ([ "role", `String (P.role_to_string role)
     ; "origin", `String (P.message_origin_to_string origin)
     ; "content", `List (List.map content_block_to_json content)
     ]
     @ optional_fields)
;;

(* ================================================================ *)
(* JSON decoding                                                    *)
(* ================================================================ *)

type json_expectation =
  | Json_object
  | Json_array
  | Json_string
  | Json_string_or_array
  | Json_bool
  | Json_int
  | Json_non_blank_string
[@@deriving show]

type tool_result_problem =
  | Failure_without_kind
  | Error_class_without_kind
  | Success_with_provenance
  | Text_content_with_string_content
[@@deriving show]

type decode_error =
  | Wrong_json_kind of
      { at : string
      ; expected : json_expectation
      }
  | Missing_field of
      { at : string
      ; field : string
      }
  | Unknown_field of
      { at : string
      ; field : string
      }
  | Duplicate_field of
      { at : string
      ; field : string
      }
  | Unknown_block_type of
      { at : string
      ; block_type : string
      }
  | Base64_source of { at : string }
  | Unknown_source_type of
      { at : string
      ; source_type : string
      }
  | Invalid_stored of
      { at : string
      ; error : stored_error
      }
  | Unknown_failure_kind of { at : string }
  | Unknown_error_class of { at : string }
  | Unknown_role of
      { at : string
      ; role : string
      }
  | Unknown_origin of
      { at : string
      ; origin : string
      }
  | Inconsistent_tool_result of
      { at : string
      ; problem : tool_result_problem
      }
  | Empty_metadata of { at : string }
[@@deriving show]

let json_expectation_to_string = function
  | Json_object -> "an object"
  | Json_array -> "an array"
  | Json_string -> "a string"
  | Json_string_or_array -> "a string or an array"
  | Json_bool -> "a boolean"
  | Json_int -> "an integer"
  | Json_non_blank_string -> "a non-blank string"
;;

let tool_result_problem_to_string = function
  | Failure_without_kind -> "is_error is true without failure_kind"
  | Error_class_without_kind -> "error_class without failure_kind"
  | Success_with_provenance -> "failure provenance on a successful result"
  | Text_content_with_string_content -> "text_content with string content"
;;

let decode_error_to_string = function
  | Wrong_json_kind { at; expected } ->
    Printf.sprintf "%s must be %s" at (json_expectation_to_string expected)
  | Missing_field { at; field } -> Printf.sprintf "%s has no field %s" at field
  | Unknown_field { at; field } -> Printf.sprintf "%s has unknown field %s" at field
  | Duplicate_field { at; field } -> Printf.sprintf "%s has field %s twice" at field
  | Unknown_block_type { at; block_type } ->
    Printf.sprintf "%s has unknown block type %S" at block_type
  | Base64_source { at } -> Printf.sprintf "%s is a base64 source; history holds media by reference" at
  | Unknown_source_type { at; source_type } ->
    Printf.sprintf "%s has unknown source type %S" at source_type
  | Invalid_stored { at; error } -> Printf.sprintf "%s: %s" at (stored_error_to_string error)
  | Unknown_failure_kind { at } -> Printf.sprintf "%s has an unknown failure_kind" at
  | Unknown_error_class { at } -> Printf.sprintf "%s has an unknown error_class" at
  | Unknown_role { at; role } -> Printf.sprintf "%s has unknown role %S" at role
  | Unknown_origin { at; origin } -> Printf.sprintf "%s has unknown origin %S" at origin
  | Inconsistent_tool_result { at; problem } ->
    Printf.sprintf "%s: %s" at (tool_result_problem_to_string problem)
  | Empty_metadata { at } -> Printf.sprintf "%s has empty metadata" at
;;

let root_path = "$"
let field_path at field = at ^ "." ^ field
let index_path at index = Printf.sprintf "%s[%d]" at index

let wrong_kind ~at expected = Error (Wrong_json_kind { at; expected })

let map_indexed ~at f items =
  let rec loop index acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      (match f ~at:(index_path at index) item with
       | Ok value -> loop (index + 1) (value :: acc) rest
       | Error _ as error -> error)
  in
  loop 0 [] items
;;

let find_duplicate names =
  let rec scan = function
    | first :: (second :: _ as rest) ->
      if String.equal first second then Some first else scan rest
    | [ _ ] | [] -> None
  in
  scan (List.sort String.compare names)
;;

(* The members of an object whose keys are unique. *)
let unique_object ~at (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match find_duplicate (List.map fst fields) with
     | Some field -> Error (Duplicate_field { at; field })
     | None -> Ok fields)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    wrong_kind ~at Json_object
;;

(* [fields] hold exactly [required] plus any of [optional]. *)
let exact_fields ~at ~required ~optional fields =
  match
    List.find_opt
      (fun (field, _) -> not (List.mem field required || List.mem field optional))
      fields
  with
  | Some (field, _) -> Error (Unknown_field { at; field })
  | None ->
    (match List.find_opt (fun field -> not (List.mem_assoc field fields)) required with
     | Some field -> Error (Missing_field { at; field })
     | None -> Ok ())
;;

let required ~at field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Missing_field { at; field })
;;

let string_value ~at (json : Yojson.Safe.t) =
  match json with
  | `String value -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    wrong_kind ~at Json_string
;;

let required_string ~at field fields =
  Result.bind (required ~at field fields) (string_value ~at:(field_path at field))
;;

let optional_string ~at field fields =
  map_option (string_value ~at:(field_path at field)) (List.assoc_opt field fields)
;;

let required_identifier ~at field fields =
  let open Result_syntax in
  let* value = required_string ~at field fields in
  if String.trim value = ""
  then wrong_kind ~at:(field_path at field) Json_non_blank_string
  else Ok value
;;

let required_bool ~at field fields =
  let open Result_syntax in
  let* value = required ~at field fields in
  match value with
  | `Bool value -> Ok value
  | `Null | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
    wrong_kind ~at:(field_path at field) Json_bool
;;

let required_int ~at field fields =
  let open Result_syntax in
  let* value = required ~at field fields in
  match value with
  | `Int value -> Ok value
  | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
    wrong_kind ~at:(field_path at field) Json_int
;;

let required_array ~at field fields =
  let open Result_syntax in
  let* value = required ~at field fields in
  match value with
  | `List items -> Ok items
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
    wrong_kind ~at:(field_path at field) Json_array
;;

(* The provider decoder derives [text] from the raw detail the same way: a
   non-blank string [text] member, otherwise [None]. *)
let reasoning_detail_of_json ~at json =
  let open Result_syntax in
  let* fields = unique_object ~at json in
  let+ text =
    match List.assoc_opt "text" fields with
    | None | Some `Null -> Ok None
    | Some (`String text) -> Ok (if String.trim text = "" then None else Some text)
    | Some (`Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) ->
      wrong_kind ~at:(field_path at "text") Json_string
  in
  { P.raw = json; text }
;;

let reference_source_of_fields ~at ~make fields =
  let open Result_syntax in
  let* () =
    exact_fields ~at ~required:[ "type"; "media_type"; "data" ] ~optional:[] fields
  in
  let* media_type = required_string ~at "media_type" fields in
  let+ data = required_string ~at "data" fields in
  media_type, make data
;;

let stored_source_of_fields ~at fields =
  let open Result_syntax in
  let* () =
    exact_fields
      ~at
      ~required:[ "type"; "media_type"; "sha256"; "bytes" ]
      ~optional:[]
      fields
  in
  let* media_type = required_string ~at "media_type" fields in
  let* sha256 = required_string ~at "sha256" fields in
  let* bytes = required_int ~at "bytes" fields in
  match stored ~sha256 ~bytes with
  | Ok stored -> Ok (media_type, stored)
  | Error error -> Error (Invalid_stored { at; error })
;;

let media_source_of_json ~at json =
  let open Result_syntax in
  let* fields = unique_object ~at json in
  let* source_type = required_string ~at "type" fields in
  match source_type with
  | "stored" ->
    let+ media_type, stored = stored_source_of_fields ~at fields in
    media_type, Stored stored
  | "url" -> reference_source_of_fields ~at ~make:(fun url -> Url url) fields
  | "file_id" ->
    reference_source_of_fields ~at ~make:(fun file_id -> File_id file_id) fields
  | "base64" -> Error (Base64_source { at })
  | source_type -> Error (Unknown_source_type { at; source_type })
;;

let media_block_of_fields ~at ~make fields =
  let open Result_syntax in
  let* () = exact_fields ~at ~required:[ "type"; "source" ] ~optional:[] fields in
  let* source_json = required ~at "source" fields in
  let+ media_type, source =
    media_source_of_json ~at:(field_path at "source") source_json
  in
  make ~media_type ~source
;;

let optional_typed ~at field fields ~decode ~error =
  match List.assoc_opt field fields with
  | None -> Ok None
  | Some value ->
    (match decode value with
     | Ok value -> Ok (Some value)
     | Error (_ : string) -> Error (error ~at:(field_path at field)))
;;

let tool_result_outcome_of_fields ~at fields =
  let open Result_syntax in
  let* is_error = required_bool ~at "is_error" fields in
  let* failure_kind =
    optional_typed
      ~at
      "failure_kind"
      fields
      ~decode:P.tool_failure_kind_of_yojson
      ~error:(fun ~at -> Unknown_failure_kind { at })
  in
  let* error_class =
    optional_typed
      ~at
      "error_class"
      fields
      ~decode:P.tool_error_class_of_yojson
      ~error:(fun ~at -> Unknown_error_class { at })
  in
  let inconsistent problem = Error (Inconsistent_tool_result { at; problem }) in
  match is_error, failure_kind, error_class with
  | true, Some failure_kind, error_class ->
    Ok (P.Tool_failed { failure_kind; error_class })
  | true, None, None -> inconsistent Failure_without_kind
  | true, None, Some _ -> inconsistent Error_class_without_kind
  | false, None, None -> Ok P.Tool_succeeded
  | false, Some _, (Some _ | None) | false, None, Some _ ->
    inconsistent Success_with_provenance
;;

let rec content_block_of_json_at ~at json =
  let open Result_syntax in
  let* fields = unique_object ~at json in
  let* block_type = required_string ~at "type" fields in
  let exact ~required ~optional = exact_fields ~at ~required ~optional fields in
  match block_type with
  | "text" ->
    let* () = exact ~required:[ "type"; "text" ] ~optional:[] in
    let+ text = required_string ~at "text" fields in
    P.Text text
  | "thinking" ->
    let* () = exact ~required:[ "type"; "thinking" ] ~optional:[ "signature" ] in
    let* content = required_string ~at "thinking" fields in
    let+ signature = optional_string ~at "signature" fields in
    P.Thinking { content; signature }
  | "reasoning_details" ->
    let* () = exact ~required:[ "type"; "details" ] ~optional:[ "reasoning_content" ] in
    let* details = required_array ~at "details" fields in
    let* details =
      map_indexed ~at:(field_path at "details") reasoning_detail_of_json details
    in
    let+ reasoning_content = optional_string ~at "reasoning_content" fields in
    P.ReasoningDetails { reasoning_content; details }
  | "redacted_thinking" ->
    let* () = exact ~required:[ "type"; "data" ] ~optional:[] in
    let+ data = required_string ~at "data" fields in
    P.RedactedThinking data
  | "tool_use" ->
    let* () = exact ~required:[ "type"; "id"; "name"; "input" ] ~optional:[] in
    let* id = required_identifier ~at "id" fields in
    let* name = required_identifier ~at "name" fields in
    let+ input = required ~at "input" fields in
    P.ToolUse { id; name; input }
  | "tool_result" ->
    let* () =
      exact
        ~required:[ "type"; "tool_use_id"; "content"; "is_error" ]
        ~optional:[ "failure_kind"; "error_class"; "text_content" ]
    in
    let* tool_use_id = required_identifier ~at "tool_use_id" fields in
    let* outcome = tool_result_outcome_of_fields ~at fields in
    let* content_json = required ~at "content" fields in
    let* text_content = optional_string ~at "text_content" fields in
    let+ content, content_blocks =
      match content_json, text_content with
      | `String content, None -> Ok (content, None)
      | `String _, Some _ ->
        Error
          (Inconsistent_tool_result { at; problem = Text_content_with_string_content })
      | `List blocks, Some text_content ->
        let+ blocks =
          map_indexed ~at:(field_path at "content") content_block_of_json_at blocks
        in
        text_content, Some blocks
      | `List _, None -> Error (Missing_field { at; field = "text_content" })
      | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _), (Some _ | None) ->
        wrong_kind ~at:(field_path at "content") Json_string_or_array
    in
    P.ToolResult { tool_use_id; content; outcome; json = None; content_blocks }
  | "image" ->
    media_block_of_fields ~at fields ~make:(fun ~media_type ~source ->
      P.Image { media_type; source })
  | "document" ->
    media_block_of_fields ~at fields ~make:(fun ~media_type ~source ->
      P.Document { media_type; source })
  | "audio" ->
    media_block_of_fields ~at fields ~make:(fun ~media_type ~source ->
      P.Audio { media_type; source })
  | block_type -> Error (Unknown_block_type { at; block_type })
;;

let content_block_of_json json = content_block_of_json_at ~at:root_path json

type stored_source_decode =
  | Not_stored_source
  | Invalid_stored_source of decode_error
  | Decoded_stored_source of
      { media_type : string
      ; stored : stored
      }

let stored_source_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let tagged_stored =
      match List.assoc_opt "type" fields with
      | Some (`String tag) -> String.equal tag stored_source_tag
      | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _)
      | None -> false
    in
    if tagged_stored && List.mem_assoc "sha256" fields
    then (
      match
        Result.bind (unique_object ~at:root_path json) (stored_source_of_fields ~at:root_path)
      with
      | Ok (media_type, stored) -> Decoded_stored_source { media_type; stored }
      | Error error -> Invalid_stored_source error)
    else Not_stored_source
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Not_stored_source
;;

let metadata_of_json ~at fields =
  match List.assoc_opt "metadata" fields with
  | None -> Ok []
  | Some (`Assoc []) -> Error (Empty_metadata { at = field_path at "metadata" })
  | Some metadata -> unique_object ~at:(field_path at "metadata") metadata
;;

let message_of_json json =
  let open Result_syntax in
  let at = root_path in
  let* fields = unique_object ~at json in
  let* () =
    exact_fields
      ~at
      ~required:[ "role"; "origin"; "content" ]
      ~optional:[ "name"; "tool_call_id"; "metadata" ]
      fields
  in
  let* role_text = required_string ~at "role" fields in
  let* role =
    match P.role_of_string role_text with
    | Some role -> Ok role
    | None -> Error (Unknown_role { at = field_path at "role"; role = role_text })
  in
  let* origin_text = required_string ~at "origin" fields in
  let* origin =
    match P.message_origin_of_string origin_text with
    | Some origin -> Ok origin
    | None ->
      Error (Unknown_origin { at = field_path at "origin"; origin = origin_text })
  in
  let* blocks = required_array ~at "content" fields in
  let* content =
    map_indexed ~at:(field_path at "content") content_block_of_json_at blocks
  in
  let* name = optional_string ~at "name" fields in
  let* tool_call_id = optional_string ~at "tool_call_id" fields in
  let+ metadata = metadata_of_json ~at fields in
  { P.role; origin; content; name; tool_call_id; metadata }
;;

(* ================================================================ *)
(* In-memory store                                                  *)
(* ================================================================ *)

module Memory_store = struct
  let initial_size = 16

  let create () =
    let blobs : (string, string) Hashtbl.t = Hashtbl.create initial_size in
    let lock = Mutex.create () in
    let put ~media_type:_ ~raw =
      let stored = stored_of_raw raw in
      Mutex.protect lock (fun () -> Hashtbl.replace blobs stored.sha256 raw);
      Ok stored
    in
    let get expected =
      match Mutex.protect lock (fun () -> Hashtbl.find_opt blobs expected.sha256) with
      | None -> Error (Missing_bytes expected)
      | Some raw ->
        let actual = stored_of_raw raw in
        if stored_equal actual expected
        then Ok raw
        else Error (Digest_mismatch { expected; actual })
    in
    { put; get }
  ;;
end
