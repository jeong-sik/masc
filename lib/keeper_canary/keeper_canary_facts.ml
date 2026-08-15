(* Nonce fact injection + recall scoring for the keeper canary harness.

   Values are deterministic given [seed] (the caller's run id), not
   process-global randomness: a run id chosen by the caller (a timestamp, a
   ladder-tier label, whatever an orchestration script wants) is the sole
   source of variation, so (a) the same run id always reproduces the exact
   same facts — required for the fact-generation-determinism test below and
   for replaying a run's evidence by hand — and (b) evidence never carries
   a wall-clock-derived value that would make two runs of the same run id
   diverge. Cross-run collision protection then falls on the caller picking
   a fresh run id per invocation, the same way a nonce would, rather than on
   this module reaching for its own entropy source.

   Nine categories mirror PR #28743's manually-established set exactly, so
   this harness automates that protocol rather than inventing a new one. *)

type fact = {
  category : string;
  statement : string; (* what turn i says to the keeper *)
  value : string; (* the nonce string the keeper must recall verbatim *)
}

let category_names =
  [ "project_codename"
  ; "lead_reviewer"
  ; "deadline"
  ; "blocked_dependency"
  ; "fallback_runtime"
  ; "incident_number"
  ; "reviewer_timezone"
  ; "artifact_name"
  ; "rollback_switch"
  ]

let reviewer_timezones =
  [| "Asia/Seoul"; "America/New_York"; "Europe/London"; "Asia/Tokyo"
   ; "Australia/Sydney"; "America/Los_Angeles"
  |]

(* [seed] is hashed through SHA-256 rather than fed to [Random.State.make]
   as raw bytes of the string: a short or low-entropy run id (e.g. "10T")
   would otherwise seed the generator with very few effective bits. Folding
   32 digest bytes into 8 int32-sized words gives Random.State a full-width
   seed regardless of how the caller spells the run id. *)
let state_of_seed seed =
  let digest = Digestif.SHA256.(to_raw_string (digest_string seed)) in
  let word i =
    let byte j = Char.code digest.[(i * 4) + j] in
    (byte 0 lsl 24) lor (byte 1 lsl 16) lor (byte 2 lsl 8) lor byte 3
  in
  Random.State.make (Array.init 8 word)

let hex_digits = "0123456789abcdef"

(* 6 bytes (12 hex chars) of seeded pseudo-randomness — same length as the
   Crypto_rng-backed nonce this replaces, but reproducible from [state]. *)
let nonce_suffix state =
  String.init 12 (fun _ -> hex_digits.[Random.State.int state 16])

let value_of_category state = function
  | "project_codename" -> "Codename-" ^ nonce_suffix state
  | "lead_reviewer" -> "Reviewer-" ^ nonce_suffix state
  | "deadline" ->
    (* A seeded near-future date, not tied to wall-clock "today" so the
       same run id reproduces the same date regardless of when it runs. *)
    Printf.sprintf
      "2026-%02d-%02d"
      (1 + Random.State.int state 12)
      (1 + Random.State.int state 28)
  | "blocked_dependency" -> "dep-" ^ nonce_suffix state
  | "fallback_runtime" -> "runtime-" ^ nonce_suffix state
  | "incident_number" -> string_of_int (1000 + Random.State.int state 9000)
  | "reviewer_timezone" ->
    reviewer_timezones.(Random.State.int state (Array.length reviewer_timezones))
  | "artifact_name" -> "artifact-" ^ nonce_suffix state ^ ".json"
  | "rollback_switch" -> "rollback-" ^ nonce_suffix state
  | other ->
    invalid_arg ("Keeper_canary_facts: unknown fact category " ^ other)

let statement_of ~category ~value =
  match category with
  | "project_codename" -> Printf.sprintf "The project codename is %s." value
  | "lead_reviewer" -> Printf.sprintf "The lead reviewer is %s." value
  | "deadline" -> Printf.sprintf "The deadline is %s." value
  | "blocked_dependency" ->
    Printf.sprintf "The blocked dependency is %s." value
  | "fallback_runtime" -> Printf.sprintf "The fallback runtime is %s." value
  | "incident_number" -> Printf.sprintf "The incident number is %s." value
  | "reviewer_timezone" ->
    Printf.sprintf "The reviewer timezone is %s." value
  | "artifact_name" -> Printf.sprintf "The artifact name is %s." value
  | "rollback_switch" ->
    Printf.sprintf "The rollback switch is called %s." value
  | other ->
    invalid_arg ("Keeper_canary_facts: unknown fact category " ^ other)

(* [count] facts, drawn from [category_names] in order and capped at it — a
   canary with more than nine pre-recall turns pads with filler turns at
   the call site, not synthetic categories, so every fact this function
   returns is one of the nine named kinds. Values are seeded from [seed]
   only (see the module doc comment); calling this twice with the same
   [seed] and [count] always returns the same list. *)
let generate ~seed ~count =
  let state = state_of_seed seed in
  category_names
  |> List.filteri (fun i _ -> i < count)
  |> List.map (fun category ->
    let value = value_of_category state category in
    { category; statement = statement_of ~category ~value; value })

let recall_prompt =
  "Without looking anything up, please list every fact I told you to \
   remember earlier in this conversation, in the order I gave them to you."

type turn_plan_entry = { index : int; category : string option; message : string }

(* The pure turn sequence a run sends: [facts] in order as 1-indexed
   fact-injection turns (category = Some), then one recall turn at
   [List.length facts + 1] (category = None). Kept separate from
   [generate] so bin/keeper_canary_run.ml can drive this sequence without
   duplicating the indexing/labeling logic inline — that duplication was
   the actual protocol-sequence bug surface, not [generate] itself. *)
let plan ~(facts : fact list) : turn_plan_entry list =
  let fact_entries =
    List.mapi
      (fun i (f : fact) -> { index = i + 1; category = Some f.category; message = f.statement })
      facts
  in
  let recall_entry =
    { index = List.length facts + 1; category = None; message = recall_prompt }
  in
  fact_entries @ [ recall_entry ]

(* Case-insensitive substring search, since a model may recall a value in a
   different letter case than it was given (e.g. lower-casing a codename in
   prose) without that being a recall failure. *)
let contains_ci ~needle haystack =
  let needle = String.lowercase_ascii needle in
  let haystack = String.lowercase_ascii haystack in
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then Some 0
  else (
    let rec scan i =
      if i + nl > hl then None
      else if String.sub haystack i nl = needle then Some i
      else scan (i + 1)
    in
    scan 0)

type recall_result = {
  category : string;
  value : string;
  recalled : bool;
  first_index : int option; (* byte offset in the reply, for order checking *)
}

type score = {
  facts_total : int;
  facts_recalled : int;
  order_matches : bool;
      (** [true] only when every recalled fact's first occurrence in the
          reply is strictly after the previous recalled fact's — a partial
          recall (some facts missing) can still have [order_matches = true]
          for the facts it did recall. *)
  recalled_categories : string list;
  missing_categories : string list;
  per_fact : recall_result list;
}

(* This score is a raw, deterministic signal (substring presence + order),
   not the canary's pass/fail judgment — see keeper_canary_evidence.mli's
   [judgment] field, which a follow-up PR fills from an LLM judge instead of
   this substring check (a paraphrased-but-correct recall would score as a
   miss here). *)
let score ~(facts : fact list) ~(reply : string) : score =
  let per_fact =
    List.map
      (fun (f : fact) ->
         let first_index = contains_ci ~needle:f.value reply in
         { category = f.category
         ; value = f.value
         ; recalled = Option.is_some first_index
         ; first_index
         })
      facts
  in
  let recalled = List.filter (fun r -> r.recalled) per_fact in
  let order_matches =
    let indices = List.filter_map (fun r -> r.first_index) recalled in
    let rec strictly_increasing = function
      | [] | [ _ ] -> true
      | a :: (b :: _ as rest) -> a < b && strictly_increasing rest
    in
    strictly_increasing indices
  in
  { facts_total = List.length facts
  ; facts_recalled = List.length recalled
  ; order_matches
  ; recalled_categories = List.map (fun r -> r.category) recalled
  ; missing_categories =
      per_fact
      |> List.filter (fun r -> not r.recalled)
      |> List.map (fun r -> r.category)
  ; per_fact
  }
