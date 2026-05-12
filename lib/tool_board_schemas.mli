(** Tool_board_schemas - Board tool schema definitions.

    Extracted from tool_board.ml to reduce godfile size.
*)

val tool_post_create : Masc_domain.tool_schema
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
