(** Agent Permanence — Stable identity across sessions and generations.

    @since 2.90.0 *)

(** Permanent agent identity — survives session boundaries. *)
type permanent_id = {
  stable_hash : string;
  display_name : string;
  created_at : float;
  total_sessions : int;
  total_turns : int;
  total_cost_usd : float;
  current_generation : int;
  model_history : string list;
}

val compute_stable_hash : name:string -> created_at:float -> string
val create : name:string -> permanent_id
val new_session : permanent_id -> permanent_id
val record_turn : permanent_id -> cost_usd:float -> permanent_id
val advance_generation : permanent_id -> model:string -> permanent_id

val to_yojson : permanent_id -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (permanent_id, string) result

val save_to_jsonl : permanent_id -> unit
val load_from_jsonl : name:string -> permanent_id option

val build_neo4j_update_query : permanent_id -> string
val resolve_or_create : name:string -> permanent_id
