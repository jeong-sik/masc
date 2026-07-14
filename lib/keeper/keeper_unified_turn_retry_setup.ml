type retry_setup =
  { current_turn_phase_elapsed_ms : float option -> int * int option
  }

let build ~now =
  let turn_started_at = now () in
  let elapsed_ms seconds = int_of_float (Float.max 0.0 seconds *. 1000.0) in
  let current_turn_phase_elapsed_ms retry_phase_started_at =
    let now_s = now () in
    match retry_phase_started_at with
    | None -> elapsed_ms (now_s -. turn_started_at), Some 0
    | Some retry_started_at ->
      ( elapsed_ms (retry_started_at -. turn_started_at)
      , Some (elapsed_ms (now_s -. retry_started_at)) )
  in
  { current_turn_phase_elapsed_ms }
