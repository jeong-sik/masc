type origin = {
  guild_id : string option;
  channel_id : string;
  original_message_id : string;
}

type target = { keeper : string; chat_id : string; origin : origin }

type refusal = Binding_changed | Discord_unconfigured | Discord_rejected
type state = Sending | Delivered of string | Refused of refusal | Outcome_unknown

type request =
  | Send of { target : target; operation_id : string; content : string }
  | Status of { target : target; operation_id : string }

val decode_origin : message:Yojson.Safe.t -> surface:Yojson.Safe.t -> origin option
(** Returns a target only for a recorded external Discord user row with an
    exact source message and coherent channel/thread coordinates. *)

val equal_target : target -> target -> bool
val path : request -> string
val identity : request -> target * string
val encode : workspace:Wire_work.expected_workspace -> request -> Yojson.Safe.t
val decode : request -> Yojson.Safe.t -> (state, string) result
(** Rejects a receipt that names any other operation, Keeper, row, or origin. *)
