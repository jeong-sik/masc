(** Board tool non-post handlers and shared callbacks. *)

open Masc_board_handlers

val agent_lookup_hook : (string -> bool) option Atomic.t
val set_agent_lookup : (string -> bool) -> unit
val set_agent_lookup_none : unit -> unit
val is_agent : string -> bool

val resolve_board_post_kind :
  author:string -> string option -> (Board.post_kind, string) result

type evolution_callback =
  { get_primary_value : string -> string option
  ; record_feedback : name:string -> dimension:string -> is_positive:bool -> unit
  }

val evolution_hook : evolution_callback option Atomic.t
val register_evolution_callback : evolution_callback -> unit

val invalid_vote_direction :
  tool_name:string -> start_time:float -> string -> Tool_result.result

val legacy_vote_parameter_removed :
  tool_name:string -> start_time:float -> string -> Tool_result.result

val handle_vote :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_stats :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_search :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_comment_vote :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_reaction :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_profile :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_hearth_list :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_delete :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_board_cleanup :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result
