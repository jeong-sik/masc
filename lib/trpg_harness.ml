(** trpg_harness.ml — TRPG Keeper Evaluation Harness.

    2-Tier LLM-as-judge system for scoring keeper responses.
    Follows the verifier.ml pattern for LLM calls.

    @since 2.70.0 *)

open Printf

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type dimension = Character_fidelity | Human_likeness | Narrative_consistency
[@@deriving show, eq]

type dimension_score = {
  dimension : dimension;
  score : float;
  reason : string;
}

type tier1_result = Pass | Fail of string

type evaluation_result = {
  tier1 : tier1_result;
  scores : dimension_score list;
  weighted_total : float;
  raw_response : string;
  evaluated_at : string;
}

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let string_of_dimension = function
  | Character_fidelity -> "character_fidelity"
  | Human_likeness -> "human_likeness"
  | Narrative_consistency -> "narrative_consistency"

let truncate ~max_len s =
  if String.length s > max_len then String.sub s 0 max_len ^ "..."
  else s

let now_iso8601 () =
  let t = Time_compat.now () in
  let tm = Unix.gmtime t in
  sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec

(* ================================================================ *)
(* Dimension weights                                                *)
(* ================================================================ *)

let weight_of = function
  | Character_fidelity -> 0.4
  | Human_likeness -> 0.3
  | Narrative_consistency -> 0.3

let all_dimensions = [Character_fidelity; Human_likeness; Narrative_consistency]

(* ================================================================ *)
(* Tier 1: Structural gate                                          *)
(* ================================================================ *)

let build_tier1_prompt ~actor_name ~actor_persona ~response_text =
  sprintf
{|You are evaluating a TRPG character response for basic quality.
Character: %s (%s)
Response: %s

Check:
1. Is the response non-empty and coherent?
2. Does it contain an action or dialogue (not just meta-commentary)?
3. Is it roughly in-character (not random gibberish)?

Answer exactly: PASS or FAIL: <reason>|}
    actor_name
    actor_persona
    (truncate ~max_len:500 response_text)

let parse_tier1 (text : string) : tier1_result =
  let trimmed = String.trim text in
  let upper = String.uppercase_ascii trimmed in
  if String.length upper >= 4 && String.sub upper 0 4 = "PASS" then
    Pass
  else if String.length upper >= 4 && String.sub upper 0 4 = "FAIL" then
    let rest = if String.length trimmed > 4 then
      String.trim (String.sub trimmed 4 (String.length trimmed - 4))
    else "" in
    let reason =
      if String.length rest > 0 && (rest.[0] = ':' || rest.[0] = '-') then
        String.trim (String.sub rest 1 (String.length rest - 1))
      else if String.length rest > 0 then rest
      else "structural check failed"
    in
    Fail reason
  else
    Fail "unparseable response"

let tier1_check ~(model : Llm_types.model_spec) ~actor_name ~actor_persona
    ~response_text : tier1_result =
  let prompt = build_tier1_prompt ~actor_name ~actor_persona ~response_text in
  let req : Llm_types.completion_request = {
    model;
    messages = [Llm_types.user_msg prompt];
    temperature = 0.0;
    max_tokens = 50;
    tools = [];
    response_format = `Text;
  } in
  match Llm_orchestration.complete req with
  | Ok resp -> parse_tier1 (Llm_types.text_of_response resp)
  | Error e ->
    eprintf "[trpg_harness] tier1 LLM call failed: %s\n%!" e;
    Fail ("tier1_unavailable: " ^ e)

(* ================================================================ *)
(* Tier 2: Quality evaluation                                       *)
(* ================================================================ *)

let build_tier2_prompt ~actor_name ~actor_persona ~actor_traits ~scene_context
    ~response_text =
  let traits_str = String.concat ", " actor_traits in
  sprintf
{|You are a TRPG quality judge. Score this character's response on three dimensions (1-5 each).

Character: %s
Persona: %s
Traits: %s
Scene: %s
Response: %s

Score each dimension (1=poor, 5=excellent):
CHARACTER_FIDELITY: <score> <one-line reason>
HUMAN_LIKENESS: <score> <one-line reason>
NARRATIVE_CONSISTENCY: <score> <one-line reason>|}
    actor_name
    actor_persona
    traits_str
    (truncate ~max_len:300 scene_context)
    (truncate ~max_len:500 response_text)

(** Extract score (1-5) and reason from a line like "CHARACTER_FIDELITY: 4 stays in role" *)
let parse_score_line (line : string) (prefix : string) : (float * string) option =
  let upper = String.uppercase_ascii line in
  let plen = String.length prefix in
  if String.length upper >= plen && String.sub upper 0 plen = prefix then
    let rest = String.trim (String.sub line plen (String.length line - plen)) in
    (* Strip leading colon *)
    let rest =
      if String.length rest > 0 && rest.[0] = ':' then
        String.trim (String.sub rest 1 (String.length rest - 1))
      else rest
    in
    (* Extract leading digit 1-5 followed by space or end-of-string *)
    let re = Str.regexp {|^\([1-5]\)[ \t]\(.*\)|} in
    if Str.string_match re rest 0 then
      let score = float_of_string (Str.matched_group 1 rest) in
      let reason = String.trim (Str.matched_group 2 rest) in
      let reason = if String.length reason = 0 then "no reason given" else reason in
      Some (score, reason)
    else if String.length rest = 1 && rest.[0] >= '1' && rest.[0] <= '5' then
      (* Bare digit with no reason *)
      Some (float_of_string rest, "no reason given")
    else
      None
  else
    None

let default_score dim = {
  dimension = dim;
  score = 3.0;
  reason = "not evaluated";
}

let parse_tier2 (text : string) : dimension_score list =
  let lines = String.split_on_char '\n' text in
  let find_dim dim prefix =
    let rec search = function
      | [] -> default_score dim
      | line :: rest ->
        (match parse_score_line line prefix with
         | Some (score, reason) -> { dimension = dim; score; reason }
         | None -> search rest)
    in
    search lines
  in
  [
    find_dim Character_fidelity "CHARACTER_FIDELITY";
    find_dim Human_likeness "HUMAN_LIKENESS";
    find_dim Narrative_consistency "NARRATIVE_CONSISTENCY";
  ]

let tier2_evaluate ~(model : Llm_types.model_spec) ~actor_name ~actor_persona
    ~actor_traits ~scene_context ~response_text : dimension_score list =
  let prompt = build_tier2_prompt ~actor_name ~actor_persona ~actor_traits
    ~scene_context ~response_text in
  let req : Llm_types.completion_request = {
    model;
    messages = [Llm_types.user_msg prompt];
    temperature = 0.0;
    max_tokens = 200;
    tools = [];
    response_format = `Text;
  } in
  match Llm_orchestration.complete req with
  | Ok resp -> parse_tier2 (Llm_types.text_of_response resp)
  | Error e ->
    eprintf "[trpg_harness] tier2 LLM call failed: %s\n%!" e;
    List.map default_score all_dimensions

(* ================================================================ *)
(* Weighted scoring                                                 *)
(* ================================================================ *)

(** Compute weighted total normalized to 0.0-1.0 range. *)
let compute_weighted_total (scores : dimension_score list) : float =
  let weighted_sum = List.fold_left (fun acc ds ->
    acc +. (ds.score *. weight_of ds.dimension)
  ) 0.0 scores in
  weighted_sum /. 5.0

(* ================================================================ *)
(* Full pipeline                                                    *)
(* ================================================================ *)

let evaluate ~tier1_model ~tier2_model ~actor_name ~actor_persona
    ~actor_traits ~scene_context ~response_text : evaluation_result =
  let tier1 = tier1_check ~model:tier1_model ~actor_name ~actor_persona
    ~response_text in
  match tier1 with
  | Fail _ as f ->
    { tier1 = f;
      scores = [];
      weighted_total = 0.0;
      raw_response = "";
      evaluated_at = now_iso8601 (); }
  | Pass ->
    let scores = tier2_evaluate ~model:tier2_model ~actor_name ~actor_persona
      ~actor_traits ~scene_context ~response_text in
    let weighted_total = compute_weighted_total scores in
    { tier1 = Pass;
      scores;
      weighted_total;
      raw_response = "";
      evaluated_at = now_iso8601 (); }

(* ================================================================ *)
(* JSON serialization                                               *)
(* ================================================================ *)

let tier1_to_string = function
  | Pass -> "pass"
  | Fail reason -> "fail:" ^ reason

let dimension_score_to_yojson (ds : dimension_score) : Yojson.Safe.t =
  `Assoc [
    ("dimension", `String (string_of_dimension ds.dimension));
    ("score", `Float ds.score);
    ("reason", `String ds.reason);
  ]

let result_to_yojson (r : evaluation_result) : Yojson.Safe.t =
  `Assoc [
    ("tier1", `String (tier1_to_string r.tier1));
    ("scores", `List (List.map dimension_score_to_yojson r.scores));
    ("weighted_total", `Float r.weighted_total);
    ("raw_response", `String r.raw_response);
    ("evaluated_at", `String r.evaluated_at);
  ]
