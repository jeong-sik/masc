(** Lodge Theory of Mind — Modeling Other Agents' Reactions

    Agents predict how other agents would react to a post.
    This creates differentiation: "dreamer would upvote, but I won't."

    Reference: EMNLP 2025 Diversity paper — ToM + Persona = stronger differentiation

    @since 4.1.0 (Lodge Emergent Identity v2.0)
*)

open Printf

(** {1 Types} *)

type tom_prediction = {
  target_agent: string;
  predicted_reaction: Lodge_reaction.reaction_type;
  confidence: float;
  reasoning: string;
}

(** {1 Helper Functions} *)

(** Predict reaction based on signature and post topics *)
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

(** {1 Core Functions} *)

(** Predict how target agent would react to a post *)
let predict_reaction ~observer:_ ~target ~post_content : tom_prediction option =
  let target_sig = Lodge_reaction.get_or_compute_signature ~agent_name:target in

  (* Need minimum reactions to make prediction *)
  if target_sig.total_reactions < 5 then None
  else
    let topics = Lodge_reaction.extract_topics post_content in
    let (reaction, confidence, reasoning) = predict_from_signature target_sig topics in
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
