(** Tool_shard_types_schemas_filesystem — [filesystem_tools] keeper_fs_* + keeper_ide_annotate schemas. *)

open Tool_shard_types_enum_mirrors

let filesystem_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_fs_read"
    ; description =
        "Read a file as text (truncated at max_bytes). path is REQUIRED. Paths resolve \
         relative to your playground — use 'repos/X/lib/foo.ml' not \
         '.masc/playground/your-name/repos/X/lib/foo.ml'. Good: path='lib/foo.ml', \
         path='repos/masc-mcp/lib/room.ml'. Bad: path=''. For multi-file search, use \
         keeper_shell with op=rg."
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
                             ^ Tool_shard_limits.keeper_fs_read_default_max_bytes_string
                             ^ ")") )
                      ] )
                ] )
          ; "required", `List [ `String "path" ]
          ]
    }
  ; { name = "keeper_fs_edit"
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
           [Keeper_exec_fs.valid_fs_write_mode_strings]. *)
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
  ; { name = "keeper_ide_annotate"
    ; description =
        "Attach a keeper-authored annotation to a source file line range. Use this to \
         leave durable IDE context that links code to goal/task/board/comment/PR/git/log \
         evidence. file_path, line_start, and content are required; optional route \
         fields are preserved for dashboard Context Lens links."
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
                ; ( "goal_id"
                  , `Assoc [ "type", `String "string"; "description", `String "Optional Goal route id" ] )
                ; ( "task_id"
                  , `Assoc [ "type", `String "string"; "description", `String "Optional Task route id" ] )
                ; ( "board_post_id"
                  , `Assoc [ "type", `String "string"; "description", `String "Optional Board post route id" ] )
                ; ( "comment_id"
                  , `Assoc [ "type", `String "string"; "description", `String "Optional Board/GitHub comment route id" ] )
                ; ( "pr_id"
                  , `Assoc [ "type", `String "string"; "description", `String "Optional PR number or id" ] )
                ; ( "git_ref"
                  , `Assoc [ "type", `String "string"; "description", `String "Optional branch, commit, or ref" ] )
                ; ( "log_id"
                  , `Assoc [ "type", `String "string"; "description", `String "Optional runtime audit log id" ] )
                ; ( "session_id"
                  , `Assoc [ "type", `String "string"; "description", `String "Optional telemetry session id" ] )
                ; ( "operation_id"
                  , `Assoc [ "type", `String "string"; "description", `String "Optional telemetry operation id" ] )
                ; ( "worker_run_id"
                  , `Assoc [ "type", `String "string"; "description", `String "Optional telemetry worker run id" ] )
                ] )
          ; "required", `List [ `String "file_path"; `String "line_start"; `String "content" ]
          ]
    }
  ]
;;
