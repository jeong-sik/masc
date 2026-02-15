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

let string_of_phase = function
  | Lobby -> "lobby"
  | Briefing -> "briefing"
  | Round -> "round"
  | Resolution -> "resolution"
  | Ended -> "end"

let phase_of_string = function
  | "lobby" -> Ok Lobby
  | "briefing" -> Ok Briefing
  | "round" -> Ok Round
  | "resolution" -> Ok Resolution
  | "end" | "ended" -> Ok Ended
  | s -> Error (Printf.sprintf "unknown phase: %s" s)

let string_of_dm_control = function
  | Keeper -> "keeper"
  | Human -> "human"

let dm_control_of_string = function
  | "keeper" -> Ok Keeper
  | "human" -> Ok Human
  | s -> Error (Printf.sprintf "unknown dm_control: %s" s)

let initial_room_state ~room_id ~scenario_id ~dm_control ~turn_order =
  {
    room_id;
    scenario_id;
    phase = Lobby;
    dm_control;
    round = 1;
    turn_order;
    current_turn_index = None;
  }
