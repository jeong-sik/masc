open Keeper_registry_types

type attempt_state = Keeper_registry_types.turn_attempt_state

type start_observation =
  | Fresh
  | Reattempt of
      { previous_attempts : int
      ; first_started_at : float
      }
  | Regression of { previous_turn_id : int }

let classify_and_update ~now ~turn_id (previous_state : attempt_state option) =
  match previous_state with
  | None -> Some { turn_id; attempts = 1; first_started_at = now }, Fresh
  | Some previous when previous.turn_id < turn_id ->
    Some { turn_id; attempts = 1; first_started_at = now }, Fresh
  | Some previous when previous.turn_id = turn_id ->
    ( Some { previous with attempts = previous.attempts + 1 }
    , Reattempt
        { previous_attempts = previous.attempts
        ; first_started_at = previous.first_started_at
        } )
  | Some previous ->
    ( Some { turn_id; attempts = 1; first_started_at = now }
    , Regression { previous_turn_id = previous.turn_id } )
;;

let with_registered_entry ~base_path ~keeper f =
  match Keeper_registry.get ~base_path keeper with
  | None -> None
  | Some entry -> Some (f entry)
;;

let update_state ~base_path ~keeper f =
  with_registered_entry ~base_path ~keeper (fun entry ->
    let rec loop () =
      let previous = Atomic.get entry.turn_attempt_state in
      let next, observation = f previous in
      if Atomic.compare_and_set entry.turn_attempt_state previous next
      then observation
      else loop ()
    in
    loop ())
;;

let record_metrics ~keeper observation =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string TurnStarts)
    ~labels:[ "keeper", keeper ]
    ();
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string TurnScheduled)
    ~labels:[ "keeper", keeper ]
    ();
  (match observation with
   | Fresh -> ()
   | Reattempt _ ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string TurnReattempts)
       ~labels:[ "keeper", keeper ]
       ()
   | Regression _ ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string TurnRegressions)
       ~labels:[ "keeper", keeper ]
       ());
  observation
;;

let record_turn_start ~base_path ~keeper ~turn_id =
  let observation =
    match
      update_state ~base_path ~keeper (classify_and_update ~now:(Time_compat.now ()) ~turn_id)
    with
    | Some observation -> observation
    | None -> Fresh
  in
  record_metrics ~keeper observation
;;

let current_state ~base_path ~keeper =
  with_registered_entry ~base_path ~keeper (fun entry ->
    Atomic.get entry.turn_attempt_state)
  |> Option.join
;;

let reset_keeper ~base_path ~keeper =
  match Keeper_registry.get ~base_path keeper with
  | Some entry -> Atomic.set entry.turn_attempt_state None
  | None -> ()
;;

let reset_for_tests () =
  List.iter
    (fun entry -> Atomic.set entry.turn_attempt_state None)
    (Keeper_registry.all ())
;;
