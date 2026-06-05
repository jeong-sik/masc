(** Board curation tool argument coercion and handlers. *)

open Masc_board_handlers

val curation_tag_suggestions_arg :
  Yojson.Safe.t -> Board_curation.curation_tag_suggestion list

val curation_answer_matches_arg :
  Yojson.Safe.t -> Board_curation.curation_answer_match list

val curation_health_components_arg :
  Yojson.Safe.t -> Board_curation.curation_health_component list

val handle_board_curation_read :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

val handle_board_curation_submit :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result
