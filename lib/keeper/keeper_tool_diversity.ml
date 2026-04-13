(** Keeper_tool_diversity — Information-theoretic tool usage analysis.

    Measures Shannon entropy of a keeper's tool usage distribution to detect
    exploitation-only behavior (low entropy = same tools repeated).
    When entropy falls below a threshold, generates a deterministic hint
    that the LLM (non-deterministic layer) can use to explore new tools.

    The boundary is strict:
    - Deterministic: entropy calculation, threshold comparison, hint text
    - Non-deterministic: LLM decides whether/how to act on the hint

    Based on:
    - Shannon (1948) entropy H = -Σ p(x) log2(p(x))
    - Pathak et al. (2017) curiosity-driven exploration via intrinsic reward
    - The max entropy for N tools is log2(N); we normalize to [0,1]

    @since 2.258.0 *)

(** A single tool's usage statistics. *)
type tool_stat = {
  name : string;
  count : int;
  successes : int;
  failures : int;
}

(** Summary of a keeper's tool diversity. *)
type diversity_summary = {
  total_calls : int;
  unique_tools : int;
  available_tools : int;
  entropy : float;
  normalized_entropy : float;  (** [0,1] where 1 = perfectly uniform *)
  underused_tools : string list;
  overused_tools : string list;
}

(** Parse keeper tool_usage JSON (the .masc/keepers/tool_usage/{name}.json
    format) into a list of tool_stat. *)
let parse_tool_usage_json (json : Yojson.Safe.t) : tool_stat list =
  let open Yojson.Safe.Util in
  match member "tools" json with
  | `List items ->
    List.filter_map (fun item ->
      match member "tool" item |> to_string_option with
      | Some name ->
        let count = member "count" item |> to_int_option |> Option.value ~default:0 in
        let successes = member "successes" item |> to_int_option |> Option.value ~default:0 in
        let failures = member "failures" item |> to_int_option |> Option.value ~default:0 in
        Some { name; count; successes; failures }
      | None -> None
    ) items
  | _ -> []

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
  let unique_tools = List.length (List.filter (fun s -> s.count > 0) stats) in
  let n_available = List.length available_tools in
  let raw_h = shannon_entropy counts in
  let norm_h = normalized_entropy ~n_categories:n_available raw_h in
  (* Overused: tools with > 2x average share *)
  let avg_share =
    if n_available = 0 then 0.0
    else Float.of_int total_calls /. Float.of_int n_available
  in
  let overused = stats
    |> List.filter (fun s -> Float.of_int s.count > avg_share *. 2.0)
    |> List.map (fun s -> s.name)
  in
  (* Underused: available tools never called or called < 1% *)
  let used_set = Hashtbl.create (List.length stats) in
  List.iter (fun s ->
    if s.count > 0 then Hashtbl.replace used_set s.name ()
  ) stats;
  let threshold = max 1 (total_calls / 100) in
  let underused = available_tools
    |> List.filter (fun tool ->
      not (Keeper_tool_registry.is_boring_tool tool)
      && (not (Hashtbl.mem used_set tool)
          || List.exists (fun s -> s.name = tool && s.count < threshold) stats))
  in
  { total_calls; unique_tools; available_tools = n_available;
    entropy = raw_h; normalized_entropy = norm_h;
    underused_tools = underused; overused_tools = overused }

(** Default normalized entropy threshold.  Below this, the keeper is
    considered to be in an exploitation-only pattern.
    Empirical: a keeper using 5 of 25 tools at roughly equal rates
    has normalized entropy ~0.43.  We set the threshold at 0.35 to
    allow some specialization while catching extreme loops. *)
let default_entropy_threshold = 0.35

(** Generate a diversity hint string from entropy analysis.
    Returns [None] when entropy is above threshold (no intervention needed).
    Returns [Some hint] with specific tool suggestions otherwise.

    NOTE: No longer injected into keeper prompt (#6814). Retained for
    test coverage and potential future use. Entropy value is recorded
    in decision_audit via [normalized_entropy] instead. *)
let diversity_hint ?(threshold = default_entropy_threshold)
    (summary : diversity_summary) : string option =
  if summary.normalized_entropy >= threshold then None
  else if summary.total_calls < 10 then None  (* too few calls to judge *)
  else
    let suggestions =
      summary.underused_tools
      |> List.filteri (fun i _ -> i < 5)
    in
    if suggestions = [] then None
    else
      let suggestion_str = String.concat ", " suggestions in
      Some (Printf.sprintf
        "[Tool Diversity: your recent tool usage is concentrated on a few tools \
         (entropy=%.2f/1.0). Consider using: %s]"
        summary.normalized_entropy suggestion_str)

(** Convert in-memory tool_call_entry list (from Keeper_registry.tool_usage_of)
    into tool_stat list. This avoids file I/O and uses the live data. *)
let stats_of_registry_entries
    (entries : (string * Keeper_types.tool_call_entry) list) : tool_stat list =
  List.map (fun (name, (e : Keeper_types.tool_call_entry)) ->
    { name; count = e.count; successes = e.successes; failures = e.failures }
  ) entries

(* Tests are in test/test_tool_diversity.ml (Alcotest + QCheck). *)
