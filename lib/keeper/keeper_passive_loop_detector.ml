(** Keeper_passive_loop_detector — detect keepers stuck in no-progress loops.

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

let required_tool_failure_threshold = 3
(** Number of consecutive required-tool contract failures before declaring
    a no-tool/no-progress loop (#13362). *)

let threshold () =
  max 2
    (match Sys.getenv_opt "MASC_KEEPER_PASSIVE_LOOP_THRESHOLD" with
     | None -> default_threshold
     | Some s ->
         match int_of_string_opt (String.trim s) with
         | Some n when n > 0 -> n
         | _ -> default_threshold)

let required_tool_no_call_progress_class = "required_tool_no_call"
let required_tool_unsatisfied_progress_class = "required_tool_unsatisfied"

let progress_class_of_terminal_reason_code = function
  | "required_tool_use_no_tool_call" ->
      Some required_tool_no_call_progress_class
  | "required_tool_use_unsatisfied" ->
      Some required_tool_unsatisfied_progress_class
  | _ -> None

type keeper_state = {
  mutable streak : int;
  mutable detected_latched : bool;
  mutable last_progress_class : string option;
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
                last_progress_class = None; last_productive_ts = 0.0 } in
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

let is_required_tool_progress_class = function
  | "required_tool_no_call" | "required_tool_unsatisfied" -> true
  | _ -> false

let increments_streak = function
  | "passive_status" | "claim_context"
  | "required_tool_no_call" | "required_tool_unsatisfied" -> true
  | _ -> false

let same_streak_family a b =
  (is_required_tool_progress_class a && is_required_tool_progress_class b)
  || ((not (is_required_tool_progress_class a))
      && not (is_required_tool_progress_class b))

let threshold_for_progress_class progress_class =
  if is_required_tool_progress_class progress_class
  then required_tool_failure_threshold
  else threshold ()

let detect_counter_for_progress_class progress_class =
  if is_required_tool_progress_class progress_class
  then Prometheus.metric_keeper_required_tool_loop_detected_total
  else Prometheus.metric_keeper_passive_loop_detected_total

let detect_labels_for_progress_class keeper_name progress_class =
  if is_required_tool_progress_class progress_class
  then [("keeper", keeper_name); ("kind", progress_class)]
  else [("keeper", keeper_name)]

let emit_detected_loop_metrics keeper_name progress_class =
  Prometheus.inc_counter
    (detect_counter_for_progress_class progress_class)
    ~labels:(detect_labels_for_progress_class keeper_name progress_class)
    ();
  Prometheus.inc_counter
    Prometheus.metric_keeper_zombie_loop_detected_total
    ~labels:[("keeper_name", keeper_name)]
    ()

let log_detected_loop keeper_name progress_class streak threshold =
  if is_required_tool_progress_class progress_class then
    Log.Keeper.warn
      "REQUIRED_TOOL_LOOP: keeper=%s streak=%d threshold=%d kind=%s \
       — actionable turns are failing the required-tool contract before any \
       execution/completion progress. The next turn will receive a \
       tool-required nudge; inspect provider tool support and active-goal \
       ownership if this repeats."
      keeper_name streak threshold progress_class
  else
    Log.Keeper.warn
      "PASSIVE_LOOP: keeper=%s streak=%d threshold=%d \
       — keeper is completing turns with only read-only/status tools. \
       Check task assignment, persona contract, or cascade proactive \
       setting.  Counter latched; will not re-fire until an \
       execution/completion turn resets the streak."
      keeper_name streak threshold

(** [record_turn ~keeper_name ~progress_class] updates the passive streak
    counter for [keeper_name] based on the [tool_progress_class] of the
    turn that just completed.  Pass the string representation
    ([passive_status | claim_context | execution | completion]). *)
let record_turn ~keeper_name ~progress_class =
  with_lock (fun () ->
    let s = get_or_create keeper_name in
    if increments_streak progress_class then begin
        s.streak <-
          (match s.last_progress_class with
          | Some last when same_streak_family last progress_class -> s.streak + 1
          | _ ->
              s.detected_latched <- false;
              1);
        s.last_progress_class <- Some progress_class;
        update_streak_gauge keeper_name s.streak;
        let t = threshold_for_progress_class progress_class in
        if s.streak >= t && not s.detected_latched then begin
          s.detected_latched <- true;
          emit_detected_loop_metrics keeper_name progress_class;
          log_detected_loop keeper_name progress_class s.streak t
        end
      end
    else begin
        (* Execution or Completion: reset streak *)
        if s.streak > 0 then
          update_streak_gauge keeper_name 0;
        s.streak <- 0;
        s.detected_latched <- false;
        s.last_progress_class <- Some progress_class;
        (* Task-138: record productive turn timestamp + gauge.
           Both internal field and external metric stay in sync so a
           later [last_productive_ts] read returns the same value the
           dashboard sees. *)
        let now = Unix.time () in
        s.last_productive_ts <- now;
        update_last_productive_gauge keeper_name now
      end)

let current_streak ~keeper_name =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper_name with
    | Some s -> s.streak
    | None -> 0)

let nudge_message_text ~streak ~progress_class =
  if is_required_tool_progress_class progress_class then
    Printf.sprintf
      ("ACTION REQUIRED — REQUIRED TOOL LOOP DETECTED: You have failed %d"
       ^^ " consecutive actionable turns without satisfying the required"
       ^^ " keeper-tool contract (%s). This turn MUST emit a real keeper"
       ^^ " tool call that advances the active goal/task, such as"
       ^^ " keeper_shell, keeper_fs_read, keeper_board_post,"
       ^^ " keeper_board_comment, keeper_task_claim, or keeper_task_done."
       ^^ " If no action is actually possible, call keeper_stay_silent only"
       ^^ " with a typed no-work proof instead of returning plain text or"
       ^^ " an empty response.")
      streak progress_class
  else
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
        let progress_class =
          Option.value ~default:"passive_status" s.last_progress_class
        in
        Some (nudge_message_text ~streak:s.streak ~progress_class)
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
