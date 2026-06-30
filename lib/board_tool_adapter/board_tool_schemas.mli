(** Board_tool_schemas - Board tool schema definitions.

    Extracted from board_tool.ml to reduce godfile size.
*)

open Masc_board_handlers

val tool_post_create : Masc_domain.tool_schema
val tool_post_edit : Masc_domain.tool_schema
val tool_post_list : Masc_domain.tool_schema
val tool_post_get : Masc_domain.tool_schema
val tool_comment_add : Masc_domain.tool_schema
val tool_vote : Masc_domain.tool_schema
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
