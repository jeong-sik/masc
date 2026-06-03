(** Sub-board JSON serializer + member-list parser. *)

open Board_types

val sub_board_access_to_string : sub_board_access -> string
val sub_board_access_of_string_opt : string -> sub_board_access option
val sub_board_to_yojson : sub_board -> Yojson.Safe.t
val sub_board_of_yojson : Yojson.Safe.t -> sub_board option

val dedupe_agent_ids : Agent_id.t list -> Agent_id.t list

(** Parse a member-name list with owner injected, failing on the first
    invalid agent id. *)
val parse_sub_board_members
  :  owner:Agent_id.t
  -> string list
  -> (Agent_id.t list, board_error) result

(** Same as [parse_sub_board_members] but skips invalid agent ids. *)
val parse_sub_board_members_lenient
  :  owner:Agent_id.t
  -> string list
  -> Agent_id.t list
