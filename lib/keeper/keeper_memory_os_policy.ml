(** Keeper_memory_os_policy — deterministic importance scoring and
    retention decisions for the Memory OS.

    The LLM librarian decides *what facts exist*; this module decides
    *how to retain them* using a deterministic composite score and
    explicit retention verdicts. *)

open Keeper_memory_os_types

type retention_verdict =
  | KeepVerbatim
  | Summarize
  | ReferenceOnly
  | Discard

let default_lambda = 1.0 /. (86400.0 *. 7.0) (* half-life ~7 days *)
let default_alpha = 0.5
let keep_verbatim_score_threshold = 0.75
let summarize_score_threshold = 0.35

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

let score_fact ?(lambda = default_lambda) ?(alpha = default_alpha) ~now fact =
  fact.confidence *. recency_factor ~lambda ~now fact.last_accessed *. access_factor ~alpha fact.access_count
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

let decide_retention score =
  if score >= keep_verbatim_score_threshold
  then KeepVerbatim
  else if score >= summarize_score_threshold
  then Summarize
  else Discard
;;

let verdict_to_string = function
  | KeepVerbatim -> "keep_verbatim"
  | Summarize -> "summarize"
  | ReferenceOnly -> "reference_only"
  | Discard -> "discard"
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

let string_contains_any needles str =
  List.exists (fun needle -> string_contains needle str) needles
;;

let transient_admission_markers =
  [ "goal_cap"
  ; "goal cap"
  ; "goal cap clear"
  ; "goal cap clears"
  ; "goal capacity"
  ; "capacity 3/3"
  ; "capacity full"
  ; "full 3/3"
  ; "wip cap"
  ; "wip 3/3"
  ; "wip 4/3"
  ; "claim admission"
  ; "admission slot"
  ; "admission slots"
  ; "claim cooldown"
  ; "task claim cooldown"
  ; "cooldown period"
  ; "cooldown constraint"
  ; "self-imposed constraint"
  ; "self-imposed cooldown"
  ; "task claim"
  ; "task claiming"
  ; "claim new task"
  ; "claiming new task"
  ; "against claiming new task"
  ; "against claiming new tasks"
  ; "able to claim new task"
  ; "able to claim new tasks"
  ; "before being able to claim new task"
  ; "before being able to claim new tasks"
  ; "new task claim"
  ; "new task assignment"
  ; "new task assignments"
  ; "accept new task"
  ; "accept new tasks"
  ; "accepting new task"
  ; "accepting new tasks"
  ; "acceptance of new task"
  ; "acceptance of new tasks"
  ]
;;

let transient_blocker_markers =
  [ "3/3"
  ; "4/3"
  ; "at limit"
  ; "blocked"
  ; "blocking"
  ; "cannot claim"
  ; "can't claim"
  ; "unable to claim"
  ; "not able to claim"
  ; "prevents claiming"
  ; "preventing"
  ; "rejected"
  ; "constraint"
  ; "cooldown"
  ; "before being able"
  ; "against claiming"
  ; "until"
  ; "clears"
  ; "all slots occupied"
  ; "slots occupied"
  ; "slots held"
  ; "occupied by other agents"
  ; "no new tasks can be claimed"
  ; "no more goals can be claimed"
  ; "full"
  ; "stuck"
  ]
;;

let durable_meta_markers =
  [ "stale"
  ; "outdated"
  ; "obsolete"
  ; "incorrectly"
  ; "disproved"
  ; "disproving"
  ; "mismatch"
  ; "contradict"
  ; "root cause"
  ; "fix"
  ; "fixed"
  ]
;;

let is_transient_admission_memory_text text =
  let lower = String.lowercase_ascii text in
  string_contains_any transient_admission_markers lower
  && string_contains_any transient_blocker_markers lower
  && not (string_contains_any durable_meta_markers lower)
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
