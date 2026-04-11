(** Typed broadcast tool — Phase 1 PoC for Typed_tool_masc.
    Derives parse + params from Tool_schema_gen combinators. *)

module Sg = Agent_sdk.Tool_schema_gen

let broadcast_schema = Sg.two
  (Sg.string_field "message" ~required:true
     ~desc:"Message content to broadcast to all agents" ())
  (Sg.string_field "format" ~required:false
     ~desc:"Output format: compact or verbose (default: verbose)" ())

type broadcast_output = {
  delivered : bool;
  room_message : string;
  mention : string option;
}

let encode_broadcast (output : broadcast_output) : Yojson.Safe.t =
  `Assoc ([
    ("delivered", `Bool output.delivered);
    ("room_message", `String output.room_message);
  ] @ match output.mention with
    | Some m -> [("mention", `String m)]
    | None -> [])

let handle_broadcast ((message, _format) : string * string)
    : (broadcast_output, string) result =
  let trimmed = String.trim message in
  if trimmed = "" then Error "Broadcast message cannot be empty"
  else
    let mention = Mention.extract trimmed in
    Ok { delivered = true; room_message = trimmed; mention }

let tool = Typed_tool_masc.create
  ~name:"masc_broadcast_typed"
  ~description:"[Typed PoC] Send a message visible to ALL agents via SSE push."
  ~module_tag:Tool_dispatch.Mod_room
  ~params:(Sg.to_params broadcast_schema)
  ~parse:(Sg.parse broadcast_schema)
  ~handler:handle_broadcast
  ~encode:encode_broadcast
  ~requires_join:true
  ()
