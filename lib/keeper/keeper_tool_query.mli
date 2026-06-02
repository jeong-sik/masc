(** Keeper_tool_query - keeper tool retrieval query projection. *)

(** Project a user-message text to the BM25 query text by keeping only the
    world-state header and a curated set of subsections. *)
val tool_query_text_of_user_message : string -> string
