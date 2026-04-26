(** Tool_schemas_code — SSOT for code-inspection tool schemas.

    Defines schemas for ripgrep search, symbol extraction, and paginated
    file reading.
*)

open Types

let schemas : Types.tool_schema list =
  [ { name = "masc_code_search"
    ; description =
        "Search code using ripgrep with regex support. Returns structured results with \
         file path, line number, and matched content."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ "query", `Assoc [ "type", `String "string" ]
                ; "path", `Assoc [ "type", `String "string" ]
                ; "file_pattern", `Assoc [ "type", `String "string" ]
                ; "case_insensitive", `Assoc [ "type", `String "boolean" ]
                ; "max_results", `Assoc [ "type", `String "number" ]
                ] )
          ; "required", `List [ `String "query" ]
          ]
    }
  ; { name = "masc_code_symbols"
    ; description =
        "Extract symbols (functions, types, classes) from a file using heuristics."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc [ "path", `Assoc [ "type", `String "string" ] ]
          ; "required", `List [ `String "path" ]
          ]
    }
  ; { name = "masc_code_read"
    ; description =
        "Read a file with offset/limit pagination for large files. Use when inspecting \
         source code during task execution without loading the entire file into context."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ "path", `Assoc [ "type", `String "string" ]
                ; "offset", `Assoc [ "type", `String "number" ]
                ; "limit", `Assoc [ "type", `String "number" ]
                ] )
          ; "required", `List [ `String "path" ]
          ]
    }
  ]
;;
