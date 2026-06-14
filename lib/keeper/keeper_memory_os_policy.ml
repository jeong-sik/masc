(** Keeper_memory_os_policy — deterministic importance scoring for the
    Memory OS.

    The LLM librarian decides *what facts exist*; this module assigns
    each fact a deterministic composite importance score (used by recall
    ranking). *)

open Keeper_memory_os_types

let default_lambda = 1.0 /. (86400.0 *. 7.0) (* half-life ~7 days *)
let default_alpha = 0.5

(** Forgetting curve: recency decays exponentially with a half-life
    controlled by [lambda]. *)
let recency_factor ~lambda ~now last_accessed =
  let delta = now -. last_accessed in
  if delta <= 0.0 then 1.0 else exp (-.lambda *. delta)
;;

(** Access boost: each recall incrementally increases the weight of a
    fact, governed by [alpha] (sub-linear by default). *)
let access_factor ~alpha access_count =
  (1.0 +. float access_count) ** alpha
;;

(** Stale penalty: stale_factor 0.0 = no penalty, 1.0 = zero contribution. *)
let stale_penalty fact =
  1.0 -. Float.min 1.0 (Float.max 0.0 fact.stale_factor)
;;
let score_fact ?(lambda = default_lambda) ?(alpha = default_alpha) ~now fact =
  let effective_lambda =
    match fact.expected_lifetime_cycles with
    | None -> lambda
    | Some n -> lambda *. (1.0 +. 1.0 /. float (max 1 n))
  in
  fact.confidence *. recency_factor ~lambda:effective_lambda ~now fact.last_accessed *. access_factor ~alpha fact.access_count *. stale_penalty fact
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

(** Retention verdict for scored facts. *)
type retention_verdict = KeepVerbatim | Summarize | ReferenceOnly | Discard
[@@deriving yojson, show]

(** Map a composite score to a retention decision.

    Thresholds:
    - > 0.8 → KeepVerbatim (high-confidence, recently accessed)
    - > 0.5 → Summarize  (moderate importance, can be compressed)
    - > 0.3 → ReferenceOnly (low importance, keep reference only)
    - ≤ 0.3 → Discard     (negligible, safe to remove) *)
let decide_retention score =
  if score > 0.8 then KeepVerbatim
  else if score > 0.5 then Summarize
  else if score > 0.3 then ReferenceOnly
  else Discard
