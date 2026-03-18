type phase =
  | Lobby
  | Briefing
  | Round
  | Resolution
  | Ended

type dm_control =
  | Keeper
  | Human

type actor_role =
  | Dm
  | Player
  | Npc

type actor = {
  actor_id : string;
  role : actor_role;
  keeper_name : string option;
}

type room_state = {
  room_id : string;
  scenario_id : string;
  phase : phase;
  dm_control : dm_control;
  round : int;
  turn_order : string list;
  current_turn_index : int option;
}

val string_of_phase : phase -> string
val phase_of_string : string -> (phase, string) result

val string_of_dm_control : dm_control -> string
val dm_control_of_string : string -> (dm_control, string) result

val initial_room_state :
  room_id:string ->
  scenario_id:string ->
  dm_control:dm_control ->
  turn_order:string list ->
  room_state

val room_state_to_yojson : room_state -> Yojson.Safe.t
val room_state_of_yojson : Yojson.Safe.t -> (room_state, string) result
