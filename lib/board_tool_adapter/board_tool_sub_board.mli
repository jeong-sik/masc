(** Board sub-board handlers. *)

val handle_sub_board_create :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_sub_board_list :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_sub_board_get :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_sub_board_update :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_sub_board_delete :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result
