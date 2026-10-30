let surface_digest surface =
  Digestif.SHA256.digesti_string (fun emit ->
    (* Same initial size as Yojson.Safe.to_string; owned by this one call. *)
    let buffer = Buffer.create 256 in
    let emit_entry { source; schema } =
      `Assoc
        [ "source", source_to_json source
        ; "schema", Agent_core.Types.tool_schema_to_json schema
        ]
      |> Yojson.Safe.sort
      |> Yojson.Safe.to_string ~buf:buffer
      |> emit
    in
    let rec emit_entries = function
      | [] -> ()
      | [ entry ] -> emit_entry entry
      | entry :: rest ->
        emit_entry entry;
        emit ",";
        emit_entries rest
    in
    emit "[";
    emit_entries surface;
    emit "]")
;;
