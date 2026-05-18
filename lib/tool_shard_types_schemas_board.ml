(** Tool_shard_types_schemas_board — [board_tools] keeper_board_* schemas. *)

open Tool_shard_types_enum_mirrors

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
