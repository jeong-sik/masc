open Yojson.Safe.Util

type action =
  | Post
  | Comment
  | Upvote
  | Skip

type reaction = {
  post_id : string;
  reaction : Lodge_reaction.reaction_type;
  confidence : float;
  reason : string option;
}

type choice = {
  action : action;
  target_post_id : string option;
  content : string option;
  reason : string;
  confidence : float;
}

type outcome = {
  reactions : reaction list;
  choice : choice;
}

let ( let* ) value f = match value with Ok x -> f x | Error _ as err -> err

let action_to_string = function
  | Post -> "post"
  | Comment -> "comment"
  | Upvote -> "upvote"
  | Skip -> "skip"

let action_of_string = function
  | "post" -> Ok Post
  | "comment" -> Ok Comment
  | "upvote" -> Ok Upvote
  | "skip" -> Ok Skip
  | other -> Error (Printf.sprintf "unsupported action: %s" other)

let trim_opt = function
  | None -> None
  | Some text ->
      let trimmed = String.trim text in
      if trimmed = "" then None else Some trimmed

let extract_json_object (response : string) : (string, string) result =
  let trimmed = String.trim response in
  try
    let start_idx = String.index trimmed '{' in
    let end_idx = String.rindex trimmed '}' in
    if end_idx < start_idx then Error "missing JSON object terminator"
    else Ok (String.sub trimmed start_idx (end_idx - start_idx + 1))
  with Not_found -> Error "missing JSON object"

let parse_confidence json =
  match json with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error "confidence must be numeric"

let validate_confidence confidence =
  if confidence < 0.0 || confidence > 1.0 then
    Error "confidence must be between 0.0 and 1.0"
  else
    Ok confidence

let parse_reason json =
  match json with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed = "" then Error "reason must be non-empty" else Ok trimmed
  | _ -> Error "reason must be a string"

let parse_reaction json =
  let post_id =
    match json |> member "post_id" with
    | `String s ->
        let trimmed = String.trim s in
        if trimmed = "" then Error "reaction.post_id must be non-empty" else Ok trimmed
    | _ -> Error "reaction.post_id must be a string"
  in
  match post_id with
  | Error _ as err -> err
  | Ok post_id ->
      let reaction_str =
        match json |> member "reaction" with
        | `String s -> Ok (String.lowercase_ascii (String.trim s))
        | _ -> Error "reaction.reaction must be a string"
      in
      let confidence =
        match parse_confidence (json |> member "confidence") with
        | Ok value -> validate_confidence value
        | Error _ as err -> err
      in
      let reason =
        json |> member "reason" |> to_string_option |> trim_opt
      in
      match reaction_str, confidence with
      | Ok reaction_name, Ok confidence -> (
          match Lodge_reaction.reaction_type_of_string reaction_name with
          | Ok reaction -> Ok { post_id; reaction; confidence; reason }
          | Error err ->
              Error (Printf.sprintf "invalid reaction for %s: %s" post_id err))
      | Error err, _ -> Error err
      | _, Error err -> Error err

let parse_choice json =
  let action =
    match json |> member "action" with
    | `String s -> action_of_string (String.lowercase_ascii (String.trim s))
    | _ -> Error "decision.action must be a string"
  in
  let target_post_id =
    json |> member "target_post_id" |> to_string_option |> trim_opt
  in
  let content =
    json |> member "content" |> to_string_option |> trim_opt
  in
  let reason = parse_reason (json |> member "reason") in
  let confidence =
    match parse_confidence (json |> member "confidence") with
    | Ok value -> validate_confidence value
    | Error _ as err -> err
  in
  match action, reason, confidence with
  | Ok action, Ok reason, Ok confidence ->
      Ok { action; target_post_id; content; reason; confidence }
  | Error err, _, _ -> Error err
  | _, Error err, _ -> Error err
  | _, _, Error err -> Error err

let validate_choice ~allowed_post_ids ~allow_post (choice : choice) =
  let post_id_allowed post_id =
    List.exists (String.equal post_id) allowed_post_ids
  in
  let require_content () =
    match choice.content with
    | Some content when String.trim content <> "" -> Ok ()
    | _ -> Error "content is required for this action"
  in
  let require_target () =
    match choice.target_post_id with
    | Some post_id when post_id_allowed post_id -> Ok post_id
    | Some post_id ->
        Error (Printf.sprintf "target_post_id %s is not in the candidate set" post_id)
    | None -> Error "target_post_id is required for this action"
  in
  match choice.action with
  | Post ->
      if not allow_post then Error "post action is not allowed in this context"
      else
        let* () = require_content () in
        Ok { choice with target_post_id = None }
  | Comment ->
      let* target_post_id = require_target () in
      let* () = require_content () in
      Ok { choice with target_post_id = Some target_post_id }
  | Upvote ->
      let* target_post_id = require_target () in
      Ok { choice with target_post_id = Some target_post_id; content = None }
  | Skip -> Ok { choice with target_post_id = None; content = None }

let validate_reactions ~allowed_post_ids (reactions : reaction list) =
  let seen = Hashtbl.create (List.length reactions) in
  let validate_one (reaction : reaction) =
    if not (List.exists (String.equal reaction.post_id) allowed_post_ids) then
      Error
        (Printf.sprintf "reaction post_id %s is not in the candidate set" reaction.post_id)
    else if Hashtbl.mem seen reaction.post_id then
      Error (Printf.sprintf "duplicate reaction for %s" reaction.post_id)
    else (
      Hashtbl.add seen reaction.post_id ();
      Ok ())
  in
  let rec loop = function
    | [] ->
        let missing =
          List.filter (fun post_id -> not (Hashtbl.mem seen post_id)) allowed_post_ids
        in
        if missing <> [] then
          Error
            (Printf.sprintf "missing reactions for: %s"
               (String.concat ", " missing))
        else
          Ok reactions
    | reaction :: rest ->
        let* () = validate_one reaction in
        loop rest
  in
  loop reactions

let single_reaction_prompt ~agent_name ~agent_prompt ~interests ~post_id ~content
    ~language_instruction =
  let interests_line =
    match interests with
    | [] -> ""
    | items ->
        Printf.sprintf "\nCurrent interests: %s"
          (String.concat ", " items)
  in
  Printf.sprintf
    {|You are Lodge agent %s.

Agent identity:
%s%s

Decide exactly one action for the target post below.
Allowed actions: "comment", "upvote", "skip"
Return JSON only. No markdown. No code fences.

Required JSON shape:
{
  "action": "comment|upvote|skip",
  "target_post_id": "%s",
  "content": "required when action=comment",
  "reason": "why this action fits your identity and the post",
  "confidence": 0.0
}

Rules:
- target_post_id must stay "%s"
- If action is comment, content must be concrete and add value in 1-4 sentences
- If action is upvote or skip, omit content or set it to empty
- %s

Target post:
%s|}
    agent_name agent_prompt interests_line post_id post_id
    (if String.trim language_instruction = "" then "Write naturally."
     else language_instruction)
    content

let batch_decision_prompt ~agent_name ~identity_prompt ~posts ~extra_context ~allow_post
    =
  let posts_section =
    match posts with
    | [] -> "(no recent posts)"
    | items ->
        items
        |> List.mapi (fun idx (post_id, author, content) ->
               Printf.sprintf "[Post %d]\nid=%s\nauthor=%s\ncontent=%s" (idx + 1)
                 post_id author content)
        |> String.concat "\n\n"
  in
  let action_choices =
    if allow_post then "\"post\", \"comment\", \"upvote\", \"skip\""
    else "\"comment\", \"upvote\", \"skip\""
  in
  let extra_context =
    match trim_opt extra_context with
    | Some text -> "\n\nAdditional context:\n" ^ text
    | None -> ""
  in
  Printf.sprintf
    {|You are Lodge agent %s.

Identity context:
%s%s

Review the candidate posts and make one final decision.
Return JSON only. No markdown. No code fences.

Required JSON shape:
{
  "reactions": [
    {
      "post_id": "candidate post id",
      "reaction": "upvote|pass|comment_intent|skip",
      "confidence": 0.0,
      "reason": "short rationale"
    }
  ],
  "decision": {
    "action": %s,
    "target_post_id": "required for comment/upvote",
    "content": "required for post/comment",
    "reason": "why this is the best next action",
    "confidence": 0.0
  }
}

Rules:
- React to every listed post exactly once
- decision.action must be one of %s
- If decision.action is comment or upvote, target_post_id must match a listed post
- If decision.action is comment or post, content must be non-empty and concrete
- If there are no candidate posts, reactions must be []
- If nothing is worth doing, choose "skip" with an explicit reason

Candidate posts:
%s|}
    agent_name identity_prompt extra_context action_choices action_choices posts_section

let parse_single_choice ~post_id response =
  let* json_text = extract_json_object response in
  let* json =
    try Ok (Yojson.Safe.from_string json_text)
    with Yojson.Json_error msg -> Error (Printf.sprintf "invalid JSON: %s" msg)
  in
  let* choice = parse_choice json in
  validate_choice ~allowed_post_ids:[ post_id ] ~allow_post:false choice

let parse_batch_outcome ~allowed_post_ids ~allow_post response =
  let* json_text = extract_json_object response in
  let* json =
    try Ok (Yojson.Safe.from_string json_text)
    with Yojson.Json_error msg -> Error (Printf.sprintf "invalid JSON: %s" msg)
  in
  let reactions =
    match json |> member "reactions" with
    | `List items ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | item :: rest ->
              let* parsed = parse_reaction item in
              loop (parsed :: acc) rest
        in
        loop [] items
    | _ -> Error "reactions must be an array"
  in
  let* reactions = reactions in
  let* reactions = validate_reactions ~allowed_post_ids reactions in
  let* choice =
    json |> member "decision" |> parse_choice
    |> function Ok choice -> validate_choice ~allowed_post_ids ~allow_post choice | Error _ as err -> err
  in
  Ok { reactions; choice }
