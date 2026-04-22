(** Keeper_identity — Trace ID generation, git identity, and keeper-name
    normalization for keeper operations. *)

val generate_trace_id : unit -> string
val keeper_git_author : keeper_name:string -> string
val keeper_git_email : keeper_name:string -> string
val git_env_for_keeper : keeper_name:string -> string array

val keeper_name_from_agent_name : string -> string option
val canonical_keeper_name_from_agent_name : string -> string option
val canonical_keeper_name : string -> string option

type parsed_identity = {
  keeper_name : string;
  agent_name : string;
  trace_id : string option;
}

val parse_json_identity : Yojson.Safe.t -> parsed_identity
