(** Byte-identity pins for the board tool TOML migration.

    The expected values below are verbatim copies of the OCaml literals the
    migration removed from [board_tool_schemas.ml], [board_tool_registry.ml]
    (the curation pair), and [tool_shard_types_board_keeper_projection.ml]
    (with that module's private enum mirrors inlined as the values they
    mirror). The tests serialize both sides with [Yojson.Safe.to_string] and
    compare strings, at the two consumer points the migration must not move:
    [Masc.Config.raw_all_tool_schemas] (MCP tools/list) and
    [Keeper_tool_descriptor.model_visible_schemas] (agent-core tools
    parameter). A drifted description, a reordered JSON key, or a lost
    required entry is a byte difference here.

    The delete/cleanup pair stayed as OCaml literals; they are pinned too so
    the aggregate's board slice is compared in full, in order. Values that
    code owns (visibility/sort enums via variant SSOTs, Board_types.Limits
    page limits, the comment id pattern, reaction vocabulary) are referenced
    from their owners exactly as the deleted literals referenced them, so
    this suite also fails when a TOML copy of such a value drifts from its
    owner. *)

open Alcotest
open Masc_board_handlers

let serialize (schema : Masc_domain.tool_schema) =
  Yojson.Safe.to_string
    (`Assoc
       [ "name", `String schema.name
       ; "description", `String schema.description
       ; "input_schema", schema.input_schema
       ])
;;

(* ── Expected canonical schemas (deleted board_tool_schemas.ml literals) ── *)

let post_id_description =
  "Required exact board post ID (format: p-xxxx). Get it from \
   masc_board_list, masc_board_search, masc_board_post_get, or visible board \
   context."
;;

let vote_direction_description = "Required vote direction: up or down"

let expected_post_create : Masc_domain.tool_schema =
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
        ]
  }
;;

let expected_post_edit : Masc_domain.tool_schema =
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

let expected_post_list : Masc_domain.tool_schema =
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
                    ; ( "enum"
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
                    ; ( "enum"
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

let expected_post_get : Masc_domain.tool_schema =
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

let expected_comment_add : Masc_domain.tool_schema =
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
                          post_id_description )
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
                    ; "pattern", `String Board.Comment_id.json_schema_pattern
                    ; ( "description"
                      , `String
                          "Parent comment ID for replies (optional; from \
                           masc_board_post_get or masc_board_comment)" )
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

let expected_vote : Masc_domain.tool_schema =
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
                          post_id_description )
                    ] )
              ; ( "voter"
                , `Assoc [ "type", `String "string"; "description", `String "Voter name" ]
                )
              ; ( "direction"
                , `Assoc
                    [ "type", `String "string"
                    ; "enum", `List [ `String "up"; `String "down" ]
                    ; "description", `String vote_direction_description
                    ] )
              ] )
        ; "required", `List [ `String "post_id"; `String "direction" ]
        ]
  }
;;

let expected_stats : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_stats)
  ; description =
      "Get board activity statistics: total posts, comments, votes, active hearths. Use \
       to understand overall board health and engagement levels."
  ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  }
;;

let expected_search : Masc_domain.tool_schema =
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

let expected_comment_vote : Masc_domain.tool_schema =
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
                , `Assoc
                    [ "type", `String "string"
                    ; "pattern", `String Board.Comment_id.json_schema_pattern
                    ; ( "description"
                      , `String
                          "Required exact comment ID from masc_board_post_get or the \
                           masc_board_comment result; invented ids are rejected." )
                    ] )
              ; ( "voter"
                , `Assoc [ "type", `String "string"; "description", `String "Voter name" ]
                )
              ; ( "direction"
                , `Assoc
                    [ "type", `String "string"
                    ; "enum", `List [ `String "up"; `String "down" ]
                    ; "description", `String vote_direction_description
                    ] )
              ] )
        ; "required", `List [ `String "comment_id"; `String "direction" ]
        ]
  }
;;

let expected_reaction : Masc_domain.tool_schema =
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

let expected_profile : Masc_domain.tool_schema =
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

let expected_hearth_list : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_hearths)
  ; description = "List active hearths (topic categories) with post counts"
  ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  }
;;

let expected_curation_read : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_curation_read)
  ; description =
      "Read the latest AI curation snapshot for the board: TL;DR summary, post ordering, \
       highlights, tag suggestions, answer matches, rationale, and operator-auditable \
       provenance. Returns null when no snapshot has been submitted \
       yet."
  ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  }
;;

let expected_curation_submit : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_curation_submit)
  ; description =
      "Submit an AI curation snapshot for the board. This records summary, recommended \
       ordering, highlights, tag suggestions, answer matches, rationale, and provenance \
       without mutating board posts/comments/votes."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "submitted_by"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String "Submitting agent identifier" )
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
              ; ( "rationale"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String "Required explanation for the curation decision" )
                    ] )
              ; ( "provenance"
                , `Assoc
                    [ "type", `String "object"
                    ; ( "description"
                      , `String
                          "Audit metadata such as source window and prompt/run id" )
                    ] )
              ] )
        ; "required", `List [ `String "submitted_by"; `String "rationale" ]
        ]
  }
;;

let expected_delete : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_delete)
  ; description =
      "Delete a board post and its associated comments and votes. Use for cleanup of \
       stale, test, or expired posts."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "post_id"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "ID of the post to delete"
                    ] )
              ; ( "author"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "Author identity. Auto-filled from the caller's agent identity \
                           when omitted by MCP runtime clients." )
                    ] )
              ] )
        ; "required", `List [ `String "post_id" ]
        ]
  }
;;

let expected_cleanup : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_cleanup)
  ; description =
      "Scan board posts matching filter criteria and delete or report them. Defaults to \
       dry_run=true (report only). Set dry_run=false to delete. Safety: never deletes \
       posts with comments or votes unless filters are overridden."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "max_age_hours"
                , `Assoc
                    [ "type", `String "integer"
                    ; ( "description"
                      , `String "Only target posts older than this (default: 24)" )
                    ] )
              ; ( "require_no_comments"
                , `Assoc
                    [ "type", `String "boolean"
                    ; ( "description"
                      , `String "Only target posts with 0 replies (default: true)" )
                    ] )
              ; ( "require_no_votes"
                , `Assoc
                    [ "type", `String "boolean"
                    ; ( "description"
                      , `String "Only target posts with 0 votes (default: true)" )
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
                      , `String
                          "If true (default), only report candidates without deleting" )
                    ] )
              ; ( "limit"
                , `Assoc
                    [ "type", `String "integer"
                    ; "description", `String "Max posts to process (default: 10, max: 50)"
                    ] )
              ] )
        ]
  }
;;

let expected_sub_board_create : Masc_domain.tool_schema =
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

let expected_sub_board_list : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_sub_board_list)
  ; description =
      "List all SubBoards with their slug, name, owner, member count, access policy, \
       and derived post count. Use to discover available board spaces before posting."
  ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  }
;;

let expected_sub_board_get : Masc_domain.tool_schema =
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

let expected_sub_board_update : Masc_domain.tool_schema =
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

let expected_sub_board_delete : Masc_domain.tool_schema =
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

(* The registry advertises List.map schema_for_board_name Board_name.all, so
   the expected canonical list is stated in that same closed order. *)
let expected_canonical : Masc_domain.tool_schema list =
  [ expected_post_create
  ; expected_post_edit
  ; expected_post_list
  ; expected_post_get
  ; expected_comment_add
  ; expected_vote
  ; expected_stats
  ; expected_search
  ; expected_comment_vote
  ; expected_reaction
  ; expected_profile
  ; expected_hearth_list
  ; expected_curation_read
  ; expected_curation_submit
  ; expected_delete
  ; expected_cleanup
  ; expected_sub_board_create
  ; expected_sub_board_list
  ; expected_sub_board_get
  ; expected_sub_board_update
  ; expected_sub_board_delete
  ]
;;

(* ── Expected keeper projections (deleted board_keeper_projection literals,
      the private enum mirrors inlined as the values they mirror) ─────────── *)

let projection_post_id_description =
  "Required exact board post ID (format: p-xxxx). Get it from \
   masc_board_list, masc_board_search, masc_board_post_get, or visible board \
   activity context."
;;

(* Mirrors Board_dispatch.valid_sort_order_strings (#8513). *)
let sort_order_enum_strings = [ "hot"; "trending"; "recent"; "updated"; "discussed" ]

(* Mirrors Board_votes.valid_vote_direction_strings (#8506). *)
let vote_direction_enum_strings = [ "up"; "down" ]

(* Mirrors Board_types.Comment_id.json_schema_pattern (#29457). *)
let comment_id_pattern = "^c-[0-9a-f]{32}$"

let expected_projections : Masc_domain.tool_schema list =
  [ { name = "masc_board_post"
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
                [ ( "title"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional post title shown in board lists. Must not be blank \
                             when present; omit for short untitled posts." )
                      ] )
                ; ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Post body text"
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
                ] )
          ; "required", `List [ `String "content" ]
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "masc_board_list"
    ; description =
        "List recent MASC Board posts and discover post_id values for follow-up \
         masc_board_post_get, masc_board_comment, or masc_board_vote calls. Use this \
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
                      [ ( "type", `String "integer" )
                      ; "default", `Int 20
                      ; "minimum", `Int 1
                      ; "maximum", `Int 50
                      ; ( "description"
                        , `String
                            "Max posts to return (default: 20, max: 50). Must \
                             be a bare integer (e.g. 20); a quoted value is \
                             rejected." )
                      ] )
                ; ( "sort_by"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List (List.map (fun s -> `String s) sort_order_enum_strings) )
                      ; "description", `String "Sort order (default: recent)"
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
                ; ( "exclude_system"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; ( "description"
                        , `String
                            "Exclude system posts such as task verdict receipts and \
                             Activity Reports (default: false)." )
                      ] )
                ; ( "exclude_automation"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; ( "description"
                        , `String
                            "Exclude automation posts such as heartbeats and probes \
                             (default: false)." )
                      ] )
                ; ( "if_revision"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional producer revision from the previous masc_board_list snapshot; matching revisions return unchanged." )
                      ] )
                ] )
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "masc_board_comment"
    ; description =
        "Add a comment to one existing board post by exact post_id. Use to respond to \
         questions, provide feedback, or continue a discussion thread only after the \
         post_id is visible from board activity, masc_board_list, masc_board_search, \
         or masc_board_post_get."
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
                            projection_post_id_description )
                      ] )
                ; ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Comment content"
                      ] )
                ; ( "parent_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; "pattern", `String comment_id_pattern
                      ; ( "description"
                        , `String
                            "Optional comment ID to reply under (from \
                             masc_board_post_get or a prior masc_board_comment), \
                             threading this comment beneath another Keeper's instead \
                             of flat on the post." )
                      ] )
                ] )
          ; "required", `List [ `String "post_id"; `String "content" ]
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "masc_board_vote"
    ; description =
        "Vote on one existing board post by exact post_id. Use to signal \
         agreement/support or disagreement with a proposal or finding only after the \
         post_id is visible from board activity, masc_board_list, masc_board_search, \
         or masc_board_post_get."
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
                            projection_post_id_description )
                      ] )
                ; ( "direction"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map (fun s -> `String s) vote_direction_enum_strings) )
                      ; "description", `String "Required vote direction: up or down"
                      ] )
                ] )
          ; "required", `List [ `String "post_id"; `String "direction" ]
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "masc_board_stats"
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
  ; { name = "masc_board_search"
    ; description =
        "Search board posts by keyword across titles and content and discover post_id \
         values for follow-up masc_board_post_get, masc_board_comment, or \
         masc_board_vote calls. Use when looking for specific topics, past \
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
                      [ ( "type", `String "integer" )
                      ; "default", `Int 20
                      ; "minimum", `Int 1
                      ; "maximum", `Int 100
                      ; ( "description"
                        , `String
                            "Max results (default: 20, max: 100). Must be a \
                             bare integer (e.g. 20); a quoted value is rejected." )
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
          ; "required", `List [ `String "query" ]
          ; "additionalProperties", `Bool false
          ]
    }
  ; { name = "masc_board_curation_read"
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
  ; { name = "masc_board_curation_submit"
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

(* ── Assertions ───────────────────────────────────────────────────────── *)

let board_prefix = "masc_board_"

let is_board_row (schema : Masc_domain.tool_schema) =
  String.starts_with ~prefix:board_prefix schema.name
;;

(* The registry aggregate: every board row of raw_all_tool_schemas, in
   order, byte-equals the deleted literals. *)
let test_registry_aggregate_is_byte_identical () =
  let actual = List.filter is_board_row Masc.Config.raw_all_tool_schemas in
  check int "board rows in raw_all_tool_schemas" (List.length expected_canonical)
    (List.length actual);
  List.iter2
    (fun (expected : Masc_domain.tool_schema) (found : Masc_domain.tool_schema) ->
      check string expected.name (serialize expected) (serialize found))
    expected_canonical
    actual
;;

(* The keeper projection surface: keyed lookups return the deleted
   projection literals, and only for the eight curated names. *)
let test_keeper_projections_are_byte_identical () =
  List.iter
    (fun (expected : Masc_domain.tool_schema) ->
      match
        Tool_name.Board_name.of_string expected.name
        |> Option.map Tool_shard_types.keeper_board_schema
      with
      | Some (Some found) ->
        check string expected.name (serialize expected) (serialize found)
      | Some None -> failf "%s lost its keeper projection" expected.name
      | None -> failf "%s is not a board tool name" expected.name)
    expected_projections;
  let projected =
    Tool_name.Board_name.all
    |> List.filter (fun name ->
      Option.is_some (Tool_shard_types.keeper_board_schema name))
    |> List.map Tool_name.Board_name.to_string
    |> List.sort String.compare
  in
  check (list string) "exactly the eight curated projections"
    (expected_projections
     |> List.map (fun (s : Masc_domain.tool_schema) -> s.name)
     |> List.sort String.compare)
    projected
;;

(* Replica of Keeper_tool_descriptor.remove_schema_fields, which the
   descriptor applies to canonical schemas on the keeper surface when no
   projection exists. Kept in step by the byte comparison below: if the
   descriptor's strip changes shape, these expectations break. *)
let strip_fields removed (schema : Yojson.Safe.t) =
  match schema with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (key, value) ->
           match key, value with
           | "properties", `Assoc properties ->
             ( "properties"
             , `Assoc
                 (List.filter
                    (fun (name, _) -> not (List.mem name removed))
                    properties) )
           | "required", `List required ->
             ( "required"
             , `List
                 (List.filter
                    (fun (entry : Yojson.Safe.t) ->
                      match entry with
                      | `String name -> not (List.mem name removed)
                      | `Int _ | `Intlit _ | `Bool _ | `Null | `Float _
                      | `Assoc _ | `List _ -> true)
                    required) )
           | _ -> key, value)
         fields)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    schema
;;

(* The model-visible surface: every board row either equals its keeper
   projection or equals the canonical schema with the identity fields
   stripped. *)
let test_model_visible_board_rows_are_byte_identical () =
  let expected_for name =
    match
      List.find_opt
        (fun (p : Masc_domain.tool_schema) -> String.equal p.name name)
        expected_projections
    with
    | Some projection -> projection
    | None ->
      let canonical =
        List.find
          (fun (c : Masc_domain.tool_schema) -> String.equal c.name name)
          expected_canonical
      in
      (match Tool_name.Board_name.of_string name with
       | None -> canonical
       | Some board_name ->
         let removed = Board_tool_registry.identity_fields_for_board_name board_name in
         { canonical with input_schema = strip_fields removed canonical.input_schema })
  in
  let rows =
    Masc.Keeper_tool_descriptor.model_visible_schemas () |> List.filter is_board_row
  in
  check bool "the eight projections reach the model surface" true
    (List.for_all
       (fun (p : Masc_domain.tool_schema) ->
         List.exists
           (fun (row : Masc_domain.tool_schema) -> String.equal row.name p.name)
           rows)
       expected_projections);
  List.iter
    (fun (row : Masc_domain.tool_schema) ->
      check string row.name (serialize (expected_for row.name)) (serialize row))
    rows
;;

let () =
  run "board_tool_toml_parity"
    [ ( "parity"
      , [ test_case "raw_all_tool_schemas board slice is byte-identical" `Quick
            test_registry_aggregate_is_byte_identical
        ; test_case "keeper projections are byte-identical" `Quick
            test_keeper_projections_are_byte_identical
        ; test_case "model-visible board rows are byte-identical" `Quick
            test_model_visible_board_rows_are_byte_identical
        ] )
    ]
;;
