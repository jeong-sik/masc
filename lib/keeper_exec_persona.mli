open Keeper_types

val persona_summary_to_json : persona_summary -> Yojson.Safe.t
val string_list_to_json : string list -> Yojson.Safe.t

val read_jsonl_rows :
  string -> max_bytes:int -> max_lines:int -> Yojson.Safe.t list

val find_jsonl_row_by_action_id :
  Yojson.Safe.t list -> string -> Yojson.Safe.t option

val validate_resolved_keeper_create_json : Yojson.Safe.t -> string list

val resolved_keeper_args_from_persona :
  Yojson.Safe.t -> (persona_summary * Yojson.Safe.t, string) result
