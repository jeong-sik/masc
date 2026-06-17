(** Keeper_turn_livelock — observability surface for stuck-turn livelocks.

    #10121 reports 10 (keeper, turn) pairs retrying 4-12× over 4+ hours
    because the FSM has no max-attempts guard or stuck-turn detector.
    The root cause trigger is a [write_meta] CAS race (#9733) that
    silently drops the in-memory turn-counter increment, but the
    defense-in-depth gap is observability: nothing surfaces "this
    keeper has tried turn 91 twelve times" until an operator greps
    log lines.

    Per-keeper state is stored in the registry entry
    ([Keeper_registry_types.livelock_attempt_state option Atomic.t])
    and updated via CAS on that per-entry atomic so a keeper's retry
    history is part of the SSOT.  The previous separate [Hashtbl] +
    [Eio.Mutex.t] has been removed. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_registry_types

type attempt_state = Keeper_registry_types.livelock_attempt_state

(** [start_outcome] records what happened on a [record_turn_start]
    call.  Returned so callers (tests, future gating logic) don't
    have to re-derive the classification from external data. *)
type start_outcome =
  | Fresh
    (** First time we have ever seen this keeper, or the turn id
        advanced from the previous one. *)
  | Reattempt of { previous_attempts : int; first_started_at : float }
    (** The same turn id is being started again.  [previous_attempts]
        is the count BEFORE this start (so the new attempt count is
        [previous_attempts + 1]).  [first_started_at] lets a future
        gate compute "stuck for X minutes". *)
  | Regression of { previous_turn_id : int }
    (** The turn id strictly decreased — usually a write_meta race
        losing an in-memory increment (#9733). *)

type gate_reason =
  | Attempts_exhausted of {
      attempts : int;
      max_attempts : int;
      first_started_at : float;
    }
  | Stuck_age_exceeded of {
      attempts : int;
      age_sec : float;
      threshold_sec : float;
      first_started_at : float;
    }

type guarded_start_outcome =
  | Started of start_outcome
  | Blocked of gate_reason

let now_unix () = Time_compat.now ()

let record_started_metrics ~keeper outcome =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string TurnStarts)
    ~labels:[ ("keeper", keeper) ] ();
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string TurnScheduled)
    ~labels:[ ("keeper", keeper) ] ();
  (match outcome with
   | Fresh -> ()
   | Reattempt _ ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string TurnReattempts)
       ~labels:[ ("keeper", keeper) ] ()
   | Regression _ ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string TurnRegressions)
       ~labels:[ ("keeper", keeper) ] ());
  outcome

let gate_reason_kind = function
  | Attempts_exhausted _ -> "attempts_exhausted"
  | Stuck_age_exceeded _ -> "stuck_age_exceeded"

let gate_reason_to_string = function
  | Attempts_exhausted { attempts; max_attempts; _ } ->
    Printf.sprintf
      "attempts_exhausted attempts=%d max_attempts=%d"
      attempts
      max_attempts
  | Stuck_age_exceeded { attempts; age_sec; threshold_sec; _ } ->
    Printf.sprintf
      "stuck_age_exceeded attempts=%d age_sec=%.1f threshold_sec=%.1f"
      attempts
      age_sec
      threshold_sec

let classify_and_update_start ~now ~(turn_id : int) (prev : attempt_state option)
  : attempt_state option * start_outcome
  =
  match prev with
  | None ->
    Some { turn_id; attempts = 1; first_started_at = now }, Fresh
  | Some p when p.turn_id < turn_id ->
    Some { turn_id; attempts = 1; first_started_at = now }, Fresh
  | Some p when p.turn_id = turn_id ->
    let attempts = p.attempts + 1 in
    ( Some { p with attempts }
    , Reattempt
        { previous_attempts = p.attempts; first_started_at = p.first_started_at } )
  | Some p (* p.turn_id > turn_id *) ->
    (* Strictly backwards.  Reset bookkeeping so the next start
       at this lower id counts as Fresh, not Reattempt. *)
    ( Some { turn_id; attempts = 1; first_started_at = now }
    , Regression { previous_turn_id = p.turn_id } )

let with_registered_entry ~base_path ~keeper f =
  match Keeper_registry.get ~base_path keeper with
  | None -> None
  | Some entry -> Some (f entry)

(** Read the current livelock state for [keeper] without modifying it. *)
let current_state_opt ~base_path ~keeper : attempt_state option =
  with_registered_entry ~base_path ~keeper (fun entry ->
    Atomic.get entry.livelock_state)
  |> Option.join

(** Apply [f] to the current livelock state of a registered keeper and
    write back the result via CAS on the per-entry atomic.  Returns
    [Some result] when the keeper is registered, [None] otherwise. *)
let update_state ~base_path ~keeper f =
  with_registered_entry ~base_path ~keeper (fun entry ->
    let rec loop () =
      let old_state = Atomic.get entry.livelock_state in
      let new_state, result = f old_state in
      if Atomic.compare_and_set entry.livelock_state old_state new_state
      then result
      else loop ()
    in
    loop ())

let record_turn_start ~base_path ~keeper ~turn_id : start_outcome =
  let outcome =
    match
      update_state ~base_path ~keeper (fun prev ->
        classify_and_update_start ~now:(now_unix ()) ~turn_id prev)
    with
    | Some outcome -> outcome
    | None -> Fresh
  in
  record_started_metrics ~keeper outcome

let guard_and_record_turn_start
      ?(now = now_unix)
      ~base_path
      ~keeper
      ~turn_id
      ~max_attempts
      ~stuck_after_sec
      ()
  : guarded_start_outcome
  =
  let max_attempts = Int.max 1 max_attempts in
  let stuck_after_sec = Float.max 0.0 stuck_after_sec in
  let now_value = now () in
  let outcome =
    match
      update_state ~base_path ~keeper (fun current ->
        match current with
        | Some prev when prev.turn_id = turn_id ->
          let age_sec = now_value -. prev.first_started_at in
          if prev.attempts >= max_attempts
          then (
            current
            , Blocked
                (Attempts_exhausted
                   { attempts = prev.attempts
                   ; max_attempts
                   ; first_started_at = prev.first_started_at }))
          else if age_sec >= stuck_after_sec
          then (
            current
            , Blocked
                (Stuck_age_exceeded
                   { attempts = prev.attempts
                   ; age_sec
                   ; threshold_sec = stuck_after_sec
                   ; first_started_at = prev.first_started_at }))
          else
            let new_state, started =
              classify_and_update_start ~now:now_value ~turn_id current
            in
            new_state, Started started
        | _ ->
          let new_state, started =
            classify_and_update_start ~now:now_value ~turn_id current
          in
          new_state, Started started)
    with
    | Some outcome -> outcome
    | None -> Started Fresh
  in
  (match outcome with
   | Started started -> ignore (record_started_metrics ~keeper started)
   | Blocked reason ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string TurnLivelockBlocks)
       ~labels:[ ("keeper", keeper); ("reason", gate_reason_kind reason) ]
       ());
  outcome

(** Read current attempt state for [keeper] without modifying it.
    Useful for diagnostics and future gating logic that wants to
    decide BEFORE incrementing. *)
let current_state ~base_path ~keeper : attempt_state option =
  current_state_opt ~base_path ~keeper

(** [seconds_since_first_attempt ~keeper] returns the age of the
    current turn's FIRST attempt for [keeper], or [None] if no state
    exists.  Pure read. *)
let seconds_since_first_attempt ~base_path ~keeper : float option =
  current_state_opt ~base_path ~keeper
  |> Option.map (fun s -> now_unix () -. s.first_started_at)

(** Reset for tests so each test starts clean.  Public so the test
    harness can call it without poking at internals. *)
let reset_for_tests () =
  List.iter
    (fun entry -> Atomic.set entry.livelock_state None)
    (Keeper_registry.all ())

(** Remove the attempt state for a single keeper.  Called by the
    supervisor when a keeper fiber is cleaned up after a crash so
    that the next restart begins with a fresh counter rather than
    inheriting the previous stuck turn's exhaustion. *)
let reset_keeper_livelock ~base_path ~keeper : unit =
  match Keeper_registry.get ~base_path keeper with
  | Some entry -> Atomic.set entry.livelock_state None
  | None -> ()
