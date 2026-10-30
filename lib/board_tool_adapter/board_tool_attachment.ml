type kind = Image | Video | Youtube | External_link | File | Audio | Score | Midi

type source =
  | Https_url of string
  | Artifact_sha256 of string

type unresolved = { kind : kind; source : source; name : string option }

type t =
  | Url of { kind : kind; url : string; name : string option }
  | Artifact of
      { kind : kind
      ; reference : Tool_output.artifact_ref
      ; name : string option
      }

let max_name_bytes = 255

type error =
  | Raw_meta_attachments
  | Attachments_not_array
  | Duplicate_attachments
  | Entry_not_object of int
  | Invalid_entry_fields of int
  | Invalid_kind of int
  | Invalid_name of int
  | Invalid_url of int
  | Invalid_sha256 of int * Tool_output.invalid_sha256
  | Missing_artifact of int * string
  | Artifact_read_failed of int * string
  | Invalid_artifact_reference of int * Tool_output.make_error
  | Youtube_requires_url of int
  | Artifact_too_large of { index : int; bytes : int; maximum : int }

let error_to_string = function
  | Raw_meta_attachments ->
    "meta.attachments is no longer accepted; use the typed attachments argument"
  | Attachments_not_array -> "attachments must be an array"
  | Duplicate_attachments -> "attachments must appear exactly once"
  | Entry_not_object index ->
    Printf.sprintf "attachments[%d] must be an object" index
  | Invalid_entry_fields index ->
    Printf.sprintf
      "attachments[%d] must contain exactly kind, one of url or sha256, and an optional string name"
      index
  | Invalid_kind index ->
    Printf.sprintf
      "attachments[%d].kind must be image, video, youtube, external_link, file, audio, score, or midi"
      index
  | Invalid_name index ->
    Printf.sprintf
      "attachments[%d].name must be a non-empty string on one line, at most %d bytes"
      index
      max_name_bytes
  | Invalid_url index ->
    Printf.sprintf
      "attachments[%d].url must be an absolute https URL without credentials or controls"
      index
  | Invalid_sha256 (index, invalid) ->
    Printf.sprintf
      "attachments[%d].sha256: %s"
      index
      (Tool_output.invalid_sha256_to_string invalid)
  | Missing_artifact (index, sha256) ->
    Printf.sprintf "attachments[%d].sha256 artifact not found: %s" index sha256
  | Artifact_read_failed (index, reason) ->
    Printf.sprintf "attachments[%d].sha256 artifact read failed: %s" index reason
  | Invalid_artifact_reference (index, invalid) ->
    Printf.sprintf
      "attachments[%d].sha256 artifact reference invalid: %s"
      index
      (Tool_output.make_error_to_string invalid)
  | Youtube_requires_url index ->
    Printf.sprintf
      "attachments[%d]: kind youtube needs url; attach an artifact as image, video, external_link, file, audio, score, or midi"
      index
  | Artifact_too_large { index; bytes; maximum } ->
    Printf.sprintf
      "attachments[%d].sha256 artifact is %d bytes, over the %d-byte limit the dashboard can open"
      index
      bytes
      maximum
;;

let kind_of_json index = function
  | Some (`String "image") -> Ok Image
  | Some (`String "video") -> Ok Video
  | Some (`String "youtube") -> Ok Youtube
  | Some (`String "external_link") -> Ok External_link
  | Some (`String "file") -> Ok File
  | Some (`String "audio") -> Ok Audio
  | Some (`String "score") -> Ok Score
  | Some (`String "midi") -> Ok Midi
  | Some _ | None -> Error (Invalid_kind index)
;;

let valid_https_url url =
  let clean =
    String.equal url (String.trim url)
    && String.for_all
         (fun c ->
           let code = Char.code c in
           code > 32 && code <> 127 && not (Char.equal c '\\'))
         url
  in
  if not clean then false
  else
    match Uri.of_string url with
    | parsed ->
      (match Uri.scheme parsed, Uri.host parsed, Uri.userinfo parsed with
       | Some scheme, Some host, None ->
         String.equal (String.lowercase_ascii scheme) "https"
         && not (String.equal host "")
       | _ -> false)
    | exception Invalid_argument _ -> false
;;

(* A name is the file's name: a reader prints it beside the attachment and
   the dashboard saves the download under it. So it is text (the entry is
   stored as JSON, and a JSON string is not arbitrary bytes), one line, no
   longer than a file name, and names no directory. *)
let valid_name name =
  let length = String.length name in
  length > 0
  && length <= max_name_bytes
  && String.is_valid_utf_8 name
  && (not (String.equal name "."))
  && (not (String.equal name ".."))
  && String.for_all
       (fun char ->
         let code = Char.code char in
         code >= 0x20 && code <> 0x7f && char <> '/' && char <> '\\')
       name
;;

let parse_source index fields name =
  if List.length fields <> 2
  then Error (Invalid_entry_fields index)
  else
    let open Result.Syntax in
    let* kind = kind_of_json index (List.assoc_opt "kind" fields) in
    match List.assoc_opt "url" fields, List.assoc_opt "sha256" fields with
    | Some (`String url), None when valid_https_url url ->
      Ok { kind; source = Https_url url; name }
    | Some _, None -> Error (Invalid_url index)
    | None, Some (`String sha256) ->
      (match kind with
       | Youtube -> Error (Youtube_requires_url index)
       | Image | Video | External_link | File | Audio | Score | Midi ->
         (match Tool_blob_store.validate_sha256 sha256 with
          | Ok () -> Ok { kind; source = Artifact_sha256 sha256; name }
          | Error invalid -> Error (Invalid_sha256 (index, invalid))))
    | None, Some _ | None, None | Some _, Some _ ->
      Error (Invalid_entry_fields index)
;;

let parse_entry index = function
  | `Assoc entry_fields ->
    (* [name] is the only optional field; every other key must be exactly
       [kind] plus one of [url] or [sha256]. A duplicate [name] is a shape
       error, not a string to carry. *)
    let name_fields, fields =
      List.partition (fun (key, _) -> String.equal key "name") entry_fields
    in
    (match name_fields with
     | [ _, `String name ] when valid_name name ->
       parse_source index fields (Some name)
     | [] -> parse_source index fields None
     | [ _ ] -> Error (Invalid_name index)
     | _ -> Error (Invalid_entry_fields index))
  | _ -> Error (Entry_not_object index)
;;

let parse_args args =
  let fields =
    match args with
    | `Assoc fields -> fields
    | _ -> []
  in
  let raw_meta_attachments =
    List.exists
      (function
        | "meta", `Assoc meta -> List.mem_assoc "attachments" meta
        | _ -> false)
      fields
  in
  if raw_meta_attachments then Error Raw_meta_attachments
  else
    match List.filter (fun (key, _) -> String.equal key "attachments") fields with
    | [] -> Ok []
    | [ _, `List entries ] ->
      let rec parse index acc = function
        | [] -> Ok (List.rev acc)
        | entry :: rest ->
          (match parse_entry index entry with
           | Ok parsed -> parse (index + 1) (parsed :: acc) rest
           | Error _ as error -> error)
      in
      parse 0 [] entries
    | [ _ ] -> Error Attachments_not_array
    | _ -> Error Duplicate_attachments
;;

let artifact_mime bytes =
  match Yojson.Safe.from_string bytes with
  | json ->
    (match Tool_output.artifact_manifest_of_json json with
     | Tool_output.Decoded_artifact_manifest _ -> Tool_output.artifact_manifest_mime
     | Tool_output.Not_artifact_manifest
     | Tool_output.Invalid_artifact_manifest _ -> "application/octet-stream")
  | exception Yojson.Json_error _ -> "application/octet-stream"
;;

let resolve ~base_path ~max_artifact_bytes entries =
  let store = Tool_blob_store.create ~base_path in
  let rec loop index acc = function
    | [] -> Ok (List.rev acc)
    | { kind; source = Https_url url; name } :: rest ->
      loop (index + 1) (Url { kind; url; name } :: acc) rest
    | { kind; source = Artifact_sha256 sha256; name } :: rest ->
      let fetched =
        Eio_unix.run_in_systhread (fun () ->
          Tool_blob_store.fetch_bounded store ~sha256 ~max_bytes:max_artifact_bytes)
      in
      (match fetched with
       | Error (Tool_blob_store.Too_large { actual; maximum; path = _ }) ->
         Error (Artifact_too_large { index; bytes = actual; maximum })
       | Error
           (( Tool_blob_store.Invalid_sha256 _
            | Tool_blob_store.Owned_read_failed _
            | Tool_blob_store.Invalid_max_bytes _
            | Tool_blob_store.Integrity_mismatch _ ) as error) ->
         Error
           (Artifact_read_failed
              (index, Tool_blob_store.fetch_error_to_string error))
       | Ok None -> Error (Missing_artifact (index, sha256))
       | Ok (Some bytes) ->
         (match
            Tool_output.make_artifact_ref
              ~sha256
              ~bytes:(String.length bytes)
              ~preview:""
              ~mime:(artifact_mime bytes)
          with
          | Error error -> Error (Invalid_artifact_reference (index, error))
          | Ok reference ->
            loop (index + 1) (Artifact { kind; reference; name } :: acc) rest))
  in
  loop 0 [] entries
;;

let kind_to_string = function
  | Image -> "image"
  | Video -> "video"
  | Youtube -> "youtube"
  | External_link -> "external_link"
  | File -> "file"
  | Audio -> "audio"
  | Score -> "score"
  | Midi -> "midi"
;;

let name_field name =
  match name with
  | Some name -> [ "name", `String name ]
  | None -> []
;;

let to_json = function
  | Url { kind; url; name } ->
    `Assoc
      ([ "kind", `String (kind_to_string kind); "url", `String url ]
       @ name_field name)
  | Artifact { kind; reference; name } ->
    `Assoc
      ([ "kind", `String (kind_to_string kind)
       ; "artifact", Tool_output.normalized_artifact_ref_to_json reference
       ]
       @ name_field name)
;;
