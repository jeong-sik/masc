(** Typed broadcast tool — Phase 1 PoC for Typed_tool_masc. *)

type broadcast_input = {
  message : string;
  format : string option;
}

type broadcast_output = {
  delivered : bool;
  room_message : string;
  mention : string option;
}

let parse_broadcast (json : Yojson.Safe.t) : (broadcast_input, string) result =
  let open Yojson.Safe.Util in
  try
    let message = json |> member "message" |> to_string in
    let format = try
      match json |> member "format" with
      | `Null -> None
      | v -> Some (to_string v)
    with _ -> None in
    Ok { message; format }
  with
  | Yojson.Safe.Util.Type_error (msg, _) -> Error msg
  | Not_found -> Error "missing required field: message"

let encode_broadcast (output : broadcast_output) : Yojson.Safe.t =
  `Assoc ([
    ("delivered", `Bool output.delivered);
    ("room_message", `String output.room_message);
  ] @ match output.mention with
    | Some m -> [("mention", `String m)]
    | None -> [])

let broadcast_params : Agent_sdk.Types.tool_param list = [
  { name = "message";
    description = "Message content to broadcast to all agents";
    param_type = Agent_sdk.Types.String;
    required = true };
  { name = "format";
    description = "Output format: compact or verbose (default: verbose)";
    param_type = Agent_sdk.Types.String;
    required = false };
]

let handle_broadcast (input : broadcast_input) : (broadcast_output, string) result =
  let trimmed = String.trim input.message in
  if trimmed = "" then Error "Broadcast message cannot be empty"
  else
    let mention = Mention.extract trimmed in
    Ok {
      delivered = true;
      room_message = trimmed;
      mention;
    }

let tool = Typed_tool_masc.create
  ~name:"masc_broadcast_typed"
  ~description:"[Typed PoC] Send a message visible to ALL agents via SSE push."
  ~module_tag:Tool_dispatch.Mod_room
  ~params:broadcast_params
  ~parse:parse_broadcast
  ~handler:handle_broadcast
  ~encode:encode_broadcast
  ~requires_join:true
  ()
