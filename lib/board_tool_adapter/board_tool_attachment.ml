type kind = Image | Video | Youtube | External_link

type source =
  | Https_url of string
  | Artifact_sha256 of string

type unresolved = { kind : kind; source : source }

type t =
  | Url of { kind : kind; url : string }
  | Artifact of { kind : kind; reference : Tool_output.artifact_ref }

type error =
  | Raw_meta_attachments
  | Attachments_not_array
  | Duplicate_attachments
  | Entry_not_object of int
  | Invalid_entry_fields of int
  | Invalid_kind of int
  | Invalid_url of int
  | Invalid_sha256 of int * Tool_output.invalid_sha256
  | Missing_artifact of int * string
  | Artifact_read_failed of int * string
  | Invalid_artifact_reference of int * Tool_output.make_error

let error_to_string = function
  | Raw_meta_attachments ->
    "meta.attachments is no longer accepted; use the typed attachments argument"
  | Attachments_not_array -> "attachments must be an array"
  | Duplicate_attachments -> "attachments must appear exactly once"
  | Entry_not_object index ->
    Printf.sprintf "attachments[%d] must be an object" index
  | Invalid_entry_fields index ->
    Printf.sprintf
      "attachments[%d] must contain exactly kind and one of url or sha256"
      index
  | Invalid_kind index ->
    Printf.sprintf
      "attachments[%d].kind must be image, video, youtube, or external_link"
      index
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
;;

let kind_of_json index = function
  | Some (`String "image") -> Ok Image
  | Some (`String "video") -> Ok Video
  | Some (`String "youtube") -> Ok Youtube
  | Some (`String "external_link") -> Ok External_link
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

let parse_entry index = function
  | `Assoc fields ->
    if List.length fields <> 2
    then Error (Invalid_entry_fields index)
    else
      let ( let* ) = Result.bind in
      let* kind = kind_of_json index (List.assoc_opt "kind" fields) in
      (match List.assoc_opt "url" fields, List.assoc_opt "sha256" fields with
       | Some (`String url), None when valid_https_url url ->
         Ok { kind; source = Https_url url }
       | Some _, None -> Error (Invalid_url index)
       | None, Some (`String sha256) ->
         (match Tool_blob_store.validate_sha256 sha256 with
          | Ok () -> Ok { kind; source = Artifact_sha256 sha256 }
          | Error invalid -> Error (Invalid_sha256 (index, invalid)))
       | None, Some _ | None, None | Some _, Some _ ->
         Error (Invalid_entry_fields index))
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

let resolve ~base_path entries =
  let store = Tool_blob_store.create ~base_path in
  let rec loop index acc = function
    | [] -> Ok (List.rev acc)
    | { kind; source = Https_url url } :: rest ->
      loop (index + 1) (Url { kind; url } :: acc) rest
    | { kind; source = Artifact_sha256 sha256 } :: rest ->
      let fetched =
        Eio_unix.run_in_systhread (fun () -> Tool_blob_store.fetch store ~sha256)
      in
      (match fetched with
       | Error error ->
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
            loop (index + 1) (Artifact { kind; reference } :: acc) rest))
  in
  loop 0 [] entries
;;

let kind_to_string = function
  | Image -> "image"
  | Video -> "video"
  | Youtube -> "youtube"
  | External_link -> "external_link"
;;

let to_json = function
  | Url { kind; url } ->
    `Assoc [ "kind", `String (kind_to_string kind); "url", `String url ]
  | Artifact { kind; reference } ->
    `Assoc
      [ "kind", `String (kind_to_string kind)
      ; "artifact", Tool_output.normalized_artifact_ref_to_json reference
      ]
;;
