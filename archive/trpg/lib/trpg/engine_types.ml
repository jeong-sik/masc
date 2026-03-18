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
  | "discussion" -> Ok Round
  | "discuss" -> Ok Round
  | "action" -> Ok Round
  | "dice" -> Ok Round
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

let room_state_to_yojson (s : room_state) : Yojson.Safe.t =
  `Assoc
    [
      ("room_id", `String s.room_id);
      ("scenario_id", `String s.scenario_id);
      ("phase", `String (string_of_phase s.phase));
      ("dm_control", `String (string_of_dm_control s.dm_control));
      ("round", `Int s.round);
      ("turn_order", `List (List.map (fun x -> `String x) s.turn_order));
      ( "current_turn_index",
        match s.current_turn_index with Some i -> `Int i | None -> `Null );
    ]

let room_state_of_yojson (json : Yojson.Safe.t) : (room_state, string) result =
  let module U = Yojson.Safe.Util in
  try
    let room_id = json |> U.member "room_id" |> U.to_string in
    let scenario_id = json |> U.member "scenario_id" |> U.to_string in
    let phase_s = json |> U.member "phase" |> U.to_string in
    let dm_control_s = json |> U.member "dm_control" |> U.to_string in
    let round = json |> U.member "round" |> U.to_int in
    let turn_order = json |> U.member "turn_order" |> U.to_list |> List.map U.to_string in
    let current_turn_index = json |> U.member "current_turn_index" |> U.to_int_option in
    match phase_of_string phase_s, dm_control_of_string dm_control_s with
    | Ok phase, Ok dm_control ->
        Ok
          {
            room_id;
            scenario_id;
            phase;
            dm_control;
            round;
            turn_order;
            current_turn_index;
          }
    | Error e, _ | _, Error e -> Error e
  with e -> Error (Printexc.to_string e)
