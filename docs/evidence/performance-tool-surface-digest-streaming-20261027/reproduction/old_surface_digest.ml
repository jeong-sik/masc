let surface_digest surface =
  `List
    (List.map
       (fun { source; schema } ->
          `Assoc
            [ "source", source_to_json source
            ; "schema", Agent_core.Types.tool_schema_to_json schema
            ])
       surface)
  |> Yojson.Safe.sort
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
;;
