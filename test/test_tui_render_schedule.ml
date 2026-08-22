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
  check_render "initial frame" (Schedule.take schedule ~now_ns:0L);
  for offset = 1 to 1000 do
    check_idle "one second idle" (Schedule.take schedule ~now_ns:(ms offset))
  done;
  check (float 0.000_001) "idle keeps the maximum input wait" 0.1
    (Schedule.input_timeout_seconds schedule ~now_ns:(ms 1000) ~maximum:0.1)

let test_burst_coalesces_to_one_frame () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take schedule ~now_ns:0L);
  for offset = 1 to 1000 do
    Schedule.request schedule Schedule.Background;
    match Schedule.take schedule ~now_ns:(Int64.of_int offset) with
    | Schedule.Wait_until due -> check int64 "stable deadline" (ms 16) due
    | Schedule.Idle -> fail "dirty burst became idle"
    | Schedule.Render -> fail "dirty burst rendered before its frame deadline"
  done;
  check_render "one coalesced frame"
    (Schedule.take schedule ~now_ns:(ms 16));
  check_idle "burst is consumed"
    (Schedule.take schedule ~now_ns:(ms 17))

let test_input_after_idle_renders_immediately () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take schedule ~now_ns:0L);
  Schedule.request schedule Schedule.Input;
  check_render "input after idle"
    (Schedule.take schedule ~now_ns:(ms 1000))

let test_dirty_timeout_wakes_at_deadline () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take schedule ~now_ns:0L);
  Schedule.request schedule Schedule.Background;
  check (float 0.000_001) "deadline caps the select wait" 0.006
    (Schedule.input_timeout_seconds schedule ~now_ns:(ms 10) ~maximum:0.1)

let test_input_preempts_pending_background_frame () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take schedule ~now_ns:0L);
  Schedule.request schedule Schedule.Background;
  (match Schedule.take schedule ~now_ns:(ms 2) with
   | Schedule.Wait_until due -> check int64 "background deadline" (ms 16) due
   | Schedule.Idle -> fail "background request became idle"
   | Schedule.Render -> fail "background request rendered too early");
  Schedule.request schedule Schedule.Input;
  check_render "input preempts background deadline"
    (Schedule.take schedule ~now_ns:(ms 2))

let test_input_burst_stays_inside_one_frame_window () =
  let schedule = Schedule.create ~min_interval_ns:(ms 16) () in
  check_render "initial frame" (Schedule.take schedule ~now_ns:0L);
  for offset = 1 to 1000 do
    Schedule.request schedule Schedule.Input;
    match Schedule.take schedule ~now_ns:(Int64.of_int offset) with
    | Schedule.Wait_until due -> check int64 "input deadline" (ms 16) due
    | Schedule.Idle -> fail "input request became idle"
    | Schedule.Render -> fail "input byte burst rendered before the deadline"
  done;
  check_render "coalesced input frame"
    (Schedule.take schedule ~now_ns:(ms 16))

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
  check (pair int int) "probe failure uses fallback" (24, 80)
    (Schedule.Terminal_size_cache.get cache ~probe)

let test_render_widths_are_total () =
  check int "negative width clamps to zero" 0 (Schedule.nonnegative_width (-1));
  check int "tiny keeper panel has an empty context bar" 0
    (Schedule.keeper_context_bar_width ~inner_width:0);
  check int "context bar remains bounded" 30
    (Schedule.keeper_context_bar_width ~inner_width:100)

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

let test_global_shortcuts_do_not_steal_message_input () =
  check bool "q quits outside message input" true
    (Schedule.Input_shortcut.is_quit ~message_mode:false "q");
  check bool "uppercase q quits outside message input" true
    (Schedule.Input_shortcut.is_quit ~message_mode:false "Q");
  check bool "2 opens Keepers outside message input" true
    (Schedule.Input_shortcut.opens_keepers ~message_mode:false "2");
  check bool "q remains message text" false
    (Schedule.Input_shortcut.is_quit ~message_mode:true "q");
  check bool "2 remains message text" false
    (Schedule.Input_shortcut.opens_keepers ~message_mode:true "2");
  check bool "unrelated key is not a shortcut" false
    (Schedule.Input_shortcut.opens_keepers ~message_mode:false "x")

let test_compact_viewport_uses_largest_fixed_chrome_budget () =
  check int "minimum fixed chrome height" 14
    Schedule.Viewport.minimum_fixed_chrome_rows;
  check bool "thirteen rows use the compact frame" true
    (Schedule.Viewport.requires_compact_frame ~rows:13);
  check bool "fourteen rows restore the selected surface" false
    (Schedule.Viewport.requires_compact_frame ~rows:14);
  check bool "normal terminals keep the selected surface" false
    (Schedule.Viewport.requires_compact_frame ~rows:30)

let overview_frame_rows ~has_cluster
    (allocation : Schedule.overview_allocation) =
  10
  + (if has_cluster then 1 else 0)
  + allocation.attention_rows
  + allocation.task_error_rows
  + allocation.task_rows

let test_overview_rows_share_one_viewport_budget () =
  let max_data =
    Schedule.allocate_overview ~terminal_rows:14 ~has_cluster:true
      ~attention_count:6 ~event_count:0 ~task_count:5 ~has_task_error:false
  in
  check int "14-row attention allocation" 2 max_data.attention_rows;
  check int "14-row task allocation" 1 max_data.task_rows;
  check int "14-row error allocation" 0 max_data.task_error_rows;
  check int "14-row frame is exact" 14
    (overview_frame_rows ~has_cluster:true max_data);
  let task_error =
    Schedule.allocate_overview ~terminal_rows:14 ~has_cluster:true
      ~attention_count:6 ~event_count:0 ~task_count:5 ~has_task_error:true
  in
  check int "task error keeps its reserved row" 1
    task_error.task_error_rows;
  check int "task error precedes ordinary task rows" 0 task_error.task_rows;
  check int "task error frame is exact" 14
    (overview_frame_rows ~has_cluster:true task_error);
  let full =
    Schedule.allocate_overview ~terminal_rows:22 ~has_cluster:true
      ~attention_count:6 ~event_count:0 ~task_count:5 ~has_task_error:false
  in
  check int "full viewport restores attention cap" 6 full.attention_rows;
  check int "full viewport restores task cap" 5 full.task_rows;
  let events_only =
    Schedule.allocate_overview ~terminal_rows:22 ~has_cluster:true
      ~attention_count:0 ~event_count:6 ~task_count:5 ~has_task_error:false
  in
  check int "events size the shared panel" 6 events_only.attention_rows;
  check int "events preserve full task rows" 5 events_only.task_rows;
  let mixed_panel =
    Schedule.allocate_overview ~terminal_rows:22 ~has_cluster:true
      ~attention_count:2 ~event_count:4 ~task_count:5 ~has_task_error:false
  in
  check int "the longer panel column determines shared rows" 4
    mixed_panel.attention_rows;
  check int "mixed panel counts preserve full task rows" 5 mixed_panel.task_rows;
  let compact_events_only =
    Schedule.allocate_overview ~terminal_rows:14 ~has_cluster:true
      ~attention_count:0 ~event_count:6 ~task_count:5 ~has_task_error:false
  in
  check int "compact events use remaining panel rows" 2
    compact_events_only.attention_rows;
  check int "compact events preserve one task row" 1
    compact_events_only.task_rows;
  for terminal_rows = 14 to 40 do
    List.iter
      (fun has_cluster ->
        for attention_count = 0 to 8 do
          for event_count = 0 to 8 do
            for task_count = 0 to 7 do
              List.iter
                (fun has_task_error ->
                  let allocation =
                    Schedule.allocate_overview ~terminal_rows ~has_cluster
                      ~attention_count ~event_count ~task_count ~has_task_error
                  in
                  let total = overview_frame_rows ~has_cluster allocation in
                  if total > terminal_rows then
                    failf
                      "overview exceeds viewport: rows=%d cluster=%b attention=%d events=%d tasks=%d error=%b total=%d"
                      terminal_rows has_cluster attention_count event_count
                      task_count has_task_error total;
                  if
                    allocation.attention_rows < 0
                    || allocation.task_error_rows < 0
                    || allocation.task_rows < 0
                  then
                    failf "overview allocation became negative at rows=%d"
                      terminal_rows)
                [ false; true ]
            done
          done
        done)
      [ false; true ]
  done

let board_read_frame_rows ~comment_count
    (allocation : Schedule.board_read_allocation) =
  8
  + (if comment_count > 0 then 2 else 0)
  + allocation.body_rows
  + allocation.comment_rows

let test_board_read_rows_reserve_comments_and_footer () =
  let crowded =
    Schedule.allocate_board_read ~terminal_rows:14 ~body_line_count:10
      ~comment_count:5
  in
  check int "14-row board keeps one body row" 1 crowded.body_rows;
  check int "14-row board fits three comments" 3 crowded.comment_rows;
  check int "14-row board frame is exact" 14
    (board_read_frame_rows ~comment_count:5 crowded);
  let comments_only =
    Schedule.allocate_board_read ~terminal_rows:14 ~body_line_count:0
      ~comment_count:5
  in
  check int "empty body consumes no semantic row" 0 comments_only.body_rows;
  check int "empty body frees a fourth comment row" 4
    comments_only.comment_rows;
  let no_comments =
    Schedule.allocate_board_read ~terminal_rows:14 ~body_line_count:10
      ~comment_count:0
  in
  check int "comment-free board uses the full body viewport" 6
    no_comments.body_rows;
  let full_comments =
    Schedule.allocate_board_read ~terminal_rows:16 ~body_line_count:10
      ~comment_count:5
  in
  check int "16-row board restores comment cap" 5
    full_comments.comment_rows;
  for terminal_rows = 14 to 40 do
    for body_line_count = 0 to 10 do
      for comment_count = 0 to 10 do
        let allocation =
          Schedule.allocate_board_read ~terminal_rows ~body_line_count
            ~comment_count
        in
        let total = board_read_frame_rows ~comment_count allocation in
        if total <> terminal_rows then
          failf
            "board-read does not fill viewport: rows=%d body=%d comments=%d total=%d"
            terminal_rows body_line_count comment_count total;
        if body_line_count > 0 && allocation.body_rows < 1 then
          failf "board-read hid a nonempty body at rows=%d comments=%d"
            terminal_rows comment_count;
        if
          allocation.comment_rows < 0
          || allocation.comment_rows > min 5 comment_count
        then
          failf "board-read comment allocation escaped its cap";
        let last =
          Schedule.project_board_read_scroll ~body_line_count
            ~body_rows:allocation.body_rows ~comment_count
            ~comment_rows:allocation.comment_rows max_int
        in
        if last.comment_offset + allocation.comment_rows <> comment_count then
          failf
            "board-read cannot reach the last comment: rows=%d body=%d comments=%d"
            terminal_rows body_line_count comment_count;
        if
          body_line_count > allocation.body_rows
          && last.body_offset + allocation.body_rows <> body_line_count
        then
          failf "board-read cannot reach the last body row"
      done
    done
  done

let test_board_read_scroll_reaches_hidden_comments () =
  let allocation =
    Schedule.allocate_board_read ~terminal_rows:14 ~body_line_count:1
      ~comment_count:5
  in
  let first =
    Schedule.project_board_read_scroll ~body_line_count:1
      ~body_rows:allocation.body_rows ~comment_count:5
      ~comment_rows:allocation.comment_rows 0
  in
  check int "initial body offset" 0 first.body_offset;
  check int "initial comment offset" 0 first.comment_offset;
  let last =
    Schedule.project_board_read_scroll ~body_line_count:1
      ~body_rows:allocation.body_rows ~comment_count:5
      ~comment_rows:allocation.comment_rows 99
  in
  check int "overscroll normalizes to the combined maximum" 2
    last.normalized_scroll;
  check int "one-line body remains visible" 0 last.body_offset;
  check int "last comment becomes visible" 2 last.comment_offset;
  let long_body =
    Schedule.project_board_read_scroll ~body_line_count:10 ~body_rows:1
      ~comment_count:5 ~comment_rows:3 10
  in
  check int "body scroll is consumed first" 9 long_body.body_offset;
  check int "remaining scroll advances comments" 1
    long_body.comment_offset;
  let negative =
    Schedule.project_board_read_scroll ~body_line_count:10 ~body_rows:1
      ~comment_count:5 ~comment_rows:3 (-1)
  in
  check int "negative scroll normalizes to zero" 0
    negative.normalized_scroll

let test_keeper_detail_scroll_normalizes_across_bounds () =
  let normalize = Schedule.normalize_keeper_detail_scroll in
  let bottom = normalize ~line_count:29 ~content_height:14 max_int in
  check int "overscroll reaches the exact bottom" 15 bottom;
  let resized = normalize ~line_count:29 ~content_height:15 bottom in
  check int "larger viewport clamps the persisted bottom" 14 resized;
  check int "one upward action reveals the previous row" 13
    (max 0 (resized - 1));
  let measured = normalize ~line_count:31 ~content_height:15 max_int in
  check int "measured context adds two scroll positions" 16 measured;
  check int "content shrink clamps to its new bottom" 14
    (normalize ~line_count:29 ~content_height:15 measured);
  check int "content growth preserves the current offset" 14
    (normalize ~line_count:31 ~content_height:15 resized);
  check int "negative raw state normalizes to zero" 0
    (normalize ~line_count:29 ~content_height:15 (-1));
  check int "fully visible content cannot scroll" 0
    (normalize ~line_count:10 ~content_height:15 max_int)

let () =
  run "tui_render_schedule"
    [ ( "render scheduling"
      , [ test_case "idle performs no render work" `Quick
            test_idle_has_no_render_work
        ; test_case "1000 invalidations coalesce" `Quick
            test_burst_coalesces_to_one_frame
        ; test_case "input after idle is immediate" `Quick
            test_input_after_idle_renders_immediately
        ; test_case "dirty input wait uses the frame deadline" `Quick
            test_dirty_timeout_wakes_at_deadline
        ; test_case "input preempts a pending background frame" `Quick
            test_input_preempts_pending_background_frame
        ; test_case "input byte bursts stay inside one frame" `Quick
            test_input_burst_stays_inside_one_frame_window
        ; test_case "terminal size is cached until resize" `Quick
            test_terminal_size_cache_reprobes_only_after_invalidation
        ; test_case "derived render widths are total" `Quick
            test_render_widths_are_total
        ; test_case "interrupted input waits retry" `Quick
            test_interrupted_input_wait_retries_until_deadline
        ; test_case "global shortcuts preserve message input" `Quick
            test_global_shortcuts_do_not_steal_message_input
        ; test_case "compact viewport follows fixed chrome budget" `Quick
            test_compact_viewport_uses_largest_fixed_chrome_budget
        ; test_case "overview rows share one viewport budget" `Quick
            test_overview_rows_share_one_viewport_budget
        ; test_case "board read reserves comments and footer" `Quick
            test_board_read_rows_reserve_comments_and_footer
        ; test_case "board read reaches hidden comments" `Quick
            test_board_read_scroll_reaches_hidden_comments
        ; test_case "keeper detail scroll follows current bounds" `Quick
            test_keeper_detail_scroll_normalizes_across_bounds
        ] )
    ]
