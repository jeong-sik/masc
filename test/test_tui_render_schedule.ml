open Alcotest

module Schedule = Masc_tui_render_schedule
let ns_per_ms = 1_000_000L
let ms value = Int64.mul (Int64.of_int value) ns_per_ms

let check_render label = function
  | Schedule.Render -> ()
  | Schedule.Idle -> failf "%s: expected render, got idle" label
  | Schedule.Wait_until due ->
      failf "%s: expected render, waiting until %Ld" label due

let check_idle label = function
  | Schedule.Idle -> ()
  | Schedule.Render -> failf "%s: expected idle, got render" label
  | Schedule.Wait_until due ->
      failf "%s: expected idle, waiting until %Ld" label due

let test_idle_has_no_render_work () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  for offset = 1 to 1000 do
    check_idle "one second idle" (Schedule.take ~input_pending:false schedule ~now_ns:(ms offset))
  done;
  check (option int64) "idle has no frame to wake for" None
    (Schedule.frame_due_ns schedule ~now_ns:(ms 1000))

let test_burst_coalesces_to_one_frame () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  for offset = 1 to 1000 do
    Schedule.request schedule Schedule.Background;
    match Schedule.take ~input_pending:false schedule ~now_ns:(Int64.of_int offset) with
    | Schedule.Wait_until due -> check int64 "stable deadline" (ms 16) due
    | Schedule.Idle -> fail "dirty burst became idle"
    | Schedule.Render -> fail "dirty burst rendered before its frame deadline"
  done;
  check_render "one coalesced frame"
    (Schedule.take ~input_pending:false schedule ~now_ns:(ms 16));
  check_idle "burst is consumed"
    (Schedule.take ~input_pending:false schedule ~now_ns:(ms 17))

let test_input_after_idle_renders_immediately () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  Schedule.request schedule Schedule.Input;
  check_render "input after idle"
    (Schedule.take ~input_pending:false schedule ~now_ns:(ms 1000))

let test_input_does_not_wait_for_recent_frame () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  Schedule.request schedule Schedule.Input;
  check (option int64) "first input does not sleep" (Some 1L)
    (Schedule.frame_due_ns schedule ~now_ns:1L);
  check_render "keypress immediately after a background frame"
    (Schedule.take ~input_pending:false schedule ~now_ns:1L)

let test_separate_repeated_inputs_render_when_drained () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  Schedule.request schedule Schedule.Input;
  check_render "first input is immediate" (Schedule.take ~input_pending:false schedule ~now_ns:(ms 1));
  Schedule.request schedule Schedule.Input;
  check (option int64) "handled input does not sleep for the frame deadline" (Some (ms 6))
    (Schedule.frame_due_ns schedule ~now_ns:(ms 6));
  check_render "second drained input preempts the recent input frame"
    (Schedule.take ~input_pending:false schedule ~now_ns:(ms 6));
  check_idle "drained input is consumed once"
    (Schedule.take ~input_pending:false schedule ~now_ns:(ms 7));
  Schedule.request schedule Schedule.Force;
  check_render "force still renders immediately" (Schedule.take ~input_pending:false schedule ~now_ns:(ms 18));
  Schedule.request schedule Schedule.Input;
  check_render "a later input preempts the forced frame"
    (Schedule.take ~input_pending:false schedule ~now_ns:(ms 19))

let test_continuous_input_is_paced_and_final_input_is_immediate () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  let rendered = ref 0 in
  for offset = 1 to 1000 do
    Schedule.request schedule Schedule.Input;
    match Schedule.take ~input_pending:true schedule ~now_ns:(ms offset) with
    | Schedule.Render -> incr rendered
    | Schedule.Wait_until _ -> ()
    | Schedule.Idle -> fail "continuous input was dropped"
  done;
  check bool "continuous input paints at most 63 frames in one second" true
    (!rendered > 0 && !rendered <= 63);
  Schedule.request schedule Schedule.Input;
  check_render "last input renders before the next interval"
    (Schedule.take ~input_pending:false schedule ~now_ns:(ms 1001));
  check_idle "no redraw or busy poll after the burst"
    (Schedule.take ~input_pending:false schedule ~now_ns:(ms 1002));
  check (option int64) "reader can block once input is presented" None
    (Schedule.frame_due_ns schedule ~now_ns:(ms 1002))

let test_buffered_input_renders_when_drained () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  Schedule.request schedule Schedule.Background;
  Schedule.request schedule Schedule.Input;
  (match Schedule.take ~input_pending:true schedule ~now_ns:1L with
   | Schedule.Wait_until due -> check int64 "buffered burst deadline" (ms 16) due
   | Schedule.Render -> fail "painted before buffered input was handled"
   | Schedule.Idle -> fail "lost pending input");
  Schedule.request schedule Schedule.Input;
  check_render "the last byte need not wait for the deadline"
    (Schedule.take ~input_pending:false schedule ~now_ns:2L);
  check_idle "input frame consumed" (Schedule.take ~input_pending:false schedule ~now_ns:3L)

let test_dirty_timeout_wakes_at_deadline () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  Schedule.request schedule Schedule.Background;
  check (option int64) "a deferred frame wakes the wait at its slot" (Some (ms 16))
    (Schedule.frame_due_ns schedule ~now_ns:(ms 10));
  check (option int64) "a slot already passed is due now" (Some (ms 40))
    (Schedule.frame_due_ns schedule ~now_ns:(ms 40))

let test_overrun_leaves_a_window_to_consume_pending_input () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "begin slow frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  Schedule.completed schedule ~now_ns:(ms 64);
  Schedule.request schedule Schedule.Input;
  (match Schedule.take ~input_pending:true schedule ~now_ns:(ms 65) with
   | Schedule.Wait_until due -> check int64 "pace from completion" (ms 80) due
   | Schedule.Render -> fail "another slow frame displaced queued input"
   | Schedule.Idle -> fail "pending input was lost");
  check (option int64) "queued input can be read immediately" (Some (ms 65))
    (Schedule.frame_due_ns schedule ~now_ns:(ms 65));
  check_render "the last input does not wait for the new deadline"
    (Schedule.take ~input_pending:false schedule ~now_ns:(ms 66))

let test_completion_keeps_requests_and_force_preempts_it () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "begin frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  Schedule.request schedule Schedule.Input;
  Schedule.completed schedule ~now_ns:(ms 64);
  (match Schedule.take ~input_pending:true schedule ~now_ns:(ms 65) with
   | Schedule.Wait_until due -> check int64 "request survived completion" (ms 80) due
   | Schedule.Render -> fail "queued input ignored completion"
   | Schedule.Idle -> fail "completion discarded a request raised during presentation");
  Schedule.request schedule Schedule.Force;
  check_render "force remains immediate with queued input"
    (Schedule.take ~input_pending:true schedule ~now_ns:(ms 66))

let test_completion_preserves_background_and_deferred_pacing () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "begin slow frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  Schedule.completed schedule ~now_ns:(ms 64);
  Schedule.request schedule Schedule.Background;
  check_render "background keeps the original start deadline"
    (Schedule.take ~input_pending:false schedule ~now_ns:(ms 65));
  (* The caller deferred this frame before Build: its start is the fallback,
     and completion of the preceding frame cannot make it immediately due. *)
  Schedule.request schedule Schedule.Input;
  (match Schedule.take ~input_pending:true schedule ~now_ns:(ms 66) with
   | Schedule.Wait_until due -> check int64 "deferred frame fallback" (ms 81) due
   | Schedule.Render -> fail "deferred frame reused an old completion deadline"
   | Schedule.Idle -> fail "deferred frame lost pending input")

let test_input_preempts_pending_background_frame () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  Schedule.request schedule Schedule.Background;
  (match Schedule.take ~input_pending:false schedule ~now_ns:(ms 2) with
   | Schedule.Wait_until due -> check int64 "background deadline" (ms 16) due
   | Schedule.Idle -> fail "background request became idle"
   | Schedule.Render -> fail "background request rendered too early");
  Schedule.request schedule Schedule.Input;
  check_render "input preempts background deadline"
    (Schedule.take ~input_pending:false schedule ~now_ns:(ms 2))

let test_input_burst_stays_inside_one_frame_window () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  for offset = 1 to 1000 do
    Schedule.request schedule Schedule.Input;
    match Schedule.take ~input_pending:true schedule ~now_ns:(Int64.of_int offset) with
    | Schedule.Wait_until due -> check int64 "input deadline" (ms 16) due
    | Schedule.Idle -> fail "input request became idle"
    | Schedule.Render -> fail "input byte burst rendered before the deadline"
  done;
  check_render "coalesced input frame"
    (Schedule.take ~input_pending:true schedule ~now_ns:(ms 16))

let test_terminal_size_cache_reprobes_only_after_invalidation () =
  let probes = ref 0 in
  let next_size = ref (Some (40, 120)) in
  let probe () =
    incr probes;
    !next_size
  in
  let cache = Schedule.Terminal_size_cache.create ~fallback:(24, 80) in
  check (pair int int) "first probe" (40, 120)
    (Schedule.Terminal_size_cache.get cache ~probe);
  next_size := Some (50, 160);
  check (pair int int) "cached size" (40, 120)
    (Schedule.Terminal_size_cache.get cache ~probe);
  check int "one probe before resize" 1 !probes;
  Schedule.Terminal_size_cache.invalidate cache;
  Schedule.Terminal_size_cache.invalidate cache;
  check (pair int int) "resize reprobe" (50, 160)
    (Schedule.Terminal_size_cache.get cache ~probe);
  check int "one additional probe" 2 !probes;
  Schedule.Terminal_size_cache.invalidate cache;
  next_size := Some (1, 1);
  check (pair int int) "tiny resize preserves box invariants" (1, 4)
    (Schedule.Terminal_size_cache.get cache ~probe);
  Schedule.Terminal_size_cache.invalidate cache;
  next_size := None;
  check (pair int int) "probe failure keeps last valid size" (1, 4)
    (Schedule.Terminal_size_cache.get cache ~probe);
  let empty = Schedule.Terminal_size_cache.create ~fallback:(24, 80) in
  check (pair int int) "first probe failure uses fallback" (24, 80)
    (Schedule.Terminal_size_cache.get empty ~probe)

let test_terminal_size_cache_refreshes_without_losing_last_valid () =
  let next_size = ref (Some (46, 180)) in
  let probes = ref 0 in
  let probe () =
    incr probes;
    !next_size
  in
  let cache = Schedule.Terminal_size_cache.create ~fallback:(24, 80) in
  check bool "startup shape is new" true
    (Schedule.Terminal_size_cache.refresh cache ~probe
    = Schedule.Terminal_size_cache.Changed (46, 180));
  next_size := Some (42, 180);
  check bool "resize without signal is a change" true
    (Schedule.Terminal_size_cache.refresh cache ~probe
    = Schedule.Terminal_size_cache.Changed (42, 180));
  next_size := None;
  check bool "transient failure keeps resized shape unchanged" true
    (Schedule.Terminal_size_cache.refresh cache ~probe
    = Schedule.Terminal_size_cache.Unchanged (42, 180));
  check (pair int int) "frame read shares refreshed shape" (42, 180)
    (Schedule.Terminal_size_cache.get cache ~probe);
  check int "one probe per refresh, none per frame read" 3 !probes;
  let unavailable = Schedule.Terminal_size_cache.create ~fallback:(24, 80) in
  check bool "first unavailable refresh installs fallback" true
    (Schedule.Terminal_size_cache.refresh unavailable ~probe
    = Schedule.Terminal_size_cache.Changed (24, 80));
  check bool "repeated unavailable refresh is unchanged" true
    (Schedule.Terminal_size_cache.refresh unavailable ~probe
    = Schedule.Terminal_size_cache.Unchanged (24, 80))

let test_work_geometry_checks_resize_before_admission () =
  let module Size = Schedule.Terminal_size_cache in
  let pending = ref false and probes = ref 0 and physical = ref (Some (24, 80)) in
  let probe () = incr probes; !physical in
  let check_geometry () = Size.verify_for_work ~cached:(24,80)
      ~resize_changed:(fun () -> !pending) ~probe in
  check bool "current geometry may be admitted" true (check_geometry () = Size.Current);
  pending := true;
  check bool "pending resize prevents admission" true (check_geometry () = Size.Resize_interrupted);
  check int "pending resize avoids probing" 1 !probes;
  pending := false;
  physical := Some (25,80);
  check bool "physical resize requests refresh" true (check_geometry () = Size.Resize_detected);
  physical := None;
  check bool "unavailable probe retains cached geometry" true (check_geometry () = Size.Current);
  let pending_during_probe () = pending := true; Some (24,80) in
  check bool "resize during probe prevents admission" true
    (Size.verify_for_work ~cached:(24,80) ~resize_changed:(fun () -> !pending)
       ~probe:pending_during_probe = Size.Resize_interrupted);
  pending := false;
  let generation = ref 0 in
  let resized_and_consumed () = incr generation; Some (24,80) in
  check bool "consumed resize still prevents admission" true
    (Size.verify_for_work ~cached:(24,80)
       ~resize_changed:(fun () -> !pending || !generation <> 0)
       ~probe:resized_and_consumed = Size.Resize_interrupted)

let test_interrupted_input_wait_retries_until_deadline () =
  let now = ref 0L in
  let polls = ref 0 in
  let poll _remaining =
    incr polls;
    if !polls = 1 then begin
      now := ms 5;
      Schedule.Input_wait.Interrupted
    end else
      Schedule.Input_wait.Ready 'A'
  in
  check (option char) "byte survives an interrupted wait" (Some 'A')
    (Schedule.Input_wait.await ~now_ns:(fun () -> !now) ~timeout_ns:(Some (ms 16))
       ~poll);
  check int "wait retried exactly once" 2 !polls;
  now := 0L;
  let expired_poll _remaining =
    now := ms 16;
    Schedule.Input_wait.Interrupted
  in
  check (option char) "deadline stops repeated interruptions" None
    (Schedule.Input_wait.await ~now_ns:(fun () -> !now) ~timeout_ns:(Some (ms 16))
       ~poll:expired_poll);
  (* With no deadline the wait has no end of its own: an interruption polls
     again, with no time limit, until something answers. *)
  let unbounded_polls = ref [] in
  let unbounded_poll remaining =
    unbounded_polls := remaining :: !unbounded_polls;
    now := Int64.add !now (ms 1000);
    if List.length !unbounded_polls < 3 then Schedule.Input_wait.Interrupted
    else Schedule.Input_wait.Ready 'B'
  in
  check (option char) "an unbounded wait outlasts interruptions" (Some 'B')
    (Schedule.Input_wait.await ~now_ns:(fun () -> !now) ~timeout_ns:None
       ~poll:unbounded_poll);
  check (list (option (float 0.))) "every poll of an unbounded wait has no limit"
    [ None; None; None ] !unbounded_polls

let test_quit_shortcut_does_not_steal_message_input () =
  check bool "q quits outside message input" true
    (Schedule.Input_shortcut.is_quit ~message_mode:false "q");
  check bool "uppercase q quits outside message input" true
    (Schedule.Input_shortcut.is_quit ~message_mode:false "Q");
  check bool "q remains message text" false
    (Schedule.Input_shortcut.is_quit ~message_mode:true "q")

let test_consecutive_identical_events_fold_to_one_row () =
  let folded =
    Schedule.collapse_consecutive ~key:Fun.id
      [ "turn"; "refresh"; "refresh"; "refresh"; "chat"; "refresh" ]
  in
  check
    (list (pair string int))
    "runs fold to newest-with-count, order preserved"
    [ ("turn", 1); ("refresh", 3); ("chat", 1); ("refresh", 1) ]
    folded;
  check (list (pair string int)) "empty stays empty" []
    (Schedule.collapse_consecutive ~key:Fun.id [])

let test_capped_page_cannot_report_an_empty_store () =
  check bool "a capped page is not an empty store" true
    (Schedule.classify_keeper_schedule_absence ~truncated:true ~shown:20
       ~total:(Some 323)
     = Schedule.Page_capped { shown = 20; total = Some 323 });
  check bool "a whole page that matched nothing is" true
    (Schedule.classify_keeper_schedule_absence ~truncated:false ~shown:12
       ~total:(Some 12)
     = Schedule.Store_has_none)

(* The pane had one shape when one wake was all it could get. Four readings
   share the block now, and three of them are not "never woke": a load still in
   flight, a load that failed, and a schedule with attempts to list. Merging any
   of them into the empty case is how a pane reports what it has not seen. *)
let test_wake_readings_stay_four_separate_answers () =
  check bool "a load in flight is not an empty history" true
    (Schedule.classify_wake_reading ~history_error:None ~history:None
     = Schedule.Wake_last_only);
  check bool "a failed load is not an empty history either" true
    (Schedule.classify_wake_reading ~history_error:(Some "store unreadable")
       ~history:None
     = Schedule.Wake_history_failed "store unreadable");
  check bool "an answered lookup with no wakes is" true
    (Schedule.classify_wake_reading ~history_error:None ~history:(Some (0, 32))
     = Schedule.Wake_never);
  check bool "and attempts carry their ceiling" true
    (Schedule.classify_wake_reading ~history_error:None ~history:(Some (3, 32))
     = Schedule.Wake_history { count = 3; retention = 32 });
  (* An error outranks a stale list: the pane must not draw the previous
     schedule's attempts under a failure. *)
  check bool "an error outranks a list already in hand" true
    (Schedule.classify_wake_reading ~history_error:(Some "boom")
       ~history:(Some (3, 32))
     = Schedule.Wake_history_failed "boom")
;;

let test_terminal_size_retains_raw_resize_signal () =
  let cache = Schedule.Terminal_size_cache.create ~fallback:(24,80) in
  List.iter (fun cols ->
    check bool "tiny raw width change repaints even with same safe layout width" true
      (Schedule.Terminal_size_cache.refresh cache ~probe:(fun () -> Some (24,cols))
       = Schedule.Terminal_size_cache.Changed (24,4));
    check bool "same raw width stays idle" true
      (Schedule.Terminal_size_cache.refresh cache ~probe:(fun () -> Some (24,cols))
       = Schedule.Terminal_size_cache.Unchanged (24,4))) [1;2;3;4;2;1]

(* RFC tui-one-screen-grammar §8 and §10: a frame that only time asks for is
   drawn on the first whole second at or after the first change of visible
   time text, and never at or before the moment it is scheduled from. *)
let test_time_renders_on_the_second_after_the_first_change () =
  let module Time = Schedule.Time_redraw in
  check (option (float 1e-9)) "a change within a second waits for its boundary"
    (Some 101.) (Time.due ~now:99.2 (Some 100.3));
  check (option (float 1e-9)) "a change on a boundary is drawn on it" (Some 100.)
    (Time.due ~now:99.5 (Some 100.));
  check (option (float 1e-9)) "a change already passed is drawn on the next boundary"
    (Some 101.) (Time.due ~now:100.2 (Some 100.));
  check (option (float 1e-9)) "a change far ahead keeps its own boundary" (Some 160.)
    (Time.due ~now:100.2 (Some 159.01))

let test_no_time_text_schedules_nothing () =
  check (option (float 1e-9)) "a frame with no time text" None
    (Schedule.Time_redraw.due ~now:100.2 None)

module Redraw = Masc_tui_value.Redraw
module Ongoing = Masc_tui_value.Ongoing

(* The two halves the loop joins: what a frame notes while it draws a length
   that changes with time, and the second [Time_redraw.due] turns that into.
   [reading t] is the text that length shows at wall-clock [t]. The render
   must fall on the first whole second at or after the first instant the
   reading differs: by that second the reading has changed, and a second
   earlier, unless that is already behind the frame, it had not. A reading of
   these ladders holds over one stretch of time, so checking the two ends of
   the wait is enough. [settle] is how long after the render the reading is
   read: a countdown notes the instant it reaches a reading's floor and shows
   the next reading only just after it. *)
let check_first_change_second ~label ~settle ~now ~reading =
  match Schedule.Time_redraw.due ~now (Redraw.next_change ()) with
  | None -> failf "%s: a length that changes with time schedules a render" label
  | Some due ->
      check bool (label ^ ": the render comes after the frame") true (due > now);
      check bool (label ^ ": on a whole second") true (Float.is_integer due);
      check bool (label ^ ": the reading has changed by then") false
        (String.equal (reading now) (reading (due +. settle)));
      if due -. 1. >= now then
        check bool (label ^ ": and had not a second earlier") true
          (String.equal (reading now) (reading (due -. 1.)))

(* Frames are built at any instant, so the wall clock is taken on a second,
   a quarter past one and a millisecond before the next. *)
let frame_instants = [ 1_794_050_000.; 1_794_050_000.25; 1_794_050_059.999 ]

(* RFC tui-one-screen-grammar §10, the second decision test: the render
   asked of time is the first second boundary after the first visible change
   of a length still going. *)
let test_an_ongoing_length_renders_on_the_second_it_changes () =
  List.iter
    (fun now ->
      List.iter
        (fun span ->
          let at = now -. span in
          Redraw.begin_frame ();
          ignore (Ongoing.since ~now at);
          check_first_change_second ~settle:0.
            ~label:(Printf.sprintf "%.3f s ago at %.3f" span now)
            ~now ~reading:(fun t -> Ongoing.text (t -. at)))
        [ 0.; 0.3; 1.7; 59.2; 59.999; 60.; 61.5; 119.9; 3_599.2; 3_600.; 3_661.7;
          86_399.5; 86_400.; 90_061.3; 8_639_999.5; 8_640_000. ])
    frame_instants

(* The same for the narrow one-unit ladder a short column draws ([45s], [3m],
   [1h], [2d]) and the countdown it draws in the due column. *)
let test_a_narrow_length_renders_on_the_second_it_changes () =
  List.iter
    (fun now ->
      List.iter
        (fun span ->
          let at = now -. span in
          Redraw.begin_frame ();
          ignore (Ongoing.Narrow.since ~now at);
          check_first_change_second ~settle:0.
            ~label:(Printf.sprintf "narrow %.3f s ago at %.3f" span now)
            ~now ~reading:(fun t -> Ongoing.Narrow.text (t -. at)))
        [ 0.; 1.7; 59.999; 60.; 89.5; 3_599.2; 3_600.; 7_322.; 86_399.5; 90_061.3 ];
      List.iter
        (fun left ->
          let at = now +. left in
          Redraw.begin_frame ();
          ignore (Ongoing.Narrow.until ~now at);
          check_first_change_second ~settle:0.001
            ~label:(Printf.sprintf "narrow %.3f s left at %.3f" left now)
            ~now ~reading:(fun t -> Ongoing.Narrow.text (at -. t)))
        [ 1.5; 60.4; 3_661.7; 86_400.5; 190_000. ])
    frame_instants

(* The same for a countdown ("in 3m"): what is left shrinks, and its reading
   turns when what is left drops below the reading's floor. *)
let test_a_countdown_renders_on_the_second_it_changes () =
  List.iter
    (fun now ->
      List.iter
        (fun left ->
          let at = now +. left in
          Redraw.begin_frame ();
          ignore (Ongoing.until ~now at);
          check_first_change_second ~settle:0.001
            ~label:(Printf.sprintf "%.3f s left at %.3f" left now)
            ~now ~reading:(fun t -> Ongoing.text (at -. t)))
        [ 1.; 1.5; 59.9; 60.; 60.4; 125.3; 3_600.; 3_661.7; 86_400.5; 8_726_400.5 ])
    frame_instants

(* §6.2 and §8: a finished length ([243ms], [29.2s], [3m15s]) does not change
   while the reader looks, so a frame that draws only finished lengths asks
   time for nothing. An age drawn beside them does. *)
let test_finished_lengths_ask_time_for_nothing () =
  Redraw.begin_frame ();
  ignore (Masc_tui_message_layout.span_text 195.);
  ignore (Masc_tui_message_layout.elapsed_text 29.2);
  ignore (Masc_tui_message_layout.elapsed_text 0.243);
  check (option (float 1e-9)) "finished lengths schedule nothing" None
    (Schedule.Time_redraw.due ~now:1000.2 (Redraw.next_change ()));
  ignore (Masc_tui_message_layout.age_text ~now:1000.2 ~since:900.);
  check bool "an age beside them schedules a render" true
    (Option.is_some (Schedule.Time_redraw.due ~now:1000.2 (Redraw.next_change ())))

(* §8 and §10: time alone redraws at most once a second. Whatever a frame
   noted, even an instant already behind it, the render it asks for is a
   whole second strictly after the frame, so the frame built for it asks for
   the following second at the earliest. *)
let test_time_alone_renders_at_most_once_a_second () =
  List.iter
    (fun now ->
      List.iter
        (fun offset ->
          match Schedule.Time_redraw.due ~now (Some (now +. offset)) with
          | None -> fail "a noted change schedules a render"
          | Some due ->
              check bool "a whole second" true (Float.is_integer due);
              check bool "after the frame" true (due > now);
              check bool "no later than the second after the change" true
                (due <= Float.max (Float.ceil (now +. offset)) (Float.floor now +. 1.)))
        [ -5.; -0.001; 0.; 0.001; 0.4; 0.999; 1.; 59.5 ])
    frame_instants

let test_board_layout_column_order_and_hide_hearth () =
  let contains_sub hay needle =
    let len = String.length needle in
    let rec find i =
      i + len <= String.length hay
      && (String.sub hay i len = needle || find (i + 1))
    in
    find 0
  in
  let wide =
    Masc_tui_render_schedule.board_layout ~hide_hearth:false
      ~sort_column:Sort_score ~inner_width:140
  in
  check bool "wide layout places metadata ahead of title and counters after" true
    (wide.shown
     = [ Masc_tui_render_schedule.Board_mark
       ; Board_age
       ; Board_author
       ; Board_hearth
       ; Board_title
       ; Board_score
       ; Board_replies
       ]);
  check int "wide layout drops nothing" 0 wide.dropped;
  let narrowed =
    Masc_tui_render_schedule.board_layout ~hide_hearth:true
      ~sort_column:Sort_score ~inner_width:140
  in
  check bool "hide_hearth omits Board_hearth" false
    (List.mem Masc_tui_render_schedule.Board_hearth narrowed.shown);
  check int "hide_hearth does not count omitted hearth as dropped" 0 narrowed.dropped;
  check bool "hide_hearth gives freed cells to title" true
    (narrowed.flex_width > wide.flex_width);
  let tight =
    Masc_tui_render_schedule.board_layout ~hide_hearth:false
      ~sort_column:Sort_age ~inner_width:50
  in
  check bool "narrow layout preserves 30-cell title floor" true
    (tight.flex_width >= 30);
  check bool "narrow layout keeps mark, age, and title" true
    (List.mem Masc_tui_render_schedule.Board_mark tight.shown
     && List.mem Masc_tui_render_schedule.Board_age tight.shown
     && List.mem Masc_tui_render_schedule.Board_title tight.shown);
  (* At 80 cols (inner_width = 76), active sort column stays visible and
     board_header_row_with_dropped places the dropped badge inside TITLE's slack
     without overwriting the rightmost right-aligned header or its sort arrow. *)
  let at_80_score =
    Masc_tui_render_schedule.board_layout ~hide_hearth:false
      ~sort_column:Sort_score ~inner_width:76
  in
  check bool "80 cols under Sort_score keeps Board_score visible" true
    (List.mem Masc_tui_render_schedule.Board_score at_80_score.shown);
  let hdr_80_en =
    Masc_tui_render_schedule.board_header_row_with_dropped ~sort_column:Sort_score
      ~ko:false ~inner_width:76 ~age_header:"AGE" ~layout:at_80_score
  in
  check int "80-col EN dropped header fits exact inner_width" 76
    (Masc_tui_message_layout.display_width hdr_80_en);
  check bool "80-col EN dropped header keeps SCORE ↓ intact" true
    (contains_sub hdr_80_en "SCORE \xe2\x86\x93");
  check bool "80-col EN dropped header shows dropped badge" true
    (contains_sub hdr_80_en "2 more cols");
  let hdr_80_ko =
    Masc_tui_render_schedule.board_header_row_with_dropped ~sort_column:Sort_score
      ~ko:true ~inner_width:76 ~age_header:"게시 후" ~layout:at_80_score
  in
  check int "80-col KO dropped header fits exact inner_width" 76
    (Masc_tui_message_layout.display_width hdr_80_ko);
  check bool "80-col KO dropped header keeps 점수 ↓ intact" true
    (contains_sub hdr_80_ko "점수 \xe2\x86\x93");
  let at_80_replies =
    Masc_tui_render_schedule.board_layout ~hide_hearth:false
      ~sort_column:Sort_replies ~inner_width:76
  in
  check bool "80 cols under Sort_replies keeps Board_replies visible" true
    (List.mem Masc_tui_render_schedule.Board_replies at_80_replies.shown);
  let hdr_80_replies =
    Masc_tui_render_schedule.board_header_row_with_dropped ~sort_column:Sort_replies
      ~ko:false ~inner_width:76 ~age_header:"AGE" ~layout:at_80_replies
  in
  check bool "80-col Sort_replies header keeps REPLIES↓ intact" true
    (contains_sub hdr_80_replies "REPLIES\xe2\x86\x93");
  let at_90 =
    Masc_tui_render_schedule.board_layout ~hide_hearth:false
      ~sort_column:Sort_replies ~inner_width:86
  in
  let hdr_90 =
    Masc_tui_render_schedule.board_header_row_with_dropped ~sort_column:Sort_replies
      ~ko:false ~inner_width:86 ~age_header:"AGE" ~layout:at_90
  in
  check int "90-col dropped header fits exact inner_width" 86
    (Masc_tui_message_layout.display_width hdr_90);
  check bool "90-col dropped header keeps REPLIES↓ intact" true
    (contains_sub hdr_90 "REPLIES\xe2\x86\x93");
  let narrow_36 =
    Masc_tui_render_schedule.board_layout ~hide_hearth:false
      ~sort_column:Masc_tui_render_schedule.Sort_score ~inner_width:36
  in
  let hdr_36_en =
    Masc_tui_render_schedule.board_header_row_with_dropped
      ~sort_column:Masc_tui_render_schedule.Sort_score ~ko:false
      ~inner_width:36 ~age_header:"AGE" ~layout:narrow_36
  in
  check bool "36-col EN dropped header fits inner_width" true
    (Masc_tui_message_layout.display_width hdr_36_en <= 36);
  check bool "36-col EN dropped header preserves badge" true
    (contains_sub hdr_36_en "4 more cols");
  let hdr_36_ko =
    Masc_tui_render_schedule.board_header_row_with_dropped
      ~sort_column:Masc_tui_render_schedule.Sort_score ~ko:true
      ~inner_width:36 ~age_header:"게시 후" ~layout:narrow_36
  in
  check bool "36-col KO dropped header fits inner_width" true
    (Masc_tui_message_layout.display_width hdr_36_ko <= 36);
  check bool "36-col KO dropped header preserves badge" true
    (contains_sub hdr_36_ko "외 4열");
  List.iter
    (fun (ko, age_header) ->
      List.iter
        (fun sort_column ->
          let row =
            Masc_tui_render_schedule.board_header_row ~sort_column ~ko
              ~age_header ~layout:wide
          in
          check int "header width matches inner width" 140
            (Masc_tui_message_layout.display_width row);
          check bool "active sort column carries arrow"
            (sort_column <> Masc_tui_render_schedule.Sort_none)
            (contains_sub row "\xe2\x86\x93"))
        [ Masc_tui_render_schedule.Sort_none; Sort_age; Sort_score; Sort_replies ])
    [ false, "AGE"; false, "MOVED"; true, "게시 후"; true, "변경 후" ]

let () =
  test_terminal_size_retains_raw_resize_signal ();
  test_terminal_size_retains_raw_resize_signal ();
  run "tui_render_schedule"
    [ ( "render scheduling"
      , [ test_case "time renders on the second after the first change" `Quick
            test_time_renders_on_the_second_after_the_first_change
        ; test_case "no time text schedules nothing" `Quick
            test_no_time_text_schedules_nothing
        ; test_case "an ongoing length renders on the second it changes" `Quick
            test_an_ongoing_length_renders_on_the_second_it_changes
        ; test_case "a countdown renders on the second it changes" `Quick
            test_a_countdown_renders_on_the_second_it_changes
        ; test_case "a narrow length renders on the second it changes" `Quick
            test_a_narrow_length_renders_on_the_second_it_changes
        ; test_case "finished lengths ask time for nothing" `Quick
            test_finished_lengths_ask_time_for_nothing
        ; test_case "time alone renders at most once a second" `Quick
            test_time_alone_renders_at_most_once_a_second
        ; test_case "idle performs no render work" `Quick
            test_idle_has_no_render_work
        ; test_case "1000 invalidations coalesce" `Quick
            test_burst_coalesces_to_one_frame
        ; test_case "input after idle is immediate" `Quick
            test_input_after_idle_renders_immediately
        ; test_case "a recent frame does not delay a keypress" `Quick
            test_input_does_not_wait_for_recent_frame
        ; test_case "separate repeated inputs render when drained" `Quick
            test_separate_repeated_inputs_render_when_drained
        ; test_case "continuous input is paced and final input is immediate" `Quick
            test_continuous_input_is_paced_and_final_input_is_immediate
        ; test_case "overrun leaves a window to consume queued input" `Quick
            test_overrun_leaves_a_window_to_consume_pending_input
        ; test_case "completion preserves pending work and force" `Quick
            test_completion_keeps_requests_and_force_preempts_it
        ; test_case "completion preserves background and deferred pacing" `Quick
            test_completion_preserves_background_and_deferred_pacing
        ; test_case "buffered input paints when drained" `Quick
            test_buffered_input_renders_when_drained
        ; test_case "dirty input wait uses the frame deadline" `Quick
            test_dirty_timeout_wakes_at_deadline
        ; test_case "input preempts a pending background frame" `Quick
            test_input_preempts_pending_background_frame
        ; test_case "input byte bursts stay inside one frame" `Quick
            test_input_burst_stays_inside_one_frame_window
        ; test_case "terminal size is cached until resize" `Quick
            test_terminal_size_cache_reprobes_only_after_invalidation
        ; test_case "terminal size refresh keeps last valid shape" `Quick
            test_terminal_size_cache_refreshes_without_losing_last_valid
        ; test_case "work admission checks terminal resize" `Quick
            test_work_geometry_checks_resize_before_admission
        ; test_case "interrupted input waits retry" `Quick
            test_interrupted_input_wait_retries_until_deadline
        ; test_case "quit shortcut preserves message input" `Quick
            test_quit_shortcut_does_not_steal_message_input
        ; test_case "consecutive identical events fold to one row" `Quick
            test_consecutive_identical_events_fold_to_one_row
        ; test_case "a capped page cannot report an empty store" `Quick
            test_capped_page_cannot_report_an_empty_store
        ; test_case "wake readings stay four separate answers" `Quick
            test_wake_readings_stay_four_separate_answers
        ; test_case "board layout column order, hide_hearth, and sort arrow" `Quick
            test_board_layout_column_order_and_hide_hearth
        ;] )
    ]
