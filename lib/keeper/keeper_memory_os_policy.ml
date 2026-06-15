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

let score_fact ?(lambda = default_lambda) ?(alpha = default_alpha) ~now fact =
  (* Confidence contributes 50-100% weight; even low-confidence facts
     retain half their score, preventing confidence-only dominance. *)
  let confidence_weight = 0.5 +. 0.5 *. fact.confidence in
  confidence_weight
  *. recency_factor ~lambda ~now fact.last_accessed
  *. (truth_recency_factor ~now fact ** 2.0)
  *. stale_penalty fact
  *. access_factor ~alpha fact.access_count
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
    List.fold_left (fun acc tok -> if string_contains tok lower then acc + 1 else acc) 0 tokens
  in
  List.map
    (fun f ->
       let match_score = score_claim f.claim in
       if match_score > 0
       then { f with access_count = f.access_count + 1; last_accessed = now }
       else f)
    facts
;;

(* RFC-0243: weight of a single re-observation when blending confidence. The
   librarian re-extracting the same claim is one new observation, so confidence
   moves a bounded fraction toward the re-observed value rather than jumping to
   it — repeated agreement at the same confidence is stable (no runaway
   inflation), while a contradiction (lower re-observed confidence) pulls it
   down. 0.3 gives meaningful movement over a handful of re-observations without
   one outlier dominating. *)
let reaffirm_weight = 0.3

(** Blend a prior confidence with a freshly re-observed confidence via a bounded
    EMA. Result is a convex combination, so it stays within [min prior observed,
    max prior observed] which is a subset of [0, 1], and is monotone in
    [observed]. *)
let blend_confidence ~prior ~observed =
  clamp01 ((prior *. (1.0 -. reaffirm_weight)) +. (observed *. reaffirm_weight))
;;

(** Fold a re-observation of an existing fact into that fact. [existing] is the
    persisted row; [incoming] is the newly extracted claim with the same
    normalized identity. The fact's identity and first-seen provenance
    ([claim]/[category]/[source]/[first_seen]) are preserved; only the
    re-observation signals move: confidence blends toward the new observation,
    [access_count] rises (feeds [access_factor]), and [last_accessed] /
    [last_verified_at] refresh (feed [recency_factor] / [truth_recency_factor]).
    This is what makes those score inputs respond to evidence instead of being
    frozen at creation. *)
let reobserve_fact ~now ~existing ~incoming =
  { existing with
    confidence = blend_confidence ~prior:existing.confidence ~observed:incoming.confidence
  ; access_count = existing.access_count + 1
  ; last_accessed = now
  ; last_verified_at = Some now
  }
;;
