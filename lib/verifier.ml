(** Verifier — Cheap-model action verification for feedback loops.

    Each action is sent to a cheap model with a structured prompt:
    "Given goal X, action Y produced result Z. Is this correct?"
    The model responds PASS/WARN/FAIL with a brief reason.

    Budget: max 200 output tokens per verification (~0.01 cents).
    Skip: read-only actions (file reads, glob, grep, searches).

    @since 2.61.0 *)

open Printf

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type verification_request = {
  action_description : string;
  action_result : string;
  goal : string;
  context_summary : string;
}

type verdict =
  | Pass
  | Warn of string
  | Fail of string

(* ================================================================ *)
(* Read-Only Detection                                              *)
(* ================================================================ *)

(** Actions that are safe and need no verification. *)
let read_only_patterns = [
  "read"; "glob"; "grep";
  "search"; "find"; "list"; "ls"; "cat"; "head"; "tail";
  "git status"; "git log"; "git diff";
  "status"; "view"; "get"; "fetch"; "query";
]

let is_word_char c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

let has_pattern_with_word_boundary ~text ~pat =
  let tlen = String.length text in
  let plen = String.length pat in
  if plen = 0 || tlen < plen then false
  else
    let rec loop i =
      if i > tlen - plen then false
      else if String.sub text i plen = pat then
        let before_ok = i = 0 || not (is_word_char text.[i - 1]) in
        let after_idx = i + plen in
        let after_ok = after_idx >= tlen || not (is_word_char text.[after_idx]) in
        if before_ok && after_ok then true else loop (i + 1)
      else
        loop (i + 1)
    in
    loop 0

let should_skip ~action_description =
  let text = String.lowercase_ascii action_description in
  List.exists (fun pat ->
    has_pattern_with_word_boundary ~text ~pat
  ) read_only_patterns

(* ================================================================ *)
(* Verdict Parsing                                                  *)
(* ================================================================ *)

let verdict_to_string = function
  | Pass -> "PASS"
  | Warn reason -> sprintf "WARN: %s" reason
  | Fail reason -> sprintf "FAIL: %s" reason

(** Parse "PASS", "WARN: reason", "FAIL: reason" from LLM output. *)
let parse_verdict (text : string) : verdict =
  let trimmed = String.trim text in
  let upper = String.uppercase_ascii trimmed in
  if String.length upper >= 4 && String.sub upper 0 4 = "PASS" then
    Pass
  else if String.length upper >= 4 && String.sub upper 0 4 = "WARN" then
    let reason = if String.length trimmed > 5 then
      String.trim (String.sub trimmed 5 (String.length trimmed - 5))
    else "unspecified concern" in
    (* Strip leading colon/dash *)
    let reason = if String.length reason > 0 &&
      (reason.[0] = ':' || reason.[0] = '-') then
      String.trim (String.sub reason 1 (String.length reason - 1))
    else reason in
    Warn reason
  else if String.length upper >= 4 && String.sub upper 0 4 = "FAIL" then
    let reason = if String.length trimmed > 5 then
      String.trim (String.sub trimmed 5 (String.length trimmed - 5))
    else "action did not achieve goal" in
    let reason = if String.length reason > 0 &&
      (reason.[0] = ':' || reason.[0] = '-') then
      String.trim (String.sub reason 1 (String.length reason - 1))
    else reason in
    Fail reason
  else
    (* If model doesn't follow format, treat as warning *)
    if String.length trimmed > 0 then Warn trimmed
    else Pass

(* ================================================================ *)
(* Verification Prompt                                              *)
(* ================================================================ *)

let build_prompt (req : verification_request) : string =
  sprintf
{|You are a verification agent. Evaluate whether this action was correct.

Goal: %s

Context: %s

Action taken: %s

Result: %s

Respond with exactly one of:
PASS - if the action is correct and moves toward the goal
WARN: <reason> - if the action is acceptable but has concerns
FAIL: <reason> - if the action is wrong or harmful

One line only.|}
    req.goal
    (if String.length req.context_summary > 300
     then String.sub req.context_summary 0 300 ^ "..."
     else req.context_summary)
    req.action_description
    (if String.length req.action_result > 500
     then String.sub req.action_result 0 500 ^ "..."
     else req.action_result)

(* ================================================================ *)
(* Core: verify                                                     *)
(* ================================================================ *)

let verify ~(model : Llm_types.model_spec) (req : verification_request) : verdict =
  if should_skip ~action_description:req.action_description then
    Pass
  else
    let prompt = build_prompt req in
    let completion_req : Llm_types.completion_request = {
      model;
      messages = [Llm_types.user_msg prompt];
      temperature = 0.0;  (* Deterministic for verification *)
      max_tokens = 200;   (* Budget cap *)
      tools = [];
      response_format = `Text;
    } in
    match Llm_orchestration.complete completion_req with
    | Ok resp -> parse_verdict (Llm_types.text_of_response resp)
    | Error e ->
      eprintf "[verifier] LLM call failed: %s (defaulting to WARN)\n%!" e;
      Warn ("verifier_unavailable: " ^ e)
