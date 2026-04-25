(** Keeper_turn_livelock — observability surface for stuck-turn livelocks.

    #10121 reports 10 (keeper, turn) pairs retrying 4-12× over 4+ hours
    because the FSM has no max-attempts guard or stuck-turn detector.
    The root cause trigger is a [write_meta] CAS race (#9733) that
    silently drops the in-memory turn-counter increment, but the
    defense-in-depth gap is observability: nothing surfaces "this
    keeper has tried turn 91 twelve times" until an operator greps
    log lines.

    Per-keeper in-memory state tracks the most recent turn id seen and
    the attempt count for that id.  When the same id starts again we emit
    a re-attempt counter.  When the id moves strictly backwards we emit a
    regression counter (rare; indicative of the write_meta race).  When
    the id advances normally we reset the per-keeper bookkeeping.  The
    guarded entrypoint enforces a per-turn retry/age budget before the
    dispatcher marks the turn live.

    State is process-local: a server restart resets the counters,
    which is intentional — the issue's fleet-wide signal comes from
    in-process retry storms, not cross-restart divergence. *)

type attempt_state = {
  turn_id : int;
  attempts : int;
  first_started_at : float;
}

let mu = Stdlib.Mutex.create ()
let state : (string, attempt_state) Hashtbl.t = Hashtbl.create 16

(** Reset for tests so each test starts clean.  Public so the test
    harness can call it without poking at internals. *)
let reset_for_tests () =
  Stdlib.Mutex.lock mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock mu)
    (fun () -> Hashtbl.clear state)

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
  Prometheus.inc_counter
    Prometheus.metric_keeper_turn_starts
    ~labels:[ ("keeper", keeper) ] ();
  (match outcome with
   | Fresh -> ()
   | Reattempt _ ->
     Prometheus.inc_counter
       Prometheus.metric_keeper_turn_reattempts
       ~labels:[ ("keeper", keeper) ] ()
   | Regression _ ->
     Prometheus.inc_counter
       Prometheus.metric_keeper_turn_regressions
       ~labels:[ ("keeper", keeper) ] ());
  outcome

let gate_reason_kind = function
  | Attempts_exhausted _ -> "attempts_exhausted"
  | Stuck_age_exceeded _ -> "stuck_age_exceeded"

let gate_reason_to_string = function
  | Attempts_exhausted { attempts; max_attempts; _ } ->
      Printf.sprintf "attempts_exhausted attempts=%d max_attempts=%d"
        attempts max_attempts
  | Stuck_age_exceeded { attempts; age_sec; threshold_sec; _ } ->
      Printf.sprintf
        "stuck_age_exceeded attempts=%d age_sec=%.1f threshold_sec=%.1f"
        attempts age_sec threshold_sec

let classify_and_update_start ~now ~(keeper : string) ~(turn_id : int)
    : start_outcome =
  match Hashtbl.find_opt state keeper with
  | None ->
    Hashtbl.replace state keeper
      { turn_id; attempts = 1; first_started_at = now };
    Fresh
  | Some prev when prev.turn_id < turn_id ->
    Hashtbl.replace state keeper
      { turn_id; attempts = 1; first_started_at = now };
    Fresh
  | Some prev when prev.turn_id = turn_id ->
    let attempts = prev.attempts + 1 in
    Hashtbl.replace state keeper { prev with attempts };
    Reattempt
      { previous_attempts = prev.attempts;
        first_started_at = prev.first_started_at }
  | Some prev (* prev.turn_id > turn_id *) ->
    (* Strictly backwards.  Reset bookkeeping so the next start
       at this lower id counts as Fresh, not Reattempt. *)
    Hashtbl.replace state keeper
      { turn_id; attempts = 1; first_started_at = now };
    Regression { previous_turn_id = prev.turn_id }

let record_turn_start ~(keeper : string) ~(turn_id : int) : start_outcome =
  let outcome =
    Stdlib.Mutex.lock mu;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock mu)
      (fun () ->
        classify_and_update_start ~now:(now_unix ()) ~keeper ~turn_id)
  in
  (* Counter emissions outside the lock — Prometheus calls allocate
     and can recurse; minimise critical-section scope. *)
  record_started_metrics ~keeper outcome

let guard_and_record_turn_start ?(now = now_unix) ~(keeper : string)
    ~(turn_id : int) ~(max_attempts : int) ~(stuck_after_sec : float) () :
    guarded_start_outcome =
  let max_attempts = Int.max 1 max_attempts in
  let stuck_after_sec = Float.max 0.0 stuck_after_sec in
  let now_value = now () in
  let outcome =
    Stdlib.Mutex.lock mu;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock mu)
      (fun () ->
        match Hashtbl.find_opt state keeper with
        | Some prev when prev.turn_id = turn_id ->
          let age_sec = now_value -. prev.first_started_at in
          if prev.attempts >= max_attempts then
            Blocked
              (Attempts_exhausted
                 { attempts = prev.attempts;
                   max_attempts;
                   first_started_at = prev.first_started_at })
          else if age_sec >= stuck_after_sec then
            Blocked
              (Stuck_age_exceeded
                 { attempts = prev.attempts;
                   age_sec;
                   threshold_sec = stuck_after_sec;
                   first_started_at = prev.first_started_at })
          else
            Started
              (classify_and_update_start ~now:now_value ~keeper ~turn_id)
        | _ ->
          Started (classify_and_update_start ~now:now_value ~keeper ~turn_id))
  in
  (match outcome with
   | Started started -> ignore (record_started_metrics ~keeper started)
   | Blocked reason ->
     Prometheus.inc_counter
       Prometheus.metric_keeper_turn_livelock_blocks
       ~labels:[ ("keeper", keeper); ("reason", gate_reason_kind reason) ] ());
  outcome

(** Read current attempt state for [keeper] without modifying it.
    Useful for diagnostics and future gating logic that wants to
    decide BEFORE incrementing. *)
let current_state ~(keeper : string) : attempt_state option =
  Stdlib.Mutex.lock mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock mu)
    (fun () -> Hashtbl.find_opt state keeper)

(** [seconds_since_first_attempt ~keeper] returns the age of the
    current turn's FIRST attempt for [keeper], or [None] if no state
    exists.  Pure read. *)
let seconds_since_first_attempt ~(keeper : string) : float option =
  current_state ~keeper
  |> Option.map (fun s -> now_unix () -. s.first_started_at)
