(** Tool_shard_types_schemas_search_files — [search_files_tools] tool_search_files
    schema.

    [Grep] is ripgrep pattern search over the repo. Directory listing, file
    reads, find, and git views are done with the Execute tool. *)

let tool_search_files_schema : Masc_domain.tool_schema =
  { name = "tool_search_files"
  ; description =
        "Search file contents with ripgrep. Provide a regex `pattern` (and \
         optionally path/glob/type). Paths resolve automatically — use \
         'repos/X' or 'mind/X'; never include host paths like \
         '.masc/playground/your-name/repos/X'. To list a directory, read a \
         file, run find, or view git status/log/diff, use the Execute tool."
  ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "pattern"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Regular expression in Rust regex syntax (ripgrep). No lookaround (?!...) (?<=...) and no backreferences; alternation is a plain | (never \\|); a literal double quote needs no backslash. PCRE/BRE-dialect patterns are rejected with a regex parse error."
                      ] )
                ; ( "path"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Directory or file to search in. Defaults to the keeper sandbox." )
                      ] )
                ; ( "glob"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Glob filter, e.g. '*.ml' or 'lib/**/*.ml'."
                      ] )
                ; ( "type"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Ripgrep file-type filter, e.g. 'ml', 'py'. May contain only letters, digits, hyphens, and underscores."
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Maximum number of matches to return."
                      ] )
                ] )
          ; "required", `List [ `String "pattern" ]
          ]
  }
;;

let search_files_tools : Masc_domain.tool_schema list =
  [ tool_search_files_schema ]
;;
