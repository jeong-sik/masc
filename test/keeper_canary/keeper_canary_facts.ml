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
  ; "escalation_channel"
  ; "artifact_name"
  ; "rollback_switch"
  ]

(* No enum-valued categories: a value drawn from a small pool (the old
   reviewer_timezones array) can also appear in a keeper transcript for
   unrelated reasons — another run's round, or ordinary prose — and the
   scorer attributes the first occurrence to this run's fact. Asia/Tokyo
   did exactly that on a reused keeper (2026-08-16, wave-1 sweep): the
   old round's list matched first and flipped order_matches to false.
   Every category value carries digest entropy instead. *)

(* No PRNG anywhere in this module: every value is read directly off a
   SHA-256 digest of [seed] and a [label] naming which draw it is
   (e.g. "deadline:month" vs "deadline:day" — a category needing more than
   one independent-looking value uses one label per value, not one seeded
   generator advanced twice). A PRNG's whole point is a stream of values
   from one seed; a hash keyed per-draw gives the same "looks independent,
   fully reproducible" property without a stream to seed, advance, or
   thread through call sites. *)
let digest_bytes ~seed ~label =
  Digestif.SHA256.(to_raw_string (digest_string (seed ^ "\x00" ^ label)))

let byte_at bytes i = Char.code bytes.[i]

(* First 4 digest bytes as a non-negative int, masked to fit a 32-bit
   OCaml int (top bit of the first byte cleared) so this behaves the same
   on 32- and 64-bit builds. *)
let uint31_of_bytes bytes =
  ((byte_at bytes 0 land 0x7f) lsl 24)
  lor (byte_at bytes 1 lsl 16)
  lor (byte_at bytes 2 lsl 8)
  lor byte_at bytes 3

let int_in_range ~seed ~label ~modulus =
  uint31_of_bytes (digest_bytes ~seed ~label) mod modulus

let hex_digits = "0123456789abcdef"

(* 6 bytes (12 hex chars) of digest output — same length as the
   Crypto_rng-backed nonce this module used to mint, but reproducible from
   [seed] and [label] alone. *)
let hex_suffix ~seed ~label =
  let bytes = digest_bytes ~seed ~label in
  String.init 12 (fun i ->
    let b = byte_at bytes (i / 2) in
    let nibble = if i mod 2 = 0 then b lsr 4 else b land 0xf in
    hex_digits.[nibble])

let value_of_category ~seed = function
  | "project_codename" -> "Codename-" ^ hex_suffix ~seed ~label:"project_codename"
  | "lead_reviewer" -> "Reviewer-" ^ hex_suffix ~seed ~label:"lead_reviewer"
  | "deadline" ->
    (* A digest-derived near-future timestamp, not tied to wall-clock
       "today" so the same run id reproduces the same value regardless of
       when it runs. Month, day, and time are independent labels, not
       draws from one stream, so none depends on another's derivation
       order. Minute resolution lifts the pool from ~336 dates to ~484k
       combinations (~19 bits) — collision *resistance* across rounds on
       one keeper, not a uniqueness guarantee like the 48-bit hex-suffix
       categories; ~50 accumulated rounds still carry roughly a 0.2%
       birthday collision chance on this field alone. The fresh-transcript
       gate in bin/keeper_canary_run.ml is what actually removes the
       reused-round scenario. *)
    let month = 1 + int_in_range ~seed ~label:"deadline:month" ~modulus:12 in
    let day = 1 + int_in_range ~seed ~label:"deadline:day" ~modulus:28 in
    let hour = int_in_range ~seed ~label:"deadline:hour" ~modulus:24 in
    let minute = int_in_range ~seed ~label:"deadline:minute" ~modulus:60 in
    Printf.sprintf "2026-%02d-%02d %02d:%02d UTC" month day hour minute
  | "blocked_dependency" -> "dep-" ^ hex_suffix ~seed ~label:"blocked_dependency"
  | "fallback_runtime" -> "runtime-" ^ hex_suffix ~seed ~label:"fallback_runtime"
  | "incident_number" ->
    (* Nine digits: the old 1000..9999 pool recurred across rounds. *)
    string_of_int (100_000_000 + int_in_range ~seed ~label:"incident_number" ~modulus:900_000_000)
  | "escalation_channel" -> "#esc-" ^ hex_suffix ~seed ~label:"escalation_channel"
  | "artifact_name" -> "artifact-" ^ hex_suffix ~seed ~label:"artifact_name" ^ ".json"
  | "rollback_switch" -> "rollback-" ^ hex_suffix ~seed ~label:"rollback_switch"
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
  | "escalation_channel" ->
    Printf.sprintf "The escalation channel is %s." value
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
  category_names
  |> List.filteri (fun i _ -> i < count)
  |> List.map (fun category ->
    let value = value_of_category ~seed category in
    { category; statement = statement_of ~category ~value; value })

let recall_prompt () =
  let prompt = Prompt_registry.get_prompt Prompt_names.keeper_canary_recall in
  if String.trim prompt = "" then invalid_arg "missing required canary recall prompt"
  else String.trim prompt

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
    { index = List.length facts + 1; category = None; message = recall_prompt () }
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

let interval_for_wall_clock ~gaps ~target_s =
  if gaps <= 0 then 0.0 else target_s /. float_of_int gaps
