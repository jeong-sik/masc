(** Board JSON wire encoders and reaction parsers. *)

open Board_types

val post_to_yojson : post -> Yojson.Safe.t

val post_origin_to_yojson : post_origin -> Yojson.Safe.t
(** RFC-0233 §7: encode the typed post origin (turn_ref / source /
    fusion_run_id) as a JSON object. Shared with the dashboard board
    serializer ({!Board_votes.post_to_yojson_with_karma}) so the wire shape
    matches {!post_to_yojson}. *)
val comment_to_yojson : comment -> Yojson.Safe.t
val reaction_to_yojson : reaction -> Yojson.Safe.t
val reaction_of_yojson : Yojson.Safe.t -> reaction option
val reaction_summary_to_yojson : reaction_summary -> Yojson.Safe.t
val reaction_toggle_result_to_yojson : reaction_toggle_result -> Yojson.Safe.t
val reaction_target_type_to_string : reaction_target_type -> string
val reaction_target_type_of_string_opt : string -> reaction_target_type option
val valid_reaction_target_type_strings : string list
val board_reaction_emojis : string list

val reaction_key :
  target_type:reaction_target_type ->
  target_id:string ->
  user_id:string ->
  emoji:string ->
  string
