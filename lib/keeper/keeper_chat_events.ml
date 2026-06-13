type role = User | Assistant

type keeper_chat_event =
  | Run_started of { run_id : string; thread_id : string }
  | Text_message_start of { message_id : string; role : role }
  | Text_delta of string
  | Text_message_end
  | Run_finished of { run_id : string }
  | Event_error of { message : string }
  | Custom of { name : string; value : Yojson.Safe.t }
  | Tool_call_start of { tool_call_id : string; tool_call_name : string }
  | Tool_call_args of { tool_call_id : string; delta : string }
  | Tool_call_end of { tool_call_id : string }

let create () = Eio.Stream.create 512

let publish stream event = Eio.Stream.add stream event

let subscribe stream = Eio.Stream.take stream
