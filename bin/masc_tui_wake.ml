type source =
  | Mailbox
  | Workspace_result
  | Preference_written
  | Keeper_preference_written
  | Refresh_progress
  | Settings_reread
  | Credential_prepared
  | History_read
  | Ask_answer_receipt
  | Ask_answer_completion
  | Runtime_assignment_saved
  | Keeper_settings_saved
  | Runtime_form_saved
  | Keeper_creation_observed
  | Task_dispatched
  | Console_write
  | Terminal_write_lost
  | Resize_signal
  | Interrupt_signal
  | Terminate_signal
  | Server_start_settled

let all_sources =
  [ Mailbox; Workspace_result; Preference_written; Keeper_preference_written;
    Refresh_progress; Settings_reread; Credential_prepared; History_read;
    Ask_answer_receipt; Ask_answer_completion; Runtime_assignment_saved;
    Keeper_settings_saved; Runtime_form_saved; Keeper_creation_observed;
    Task_dispatched; Console_write; Terminal_write_lost; Resize_signal;
    Interrupt_signal; Terminate_signal; Server_start_settled ]

(* One bit per source. A new constructor stops this match from compiling
   until it has a bit of its own. *)
let bit = function
  | Mailbox -> 0
  | Workspace_result -> 1
  | Preference_written -> 2
  | Keeper_preference_written -> 3
  | Refresh_progress -> 4
  | Settings_reread -> 5
  | Credential_prepared -> 6
  | History_read -> 7
  | Ask_answer_receipt -> 8
  | Ask_answer_completion -> 9
  | Runtime_assignment_saved -> 10
  | Keeper_settings_saved -> 11
  | Runtime_form_saved -> 12
  | Keeper_creation_observed -> 13
  | Task_dispatched -> 14
  | Console_write -> 15
  | Terminal_write_lost -> 16
  | Resize_signal -> 17
  | Interrupt_signal -> 18
  | Terminate_signal -> 19
  | Server_start_settled -> 20

let mask source = 1 lsl bit source

type bell = { rung : int Atomic.t; changed : Eio.Condition.t }

let create () = { rung = Atomic.make 0; changed = Eio.Condition.create () }
let loop = create ()

(* A compare-and-set loop rather than a lock: a signal handler may run in
   the middle of another ring on the same domain, and a lock taken there
   could never be released. *)
let ring bell source =
  let wanted = mask source in
  let rec set () =
    let rung = Atomic.get bell.rung in
    if rung land wanted = 0
       && not (Atomic.compare_and_set bell.rung rung (rung lor wanted))
    then set ()
  in
  set ();
  Eio.Condition.broadcast bell.changed

(* [loop_no_mutex] registers before it looks, so a ring that lands between
   the look and the sleep still wakes this fiber. *)
let await bell =
  Eio.Condition.loop_no_mutex bell.changed (fun () ->
      if Atomic.get bell.rung = 0 then None else Some ())

let take bell =
  let rung = Atomic.exchange bell.rung 0 in
  List.filter (fun source -> rung land mask source <> 0) all_sources

type mono_reason =
  | Frame_slot
  | After_frame
  | Owed_read_retry
  | Refresh_retry
  | Roster_row_scheduled
  | Engine_sample
  | Play_room_read
  | Tool_series_reread
  | Emblem_step
  | Paste_quiet
  | Drain_budget_spent
  | Machine_view_cadence
  | Wall_clock_recheck

type wall_reason =
  | Time_text
  | Provider_history_day
  | Harness_stale
  | Identity_attempt_deadline
  | Identity_login_expiry
  | Quit_notice_expiry

(* The clock column of RFC tui-idle-wait §2.2: which clock the decision
   behind each reason reads its instants on. *)
type deadline_reason = Monotonic of mono_reason | Wall of wall_reason

(* RFC tui-idle-wait §6. The loop's wait runs on Mtime, which on macOS is
   mach_absolute_time, and on the kernel's poll timeout: neither counts the
   time a machine sleeps, and a wall-clock step moves neither. A wall-clock
   instant noted as "so long from now" is therefore late by however long the
   machine slept, or the clock stepped, unless something else wakes the
   loop. No notice of a wake or a clock change reaches Eio or the OCaml
   runtime, so the bound is a re-read: a wall-clock instant further away than
   this is noted this far away instead, and the next pass reads the wall
   clock again. Five seconds keeps a wrong clock or age on screen at most
   that long after a wake, for at most one pass in five seconds, and only
   while such an instant is noted. *)
let wall_clock_recheck_s = 5.0

let nanoseconds_per_second = 1e9

module Mono = struct
  type t = int64

  let now = Mtime_clock.elapsed_ns

  (* A wait too long for the clock's range is due at its end: the same as
     never for a process. *)
  let offset_ns seconds =
    let ns = seconds *. nanoseconds_per_second in
    if ns >= Int64.to_float Int64.max_int then Int64.max_int else Int64.of_float ns

  let add_saturating at offset =
    let sum = Int64.add at offset in
    if Int64.compare offset 0L > 0 && Int64.compare sum at < 0 then Int64.max_int else sum

  let after at seconds =
    (* [seconds > 0.] is false for nan. *)
    let offset = if seconds > 0. then offset_ns seconds else 0L in
    add_saturating at offset

  let compare = Int64.compare

  let seconds_since at ~since =
    Int64.to_float (Int64.sub at since) /. nanoseconds_per_second

  (* RFC tui-idle-wait §3.2: only what remains of a wall-clock instant moves
     onto this clock, so a wall-clock step after this call does not move the
     result, and the next pass converts again. *)
  let of_wall ~now ~wall_now at = after now (at -. wall_now)
end

type deadline = { reason : deadline_reason; at_ns : int64 }

let earlier left right = if Int64.compare right.at_ns left.at_ns < 0 then right else left

let earliest = function
  | [] -> None
  | first :: rest -> Some (List.fold_left earlier first rest)

let in_seconds reason ~now_ns seconds = { reason = Monotonic reason; at_ns = Mono.after now_ns seconds }

module Pass = struct
  let current : deadline option Atomic.t = Atomic.make None

  let begin_pass () = Atomic.set current None

  let rec note deadline =
    let before = Atomic.get current in
    let after = match before with
      | None -> deadline
      | Some held -> earlier held deadline in
    if not (Option.equal ( == ) before (Some after))
       && not (Atomic.compare_and_set current before (Some after))
    then note deadline

  let noted () = Atomic.get current
end

let reached_mono reason ~now ~at =
  if Int64.compare now at >= 0 then true
  else begin
    Pass.note { reason = Monotonic reason; at_ns = at };
    false
  end

let reached_wall reason ~now ~at =
  if not (Float.is_finite now && Float.is_finite at) then false
  else if now >= at then true
  else begin
    let now_ns = Mono.now () in
    Pass.note
      (if at -. now > wall_clock_recheck_s then
         in_seconds Wall_clock_recheck ~now_ns wall_clock_recheck_s
       else { reason = Wall reason; at_ns = Mono.of_wall ~now:now_ns ~wall_now:now at });
    false
  end

(* RFC tui-idle-wait §2.3: the one cadence left. The machine's screen
   arrives through the observer stream and the chat beside it reads on its
   own deadline, so nothing found in the code needs it; it stays named until
   a game is checked without it. *)
let machine_view_cadence_s = 0.3

type loop_moments = { frame_due_ns : int64 option; frame_drawn : bool; machine_view : bool }

let next_deadline ~now_ns { frame_due_ns; frame_drawn; machine_view } =
  let frame_slot = Option.map (fun at_ns -> { reason = Monotonic Frame_slot; at_ns }) frame_due_ns in
  let after_frame = if frame_drawn then Some { reason = Monotonic After_frame; at_ns = now_ns } else None in
  let machine =
    if machine_view then Some (in_seconds Machine_view_cadence ~now_ns machine_view_cadence_s)
    else None in
  earliest (List.filter_map Fun.id [ frame_slot; after_frame; machine; Pass.noted () ])

type wait = { within_s : float option; bell : bell option }

let within seconds = { within_s = Some seconds; bell = None }

let until ~now_ns bell deadline =
  let within_s = Option.map (fun deadline ->
      let remaining = Int64.sub deadline.at_ns now_ns in
      if Int64.compare remaining 0L <= 0 then 0.
      else Int64.to_float remaining /. nanoseconds_per_second) deadline in
  { within_s; bell = Some bell }
