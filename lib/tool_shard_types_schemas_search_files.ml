(** Tool_shard_types_schemas_search_files — [search_files_tools]
    tool_search_files schema.

    [SearchFiles] is a repo inspection capability, not a shell capability. *)

open Tool_shard_types_enum_mirrors

let search_files_tools : Masc_domain.tool_schema list =
  [ { name = "tool_search_files"
    ; description =
        "Inspect the project workspace via a structured op. ops: pwd, ls, cat, rg, git_status, \
         find, head, tail, wc, tree, git_log, git_diff. \
         Structured ops default to the keeper sandbox. IMPORTANT: paths resolve \
         automatically — use 'repos/X' or 'mind/X'. Never include host paths like \
         '.masc/playground/your-name/repos/X' in path or cwd. Use cwd to target an \
         explicit allowed directory or cloned repo. find REQUIRES pattern param (e.g. \
         pattern=\"*.ml\"). No generic bash execution: use Execute for command \
         execution. Use rg for pattern search, find for path discovery, head/tail for \
         line ranges, and git_log/git_diff for repo history."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [
                  ( "op"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map
                               (fun s -> `String s)
                               tool_search_files_op_enum_strings) )
                      ; "description", `String "Structured operation to run"
                      ] )
                ; ( "path"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Target path for ls/cat/rg/find/head/tail/wc/tree" )
                      ] )
                ; ( "cwd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional working directory for \
                             pwd/git_status/git_log/git_diff. Must stay \
                             within the keeper sandbox or an explicit allowed path." )
                      ] )
                ; ( "pattern"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Search pattern for rg, or name glob for find (REQUIRED for \
                             find, e.g. \"*.ml\")" )
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String
                            "Result limit for ls/rg/find/tree, or line count for git_log"
                        )
                      ] )
                ; ( "lines"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String "Number of lines for head/tail (default 20, max 200)" )
                      ] )
                ; ( "max_bytes"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Max bytes for cat"
                      ] )
                ] )
          ; "required", `List [ `String "op" ]
          ]
    }
  ]
;;
