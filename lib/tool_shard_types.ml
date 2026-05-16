(** Tool_shard_types — pure types + enum-string SSOT mirrors extracted
    from Tool_shard (2165 LoC godfile).

    See tool_shard_types.mli for rationale and contract. *)

let pr_review_event_enum_strings = [ "COMMENT"; "APPROVE"; "REQUEST_CHANGES" ]

let memory_search_source_enum_strings = [ "memory"; "history"; "all" ]

let memory_kind_enum_strings =
  [ "constraints"; "decision"; "next"; "goal"; "progress"; "open_question"; "long_term" ]
;;

let fs_write_mode_enum_strings = [ "overwrite"; "append"; "patch" ]

let sort_order_enum_strings = [ "hot"; "trending"; "recent"; "updated"; "discussed" ]

let vote_direction_enum_strings = [ "up"; "down" ]

let keeper_shell_op_enum_strings =
  [ "pwd"
  ; "ls"
  ; "cat"
  ; "rg"
  ; "git_status"
  ; "find"
  ; "head"
  ; "tail"
  ; "wc"
  ; "tree"
  ; "git_log"
  ; "git_diff"
  ; "git_worktree"
  ; "git_clone"
  ; "gh"
  ]
;;

type shard =
  { name : string
  ; tools : Masc_domain.tool_schema list
  ; read_only_tools : string list
  ; removable : bool
  ; description : string
  }

module StringMap = Map.Make (String)

let select_named_schemas (names : string list) (schemas : Masc_domain.tool_schema list)
  : Masc_domain.tool_schema list
  =
  names
  |> List.filter_map (fun name ->
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
      schemas)
;;

let default_shard_names : string list =
  [ "base"
  ; "board"
  ; "filesystem"
  ; "shell"
  ; "library"
  ; "taskboard"
  ; "coding"
  ]
;;

let tool_spec_read_only = [ "masc_tool_list" ]
let tool_spec_destructive = [ "masc_tool_grant"; "masc_tool_revoke" ]

let tool_required_permission = function
  | "masc_tool_list" -> Some Masc_domain.CanReadState
  | "masc_tool_grant" | "masc_tool_revoke" -> Some Masc_domain.CanAdmin
  | _ -> None
;;

let tool_effect_domain name =
  match Tool_name.of_string name with
  | Some (Tool_name.Masc Tool_name.Masc.Tool_list) -> Some Tool_catalog.Read_only
  | Some (Tool_name.Masc (Tool_name.Masc.Tool_grant | Tool_name.Masc.Tool_revoke)) ->
    Some Tool_catalog.Masc_coordination
  | _ -> None
;;
let base_tools : Masc_domain.tool_schema list =
  [ (* Stay silent: no-op tool for tool_choice=Any turns.
     Lets the model explicitly skip a turn without being forced
     to call a real tool when there is nothing to do. *)
    { name = "keeper_stay_silent"
    ; description =
        "Do nothing this turn. Call when you have no pending work and no information to \
         share. Costs no resources. Prefer this over calling a tool with no purpose."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; (* Time *)
    { name = "keeper_time_now"
    ; description =
        "Get current server time. Returns now_iso (ISO8601) and now_unix (float). Use to \
         timestamp events, check elapsed time, or include current time in reports."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; (* Context status *)
    { name = "keeper_context_status"
    ; description =
        "Check your own context window usage and session state. Returns: name (your \
         keeper name), context_ratio (0.0-1.0), context_tokens, context_max, \
         message_count, generation, last_model_used, continuity_summary, and canonical \
         sandbox paths (sandbox_root, sandbox_mind, sandbox_repos) plus backend/profile \
         metadata. sandbox paths are tool-ready and can be passed directly as path or \
         cwd to keeper tools without prefix. Use when deciding whether to compact \
         context, extend turns, hand off to the next generation, or resolve a path \
         without string-interpolating your own keeper name."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; (* Memory *)
    { name = "keeper_memory_search"
    ; description =
        "Search memory for past goals, decisions, progress, or conversation history. \
         Returns scored results with metadata. Default searches the structured memory \
         bank. Use 'kind' to filter (goal, decision, progress, next, open_question, \
         constraints, long_term). Use source='history' for raw user messages, \
         source='all' for both."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "query"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "keyword to search for"
                      ] )
                ; ( "kind"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List (List.map (fun s -> `String s) memory_kind_enum_strings) )
                      ; "description", `String "Filter by memory kind"
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "max results (1-10, default 5)"
                      ] )
                ; (* Issue #8484: derive from local mirror that tracks
           [Keeper_exec_memory.valid_memory_search_source_strings]. *)
                  ( "source"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map
                               (fun s -> `String s)
                               memory_search_source_enum_strings) )
                      ; ( "description"
                        , `String
                            "Search scope: memory (default, structured notes), history \
                             (raw messages), or all" )
                      ] )
                ] )
          ; "required", `List [ `String "query" ]
          ]
    }
  ; (* RFC-0035 P4: explicit memory write surface.
     Symmetric to keeper_memory_search; promotes a structured note
     (kind/title/content) into the memory bank, queryable on later
     turns. long_term kind is reserved for tool-result emission and
     is rejected here. *)
    { name = "keeper_memory_write"
    ; description =
        "Promote a structured decision/question/goal/etc into the memory bank, queryable \
         on later turns by keeper_memory_search. Use when board discussion converges to \
         a fact worth crystallizing, or to record a constraint, open question, next \
         step, or progress note. Subject to per-kind cap (typically 2) and total cap \
         (12); oldest may be dropped. 'long_term' kind is reserved for tool-result \
         emission and is not callable here."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "kind"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List (List.map (fun s -> `String s) memory_kind_enum_strings) )
                      ; ( "description"
                        , `String
                            "Memory kind. One of \
                             goal/progress/next/decision/open_question/constraints. \
                             long_term not supported." )
                      ] )
                ; ( "title"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Short hook (≤120 chars). Optional; may be empty." )
                      ] )
                ; ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Body. Required, must be non-empty. For \
                             decisions/constraints, lead with the rule then **Why** and \
                             **How to apply** lines." )
                      ] )
                ] )
          ; "required", `List [ `String "kind"; `String "content" ]
          ]
    }
  ; (* Tool self-introspection — lets the keeper enumerate its own capabilities *)
    { name = "keeper_tools_list"
    ; description =
        "List all tools currently available to you, grouped by category. Use when asked \
         'what can you do?' or when you need to discover your capabilities. Returns tool \
         names organized by category. Only includes tools allowed by your current preset \
         and policy."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ]
;;
let board_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_board_get"
    ; description =
        "Read a single board post with all its comments and votes. Use before deciding \
         to comment, vote, or escalate. Returns post content, author, timestamp, \
         vote_count, and comment thread. post_id format: 'p-xxxx'. Get post_id from \
         keeper_board_list results."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "post_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Post ID (format: p-xxxx). Get from keeper_board_list."
                        )
                      ] )
                ] )
          ; "required", `List [ `String "post_id" ]
          ]
    }
  ; { name = "keeper_board_post"
    ; description =
        "Create a new board post with content. Use hearth to target a topic channel \
         (e.g. 'code-review', 'research', 'ops'). Use for sharing findings, asking \
         questions, or starting discussions that other keepers should see."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Post content (max 4000 chars)"
                      ] )
                ; ( "hearth"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Topic channel name (e.g. code-review, research, ops)" )
                      ] )
                ; ( "thread_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Linked conversation thread ID (optional)"
                      ] )
                ; ( "classification_reason"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional explicit rationale for why this should appear as \
                             automation/direct in board views" )
                      ] )
                ; ( "judgment"
                  , `Assoc
                      [ "type", `String "object"
                      ; ( "description"
                        , `String
                            "Optional structured LLM judgment metadata. Use summary or \
                             reason to preserve why you posted/classified it this way" )
                      ] )
                ; ( "sources"
                  , `Assoc
                      [ "type", `String "array"
                      ; ( "description"
                        , `String
                            "Optional external evidence sources appended to the post and \
                             persisted in meta.sources" )
                      ; ( "items"
                        , `Assoc
                            [ "type", `String "object"
                            ; ( "properties"
                              , `Assoc
                                  [ ( "url"
                                    , `Assoc
                                        [ "type", `String "string"
                                        ; "description", `String "Source URL"
                                        ] )
                                  ; ( "quote"
                                    , `Assoc
                                        [ "type", `String "string"
                                        ; ( "description"
                                          , `String "Short relevant quote or snippet" )
                                        ] )
                                  ] )
                            ] )
                      ] )
                ; ( "quantitative_evidence"
                  , `Assoc
                      [ ( "type"
                        , `List [ `String "object"; `String "string"; `String "array" ] )
                      ; ( "description"
                        , `String
                            "Required for code-count or line-number claims. Include the \
                             exact command/output or checked count that supports the \
                             quantitative claim." )
                      ] )
                ] )
          ; "required", `List [ `String "content" ]
          ]
    }
  ; { name = "keeper_board_list"
    ; description =
        "List recent posts on the MASC Board. Filter by hearth (topic channel) to see \
         specific topics. Returns post_id, author, hearth, timestamp, vote_count, \
         comment_count, and content preview for each post."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "hearth"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Filter by topic channel (e.g. code-review, research)" )
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String "Max posts to return (default: 20, max: 50)" )
                      ] )
                ; (* Issue #8513: derive from local mirror tracking
           [Board_dispatch.valid_sort_order_strings].  Schema used to
           expose only 3 of 5 sort orders. *)
                  ( "sort_by"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List (List.map (fun s -> `String s) sort_order_enum_strings) )
                      ; "description", `String "Sort order (default: recent)"
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_board_comment"
    ; description =
        "Add a comment to a board post by post_id. Use to respond to questions, provide \
         feedback, or continue a discussion thread."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "post_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Post ID (format: p-xxxx...). Get from keeper_board_list \
                             results." )
                      ] )
                ; ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Comment content"
                      ] )
                ] )
          ; "required", `List [ `String "post_id"; `String "content" ]
          ]
    }
  ; { name = "keeper_board_vote"
    ; description =
        "Vote on a board post (up or down). Use to signal agreement/support or \
         disagreement with a proposal or finding."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "post_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Post ID (format: p-xxxx...). Get from keeper_board_list \
                             results." )
                      ] )
                ; (* Issue #8506: derive from local mirror that tracks
           [Board_votes.valid_vote_direction_strings]. *)
                  ( "direction"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map (fun s -> `String s) vote_direction_enum_strings) )
                      ; "description", `String "Vote direction (default: up)"
                      ] )
                ] )
          ; "required", `List [ `String "post_id" ]
          ]
    }
  ; { name = "keeper_board_stats"
    ; description =
        "Get board activity statistics: total posts, comments, votes, active hearths. \
         Use to understand overall board health and engagement levels."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; { name = "keeper_board_search"
    ; description =
        "Search board posts by keyword across titles and content. Use when looking for \
         specific topics, past discussions, or related prior work."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "query"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Search keyword"
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Max results (default: 20)"
                      ] )
                ] )
          ; "required", `List [ `String "query" ]
          ]
    }
  ; { name = "keeper_board_curation_read"
    ; description =
        "Read the latest AI curation snapshot for the board, including summary, \
         recommended ordering, highlights, tag suggestions, answer matches, health \
         score, rationale, and provenance. Returns null when no snapshot has been \
         submitted yet."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; { name = "keeper_board_curation_submit"
    ; description =
        "Submit an AI curation snapshot for the current board window. Use after reading \
         recent board activity to publish a summary, recommended reading order, \
         highlights, tag suggestions, answer matches, health score, and rationale. This \
         does not edit board posts/comments/votes; submitted_by is filled from your \
         keeper identity."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "model"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Model or provider label used for the curation" )
                      ] )
                ; ( "summary"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Short TL;DR summary of the current board window" )
                      ] )
                ; ( "ordering"
                  , `Assoc
                      [ "type", `String "array"
                      ; "items", `Assoc [ "type", `String "string" ]
                      ; "description", `String "Recommended post id reading order"
                      ] )
                ; ( "highlights"
                  , `Assoc
                      [ "type", `String "array"
                      ; "items", `Assoc [ "type", `String "string" ]
                      ; "description", `String "Important post ids to highlight"
                      ] )
                ; ( "tag_suggestions"
                  , `Assoc
                      [ "type", `String "array"
                      ; "description", `String "Objects with post_id, tags[], rationale"
                      ] )
                ; ( "answer_matches"
                  , `Assoc
                      [ "type", `String "array"
                      ; ( "description"
                        , `String
                            "Objects with question_post_id, answer_post_id, score, \
                             rationale" )
                      ] )
                ; ( "health_score"
                  , `Assoc
                      [ "type", `String "number"
                      ; "minimum", `Float 0.0
                      ; "maximum", `Float 1.0
                      ; ( "description"
                        , `String "Optional normalized health score in [0.0, 1.0]" )
                      ] )
                ; ( "health_components"
                  , `Assoc
                      [ "type", `String "array"
                      ; ( "description"
                        , `String "Objects with name, score, weight, rationale" )
                      ] )
                ; ( "rationale"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Why this curation snapshot is useful now"
                      ] )
                ; ( "provenance"
                  , `Assoc
                      [ "type", `String "object"
                      ; ( "description"
                        , `String
                            "Audit metadata such as source window, prompt/run id, and \
                             model params" )
                      ] )
                ] )
          ; "required", `List [ `String "rationale" ]
          ]
    }
  ; { name = "keeper_board_delete"
    ; description =
        "Delete a board post by post_id. Use only for generated garbage, expired \
         automation, or other explicitly-approved cleanup cases."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "post_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Post ID to delete"
                      ] )
                ] )
          ; "required", `List [ `String "post_id" ]
          ]
    }
  ; { name = "keeper_board_cleanup"
    ; description =
        "Batch scan and cleanup board posts matching filter criteria. Defaults to \
         dry_run=true (report candidates only). Set dry_run=false to delete matched \
         posts. Safe defaults: only targets posts older than 24h with no comments and no \
         votes."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "max_age_hours"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String
                            "Only target posts older than this many hours (default: 24)" )
                      ] )
                ; ( "title_pattern"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Substring filter on post title (case-insensitive)" )
                      ] )
                ; ( "author_pattern"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Substring filter on post author (case-insensitive)" )
                      ] )
                ; ( "dry_run"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; ( "description"
                        , `String "If true (default), report candidates without deleting"
                        )
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String "Max posts to process (default: 10, max: 50)" )
                      ] )
                ] )
          ; "required", `List []
          ]
    }
  ]
;;
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
let shell_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_shell"
    ; description =
        "Run a structured project shell operation. ops: pwd, ls, cat, rg, git_status, \
         find, head, tail, wc, tree, git_log, git_diff, git_worktree, git_clone, gh. \
         Structured ops default to the keeper sandbox. IMPORTANT: paths resolve \
         automatically — use 'repos/X' or 'mind/X'. Never include host paths like \
         '.masc/playground/your-name/repos/X' in path or cwd. Use cwd to target an \
         explicit allowed directory or cloned repo. find REQUIRES pattern param (e.g. \
         pattern=\"*.ml\"). No generic bash execution: use Bash/keeper_bash for command \
         execution. git_clone: clone a repo into your sandbox repos/ lane (url \
         required). gh op: run a gh CLI subcommand with cmd=\"<subcommand>\" (e.g. \
         cmd=\"pr list --state open\"). Requires an active claimed task/current_task_id \
         because repo context is derived from the task worktree. Always run `gh pr list` \
         first before referencing a PR number to avoid hallucinations. Dangerous \
         commands (repo delete, auth logout, secret set/delete) are blocked. If path not \
         found, clone the repo first with op=git_clone. Use rg for pattern search, find \
         for path discovery, head/tail for line ranges, git_log/git_diff for repo \
         history, gh for GitHub PR/issue/CI."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ (* Issue #8524: derive from local mirror tracking
           [Keeper_exec_shell.valid_shell_op_strings].  Schema used to
           omit git_worktree even though the handler accepted it. *)
                  ( "op"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map (fun s -> `String s) keeper_shell_op_enum_strings) )
                      ; "description", `String "Structured operation to run"
                      ] )
                ; ( "cmd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "gh subcommand for op=gh, e.g. 'pr list --state open'. \
                             Requires an active claimed task/current_task_id. The active \
                             task worktree determines the repo; any --repo flag is \
                             normalized to that repo." )
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
                             pwd/git_status/git_log/git_diff/git_worktree. Must stay \
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
                ; ( "url"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Git repo URL for git_clone op (e.g. \
                             'https://github.com/org/repo'). Clones into sandbox repos/."
                        )
                      ] )
                ] )
          ; "required", `List [ `String "op" ]
          ]
    }
  ]
;;
let coding_keeper_bridge_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_bash"
    ; description =
        "Execute ONE shell command through the keeper_bash safety gates. No \
         chaining/control syntax (&&, ||, ;), command substitution, background \
         operators, or file redirects. Pipelines and fd-only redirects are accepted only \
         when the active preset validator allows every segment. Good: cmd='dune build', \
         cmd='ls -la lib/'. Bad: cmd='cd x && dune build', cmd='echo hi > out.txt'. Runs \
         in the keeper sandbox by default; use cwd to target an explicit allowed \
         directory. Paths resolve automatically — never include host storage prefixes \
         such as '.masc/playground/your-name/' in cwd. Use 'repos/X' instead. Sandbox \
         root is NOT a git repository: git/gh calls require cwd='repos/<REPO_NAME>' (or \
         the worktree path under it). 'not a git repository' or 'path_outside_sandbox' \
         from the sandbox root means you forgot the cwd. For read-only ops use \
         keeper_shell, for file edits use keeper_fs_edit. Set run_in_background=true for \
         long-running tasks (returns background_task_id; poll with keeper_bash_output, \
         terminate with keeper_bash_kill)."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "cmd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Single command only. No chaining/control syntax or file \
                             redirects. Example: 'dune build', 'rg pattern lib/'" )
                      ] )
                ; ( "cwd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional working directory for the command. Must stay \
                             within the keeper sandbox or an explicit allowed path." )
                      ] )
                ; ( "timeout_sec"
                  , `Assoc
                      [ "type", `String "number"
                      ; ( "description"
                        , `String
                            "Timeout seconds (default: 30, max: 180). For \
                             run_in_background=true, 0 disables the timeout." )
                      ] )
                ; ( "run_in_background"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; ( "description"
                        , `String
                            "Default false. When true, returns immediately with \
                             background_task_id; poll output via keeper_bash_output, \
                             stop via keeper_bash_kill." )
                      ] )
                ] )
          ; "required", `List [ `String "cmd" ]
          ]
    }
  ; { name = "keeper_bash_output"
    ; description =
        "Fetch incremental output from a background shell task spawned via keeper_bash \
         with run_in_background=true. Non-blocking: returns whatever stdout/stderr bytes \
         are currently buffered beyond the given offsets. Poll repeatedly until \
         closed=true. Mirrors claude-code BashOutput semantics."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "task_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "background_task_id returned by keeper_bash. Example: \
                             'bgt-1713600000-000001-12345'." )
                      ] )
                ; ( "since_stdout"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String
                            "Cumulative byte offset at which to start reading stdout. \
                             Use 0 for the first call, then the running length returned \
                             previously." )
                      ] )
                ; ( "since_stderr"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String
                            "Same cursor for stderr. Note: in the current implementation \
                             keeper_bash redirects stderr into stdout so stderr_since is \
                             usually empty." )
                      ] )
                ] )
          ; "required", `List [ `String "task_id" ]
          ]
    }
  ; { name = "keeper_bash_kill"
    ; description =
        "Terminate a background shell task. Sends [signal] (default SIGTERM) to the \
         task's process group, waits up to grace_sec seconds, and escalates to SIGKILL \
         if any member survives. Idempotent — safe to call on already-exited tasks. \
         Mirrors claude-code KillShell semantics."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "task_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "background_task_id returned by keeper_bash." )
                      ] )
                ; ( "signal"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Signal name (TERM, KILL, INT, HUP, QUIT) or number. Default \
                             TERM." )
                      ] )
                ; ( "grace_sec"
                  , `Assoc
                      [ "type", `String "number"
                      ; ( "description"
                        , `String
                            "Seconds to wait for graceful exit before SIGKILL \
                             escalation. Default 2.0, max 30." )
                      ] )
                ] )
          ; "required", `List [ `String "task_id" ]
          ]
    }
  ]
;;

(** PR review tools — read diffs, leave comments, approve/request changes. *)
let keeper_pr_review_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_pr_review_read"
    ; description =
        "Read PR metadata, diff, reviews, and comments. Returns title, body, changed \
         files, review threads, and truncated diff (max 64KB). Read-only. Pass the PR \
         number as `pr_number` (preferred) or `number` (legacy alias)."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "GitHub repo (owner/name)"
                      ] )
                ; ( "pr_number"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "PR number (preferred field name)"
                      ] )
                ; ( "number"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "PR number (legacy alias for pr_number)"
                      ] )
                ] )
          ; (* No `required` for the number — the handler reads either
         pr_number or number and emits a clear error if both are
         missing. Schema-level required=[number] rejected callers
         that learned the historical pr_number key. *)
            "required", `List [ `String "repo" ]
          ]
    }
  ; { name = "keeper_pr_review_comment"
    ; description =
        "Submit a PR review with optional inline comments. Events: COMMENT, APPROVE, \
         REQUEST_CHANGES. Requires research, delivery, coding, or full preset. Use \
         REQUEST_CHANGES for actionable blockers; use APPROVE only when the draft proof \
         preflight permits it. Pass the PR number as `pr_number` (preferred) or `number` \
         (legacy alias)."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "GitHub repo (owner/name)"
                      ] )
                ; ( "pr_number"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "PR number (preferred field name)"
                      ] )
                ; ( "number"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "PR number (legacy alias for pr_number)"
                      ] )
                ; ( "body"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Review body text"
                      ] )
                ; (* Issue #8480: mirrors [Keeper_tool_pr_review.valid_pr_review_event_strings].
           Direct dependency would create a cycle (Tool_shard ->
           Keeper_tool_pr_review -> Keeper_alerting -> Tool_shard), so the
           sync regression test [test_types.ml :: pr_review_event_ssot]
           asserts these stay in lock-step. Same pattern as #8467
           (sandbox_profile / network_mode). *)
                  ( "event"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map (fun s -> `String s) pr_review_event_enum_strings) )
                      ; "description", `String "Review event type"
                      ] )
                ; ( "path"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "File path for inline comment (optional)"
                      ] )
                ; ( "line"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Line number for inline comment (optional)"
                      ] )
                ] )
          ; "required", `List [ `String "repo"; `String "body"; `String "event" ]
          ]
    }
  ; { name = "keeper_pr_review_reply"
    ; description =
        "Reply to a specific PR review comment. Requires research, delivery, coding, or \
         full preset. Pass the PR number as `pr_number` (preferred) or `number` (legacy \
         alias)."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "GitHub repo (owner/name)"
                      ] )
                ; ( "pr_number"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "PR number (preferred field name)"
                      ] )
                ; ( "number"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "PR number (legacy alias for pr_number)"
                      ] )
                ; ( "comment_id"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Comment ID to reply to"
                      ] )
                ; ( "body"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Reply body text"
                      ] )
                ] )
          ; "required", `List [ `String "repo"; `String "comment_id"; `String "body" ]
          ]
    }
  ]
;;

let coding_workspace_tool_names : string list =
  [ "masc_worktree_create"
  ; "masc_worktree_list"
  ; "masc_code_search"
  ; "masc_code_symbols"
  ; "masc_code_read"
  ]
;;

(* coding_keeper_bridge_tools schema list moved to Tool_shard_types. *)
(** Pre-flight validation for keeper autonomous work. *)
let keeper_preflight_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_preflight_check"
    ; description =
        "Validate prerequisites before starting autonomous work: gh auth, repo access, \
         keeper identity, preset level, cascade resilience, autonomous activation, repo \
         readiness. Returns structured JSON with all check results. Read-only, no side \
         effects."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "GitHub repo (owner/name) to check access for" )
                      ] )
                ; ( "repo_name"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional sandbox repo directory name under repos/ when it \
                             differs from the GitHub repo basename" )
                      ] )
                ] )
          ; "required", `List [ `String "repo" ]
          ]
    }
  ]
;;

(** Dedicated GitHub PR workflow tools. *)
let keeper_github_pr_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_pr_list"
    ; description =
        "List GitHub pull requests with keeper-scoped credentials. Runs credential \
         preflight before gh, accepts repo owner/name or cwd, and returns gh JSON. \
         Read-only."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "GitHub repo (owner/name). Optional when cwd is a git repo." )
                      ] )
                ; ( "cwd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Optional keeper sandbox repo/worktree cwd." )
                      ] )
                ; ( "state"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            [ `String "open"
                            ; `String "closed"
                            ; `String "merged"
                            ; `String "all"
                            ] )
                      ; "description", `String "PR state filter. Default open."
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Max PRs to return, 1-100. Default 20."
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_pr_status"
    ; description =
        "Read one GitHub PR status/details with keeper-scoped credentials. Runs \
         credential preflight before gh. Pass pr_number (preferred) or number."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "GitHub repo (owner/name). Optional when cwd is a git repo." )
                      ] )
                ; ( "cwd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Optional keeper sandbox repo/worktree cwd." )
                      ] )
                ; ( "pr_number"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "PR number (preferred field name)"
                      ] )
                ; ( "number"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "PR number (legacy alias for pr_number)"
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_pr_create"
    ; description =
        "Create a draft GitHub pull request with keeper-scoped credentials. Draft-only \
         by policy: omit draft or set draft=true. Requires delivery, coding, or full \
         preset."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "GitHub repo (owner/name). Optional when cwd is a git repo." )
                      ] )
                ; ( "cwd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Keeper sandbox repo/worktree cwd. Required when repo cannot \
                             infer the branch context." )
                      ] )
                ; ( "title"
                  , `Assoc [ "type", `String "string"; "description", `String "PR title" ]
                  )
                ; ( "body"
                  , `Assoc [ "type", `String "string"; "description", `String "PR body" ]
                  )
                ; ( "base"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Optional base branch"
                      ] )
                ; ( "head"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Optional head branch"
                      ] )
                ; ( "draft"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; ( "description"
                        , `String
                            "Must be true if provided; ready PR creation is rejected." )
                      ] )
                ] )
          ; "required", `List [ `String "title"; `String "body" ]
          ]
    }
  ]
;;
