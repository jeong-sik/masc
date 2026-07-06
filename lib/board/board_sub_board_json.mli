(** Sub-board JSON serializer + member-list parser. *)

open Board_types

val sub_board_access_to_string : sub_board_access -> string
val sub_board_access_of_string_opt : string -> sub_board_access option
val sub_board_to_yojson : sub_board -> Yojson.Safe.t

type sub_board_member_parse_error =
  { member_name : string
  ; error : board_error
  }

type sub_board_members_parse_report =
  { members : Agent_id.t list
  ; errors : sub_board_member_parse_error list
  }

type sub_board_json_report =
  { sub_board : sub_board option
  ; member_errors : sub_board_member_parse_error list
  }

val sub_board_of_yojson_report : Yojson.Safe.t -> sub_board_json_report
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

(** Same compatibility behavior as [parse_sub_board_members_lenient], while
    preserving invalid member ids as typed read errors for persistence callers. *)
val parse_sub_board_members_lenient_report
  :  owner:Agent_id.t
  -> string list
  -> sub_board_members_parse_report
