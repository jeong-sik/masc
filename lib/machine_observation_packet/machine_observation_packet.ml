let ( let* ) = Result.bind
let encode = function
  | `Assoc packet ->
      let* rows = match List.assoc_opt "rows" packet with
        | Some (`List rows) -> Ok rows | _ -> Error "machine packet requires rows" in
      let* rows, artifacts = List.fold_left (fun acc row ->
        let* rows, artifacts = acc in
        match row with
        | `Assoc fields ->
            (match List.assoc_opt "fields" fields with
             | Some (`Assoc values) ->
                 (match List.assoc_opt "machine_live" values with
                  | None -> Ok (row::rows, artifacts)
                  | Some live ->
                      let* id = match List.assoc_opt "id" fields with
                        | Some (`String id) -> Ok ("machine-live/" ^ id)
                        | _ -> Error "machine row requires an id" in
                      let bytes = Yojson.Safe.to_string live in
                      let digest = Digestif.SHA256.(to_hex (digest_string bytes)) in
                      let reference = `Assoc ["uri", `String ("lane-evidence:" ^ digest); "sha256", `String digest] in
                      let* evidence = match List.assoc_opt "evidence" fields with
                        | Some (`List evidence) -> Ok evidence | _ -> Error "machine row requires evidence" in
                      let row = `Assoc (List.map (fun (name,value) -> name,
                        if name = "fields" then `Assoc (("machine_live",reference) :: List.remove_assoc "machine_live" values)
                        else if name = "evidence" then `List (`Assoc ["artifact_id", `String id] :: evidence)
                        else value) fields) in
                      let artifact = `Assoc ["id", `String id; "mime_type", `String "application/json";
                        "data_base64", `String (Base64.encode_string bytes)] in
                      Ok (row::rows,artifact::artifacts))
             | _ -> Error "machine row requires fields")
        | _ -> Error "machine row must be an object") (Ok ([],[])) rows in
      Ok (`Assoc (("rows", `List (List.rev rows)) :: ("artifacts", `List (List.rev artifacts))
        :: List.remove_assoc "rows" packet))
  | _ -> Error "machine packet must be an object"
