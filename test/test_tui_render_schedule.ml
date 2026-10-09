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
  check (float 0.000_001) "idle keeps the maximum input wait" 0.1
    (Schedule.input_timeout_seconds schedule ~now_ns:(ms 1000) ~maximum:0.1)

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
  check (float 0.0) "first input does not sleep" 0.0
    (Schedule.input_timeout_seconds schedule ~now_ns:1L ~maximum:0.1);
  check_render "keypress immediately after a background frame"
    (Schedule.take ~input_pending:false schedule ~now_ns:1L)

let test_separate_repeated_inputs_render_when_drained () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take ~input_pending:false schedule ~now_ns:0L);
  Schedule.request schedule Schedule.Input;
  check_render "first input is immediate" (Schedule.take ~input_pending:false schedule ~now_ns:(ms 1));
  Schedule.request schedule Schedule.Input;
  check (float 0.0) "handled input does not sleep for the frame deadline" 0.0
    (Schedule.input_timeout_seconds schedule ~now_ns:(ms 6) ~maximum:0.1);
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
  check (float 0.0) "reader can block once input is presented" 0.1
    (Schedule.input_timeout_seconds schedule ~now_ns:(ms 1002) ~maximum:0.1)

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
  check (float 0.000_001) "deadline caps the select wait" 0.006
    (Schedule.input_timeout_seconds schedule ~now_ns:(ms 10) ~maximum:0.1)

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
    (Schedule.Input_wait.await ~now_ns:(fun () -> !now) ~timeout_ns:(ms 16)
       ~poll);
  check int "wait retried exactly once" 2 !polls;
  now := 0L;
  let expired_poll _remaining =
    now := ms 16;
    Schedule.Input_wait.Interrupted
  in
  check (option char) "deadline stops repeated interruptions" None
    (Schedule.Input_wait.await ~now_ns:(fun () -> !now) ~timeout_ns:(ms 16)
       ~poll:expired_poll)

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

type cell_edge =
  | Left_edge
  | Right_edge

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

let () =
  run "tui_render_schedule"
    [ ( "render scheduling"
      , [ test_case "idle performs no render work" `Quick
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
        ;] )
    ]
