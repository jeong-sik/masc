(** Keeper_tool_diversity — Shannon entropy of a keeper's tool usage.

    Both outputs are telemetry: the normalized entropy reaches the keeper's
    decision audit record, and the count of barely-called allowed tools is
    published as a gauge. Nothing branches on either.

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
}

val shannon_entropy : int list -> float
val normalized_entropy : n_categories:int -> float -> float
val compute_diversity : available_tools:string list -> tool_stat list -> diversity_summary
val record_underused_tool_metrics : keeper_name:string -> diversity_summary -> unit
(** Emit the aggregate underused-tool count. Per-tool heartbeat gauges are
    intentionally avoided to keep OTel series cardinality bounded by keeper. *)
val stats_of_registry_entries : (string * Keeper_types.tool_call_entry) list -> tool_stat list
