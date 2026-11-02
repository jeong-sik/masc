type freshness =
  | Current_generation
  | Invalidated_during_refresh of float

type 'completion worker =
  { id : int
  ; started_at : float
  ; completion : 'completion
  ; freshness : freshness
  ; was_requested : bool
  }

type flight =
  | Idle
  | In_flight of float option

type 'completion t =
  { flight : flight
  ; direct_flight : float option
  ; requested : bool
  ; active_worker : 'completion worker option
  ; next_worker_id : int
  ; submissions : int
  ; joins : int
  ; invalidation_generation : int
  }

let empty =
  { flight = Idle
  ; direct_flight = None
  ; requested = false
  ; active_worker = None
  ; next_worker_id = 0
  ; submissions = 0
  ; joins = 0
  ; invalidation_generation = 0
  }

let request state = { state with requested = true }

let begin_direct ~now state =
  { state with
    flight = In_flight (Some now)
  ; direct_flight = Some now
  ; requested = false
  }

let cancel_direct ~was_requested state =
  let flight =
    match state.active_worker with
    | Some worker -> In_flight (Some worker.started_at)
    | None -> Idle
  in
  { state with
    flight
  ; direct_flight = None
  ; requested = state.requested || was_requested
  }

let complete ~refresh_requested state =
  { state with
    flight = Idle
  ; direct_flight = None
  ; requested = refresh_requested
  }

let note_failure ~worker_active state =
  if worker_active then
    let started_at =
      match state.flight with
      | Idle -> None
      | In_flight started_at -> started_at
    in
    { state with flight = In_flight started_at }
  else complete ~refresh_requested:false state

type 'completion start_plan = Start_plan of 'completion t

type 'completion admission =
  | Join of 'completion t * 'completion worker
  | Start of 'completion start_plan

let admit state =
  match state.active_worker with
  | Some worker -> Join ({ state with joins = state.joins + 1 }, worker)
  | None -> Start (Start_plan state)

let start ~now ~completion (Start_plan state) =
  let id = state.next_worker_id + 1 in
  let worker =
    { id
    ; started_at = now
    ; completion
    ; freshness = Current_generation
    ; was_requested = state.requested
    }
  in
  ( { state with
      flight = In_flight (Some now)
    ; requested = false
    ; active_worker = Some worker
    ; next_worker_id = id
    ; submissions = state.submissions + 1
    }
  , worker )

let take_worker ~id state =
  match state.active_worker with
  | Some worker when worker.id = id ->
    Some ({ state with active_worker = None }, worker)
  | Some _ | None -> None

let cancel_worker ~id state =
  match state.active_worker with
  | Some worker when worker.id = id ->
    let dirty =
      match worker.freshness with
      | Current_generation -> false
      | Invalidated_during_refresh _ -> true
    in
    let flight =
      match state.direct_flight with
      | Some direct_started_at -> In_flight (Some direct_started_at)
      | None -> Idle
    in
    let requested = state.requested || worker.was_requested || dirty in
    Some ({ state with flight; requested; active_worker = None }, dirty)
  | Some _ | None -> None

let invalidate ~now state =
  let active_worker =
    Option.map
      (fun worker ->
         match worker.freshness with
         | Current_generation ->
           { worker with freshness = Invalidated_during_refresh now }
         | Invalidated_during_refresh _ -> worker)
      state.active_worker
  in
  { state with
    requested = true
  ; active_worker
  ; invalidation_generation = state.invalidation_generation + 1
  }
