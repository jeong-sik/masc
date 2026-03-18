(** Vote tools - Consensus voting system.

    Provides both MASC dispatch convention and OAS [Tool.t] interface.
    OAS tools are created via {!Tool_bridge.oas_tool_of_masc}. *)

open Tool_args

(* Context required by vote tools *)
type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

(* Individual handlers *)
let handle_vote_create ctx args =
  let proposer = get_string args "proposer" ctx.agent_name in
  let topic = get_string args "topic" "" in
  let options = get_string_list args "options" in
  let required_votes = get_int args "required_votes" 2 in
  (true, Room.vote_create ctx.config ~proposer ~topic ~options ~required_votes)

let handle_vote_cast ctx args =
  let vote_id = get_string args "vote_id" "" in
  let choice = get_string args "choice" "" in
  (true, Room.vote_cast ctx.config ~agent_name:ctx.agent_name ~vote_id ~choice)

let handle_vote_status ctx args =
  let vote_id = get_string args "vote_id" "" in
  let json = Room.vote_status ctx.config ~vote_id in
  (true, Yojson.Safe.pretty_to_string json)

let handle_votes ctx _args =
  let json = Room.list_votes ctx.config in
  (true, Yojson.Safe.pretty_to_string json)

(* Dispatch function - returns None if tool not handled *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_vote_create" -> Some (handle_vote_create ctx args)
  | "masc_vote_cast" -> Some (handle_vote_cast ctx args)
  | "masc_vote_status" -> Some (handle_vote_status ctx args)
  | "masc_votes" -> Some (handle_votes ctx args)
  | _ -> None

(** {1 OAS Tool.t Interface}

    Creates OAS [Agent_sdk.Tool.t] list from vote handlers.
    Context is captured via closure at creation time. *)

let[@warning "-32"] oas_tools (ctx : context) : Agent_sdk.Tool.t list =
  let mk = Tool_bridge.oas_tool_of_masc in
  [
    mk ~name:"masc_vote_create"
      ~description:"Create a vote for multi-agent consensus on a decision."
      ~input_schema:(`Assoc [
        ("type", `String "object");
        ("properties", `Assoc [
          ("proposer", `Assoc [("type", `String "string"); ("description", `String "Your agent name")]);
          ("topic", `Assoc [("type", `String "string"); ("description", `String "What to vote on")]);
          ("options", `Assoc [("type", `String "array"); ("items", `Assoc [("type", `String "string")]); ("description", `String "Vote options")]);
          ("required_votes", `Assoc [("type", `String "integer"); ("description", `String "Votes needed to resolve"); ("default", `Int 2)]);
        ]);
        ("required", `List [`String "proposer"; `String "topic"; `String "options"]);
      ])
      (fun args -> handle_vote_create ctx args);

    mk ~name:"masc_vote_cast"
      ~description:"Cast your vote on an active proposal."
      ~input_schema:(`Assoc [
        ("type", `String "object");
        ("properties", `Assoc [
          ("vote_id", `Assoc [("type", `String "string"); ("description", `String "Vote ID")]);
          ("choice", `Assoc [("type", `String "string"); ("description", `String "Your choice")]);
        ]);
        ("required", `List [`String "vote_id"; `String "choice"]);
      ])
      (fun args -> handle_vote_cast ctx args);

    mk ~name:"masc_vote_status"
      ~description:"Get the current tally and result of a specific vote."
      ~input_schema:(`Assoc [
        ("type", `String "object");
        ("properties", `Assoc [
          ("vote_id", `Assoc [("type", `String "string"); ("description", `String "Vote ID")]);
        ]);
        ("required", `List [`String "vote_id"]);
      ])
      (fun args -> handle_vote_status ctx args);

    mk ~name:"masc_votes"
      ~description:"List all votes in the current room."
      ~input_schema:(`Assoc [
        ("type", `String "object");
        ("properties", `Assoc []);
      ])
      (fun args -> handle_votes ctx args);
  ]

let schemas : Types.tool_schema list = [
  (* masc_vote_create *)
  {
    name = "masc_vote_create";
    description = "Create a vote for multi-agent consensus on a decision (approach, PR approval, architecture). \
Use when 2+ agents need to agree before proceeding. All active agents can participate. \
Pair with masc_vote_cast to collect votes and masc_vote_status to check the result.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("proposer", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name (vote creator)");
        ]);
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "What are we voting on? (e.g., 'Approach for API refactoring')");
        ]);
        ("options", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Vote options (e.g., ['Option A: REST', 'Option B: GraphQL'])");
        ]);
        ("required_votes", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of votes needed to resolve (usually 2 or 3)");
          ("default", `Int 2);
        ]);
      ]);
      ("required", `List [`String "proposer"; `String "topic"; `String "options"]);
    ];
  };

  (* masc_vote_cast *)
  {
    name = "masc_vote_cast";
    description = "Cast your vote on an active proposal. Choice must match one of the options exactly. \
Call when you receive a vote notification or see an open vote in masc_votes. \
After masc_vote_create; check masc_vote_status to see if quorum is reached.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("vote_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Vote ID from masc_vote_create");
        ]);
        ("choice", `Assoc [
          ("type", `String "string");
          ("description", `String "Your choice (must match an option exactly)");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "vote_id"; `String "choice"]);
    ];
  };

  (* masc_vote_status *)
  {
    name = "masc_vote_status";
    description = "Get the current tally and result of a specific vote. \
Use when you want to check if quorum has been reached or see who voted for what. \
After masc_vote_create or masc_vote_cast; pair with masc_votes to list all votes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("vote_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Vote ID to check");
        ]);
      ]);
      ("required", `List [`String "vote_id"]);
    ];
  };

  (* masc_votes *)
  {
    name = "masc_votes";
    description = "List all votes in the room (active and resolved) with their tallies and status. \
Use when you want an overview of pending decisions or past consensus outcomes. \
Pair with masc_vote_cast to participate or masc_vote_create to start a new vote.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

]
