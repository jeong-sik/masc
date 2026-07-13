open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val persona_summary_to_json : persona_summary -> Yojson.Safe.t
val read_jsonl_rows :
  string -> max_bytes:int -> max_lines:int -> Yojson.Safe.t list

val find_jsonl_row_by_action_id :
  Yojson.Safe.t list -> string -> Yojson.Safe.t option

val validate_resolved_keeper_create_json : Yojson.Safe.t -> string list

(** D-10a transition injection: set the legacy ["goal"] string to [goal_text]
    and, when [goal_id] is given, append it to ["active_goal_ids"] (dedup).
    Pure — the Goal_store mint stays at the handler boundary so dry_run can
    preview the injection effect-free. *)
val resolved_args_with_initial_goal :
  goal_text:string -> ?goal_id:string -> Yojson.Safe.t -> Yojson.Safe.t

val render_keeper_toml_from_resolved_args :
  Yojson.Safe.t -> (string, string) result

val persist_keeper_toml_from_resolved_args :
  Yojson.Safe.t -> (Yojson.Safe.t, string) result

val resolved_keeper_args_from_persona :
  Yojson.Safe.t -> (persona_summary * Yojson.Safe.t, string) result
