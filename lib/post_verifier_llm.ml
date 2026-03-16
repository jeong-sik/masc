(** Post Verifier LLM — G-Eval rubric scoring via LLM cascade.

    Separated from Post_verifier to avoid dependency cycles:
    Board -> Lodge_selection -> Post_verifier would pull in Llm_client,
    creating a cycle through Llm_response_cache -> Board.

    Modes (MASC_VERIFIER_MODE env var):
    - "heuristic" (default): delegates to Post_verifier.verify
    - "llm": G-Eval rubric scoring via LLM cascade
    - "hybrid": heuristic pre-filter + LLM for non-Fail content

    @since 2.71.0 *)

open Post_verifier

type verifier_mode = Heuristic | Llm | Hybrid

let get_verifier_mode () =
  match Sys.getenv_opt "MASC_VERIFIER_MODE" with
  | Some "llm" -> Llm
  | Some "hybrid" -> Hybrid
  | _ -> Heuristic

(** G-Eval rubric prompt for post quality assessment. *)
let build_geval_prompt ~content : string =
  Printf.sprintf
{|You are evaluating content quality for an AI agent community board.

Rate the following content on three dimensions using a 1-5 scale.

## Rubric

### Relevance (1-5)
1: Empty, placeholder, or completely off-topic
2: Minimal substance, mostly filler
3: Has a topic but lacks depth
4: Clear topic with reasonable substance
5: Focused, substantive, adds value

### Quality (1-5)
1: Gibberish, extreme repetition, unreadable
2: Poorly structured, significant repetition
3: Readable but has structural issues
4: Well-formed, coherent structure
5: Polished, clear writing with good flow

### Safety (1-5)
1: Harmful, spam, or abusive content
2: Borderline spam, excessive self-promotion
3: Minor concerns (all-caps sections, many URLs)
4: Mostly clean with negligible issues
5: Completely appropriate for a professional board

## Content to evaluate
%s

## Response format
Respond with ONLY a JSON object, no other text:
{"relevance": <1-5>, "quality": <1-5>, "safety": <1-5>, "reasoning": "<brief explanation>"}|}
    (Yojson.Safe.to_string (`String content))

(** Parse G-Eval JSON response into scores.
    Returns Ok (relevance_score, quality_score, safety_score, reasoning) or Error. *)
let parse_geval_response (text : string) :
    (int * int * int * string, string) result =
  let trimmed = String.trim text in
  let json_str =
    (* Handle cases where LLM wraps JSON in markdown code blocks *)
    match String.index_opt trimmed '{' with
    | None -> trimmed
    | Some start_idx -> (
        match String.rindex_opt trimmed '}' with
        | None -> trimmed
        | Some end_idx ->
            if end_idx > start_idx then
              String.sub trimmed start_idx (end_idx - start_idx + 1)
            else trimmed)
  in
  match Yojson.Safe.from_string json_str with
  | exception _ -> Error (Printf.sprintf "invalid JSON: %s" json_str)
  | json ->
      let open Yojson.Safe.Util in
      (try
         let r = json |> member "relevance" |> to_int in
         let q = json |> member "quality" |> to_int in
         let s = json |> member "safety" |> to_int in
         let reasoning =
           try json |> member "reasoning" |> to_string
           with
           | Yojson.Safe.Util.Type_error _ -> ""
           | exn ->
               Log.BoardLog.warn "post_verifier reasoning parse: %s" (Printexc.to_string exn);
               ""
         in
         if r >= 1 && r <= 5 && q >= 1 && q <= 5 && s >= 1 && s <= 5 then
           Ok (r, q, s, reasoning)
         else
           Error
             (Printf.sprintf "scores out of range: r=%d q=%d s=%d" r q s)
       with exn ->
         Error
           (Printf.sprintf "missing fields: %s" (Printexc.to_string exn)))

(** Convert a 1-5 G-Eval score to a verdict. *)
let score_to_verdict ~(dim_name : string) (score : int) : verdict =
  if score <= 1 then Fail (Printf.sprintf "%s scored 1/5" dim_name)
  else if score <= 2 then Fail (Printf.sprintf "%s scored 2/5" dim_name)
  else if score = 3 then Warn (Printf.sprintf "%s scored 3/5" dim_name)
  else Pass

(** Validate that an LLM response contains parseable G-Eval scores. *)
let geval_response_is_valid (resp : Llm_client.completion_response) : bool =
  match parse_geval_response resp.content with
  | Ok _ -> true
  | Error _ -> false

(** LLM-based G-Eval verification. Calls the LLM cascade.
    Returns Ok verification_result or Error string. *)
let verify_llm ~content : (verification_result, string) result =
  let prompt = build_geval_prompt ~content in
  match
    Lodge_cascade.call ~cascade_name:"verifier" ~prompt
      ~temperature:0.2 ~timeout_sec:15 ~max_tokens:150
      ~accept:geval_response_is_valid ()
  with
  | Error err -> Error err
  | Ok r -> (
      match parse_geval_response r.response with
      | Error err -> Error err
      | Ok (r, q, s, _reasoning) ->
          let relevance = score_to_verdict ~dim_name:"relevance" r in
          let quality = score_to_verdict ~dim_name:"quality" q in
          let safety = score_to_verdict ~dim_name:"safety" s in
          let overall =
            match (relevance, quality, safety) with
            | (Fail reason, _, _) -> Fail reason
            | (_, Fail reason, _) -> Fail reason
            | (_, _, Fail reason) -> Fail reason
            | (Warn reason, _, _) -> Warn reason
            | (_, Warn reason, _) -> Warn reason
            | (_, _, Warn reason) -> Warn reason
            | (Pass, Pass, Pass) -> Pass
          in
          Ok { relevance; quality; safety; overall })

(** Verify content using the mode from MASC_VERIFIER_MODE.
    - heuristic: pure deterministic (default)
    - llm: G-Eval rubric scoring
    - hybrid: heuristic pre-filter, then LLM for non-Fail content *)
let verify_auto ~content : verification_result =
  match get_verifier_mode () with
  | Heuristic -> verify ~content
  | Llm -> (
      match verify_llm ~content with
      | Ok result -> result
      | Error _err -> verify ~content)
  | Hybrid ->
      let heuristic = verify ~content in
      if not (is_acceptable heuristic) then heuristic
      else (
        match verify_llm ~content with
        | Ok result -> result
        | Error _err -> heuristic)
