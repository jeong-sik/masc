type role = User | Assistant

type keeper_chat_event =
  | Run_started of { run_id : string; thread_id : string }
  | Text_message_start of { message_id : string; role : role }
  | Text_delta of string
  | Text_message_end
  | Run_finished of { run_id : string }
  | Error of { message : string }
  | Custom of { name : string; value : Yojson.Safe.t }

let create () = Eio.Stream.create 512

let publish stream event = Eio.Stream.add stream event

let subscribe stream = Eio.Stream.take stream
