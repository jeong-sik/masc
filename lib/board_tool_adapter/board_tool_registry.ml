(** Board_tool_registry — tool schema list advertised to MCP clients.

    Re-exports the per-tool schemas from {!Board_tool_schemas} (read from
    the embedded [config/tools/masc_board_*.toml] declarations, curation
    pair included) and defines the two inline-only ones (delete, cleanup)
    for which a separate schemas module wasn't created when the original
    board_tool.ml grew. Order in {!tools} matches the original
    advertisement order from the pre-split board_tool.ml.

    Stage 10 split of lib/board_tool_adapter/board_tool.ml. *)

(** {1 Inline schemas} *)

let tool_delete : Masc_domain.tool_schema = Board_tool_schemas.tool_delete

let board_tool_cleanup : Masc_domain.tool_schema =
  Board_tool_schemas.tool_cleanup
;;

let board_tool_curation_read : Masc_domain.tool_schema =
  Board_tool_schemas.tool_curation_read
;;

let board_tool_curation_submit : Masc_domain.tool_schema =
  Board_tool_schemas.tool_curation_submit
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
  ; idempotent = false
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
