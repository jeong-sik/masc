(** Memory Consolidation — Stability-based retention tiers.

    Based on Ebbinghaus forgetting curve + spaced repetition (SRS) principles.
    Memories transition through stability tiers based on access patterns
    and importance, determining their GC eligibility.

    Stability formula:
      S = alpha * ln(1 + access_count) + beta * importance/10 + gamma * (1 - e^(-t/tau))

    Tiers:
    - Volatile:   < 3 accesses, < 7 days   → aggressive GC
    - Developing: 3-10 accesses or 7-30 days → normal retention
    - Stable:     10+ accesses or high importance → preserved
    - Core:       Reflection output, high-importance decisions → permanent

    @since 2.90.0 *)

(** Stability tiers for memory retention. *)
type stability_tier =
  | Volatile     (** < 3 accesses, < 7 days: aggressive GC *)
  | Developing   (** 3-10 accesses or 7-30 days: normal retention *)
  | Stable       (** 10+ accesses or high importance: preserved *)
  | Core         (** Reflection output, high-importance: permanent *)

let string_of_tier = function
  | Volatile -> "volatile"
  | Developing -> "developing"
  | Stable -> "stable"
  | Core -> "core"

(** Stability scoring coefficients *)
type coefficients = {
  alpha : float;  (** Weight for access frequency *)
  beta : float;   (** Weight for importance *)
  gamma : float;  (** Weight for age maturation *)
  tau : float;    (** Time constant for age (days) *)
}

let default_coefficients = {
  alpha = 0.4;
  beta = 0.35;
  gamma = 0.25;
  tau = 14.0;  (* 14 days half-maturation *)
}

(** Compute stability score for a memory entry.
    S = alpha * ln(1 + access_count) + beta * importance/10 + gamma * (1 - e^(-t/tau)) *)
let stability_score ?(coeffs = default_coefficients) (entry : Memory_stream.memory_entry) =
  let age_days = (Time_compat.now () -. entry.timestamp) /. 86400.0 in
  let freq_component = coeffs.alpha *. log (1.0 +. Float.of_int entry.access_count) in
  let importance_component = coeffs.beta *. (Float.of_int entry.importance /. 10.0) in
  let age_component = coeffs.gamma *. (1.0 -. exp (-. age_days /. coeffs.tau)) in
  freq_component +. importance_component +. age_component

(** Classify a memory entry into a stability tier. *)
let classify (entry : Memory_stream.memory_entry) : stability_tier =
  let age_days = (Time_compat.now () -. entry.timestamp) /. 86400.0 in
  (* Core: reflections with importance >= 8 *)
  match entry.entry_type with
  | Memory_stream.Reflection _ when entry.importance >= 8 -> Core
  | _ ->
    if entry.access_count >= 10 || entry.importance >= 9 then Stable
    else if entry.access_count >= 3 || age_days >= 7.0 then Developing
    else Volatile

(** GC eligibility based on tier and age. *)
let should_gc (entry : Memory_stream.memory_entry) : bool =
  match classify entry with
  | Core -> false  (* never GC *)
  | Stable -> false  (* preserve *)
  | Developing ->
    let age_days = (Time_compat.now () -. entry.timestamp) /. 86400.0 in
    age_days > 60.0 && entry.importance < 5  (* GC after 60 days if low importance *)
  | Volatile ->
    let age_days = (Time_compat.now () -. entry.timestamp) /. 86400.0 in
    age_days > 7.0  (* aggressive: GC after 7 days *)

(** Run GC on agent memories. Returns (kept, removed) counts. *)
let gc_agent_memories ~agent_name : int * int =
  let entries = Memory_stream.load_all_entries ~agent_name in
  let kept, removed = List.partition (fun e -> not (should_gc e)) entries in
  let removed_count = List.length removed in
  if removed_count > 0 then begin
    Memory_stream.rewrite_entries ~agent_name kept;
    Log.Misc.info "%s: kept=%d removed=%d (volatile=%d developing=%d)"
      agent_name (List.length kept) removed_count
      (List.length (List.filter (fun e -> classify e = Volatile) removed))
      (List.length (List.filter (fun e -> classify e = Developing) removed))
  end;
  (List.length kept, removed_count)

(** Get tier distribution for an agent's memories. *)
let tier_distribution ~agent_name
  : (stability_tier * int) list =
  let entries = Memory_stream.load_all_entries ~agent_name in
  let count tier = List.length (List.filter (fun e -> classify e = tier) entries) in
  [
    (Volatile, count Volatile);
    (Developing, count Developing);
    (Stable, count Stable);
    (Core, count Core);
  ]

(** Serialize tier distribution to JSON. *)
let distribution_to_json dist =
  `Assoc (List.map (fun (tier, count) ->
    (string_of_tier tier, `Int count)
  ) dist)
