open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val persona_summary_to_json : persona_summary -> Yojson.Safe.t
val read_jsonl_rows :
  string -> max_bytes:int -> max_lines:int -> Yojson.Safe.t list

val find_jsonl_row_by_action_id :
  Yojson.Safe.t list -> string -> Yojson.Safe.t option

type create_field =
  | Keeper_name
  | Initial_goal
  | Mention_targets

type mention_target_error =
  | Expected_string
  | Empty_string

type create_validation_error =
  | Required of create_field
  | Invalid_json_type of create_field
  | Invalid_keeper_name of string
  | Invalid_mention_target of
      { index : int
      ; reason : mention_target_error
      }

type create_validation_status =
  | Ready
  | Not_ready of create_validation_error list

type create_validation_decision =
  | Preview of create_validation_status
  | Proceed
  | Reject of create_validation_error list

val validate_resolved_keeper_create_json :
  Yojson.Safe.t -> (unit, create_validation_error list) result

val decide_resolved_keeper_create :
  dry_run:bool -> Yojson.Safe.t -> create_validation_decision

val create_validation_errors_to_json :
  create_validation_error list -> Yojson.Safe.t

val render_keeper_toml_from_resolved_args :
  Yojson.Safe.t -> (string, string) result

val persist_keeper_toml_from_resolved_args :
  Yojson.Safe.t -> (Yojson.Safe.t, string) result

val resolved_keeper_args_from_persona :
  Yojson.Safe.t -> (persona_summary * Yojson.Safe.t, string) result
