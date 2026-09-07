type counts = {
  todo : int;
  claimed : int;
  in_progress : int;
  awaiting_verification : int;
  completed : int;
  cancelled : int;
}

type window = { created : int; completed : int; cancelled : int }

type t = {
  observed_at : float;
  window_started_at : float;
  current : counts;
  recent : window;
  oldest_open_created_at : float option;
  unparseable_timestamps : int;
}

let open_count c = c.todo + c.claimed + c.in_progress + c.awaiting_verification
let total_count (c : counts) = open_count c + c.completed + c.cancelled

let of_tasks ~now tasks =
  let window_started_at = now -. (24. *. 60. *. 60.) in
  let empty =
    { observed_at = now; window_started_at;
      current = { todo = 0; claimed = 0; in_progress = 0;
                  awaiting_verification = 0; completed = 0; cancelled = 0 };
      recent = { created = 0; completed = 0; cancelled = 0 };
      oldest_open_created_at = None; unparseable_timestamps = 0 }
  in
  let recent = function
    | Some at -> at >= window_started_at && at <= now
    | None -> false
  in
  let parse state text =
    match Masc_domain.parse_iso8601_opt text with
    | Some at when Float.is_finite at -> state, Some at
    | Some _ | None ->
      { state with unparseable_timestamps = state.unparseable_timestamps + 1 }, None
  in
  List.fold_left
    (fun state (task : Masc_domain.task) ->
      let state, created_at = parse state task.created_at in
      let state =
        if recent created_at then
          { state with recent = { state.recent with created = state.recent.created + 1 } }
        else state
      in
      let count, terminal =
        match task.task_status with
        | Masc_domain.Todo -> { state.current with todo = state.current.todo + 1 }, None
        | Claimed _ -> { state.current with claimed = state.current.claimed + 1 }, None
        | InProgress _ -> { state.current with in_progress = state.current.in_progress + 1 }, None
        | AwaitingVerification _ ->
          { state.current with awaiting_verification = state.current.awaiting_verification + 1 }, None
        | Done { completed_at; _ } ->
          { state.current with completed = state.current.completed + 1 }, Some (`Completed, completed_at)
        | Cancelled { cancelled_at; _ } ->
          { state.current with cancelled = state.current.cancelled + 1 }, Some (`Cancelled, cancelled_at)
      in
      let state = { state with current = count } in
      match terminal with
      | Some (kind, text) ->
        let state, at = parse state text in
        if not (recent at) then state
        else
          let counts = match kind with
            | `Completed -> { state.recent with completed = state.recent.completed + 1 }
            | `Cancelled -> { state.recent with cancelled = state.recent.cancelled + 1 }
          in
          { state with recent = counts }
      | None ->
        let oldest = match state.oldest_open_created_at, created_at with
          | oldest, Some at when at <= now -> Some (Option.fold ~none:at ~some:(Float.min at) oldest)
          | oldest, _ -> oldest
        in
        { state with oldest_open_created_at = oldest })
    empty tasks
