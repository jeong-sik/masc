(** Board_tool_schemas - Board tool schema definitions.

    Extracted from board_tool.ml to reduce godfile size.
*)

open Masc_board_handlers

val schema_of_board_name : Tool_name.Board_name.t -> Masc_domain.tool_schema
(** Decode the tool [board_name] declares in its embedded
    [config/tools/masc_board_*.toml]. Raises when the file is missing or does
    not decode: a partial Board surface is worse than a refused boot.

    Exposed because {!Board_tool_registry} reads two curation schemas straight
    through it rather than through a named value here. *)

val tool_post_create : Masc_domain.tool_schema
val tool_post_edit : Masc_domain.tool_schema
val tool_post_list : Masc_domain.tool_schema
val tool_post_get : Masc_domain.tool_schema
val tool_comment_add : Masc_domain.tool_schema
val tool_vote : Masc_domain.tool_schema
val tool_cleanup : Masc_domain.tool_schema
val tool_delete : Masc_domain.tool_schema
val tool_stats : Masc_domain.tool_schema
val tool_search : Masc_domain.tool_schema
val tool_comment_vote : Masc_domain.tool_schema
val tool_reaction : Masc_domain.tool_schema
val tool_profile : Masc_domain.tool_schema
val tool_hearth_list : Masc_domain.tool_schema
val tool_sub_board_create : Masc_domain.tool_schema
val tool_sub_board_list : Masc_domain.tool_schema
val tool_sub_board_get : Masc_domain.tool_schema
val tool_sub_board_update : Masc_domain.tool_schema
val tool_sub_board_delete : Masc_domain.tool_schema
val tool_curation_read : Masc_domain.tool_schema
val tool_curation_submit : Masc_domain.tool_schema
