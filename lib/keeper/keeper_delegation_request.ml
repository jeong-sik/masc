(** Keeper delegation requests projected from deliberation. *)

open Keeper_deliberation

type promotion_state =
  | Candidate
  | Promoted
  | Rejected

let promotion_state_to_string = function
  | Candidate -> "candidate"
  | Promoted -> "promoted"
  | Rejected -> "rejected"

type task_seed = {
  title : string;
  description : string;
  tags : string list;
}

type t = {
  id : string;
  requester : string;
  topic : string;
  reason : string;
  goal : string option;
  source_action : string;
  promotion_state : promotion_state;
  task_seed : task_seed;
}

let normalize_opt value =
  match String.trim value with
  | "" -> None
  | text -> Some text

let compact_whitespace text =
  let buf = Buffer.create (String.length text) in
  let pending_space = ref false in
  String.iter
    (fun ch ->
      match ch with
      | ' ' | '\n' | '\r' | '\t' ->
          pending_space := Buffer.length buf > 0
      | _ ->
          if !pending_space then Buffer.add_char buf ' ';
          pending_space := false;
          Buffer.add_char buf ch)
    (String.trim text);
  Buffer.contents buf

let truncate ~max_len text =
  if String.length text <= max_len then text
  else
    let rec utf8_boundary idx =
      if idx <= 0 then 0
      else if Char.code text.[idx] land 0xc0 = 0x80 then utf8_boundary (idx - 1)
      else idx
    in
    String.sub text 0 (utf8_boundary max_len)

let digest_id ~requester ?goal ~topic ~reason () =
  let goal_text =
    match goal with
    | Some text -> text
    | None -> ""
  in
  let raw =
    String.concat "\n"
      [
        requester;
        topic;
        reason;
        goal_text;
      ]
  in
  let hex = Digest.to_hex (Digest.string raw) in
  "delegation-" ^ String.sub hex 0 12

let task_seed ~requester ?goal ~topic ~reason () =
  let title_topic = topic |> compact_whitespace |> truncate ~max_len:80 in
  let title =
    if title_topic = "" then "Delegate keeper work"
    else "Delegate: " ^ title_topic
  in
  let reason =
    match compact_whitespace reason with
    | "" -> "(no reason supplied)"
    | text -> text
  in
  let goal_lines =
    match goal with
    | Some goal -> [ ""; "Goal:"; goal ]
    | None -> []
  in
  let description =
    String.concat "\n"
      ([
         "Delegation request from keeper `" ^ requester ^ "`.";
         "";
         "Topic:";
         topic;
         "";
         "Reason:";
         reason;
       ]
      @ goal_lines
      @ [
          "";
          "Execution contract:";
          "- This is a MASC task seed, not a direct child-agent spawn.";
          "- Promote by creating/assigning a task or routing to an existing keeper.";
          "- Do not invoke generic OAS swarm orchestration from this artifact.";
        ])
  in
  let tags =
    [
      "keeper_delegation";
      "propose_spawn";
      "requester:" ^ requester;
    ]
    @
    match goal with
    | Some _ -> [ "has_goal" ]
    | None -> []
  in
  { title; description; tags }

let make ~requester ?goal ~topic ~reason () =
  let requester =
    match compact_whitespace requester with
    | "" -> "unknown"
    | text -> text
  in
  let topic = compact_whitespace topic in
  let reason = compact_whitespace reason in
  let goal = Option.bind goal normalize_opt in
  let source_action =
    deliberation_action_to_string (ProposeSpawn { topic; reason })
  in
  {
    id = digest_id ~requester ?goal ~topic ~reason ();
    requester;
    topic;
    reason;
    goal;
    source_action;
    promotion_state = Candidate;
    task_seed = task_seed ~requester ?goal ~topic ~reason ();
  }

let rec of_action ~requester ?goal = function
  | ProposeSpawn { topic; reason } ->
      [ make ~requester ?goal ~topic ~reason () ]
  | MultiStep actions ->
      List.concat_map (of_action ~requester ?goal) actions
  | Noop _ | BoardPost _ | BoardComment _ | BoardVote _ | TaskClaim _
  | Broadcast _ ->
      []


let of_execution_result ~requester ?goal result =
  of_action ~requester ?goal result.selected_action

let task_seed_to_json seed =
  `Assoc
    [
      ("title", `String seed.title);
      ("description", `String seed.description);
      ("tags", `List (List.map (fun tag -> `String tag) seed.tags));
    ]

let to_json request =
  `Assoc
    [
      ("schema", `String "masc.keeper_delegation_request.v1");
      ("id", `String request.id);
      ("requester", `String request.requester);
      ("topic", `String request.topic);
      ("reason", `String request.reason);
      ("goal", Json_util.string_opt_to_json request.goal);
      ("source_action", `String request.source_action);
      ( "promotion_state",
        `String (promotion_state_to_string request.promotion_state) );
      ("task_seed", task_seed_to_json request.task_seed);
    ]

let delegation_request_json ~requester ?goal = function
  | Some execution ->
      let requests = of_execution_result ~requester ?goal execution in
      (match requests with
      | [] -> `Null
      | [ request ] -> to_json request
      | _ -> `List (List.map to_json requests))
  | None -> `Null

let delegation_request_field ~requester ?goal execution =
  ("delegation_request", delegation_request_json ~requester ?goal execution)

