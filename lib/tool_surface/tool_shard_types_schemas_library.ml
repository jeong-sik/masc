(** Tool_shard_types_schemas_library — keeper_library_* tool schemas. *)

let library_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_library_search"
    ; description =
        "Search the keeper library catalog."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "query"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Search query string; empty or missing returns a \
                             workflow error" )
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_library_read"
    ; description =
        "Read a library entry by id."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "topic"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Exact document topic name (from search results or known)" )
                      ] )
                ] )
          ; "required", `List [ `String "topic" ]
          ]
    }
  ]
;;
