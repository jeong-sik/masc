(** One explicit snapshot of the server inbox; never a claim of delivery. *)
type action = Inspect | Pause | Resume | Cancel of string | Move_to_end of string | Edit of string * string
  | Cancel_event of string * int64 * string
  | Prioritize_event of string * int64 * Keeper_event_queue.urgency
val parse : string -> (action, string) result
val waiting_lines : Yojson.Safe.t -> (string list, string) result
val operation_lines : Yojson.Safe.t -> (string list, string) result
val edited_input : message:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
val next_sequence : Yojson.Safe.t -> (string option, string) result
