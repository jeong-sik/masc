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
  source_action : string;
  promotion_state : promotion_state;
  task_seed : task_seed;
}

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
  let prefix, _ =
    Keeper_text_processing.truncate_utf8_prefix ~max_bytes:max_len text
  in
  prefix

let digest_id ~requester ~topic ~reason () =
  let raw =
    String.concat "\n" [ requester; topic; reason ]
  in
  let hex = Digest.to_hex (Digest.string raw) in
  "delegation-" ^ String.sub hex 0 12

let identity_key request =
  String.concat "\n"
    [
      request.id;
      request.requester;
      request.topic;
      request.reason;
    ]

let task_seed ~requester ~topic ~reason () =
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
      @ [
          "";
          "Execution contract:";
          "- This is a MASC task seed, not a direct child-agent spawn.";
          "- Promote by creating/assigning a task or routing to an existing keeper.";
          "- Do not invoke generic OAS swarm orchestration from this artifact.";
        ])
  in
  let tags =
    [ "keeper_delegation"; "propose_spawn"; "requester:" ^ requester ]
  in
  { title; description; tags }

let make ~requester ~topic ~reason () =
  let requester =
    match compact_whitespace requester with
    | "" -> "unknown"
    | text -> text
  in
  let topic = compact_whitespace topic in
  let reason = compact_whitespace reason in
  let source_action =
    deliberation_action_to_string (ProposeSpawn { topic; reason })
  in
  {
    id = digest_id ~requester ~topic ~reason ();
    requester;
    topic;
    reason;
    source_action;
    promotion_state = Candidate;
    task_seed = task_seed ~requester ~topic ~reason ();
  }

let rec of_action ~requester = function
  | ProposeSpawn { topic; reason } ->
      [ make ~requester ~topic ~reason () ]
  | MultiStep actions ->
      List.concat_map (of_action ~requester) actions
  | Noop _ | BoardPost _ | BoardComment _ | BoardVote _ | TaskClaim _
  | TaskCreate _ | Broadcast _ ->
      []


let of_execution_result ~requester result =
  of_action ~requester result.selected_action

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
      ("source_action", `String request.source_action);
      ( "promotion_state",
        `String (promotion_state_to_string request.promotion_state) );
      ("task_seed", task_seed_to_json request.task_seed);
    ]

let delegation_request_json ~requester = function
  | Some execution ->
      let requests = of_execution_result ~requester execution in
      `List (List.map to_json requests)
  | None -> `List []

let delegation_request_field ~requester execution =
  ("delegation_request", delegation_request_json ~requester execution)
