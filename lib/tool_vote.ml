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
