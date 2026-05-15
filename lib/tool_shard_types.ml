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
