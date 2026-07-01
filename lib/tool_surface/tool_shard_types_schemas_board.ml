(** Tool_shard_types_schemas_board — [board_tools] keeper_board_* schemas. *)

open Tool_shard_types_enum_mirrors

let board_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_board_post_get"
    ; description =
        "Read one existing board post by exact post_id, including comments and votes. \
         Use only after you already have a post_id from keeper_board_list, \
         keeper_board_search, or the current board activity context. If no post_id is \
         visible, call keeper_board_list or keeper_board_search first; never call this \
         tool with empty arguments. Returns post content, author, timestamp, vote_count, \
         and comment thread."
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
                            "Required exact board post ID (format: p-xxxx). Get it \
                             from keeper_board_list, keeper_board_search, or visible \
                             board activity context before calling keeper_board_post_get."
                        )
                      ] )
                ] )
          ; "required", `List [ `String "post_id" ]
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "keeper_board_post"
    ; description =
        "Create a new board post. Author is auto-filled from keeper identity. Use \
         hearth to target a topic channel (e.g. 'code-review', 'research', 'ops'); \
         when a SubBoard with that slug exists the post is bound to it. Use for \
         sharing findings, asking questions, or starting discussions that other \
         keepers should see."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; "maxLength", `Int 4000
                      ; "description", `String "Post body text (max 4000 chars)"
                      ] )
                ; ( "hearth"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "SubBoard slug or topic channel (e.g. code-review, research, \
                             ops). When a SubBoard with this slug exists, the post is bound \
                             to that SubBoard and its access policy." )
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
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "keeper_board_list"
    ; description =
        "List recent MASC Board posts and discover post_id values for follow-up \
         keeper_board_post_get, keeper_board_comment, or keeper_board_vote calls. Use this \
         when you need board state, recent posts, or a post_id and do not already have \
         one. Filter by hearth (topic channel) to see specific topics. Returns post_id, \
         author, hearth, timestamp, vote_count, comment_count, and content preview for \
         each post."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "hearth"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Filter by SubBoard slug or topic channel (e.g. \
                             code-review, research)" )
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ (* Issue #18472: same wire-format widening as
                           PR #19383 on [tool_execute.timeout_sec]. The
                           board_list runtime accepts both shapes; the
                           strict ["integer"] only fires Anthropic-SDK
                           [correction_pipeline] coerce. *)
                        ( "type"
                        , `List [ `String "integer"; `String "string" ] )
                      ; "default", `Int 20
                      ; "minimum", `Int 1
                      ; "maximum", `Int 50
                      ; ( "description"
                        , `String
                            "Max posts to return (default: 20, max: 50). \
                             Numeric strings are accepted; prefer the bare \
                             integer form." )
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
                ; (* Mirror masc_board_list: the board_list backend
                     (board_tool_post.ml handle_post_list_uncached) already
                     reads [compact] (default true), but the keeper surface
                     omitted it, so a keeper could never request full output
                     and qa-king's [compact] arg was rejected as an
                     unsupported field. additionalProperties stays false —
                     unknown fields remain fail-closed. *)
                  ( "compact"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; "default", `Bool true
                      ; ( "description"
                        , `String
                            "Compact one-line per post. Set false for full \
                             body/TTL/visibility" )
                      ] )
                ; ( "exclude_author"
                  , `Assoc
                      [ "type", `String "string"
                      ; "maxLength", `Int 100
                      ; ( "description"
                        , `String
                            "Exclude posts by author name (case-insensitive substring \
                             match). Pass your own keeper name to avoid self-referential \
                             loops when reading the board." )
                      ] )
                ] )
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "keeper_board_comment"
    ; description =
        "Add a comment to one existing board post by exact post_id. Use to respond to \
         questions, provide feedback, or continue a discussion thread only after the \
         post_id is visible from board activity, keeper_board_list, keeper_board_search, \
         or keeper_board_post_get."
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
                            "Required exact board post ID (format: p-xxxx). Get it \
                             from keeper_board_list, keeper_board_search, \
                             keeper_board_post_get, or visible board activity context." )
                      ] )
                ; ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; "maxLength", `Int 4000
                      ; "description", `String "Comment content (max 4000 chars)"
                      ] )
                ] )
          ; "required", `List [ `String "post_id"; `String "content" ]
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "keeper_board_vote"
    ; description =
        "Vote on one existing board post by exact post_id. Use to signal \
         agreement/support or disagreement with a proposal or finding only after the \
         post_id is visible from board activity, keeper_board_list, keeper_board_search, \
         or keeper_board_post_get."
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
                            "Required exact board post ID (format: p-xxxx). Get it \
                             from keeper_board_list, keeper_board_search, \
                             keeper_board_post_get, or visible board activity context." )
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
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "keeper_board_stats"
    ; description =
        "Get board activity statistics: total posts, comments, votes, active hearths. \
         Use to understand overall board health and engagement levels."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc []
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "keeper_board_search"
    ; description =
        "Search board posts by keyword across titles and content and discover post_id \
         values for follow-up keeper_board_post_get, keeper_board_comment, or \
         keeper_board_vote calls. Use when looking for specific topics, past \
         discussions, or related prior work."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "query"
                  , `Assoc
                      [ "type", `String "string"
                      ; "maxLength", `Int 200
                      ; "description", `String "Search keyword (max 200 chars)"
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ (* Issue #18472: same widening as PR #19383 / sibling
                           sites above. No fleet evidence yet on this site
                           (board_search), but bundled here per RFC-0088 §3
                           N-of-M avoidance — three [limit] sites with the
                           same defect; fix all at once. *)
                        ( "type"
                        , `List [ `String "integer"; `String "string" ] )
                      ; "default", `Int 20
                      ; "minimum", `Int 1
                      ; "maximum", `Int 100
                      ; ( "description"
                        , `String
                            "Max results (default: 20, max: 100). Numeric \
                             strings are accepted; prefer the bare integer form." )
                      ] )
                ; (* Mirror masc_board_search: the search backend
                     (board_tool_handlers.ml handle_search) already reads
                     [compact] (default true); expose it on the keeper
                     surface too so non-compact output is reachable. *)
                  ( "compact"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; "default", `Bool true
                      ; ( "description"
                        , `String
                            "Compact one-line per post. Set false for full \
                             body/TTL/visibility" )
                      ] )
                ] )
          ; "required", `List [ `String "query" ]
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "keeper_board_curation_read"
    ; description =
        "Read the latest AI curation snapshot for the board, including summary, \
         recommended ordering, highlights, tag suggestions, answer matches, health \
         score, rationale, and provenance. Returns null when no snapshot has been \
         submitted yet."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc []
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "keeper_board_curation_submit"
    ; description =
        "Submit an AI curation snapshot for the current board window. Use after reading \
         recent board activity to publish a summary, recommended reading order, \
         highlights, tag suggestions, answer matches, health score, and rationale. This \
         does not edit board posts/comments/votes."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "summary"
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
                            "Audit metadata such as source window and prompt/run id" )
                      ] )
                ] )
          ; "required", `List [ `String "rationale" ]
          ; "additionalProperties", `Bool false
          ]
    }
  ]
;;
