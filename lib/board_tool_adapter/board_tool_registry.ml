(** Board_tool_registry — tool schema list advertised to MCP clients.

    Re-exports the per-tool schemas from {!Board_tool_schemas} and
    defines the inline-only ones (delete, cleanup, curation_read,
    curation_submit) for which a separate schemas module wasn't created
    when the original board_tool.ml grew. Order in {!tools} matches the
    original advertisement order from the pre-split board_tool.ml.

    Stage 10 split of lib/board_tool.ml. *)

(** {1 Inline schemas} *)

let tool_delete : Masc_domain.tool_schema =
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

let board_tool_cleanup : Masc_domain.tool_schema =
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
        ; "required", `List []
        ]
  }
;;

(** All board tools. *)
let board_tool_curation_read : Masc_domain.tool_schema =
  { name = Tool_name.Board_name.(to_string Board_curation_read)
  ; description =
      "Read the latest AI curation snapshot for the board: TL;DR summary, post ordering, \
       highlights, tag suggestions, answer matches, rationale, and operator-auditable \
       provenance. Returns null when no snapshot has been submitted \
       yet."
  ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  }
;;

let board_tool_curation_submit : Masc_domain.tool_schema =
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

(** {1 Typed operation projection} *)
type operation_policy =
  { visibility : Tool_catalog.visibility
  ; readonly : bool
  ; idempotent : bool
  }

let operation_policy board_name =
  let readonly = not (Tool_name.Board_name.is_resource_write board_name) in
  { visibility = Tool_catalog.Default
  ; readonly
  ; idempotent = readonly
  }
;;

(** {1 Typed schema projection} *)
let schema_for_board_name = function
  | Tool_name.Board_name.Board_post -> Board_tool_schemas.tool_post_create
  | Tool_name.Board_name.Board_post_update -> Board_tool_schemas.tool_post_edit
  | Tool_name.Board_name.Board_list -> Board_tool_schemas.tool_post_list
  | Tool_name.Board_name.Board_post_get -> Board_tool_schemas.tool_post_get
  | Tool_name.Board_name.Board_comment -> Board_tool_schemas.tool_comment_add
  | Tool_name.Board_name.Board_vote -> Board_tool_schemas.tool_vote
  | Tool_name.Board_name.Board_stats -> Board_tool_schemas.tool_stats
  | Tool_name.Board_name.Board_search -> Board_tool_schemas.tool_search
  | Tool_name.Board_name.Board_comment_vote -> Board_tool_schemas.tool_comment_vote
  | Tool_name.Board_name.Board_reaction -> Board_tool_schemas.tool_reaction
  | Tool_name.Board_name.Board_profile -> Board_tool_schemas.tool_profile
  | Tool_name.Board_name.Board_hearths -> Board_tool_schemas.tool_hearth_list
  | Tool_name.Board_name.Board_curation_read -> board_tool_curation_read
  | Tool_name.Board_name.Board_curation_submit -> board_tool_curation_submit
  | Tool_name.Board_name.Board_delete -> tool_delete
  | Tool_name.Board_name.Board_cleanup -> board_tool_cleanup
  | Tool_name.Board_name.Board_sub_board_create ->
    Board_tool_schemas.tool_sub_board_create
  | Tool_name.Board_name.Board_sub_board_list ->
    Board_tool_schemas.tool_sub_board_list
  | Tool_name.Board_name.Board_sub_board_get -> Board_tool_schemas.tool_sub_board_get
  | Tool_name.Board_name.Board_sub_board_update ->
    Board_tool_schemas.tool_sub_board_update
  | Tool_name.Board_name.Board_sub_board_delete ->
    Board_tool_schemas.tool_sub_board_delete
;;

(** Aggregate list advertised to MCP clients, derived from the closed Board
    operation vocabulary in its stable advertised order. *)
let tools = List.map schema_for_board_name Tool_name.Board_name.all

let identity_fields_for_board_name = function
  | Tool_name.Board_name.Board_post
  | Tool_name.Board_name.Board_post_update
  | Tool_name.Board_name.Board_comment -> [ "author" ]
  | Tool_name.Board_name.Board_vote
  | Tool_name.Board_name.Board_comment_vote -> [ "voter" ]
  | Tool_name.Board_name.Board_reaction -> [ "user_id" ]
  | Tool_name.Board_name.Board_sub_board_create -> [ "owner" ]
  | Tool_name.Board_name.Board_sub_board_delete
  | Tool_name.Board_name.Board_sub_board_update -> [ "owner" ]
  | Tool_name.Board_name.Board_curation_submit -> [ "submitted_by" ]
  | Tool_name.Board_name.Board_delete -> [ "author" ]
  | Tool_name.Board_name.Board_cleanup
  | Tool_name.Board_name.Board_curation_read
  | Tool_name.Board_name.Board_post_get
  | Tool_name.Board_name.Board_hearths
  | Tool_name.Board_name.Board_list
  | Tool_name.Board_name.Board_profile
  | Tool_name.Board_name.Board_search
  | Tool_name.Board_name.Board_stats
  | Tool_name.Board_name.Board_sub_board_get
  | Tool_name.Board_name.Board_sub_board_list
  -> []
;;

let identity_input_fields =
  Tool_name.Board_name.all
  |> List.concat_map identity_fields_for_board_name
  |> List.sort_uniq String.compare
;;
