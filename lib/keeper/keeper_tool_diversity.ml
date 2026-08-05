(** Keeper_tool_diversity — Shannon entropy of a keeper's tool usage.

    Two values leave this module, both as telemetry: the normalized entropy,
    which the heartbeat loop writes into the keeper's decision audit record,
    and the count of allowed tools the keeper has barely called, which is
    published as a gauge. Nothing branches on either -- no turn is skipped,
    no prompt is altered, no tool is offered or withheld because of them.

    H = -Σ p(x) log2(p(x)) over the call counts; the maximum for N tools is
    log2(N), so dividing by it puts the result in [0,1] where 1 is a
    perfectly uniform spread.

    @since 2.258.0 *)

(** A single tool's usage statistics. *)
type tool_stat = {
  name : string;
  count : int;
}

(** Summary of a keeper's tool diversity. *)
type diversity_summary = {
  total_calls : int;
  unique_tools : int;
  available_tools : int;
  entropy : float;
  normalized_entropy : float;  (** [0,1] where 1 = perfectly uniform *)
  underused_tools : string list;
}

(** Shannon entropy in bits from a list of counts.
    Returns 0.0 for empty input or all-zero counts. *)
let shannon_entropy (counts : int list) : float =
  let total = List.fold_left ( + ) 0 counts in
  if total = 0 then 0.0
  else
    let total_f = Float.of_int total in
    List.fold_left (fun acc c ->
      if c = 0 then acc
      else
        let p = Float.of_int c /. total_f in
        acc -. (p *. Float.log2 p)
    ) 0.0 counts

(** Normalize entropy to [0, 1] by dividing by log2(n_categories).
    Returns 0.0 when n_categories <= 1. *)
let normalized_entropy ~n_categories (raw_entropy : float) : float =
  if n_categories <= 1 then 0.0
  else raw_entropy /. Float.log2 (Float.of_int n_categories)

(** Compute diversity summary from tool stats and the list of
    tools available to this keeper. *)
let compute_diversity ~(available_tools : string list)
    (stats : tool_stat list) : diversity_summary =
  let counts = List.map (fun s -> s.count) stats in
  let total_calls = List.fold_left ( + ) 0 counts in
  let unique_tools = List_util.count_if (fun s -> s.count > 0) stats in
  let n_available = List.length available_tools in
  let raw_h = shannon_entropy counts in
  let norm_h = normalized_entropy ~n_categories:n_available raw_h in
  (* Underused: available tools never called or called < 1% *)
  let module SS = Set_util.StringSet in
  let used_set =
    List.fold_left (fun acc s ->
      if s.count > 0 then SS.add s.name acc else acc)
      SS.empty stats
  in
  let threshold = max 1 (total_calls / 100) in
  let underused = available_tools
    |> List.filter (fun tool ->
      not (SS.mem tool used_set)
      || List.exists (fun s -> s.name = tool && s.count < threshold) stats)
  in
  { total_calls; unique_tools; available_tools = n_available;
    entropy = raw_h; normalized_entropy = norm_h;
    underused_tools = underused }

let record_underused_tool_metrics ~keeper_name summary =
  let underused_tools =
    List.sort_uniq String.compare summary.underused_tools
  in
  Otel_metric_store.set_gauge
    Keeper_metrics.(to_string ToolUnderusedAllowedCount)
    ~labels:[ ("keeper", keeper_name) ]
    (float_of_int (List.length underused_tools))

(** Convert in-memory tool_call_entry list (from Keeper_registry.tool_usage_of)
    into tool_stat list. This avoids file I/O and uses the live data. *)
let stats_of_registry_entries
    (entries : (string * Keeper_types.tool_call_entry) list) : tool_stat list =
  List.map (fun (name, (e : Keeper_types.tool_call_entry)) ->
    { name; count = e.count }
  ) entries

(* Tests are in test/test_tool_diversity.ml (Alcotest + QCheck). *)
