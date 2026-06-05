(** Board post, list, get, and comment handlers. *)

val handle_post_create :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_post_list_uncached :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_post_list :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_post_get :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_comment_add :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result
