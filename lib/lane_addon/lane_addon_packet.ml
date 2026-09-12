open Lane_addon_types
let ( let* ) = Result.bind
let exact names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | _ -> Error ("expected exactly fields: " ^ String.concat ", " names)
let text = function `String value when String.trim value <> "" -> Ok value
  | _ -> Error "expected a non-blank string"
let traverse f values =
  List.fold_left (fun acc value -> let* acc = acc in let* value = f value in Ok (value :: acc))
    (Ok []) values |> Result.map List.rev
let decode ?store ~max_bytes json =
  let* () = if String.length (Yojson.Safe.to_string json) <= max_bytes then Ok ()
    else Error "artifact output exceeds the package reply envelope" in
  let* fields, packet_artifacts = match json with
    | `Assoc fields when List.sort String.compare (List.map fst fields) = ["coverage"; "rows"] ->
        Ok (fields, `List [])
    | _ -> let* fields = exact ["rows"; "coverage"; "artifacts"] json in
        Ok (fields, List.assoc "artifacts" fields) in
  let* artifacts = match packet_artifacts with
    | `List values -> traverse (fun value ->
        let* fields = exact ["id"; "mime_type"; "data_base64"] value in
        let* id = text (List.assoc "id" fields) in
        let* _mime = text (List.assoc "mime_type" fields) in
        let* encoded = match List.assoc "data_base64" fields with
          | `String value -> Ok value | _ -> Error "artifact data_base64 must be a string" in
        let* bytes = Base64.decode encoded |> Result.map_error (fun (`Msg message) -> message) in
        if Base64.encode_string bytes <> encoded then Error "artifact bytes require canonical padded base64"
        else let sha256 = Lane_addon_store.digest bytes in
          Ok (id, bytes, {uri = "lane-evidence:" ^ sha256; sha256 = Some sha256})) values
    | _ -> Error "artifacts must be an array" in
  let ids = List.map (fun (id, _, _) -> id) artifacts in
  let* () = if List.length ids = List.length (List.sort_uniq String.compare ids) then Ok ()
    else Error "duplicate artifact identity" in
  let resolve = function
    | `Assoc ["artifact_id", value] ->
        let* id = text value in
        (match List.find_opt (fun (key, _, _) -> key = id) artifacts with
         | None -> Error ("unknown row artifact_id: " ^ id)
         | Some (_, _, reference) -> Ok (`Assoc ["uri", `String reference.uri;
             "sha256", Option.fold ~none:`Null ~some:(fun value -> `String value) reference.sha256]))
    | `Assoc fields as reference when not (List.mem_assoc "artifact_id" fields) -> Ok reference
    | _ -> Error "evidence requires an artifact_id or URI and SHA-256 reference" in
  let* rows = match List.assoc "rows" fields with
    | `List values -> traverse (function
        | `Assoc fields ->
            let* evidence = match List.assoc_opt "evidence" fields with
              | Some (`List references) -> traverse resolve references
              | _ -> Error "row evidence must be an array" in
            (* Replace only after checking duplicates; the ordinary row decoder
               must still see malformed producer fields. *)
            if List.length (List.filter (fun (name, _) -> name = "evidence") fields) <> 1
            then Error "duplicate row evidence field"
            else Ok (`Assoc (List.map (fun (name, value) ->
              if name = "evidence" then name, `List evidence else name, value) fields))
        | _ -> Error "row must be an object") values
    | _ -> Error "rows must be an array" in
  let* output = output_of_json (`Assoc ["rows", `List rows; "coverage", List.assoc "coverage" fields]) in
  let* () = match store, artifacts with
    | None, [] -> Ok ()
    | None, _ -> Error "artifact bytes require the host's owned artifact store"
    | Some store, _ -> let* _ = traverse (fun (_, bytes, _) -> Lane_addon_store.write_blob store bytes) artifacts in Ok () in
  Ok output
