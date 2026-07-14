open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val persona_summary_to_json : persona_summary -> Yojson.Safe.t
val read_jsonl_rows :
  string -> max_bytes:int -> max_lines:int -> Yojson.Safe.t list

val find_jsonl_row_by_action_id :
  Yojson.Safe.t list -> string -> Yojson.Safe.t option

val render_keeper_toml_from_resolved_args :
  Yojson.Safe.t -> (string, string) result

val persist_keeper_toml_from_resolved_args :
  Yojson.Safe.t -> (Yojson.Safe.t, string) result

val resolved_keeper_args_from_persona :
  Yojson.Safe.t -> (persona_summary * Yojson.Safe.t, string) result
