(** Tool_board_registry — tool schema list advertised to MCP clients.

    Re-exports the per-tool schemas from {!Tool_board_schemas} and
    defines the inline-only ones (delete, cleanup, curation_read,
    curation_submit) for which a separate schemas module wasn't created
    when the original tool_board.ml grew. Order in {!tools} matches the
    original advertisement order from the pre-split tool_board.ml.

    Stage 10 split of lib/tool_board.ml. *)

(** {1 Schemas re-exported from Tool_board_schemas} *)

let tool_post_create = Tool_board_schemas.tool_post_create
let tool_post_list = Tool_board_schemas.tool_post_list
let tool_post_get = Tool_board_schemas.tool_post_get
let tool_comment_add = Tool_board_schemas.tool_comment_add
let tool_vote = Tool_board_schemas.tool_vote
let tool_stats = Tool_board_schemas.tool_stats
let tool_search = Tool_board_schemas.tool_search
let tool_comment_vote = Tool_board_schemas.tool_comment_vote
let tool_reaction = Tool_board_schemas.tool_reaction
let tool_profile = Tool_board_schemas.tool_profile
let tool_hearth_list = Tool_board_schemas.tool_hearth_list
let tool_sub_board_create = Tool_board_schemas.tool_sub_board_create
let tool_sub_board_list = Tool_board_schemas.tool_sub_board_list
let tool_sub_board_get = Tool_board_schemas.tool_sub_board_get
let tool_sub_board_update = Tool_board_schemas.tool_sub_board_update
let tool_sub_board_delete = Tool_board_schemas.tool_sub_board_delete

(** {1 Inline schemas} *)

let tool_delete : Masc_domain.tool_schema =
  { name = "masc_board_delete"
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
              ] )
        ; "required", `List [ `String "post_id" ]
        ]
  }
;;

let tool_board_cleanup : Masc_domain.tool_schema =
  { name = "masc_board_cleanup"
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
        ; "required", `List []
        ]
  }
;;

(** All board tools. *)
let tool_board_curation_read : Masc_domain.tool_schema =
  { name = "masc_board_curation_read"
  ; description =
      "Read the latest AI curation snapshot for the board: TL;DR summary, post ordering, \
       highlights, tag suggestions, answer matches, health score, rationale, and \
       operator-auditable provenance. Returns null when no snapshot has been submitted \
       yet."
  ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  }
;;

let tool_board_curation_submit : Masc_domain.tool_schema =
  { name = "masc_board_curation_submit"
  ; description =
      "Submit an AI curation snapshot for the board. This records summary, recommended \
       ordering, highlights, tag suggestions, answer matches, health score, rationale, \
       and provenance without mutating board posts/comments/votes. Keeper wrappers \
       auto-fill submitted_by."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "submitted_by"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String "Submitting agent; keeper wrapper auto-fills this" )
                    ] )
              ; ( "model"
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
                    ; "description", `String "Objects with name, score, weight, rationale"
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
                          "Audit metadata such as source window, prompt/run id, and \
                           model params" )
                    ] )
              ] )
        ; "required", `List [ `String "submitted_by"; `String "rationale" ]
        ]
  }
;;

(** {1 Aggregate list advertised to MCP clients}

    Order preserved from pre-split tool_board.ml. *)
let tools =
  [ tool_post_create
  ; tool_post_list
  ; tool_post_get
  ; tool_comment_add
  ; tool_vote
  ; tool_stats
  ; tool_search
  ; tool_comment_vote
  ; tool_reaction
  ; tool_profile
  ; tool_hearth_list
  ; tool_board_curation_read
  ; tool_board_curation_submit
  ; tool_delete
  ; tool_sub_board_create
  ; tool_sub_board_list
  ; tool_sub_board_get
  ; tool_sub_board_update
  ; tool_sub_board_delete
  ]
;;
