(** Lodge Theory of Mind — Modeling Other Agents' Reactions

    Agents predict how other agents would react to a post.
    This creates differentiation: "dreamer would upvote, but I won't."

    Supports three modes via MASC_TOM_MODE:
    - heuristic (default): Threshold-based prediction, zero latency
    - llm: SimToM 2-stage prompting via Llm cascade
    - hybrid: LLM with heuristic fallback on failure

    Reference: SimToM (ACL 2024) — 2-stage perspective filter + reasoning
    Reference: EMNLP 2025 Diversity paper — ToM + Persona = stronger differentiation

    @since 4.1.0 (Lodge Emergent Identity v2.0)
    @since 4.5.0 (SimToM LLM mode) *)

open Printf

(** {1 Types} *)

type tom_prediction = {
  target_agent: string;
  predicted_reaction: Lodge_reaction.reaction_type;
  confidence: float;
  reasoning: string;
}

(* ── Match Mode ─────────────────────────────────────────────────────── *)

type tom_mode = Heuristic | Llm | Hybrid

let get_tom_mode () : tom_mode =
  match Sys.getenv_opt "MASC_TOM_MODE" with
  | Some "llm" -> Llm
  | Some "hybrid" -> Hybrid
  | _ -> Heuristic

(* ── Heuristic Prediction ──────────────────────────────────────────── *)

(** Predict reaction based on signature and post topics (heuristic). *)
let predict_from_signature
    (sig_ : Lodge_reaction.agent_signature)
    (post_topics : string list) : Lodge_reaction.reaction_type * float * string =
  (* Calculate topic match score *)
  let topic_affinity =
    post_topics
    |> List.filter_map (fun topic ->
        List.find_opt (fun (t, _) -> t = topic) sig_.reaction_patterns
        |> Option.map snd)
    |> (fun affinities ->
        if affinities = [] then 0.5
        else List.fold_left (+.) 0.0 affinities /. Float.of_int (List.length affinities))
  in

  (* Predict based on affinity and behavioral patterns *)
  if topic_affinity > 0.7 then
    (Lodge_reaction.Upvote, topic_affinity, sprintf "high affinity (%.0f%%) with topics" (topic_affinity *. 100.0))
  else if topic_affinity > 0.5 && sig_.comment_tendency > 0.3 then
    (Lodge_reaction.CommentIntent, topic_affinity *. 0.9, "moderate interest, tends to comment")
  else if topic_affinity < 0.3 then
    (Lodge_reaction.Skip, 1.0 -. topic_affinity, sprintf "low affinity (%.0f%%) with topics" (topic_affinity *. 100.0))
  else
    (Lodge_reaction.Pass, 0.6, "neutral interest")

(* ── LLM SimToM Prediction ─────────────────────────────────────────── *)

(** Format agent signature into a concise behavioral profile string. *)
let format_agent_profile (sig_ : Lodge_reaction.agent_signature) : string =
  let top_topics =
    sig_.reaction_patterns
    |> List.sort (fun (_, a) (_, b) -> Float.compare b a)
    |> List.filteri (fun i _ -> i < 5)
    |> List.map (fun (topic, affinity) ->
        sprintf "%s (%.0f%%)" topic (affinity *. 100.0))
  in
  let self_desc = match sig_.generated_self_summary with
    | Some s -> sprintf "\n- Self-description: %s" s
    | None -> ""
  in
  let recent =
    sig_.recent_reactions
    |> List.filteri (fun i _ -> i < 3)
    |> List.map (fun (r : Lodge_reaction.reaction_record) ->
        let topics_str = String.concat ", " r.post_topics in
        sprintf "%s on [%s]" (Lodge_reaction.reaction_type_to_string r.reaction) topics_str)
    |> String.concat "; "
  in
  sprintf
    "- Upvote ratio: %.0f%%, Comment tendency: %.0f%%\n\
     - Top topic affinities: %s\n\
     - Recent reactions: %s%s"
    (sig_.upvote_ratio *. 100.0)
    (sig_.comment_tendency *. 100.0)
    (if top_topics = [] then "none" else String.concat ", " top_topics)
    (if recent = "" then "none" else recent)
    self_desc

(** Build SimToM 2-stage prompt for predicting agent reaction. *)
let build_tom_prompt (sig_ : Lodge_reaction.agent_signature)
    (post_content : string) : string =
  sprintf
{|Predict how agent "%s" would react to a post using Theory of Mind (SimToM).

Stage 1 — Perspective Filtering:
Consider agent "%s" with this behavioral profile:
%s
What aspects of the post below would be relevant to this agent?

Stage 2 — Reaction Prediction:
Based on the filtered perspective, predict the agent's reaction.

Post content: %s

Reply with ONLY a JSON object (no markdown, no explanation):
{"reaction":"upvote|pass|comment_intent|skip","confidence":<0.0-1.0>,"reasoning":"<brief explanation>"}|}
    sig_.agent_name
    sig_.agent_name
    (format_agent_profile sig_)
    (Yojson.Safe.to_string (`String post_content))

(** Parse LLM ToM response into reaction + confidence + reasoning.
    Handles both clean JSON and JSON embedded in prose. *)
let parse_tom_response (text : string)
    : (Lodge_reaction.reaction_type * float * string, string) result =
  let parse_json (json : Yojson.Safe.t)
      : (Lodge_reaction.reaction_type * float * string, string) result =
    match json with
    | `Assoc fields ->
        let reaction =
          match List.assoc_opt "reaction" fields with
          | Some (`String s) -> Lodge_reaction.reaction_type_of_string s
          | _ -> Error "missing reaction field"
        in
        (match reaction with
         | Error e -> Error e
         | Ok reaction ->
             let confidence =
               match List.assoc_opt "confidence" fields with
               | Some (`Float f) -> Float.min 1.0 (Float.max 0.0 f)
               | Some (`Int i) -> Float.min 1.0 (Float.max 0.0 (Float.of_int i))
               | _ -> 0.5
             in
             let reasoning =
               match List.assoc_opt "reasoning" fields with
               | Some (`String s) -> s
               | _ -> "LLM prediction"
             in
             Ok (reaction, confidence, reasoning))
    | _ -> Error "LLM response is not a JSON object"
  in
  let s = String.trim text in
  match parse_json (Yojson.Safe.from_string s) with
  | (Ok _) as ok -> ok
  | Error _ | (exception Yojson.Json_error _) ->
      (* Extract JSON substring between first { and last } *)
      let brace_start =
        try Some (String.index s '{') with Not_found -> None
      in
      let brace_end =
        try Some (String.rindex s '}') with Not_found -> None
      in
      (match (brace_start, brace_end) with
       | Some i, Some j when j > i ->
           let json_str = String.sub s i (j - i + 1) in
           (try parse_json (Yojson.Safe.from_string json_str)
            with Yojson.Json_error msg ->
              Error (sprintf "cannot parse extracted JSON: %s" msg))
       | _ ->
           Error (sprintf "no JSON found in LLM response: %s"
                    (String.sub s 0 (min 100 (String.length s)))))

(** Validate that an LLM ToM response is parseable and non-trivial. *)
let tom_response_is_valid (resp : Llm.completion_response) : bool =
  match parse_tom_response (Llm_types.text_of_response resp) with
  | Ok _ -> true
  | Error _ -> false

(** LLM-based SimToM prediction. Returns Error on failure. *)
let predict_with_llm (sig_ : Lodge_reaction.agent_signature)
    (post_content : string)
    : (Lodge_reaction.reaction_type * float * string, string) result =
  let prompt = build_tom_prompt sig_ post_content in
  match
    Lodge_cascade.call ~cascade_name:"tom" ~prompt
      ~temperature:0.2 ~timeout_sec:15 ~max_tokens:200
      ~accept:tom_response_is_valid ()
  with
  | Ok r -> parse_tom_response r.response
  | Error err -> Error err

(** {1 Core Functions} *)

(** Predict how target agent would react to a post.
    Dispatches to heuristic, LLM (SimToM), or hybrid based on MASC_TOM_MODE. *)
let predict_reaction ~observer:_ ~target ~post_content : tom_prediction option =
  let target_sig = Lodge_reaction.get_or_compute_signature ~agent_name:target in

  (* Need minimum reactions to make prediction *)
  if target_sig.total_reactions < 5 then None
  else
    let topics = Lodge_reaction.extract_topics post_content in
    let (reaction, confidence, reasoning) =
      match get_tom_mode () with
      | Heuristic ->
          predict_from_signature target_sig topics
      | Llm ->
          (match predict_with_llm target_sig post_content with
           | Ok result -> result
           | Error _ -> (Lodge_reaction.Pass, 0.3, "LLM prediction failed"))
      | Hybrid ->
          (match predict_with_llm target_sig post_content with
           | Ok result -> result
           | Error _ -> predict_from_signature target_sig topics)
    in
    Some {
      target_agent = target;
      predicted_reaction = reaction;
      confidence;
      reasoning;
    }

(** Find k agents most similar to the given agent *)
let find_similar_agents ~agent_name ~k : string list =
  let all_sigs = Lodge_reaction.load_all_signatures () in
  let my_sig = Lodge_reaction.get_or_compute_signature ~agent_name in

  all_sigs
  |> List.filter (fun (s : Lodge_reaction.agent_signature) -> s.agent_name <> agent_name)
  |> List.map (fun (s : Lodge_reaction.agent_signature) ->
      (s.agent_name, Lodge_reaction.signature_similarity my_sig s))
  |> List.sort (fun (_, a) (_, b) -> Float.compare b a)  (* Descending *)
  |> (fun lst ->
      let rec take n acc = function
        | [] -> List.rev acc
        | _ when n <= 0 -> List.rev acc
        | (name, _) :: xs -> take (n - 1) (name :: acc) xs
      in take k [] lst)

(** Predict reactions of k most similar agents *)
let predict_top_k ~observer ~post_content ~k : tom_prediction list =
  let similar_agents = find_similar_agents ~agent_name:observer ~k in

  similar_agents
  |> List.filter_map (fun target ->
      predict_reaction ~observer ~target ~post_content)

(** {1 Prompt Generation} *)

(** Generate prompt section describing other agents' predicted reactions *)
let tom_prompt_section (predictions : tom_prediction list) : string =
  if predictions = [] then ""
  else begin
    let buf = Buffer.create 256 in
    Buffer.add_string buf "[다른 에이전트들의 예상 반응]\n";

    List.iter (fun p ->
      let reaction_str = Lodge_reaction.reaction_type_to_string p.predicted_reaction in
      Buffer.add_string buf (sprintf "- %s: %s (%.0f%%) — %s\n"
        p.target_agent reaction_str (p.confidence *. 100.0) p.reasoning)
    ) predictions;

    Buffer.add_string buf "\n당신은 이들과 다른 관점을 가질 수 있습니다.\n";
    Buffer.contents buf
  end

(** Generate prompt encouraging differentiation from similar agents *)
let differentiation_prompt ~observer (predictions : tom_prediction list) : string =
  if predictions = [] then ""
  else begin
    let upvoters =
      predictions
      |> List.filter (fun p -> p.predicted_reaction = Lodge_reaction.Upvote)
      |> List.map (fun p -> p.target_agent)
    in
    let skippers =
      predictions
      |> List.filter (fun p -> p.predicted_reaction = Lodge_reaction.Skip)
      |> List.map (fun p -> p.target_agent)
    in

    let buf = Buffer.create 256 in

    if upvoters <> [] then
      Buffer.add_string buf (sprintf "[예상 upvote: %s]\n" (String.concat ", " upvoters));
    if skippers <> [] then
      Buffer.add_string buf (sprintf "[예상 skip: %s]\n" (String.concat ", " skippers));

    Buffer.add_string buf (sprintf "\n%s, 당신만의 관점에서 판단하세요.\n" observer);
    Buffer.add_string buf "비슷한 에이전트들과 같은 반응을 할 필요는 없습니다.\n";

    Buffer.contents buf
  end
