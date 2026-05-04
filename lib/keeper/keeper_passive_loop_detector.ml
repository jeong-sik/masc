(** Keeper_passive_loop_detector — detect keepers stuck in passive-read loops.

    A "passive loop" is N consecutive turns where the LLM only called
    read-only / status tools ([Passive_status] class in
    [Keeper_tool_disclosure]) without any execution or completion action.
    This is the proactive-turn equivalent of the stay-silent loop: the
    keeper is cycling but making no progress on its owned task.

    Detection triggers a [metric_keeper_passive_loop_detected_total]
    Prometheus counter (latched per episode, resets on any
    [Execution] or [Completion] turn) and a structured WARN log.

    @since #12799 *)

let default_threshold = 5
(** Number of consecutive passive turns before declaring a loop. *)

let threshold () =
  max 2
    (match Sys.getenv_opt "MASC_KEEPER_PASSIVE_LOOP_THRESHOLD" with
     | None -> default_threshold
     | Some s ->
         match int_of_string_opt (String.trim s) with
         | Some n when n > 0 -> n
         | _ -> default_threshold)

type keeper_state = {
  mutable streak : int;
  mutable detected_latched : bool;
  (* Task-138: Unix timestamp of the most recent productive turn
     (execution/completion class). 0.0 until the keeper has produced
     anything in this process. *)
  mutable last_productive_ts : float;
}

let state : (string, keeper_state) Hashtbl.t = Hashtbl.create 16

let mutex = Eio.Mutex.create ()

let with_lock f =
  Eio.Mutex.use_rw ~protect:true mutex f

let get_or_create keeper_name =
  match Hashtbl.find_opt state keeper_name with
  | Some s -> s
  | None ->
      let s = { streak = 0; detected_latched = false;
                last_productive_ts = 0.0 } in
      Hashtbl.replace state keeper_name s;
      s

(* Task-138: streak gauge — pairs with the counter so dashboards see
   the climb before the latch fires (counter only triggers once per
   episode at threshold). *)
let update_streak_gauge keeper_name value =
  Prometheus.set_gauge
    Prometheus.metric_keeper_consecutive_idle
    ~labels:[("keeper", keeper_name)]
    (float_of_int value)

(* Task-138: timestamp of the most recent productive turn.  Operators
   plot [time() - keeper_last_productive_ts > N] as a single PromQL
   alert per keeper. *)
let update_last_productive_gauge keeper_name ts =
  Prometheus.set_gauge
    Prometheus.metric_keeper_last_productive_ts
    ~labels:[("keeper", keeper_name)]
    ts

(** [record_turn ~keeper_name ~progress_class] updates the passive streak
    counter for [keeper_name] based on the [tool_progress_class] of the
    turn that just completed.  Pass the string representation
    ([passive_status | claim_context | execution | completion]). *)
let record_turn ~keeper_name ~progress_class =
  with_lock (fun () ->
    let s = get_or_create keeper_name in
    match progress_class with
    | "passive_status" | "claim_context" ->
        s.streak <- s.streak + 1;
        update_streak_gauge keeper_name s.streak;
        let t = threshold () in
        if s.streak >= t && not s.detected_latched then begin
          s.detected_latched <- true;
          Prometheus.inc_counter
            Prometheus.metric_keeper_passive_loop_detected_total
            ~labels:[("keeper", keeper_name)] ();
          Log.Keeper.warn
            "PASSIVE_LOOP: keeper=%s streak=%d threshold=%d \
             — keeper is completing turns with only read-only/status tools. \
             Check task assignment, persona contract, or cascade proactive \
             setting.  Counter latched; will not re-fire until an \
             execution/completion turn resets the streak."
            keeper_name s.streak t
        end
    | _ ->
        (* Execution or Completion: reset streak *)
        if s.streak > 0 then
          update_streak_gauge keeper_name 0;
        s.streak <- 0;
        s.detected_latched <- false;
        (* Task-138: record productive turn timestamp + gauge.
           Both internal field and external metric stay in sync so a
           later [last_productive_ts] read returns the same value the
           dashboard sees. *)
        let now = Unix.time () in
        s.last_productive_ts <- now;
        update_last_productive_gauge keeper_name now)

let current_streak ~keeper_name =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper_name with
    | Some s -> s.streak
    | None -> 0)

let nudge_message_text ~streak =
  Printf.sprintf
    ("ACTION REQUIRED — PASSIVE LOOP DETECTED: You have completed %d"
     ^^ " consecutive turns using only read-only or status tools without any"
     ^^ " execution or completion action. This violates the keeper turn"
     ^^ " contract. You MUST call an execution or completion tool this turn"
     ^^ " (e.g. keeper_task_done, keeper_task_claim, keeper_shell,"
     ^^ " keeper_board_post with a concrete update, or another write tool)."
     ^^ " Do not call read-only tools again without first taking an action.")
    streak

let nudge_message ~keeper_name =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper_name with
    | Some s when s.detected_latched ->
        Some (nudge_message_text ~streak:s.streak)
    | _ -> None)

let reset ~keeper_name =
  with_lock (fun () ->
    Hashtbl.remove state keeper_name;
    update_streak_gauge keeper_name 0;
    (* Task-138: also zero the productive-ts gauge so a recycled keeper
       slot does not appear "alive but never produced" with the
       previous keeper's timestamp. *)
    update_last_productive_gauge keeper_name 0.0)

let reset_all_for_test () =
  with_lock (fun () -> Hashtbl.clear state)
