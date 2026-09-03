(* See .mli for the contract. Typed artifact reference + exact marker codec
   (#25096). The marker wire format is unchanged; only the type safety and
   the decode totality change. *)

type invalid_sha256 =
  | Invalid_sha256_length of { actual : int }
  | Invalid_sha256_character of { index : int; found : char }

let validate_sha256 value =
  let rec validate_character index =
    if index = String.length value then Ok ()
    else
      let found = String.unsafe_get value index in
      if (found >= '0' && found <= '9') || (found >= 'a' && found <= 'f')
      then validate_character (index + 1)
      else Error (Invalid_sha256_character { index; found })
  in
  let actual = String.length value in
  if actual <> 64 then Error (Invalid_sha256_length { actual })
  else validate_character 0

let invalid_sha256_to_string = function
  | Invalid_sha256_length { actual } ->
    Printf.sprintf
      "expected 64 lowercase hexadecimal characters, got length %d" actual
  | Invalid_sha256_character { index; found } ->
    Printf.sprintf
      "expected lowercase hexadecimal character at index %d, got %C" index
      found

type artifact_ref =
  { sha256 : string
  ; bytes : int
  ; preview : string
  ; mime : string
  }

type make_error =
  | Invalid_sha256 of invalid_sha256
  | Negative_bytes of int
  | Empty_mime
  | Unencodable_mime of string

let make_error_to_string = function
  | Invalid_sha256 err -> invalid_sha256_to_string err
  | Negative_bytes n ->
    Printf.sprintf "byte count must be non-negative, got %d" n
  | Empty_mime -> "media type must be non-empty"
  | Unencodable_mime mime ->
    Printf.sprintf
      "media type must not contain whitespace, got %S; the agent-core marker \
       writes it unquoted between spaces"
      mime

(* [encode_for_agent_core] writes mime unquoted between two spaces, and the
   decoder reads it with [%s@ ]. A media type carrying a parameter the usual
   way -- "text/plain; charset=utf-8" -- therefore ends at the space, and the
   decoder then meets "charset=" where it wants "preview=". The failure lands
   at read time as a scanf error naming a character position, far from the
   write that caused it, so the constraint is enforced where the value is
   built instead. *)
let mime_is_encodable mime =
  String.for_all
    (function
      | ' ' | '\t' | '\n' | '\r' -> false
      | _ -> true)
    mime

let make_artifact_ref ~sha256 ~bytes ~preview ~mime =
  match validate_sha256 sha256 with
  | Error err -> Error (Invalid_sha256 err)
  | Ok () ->
    if bytes < 0 then Error (Negative_bytes bytes)
    else if String.equal (String.trim mime) "" then Error Empty_mime
    else if not (mime_is_encodable mime) then Error (Unencodable_mime mime)
    else Ok { sha256; bytes; preview; mime }

let with_preview artifact_ref preview = { artifact_ref with preview }

let normalized_artifact_ref_key = "_blob"

let normalized_artifact_ref_to_json { sha256; bytes; preview; mime } =
  `Assoc
    [ ( normalized_artifact_ref_key
      , `Assoc
          [ "sha256", `String sha256
          ; "bytes", `Int bytes
          ; "mime", `String mime
          ; "preview", `String preview
          ] )
    ]
;;

type normalized_artifact_ref_decode =
  | Not_normalized_artifact_ref
  | Invalid_normalized_artifact_ref of { detail : string }
  | Decoded_normalized_artifact_ref of artifact_ref

let normalized_artifact_ref_of_json = function
  | `Assoc [ (key, `Assoc fields) ]
    when String.equal key normalized_artifact_ref_key ->
    let fields =
      List.sort
        (fun (left, _) (right, _) -> String.compare left right)
        fields
    in
    (match fields with
     | [ "bytes", `Int bytes
       ; "mime", `String mime
       ; "preview", `String preview
       ; "sha256", `String sha256
       ] ->
       (match make_artifact_ref ~sha256 ~bytes ~preview ~mime with
        | Ok reference -> Decoded_normalized_artifact_ref reference
        | Error error ->
          Invalid_normalized_artifact_ref
            { detail = make_error_to_string error })
     | _ ->
       Invalid_normalized_artifact_ref
         { detail =
             "expected exact _blob fields bytes, mime, preview, and sha256"
         })
  | `Assoc [ (key, _) ] when String.equal key normalized_artifact_ref_key ->
    Invalid_normalized_artifact_ref
      { detail = "_blob value must be an object" }
  | `Assoc fields when List.mem_assoc normalized_artifact_ref_key fields ->
    Invalid_normalized_artifact_ref
      { detail = "_blob wrapper must contain no sibling fields" }
  | _ -> Not_normalized_artifact_ref
;;

let collect_normalized_artifact_refs ~reject_invalid json =
  let add_reference references reference =
    if
      List.exists
        (fun existing ->
           String.equal existing.sha256 reference.sha256
           && String.equal existing.mime reference.mime)
        references
    then references
    else reference :: references
  in
  let rec collect references = function
    | (`Assoc fields as json) ->
      (match normalized_artifact_ref_of_json json with
       | Decoded_normalized_artifact_ref reference ->
         Ok (add_reference references reference)
       | Invalid_normalized_artifact_ref { detail } when reject_invalid ->
         Error detail
       | Invalid_normalized_artifact_ref _ | Not_normalized_artifact_ref ->
         List.fold_left
           (fun result (_, value) ->
              Result.bind result (fun references -> collect references value))
           (Ok references)
           fields)
    | `List values ->
      List.fold_left
        (fun result value ->
           Result.bind result (fun references -> collect references value))
        (Ok references)
        values
    | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ ->
      Ok references
  in
  Result.map List.rev (collect [] json)
;;

let normalized_artifact_refs_in_json json =
  match collect_normalized_artifact_refs ~reject_invalid:false json with
  | Ok references -> references
  | Error _ -> []
;;

let normalized_artifact_refs_in_json_strict json =
  collect_normalized_artifact_refs ~reject_invalid:true json
;;

let artifact_manifest_mime = "application/vnd.masc.tool-result-manifest+json"
let artifact_manifest_schema = "masc.tool-result-artifact-manifest.v1"

let artifact_manifest_to_json ~content ~structured_content =
  `Assoc
    [ "schema", `String artifact_manifest_schema
    ; "content", `String content
    ; "structured_content", structured_content
    ]
;;

type artifact_manifest_decode =
  | Not_artifact_manifest
  | Invalid_artifact_manifest of { detail : string }
  | Decoded_artifact_manifest of
      { content : string
      ; structured_content : Yojson.Safe.t
      ; artifact_refs : artifact_ref list
      }

let artifact_manifest_of_json = function
  | `Assoc
      [ "schema", `String schema
      ; "content", `String content
      ; "structured_content", structured_content
      ]
    when String.equal schema artifact_manifest_schema ->
    (match normalized_artifact_refs_in_json_strict structured_content with
     | Ok artifact_refs ->
       Decoded_artifact_manifest
         { content; structured_content; artifact_refs }
     | Error detail -> Invalid_artifact_manifest { detail })
  | `Assoc fields when List.mem_assoc "schema" fields ->
    (match List.assoc_opt "schema" fields with
     | Some (`String schema) when not (String.equal schema artifact_manifest_schema) ->
       Not_artifact_manifest
     | _ ->
       Invalid_artifact_manifest
         { detail =
             "expected exact fields schema, content, and structured_content"
         })
  | _ -> Not_artifact_manifest
;;

type t =
  | Inline of string
  | Stored of artifact_ref

type model_projection =
  | Store_above of { threshold_bytes : int }
  | Inline_up_to of { maximum_bytes : int }

let default_model_projection =
  Store_above { threshold_bytes = Common.max_tool_result_wire_bytes }

let bounded_inline_model_projection =
  Inline_up_to { maximum_bytes = Common.max_tool_result_wire_bytes }

let marker_prefix = "[masc:blob sha256="

let is_marker s = String.starts_with ~prefix:marker_prefix s

let encode_for_agent_core = function
  | Inline s -> s
  | Stored { sha256; bytes; preview; mime } ->
    Printf.sprintf "[masc:blob sha256=%s bytes=%d mime=%s preview=%S]"
      sha256 bytes mime preview

type decode_result =
  | Not_marker
  | Invalid_marker of { detail : string }
  | Decoded of artifact_ref

let decode_from_agent_core s =
  if not (is_marker s) then Not_marker
  else
    match
      (try
         Scanf.sscanf s "[masc:blob sha256=%s@ bytes=%d mime=%s@ preview=%S]"
           (fun sha256 bytes mime preview -> Ok (sha256, bytes, mime, preview))
       with
       | Scanf.Scan_failure msg -> Error msg
       | End_of_file -> Error "unexpected end of artifact marker"
       | Failure msg -> Error msg
       | Invalid_argument msg -> Error msg)
    with
    | Error detail -> Invalid_marker { detail }
    | Ok (sha256, bytes, mime, preview) -> (
      match make_artifact_ref ~sha256 ~bytes ~preview ~mime with
      | Ok artifact_ref -> Decoded artifact_ref
      | Error err -> Invalid_marker { detail = make_error_to_string err })
