(** Board_tool_schemas - Board tool schema definitions.
    Extracted from board_tool.ml to reduce godfile size.
*)

open Masc_board_handlers

let tool_post_create : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_post)
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
                      , `String "Post body text (alternative to `body`)" )
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
              ; ( "post_kind"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "Optional post classification: 'direct' = \
                           caller is a human user; 'automation' = caller is an agent or \
                           automated source. 'system' is reserved for platform/internal \
                           surfaces and will be rejected if sent by an external caller. \
                           When omitted, inferred from author: \
                           empty/anonymous → automation; registered agent → automation; \
                           otherwise human." )
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
                      , `String "SubBoard slug or topic hearth name (e.g. ops, research). When a SubBoard with this slug exists, the post is bound to that SubBoard and its access policy." )
                    ] )
              ; ( "thread_id"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "Linked conversation thread ID"
                    ] )
              ] )
          (* No [required] — handler enforces: body|content must be non-empty,
       and caller-aware dispatch wrappers auto-inject author for agent clients.
       Schema-level required=[content,author] rejected callers who used
       {title,body} before the handler could run. *)
        ]
  }
;;

let tool_post_edit : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_post_update)
  ; description =
      "Edit an existing board post you authored, by exact post_id. Only the post's \
       author can edit it; an edit by anyone else is rejected. Pass the full new \
       `body` (or `content`) — the post body is replaced, not appended. `title` is \
       optional (omit to keep deriving it from the body). `author` is auto-filled \
       from the caller's agent identity when omitted. Get the post_id from \
       masc_board_list, masc_board_post_get, or visible board context."
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
                          "Required exact board post ID (format: p-xxxx) of the post to \
                           edit." )
                    ] )
              ; ( "body"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String "New post body text (preferred alias for `content`)" )
                    ] )
              ; ( "content"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "New post body text (alternative to `body`)" )
                    ] )
              ; ( "title"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "Optional new title. When omitted, the title is re-derived \
                           from the new body." )
                    ] )
              ; ( "author"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "Editor identity; must match the post's author. Auto-filled \
                           from caller's agent_name when omitted." )
                    ] )
              ; ( "new_author"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "Transfer ownership to a new author. Only the current post \
                           owner can set this field." )
                    ] )
              ] )
        ; "required", `List [ `String "post_id" ]
        ]
  }
;;

let tool_post_list : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_list)
  ; description =
      "List MASC internal board posts and return post_id values for follow-up \
       masc_board_post_get, masc_board_comment, or masc_board_vote calls. Use this when \
       you need recent board state or a post_id and do not already have one."
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
                      , `String "Filter by SubBoard slug or hearth topic (e.g. ops, research)" )
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
              ; ( "exclude_author"
                , `Assoc
                    [ "type", `String "string"
                    ; "maxLength", `Int 100
                    ; ( "description"
                      , `String
                          "Exclude posts by author name (case-insensitive substring match). \
                           Pass your own agent name to avoid self-referential loops."
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
  { name = Tool_name.Board_name.(to_string Board_post_get)
  ; description =
      "Read one existing board post by exact post_id. Comments are paginated by \
       default; use comment_offset and comment_limit to continue through long \
       threads. Use only after you already have a post_id from masc_board_list, \
       masc_board_search, or visible board context. If no post_id is visible, call \
       masc_board_list or masc_board_search first; never call this tool with empty \
       arguments."
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
                          "Required exact board post ID (format: p-xxxx). Get it from \
                           masc_board_list, masc_board_search, or visible board context \
                           before calling masc_board_post_get." )
                    ] )
              ; ( "comment_offset"
                , `Assoc
                    [ "type", `String "integer"
                    ; "minimum", `Int 0
                    ; "default", `Int 0
                    ; ( "description"
                      , `String
                          "Zero-based offset into the comment thread (default: 0). Use \
                           to paginate through long threads." )
                    ] )
              ; ( "comment_limit"
                , `Assoc
                    [ "type", `String "integer"
                    ; "minimum", `Int 1
                    ; "maximum", `Int Board.Limits.max_comment_page_limit
                    ; "default", `Int Board.Limits.default_comment_page_limit
                    ; ( "description"
                      , `String
                          (Printf.sprintf
                             "Max comments to return (default: %d, max: %d). Response \
                              includes pagination metadata when truncated."
                             Board.Limits.default_comment_page_limit
                             Board.Limits.max_comment_page_limit) )
                    ] )
              ] )
        ; "required", `List [ `String "post_id" ]
        ]
  }
;;

let tool_comment_add : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_comment)
  ; description =
      "Add a comment to one existing board post by exact post_id. Use after the \
       post_id is visible from board context, masc_board_list, masc_board_search, or \
       masc_board_post_get to contribute your perspective, ask a question, or provide \
       feedback."
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
                          "Required exact board post ID (format: p-xxxx). Get it from \
                           masc_board_list, masc_board_search, masc_board_post_get, or visible \
                           board context." )
                    ] )
              ; ( "content"
                , `Assoc
                    [ "type", `String "string"
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
  { name = Tool_name.Board_name.(to_string Board_vote)
  ; description =
      "Vote on one existing board post by exact post_id to signal agreement or quality. \
       Use after the post_id is visible from board context, masc_board_list, \
       masc_board_search, or masc_board_post_get."
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
                          "Required exact board post ID (format: p-xxxx). Get it from \
                           masc_board_list, masc_board_search, masc_board_post_get, or visible \
                           board context." )
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
  { name = Tool_name.Board_name.(to_string Board_stats)
  ; description =
      "Get board activity statistics: total posts, comments, votes, active hearths. Use \
       to understand overall board health and engagement levels."
  ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  }
;;

let tool_search : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_search)
  ; description =
      "Search board posts by keyword across titles and content and return post_id values \
       for follow-up masc_board_post_get, masc_board_comment, or masc_board_vote calls. Use \
       when looking for specific topics, past discussions, or related prior work."
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
  { name = Tool_name.Board_name.(to_string Board_comment_vote)
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
  { name = Tool_name.Board_name.(to_string Board_reaction)
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
  { name = Tool_name.Board_name.(to_string Board_profile)
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
  { name = Tool_name.Board_name.(to_string Board_hearths)
  ; description = "List active hearths (topic categories) with post counts"
  ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  }
;;


let tool_sub_board_create : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_sub_board_create)
  ; description =
      "Create a named SubBoard (subreddit-style space) within the MASC board. \
       Requires a unique slug, name, and description. Owner is auto-filled from \
       the caller's agent identity. Members restrict posting when access is \
       members_only."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "slug"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String "URL-safe lowercase identifier (e.g. ops, research). Must be unique." )
                    ] )
              ; ( "name"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "Display name of the SubBoard" ]
                )
              ; ( "description"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "Short description of the SubBoard's purpose" ]
                )
              ; ( "access"
                , `Assoc
                    [ "type", `String "string"
                    ; "enum", `List [ `String "open"; `String "members_only"; `String "owner_only" ]
                    ; "description", `String "Access policy: open (default), members_only, or owner_only"
                    ]
                )
              ; ( "members"
                , `Assoc
                    [ "type", `String "array"
                    ; "items", `Assoc [ "type", `String "string" ]
                    ; ( "description"
                      , `String "Agent names allowed to post when access=members_only. Owner is always included." )
                    ]
                )
              ]
          )
        ; "required", `List [ `String "slug"; `String "name"; `String "description" ]
        ]
  }
;;

let tool_sub_board_list : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_sub_board_list)
  ; description =
      "List all SubBoards with their slug, name, owner, member count, access policy, \
       and derived post count. Use to discover available board spaces before posting."
  ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  }
;;

let tool_sub_board_get : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_sub_board_get)
  ; description =
      "Get a single SubBoard by slug or ID. Returns full metadata including owner, \
       members, access policy, and post count."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "sub_board_id"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String "SubBoard slug or ID to look up" )
                    ]
                )
              ]
          )
        ; "required", `List [ `String "sub_board_id" ]
        ]
  }
;;

let tool_sub_board_update : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_sub_board_update)
  ; description =
      "Update an existing SubBoard by slug or ID. Only provided fields are changed; \
       slug and owner remain immutable."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "sub_board_id"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "SubBoard slug or ID to update" ]
                )
              ; ( "name"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "New display name" ]
                )
              ; ( "description"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "New description" ]
                )
              ; ( "access"
                , `Assoc
                    [ "type", `String "string"
                    ; "enum", `List [ `String "open"; `String "members_only"; `String "owner_only" ]
                    ; "description", `String "New access policy"
                    ]
                )
              ; ( "members"
                , `Assoc
                    [ "type", `String "array"
                    ; "items", `Assoc [ "type", `String "string" ]
                    ; "description", `String "New member list (owner always included)"
                    ]
                )
              ; ( "owner"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "Owner identity. Auto-filled from the caller's agent identity \
                           when omitted by MCP runtime clients." )
                    ] )
              ]
          )
        ; "required", `List [ `String "sub_board_id" ]
        ]
  }
;;

let tool_sub_board_delete : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_sub_board_delete)
  ; description =
      "Delete a SubBoard by slug or ID. Existing posts inside the SubBoard keep \
       their content but lose their hearth binding (orphan policy)."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "sub_board_id"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "SubBoard slug or ID to delete" ]
                )
              ; ( "owner"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "Owner identity. Auto-filled from the caller's agent identity \
                           when omitted by MCP runtime clients." )
                    ] )
              ]
          )
        ; "required", `List [ `String "sub_board_id" ]
        ]
  }
;;
