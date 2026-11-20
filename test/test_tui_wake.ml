(* What wakes the TUI main loop, and when it must wake by itself
   (RFC tui-idle-wait). Checked are the decisions only: which source a ring
   reports, which moment a decision notes, and which deadline the loop's wait
   is given. *)

open Alcotest
module Wake = Masc_tui_wake
module Reader = Masc_tui_input_reader

(* An exhaustive match per type: a new constructor does not compile here
   until it has a number, and then the checks below require it. *)
let source_number : Wake.source -> int = function
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

let source_count = 21

let reason_number : Wake.deadline_reason -> int = function
  | Frame_slot -> 0
  | After_frame -> 1
  | Time_text -> 2
  | Owed_read_retry -> 3
  | Refresh_retry -> 4
  | Roster_row_scheduled -> 5
  | Engine_sample -> 6
  | Play_room_read -> 7
  | Tool_series_reread -> 8
  | Provider_history_day -> 9
  | Harness_stale -> 10
  | Identity_attempt_deadline -> 11
  | Identity_login_expiry -> 12
  | Quit_notice_expiry -> 13
  | Emblem_step -> 14
  | Paste_quiet -> 15
  | Drain_budget_spent -> 16
  | Machine_view_cadence -> 17
  | Wall_clock_recheck -> 18

let all_reasons : Wake.deadline_reason list =
  [ Frame_slot; After_frame; Time_text; Owed_read_retry; Refresh_retry;
    Roster_row_scheduled; Engine_sample; Play_room_read; Tool_series_reread;
    Provider_history_day; Harness_stale; Identity_attempt_deadline;
    Identity_login_expiry; Quit_notice_expiry; Emblem_step; Paste_quiet;
    Drain_budget_spent; Machine_view_cadence; Wall_clock_recheck ]

let reason_count = 19

(* The clock column of RFC tui-idle-wait §2.2. Moving a reason to the other
   clock changes this list. *)
let wall_reasons : Wake.deadline_reason list =
  [ Time_text; Provider_history_day; Harness_stale; Identity_attempt_deadline;
    Identity_login_expiry; Quit_notice_expiry ]
let ns_per_s = 1_000_000_000L
let seconds n = Int64.mul (Int64.of_int n) ns_per_s
let taken bell = List.map source_number (Wake.take bell)
let noted_reason () = Option.map (fun (d : Wake.deadline) -> reason_number d.reason) (Wake.Pass.noted ())

(* [reached] reads the monotonic clock itself; bracket that read. *)
let check_noted_in label reason ~remaining_s run =
  Wake.Pass.begin_pass ();
  let before = Mtime_clock.elapsed_ns () in
  let answer = run () in
  let after = Mtime_clock.elapsed_ns () in
  check bool (label ^ ": not yet") false answer;
  match Wake.Pass.noted () with
  | None -> failf "%s: nothing noted" label
  | Some noted ->
    check int (label ^ ": reason") (reason_number reason) (reason_number noted.reason);
    let offset = Int64.of_float (remaining_s *. 1e9) in
    check bool (label ^ ": at the moment the answer changes") true
      (Int64.compare noted.at_ns (Int64.add before offset) >= 0
       && Int64.compare noted.at_ns (Int64.add after offset) <= 0)

let check_nothing_noted label =
  check (option int) (label ^ ": nothing noted") None (noted_reason ())

(* The bell *)

let test_every_source_is_listed () =
  check (list int) "all_sources is every constructor once, in declaration order"
    (List.init source_count Fun.id) (List.map source_number Wake.all_sources)

let test_take_reports_each_source () =
  let bell = Wake.create () in
  check (list int) "a new bell has nothing" [] (taken bell);
  List.iter (fun source ->
      Wake.ring bell source;
      Wake.ring bell source;
      check (list int) "a ring is reported once, by its own source" [ source_number source ] (taken bell);
      check (list int) "take forgets it" [] (taken bell))
    Wake.all_sources;
  List.iter (Wake.ring bell) (List.rev Wake.all_sources);
  check (list int) "every source rung at once comes back in declaration order"
    (List.init source_count Fun.id) (taken bell)

let test_await_wakes_on_each_source () =
  Eio_mock.Backend.run (fun () ->
      List.iter (fun source ->
          let bell = Wake.create () in
          let woke = ref false in
          Eio.Fiber.both
            (fun () -> Wake.await bell; woke := true)
            (fun () ->
              Eio.Fiber.yield ();
              check bool "asleep before the ring" false !woke;
              Wake.ring bell source);
          check bool "the ring woke the waiter" true !woke;
          check (list int) "and the source is there to take" [ source_number source ] (taken bell))
        Wake.all_sources)

let test_await_sleeps_without_a_ring () =
  Eio_mock.Backend.run (fun () ->
      let bell = Wake.create () in
      let woke =
        Eio.Fiber.first
          (fun () -> Wake.await bell; true)
          (fun () -> Eio.Fiber.yield (); Eio.Fiber.yield (); false) in
      check bool "nothing rang, so the waiter still sleeps" false woke;
      Wake.ring bell Wake.Resize_signal;
      Wake.await bell;
      check (list int) "a ring before the wait ends it at once" [ source_number Wake.Resize_signal ]
        (taken bell))

(* Deadlines *)

let test_earliest_picks_each_reason () =
  check (option int) "no deadline" None
    (Option.map (fun (d : Wake.deadline) -> reason_number d.reason) (Wake.earliest []));
  check int "every reason is listed" reason_count (List.length all_reasons);
  List.iter (fun reason ->
      let others = List.mapi (fun i other -> { Wake.reason = other; at_ns = seconds (10 + i) }) all_reasons in
      let soonest = { Wake.reason; at_ns = seconds 5 } in
      List.iter (fun deadlines ->
          match Wake.earliest deadlines with
          | None -> fail "deadlines but no earliest"
          | Some chosen ->
            check int "the soonest wins whatever its reason" (reason_number reason) (reason_number chosen.reason))
        [ soonest :: others; others @ [ soonest ] ])
    all_reasons

let test_in_seconds_bounds () =
  let at offset = (Wake.in_seconds Wake.Time_text ~now_ns:(seconds 100) offset).at_ns in
  check int64 "a second and a half later" (Int64.add (seconds 100) 1_500_000_000L) (at 1.5);
  check int64 "a past moment is now" (seconds 100) (at (-3.));
  check int64 "nan is now" (seconds 100) (at Float.nan);
  check int64 "never is the end of the clock" Int64.max_int (at Float.infinity);
  check int64 "too far for the clock is its end" Int64.max_int (at 1e300)

let test_reached_notes_only_while_not_yet () =
  List.iter (fun reason ->
      check_noted_in "a moment still ahead" reason ~remaining_s:2.5
        (fun () -> Wake.reached reason ~now:1000. ~at:1002.5);
      Wake.Pass.begin_pass ();
      check bool "the moment itself is reached" true (Wake.reached reason ~now:1002.5 ~at:1002.5);
      check bool "and after it" true (Wake.reached reason ~now:2000. ~at:1002.5);
      check_nothing_noted "a reached moment")
    all_reasons;
  Wake.Pass.begin_pass ();
  check bool "never is not reached" false (Wake.reached Wake.Time_text ~now:1. ~at:Float.infinity);
  check bool "nan is not reached" false (Wake.reached Wake.Time_text ~now:Float.nan ~at:1.);
  check_nothing_noted "a moment off the clock";
  check bool "ns: still ahead" false
    (Wake.reached_ns Wake.Emblem_step ~now_ns:(seconds 1) ~at_ns:(seconds 3));
  check (option int64) "ns: noted as given" (Some (seconds 3))
    (Option.map (fun (d : Wake.deadline) -> d.at_ns) (Wake.Pass.noted ()));
  Wake.Pass.begin_pass ();
  check bool "ns: reached" true (Wake.reached_ns Wake.Emblem_step ~now_ns:(seconds 3) ~at_ns:(seconds 3));
  check_nothing_noted "ns: a reached moment"

(* The loop's own clock and the kernel's wait stop while the machine sleeps,
   so a wall-clock instant far ahead is read again soon instead (§6). *)
let test_a_far_wall_clock_instant_is_read_again_soon () =
  List.iter (fun reason ->
      let wall = List.mem reason wall_reasons in
      check bool "the reason's clock" wall
        (match Wake.clock_of reason with Wall -> true | Monotonic -> false);
      if wall then begin
        check_noted_in "a wall-clock instant an hour away" Wall_clock_recheck
          ~remaining_s:Wake.wall_clock_recheck_s (fun () -> Wake.reached reason ~now:0. ~at:3600.);
        check_noted_in "a wall-clock instant within the recheck" reason ~remaining_s:2.
          (fun () -> Wake.reached reason ~now:0. ~at:2.)
      end
      else
        check_noted_in "a monotonic instant an hour away" reason ~remaining_s:3600.
          (fun () -> Wake.reached reason ~now:0. ~at:3600.))
    all_reasons

let test_pass_keeps_the_earliest_and_begins_empty () =
  Wake.Pass.begin_pass ();
  Wake.Pass.note { reason = Harness_stale; at_ns = seconds 30 };
  Wake.Pass.note { reason = Owed_read_retry; at_ns = seconds 10 };
  Wake.Pass.note { reason = Engine_sample; at_ns = seconds 20 };
  Wake.Pass.note { reason = Paste_quiet; at_ns = seconds 10 };
  check (option int) "the earliest, the first of a tie" (Some (reason_number Owed_read_retry)) (noted_reason ());
  Wake.Pass.begin_pass ();
  check_nothing_noted "a new pass"

let test_next_deadline () =
  let now_ns = seconds 100 in
  let moments ?(frame_due_ns = None) ?(frame_drawn = false) ?(machine_view = false) () =
    { Wake.frame_due_ns; frame_drawn; machine_view } in
  let next m = Option.map (fun (d : Wake.deadline) -> (reason_number d.reason, d.at_ns))
      (Wake.next_deadline ~now_ns m) in
  Wake.Pass.begin_pass ();
  check (option (pair int int64)) "nothing to wake for" None (next (moments ()));
  check (option (pair int int64)) "a frame's slot"
    (Some (reason_number Frame_slot, seconds 101)) (next (moments ~frame_due_ns:(Some (seconds 101)) ()));
  check (option (pair int int64)) "the pass after a frame is now"
    (Some (reason_number After_frame, now_ns))
    (next (moments ~frame_due_ns:(Some (seconds 101)) ~frame_drawn:true ()));
  check (option (pair int int64)) "a game on screen"
    (Some (reason_number Machine_view_cadence,
           Int64.add now_ns (Int64.of_float (Wake.machine_view_cadence_s *. 1e9))))
    (next (moments ~machine_view:true ()));
  Wake.Pass.note { reason = Refresh_retry; at_ns = seconds 105 };
  check (option (pair int int64)) "a noted moment when nothing of the loop's is due"
    (Some (reason_number Refresh_retry, seconds 105)) (next (moments ()));
  check (option (pair int int64)) "a frame slot before it"
    (Some (reason_number Frame_slot, seconds 101)) (next (moments ~frame_due_ns:(Some (seconds 101)) ()));
  Wake.Pass.note { reason = Paste_quiet; at_ns = seconds 100 };
  check (option (pair int int64)) "a noted moment before the frame slot"
    (Some (reason_number Paste_quiet, seconds 100)) (next (moments ~frame_due_ns:(Some (seconds 101)) ()));
  Wake.Pass.begin_pass ()

let test_until () =
  let bell = Wake.create () in
  let wait = Wake.until ~now_ns:(seconds 10) bell None in
  check (option (float 0.)) "no deadline waits without a bound" None wait.within_s;
  check bool "and carries the bell" true (Option.is_some wait.bell);
  check (option (float 1e-9)) "a deadline ahead" (Some 2.5)
    (Wake.until ~now_ns:(seconds 10) bell (Some { reason = Frame_slot; at_ns = 12_500_000_000L })).within_s;
  check (option (float 0.)) "a deadline passed is no wait" (Some 0.)
    (Wake.until ~now_ns:(seconds 10) bell (Some { reason = Frame_slot; at_ns = seconds 9 })).within_s;
  check bool "within carries no bell" true (Option.is_none (Wake.within 0.1).bell)

(* The decisions that note their moment *)

(* A decision on the loop's clock notes its own instant, not one moved
   through seconds. *)
let noted () =
  Option.map (fun (d : Wake.deadline) -> (reason_number d.reason, d.at_ns)) (Wake.Pass.noted ())

let test_owed_read_retry_is_noted () =
  let module Owed = Masc_tui_owed_read in
  let now = Wake.Mono.now () in
  let waiting = Owed.failed ~retry_s:6. ~max_retry_s:60. ~now
      (Owed.started (Owed.changed Owed.settled)) in
  let retry_at = match waiting with
    | Owed.Waiting { retry_at; _ } -> retry_at
    | Owed.Settled | Owed.Owed _ | Owed.Reading _ -> fail "a failed read is not waiting" in
  check int64 "the retry is the wait after the failure"
    (Int64.add (now :> int64) (seconds 6)) (retry_at :> int64);
  Wake.Pass.begin_pass ();
  check bool "owed read: not yet" false (Owed.due ~now:(Wake.Mono.after now 1.) waiting);
  check (option (pair int int64)) "owed read: its retry is noted"
    (Some (reason_number Owed_read_retry, (retry_at :> int64))) (noted ());
  Wake.Pass.begin_pass ();
  check bool "due at its retry" true (Owed.due ~now:retry_at waiting);
  check bool "owed is due" true (Owed.due ~now (Owed.changed Owed.settled));
  check bool "settled is not" false (Owed.due ~now Owed.settled);
  check_nothing_noted "owed read without a wait"

let test_refresh_retry_is_noted () =
  let module Pace = Masc_tui_refresh_pace in
  let now = Wake.Mono.now () in
  let failing = Pace.probe_failed ~retry_s:2. ~max_retry_s:30. ~now ~wall_now:5000. Pace.answering in
  let retry_at = match failing with
    | Pace.Failing { retry_at; _ } -> retry_at
    | Pace.Answering | Pace.Recovered _ -> fail "a failed probe is not failing" in
  check int64 "the retry is the wait after the failure"
    (Int64.add (now :> int64) (seconds 2)) (retry_at :> int64);
  Wake.Pass.begin_pass ();
  check bool "refresh: not yet" false (Pace.due ~now:(Wake.Mono.after now 0.5) failing);
  check (option (pair int int64)) "refresh: its retry is noted"
    (Some (reason_number Refresh_retry, (retry_at :> int64))) (noted ());
  Wake.Pass.begin_pass ();
  check bool "due at its retry" true (Pace.due ~now:retry_at failing);
  check_nothing_noted "refresh at its retry"

let test_roster_row_is_noted () =
  let module Roster = Masc_tui_roster_owed in
  let now = Wake.Mono.now () in
  let at = Wake.Mono.after now 6. in
  let scheduled = Roster.schedule_rows [ ("keeper-a", at) ] Roster.settled in
  Wake.Pass.begin_pass ();
  let still = Roster.release_scheduled ~now scheduled in
  check (option (pair int int64)) "the scheduled row is noted"
    (Some (reason_number Roster_row_scheduled, (at :> int64))) (noted ());
  check bool "nothing to read before its time" true (Option.is_none (Roster.next_read ~now still));
  check bool "read at its time" true
    (Option.is_some (Roster.next_read ~now:at (Roster.release_scheduled ~now:at scheduled)))

let test_engine_sample_is_noted () =
  let module Samples = Masc_tui_engine_samples in
  let point = Samples.Answered
      { Samples.live_heap = Masc_tui_braille.of_count 1; scheduler_p95 = Masc_tui_braille.of_count 1 } in
  let opened = Samples.shown Samples.stopped ~now:0. ~capacity:8 in
  let opened, _ = Samples.tick opened ~now:0. ~newest:(Some { Samples.at = -0.5; reading = point }) in
  let newest = Some { Samples.at = 1.5; reading = point } in
  check_noted_in "engine sample" Wake.Engine_sample ~remaining_s:0.1
    (fun () -> match Samples.tick opened ~now:1.9 ~newest with
       | _, Samples.Nothing -> false
       | _, (Samples.Sampled | Samples.Read) -> true)

let test_play_room_read_is_noted () =
  let module Room = Masc_tui_play_room in
  let machine = Masc.Machine_lane.Dos in
  let room, read = Room.poll (Room.active (Room.create ()) true) ~now:0. ~machine in
  let read = match read with Some read -> read | None -> fail "an open room reads" in
  let failed = Room.receive room read ~now:0. (Error "connection lost") in
  check_noted_in "play room" Wake.Play_room_read ~remaining_s:1.
    (fun () -> Option.is_some (snd (Room.poll failed ~now:1. ~machine)));
  let answered = Room.receive room read ~now:0. (Ok { Masc.Play_room.messages = []; members = []; has_more = false }) in
  Wake.Pass.begin_pass ();
  check bool "an answered room waits for a change" true
    (Option.is_none (snd (Room.poll answered ~now:100. ~machine)));
  check_nothing_noted "a room with no next read"

(* The terminal read *)

let with_stdin_pipe run =
  let context = Eio_context.snapshot_state () and was_ready = Eio_guard.is_ready () in
  Fun.protect ~finally:(fun () ->
      Eio_context.restore_state context;
      if not was_ready then Eio_guard.disable ()) (fun () ->
      Eio_main.run (fun env ->
          let original_stdin = Unix.dup Unix.stdin in
          let source, writer = Unix.pipe ~cloexec:true () in
          Fun.protect ~finally:(fun () ->
              Unix.dup2 original_stdin Unix.stdin;
              Unix.close original_stdin; Unix.close source; Unix.close writer) (fun () ->
              Unix.dup2 source Unix.stdin;
              Eio.Switch.run (fun sw -> Eio_context.with_turn_switch sw (fun () ->
                  Eio_context.set_clock (Eio.Stdenv.clock env);
                  Eio_guard.enable ();
                  run ~writer)))))

let write writer text = ignore (Unix.write_substring writer text 0 (String.length text))
let is_none_event = function None -> true | Some _ -> false

(* Give a woken fiber its turns before the fallback: a read the bell cannot
   end takes the fallback byte instead, and the check below fails. *)
let settle promise = for _ = 1 to 100 do if Option.is_none (Eio.Promise.peek promise) then Eio.Fiber.yield () done

let test_ring_ends_a_read_without_a_deadline () =
  with_stdin_pipe (fun ~writer ->
      let reader = Reader.create_input_reader () and bell = Wake.create () in
      let result, resolve = Eio.Promise.create () in
      Eio.Fiber.both
        (fun () -> Eio.Promise.resolve resolve (Reader.read_input ~wait:(Wake.until ~now_ns:0L bell None) reader ()))
        (fun () ->
          settle result;
          check bool "the read sleeps while nothing rang" true (Option.is_none (Eio.Promise.peek result));
          Wake.ring bell Wake.Mailbox;
          settle result;
          if Option.is_none (Eio.Promise.peek result) then write writer "x");
      check bool "the ring ended the read with no event" true (is_none_event (Eio.Promise.await result));
      check (list int) "the ring stays for the loop to take" [ source_number Wake.Mailbox ] (taken bell))

let test_waiting_byte_is_read_before_a_ring () =
  with_stdin_pipe (fun ~writer ->
      let reader = Reader.create_input_reader () and bell = Wake.create () in
      Wake.ring bell Wake.Console_write;
      write writer "x";
      (match Reader.read_input ~wait:(Wake.until ~now_ns:0L bell None) reader () with
       | Some (Reader.Key "x") -> ()
       | Some _ | None -> fail "a ring standing before the read took the place of a waiting key");
      check (list int) "the ring is still there" [ source_number Wake.Console_write ] (taken bell))

let test_ring_does_not_split_an_escape_sequence () =
  with_stdin_pipe (fun ~writer ->
      let whole = Reader.create_input_reader () in
      write writer "\x1b[A";
      let arrow = Reader.read_input ~wait:(Wake.within 1.) whole () in
      check bool "a whole arrow is a key" true (Option.is_some arrow);
      let reader = Reader.create_input_reader () and bell = Wake.create () in
      write writer "\x1b";
      let result, resolve = Eio.Promise.create () in
      Eio.Fiber.both
        (fun () -> Eio.Promise.resolve resolve (Reader.read_input ~wait:(Wake.until ~now_ns:0L bell None) reader ()))
        (fun () ->
          Wake.ring bell Wake.Mailbox;
          Eio.Fiber.yield ();
          write writer "[A");
      check bool "the ring during ESC's wait does not end it as Escape" true
        (Eio.Promise.await result = arrow))

let sleep_s seconds =
  match Eio_context.get_clock_opt () with
  | Some clock -> Eio.Time.sleep clock seconds
  | None -> fail "no clock"

(* A terminal that never answers the graphics query (the harness VTE, iTerm2)
   keeps the startup probe in front of every byte for the whole session. *)
let behind_an_unanswered_probe ~palette_requested =
  let reader = Reader.create_input_reader () in
  Reader.install_terminal_probe reader (Masc_tui_terminal_probe.create ~palette_requested);
  reader

(* An idle read: no deadline and a bell nobody rings. If it has not ended by
   itself half a second on, [fallback] is written so that it ends; [true]
   says the fallback was needed. *)
let read_idle reader ~writer ~fallback =
  let bell = Wake.create () in
  let result, resolve = Eio.Promise.create () in
  let fell_back = ref false in
  Eio.Fiber.both
    (fun () -> Eio.Promise.resolve resolve (Reader.read_input ~wait:(Wake.until ~now_ns:0L bell None) reader ()))
    (fun () ->
      Eio.Fiber.first
        (fun () -> ignore (Eio.Promise.await result))
        (fun () -> sleep_s 0.5; fell_back := true; write writer fallback));
  (Eio.Promise.await result, !fell_back)

let rec read_rest reader =
  match Reader.read_input ~wait:(Wake.within 0.2) reader () with
  | None -> []
  | Some event -> event :: read_rest reader

let event_name = function
  | Reader.Key name -> name
  | Reader.Pasted _ | Reader.Graphics_reply _ | Reader.Mouse_left_press _
  | Reader.Mouse_left_drag _ | Reader.Mouse_left_release _ | Reader.Mouse_wheel _ -> "<not a key>"

let test_lone_escape_behind_an_unanswered_probe () =
  List.iter (fun palette_requested ->
      with_stdin_pipe (fun ~writer ->
          let reader = behind_an_unanswered_probe ~palette_requested in
          write writer "\x1b";
          let event, fell_back = read_idle reader ~writer ~fallback:"x" in
          check bool "the read ended by itself" false fell_back;
          check (option string) "a lone Esc is Escape" (Some "esc") (Option.map event_name event)))
    [ false; true ]

(* An Esc held until the next byte joins it: Backspace became Alt+Backspace,
   and [ O ] began a sequence that took the keys after them. *)
let test_lone_escape_behind_a_probe_keeps_the_next_key () =
  List.iter (fun (palette_requested, follower, expected) ->
      with_stdin_pipe (fun ~writer ->
          let reader = behind_an_unanswered_probe ~palette_requested in
          write writer "\x1b";
          let first, fell_back = read_idle reader ~writer ~fallback:follower in
          if not fell_back then write writer follower;
          check (list string) (Printf.sprintf "Esc, then %S" follower) expected
            (List.map event_name (Option.to_list first @ read_rest reader))))
    [ (false, "\x7f", [ "esc"; "\x7f" ]);
      (false, "[j", [ "esc"; "["; "j" ]);
      (false, "Oj", [ "esc"; "O"; "j" ]);
      (false, "]j", [ "esc"; "]"; "j" ]);
      (true, "]j", [ "esc"; "]"; "j" ]) ]

let test_next_byte_wait () =
  let bell = Wake.create () in
  let idle = Wake.until ~now_ns:0L bell None in
  let due_now = Wake.until ~now_ns:0L bell (Some { Wake.reason = Frame_slot; at_ns = 0L }) in
  let quiet_at_ns = seconds 10 in
  let ahead = Int64.sub quiet_at_ns 30_000_000L and past = Int64.add quiet_at_ns 1L in
  let wait held ~now_ns caller = Reader.next_byte_wait held ~quiet_at_ns ~now_ns caller in
  let within = option (float 1e-9) in
  List.iter (fun caller ->
      let prefix = wait (Some Masc_tui_input_decoder.Prefix) ~now_ns:ahead caller in
      check within "a prefix waits until it has been quiet, whatever the caller allows"
        (Some 0.03) prefix.within_s;
      check bool "and no bell ends it" true (Option.is_none prefix.bell))
    [ idle; due_now ];
  check within "a prefix already quiet waits no more" (Some 0.)
    (wait (Some Masc_tui_input_decoder.Prefix) ~now_ns:past idle).within_s;
  List.iter (fun held ->
      let first = wait (Some held) ~now_ns:ahead idle in
      check within "a sequence's first quiet read returns" (Some 0.03) first.within_s;
      check bool "and keeps the bell" true (Option.is_some first.bell);
      check within "a frame due sooner comes first" (Some 0.)
        (wait (Some held) ~now_ns:ahead due_now).within_s;
      check within "after that the caller's wait" None (wait (Some held) ~now_ns:past idle).within_s)
    [ Masc_tui_input_decoder.Sequence; Masc_tui_input_decoder.Character ];
  List.iter (fun held ->
      let caller = wait held ~now_ns:ahead idle in
      check within "a paste or nothing held waits by the caller" None caller.within_s;
      check bool "with its bell" true (Option.is_some caller.bell))
    [ Some Masc_tui_input_decoder.Pasting; Some Masc_tui_input_decoder.Draining; None ]

let () =
  run "tui_wake"
    [ ("bell",
       [ test_case "every source is listed" `Quick test_every_source_is_listed;
         test_case "take reports each source" `Quick test_take_reports_each_source;
         test_case "await wakes on each source" `Quick test_await_wakes_on_each_source;
         test_case "await sleeps without a ring" `Quick test_await_sleeps_without_a_ring ]);
      ("deadline",
       [ test_case "earliest picks each reason" `Quick test_earliest_picks_each_reason;
         test_case "in_seconds bounds" `Quick test_in_seconds_bounds;
         test_case "reached notes only while not yet" `Quick test_reached_notes_only_while_not_yet;
         test_case "a far wall-clock instant is read again soon" `Quick
           test_a_far_wall_clock_instant_is_read_again_soon;
         test_case "pass keeps the earliest" `Quick test_pass_keeps_the_earliest_and_begins_empty;
         test_case "next deadline" `Quick test_next_deadline;
         test_case "until" `Quick test_until ]);
      ("noted by decisions",
       [ test_case "owed read retry" `Quick test_owed_read_retry_is_noted;
         test_case "refresh retry" `Quick test_refresh_retry_is_noted;
         test_case "roster row" `Quick test_roster_row_is_noted;
         test_case "engine sample" `Quick test_engine_sample_is_noted;
         test_case "play room read" `Quick test_play_room_read_is_noted ]);
      ("terminal read",
       [ test_case "a ring ends a read without a deadline" `Quick test_ring_ends_a_read_without_a_deadline;
         test_case "a waiting byte is read before a ring" `Quick test_waiting_byte_is_read_before_a_ring;
         test_case "a lone Esc behind an unanswered probe" `Quick test_lone_escape_behind_an_unanswered_probe;
         test_case "a lone Esc behind a probe keeps the next key" `Quick
           test_lone_escape_behind_a_probe_keeps_the_next_key;
         test_case "next byte wait" `Quick test_next_byte_wait;
         test_case "a ring does not split an escape sequence" `Quick
           test_ring_does_not_split_an_escape_sequence ]) ]
