(** Keeper_memory_os_policy — deterministic importance scoring for the
    Memory OS.

    The LLM librarian decides *what facts exist*; this module assigns
    each fact a deterministic composite importance score (used by recall
    ranking). *)

open Keeper_memory_os_types

let default_lambda = 1.0 /. (86400.0 *. 7.0) (* half-life ~7 days *)
let default_alpha = 0.5
let default_truth_lambda = 1.0 /. (86400.0 *. 30.0)
let default_cycle_seconds = 3600.0
let default_max_access_factor = 4.0
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

let normalize_word_char = function
  | 'A'..'Z' as c -> Char.lowercase_ascii c
  | ('a'..'z' | '0'..'9') as c -> c
  | _ -> ' '
;;

(* RFC-0244: split text into a deduped set of lowercased word tokens (length > 2).
   Shared SSOT so the turn-seeded recall factor ([lexical_relevance]) and the
   keyword access bump ([bump_access_for_turn]) tokenize identically. Deterministic
   and offline — no embedding model. *)
let tokenize text =
  String.map normalize_word_char text
  |> String.split_on_char ' '
  |> List.map String.trim
  |> List.filter (fun s -> String.length s > 2)
  |> List.sort_uniq String.compare
;;

(* RFC-0244: maximum multiplicative boost a fully turn-relevant fact receives. A
   fact whose claim covers all of the turn's distinct tokens scores [1 + gain]× its
   base; one covering none scores 1× (unchanged). *)
let default_relevance_gain = 1.5

(** Deterministic lexical relevance multiplier for turn-seeded recall.

    [seed_tokens] is the current turn's token set. [[]] (autonomous wake / no turn,
    or a turn with no usable tokens) yields [1.0] = multiplicative identity, so the
    seedless ranking is byte-identical to pre-RFC-0244. With a seed, a fact is
    boosted by the fraction of the turn's distinct tokens its claim covers
    (token-set intersection, not substring — so ["test"] does not match ["latest"]).
    The result is bounded in [[1.0, 1.0 +. gain]] and monotone in coverage.

    Trade-off vs an embedding recall: this misses synonymy and paraphrase; it gains
    determinism, reproducibility, and zero added dependency (the design tenet). *)
let lexical_relevance ?(gain = default_relevance_gain) ~seed_tokens fact =
  match seed_tokens with
  | [] -> 1.0
  | _ ->
    let claim_tokens = tokenize fact.claim in
    let matched =
      List.fold_left
        (fun acc tok -> if List.mem tok claim_tokens then acc + 1 else acc)
        0
        seed_tokens
    in
    1.0 +. (gain *. (float matched /. float (List.length seed_tokens)))
;;

let score_fact
      ?(lambda = default_lambda)
      ?(alpha = default_alpha)
      ?(seed_tokens = [])
      ~now
      fact
  =
  fact.confidence
  *. recency_factor ~lambda ~now fact.last_accessed
  *. truth_recency_factor ~now fact
  *. access_factor ~alpha fact.access_count
  *. lexical_relevance ~seed_tokens fact
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

(** Bumps access counters for facts whose claims share a turn keyword. A cheap,
    deterministic heuristic (no embedding model) kept offline. Tokenization uses the
    [tokenize] SSOT (shared with the recall relevance factor); the claim match here
    stays substring-based ([string_contains]) for its coarse access-bump purpose.

    Note: this is a write (it mutates [access_count]/[last_accessed]). It is NOT
    wired into recall, which is intentionally one-way at prompt time; the
    turn-seeded ranking boost lives in [lexical_relevance] (read-only) instead. A
    persistent variant belongs in the librarian write-path (RFC-0244 §2.1, deferred). *)
let bump_access_for_turn ~now (facts : fact list) ~(turn_text : string) : fact list =
  let tokens = tokenize turn_text in
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
