module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Typed broadcast tool — Phase 1 PoC for Typed_tool_masc.
    Derives parse + params from Tool_schema_gen combinators. *)

module Sg = Agent_sdk.Tool_schema_gen

let message_field =
  Sg.string_field "message" ~required:true
    ~desc:"Message content to broadcast to all agents" ()

(* Issue #8595: dropped [format_field]. The schema field was advertised
   to LLM clients but [handle_broadcast] never read it (destructured as
   [_format]). Removing it brings the typed PoC schema in line with the
   production handler and the freshly de-bloated inline schema. *)
let broadcast_schema = Sg.one message_field

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

let handle_broadcast (message : string)
    : (broadcast_output, string) Result.t =
  let trimmed = String.trim message in
  if String.equal trimmed "" then Error "Broadcast message cannot be empty"
  else
    let mention = Mention.extract trimmed in
    Ok { delivered = true; room_message = trimmed; mention }

let parse_broadcast (json : Yojson.Safe.t) =
  match Sg.parse broadcast_schema json with
  | Ok v -> Ok v
  | Error errs ->
      Error
        (Agent_sdk.Tool_input_validation.format_errors
           ~tool_name:"masc_broadcast_typed" errs)

let tool = Typed_tool_masc.create
  ~name:"masc_broadcast_typed"
  ~description:"[Typed PoC] Send a message visible to ALL agents via SSE push."
  ~module_tag:Tool_dispatch.Mod_room
  ~params:(Sg.to_params broadcast_schema)
  ~parse:parse_broadcast
  ~handler:handle_broadcast
  ~encode:encode_broadcast
  ~requires_join:true
  ()
