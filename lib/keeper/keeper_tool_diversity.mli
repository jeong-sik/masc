(** Keeper_tool_diversity — Information-theoretic tool usage analysis.

    Measures Shannon entropy of tool usage to detect exploitation-only
    behavior.  Generates deterministic hints for the LLM to explore
    underused tools.

    @since 2.258.0 *)

type tool_stat = {
  name : string;
  count : int;
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

val shannon_entropy : int list -> float
val normalized_entropy : n_categories:int -> float -> float
val compute_diversity : available_tools:string list -> tool_stat list -> diversity_summary
val record_underused_tool_metrics :
  keeper_name:string ->
  available_tools:string list ->
  diversity_summary ->
  unit
(** Emit the aggregate underused-tool count. Per-tool heartbeat gauges are
    intentionally avoided to keep OTel series cardinality bounded by keeper. *)
val default_entropy_threshold : float
val stats_of_registry_entries : (string * Keeper_types.tool_call_entry) list -> tool_stat list
