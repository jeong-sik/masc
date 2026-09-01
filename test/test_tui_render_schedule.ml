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

let test_quit_shortcut_does_not_steal_message_input () =
  check bool "q quits outside message input" true
    (Schedule.Input_shortcut.is_quit ~message_mode:false "q");
  check bool "uppercase q quits outside message input" true
    (Schedule.Input_shortcut.is_quit ~message_mode:false "Q");
  check bool "q remains message text" false
    (Schedule.Input_shortcut.is_quit ~message_mode:true "q")

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
  + allocation.filler_rows

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

(* The frame is exactly as tall as the terminal, at every size and whatever
   the data. Short of it, the surface stops partway down the screen and leaves
   the footer stranded in the middle; over it, the terminal scrolls and the top
   of the frame is lost. *)
let test_overview_frame_always_fills_the_terminal () =
  List.iter
    (fun has_cluster ->
       List.iter
         (fun (attention_count, event_count, task_count, has_task_error) ->
            for terminal_rows = 14 to 80 do
              let allocation =
                Schedule.allocate_overview ~terminal_rows ~has_cluster
                  ~attention_count ~event_count ~task_count ~has_task_error
              in
              check int
                (Printf.sprintf "rows %d cluster %b data %d/%d/%d/%b"
                   terminal_rows has_cluster attention_count event_count
                   task_count has_task_error)
                terminal_rows
                (overview_frame_rows ~has_cluster allocation)
            done)
         [ (0, 0, 0, false)
         ; (0, 0, 0, true)
         ; (6, 0, 5, false)
         ; (0, 6, 5, false)
         ; (40, 40, 40, true)
         ; (1, 1, 1, false)
         ])
    [ true; false ]

(* A long attention list must not take the whole viewport: the backlog is the
   other half of what this surface answers. The panel is bounded, so a list of
   eighty costs the backlog nothing. *)
let test_overview_task_block_keeps_a_share_of_a_tall_viewport () =
  let crowded =
    Schedule.allocate_overview ~terminal_rows:60 ~has_cluster:true
      ~attention_count:80 ~event_count:0 ~task_count:20 ~has_task_error:false
  in
  check int "the panel stops at its ceiling" 6 crowded.attention_rows;
  check int "every task is still drawn" 20 crowded.task_rows

(* The task block is bounded by its item count rather than by a constant, so a
   tall terminal shows the whole backlog and pads the rest. The panel keeps its
   ceiling: rows past the sixth are scrolled to, not read at a glance. *)
let test_overview_blocks_grow_to_their_item_counts () =
  let roomy =
    Schedule.allocate_overview ~terminal_rows:60 ~has_cluster:true
      ~attention_count:9 ~event_count:0 ~task_count:12 ~has_task_error:false
  in
  check int "the panel stops at its ceiling" 6 roomy.attention_rows;
  check int "every task is drawn" 12 roomy.task_rows;
  check bool "the remainder becomes filler" true (roomy.filler_rows > 0)

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
  (* A tall terminal is where the old flat five hurt: a forty-reply thread got
     the same five rows on an eighty-row screen as on a twenty-row one. The
     share grows with the height, and the post still keeps the larger half. *)
  let tall =
    Schedule.allocate_board_read ~terminal_rows:60 ~body_line_count:200
      ~comment_count:40
  in
  check int "a tall pane gives comments a share, not a constant" 16
    tall.comment_rows;
  check bool "the post still keeps the larger part" true
    (tall.body_rows > tall.comment_rows);
  let few_comments =
    Schedule.allocate_board_read ~terminal_rows:60 ~body_line_count:200
      ~comment_count:3
  in
  check int "a short thread takes only what it has" 3
    few_comments.comment_rows;
  (* Rows the body cannot use are the comments'. This pane held twenty-four
     rows of filler under a ten-line post while the thread was cut at five. *)
  let short_post =
    Schedule.allocate_board_read ~terminal_rows:60 ~body_line_count:10
      ~comment_count:40
  in
  check int "a short post hands its unused rows to the thread" 40
    short_post.comment_rows;
  check int "the body keeps exactly the rows it has" 10 short_post.body_rows;
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
        let ceiling =
          let chrome = if comment_count > 0 then 2 else 0 in
          let available = max 0 (terminal_rows - 8 - chrome) in
          max 5 (max (available - body_line_count) (available / 3))
        in
        if
          allocation.comment_rows < 0
          || allocation.comment_rows > min ceiling comment_count
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

let test_overview_event_window_follows_and_preserves_anchor () =
  let project = Schedule.project_overview_event_window in
  let bottom = project ~event_count:6 ~visible_rows:2 max_int in
  check int "overscroll reaches oldest retained pair" 4 bottom.oew_offset;
  check int "oldest range begins at five" 5 bottom.oew_first_position;
  check int "oldest range ends at six" 6 bottom.oew_last_position;
  let newer = project ~event_count:6 ~visible_rows:2 3 in
  check int "one upward action moves one row" 3 newer.oew_offset;
  check int "one upward range begins at four" 4 newer.oew_first_position;
  check int "one upward range ends at five" 5 newer.oew_last_position;
  check int "older input saturates at the bottom" 4
    (Schedule.scroll_overview_events_older ~event_count:6 ~visible_rows:2
       bottom.oew_offset);
  check int "newer input moves from the bounded bottom" 3
    (Schedule.scroll_overview_events_newer ~event_count:6 ~visible_rows:2
       (Schedule.scroll_overview_events_older ~event_count:6 ~visible_rows:2
          bottom.oew_offset));
  let expanded = project ~event_count:6 ~visible_rows:6 bottom.oew_offset in
  check int "larger viewport clamps to newest" 0 expanded.oew_offset;
  check int "expanded range starts at one" 1 expanded.oew_first_position;
  check int "expanded range shows all events" 6 expanded.oew_last_position;
  let anchored_scroll =
    Schedule.overview_event_offset_after_prepend ~retained_count:7
      bottom.oew_offset
  in
  let anchored = project ~event_count:7 ~visible_rows:2 anchored_scroll in
  check int "prepend advances a manual anchor" 5 anchored.oew_offset;
  check int "anchored range starts at six" 6 anchored.oew_first_position;
  check int "anchored range retains the old tail" 7 anchored.oew_last_position;
  check int "newest-following offset stays at zero" 0
    (Schedule.overview_event_offset_after_prepend ~retained_count:7 0);
  check int "negative raw anchor normalizes to zero" 0
    (Schedule.overview_event_offset_after_prepend ~retained_count:7 (-1));
  check int "retention cap bounds pathological anchor" 10
    (Schedule.overview_event_offset_after_prepend ~retained_count:11 max_int);
  let shrunk = project ~event_count:1 ~visible_rows:2 bottom.oew_offset in
  check int "content shrink clamps to newest" 0 shrunk.oew_offset;
  check int "single event starts at one" 1 shrunk.oew_first_position;
  check int "single event ends at one" 1 shrunk.oew_last_position;
  let empty = project ~event_count:0 ~visible_rows:2 max_int in
  check int "empty events have zero offset" 0 empty.oew_offset;
  check int "empty events have no first position" 0 empty.oew_first_position;
  check int "empty events have no last position" 0 empty.oew_last_position;
  let hidden = project ~event_count:1 ~visible_rows:0 1 in
  check int "zero-row window retains a bounded offset" 1 hidden.oew_offset;
  check int "zero-row window has no first position" 0 hidden.oew_first_position;
  check int "zero-row window has no last position" 0 hidden.oew_last_position;
  check int "zero-row older input saturates without overflow" max_int
    (Schedule.scroll_overview_events_older ~event_count:max_int ~visible_rows:0
       max_int);
  check int "negative retained count cannot overflow" 0
    (Schedule.overview_event_offset_after_prepend ~retained_count:min_int 1)

(* Below the narrowest row the allocation cannot shrink further; the frame
   shows a resize gate at those sizes rather than a roster. *)
let keeper_minimum_row_width =
  Schedule.keeper_columns_used_width
    (Schedule.allocate_keeper_columns ~inner_width:0)

(* The row must never be wider than the box that holds it: the renderer fits
   each cell to these budgets, so a total over [inner_width] pushes the right
   border off the frame and the border column moves from row to row. *)
let test_keeper_columns_never_exceed_their_width () =
  for inner_width = 0 to 400 do
    let columns = Schedule.allocate_keeper_columns ~inner_width in
    let used = Schedule.keeper_columns_used_width columns in
    check bool
      (Printf.sprintf "inner %d fits (used %d)" inner_width used)
      true
      (used <= max inner_width keeper_minimum_row_width)
  done

(* Every cell of slack has to land in exactly one column. A total short of the
   width leaves a ragged gap before the border; a total over it overflows. *)
let test_keeper_columns_consume_the_whole_width () =
  for inner_width = keeper_minimum_row_width to 400 do
    let columns = Schedule.allocate_keeper_columns ~inner_width in
    check int
      (Printf.sprintf "inner %d is fully allocated" inner_width)
      inner_width
      (Schedule.keeper_columns_used_width columns)
  done

(* Columns drop from the right, and identity never drops. *)
let test_keeper_columns_drop_from_the_right () =
  let narrow = Schedule.allocate_keeper_columns ~inner_width:70 in
  check bool "no flags when narrow" false narrow.kcol_show_flags;
  check bool "no runtime when narrow" false narrow.kcol_show_runtime;
  check bool "the name still has cells" true (narrow.kcol_name > 0);
  let medium = Schedule.allocate_keeper_columns ~inner_width:100 in
  check bool "flags return first" true medium.kcol_show_flags;
  check bool "runtime is still out" false medium.kcol_show_runtime;
  let wide = Schedule.allocate_keeper_columns ~inner_width:150 in
  check bool "runtime returns when wide" true wide.kcol_show_runtime;
  check bool "a dropped column costs no cells" true (medium.kcol_runtime = 0)

(* The name column never shrinks as the terminal widens. A width that added a
   column while narrowing the name would make the same keeper unreadable on the
   larger terminal. *)
let test_keeper_name_width_never_shrinks_as_the_terminal_grows () =
  let previous = ref 0 in
  for inner_width = keeper_minimum_row_width to 400 do
    let name = (Schedule.allocate_keeper_columns ~inner_width).kcol_name in
    check bool
      (Printf.sprintf "inner %d keeps the name at least as wide" inner_width)
      true (name >= !previous);
    previous := name
  done

(* The strip named five stops while the Planning walk had three: Schedules and
   Fusion had become tabs of the selected Keeper and nothing took their names
   off this row. A reader pressing 4 or 5 arrived nowhere. *)
let test_planning_strip_names_only_its_own_stops () =
  check (list string) "three stops, and Schedules and Fusion are not among them"
    [ "1 Goals"; "2 Task Review"; "3 Evaluator Verdicts" ]
    (Schedule.planning_strip_plain ~tab:Schedule.Planning_goals
       ~review_count:None ~window:"")

(* The verdict page count read as a Fusion count: it was appended after the
   whole strip, and the strip ended with "5 Fusion". A window belongs to the
   tab the reader is on and to no other. *)
let test_planning_window_rides_the_active_stop () =
  check (list string) "the window sits on Verdicts"
    [ "1 Goals"; "2 Task Review\xc2\xb7979"; "3 Evaluator Verdicts (8 of 4223)" ]
    (Schedule.planning_strip_plain ~tab:Schedule.Planning_verdicts
       ~review_count:(Some 979) ~window:" (8 of 4223)");
  check (list string) "and moves with the reader"
    [ "1 Goals"; "2 Task Review\xc2\xb7979 (20 of 979)"; "3 Evaluator Verdicts" ]
    (Schedule.planning_strip_plain ~tab:Schedule.Planning_task_review
       ~review_count:(Some 979) ~window:" (20 of 979)")

(* A Keeper whose schedules sit past the projection's page has none the tab can
   show, which is not the same as having none. The live store held 323 requests
   behind a 20-row page when this was written. *)
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

(* Slack reaches the name and the runtime before the task id, and both stop at
   a cap so one very wide terminal does not spend eighty cells on a model
   name. *)
let test_keeper_columns_grow_identifiers_first () =
  let at width = Schedule.allocate_keeper_columns ~inner_width:width in
  let three_hundred = at 300 and four_hundred = at 400 in
  check int "the name stops growing" three_hundred.kcol_name
    four_hundred.kcol_name;
  check int "the runtime stops growing" three_hundred.kcol_runtime
    four_hundred.kcol_runtime;
  check bool "the task absorbs what is left" true
    (four_hundred.kcol_task > three_hundred.kcol_task);
  let one_twenty = at 120 in
  check bool "the name is served before the task" true
    (one_twenty.kcol_name > (at 118).kcol_name
    || one_twenty.kcol_task > (at 118).kcol_task)

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
        ; test_case "terminal size refresh keeps last valid shape" `Quick
            test_terminal_size_cache_refreshes_without_losing_last_valid
        ; test_case "derived render widths are total" `Quick
            test_render_widths_are_total
        ; test_case "interrupted input waits retry" `Quick
            test_interrupted_input_wait_retries_until_deadline
        ; test_case "quit shortcut preserves message input" `Quick
            test_quit_shortcut_does_not_steal_message_input
        ; test_case "compact viewport follows fixed chrome budget" `Quick
            test_compact_viewport_uses_largest_fixed_chrome_budget
        ; test_case "overview rows share one viewport budget" `Quick
            test_overview_rows_share_one_viewport_budget
        ; test_case "overview frame always fills the terminal" `Quick
            test_overview_frame_always_fills_the_terminal
        ; test_case "overview tasks keep a share of a tall viewport" `Quick
            test_overview_task_block_keeps_a_share_of_a_tall_viewport
        ; test_case "overview blocks grow to their item counts" `Quick
            test_overview_blocks_grow_to_their_item_counts
        ; test_case "board read reserves comments and footer" `Quick
            test_board_read_rows_reserve_comments_and_footer
        ; test_case "board read reaches hidden comments" `Quick
            test_board_read_scroll_reaches_hidden_comments
        ; test_case "keeper detail scroll follows current bounds" `Quick
            test_keeper_detail_scroll_normalizes_across_bounds
        ; test_case "overview events follow and preserve manual anchor" `Quick
            test_overview_event_window_follows_and_preserves_anchor
        ; test_case "consecutive identical events fold to one row" `Quick
            test_consecutive_identical_events_fold_to_one_row
        ; test_case "keeper columns never exceed their width" `Quick
            test_keeper_columns_never_exceed_their_width
        ; test_case "keeper columns consume the whole width" `Quick
            test_keeper_columns_consume_the_whole_width
        ; test_case "keeper columns drop from the right" `Quick
            test_keeper_columns_drop_from_the_right
        ; test_case "keeper name width never shrinks" `Quick
            test_keeper_name_width_never_shrinks_as_the_terminal_grows
        ; test_case "keeper columns grow identifiers first" `Quick
            test_keeper_columns_grow_identifiers_first
        ; test_case "planning strip names only its own stops" `Quick
            test_planning_strip_names_only_its_own_stops
        ; test_case "planning window rides the active stop" `Quick
            test_planning_window_rides_the_active_stop
        ; test_case "a capped page cannot report an empty store" `Quick
            test_capped_page_cannot_report_an_empty_store
        ; test_case "wake readings stay four separate answers" `Quick
            test_wake_readings_stay_four_separate_answers
        ] )
    ]
