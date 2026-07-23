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

let make_error_to_string = function
  | Invalid_sha256 err -> invalid_sha256_to_string err
  | Negative_bytes n ->
    Printf.sprintf "byte count must be non-negative, got %d" n
  | Empty_mime -> "media type must be non-empty"

let make_artifact_ref ~sha256 ~bytes ~preview ~mime =
  match validate_sha256 sha256 with
  | Error err -> Error (Invalid_sha256 err)
  | Ok () ->
    if bytes < 0 then Error (Negative_bytes bytes)
    else if String.equal (String.trim mime) "" then Error Empty_mime
    else Ok { sha256; bytes; preview; mime }

let with_preview artifact_ref preview = { artifact_ref with preview }

type t =
  | Inline of string
  | Stored of artifact_ref

let marker_prefix = "[masc:blob "

let is_marker s = String.starts_with ~prefix:marker_prefix s

let encode_for_oas = function
  | Inline s -> s
  | Stored { sha256; bytes; preview; mime } ->
    Printf.sprintf "[masc:blob sha256=%s bytes=%d mime=%s preview=%S]"
      sha256 bytes mime preview

type decode_result =
  | Not_marker
  | Invalid_marker of { detail : string }
  | Decoded of artifact_ref

let decode_from_oas s =
  if not (is_marker s) then Not_marker
  else
    match
      (try
         Scanf.sscanf s "[masc:blob sha256=%s@ bytes=%d mime=%s@ preview=%S]"
           (fun sha256 bytes mime preview -> Ok (sha256, bytes, mime, preview))
       with
       | Scanf.Scan_failure msg -> Error msg
       | Failure msg -> Error msg
       | Invalid_argument msg -> Error msg)
    with
    | Error detail -> Invalid_marker { detail }
    | Ok (sha256, bytes, mime, preview) -> (
      match make_artifact_ref ~sha256 ~bytes ~preview ~mime with
      | Ok artifact_ref -> Decoded artifact_ref
      | Error err -> Invalid_marker { detail = make_error_to_string err })
