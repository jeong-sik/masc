open Trpg_engine_types

type transition_error =
  | Invalid_phase_transition of {
      from_phase : phase;
      to_phase : phase;
    }
  | Not_in_round_phase of phase
  | Empty_turn_order

let can_transition ~from_phase ~to_phase =
  match (from_phase, to_phase) with
  | Lobby, Briefing -> true
  | Briefing, Round -> true
  | Round, Resolution -> true
  | Resolution, Ended -> true
  | _ -> false

let transition_phase state to_phase =
  if can_transition ~from_phase:state.phase ~to_phase then
    Ok { state with phase = to_phase }
  else
    Error (Invalid_phase_transition { from_phase = state.phase; to_phase })

let current_turn_actor state =
  match state.current_turn_index with
  | None -> None
  | Some idx -> List.nth_opt state.turn_order idx

let next_turn state =
  match state.phase with
  | Round ->
      let order = state.turn_order in
      let size = List.length order in
      if size = 0 then Error Empty_turn_order
      else
        let next_idx, next_round =
          match state.current_turn_index with
          | None -> (0, state.round)
          | Some idx ->
              let candidate = idx + 1 in
              if candidate >= size then (0, state.round + 1)
              else (candidate, state.round)
        in
        Ok
          {
            state with
            current_turn_index = Some next_idx;
            round = next_round;
          }
  | p -> Error (Not_in_round_phase p)

let string_of_transition_error = function
  | Invalid_phase_transition { from_phase; to_phase } ->
      Printf.sprintf
        "invalid phase transition: %s -> %s"
        (string_of_phase from_phase)
        (string_of_phase to_phase)
  | Not_in_round_phase phase ->
      Printf.sprintf
        "next_turn is only available in round phase (current: %s)"
        (string_of_phase phase)
  | Empty_turn_order -> "turn order is empty"
