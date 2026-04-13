(** Keeper_tool_diversity — Information-theoretic tool usage analysis.

    Measures Shannon entropy of tool usage to detect exploitation-only
    behavior.  Generates deterministic hints for the LLM to explore
    underused tools.

    @since 2.258.0 *)

type tool_stat = {
  name : string;
  count : int;
  successes : int;
  failures : int;
}

type diversity_summary = {
  total_calls : int;
  unique_tools : int;
  available_tools : int;
  entropy : float;
  normalized_entropy : float;
  underused_tools : string list;
  overused_tools : string list;
}

val parse_tool_usage_json : Yojson.Safe.t -> tool_stat list
val shannon_entropy : int list -> float
val normalized_entropy : n_categories:int -> float -> float
val compute_diversity : available_tools:string list -> tool_stat list -> diversity_summary
val default_entropy_threshold : float
val stats_of_registry_entries : (string * Keeper_types.tool_call_entry) list -> tool_stat list
