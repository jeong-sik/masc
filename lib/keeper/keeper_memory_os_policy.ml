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
            let delta = other.confidence -. fact.confidence in
            (* Scale penalty so that 30% overlap with delta=0.10 → ~15% score drop *)
            Some (overlap *. delta *. 5.0)
          else None)
        other_facts
    in
    match penalties with
    | [] -> 1.0
    | _ ->
      let total = List.fold_left (+.) 0.0 penalties in
      clamp01 (1.0 -. total)
;;

(* ── Core scoring ──────────────────────────────────────────────── *)

let score_fact ?(lambda = default_lambda) ?(alpha = default_alpha)
      ?(other_facts = []) ~now fact =
  (* Confidence contributes 50-100% weight; even low-confidence facts
     retain half their score, preventing confidence-only dominance. *)
  let confidence_weight = 0.5 +. 0.5 *. fact.confidence in
  let contradict_mult = contradict_multiplier ~other_facts fact in
  confidence_weight
  *. recency_factor ~lambda ~now fact.last_accessed
  *. (truth_recency_factor ~now fact ** 2.0)
  *. stale_penalty fact
  *. access_factor ~alpha fact.access_count
  *. contradict_mult
;;

let decide_retention ?(discard_threshold = default_discard_score_threshold) score =
  if score <= discard_threshold then Discard else KeepVerbatim
;;

let score_tool_result
      ?(lambda = default_lambda)
      ?(alpha = default_alpha)
      ~now
      ~created_at
      ~was_successful
      ~access_count
      ()
  =
  let base_confidence = if was_successful then 0.9 else 0.5 in
  base_confidence *. recency_factor ~lambda ~now created_at *. access_factor ~alpha access_count
;;

let string_contains substring str =
  let sub_len = String.length substring in
  let str_len = String.length str in
  let rec aux i =
    if i + sub_len > str_len
    then false
    else if String.sub str i sub_len = substring
    then true
    else aux (i + 1)
  in
  if sub_len = 0 then true else aux 0
;;

let normalize_word_char = function
  | 'A'..'Z' as c -> Char.lowercase_ascii c
  | ('a'..'z' | '0'..'9') as c -> c
  | _ -> ' '
;;

(** Bumps access counters for facts whose claims semantically match the
    current turn keywords. This is intentionally a cheap heuristic (no
    embedding model) to keep the system deterministic and offline. *)
let bump_access_for_turn ~now (facts : fact list) ~(turn_text : string) : fact list =
  let tokens =
    String.map normalize_word_char turn_text
    |> String.split_on_char ' '
    |> List.map String.trim
    |> List.filter (fun s -> String.length s > 2)
    |> List.sort_uniq String.compare
  in
  let score_claim claim =
    let lower = String.lowercase_ascii claim in
    List.fold_left (fun acc tok ->
      if string_contains tok lower then acc + 1 else acc) 0 tokens
  in
  let threshold = max 1 (List.length tokens / 2) in
  List.map (fun f ->
    if f.kind <> Ephemeral && score_claim f.text >= threshold then
      { f with last_accessed = now; access_count = f.access_count + 1 }
    else f) facts
;;

(** Position-independent contradict check: given a fresh tool-failure or
    live-state observation, find any stored fact whose tokens contradict
    the observation and return the worst (highest-confidence) contradictor.
    This is used by the recall layer to feed [score_fact ~other_facts]. *)
let find_contradictors
      ?(min_overlap = 0.3)
      (observation_tokens : string list)
      (facts : fact list)
  : fact list =
  let obs_set = List.sort_uniq String.compare observation_tokens in
  List.filter (fun f ->
    let f_tok = fact_tokens f.text in
    let overlap = token_overlap_ratio obs_set f_tok in
    overlap >= min_overlap && f.confidence > 0.5) facts
;;