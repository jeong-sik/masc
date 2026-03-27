(** Chain Stats - Statistics Collection and Aggregation

    체인 실행 통계를 수집하고 집계합니다.

    특징:
    - 실행 시간 통계 (평균, P95, P99)
    - 토큰 사용량 추적 (모델별)
    - 비용 추정
    - 성공/실패율 계산
    - 시간별 추이 분석
    - 통계 수집 (non-yielding ops, single-domain Eio atomic)

    @author Chain Engine
    @since 2026-01
*)

open Chain_category
open Chain_telemetry

(** {1 Statistics Types} *)

(** Execution statistics *)
type stats = {
  (* Execution stats *)
  total_chains: int;
  total_nodes: int;
  active_chains: int;  (* Currently executing chains *)
  avg_duration_ms: float;
  p50_duration_ms: float;
  p95_duration_ms: float;
  p99_duration_ms: float;

  (* Token stats *)
  total_tokens: int;
  tokens_by_model: (string * int) list;
  estimated_cost_usd: float;

  (* Success/failure *)
  success_count: int;
  failure_count: int;
  success_rate: float;
  failure_reasons: (string * int) list;

  (* Time series *)
  hourly_tokens: (int * int) list;  (* hour (0-23), tokens *)
  hourly_chains: (int * int) list;  (* hour (0-23), chain count *)
} [@@deriving yojson]

(** Per-model statistics *)
type model_stats = {
  model_name: string;
  call_count: int;
  total_tokens: int;
  avg_tokens_per_call: float;
  total_cost_usd: float;
  avg_latency_ms: float;
} [@@deriving yojson]

(** {1 Internal State} *)

(** Raw data collection *)
type raw_data = {
  mutable chain_durations: int list;
  mutable chain_timestamps: float list;  (* Timestamps for filtering by 'since' *)
  mutable node_durations: int list;
  mutable tokens_by_model: (string, int) Hashtbl.t;
  mutable call_counts_by_model: (string, int) Hashtbl.t;  (* Per-model call counts *)
  mutable latencies_by_model: (string, int list) Hashtbl.t;  (* Per-model latency lists *)
  mutable errors: (string, int) Hashtbl.t;
  mutable hourly_tokens: (int, int) Hashtbl.t;
  mutable hourly_chains: (int, int) Hashtbl.t;
  mutable success_count: int;
  mutable failure_count: int;
  mutable total_tokens: int;
  mutable total_cost: float;
  mutable active_chains: int;  (* Currently executing chains *)
}

(** Global stats collector *)
let stats_data : raw_data = {
  chain_durations = [];
  chain_timestamps = [];
  node_durations = [];
  tokens_by_model = Hashtbl.create 8;
  call_counts_by_model = Hashtbl.create 8;
  latencies_by_model = Hashtbl.create 8;
  errors = Hashtbl.create 16;
  hourly_tokens = Hashtbl.create 24;
  hourly_chains = Hashtbl.create 24;
  success_count = 0;
  failure_count = 0;
  total_tokens = 0;
  total_cost = 0.0;
  active_chains = 0;
}

(** {1 Data Collection} *)

(** Get current hour (0-23) *)
let current_hour () =
  let tm = Unix.localtime (Unix.gettimeofday ()) in
  tm.Unix.tm_hour

(** Increment hashtable counter *)
let incr_counter tbl key delta =
  let current = Hashtbl.find_opt tbl key |> Option.value ~default:0 in
  Hashtbl.replace tbl key (current + delta)

(** Event handler for statistics collection *)
let stats_handler event =
  match event with
  | ChainStart _ ->
    let hour = current_hour () in
    incr_counter stats_data.hourly_chains hour 1;
    stats_data.active_chains <- stats_data.active_chains + 1

  | NodeComplete payload ->
    stats_data.node_durations <- payload.node_duration_ms :: stats_data.node_durations;
    let tokens = payload.node_tokens in
    stats_data.total_tokens <- stats_data.total_tokens + tokens.total_tokens;
    stats_data.total_cost <- stats_data.total_cost +. tokens.estimated_cost_usd;
    let hour = current_hour () in
    incr_counter stats_data.hourly_tokens hour tokens.total_tokens

  | ChainComplete payload ->
    stats_data.chain_durations <- payload.complete_duration_ms :: stats_data.chain_durations;
    stats_data.chain_timestamps <- Unix.gettimeofday () :: stats_data.chain_timestamps;
    stats_data.success_count <- stats_data.success_count + 1;
    stats_data.active_chains <- max 0 (stats_data.active_chains - 1)

  | Error payload ->
    stats_data.failure_count <- stats_data.failure_count + 1;
    incr_counter stats_data.errors payload.error_message 1;
    stats_data.active_chains <- max 0 (stats_data.active_chains - 1)

  | NodeStart _ -> ()

(** Track model-specific token usage *)
let track_model_tokens ~model ~tokens =
  incr_counter stats_data.tokens_by_model model tokens;
  incr_counter stats_data.call_counts_by_model model 1

(** Track model-specific latency *)
let track_model_latency ~model ~latency_ms =
  let current = Hashtbl.find_opt stats_data.latencies_by_model model |> Option.value ~default:[] in
  Hashtbl.replace stats_data.latencies_by_model model (latency_ms :: current)

(** {1 Percentile Calculation} *)

(** Calculate percentile from sorted list *)
let percentile p sorted_list =
  let n = List.length sorted_list in
  if n = 0 then 0.0
  else
    let k = int_of_float (float_of_int (n - 1) *. p) in
    (* bounds-checked: k derived from (n-1)*p where 0<=p<=1 and n>0 *)
    float_of_int (List.nth_opt sorted_list k |> Option.value ~default:0)

(** Calculate multiple percentiles efficiently *)
let percentiles ps list =
  let sorted = List.sort compare list in
  List.map (fun p -> percentile p sorted) ps

(** {1 Statistics Computation} *)

(** Compute current statistics *)
let compute ?(since=0.0) () =
  let filtered_durations =
    if since <= 0.0 then stats_data.chain_durations
    else
      List.filter_map (fun (d, ts) -> if ts >= since then Some d else None)
        (List.combine stats_data.chain_durations stats_data.chain_timestamps
         |> fun pairs -> if List.length pairs = 0 then [] else pairs)
  in
  let chain_ps = percentiles [0.5; 0.95; 0.99] filtered_durations in
  let p50, p95, p99 = match chain_ps with
    | [a; b; c] -> (a, b, c)
    | _ -> (0.0, 0.0, 0.0)
  in
  let avg_duration =
    if filtered_durations = [] then 0.0
    else
      let sum = List.fold_left (+) 0 filtered_durations in
      float_of_int sum /. float_of_int (List.length filtered_durations)
  in
  let tokens_by_model =
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) stats_data.tokens_by_model []
    |> List.sort (fun (_, a) (_, b) -> compare b a)
  in
  let failure_reasons =
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) stats_data.errors []
    |> List.sort (fun (_, a) (_, b) -> compare b a)
  in
  let hourly_tokens =
    List.init 24 (fun h ->
      (h, Hashtbl.find_opt stats_data.hourly_tokens h |> Option.value ~default:0))
    |> List.filter (fun (_, v) -> v > 0)
  in
  let hourly_chains =
    List.init 24 (fun h ->
      (h, Hashtbl.find_opt stats_data.hourly_chains h |> Option.value ~default:0))
    |> List.filter (fun (_, v) -> v > 0)
  in
  let total_attempts = stats_data.success_count + stats_data.failure_count in
  let success_rate =
    if total_attempts = 0 then 1.0
    else float_of_int stats_data.success_count /. float_of_int total_attempts
  in
  {
    total_chains = List.length stats_data.chain_durations;
    total_nodes = List.length stats_data.node_durations;
    active_chains = stats_data.active_chains;
    avg_duration_ms = avg_duration;
    p50_duration_ms = p50;
    p95_duration_ms = p95;
    p99_duration_ms = p99;
    total_tokens = stats_data.total_tokens;
    tokens_by_model;
    estimated_cost_usd = stats_data.total_cost;
    success_count = stats_data.success_count;
    failure_count = stats_data.failure_count;
    success_rate;
    failure_reasons;
    hourly_tokens;
    hourly_chains;
  }

(** {1 Cascade Data (must precede reset)} *)

(** Cascade-specific statistics *)
type cascade_stats = {
  total_cascades: int;
  tier0_resolved: int;    (* Resolved at cheapest tier *)
  tier1_resolved: int;    (* Resolved at mid tier *)
  tier2_plus_resolved: int; (* Resolved at expensive tier *)
  total_escalations: int;
  total_hard_failures: int;
  avg_tier: float;
  estimated_savings_pct: float;  (* % saved vs always using top tier *)
} [@@deriving yojson]

(** Raw cascade data *)
type cascade_raw = {
  mutable cascade_count: int;
  mutable tier_resolutions: int list;  (* Which tier resolved each cascade *)
  mutable tier_resolution_count: int;  (* Track list length to avoid O(n) List.length *)
  mutable escalation_count: int;
  mutable hard_failure_count: int;
}

(** Maximum tier history to retain (prevents unbounded memory growth) *)
let max_tier_history = 10_000

(** Take first n elements from a list *)
let list_take n lst =
  let rec aux acc i = function
    | [] -> List.rev acc
    | _ when i >= n -> List.rev acc
    | x :: rest -> aux (x :: acc) (i + 1) rest
  in
  aux [] 0 lst

let cascade_data : cascade_raw = {
  cascade_count = 0;
  tier_resolutions = [];
  tier_resolution_count = 0;
  escalation_count = 0;
  hard_failure_count = 0;
}

(** {1 Reset and Management} *)

(** Reset all statistics *)
let reset () =
  stats_data.chain_durations <- [];
  stats_data.chain_timestamps <- [];
  stats_data.node_durations <- [];
  Hashtbl.clear stats_data.tokens_by_model;
  Hashtbl.clear stats_data.call_counts_by_model;
  Hashtbl.clear stats_data.latencies_by_model;
  Hashtbl.clear stats_data.errors;
  Hashtbl.clear stats_data.hourly_tokens;
  Hashtbl.clear stats_data.hourly_chains;
  stats_data.success_count <- 0;
  stats_data.failure_count <- 0;
  stats_data.total_tokens <- 0;
  stats_data.total_cost <- 0.0;
  stats_data.active_chains <- 0;
  cascade_data.cascade_count <- 0;
  cascade_data.tier_resolutions <- [];
  cascade_data.tier_resolution_count <- 0;
  cascade_data.escalation_count <- 0;
  cascade_data.hard_failure_count <- 0

(** {1 Subscription Management} *)

(** Stats collection subscription *)
let stats_subscription = ref None

(** Enable automatic stats collection *)
let enable () =
  match !stats_subscription with
  | Some _ -> ()  (* Already enabled *)
  | None ->
    stats_subscription := Some (subscribe stats_handler)

(** Disable automatic stats collection *)
let disable () =
  match !stats_subscription with
  | None -> ()
  | Some sub ->
    unsubscribe sub;
    stats_subscription := None

(** Check if stats collection is enabled *)
let is_enabled () =
  Option.is_some !stats_subscription

(** {1 Model Statistics} *)

let starts_with_prefix ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(** Cost per 1K tokens by provider prefix (approximate).
    Uses prefix matching so concrete model versions don't need updating. *)
let cost_per_1k_tokens model =
  if starts_with_prefix ~prefix:"gpt-4" model then 0.03
  else if starts_with_prefix ~prefix:"gpt-3" model then 0.002
  else if starts_with_prefix ~prefix:"gpt-5" model then 0.01
  else if starts_with_prefix ~prefix:"claude" model then (
    if starts_with_prefix ~prefix:"claude-haiku" model
       || starts_with_prefix ~prefix:"claude-3-haiku" model then 0.00025
    else if starts_with_prefix ~prefix:"claude-opus" model
       || starts_with_prefix ~prefix:"claude-3-opus" model then 0.015
    else 0.003  (* sonnet-class default *)
  )
  else if starts_with_prefix ~prefix:"gemini" model then 0.00025
  else if starts_with_prefix ~prefix:"glm" model then 0.001
  else if starts_with_prefix ~prefix:"codex" model then 0.01
  else 0.001  (* default estimate *)

(** Calculate model-specific statistics *)
let model_statistics () : model_stats list =
  Hashtbl.fold (fun model tokens (acc : model_stats list) ->
    let cost = float_of_int tokens *. cost_per_1k_tokens model /. 1000.0 in
    let call_count =
      Hashtbl.find_opt stats_data.call_counts_by_model model
      |> Option.value ~default:1
    in
    let avg_tokens = float_of_int tokens /. float_of_int (max 1 call_count) in
    let avg_latency_ms =
      match Hashtbl.find_opt stats_data.latencies_by_model model with
      | None -> 0.0
      | Some [] -> 0.0
      | Some latencies ->
          let sum = List.fold_left (+) 0 latencies in
          float_of_int sum /. float_of_int (List.length latencies)
    in
    ({
      model_name = model;
      call_count;
      total_tokens = tokens;
      avg_tokens_per_call = avg_tokens;
      total_cost_usd = cost;
      avg_latency_ms;
    } : model_stats) :: acc
  ) stats_data.tokens_by_model ([] : model_stats list)
  |> List.sort (fun (a : model_stats) (b : model_stats) -> compare b.total_tokens a.total_tokens)

(** {1 Cascade Statistics} *)

(** Track a cascade execution result *)
let track_cascade ~resolved_tier ~escalations ~hard_failures =
  cascade_data.cascade_count <- cascade_data.cascade_count + 1;
  cascade_data.tier_resolutions <- resolved_tier :: cascade_data.tier_resolutions;
  cascade_data.tier_resolution_count <- cascade_data.tier_resolution_count + 1;
  if cascade_data.tier_resolution_count > max_tier_history * 2 then begin
    cascade_data.tier_resolutions <- list_take max_tier_history cascade_data.tier_resolutions;
    cascade_data.tier_resolution_count <- max_tier_history
  end;
  cascade_data.escalation_count <- cascade_data.escalation_count + escalations;
  cascade_data.hard_failure_count <- cascade_data.hard_failure_count + hard_failures

(** Compute cascade statistics snapshot *)
let cascade_snapshot () : cascade_stats =
  let total = cascade_data.cascade_count in
  let tiers = cascade_data.tier_resolutions in
  let tier0 = List.length (List.filter (fun t -> t = 0) tiers) in
  let tier1 = List.length (List.filter (fun t -> t = 1) tiers) in
  let tier2_plus = List.length (List.filter (fun t -> t >= 2) tiers) in
  let avg = if total = 0 then 0.0
    else float_of_int (List.fold_left (+) 0 tiers) /. float_of_int total in
  let savings = if total = 0 then 0.0
    else (float_of_int tier0 *. 1.0 +. float_of_int tier1 *. 0.5) /. float_of_int total *. 100.0 in
  {
    total_cascades = total;
    tier0_resolved = tier0;
    tier1_resolved = tier1;
    tier2_plus_resolved = tier2_plus;
    total_escalations = cascade_data.escalation_count;
    total_hard_failures = cascade_data.hard_failure_count;
    avg_tier = avg;
    estimated_savings_pct = savings;
  }

(** {1 Serialization} *)

(** Convert stats to JSON *)
let to_json (stats : stats) =
  stats_to_yojson stats

(** Convert stats to compact string summary *)
let to_summary (stats : stats) =
  let base = Printf.sprintf
    "Chains: %d (%.1f%% success) | Nodes: %d | Tokens: %d ($%.2f) | Avg: %.0fms P95: %.0fms"
    stats.total_chains
    (stats.success_rate *. 100.0)
    stats.total_nodes
    stats.total_tokens
    stats.estimated_cost_usd
    stats.avg_duration_ms
    stats.p95_duration_ms
  in
  let cs = cascade_snapshot () in
  if cs.total_cascades > 0 then
    Printf.sprintf "%s | Cascades: %d (T0:%d T1:%d T2+:%d, avg_tier:%.1f, savings:%.0f%%)"
      base cs.total_cascades cs.tier0_resolved cs.tier1_resolved
      cs.tier2_plus_resolved cs.avg_tier cs.estimated_savings_pct
  else
    base

(** {1 Pretty Printing} *)

(** Format stats for human-readable output *)
let string_of_stats (stats : stats) =
  let buf = Buffer.create 512 in
  Buffer.add_string buf "═══════════════════════════════════════════════════════════════\n";
  Buffer.add_string buf "                     Chain Engine Statistics                    \n";
  Buffer.add_string buf "═══════════════════════════════════════════════════════════════\n";

  Buffer.add_string buf "\n📊 Execution Summary\n";
  Buffer.add_string buf "───────────────────────────────────────────────────────────────\n";
  Buffer.add_string buf (Printf.sprintf "  Total Chains:    %d\n" stats.total_chains);
  Buffer.add_string buf (Printf.sprintf "  Total Nodes:     %d\n" stats.total_nodes);
  Buffer.add_string buf (Printf.sprintf "  Success Rate:    %.1f%% (%d/%d)\n"
    (stats.success_rate *. 100.0)
    stats.success_count
    (stats.success_count + stats.failure_count));

  Buffer.add_string buf "\n⏱️ Latency (ms)\n";
  Buffer.add_string buf "───────────────────────────────────────────────────────────────\n";
  Buffer.add_string buf (Printf.sprintf "  Average:         %.1f\n" stats.avg_duration_ms);
  Buffer.add_string buf (Printf.sprintf "  P50 (Median):    %.1f\n" stats.p50_duration_ms);
  Buffer.add_string buf (Printf.sprintf "  P95:             %.1f\n" stats.p95_duration_ms);
  Buffer.add_string buf (Printf.sprintf "  P99:             %.1f\n" stats.p99_duration_ms);

  Buffer.add_string buf "\n🎟️ Token Usage\n";
  Buffer.add_string buf "───────────────────────────────────────────────────────────────\n";
  Buffer.add_string buf (Printf.sprintf "  Total Tokens:    %d\n" stats.total_tokens);
  Buffer.add_string buf (Printf.sprintf "  Est. Cost:       $%.4f\n" stats.estimated_cost_usd);

  if stats.tokens_by_model <> [] then begin
    Buffer.add_string buf "  By Model:\n";
    List.iter (fun (model, tokens) ->
      Buffer.add_string buf (Printf.sprintf "    %-20s %d tokens\n" model tokens)
    ) stats.tokens_by_model
  end;

  if stats.failure_reasons <> [] then begin
    Buffer.add_string buf "\n❌ Failure Reasons\n";
    Buffer.add_string buf "───────────────────────────────────────────────────────────────\n";
    List.iter (fun (reason, count) ->
      let short_reason =
        if String.length reason > 50 then String.sub reason 0 47 ^ "..."
        else reason
      in
      Buffer.add_string buf (Printf.sprintf "  [%3d] %s\n" count short_reason)
    ) stats.failure_reasons
  end;

  if stats.hourly_tokens <> [] then begin
    Buffer.add_string buf "\n📈 Hourly Token Distribution\n";
    Buffer.add_string buf "───────────────────────────────────────────────────────────────\n";
    List.iter (fun (hour, tokens) ->
      let bar_len = min 40 (tokens / 100) in
      let bar = String.make bar_len '#' in
      Buffer.add_string buf (Printf.sprintf "  %02d:00  %s %d\n" hour bar tokens)
    ) stats.hourly_tokens
  end;

  Buffer.add_string buf "═══════════════════════════════════════════════════════════════\n";
  Buffer.contents buf

(** {1 Prometheus Format} *)

(** Export stats in Prometheus format *)
let to_prometheus (stats : stats) =
  let buf = Buffer.create 1024 in

  (* Chain executions *)
  Buffer.add_string buf "# HELP chain_executions_total Total chain executions\n";
  Buffer.add_string buf "# TYPE chain_executions_total counter\n";
  Buffer.add_string buf (Printf.sprintf "chain_executions_total{status=\"success\"} %d\n" stats.success_count);
  Buffer.add_string buf (Printf.sprintf "chain_executions_total{status=\"failure\"} %d\n" stats.failure_count);

  (* Token usage *)
  Buffer.add_string buf "\n# HELP chain_tokens_total Total tokens used\n";
  Buffer.add_string buf "# TYPE chain_tokens_total counter\n";
  List.iter (fun (model, tokens) ->
    Buffer.add_string buf (Printf.sprintf "chain_tokens_total{model=\"%s\"} %d\n" model tokens)
  ) stats.tokens_by_model;

  (* Duration histogram buckets *)
  Buffer.add_string buf "\n# HELP chain_duration_seconds Chain execution duration\n";
  Buffer.add_string buf "# TYPE chain_duration_seconds histogram\n";
  Buffer.add_string buf (Printf.sprintf "chain_duration_seconds{quantile=\"0.5\"} %.3f\n" (stats.p50_duration_ms /. 1000.0));
  Buffer.add_string buf (Printf.sprintf "chain_duration_seconds{quantile=\"0.95\"} %.3f\n" (stats.p95_duration_ms /. 1000.0));
  Buffer.add_string buf (Printf.sprintf "chain_duration_seconds{quantile=\"0.99\"} %.3f\n" (stats.p99_duration_ms /. 1000.0));

  (* Cost *)
  Buffer.add_string buf "\n# HELP chain_cost_usd_total Estimated cost in USD\n";
  Buffer.add_string buf "# TYPE chain_cost_usd_total counter\n";
  Buffer.add_string buf (Printf.sprintf "chain_cost_usd_total %.4f\n" stats.estimated_cost_usd);

  Buffer.contents buf
