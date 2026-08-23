(** Keeper-model input projections for Board capabilities.

    Public Board names and schemas are owned by [Board_tool_registry]. This
    module contains only the deliberately narrower Keeper-model input shape;
    it is not part of the public or global schema aggregate. *)

open Tool_shard_types_enum_mirrors

(* One description, two schemas. Both [masc_board_comment] and
   [masc_board_vote] name the same post id, so the text lives once; a copy
   per schema is a description slot that can drift from its twin. *)
let post_id_description =
  "Required exact board post ID (format: p-xxxx). Get it from \
   masc_board_list, masc_board_search, masc_board_post_get, or visible board \
   activity context."
;;

let schemas : Masc_domain.tool_schema list =
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
                      [ (* #18472 widening removed: a multi-type schema trips
                           agent-core boundary fail-closed and crashes the keeper cycle, so
                           [limit] stays a single scalar "integer". Tool_input_validation
                           rejects a string [limit] against this integer schema, so the
                           description must ask for a bare integer, not a numeric string
                           (codex #25274 P2). *)
                        ( "type", `String "integer" )
                      ; "default", `Int 20
                      ; "minimum", `Int 1
                      ; "maximum", `Int 50
                      ; ( "description"
                        , `String
                            "Max posts to return (default: 20, max: 50). Must \
                             be a bare integer (e.g. 20); a quoted value is \
                             rejected." )
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
                     (board_tool_post.ml handle_post_list) already
                     reads [compact] (default true), but the keeper surface
                     omitted it, so a keeper could never request full output
                     and a live Keeper's [compact] arg was rejected as an
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
                            post_id_description )
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
                            post_id_description )
                      ] )
                ; (* Issue #8506: derive from local mirror that tracks
           [Board_votes.valid_vote_direction_strings]. *)
                  ( "direction"
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
                      [ (* #18472 widening removed: a multi-type schema trips
                           agent-core boundary fail-closed and crashes the keeper cycle, so
                           [limit] stays a single scalar "integer". Tool_input_validation
                           rejects a string [limit] against this integer schema, so the
                           description must ask for a bare integer, not a numeric string
                           (codex #25274 P2). *)
                        ( "type", `String "integer" )
                      ; "default", `Int 20
                      ; "minimum", `Int 1
                      ; "maximum", `Int 100
                      ; ( "description"
                        , `String
                            "Max results (default: 20, max: 100). Must be a \
                             bare integer (e.g. 20); a quoted value is rejected." )
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

let keeper_board_schema board_name =
  let name = Tool_name.Board_name.to_string board_name in
  List.find_opt
    (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
    schemas
;;
