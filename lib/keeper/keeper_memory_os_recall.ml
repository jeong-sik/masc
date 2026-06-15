(** Keeper_memory_os_recall — render bounded advisory context from Memory OS files. *)

open Keeper_memory_os_types

let default_max_facts = 8
let default_max_episodes = 2

(* RFC-0244 Tier 2: how many shared-semantic facts to append after the keeper's
   own (private-precedence) facts. Kept small so the communal tier informs
   without crowding out keeper-local memory. *)
let default_max_shared_facts = 4
let fact_tail_scan = 64
let max_fact_text_len = 260
let max_episode_text_len = 360
let max_atom_len = 48

let prompt_injection_prefixes =
  [ "ignore previous instructions"
  ; "ignore all previous instructions"
  ; "ignore prior instructions"
  ; "ignore all prior instructions"
  ; "disregard previous instructions"
  ; "disregard prior instructions"
  ; "forget previous instructions"
  ; "system prompt:"
  ; "system:"
  ; "developer:"
  ; "assistant:"
  ; "user:"
  ]
;;

let rec take n xs =
  if n <= 0
  then []
  else (
    match xs with
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest)
;;

let truncate ~max_len s =
  if max_len <= 0
  then ""
  else if String.length s <= max_len
  then s
  else String.sub s 0 (max 0 (max_len - 3)) ^ "..."
;;

let strip_prompt_injection_prefix line =
  let trimmed = String.trim line in
  let lower = String.lowercase_ascii trimmed in
  match
    List.find_opt
      (fun prefix -> String.starts_with ~prefix lower)
      prompt_injection_prefixes
  with
  | None -> None
  | Some prefix ->
    let prefix_len = String.length prefix in
    Some (String.sub trimmed prefix_len (String.length trimmed - prefix_len) |> String.trim)
;;

let rec strip_prompt_injection_prefixes ?(remaining = 8) line =
  if remaining <= 0
  then line
  else (
    match strip_prompt_injection_prefix line with
    | None -> line
    | Some stripped -> strip_prompt_injection_prefixes ~remaining:(remaining - 1) stripped)
;;

let sanitize_text ~max_len text =
  text
  |> Inference_utils.sanitize_text_utf8
  |> String.split_on_char '\n'
  |> List.map strip_prompt_injection_prefixes
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")
  |> String.concat " "
  |> truncate ~max_len
;;

let sanitize_atom text =
  sanitize_text ~max_len:max_atom_len text
  |> String.map (function
    | '\t' | '\r' | '\n' -> ' '
    | c -> c)
;;

let fact_is_current ~now fact =
  match fact.valid_until with
  | None -> true
  | Some ts -> ts >= now
;;

(** Merge: contradict detection (?other_facts) from PR #21243 +
    RFC-0244 lexical relevance (?seed_tokens) from origin/main. *)
let render_fact ~now ?(other_facts = []) ?(seed_tokens = []) fact =
  let score = Keeper_memory_os_policy.score_fact ~now ~other_facts ~seed_tokens fact in
  let source = fact.source in
  Printf.sprintf
    "- [category=%s confidence=%.2f stale=%.2f score=%.3f turn=%d] %s"
    (sanitize_atom fact.category)
    fact.confidence
    fact.stale_factor
    score
    source.turn
    (sanitize_text ~max_len:max_fact_text_len fact.claim)
;;

(* RFC-0244 Tier 2: a shared fact is rendered with its provenance (the distinct
   keepers that corroborated it) so it is never silently merged into the keeper's
   own knowledge — the reader can see it is cross-keeper consensus. *)
let render_shared_fact ~now ?(seed_tokens = []) fact =
  let score = Keeper_memory_os_policy.score_fact ~seed_tokens ~now fact in
  let provenance =
    match fact.observed_by with
    | [] -> "shared"
    | keepers -> "shared via " ^ String.concat "," (List.map sanitize_atom keepers)
  in
  Printf.sprintf
    "- [%s category=%s confidence=%.2f score=%.3f] %s"
    provenance
    (sanitize_atom fact.category)
    fact.confidence
    score
    (sanitize_text ~max_len:max_fact_text_len fact.claim)
;;