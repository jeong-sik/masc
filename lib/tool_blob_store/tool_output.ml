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
  ; answer_fingerprint : string option
  }

type make_error =
  | Invalid_sha256 of invalid_sha256
  | Negative_bytes of int
  | Empty_mime
  | Unencodable_mime of string
  | Invalid_answer_fingerprint of invalid_sha256

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
  | Invalid_answer_fingerprint error ->
    Printf.sprintf "invalid semantic answer fingerprint: %s"
      (invalid_sha256_to_string error)

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
    else Ok { sha256; bytes; preview; mime; answer_fingerprint = None }

let with_preview artifact_ref preview = { artifact_ref with preview }
let with_answer_fingerprint artifact_ref answer_fingerprint =
  match answer_fingerprint with
  | None -> Ok { artifact_ref with answer_fingerprint = None }
  | Some fingerprint ->
    (match validate_sha256 fingerprint with
     | Ok () -> Ok { artifact_ref with answer_fingerprint }
     | Error error -> Error (Invalid_answer_fingerprint error))

let normalized_artifact_ref_key = "_blob"

let normalized_artifact_ref_to_json { sha256; bytes; preview; mime; _ } =
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

type t = Stored of artifact_ref

type model_projection =
  | Store_above of { threshold_bytes : int }
  | Inline_up_to of { maximum_bytes : int }

type artifact_projection =
  | Reference_only
  | Inline_with_reference
  | Inline_with_structured_diagnostic

let artifact_projection_to_json = function
  | Reference_only -> `String "reference_only"
  | Inline_with_reference -> `String "inline_with_reference"
  | Inline_with_structured_diagnostic -> `String "inline_with_structured_diagnostic"
;;

let artifact_projection_of_json = function
  | `String "reference_only" -> Ok Reference_only
  | `String "inline_with_reference" -> Ok Inline_with_reference
  | `String "inline_with_structured_diagnostic" -> Ok Inline_with_structured_diagnostic
  | _ -> Error "unknown artifact manifest projection"
;;

let default_model_projection =
  Store_above { threshold_bytes = Common.max_tool_result_wire_bytes }

let bounded_inline_model_projection =
  Inline_up_to { maximum_bytes = Common.max_tool_result_wire_bytes }

let agent_core_model_projection =
  Store_above { threshold_bytes = Common.max_agent_core_inline_result_bytes }

let inline_ceiling_bytes = function
  | Store_above { threshold_bytes } -> threshold_bytes
  | Inline_up_to { maximum_bytes } -> maximum_bytes

type result_boundary =
  | Projected_for_model of model_projection
  | Sent_to_client

let result_ceiling_bytes = function
  | Projected_for_model projection -> inline_ceiling_bytes projection
  | Sent_to_client -> Common.max_tool_result_wire_bytes

let marker_prefix = "[masc:blob sha256="

let is_marker s = String.starts_with ~prefix:marker_prefix s

let encode_for_agent_core = function
  | Stored { sha256; bytes; preview; mime; answer_fingerprint } ->
    let semantic =
      match answer_fingerprint with
      | None -> ""
      | Some fingerprint -> Printf.sprintf " answer_sha256=%s" fingerprint
    in
    Printf.sprintf "[masc:blob sha256=%s bytes=%d mime=%s%s preview=%S]"
      sha256 bytes mime semantic preview

let encode_structured_handle = function
  | Stored reference ->
    Yojson.Safe.to_string (normalized_artifact_ref_to_json reference)

type decode_result =
  | Not_marker
  | Invalid_marker of { detail : string }
  | Decoded of artifact_ref

let decode_structured_handle s =
  let trimmed = String.trim s in
  if not (String.starts_with ~prefix:"{" trimmed) then Not_marker
  else
    match Yojson.Safe.from_string trimmed with
    | exception Yojson.Json_error _ -> Not_marker
    | json ->
      (match normalized_artifact_ref_of_json json with
       | Not_normalized_artifact_ref -> Not_marker
       | Invalid_normalized_artifact_ref { detail } -> Invalid_marker { detail }
       | Decoded_normalized_artifact_ref reference -> Decoded reference)

(* Pure deterministic parser for the exact AGENT_CORE blob marker grammar:
   [[masc:blob sha256=<tok> bytes=<int> mime=<tok>[ answer_sha256=<tok>] preview="<escaped>"]]
   No [Scanf], no exception-driven fallback branches. *)
let scan_until_space s pos len =
  let rec loop i =
    if i >= len then None
    else
      match String.unsafe_get s i with
      | ' ' -> Some (String.sub s pos (i - pos), i + 1)
      | _ -> loop (i + 1)
  in
  loop pos

let expect_prefix s pos len prefix =
  let plen = String.length prefix in
  if pos + plen > len then None
  else
    let rec eq i =
      if i = plen then Some (pos + plen)
      else if Char.equal (String.unsafe_get s (pos + i)) (String.unsafe_get prefix i)
      then eq (i + 1)
      else None
    in
    eq 0

let hex_digit c =
  if c >= '0' && c <= '9' then Some (Char.code c - Char.code '0')
  else if c >= 'a' && c <= 'f' then Some (10 + Char.code c - Char.code 'a')
  else if c >= 'A' && c <= 'F' then Some (10 + Char.code c - Char.code 'A')
  else None

let dec_digit c =
  if c >= '0' && c <= '9' then Some (Char.code c - Char.code '0') else None

let parse_ocaml_quoted_string s pos len =
  if pos >= len || not (Char.equal (String.unsafe_get s pos) '"')
  then Error "expected opening quote for preview"
  else
    let buf = Buffer.create (max 16 (len - pos)) in
    let rec loop i =
      if i >= len then Error "unterminated preview string"
      else
        match String.unsafe_get s i with
        | '"' -> Ok (Buffer.contents buf, i + 1)
        | '\\' ->
          if i + 1 >= len then Error "truncated escape in preview string"
          else
            (match String.unsafe_get s (i + 1) with
             | '"' -> Buffer.add_char buf '"'; loop (i + 2)
             | '\\' -> Buffer.add_char buf '\\'; loop (i + 2)
             | '\'' -> Buffer.add_char buf '\''; loop (i + 2)
             | 'n' -> Buffer.add_char buf '\n'; loop (i + 2)
             | 'r' -> Buffer.add_char buf '\r'; loop (i + 2)
             | 't' -> Buffer.add_char buf '\t'; loop (i + 2)
             | 'b' -> Buffer.add_char buf '\b'; loop (i + 2)
             | ' ' -> Buffer.add_char buf ' '; loop (i + 2)
             | 'x' ->
               if i + 3 >= len then Error "truncated hex escape in preview string"
               else
                 (match
                    hex_digit (String.unsafe_get s (i + 2)),
                    hex_digit (String.unsafe_get s (i + 3))
                  with
                  | Some hi, Some lo ->
                    Buffer.add_char buf (Char.chr ((hi lsl 4) lor lo));
                    loop (i + 4)
                  | None, _ | _, None -> Error "invalid hex escape in preview string")
             | c ->
               (match dec_digit c with
                | None -> Error (Printf.sprintf "unknown escape \\%c in preview string" c)
                | Some d1 ->
                  if i + 3 >= len then Error "truncated decimal escape in preview string"
                  else
                    (match
                       dec_digit (String.unsafe_get s (i + 2)),
                       dec_digit (String.unsafe_get s (i + 3))
                     with
                     | Some d2, Some d3 ->
                       let code = (d1 * 100) + (d2 * 10) + d3 in
                       if code > 255
                       then Error "decimal escape out of byte range in preview string"
                       else (
                         Buffer.add_char buf (Char.chr code);
                         loop (i + 4))
                     | None, _ | _, None -> Error "invalid decimal escape in preview string")))
        | c ->
          Buffer.add_char buf c;
          loop (i + 1)
    in
    loop (pos + 1)

let parse_non_negative_decimal s =
  let len = String.length s in
  if len = 0 then Error "empty byte count"
  else
    let rec loop i acc =
      if i = len then Ok acc
      else
        match dec_digit (String.unsafe_get s i) with
        | None -> Error (Printf.sprintf "invalid integer %S" s)
        | Some d ->
          if acc > (max_int - d) / 10 then Error "byte count overflow"
          else loop (i + 1) ((acc * 10) + d)
    in
    if Char.equal (String.unsafe_get s 0) '-'
    then
      match int_of_string_opt s with
      | Some n -> Ok n
      | None -> Error (Printf.sprintf "invalid integer %S" s)
    else loop 0 0

let decode_from_agent_core s =
  if not (is_marker s) then Not_marker
  else
    let len = String.length s in
    let pos = String.length marker_prefix in
    let parsed =
      let ( let* ) = Result.bind in
      let* sha256, pos =
        match scan_until_space s pos len with
        | Some pair -> Ok pair
        | None -> Error "missing space after sha256"
      in
      let* pos =
        match expect_prefix s pos len "bytes=" with
        | Some p -> Ok p
        | None -> Error "expected bytes= field"
      in
      let* bytes_tok, pos =
        match scan_until_space s pos len with
        | Some pair -> Ok pair
        | None -> Error "missing space after bytes"
      in
      let* bytes = parse_non_negative_decimal bytes_tok in
      let* pos =
        match expect_prefix s pos len "mime=" with
        | Some p -> Ok p
        | None -> Error "expected mime= field"
      in
      let* mime, pos =
        match scan_until_space s pos len with
        | Some pair -> Ok pair
        | None -> Error "missing space after mime"
      in
      let* answer_fingerprint, pos =
        match expect_prefix s pos len "answer_sha256=" with
        | Some p ->
          (match scan_until_space s p len with
           | Some (fp, next_pos) -> Ok (Some fp, next_pos)
           | None -> Error "missing space after answer_sha256")
        | None -> Ok (None, pos)
      in
      let* pos =
        match expect_prefix s pos len "preview=" with
        | Some p -> Ok p
        | None -> Error "expected preview= field"
      in
      let* preview, pos = parse_ocaml_quoted_string s pos len in
      if pos + 1 = len && Char.equal (String.unsafe_get s pos) ']'
      then Ok (sha256, bytes, mime, answer_fingerprint, preview)
      else Error "expected closing ']' at end of artifact marker"
    in
    match parsed with
    | Error detail -> Invalid_marker { detail }
    | Ok (sha256, bytes, mime, answer_fingerprint, preview) ->
      (match
         Result.bind (make_artifact_ref ~sha256 ~bytes ~preview ~mime)
           (fun reference -> with_answer_fingerprint reference answer_fingerprint)
       with
       | Ok artifact_ref -> Decoded artifact_ref
       | Error err -> Invalid_marker { detail = make_error_to_string err })

let decode_any_handle s =
  match decode_structured_handle s with
  | (Decoded _ | Invalid_marker _) as res -> res
  | Not_marker -> decode_from_agent_core s
