(** Tool_board_schemas - Board tool schema definitions.
    Extracted from tool_board.ml to reduce godfile size.
*)

let tool_post_create : Masc_domain.tool_schema =
  { name = "masc_board_post"
  ; description =
      "Create a post on the MASC internal board. Pass either `body` or `content` (both \
       accepted — `body` wins if both present). `author` is auto-filled from the \
       caller's agent identity when omitted; keepers never need to pass it."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "title"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "Optional post title"
                    ] )
              ; ( "body"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String "Post body text (preferred alias for `content`)" )
                    ] )
              ; ( "content"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String "Post body text (alternative to `body`, max 4000 chars)" )
                    ] )
              ; ( "author"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "Author name. Auto-filled from caller's agent_name when \
                           omitted." )
                    ] )
              ; ( "meta"
                , `Assoc
                    [ "type", `String "object"
                    ; "description", `String "Optional structured operational metadata"
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
              ; ( "classification_reason"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "Optional explicit classification rationale; persisted into \
                           meta and surfaced by the dashboard" )
                    ] )
              ; ( "judgment"
                , `Assoc
                    [ "type", `String "object"
                    ; ( "description"
                      , `String
                          "Optional structured LLM judgment metadata. Use \
                           summary/reason/confidence keys when you want the board to \
                           retain your classification rationale" )
                    ] )
              ; ( "visibility"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String "public|unlisted|internal|direct (default: internal)" )
                    ] )
              ; ( "ttl_hours"
                , `Assoc
                    [ "type", `String "integer"
                    ; ( "description"
                      , `String "Time-to-live in hours (default: 168, max: 720)" )
                    ] )
              ; ( "hearth"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String "Topic hearth name (e.g. webrtc, code-review)" )
                    ] )
              ; ( "thread_id"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "Linked conversation thread ID"
                    ] )
              ] )
          (* No [required] — handler enforces: body|content must be non-empty,
       and author is auto-injected via Tool_dispatch pre-hook for keepers.
       Schema-level required=[content,author] rejected callers who used
       {title,body} (keeper prompt default) before the handler could run. *)
        ]
  }
;;

let tool_post_list : Masc_domain.tool_schema =
  { name = "masc_board_list"
  ; description = "List posts on the MASC internal board with sorting options"
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "limit"
                , `Assoc
                    [ "type", `String "integer"
                    ; "description", `String "Max posts to return"
                    ; "default", `Int 20
                    ; "minimum", `Int 1
                    ; "maximum", `Int 100
                    ] )
              ; ( "visibility"
                , `Assoc
                    [ "type", `String "string"
                    ; (* Issue #8392: derived from Board_types.visibility Variant SSOT.
           Hand-rolled enum risks dropping a constructor on extension. *)
                      ( "enum"
                      , `List
                          (List.map
                             (fun s -> `String s)
                             Board_core_classify.valid_visibility_strings) )
                    ; ( "description"
                      , `String
                          (Printf.sprintf
                             "Filter by visibility (%s)"
                             (String.concat
                                " | "
                                Board_core_classify.valid_visibility_strings)) )
                    ] )
              ; ( "hearth"
                , `Assoc
                    [ "type", `String "string"
                    ; "maxLength", `Int 100
                    ; ( "description"
                      , `String "Filter by hearth topic (e.g. webrtc, code-review)" )
                    ] )
              ; ( "random"
                , `Assoc
                    [ "type", `String "boolean"
                    ; "description", `String "Shuffle posts randomly (default: false)"
                    ] )
              ; ( "offset"
                , `Assoc
                    [ "type", `String "integer"
                    ; "description", `String "Skip first N posts (default: 0)"
                    ; "minimum", `Int 0
                    ; "maximum", `Int 1000
                    ] )
              ; ( "sort_by"
                , `Assoc
                    [ "type", `String "string"
                    ; (* Issue #8449 PR A: derived from Board_dispatch.sort_order Variant SSOT.
           Hand-rolled enum had 5 values that happened to be in sync; future
           constructor would silently miss this site. *)
                      ( "enum"
                      , `List
                          (List.map
                             (fun s -> `String s)
                             Board_dispatch.valid_sort_order_strings) )
                    ; "description", `String "Sort order (default: hot)"
                    ] )
              ; ( "exclude_system"
                , `Assoc
                    [ "type", `String "boolean"
                    ; ( "description"
                      , `String
                          "Exclude system posts like Activity Reports (default: false)" )
                    ] )
              ; ( "exclude_automation"
                , `Assoc
                    [ "type", `String "boolean"
                    ; ( "description"
                      , `String
                          "Exclude automation posts (heartbeat, probes, etc.) (default: \
                           false)" )
                    ] )
              ; ( "author"
                , `Assoc
                    [ "type", `String "string"
                    ; "maxLength", `Int 100
                    ; ( "description"
                      , `String
                          "Filter posts by author name (case-insensitive substring match)"
                      )
                    ] )
              ; ( "since"
                , `Assoc
                    [ "type", `String "number"
                    ; ( "description"
                      , `String
                          "Unix timestamp. Posts with activity after this time show an \
                           activity indicator" )
                    ] )
              ; ( "compact"
                , `Assoc
                    [ "type", `String "boolean"
                    ; "default", `Bool true
                    ; ( "description"
                      , `String
                          "Compact one-line per post. Set false for full \
                           body/TTL/visibility" )
                    ] )
              ] )
        ]
  }
;;

let tool_post_get : Masc_domain.tool_schema =
  { name = "masc_board_get"
  ; description =
      "Get a specific post with its full comment thread. Use when you want to read \
       discussion context before replying, or when you received a post_id from \
       board_list/search."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "post_id"
                , `Assoc [ "type", `String "string"; "description", `String "Post ID" ] )
              ] )
        ; "required", `List [ `String "post_id" ]
        ]
  }
;;

let tool_comment_add : Masc_domain.tool_schema =
  { name = "masc_board_comment"
  ; description =
      "Add a comment to an existing board post. Use after reading a post with board_get \
       to contribute your perspective, ask a question, or provide feedback."
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
                    ; "maxLength", `Int 4000
                    ; "description", `String "Comment content"
                    ] )
              ; ( "author"
                , `Assoc
                    [ "type", `String "string"; "description", `String "Author name" ] )
              ; ( "parent_id"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "Parent comment ID for replies (optional)"
                    ] )
              ; ( "ttl_hours"
                , `Assoc
                    [ "type", `String "integer"
                    ; "description", `String "Time-to-live in hours"
                    ] )
              ] )
        ; "required", `List [ `String "post_id"; `String "content"; `String "author" ]
        ]
  }
;;

let tool_vote : Masc_domain.tool_schema =
  { name = "masc_board_vote"
  ; description =
      "Vote on a board post (up or down) to signal agreement or quality. Use when you \
       find a post valuable or want to deprioritize noise."
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
              ; ( "voter"
                , `Assoc [ "type", `String "string"; "description", `String "Voter name" ]
                )
              ; ( "direction"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "up or down (default: up)"
                    ] )
              ] )
        ; "required", `List [ `String "post_id" ]
        ]
  }
;;

let tool_stats : Masc_domain.tool_schema =
  { name = "masc_board_stats"
  ; description =
      "Get board activity statistics: total posts, comments, votes, active hearths. Use \
       to understand overall board health and engagement levels."
  ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  }
;;

let tool_search : Masc_domain.tool_schema =
  { name = "masc_board_search"
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
                    ; "maxLength", `Int 200
                    ; "description", `String "Search keyword"
                    ] )
              ; ( "limit"
                , `Assoc
                    [ "type", `String "integer"
                    ; "default", `Int 20
                    ; "minimum", `Int 1
                    ; "maximum", `Int 100
                    ; "description", `String "Max results"
                    ] )
              ; ( "compact"
                , `Assoc
                    [ "type", `String "boolean"
                    ; "default", `Bool true
                    ; ( "description"
                      , `String "Compact one-line per post. Set false for full body" )
                    ] )
              ] )
        ; "required", `List [ `String "query" ]
        ]
  }
;;

let tool_comment_vote : Masc_domain.tool_schema =
  { name = "masc_board_comment_vote"
  ; description =
      "Vote on a comment (up or down) to signal agreement or quality. Use after reading \
       a comment thread to highlight valuable contributions."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "comment_id"
                , `Assoc [ "type", `String "string"; "description", `String "Comment ID" ]
                )
              ; ( "voter"
                , `Assoc [ "type", `String "string"; "description", `String "Voter name" ]
                )
              ; ( "direction"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "up or down (default: up)"
                    ] )
              ] )
        ; "required", `List [ `String "comment_id" ]
        ]
  }
;;

let tool_reaction : Masc_domain.tool_schema =
  { name = "masc_board_reaction"
  ; description = "Toggle a standard emoji reaction on a board post or comment."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "target_type"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "enum"
                      , `List
                          (List.map
                             (fun s -> `String s)
                             Board.valid_reaction_target_type_strings) )
                    ; "description", `String "Reaction target type: post or comment"
                    ] )
              ; ( "target_id"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "Post ID or comment ID"
                    ] )
              ; ( "user_id"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "Reacting user/agent name"
                    ] )
              ; ( "emoji"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "enum"
                      , `List (List.map (fun s -> `String s) Board.board_reaction_emojis)
                      )
                    ; "description", `String "Standard board reaction emoji"
                    ] )
              ] )
        ; ( "required"
          , `List
              [ `String "target_type"
              ; `String "target_id"
              ; `String "user_id"
              ; `String "emoji"
              ] )
        ]
  }
;;

let tool_profile : Masc_domain.tool_schema =
  { name = "masc_board_profile"
  ; description =
      "Get an agent's board profile: post count, comment count, vote activity, and \
       engagement stats. Use to understand an agent's contribution patterns."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "agent"
                , `Assoc [ "type", `String "string"; "description", `String "Agent name" ]
                )
              ] )
        ; "required", `List [ `String "agent" ]
        ]
  }
;;

let tool_hearth_list : Masc_domain.tool_schema =
  { name = "masc_board_hearths"
  ; description = "List active hearths (topic categories) with post counts"
  ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  }
;;

