(** Tool_shard_types_schemas_filesystem — [filesystem_tools] tool_* file schemas + keeper_ide_annotate. *)

open Tool_shard_types_enum_mirrors

let filesystem_tools : Masc_domain.tool_schema list =
  [ { name = "tool_read_file"
    ; description =
        "Read a file as text (truncated at max_bytes). path is REQUIRED. Paths resolve \
         relative to your playground — use 'repos/X/lib/foo.ml' not \
         '.masc/playground/your-name/repos/X/lib/foo.ml'. Good: path='lib/foo.ml', \
         path='repos/masc/lib/workspace.ml'. Bad: path=''. For multi-file search, use \
         Grep."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "path"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Relative or absolute file path"
                      ] )
                ; ( "max_bytes"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String
                            ("Max bytes to return (default: "
                             ^ Tool_shard_limits.read_file_default_max_bytes_string
                             ^ ")") )
                      ] )
                ] )
          ; "required", `List [ `String "path" ]
          ]
    }
  ; { name = "tool_edit_file"
    ; description =
        "Write, append, or patch a file. path is required. For mode='overwrite' \
         (default) or 'append', content is required and non-empty. For mode='patch', \
         old_string and new_string are required; old_string must match exactly once \
         unless replace_all=true. Good overwrite: path='lib/foo.ml', content='let x = \
         1'. Good patch: path='lib/foo.ml', mode='patch', old_string='old', \
         new_string='new'. Bad: path='', content=''. Bad: mode='create' (use \
         overwrite). Creates parent dirs."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "path"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Relative or absolute file path to write"
                      ] )
                ; ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "File content to write"
                      ] )
                ; ( "old_string"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Patch mode substring to replace"
                      ] )
                ; ( "new_string"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Patch mode replacement substring"
                      ] )
                ; ( "replace_all"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; "description", `String "Patch every occurrence instead of exactly one"
                      ] )
                ; (* Issue #8490: derive from local mirror that tracks
           [Keeper_tool_filesystem_runtime.valid_fs_write_mode_strings]. *)
                  ( "mode"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List (List.map (fun s -> `String s) fs_write_mode_enum_strings)
                        )
                      ; "description", `String "Write mode (default: overwrite)"
                      ] )
                ] )
          ; "required", `List [ `String "path" ]
          ]
    }
  ; { name = "tool_write_file"
    ; description =
        "Write or append a file. path is required. For mode='overwrite' (default) or \
         'append', content is required and non-empty. Good overwrite: path='lib/foo.ml', \
         content='let x = 1'. Bad: path='', content=''. Creates parent dirs."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "path"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Relative or absolute file path to write"
                      ] )
                ; ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "File content to write"
                      ] )
                ; ( "mode"
                  , `Assoc
                      [ "type", `String "string"
                      ; "enum", `List [ `String "overwrite"; `String "append" ]
                      ; "description", `String "Write mode (default: overwrite)"
                      ] )
                ] )
          ; "required", `List [ `String "path"; `String "content" ]
          ]
    }
  ; { name = "keeper_ide_annotate"
    ; description =
        "Attach a keeper-authored annotation to a source file line range. Use this to \
         leave durable IDE context linked to an optional goal, task, or opaque external \
         reference. file_path, line_start, and content are required. The IDE transport \
         stores and renders reference relation/value pairs without interpreting the \
         producer's product vocabulary."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "file_path"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Workspace-relative source file path"
                      ] )
                ; ( "line_start"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "minimum", `Int 1
                      ; "description", `String "First 1-based source line"
                      ] )
                ; ( "line_end"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "minimum", `Int 1
                      ; "description", `String "Last 1-based source line; defaults to line_start"
                      ] )
                ; ( "kind"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            [ `String "Comment"
                            ; `String "Decision"
                            ; `String "Question"
                            ; `String "Bookmark"
                            ] )
                      ; "description", `String "Annotation kind; defaults to Comment"
                      ] )
                ; ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Short annotation text shown in the IDE"
                      ] )
                ; ( "task_id"
                  , `Assoc [ "type", `String "string"; "description", `String "Optional Task route id" ] )
                ; ( "references"
                  , `Assoc
                      [ "type", `String "array"
                      ; ( "items"
                        , `Assoc
                            [ "type", `String "object"
                            ; ( "properties"
                              , `Assoc
                                  [ ( "relation"
                                    , `Assoc
                                        [ "type", `String "string"
                                        ; ( "description"
                                          , `String
                                              "Opaque relation label supplied by the producer"
                                          )
                                        ] )
                                  ; ( "reference"
                                    , `Assoc
                                        [ "type", `String "string"
                                        ; ( "description"
                                          , `String
                                              "Opaque reference value preserved without interpretation"
                                          )
                                        ] )
                                  ] )
                            ; ( "required"
                              , `List [ `String "relation"; `String "reference" ] )
                            ; "additionalProperties", `Bool false
                            ] )
                      ; ( "description"
                        , `String
                            "Optional opaque links rendered by the IDE without product-specific routing"
                        )
                      ] )
                ] )
          ; "required", `List [ `String "file_path"; `String "line_start"; `String "content" ]
          ; "additionalProperties", `Bool false
          ]
    }
  ]
;;
