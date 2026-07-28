open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val persona_summary_to_json : persona_summary -> Yojson.Safe.t


val render_keeper_toml_from_resolved_args :
  Yojson.Safe.t -> (string, string) result

val persist_keeper_toml_from_resolved_args :
  Yojson.Safe.t -> (Yojson.Safe.t, string) result

val resolved_keeper_args_from_persona :
  Yojson.Safe.t -> (persona_summary * Yojson.Safe.t, string) result
