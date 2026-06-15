(** Keeper_memory_os_policy — deterministic importance scoring for the
    Memory OS.

    The LLM librarian decides *what facts exist*; this module assigns
    each fact a deterministic composite importance score (used by recall
    ranking). *)

open Keeper_memory_os_types

let default_lambda = 1.0 /. (86400.0 *. 7.0) (* half-life ~7 days *)
let default_alpha = 0.5
let default_truth_lambda = 1.0 /. (86400.0 *. 7.0)
let default_cycle_seconds = 3600.0
let default_max_access_factor = 2.0
let default_discard_score_threshold = 0.02

type retention_verdict =
  | KeepVerbatim
  | Discard

(** Forgetting curve: recency decays exponentially with a half-life
    controlled by [lambda]. *)
let recency_factor ~lambda ~now last_accessed =
  let delta = now -. last_accessed in
  if delta <= 0.0 then 1.0 else exp (-.lambda *. delta)
;;

(** Access boost: each recall incrementally increases the weight of a
    fact, governed by [alpha] (sub-linear by default). *)
let access_factor ~alpha access_count =
  Float.min default_max_access_factor ((1.0 +. float access_count) ** alpha)
;;

let clamp01 value =
  Float.max 0.0 (Float.min 1.0 value)
;;

let stale_penalty fact =
  1.0 -. clamp01 fact.stale_factor
;;

let truth_anchor fact =
  match fact.last_verified_at with
  | Some ts -> ts
  | None -> fact.first_seen
;;

let truth_lambda_for_fact ~lambda fact =
  match fact.expected_lifetime_cycles with
  | Some cycles when cycles > 0 ->
    1.0 /. (default_cycle_seconds *. float cycles)
  | Some _ | None -> lambda
;;

let truth_recency_factor ?(lambda = default_truth_lambda) ~now fact =
  let lambda = truth_lambda_for_fact ~lambda fact in
  recency_factor ~lambda ~now (truth_anchor fact)
;;

(* ── Contradict detection helpers ────────────────────────────────── *)

(** Tokenise fact content into lowercase alphanumeric words >= 3 chars. *)
let fact_tokens text =
  let buf = Buffer.create (String.length text) in
  String.iter (function
    | 'A'..'Z' as c -> Buffer.add_char buf (Char.lowercase_ascii c)
    | 'a'..'z' | '0'..'9' as c -> Buffer.add_char buf c
    | _ -> Buffer.add_char buf ' ') text;
  Buffer.contents buf
  |> String.split_on_char ' '
  |> List.map String.trim
  |> List.filter (fun s -> String.length s >= 3)
  |> List.sort_uniq String.compare
;;

(** Jaccard-like overlap ratio between two token sets. *)
let token_overlap_ratio a_tokens b_tokens =
  let set_a = List.sort_uniq String.compare a_tokens in
  let set_b = List.sort_uniq String.compare b_tokens in
  let intersection_size =
    List.fold_left (fun acc t ->
      if List.mem t set_b then acc + 1 else acc) 0 set_a
  in
  let union_size = List.length set_a + List.length set_b - intersection_size in
  if union_size = 0 then 0.0
  else float intersection_size /. float union_size
;;

(** Compute contradict multiplier for [fact] given [other_facts]:
    - For each other fact with >= 30% token overlap and higher confidence,
      apply a penalty proportional to overlap * confidence_delta.
    - The multiplier is clamped to [min_contradict_mult, 1.0].
    - Returns 1.0 when no contradict evidence is found. *)
let min_contradict_mult = 0.3

let contradict_multiplier ?(other_facts = []) fact =
  let fact_tok = fact_tokens (fact.claim ^ " " ^ fact.category) in
  if List.length fact_tok < 2 then 1.0
  else
    let penalties =
      List.filter_map (fun other ->
        let other_tok = fact_tokens (other.claim ^ " " ^ other.category) in
        if List.length other_tok < 2 then None
        else
          let overlap = token_overlap_ratio fact_tok other_tok in
          if overlap >= 0.15 && other.confidence > fact.confidence then
            let confidence_delta = other.confidence -. fact.confidence in
            Some (overlap *. confidence_delta *. 5.0)
          else None)
        other_facts
    in
    if penalties = [] then 1.0
    else
      let total = List.fold_left (+.) 0.0 penalties in
      Float.max min_contradict_mult (1.0 -. total)
;;

(* ── RFC-0244: Turn-seeded lexical relevance ─────────────────── *)

(** RFC-0244: deduped set of lowercased word tokens (length > 2). *)
let tokenize text =
  let buf = Buffer.create (String.length text) in
  String.iter (function
    | 'A'..'Z' as c -> Buffer.add_char buf (Char.lowercase_ascii c)
    | 'a'..'z' | '0'..'9' as c -> Buffer.add_char buf c
    | _ -> Buffer.add_char buf ' ') text;
  Buffer.contents buf
  |> String.split_on_char ' '
  |> List.map String.trim
  |> List.filter (fun s -> String.length s >= 3)
  |> List.sort_uniq String.compare
;;

(** RFC-0244: deterministic lexical relevance multiplier in [1.0, 1.0 +. gain]. *)
let lexical_relevance ?(gain = 1.0) ~seed_tokens fact =
  if seed_tokens = [] then 1.0
  else
    let fact_toks = tokenize fact.claim in
    let intersection_count =
      List.fold_left (fun acc t ->
        if List.mem t fact_toks then acc + 1 else acc) 0 seed_tokens
    in
    let ratio = float intersection_count /. float (List.length seed_tokens) in
    1.0 +. (gain *. ratio)
;;

(* ── Core scoring ─────────────────────────────────────────────── *)

(** RFC-0244: backwards‑compatible composite score.

    score = confidence × access_recency × truth_recency ×
            stale_penalty × access_boost × lexical_relevance ×
            contradict_mult

    [other_facts] enables contradict‑detection; [seed_tokens] enables
    turn‑seeded lexical relevance (RFC‑0244).  Either or both can be
    omitted — when absent the corresponding multiplier defaults to 1.0
    and the score is byte‑identical to the pre‑feature formula. *)
let score_fact
    ?(lambda = default_lambda)
    ?(alpha = default_alpha)
    ?(other_facts = [])
    ?(seed_tokens = [])
    ~now
    fact =
  let access_recency = recency_factor ~lambda ~now fact.last_accessed in
  let truth_recency = truth_recency_factor ~now fact in
  let access_boost = access_factor ~alpha fact.access_count in
  (* Penalty for stale facts *)
  let stale_penalty = 1.0 -. clamp01 fact.stale_factor in
  (* Contradict penalty (task-1252) *)
  let contradict_mult = contradict_multiplier ~other_facts fact in
  (* Lexical relevance boost (RFC-0244) *)
  let lex_rel = lexical_relevance ~seed_tokens fact in
  let score =
    fact.confidence
    *. access_recency
    *. truth_recency
    *. stale_penalty
    *. access_boost
    *. lex_rel
    *. contradict_mult
  in
  if Float.is_nan score || Float.is_infinite score then 0.0
  else score
;;

let decide_retention ?(discard_threshold = default_discard_score_threshold) score =
  if score < discard_threshold then Discard
  else KeepVerbatim
;;

(** Score an archived tool result (sub‑second granularity). *)
let score_tool_result
    ?(lambda = default_lambda)
    ?(alpha = default_alpha)
    ~now
    ~created_at
    ~was_successful
    ~access_count
    () =
  let recency = recency_factor ~lambda ~now created_at in
  let access_boost = access_factor ~alpha access_count in
  let success_factor = if was_successful then 1.0 else 0.3 in
  let score = recency *. access_boost *. success_factor in
  if Float.is_nan score || Float.is_infinite score then 0.0
  else score
;;

(** RFC-0244: lightweight keyword access bump applied to ALL facts
    whose claim overlaps with the current turn text. *)
let bump_access_for_turn ~now facts ~turn_text =
  let seed_tokens = tokenize turn_text in
  if seed_tokens = [] then facts
  else
    List.map (fun fact ->
      let fact_toks = tokenize fact.claim in
      let has_overlap =
        List.exists (fun t -> List.mem t fact_toks) seed_tokens
      in
      if has_overlap then { fact with last_accessed = now }
      else fact)
    facts
;;

(** Find facts that contradict a given observation token set. *)
let find_contradictors ?(min_overlap = 0.3) observation_tokens facts =
  List.filter (fun fact ->
    let fact_toks = tokenize fact.claim in
    let overlap = token_overlap_ratio observation_tokens fact_toks in
    overlap >= min_overlap && fact.confidence > 0.5)
    facts
;;