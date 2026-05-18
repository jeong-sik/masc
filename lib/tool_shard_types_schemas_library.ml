(** Tool_shard_types_schemas_library — keeper_library_* tool schemas. *)

let library_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_library_search"
    ; description =
        "Search the knowledge library by keyword. Returns matching document titles, \
         relevance scores (0-1), and text snippets. Use to discover relevant docs before \
         reading full content with keeper_library_read."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "query"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Search query string"
                      ] )
                ] )
          ; "required", `List [ `String "query" ]
          ]
    }
  ; { name = "keeper_library_read"
    ; description =
        "Read a full document from the knowledge library by exact topic name. Use after \
         keeper_library_search identifies a relevant document, or with a known topic \
         name. Returns full document text."
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
