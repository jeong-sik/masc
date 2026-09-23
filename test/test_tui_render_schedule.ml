open Alcotest

module Schedule = Masc_tui_render_schedule
module Layout = Masc_tui_layout

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
  check int "negative width clamps to zero" 0 (Layout.nonnegative_width (-1));
  check int "tiny keeper panel has an empty context bar" 0
    (Layout.keeper_context_bar_width ~inner_width:0);
  check int "context bar remains bounded" 30
    (Layout.keeper_context_bar_width ~inner_width:100)

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
  + (if allocation.team_rows > 0
     then allocation.team_rows + Schedule.overview_team_chrome_rows
     else 0)
  + allocation.task_error_rows
  + allocation.task_rows
  + allocation.filler_rows

let test_overview_rows_share_one_viewport_budget () =
  let max_data =
    Schedule.allocate_overview ~terminal_rows:14 ~has_cluster:true
      ~attention_count:6 ~event_count:0 ~team_count:0 ~task_count:5 ~has_task_error:false
  in
  check int "14-row attention allocation" 2 max_data.attention_rows;
  check int "14-row task allocation" 1 max_data.task_rows;
  check int "14-row error allocation" 0 max_data.task_error_rows;
  check int "14-row frame is exact" 14
    (overview_frame_rows ~has_cluster:true max_data);
  let task_error =
    Schedule.allocate_overview ~terminal_rows:14 ~has_cluster:true
      ~attention_count:6 ~event_count:0 ~team_count:0 ~task_count:5 ~has_task_error:true
  in
  check int "task error keeps its reserved row" 1
    task_error.task_error_rows;
  check int "task error precedes ordinary task rows" 0 task_error.task_rows;
  check int "task error frame is exact" 14
    (overview_frame_rows ~has_cluster:true task_error);
  let full =
    Schedule.allocate_overview ~terminal_rows:22 ~has_cluster:true
      ~attention_count:6 ~event_count:0 ~team_count:0 ~task_count:5 ~has_task_error:false
  in
  check int "full viewport restores attention cap" 6 full.attention_rows;
  check int "full viewport restores task cap" 5 full.task_rows;
  let events_only =
    Schedule.allocate_overview ~terminal_rows:22 ~has_cluster:true
      ~attention_count:0 ~event_count:6 ~team_count:0 ~task_count:5 ~has_task_error:false
  in
  check int "events size the shared panel" 6 events_only.attention_rows;
  check int "events preserve full task rows" 5 events_only.task_rows;
  let mixed_panel =
    Schedule.allocate_overview ~terminal_rows:22 ~has_cluster:true
      ~attention_count:2 ~event_count:4 ~team_count:0 ~task_count:5 ~has_task_error:false
  in
  check int "the longer panel column determines shared rows" 4
    mixed_panel.attention_rows;
  check int "mixed panel counts preserve full task rows" 5 mixed_panel.task_rows;
  let compact_events_only =
    Schedule.allocate_overview ~terminal_rows:14 ~has_cluster:true
      ~attention_count:0 ~event_count:6 ~team_count:0 ~task_count:5 ~has_task_error:false
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
                      ~attention_count ~event_count ~team_count:0 ~task_count ~has_task_error
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

(* The surface is the box, the key footer under it, and -- when the post or
   the thread has more lines than it can show -- the position line the pane
   writes above the box bottom. The footer and the position line were left out
   of the allocation, so the frame ran one or two rows past the terminal and
   the footer landed on the composer's row. *)
let board_read_frame_rows ~body_line_count ~comment_count
    (allocation : Layout.board_read_allocation) =
  let position_rows =
    if
      body_line_count > allocation.body_rows
      || comment_count > allocation.comment_rows
    then 1
    else 0
  in
  Layout.board_read_box_rows
  + (if comment_count > 0 then 2 else 0)
  + 1
  + position_rows
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
                  ~attention_count ~event_count ~team_count:0 ~task_count ~has_task_error
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
      ~attention_count:80 ~event_count:0 ~team_count:0 ~task_count:20 ~has_task_error:false
  in
  check int "the panel stops at its ceiling" 6 crowded.attention_rows;
  check int "every task is still drawn" 20 crowded.task_rows

(* The task block is bounded by its item count rather than by a constant, so a
   tall terminal shows the whole backlog and pads the rest. The panel keeps its
   ceiling: rows past the sixth are scrolled to, not read at a glance. *)
let test_overview_blocks_grow_to_their_item_counts () =
  let roomy =
    Schedule.allocate_overview ~terminal_rows:60 ~has_cluster:true
      ~attention_count:9 ~event_count:0 ~team_count:0 ~task_count:12 ~has_task_error:false
  in
  check int "the panel stops at its ceiling" 6 roomy.attention_rows;
  check int "every task is drawn" 12 roomy.task_rows;
  check bool "the remainder becomes filler" true (roomy.filler_rows > 0)

(* The Team block says who is doing what. On the operator's 40-row window with
   sixteen Keepers it gets its rows ahead of the backlog, the frame still ends
   on the terminal's last row at every size, and a viewport too short for a
   title, a divider and one Keeper draws no Team block at all rather than
   chrome with nothing under it. *)
(* Pull request lines under the Team block take only blank rows: the 24-row
   Overview keeps every task, and a tall one draws the lines. *)
let test_team_detail_lines_take_only_spare_rows () =
  let tight =
    Schedule.allocate_overview ~terminal_rows:24 ~has_cluster:true
      ~attention_count:6 ~event_count:6 ~team_count:0 ~task_count:5
      ~has_task_error:false
  in
  let spent = Schedule.spend_spare_rows_on_team tight ~extra:3 in
  check int "no blank row, no pull request line" tight.team_rows spent.team_rows;
  check int "the backlog is untouched" tight.task_rows spent.task_rows;
  let tall =
    Schedule.allocate_overview ~terminal_rows:40 ~has_cluster:true
      ~attention_count:2 ~event_count:2 ~team_count:4 ~task_count:3
      ~has_task_error:false
  in
  let spent = Schedule.spend_spare_rows_on_team tall ~extra:3 in
  check int "three lines join the drawn block" (tall.team_rows + 3) spent.team_rows;
  check int "paid from the filler" (tall.filler_rows - 3) spent.filler_rows;
  check int "the backlog is untouched" tall.task_rows spent.task_rows;
  check int "40-row frame is exact" 40 (overview_frame_rows ~has_cluster:true spent);
  let empty =
    Schedule.allocate_overview ~terminal_rows:40 ~has_cluster:true
      ~attention_count:2 ~event_count:2 ~team_count:0 ~task_count:3
      ~has_task_error:false
  in
  let spent = Schedule.spend_spare_rows_on_team empty ~extra:2 in
  check int "a new block opens with two rows" 2 spent.team_rows;
  check int "and pays its chrome from the filler"
    (empty.filler_rows - 2 - Schedule.overview_team_chrome_rows) spent.filler_rows;
  check int "40-row frame is exact" 40 (overview_frame_rows ~has_cluster:true spent)

let test_overview_team_block_sits_between_panel_and_backlog () =
  let live =
    Schedule.allocate_overview ~terminal_rows:40 ~has_cluster:true
      ~attention_count:10 ~event_count:3 ~team_count:13 ~task_count:687
      ~has_task_error:false
  in
  check int "the panel keeps its ceiling" 6 live.attention_rows;
  check int "every Team row fits" 13 live.team_rows;
  check int "the backlog takes what is left" 8 live.task_rows;
  check int "40-row frame is exact" 40
    (overview_frame_rows ~has_cluster:true live);
  let short =
    Schedule.allocate_overview ~terminal_rows:18 ~has_cluster:true
      ~attention_count:6 ~event_count:0 ~team_count:13 ~task_count:20
      ~has_task_error:false
  in
  check int "a short viewport gives Team no half block" 0 short.team_rows;
  check int "the backlog keeps its held row" 1 short.task_rows;
  List.iter
    (fun team_count ->
      for terminal_rows = 14 to 80 do
        let allocation =
          Schedule.allocate_overview ~terminal_rows ~has_cluster:true
            ~attention_count:6 ~event_count:6 ~team_count ~task_count:40
            ~has_task_error:true
        in
        check int
          (Printf.sprintf "rows %d team %d" terminal_rows team_count)
          terminal_rows
          (overview_frame_rows ~has_cluster:true allocation);
        if allocation.team_rows < 0 || allocation.team_rows > team_count then
          failf "team rows out of range at rows=%d team=%d: %d" terminal_rows
            team_count allocation.team_rows
      done)
    [ 0; 1; 3; 16; 60 ]

let test_board_read_rows_reserve_comments_and_footer () =
  let crowded =
    Layout.allocate_board_read ~terminal_rows:14 ~body_line_count:10
      ~comment_count:5
  in
  check int "14-row board keeps one body row" 1 crowded.body_rows;
  check int "14-row board fits two comments" 2 crowded.comment_rows;
  check int "14-row board frame is exact" 14
    (board_read_frame_rows ~body_line_count:10 ~comment_count:5 crowded);
  let comments_only =
    Layout.allocate_board_read ~terminal_rows:14 ~body_line_count:0
      ~comment_count:5
  in
  check int "empty body consumes no semantic row" 0 comments_only.body_rows;
  check int "empty body frees a third comment row" 3
    comments_only.comment_rows;
  let no_comments =
    Layout.allocate_board_read ~terminal_rows:14 ~body_line_count:10
      ~comment_count:0
  in
  check int "comment-free board uses the full body viewport" 5
    no_comments.body_rows;
  let full_comments =
    Layout.allocate_board_read ~terminal_rows:16 ~body_line_count:10
      ~comment_count:5
  in
  check int "16-row board widens the thread" 4 full_comments.comment_rows;
  (* A tall terminal is where the old flat five hurt: a forty-reply thread got
     the same five rows on an eighty-row screen as on a twenty-row one. The
     share grows with the height, and the post still keeps the larger half. *)
  let tall =
    Layout.allocate_board_read ~terminal_rows:60 ~body_line_count:200
      ~comment_count:40
  in
  check int "a tall pane gives comments a share, not a constant" 16
    tall.comment_rows;
  check bool "the post still keeps the larger part" true
    (tall.body_rows > tall.comment_rows);
  let few_comments =
    Layout.allocate_board_read ~terminal_rows:60 ~body_line_count:200
      ~comment_count:3
  in
  check int "a short thread takes only what it has" 3
    few_comments.comment_rows;
  (* Rows the body cannot use are the comments'. This pane held twenty-four
     rows of filler under a ten-line post while the thread was cut at five. *)
  let short_post =
    Layout.allocate_board_read ~terminal_rows:60 ~body_line_count:10
      ~comment_count:40
  in
  check int "a short post hands its unused rows to the thread" 40
    short_post.comment_rows;
  check int "the body keeps exactly the rows it has" 10 short_post.body_rows;
  for terminal_rows = 14 to 40 do
    for body_line_count = 0 to 10 do
      for comment_count = 0 to 10 do
        let allocation =
          Layout.allocate_board_read ~terminal_rows ~body_line_count
            ~comment_count
        in
        let total =
          board_read_frame_rows ~body_line_count ~comment_count allocation
        in
        if total <> terminal_rows then
          failf
            "board-read does not fill viewport: rows=%d body=%d comments=%d total=%d"
            terminal_rows body_line_count comment_count total;
        if body_line_count > 0 && allocation.body_rows < 1 then
          failf "board-read hid a nonempty body at rows=%d comments=%d"
            terminal_rows comment_count;
        let ceiling =
          let chrome = if comment_count > 0 then 2 else 0 in
          let available =
            max 0 (terminal_rows - Layout.board_read_box_rows - 1 - chrome)
          in
          max 5 (max (available - body_line_count) (available / 3))
        in
        if
          allocation.comment_rows < 0
          || allocation.comment_rows > min ceiling comment_count
        then
          failf "board-read comment allocation escaped its cap";
        let last =
          Layout.project_board_read_scroll ~body_line_count
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
    Layout.allocate_board_read ~terminal_rows:14 ~body_line_count:1
      ~comment_count:5
  in
  let first =
    Layout.project_board_read_scroll ~body_line_count:1
      ~body_rows:allocation.body_rows ~comment_count:5
      ~comment_rows:allocation.comment_rows 0
  in
  check int "initial body offset" 0 first.body_offset;
  check int "initial comment offset" 0 first.comment_offset;
  let last =
    Layout.project_board_read_scroll ~body_line_count:1
      ~body_rows:allocation.body_rows ~comment_count:5
      ~comment_rows:allocation.comment_rows 99
  in
  check int "overscroll normalizes to the combined maximum" 3
    last.normalized_scroll;
  check int "one-line body remains visible" 0 last.body_offset;
  check int "last comment becomes visible" 3 last.comment_offset;
  let long_body =
    Layout.project_board_read_scroll ~body_line_count:10 ~body_rows:1
      ~comment_count:5 ~comment_rows:3 10
  in
  check int "body scroll is consumed first" 9 long_body.body_offset;
  check int "remaining scroll advances comments" 1
    long_body.comment_offset;
  let negative =
    Layout.project_board_read_scroll ~body_line_count:10 ~body_rows:1
      ~comment_count:5 ~comment_rows:3 (-1)
  in
  check int "negative scroll normalizes to zero" 0
    negative.normalized_scroll

(* Below the minimum the post column would be too narrow to read once the
   comment column takes its fixed share, so the pane falls back to the
   stacked layout instead of drawing an unreadable post. At and above it, the
   two columns always add back up to the pane's own width -- nothing is
   dropped between them, and nothing is drawn twice. *)
let test_board_read_side_layout_falls_back_when_narrow () =
  check bool "119 cols keeps the stacked layout" true
    (Layout.board_read_side_layout ~cols:119 = None);
  check bool "120 cols uses fixed side columns" true
    (Layout.board_read_side_layout ~cols:120 = Some (78, 42));
  for cols = Layout.board_read_side_minimum_cols to 220 do
    match Layout.board_read_side_layout ~cols with
    | None -> failf "cols=%d: expected a side layout at or above the minimum" cols
    | Some (body_cols, comment_cols) ->
        if body_cols + comment_cols <> cols then
          failf "cols=%d: columns do not sum to the pane width (%d + %d)"
            cols body_cols comment_cols;
        if
          comment_cols
          <> Layout.board_read_side_comment_cols
             + Layout.board_read_side_gutter_cols
        then
          failf "cols=%d: comment column changed width (%d)" cols comment_cols;
        if body_cols < Layout.board_read_side_body_minimum_cols then
          failf "cols=%d: post column is too narrow to read (%d)" cols
            body_cols
  done

(* The heading is drawn from the comment column's own share, so a column with
   any thread in it always has room for the heading and at least one line
   under it -- never a heading alone. *)
let test_board_read_side_allocation_reserves_the_heading () =
  for terminal_rows = 9 to 40 do
    for comment_count = 0 to 12 do
      let allocation =
        Layout.allocate_board_read_side ~terminal_rows ~body_line_count:20
          ~comment_count
      in
      if comment_count > 0 && allocation.comment_rows > 0
         && allocation.comment_rows < 2
      then
        failf
          "rows=%d comments=%d: comment column has a heading with no room \
           under it (%d rows)"
          terminal_rows comment_count allocation.comment_rows;
      if allocation.body_rows < 0 || allocation.comment_rows < 0 then
        failf "rows=%d comments=%d: negative row allocation" terminal_rows
          comment_count;
      let available = max 0 (terminal_rows - 9) in
      if max allocation.body_rows allocation.comment_rows <> available then
        failf
          "rows=%d comments=%d: side columns leave vertical space unused"
          terminal_rows comment_count
    done
  done;
  let no_comments =
    Layout.allocate_board_read_side ~terminal_rows:30 ~body_line_count:20
      ~comment_count:0
  in
  check int "no thread spends no row on a heading" 0 no_comments.comment_rows

(* The side layout does not own a scroll of its own: it windows through
   [project_board_read_scroll], the same function the stacked layout always
   used, with the side allocation's rows in place of the stacked ones. So a
   post beside its thread opens exactly like a post above its thread --
   both columns at their head -- and a keyboard scenario that presses Enter
   and expects the oldest comment waiting at the top, before anything has
   scrolled, sees it either way. *)
let test_board_read_side_layout_opens_head_first () =
  let allocation =
    Layout.allocate_board_read_side ~terminal_rows:16 ~body_line_count:20
      ~comment_count:20
  in
  check bool "this allocation has room for a heading and a line under it"
    true (allocation.comment_rows >= 2);
  let comment_rows = allocation.comment_rows - 1 (* the heading's own row *) in
  let opening =
    Layout.project_board_read_scroll ~body_line_count:20
      ~body_rows:allocation.body_rows ~comment_count:20 ~comment_rows 0
  in
  check int "post opens at its head" 0 opening.body_offset;
  check int "thread opens at its head, not its tail" 0 opening.comment_offset

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

(* What the runtime ceiling used to be: a constant of 34. The cases below are
   about the other columns, so they hold it still. *)
let old_runtime_ceiling = 34

(* Below the narrowest row the allocation cannot shrink further; the frame
   shows a resize gate at those sizes rather than a roster. *)
let keeper_minimum_row_width =
  Schedule.keeper_columns_used_width
    (Schedule.allocate_keeper_columns ~inner_width:0
      ~widest_runtime:old_runtime_ceiling)

(* The row must never be wider than the box that holds it: the renderer fits
   each cell to these budgets, so a total over [inner_width] pushes the right
   border off the frame and the border column moves from row to row. *)
let test_keeper_columns_never_exceed_their_width () =
  for inner_width = 0 to 400 do
    let columns = Schedule.allocate_keeper_columns ~inner_width
      ~widest_runtime:old_runtime_ceiling in
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
    let columns = Schedule.allocate_keeper_columns ~inner_width
      ~widest_runtime:old_runtime_ceiling in
    check int
      (Printf.sprintf "inner %d is fully allocated" inner_width)
      inner_width
      (Schedule.keeper_columns_used_width columns)
  done

(* Columns drop from the right, and identity never drops. *)
let test_keeper_columns_drop_from_the_right () =
  let narrow = Schedule.allocate_keeper_columns ~inner_width:70
      ~widest_runtime:old_runtime_ceiling in
  check bool "no flags when narrow" false narrow.kcol_show_flags;
  check bool "no runtime when narrow" false narrow.kcol_show_runtime;
  check bool "the name still has cells" true (narrow.kcol_name > 0);
  let medium = Schedule.allocate_keeper_columns ~inner_width:100
      ~widest_runtime:old_runtime_ceiling in
  check bool "flags return first" true medium.kcol_show_flags;
  check bool "runtime is still out" false medium.kcol_show_runtime;
  let wide = Schedule.allocate_keeper_columns ~inner_width:150
      ~widest_runtime:old_runtime_ceiling in
  check bool "runtime returns when wide" true wide.kcol_show_runtime;
  check bool "a dropped column costs no cells" true (medium.kcol_runtime = 0)

(* The runtime column is the one that holds a long identifier, and it used to
   stop growing at 34 cells whatever the rows held. Live ids reach 49
   ([antigravity_subscription.claude-opus-4-6-thinking]), so every long one was
   elided while the slack the row had left ran on to the task column -- 49
   cells of it, for a task id the layout's own note calls short by
   construction. *)
let test_the_runtime_column_grows_to_the_ids_it_holds () =
  let long = 49 in
  let columns =
    Schedule.allocate_keeper_columns ~inner_width:160 ~widest_runtime:long
  in
  check bool "the runtime column has room for the widest id" true
    (columns.kcol_runtime >= long);
  (* Not out of the name's cells: identity is what a reader picks a row by,
     and it is allocated first. *)
  let at_old_ceiling =
    Schedule.allocate_keeper_columns ~inner_width:160
      ~widest_runtime:old_runtime_ceiling
  in
  check int "the name keeps the cells it had" at_old_ceiling.kcol_name
    columns.kcol_name

(* And it stops at what they need. A roster whose runtimes are all short has
   no use for a wide column, and those cells go on to the task id. *)
let test_the_runtime_column_stops_at_what_it_holds () =
  let short =
    Schedule.allocate_keeper_columns ~inner_width:160 ~widest_runtime:12
  in
  let long =
    Schedule.allocate_keeper_columns ~inner_width:160 ~widest_runtime:49
  in
  check bool "short ids take a narrower column" true
    (short.kcol_runtime < long.kcol_runtime);
  check bool "and the cells land in the task column" true
    (short.kcol_task > long.kcol_task);
  check int "the row still spends every cell" 160
    (Schedule.keeper_columns_used_width short)


(* The name column never shrinks as the terminal widens. A width that added a
   column while narrowing the name would make the same keeper unreadable on the
   larger terminal. *)
let test_keeper_name_width_never_shrinks_as_the_terminal_grows () =
  let previous = ref 0 in
  for inner_width = keeper_minimum_row_width to 400 do
    let name = (Schedule.allocate_keeper_columns ~inner_width
      ~widest_runtime:old_runtime_ceiling).kcol_name in
    check bool
      (Printf.sprintf "inner %d keeps the name at least as wide" inner_width)
      true (name >= !previous);
    previous := name
  done

(* Memory fleet columns.

   The header row and the data row are built from one description of the
   columns. These check that the pair actually lands on the same offsets, and
   that no reading can move a cell -- the two things the screen lost while the
   header and the row each carried their own widths in a format string. *)

(* One cell per column, so a mark's position is the cell's position. *)
let memory_probe =
  { Schedule.mrow_state = "S"
  ; mrow_name = "N"
  ; mrow_updated = "R"
  ; mrow_facts = "F"
  ; mrow_size = "Z"
  ; mrow_source = "U"
  ; mrow_delta = "D"
  }

(* Every reading past its budget, including the two that used to push the row:
   a keeper name over eighteen cells and an ordinary reading over fourteen. *)
let memory_overflowing =
  { Schedule.mrow_state = "read-error-and-then-some"
  ; mrow_name = "pinewood-pr-jira-checker-and-a-longer-tail"
  ; mrow_updated = "1234567890"
  ; mrow_facts = "9876543"
  ; mrow_size = "1234567.8 MB"
  ; mrow_source = "r32 i8 1.5 KB with more than the cell holds"
  ; mrow_delta = "+1000 -1000"
  }

let index_of haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec walk index =
    if index + needle_length > haystack_length then None
    else if String.sub haystack index needle_length = needle then Some index
    else walk (index + 1)
  in
  walk 0

(* A column label that is a prefix of another label matches the wrong column
   and says nothing about it. "ST" is inside "STARTED", so after the Memory
   table renamed STATE to ST (#33919) the Fusion case read the first column
   as the state one and reported its offset as 0. A label occurs once in a
   header row, so more than one occurrence is the question being asked
   wrongly rather than an answer. *)
let offset_of needle text =
  match index_of text needle with
  | None -> failf "%S is not in %S" needle text
  | Some index ->
    let rest = String.sub text (index + String.length needle)
                 (String.length text - index - String.length needle) in
    (match index_of rest needle with
     | Some _ -> failf "%S appears more than once in %S" needle text
     | None -> index)

(* Offsets are asked in display cells, not bytes: the delta column is headed
   with a two-byte glyph that occupies one cell. *)
let cells_before text byte_offset =
  Masc_tui_message_layout.display_width (String.sub text 0 byte_offset)

let check_left_cell label mark ~header ~row ~inner_width =
  check int
    (Printf.sprintf "inner %d: %s starts where its cell starts" inner_width label)
    (cells_before header (offset_of label header))
    (cells_before row (offset_of mark row))

let check_right_cell label mark ~header ~row ~inner_width =
  let ends text needle =
    cells_before text (offset_of needle text)
    + Masc_tui_message_layout.display_width needle
  in
  check int
    (Printf.sprintf "inner %d: %s ends where its cell ends" inner_width label)
    (ends header label) (ends row mark)

let memory_minimum_row_width =
  Schedule.memory_columns_used_width
    (Schedule.allocate_memory_columns ~inner_width:0)

(* The row must never be wider than the box that holds it. *)
let test_memory_columns_never_exceed_their_width () =
  for inner_width = 0 to 400 do
    let columns = Schedule.allocate_memory_columns ~inner_width in
    let used = Schedule.memory_columns_used_width columns in
    check bool
      (Printf.sprintf "inner %d fits (used %d)" inner_width used)
      true
      (used <= max inner_width memory_minimum_row_width)
  done

(* The Δ column carries a pair, and a cell past its width folds in the middle,
   which takes the first count. Two digits each is the daily shape (the widest
   pair on the live fleet was +11 -16); three each is what a large revision
   needs. *)
let test_the_memory_delta_column_holds_a_pair_of_counts () =
  let columns = Schedule.allocate_memory_columns ~inner_width:240 in
  List.iter
    (fun delta ->
      let row = Schedule.memory_row columns { memory_probe with mrow_delta = delta } in
      check bool
        (Printf.sprintf "%s is drawn whole: %s" delta row)
        true
        (Option.is_some (index_of row delta)))
    [ "+12 -23"; "+999 -999" ]

(* The defect this pair replaces: a header naming a column the row drew
   somewhere else. Every visible column is checked at every width. *)
let test_memory_header_and_row_share_their_offsets () =
  for inner_width = memory_minimum_row_width to 240 do
    let columns = Schedule.allocate_memory_columns ~inner_width in
    let header = Schedule.memory_header_row columns in
    let row = Schedule.memory_row columns memory_probe in
    check_left_cell "ST" "S" ~header ~row ~inner_width;
    check_left_cell "KEEPER" "N" ~header ~row ~inner_width;
    if columns.Schedule.mcol_show_updated then
      check_right_cell "UPDATED" "R" ~header ~row ~inner_width;
    check_right_cell "FACTS" "F" ~header ~row ~inner_width;
    check_right_cell "RECALL" "Z" ~header ~row ~inner_width;
    if columns.Schedule.mcol_show_source then
      check_left_cell "SOURCE" "U" ~header ~row ~inner_width;
    check_right_cell "\xce\x94" "D" ~header ~row ~inner_width
  done

(* A reading wider than its cell is folded, never allowed to push the cells
   after it. Both rows are laid out on the same allocation, so both are exactly
   as wide as the header. *)
let test_memory_row_width_does_not_depend_on_its_readings () =
  for inner_width = memory_minimum_row_width to 240 do
    let columns = Schedule.allocate_memory_columns ~inner_width in
    let width text = Masc_tui_message_layout.display_width text in
    let header = width (Schedule.memory_header_row columns) in
    check int
      (Printf.sprintf "inner %d: a short row matches the header" inner_width)
      header
      (width (Schedule.memory_row columns memory_probe));
    check int
      (Printf.sprintf "inner %d: an overflowing row matches the header" inner_width)
      header
      (width (Schedule.memory_row columns memory_overflowing))
  done

(* An empty reading still holds its cell, or the columns after it move on the
   rows that read normally -- which is every row on a healthy fleet. *)
let test_memory_empty_readings_still_hold_their_cells () =
  let columns = Schedule.allocate_memory_columns ~inner_width:200 in
  let blank =
    { Schedule.mrow_state = ""
    ; mrow_name = ""
    ; mrow_updated = ""
    ; mrow_facts = ""
    ; mrow_size = ""
    ; mrow_source = ""
    ; mrow_delta = ""
    }
  in
  check int "a blank row is as wide as the header"
    (Masc_tui_message_layout.display_width (Schedule.memory_header_row columns))
    (Masc_tui_message_layout.display_width (Schedule.memory_row columns blank))

(* Columns drop from the right, and the keeper's identity never drops. *)
let test_memory_columns_drop_from_the_right () =
  let narrow = Schedule.allocate_memory_columns ~inner_width:50 in
  check bool "no source when narrow" false narrow.Schedule.mcol_show_source;
  check bool "no revision when narrow" false narrow.Schedule.mcol_show_updated;
  check bool "the name still has cells" true (narrow.Schedule.mcol_name > 0);
  (* Wide enough for the revision beside a keeper name at its widest, which is
     what a returning column now waits for. *)
  let medium = Schedule.allocate_memory_columns ~inner_width:80 in
  check bool "revision returns first" true medium.Schedule.mcol_show_updated;
  check bool "source is still out" false medium.Schedule.mcol_show_source;
  let wide = Schedule.allocate_memory_columns ~inner_width:120 in
  check bool "source returns when wide" true wide.Schedule.mcol_show_source

(* A width that added a column while narrowing the name would make the same
   keeper unreadable on the larger terminal. *)
let test_memory_name_width_never_shrinks_as_the_terminal_grows () =
  let previous = ref 0 in
  for inner_width = memory_minimum_row_width to 400 do
    let name = (Schedule.allocate_memory_columns ~inner_width).Schedule.mcol_name in
    check bool
      (Printf.sprintf "inner %d keeps the name at least as wide" inner_width)
      true (name >= !previous);
    previous := name
  done

(* Workspace repository columns.

   This screen printed one format string twice and sized its path cell by
   subtracting a constant from the terminal width. Both are gone; these check
   what replaced them. *)

let workspace_probe =
  { Schedule.wrow_name = "N"
  ; wrow_branch = "B"
  ; wrow_status = "S"
  ; wrow_sync = "Y"
  ; wrow_path = "P"
  }

let workspace_overflowing =
  { Schedule.wrow_name = "pinewood-web-store-and-a-longer-tail"
  ; wrow_branch = "feature/PK-12345-a-long-branch"
  ; wrow_status = "conflicted"
  ; wrow_sync = "manual"
  ; wrow_path = "/Users/dancer/me/workspace/pinewood/pinewood-web-store"
  }

(* The path takes what the named columns leave, so the row fills the frame it
   was allocated for rather than falling short of it or spilling past it. *)
let test_workspace_path_takes_the_remainder () =
  for inner_width = 20 to 300 do
    let path_width = Schedule.workspace_path_width ~inner_width in
    let drawn =
      Masc_tui_message_layout.display_width
        (Schedule.workspace_header_row ~path_width)
    in
    if path_width > Schedule.workspace_minimum_path_width then
      check int
        (Printf.sprintf "inner %d is fully allocated" inner_width)
        inner_width drawn
    else
      check bool
        (Printf.sprintf "inner %d keeps the path readable" inner_width)
        true
        (path_width = Schedule.workspace_minimum_path_width)
  done

(* The defect that stood here: a header and a row carrying the same widths in
   two format strings. *)
let test_workspace_header_and_row_share_their_offsets () =
  for inner_width = 60 to 240 do
    let path_width = Schedule.workspace_path_width ~inner_width in
    let header = Schedule.workspace_header_row ~path_width in
    let row = Schedule.workspace_row ~path_width workspace_probe in
    check_left_cell "NAME" "N" ~header ~row ~inner_width;
    check_left_cell "BRANCH" "B" ~header ~row ~inner_width;
    check_left_cell "STATUS" "S" ~header ~row ~inner_width;
    check_left_cell "SYNC" "Y" ~header ~row ~inner_width;
    check_left_cell "PATH" "P" ~header ~row ~inner_width
  done

(* A repository named past its cell, on a branch named past its cell, at a path
   longer than the frame: none of it may move a column. *)
let test_workspace_row_width_does_not_depend_on_its_readings () =
  for inner_width = 60 to 240 do
    let path_width = Schedule.workspace_path_width ~inner_width in
    let width text = Masc_tui_message_layout.display_width text in
    let header = width (Schedule.workspace_header_row ~path_width) in
    check int
      (Printf.sprintf "inner %d: a short row" inner_width)
      header
      (width (Schedule.workspace_row ~path_width workspace_probe));
    check int
      (Printf.sprintf "inner %d: an overflowing row" inner_width)
      header
      (width (Schedule.workspace_row ~path_width workspace_overflowing))
  done

(* System log columns.

   This screen threaded five colours through the widths in its row's format
   string, so the widths could not be compared with the header's by reading
   either. The colours ride the cells now; these check that they cost nothing
   in layout. *)

let system_log_probe =
  { Schedule.slog_time = "T"
  ; slog_level = "L"
  ; slog_module = "M"
  ; slog_keeper = "K"
  ; slog_category = "C"
  ; slog_message = "G"
  }

let system_log_dressed =
  { Schedule.slog_time_style = "\027[2m"
  ; slog_module_style = "\027[36m"
  ; slog_keeper_style = "\027[35m"
  ; slog_category_style = "\027[2m"
  }

let system_log_overflowing =
  { Schedule.slog_time = "11:08:43.512"
  ; slog_level = "! CRITICAL"
  ; slog_module = "execution_lane_writer_and_more"
  ; slog_keeper = "pinewood-pr-jira-checker"
  ; slog_category = "provider-router"
  ; slog_message = String.concat "" (List.init 20 (fun _ -> "message "))
  }

(* Task Review drew its header and its rows from two format strings, and
   printf's width is a floor: a task id past its fourteen cells printed whole
   and pushed SUBMITTED BY, EVIDENCE and the title out of line. The header
   also spelled sentence case, alone among the TUI's tables. *)
let holds needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  n = 0 || scan 0

let verification_probe : Schedule.verification_row_values =
  { vrow_task = "task-verify-000000000000001"
  ; vrow_verdict = "complete"
  ; vrow_submitted_by = "pinewood-pr-jira-checker-and-more"
  ; vrow_evidence = "12/12"
  ; vrow_title = String.concat "" (List.init 12 (fun _ -> "title "))
  }

let test_verification_rows_stay_on_the_header_columns () =
  for inner_width = 60 to 240 do
    let submitter_width = 16 in
    let title_width =
      Schedule.verification_title_width ~inner_width ~submitter_width
    in
    let width text = Masc_tui_message_layout.display_width text in
    let header =
      width (Schedule.verification_header_row ~submitter_width ~title_width)
    in
    check int
      (Printf.sprintf "inner %d: an overlong row matches the header" inner_width)
      header
      (width
         (Schedule.verification_row ~submitter_width ~title_width
            verification_probe));
    check int
      (Printf.sprintf "inner %d: an empty row matches the header" inner_width)
      header
      (width
         (Schedule.verification_row ~submitter_width ~title_width
            { Schedule.vrow_task = ""
            ; vrow_verdict = ""
            ; vrow_submitted_by = ""
            ; vrow_evidence = ""
            ; vrow_title = ""
            }))
  done

(* The title takes what the named columns leave, down to a floor below which
   a request says nothing worth the row it costs. *)
let test_verification_title_takes_the_remainder () =
  for inner_width = 20 to 300 do
    let submitter_width = 16 in
    let title_width =
      Schedule.verification_title_width ~inner_width ~submitter_width
    in
    let drawn =
      Masc_tui_message_layout.display_width
        (Schedule.verification_header_row ~submitter_width ~title_width)
    in
    if title_width > Schedule.verification_minimum_title_width then
      check int
        (Printf.sprintf "inner %d is fully allocated" inner_width)
        inner_width drawn
    else
      check bool
        (Printf.sprintf "inner %d keeps the floor" inner_width)
        true
        (title_width = Schedule.verification_minimum_title_width)
  done

(* The column names read as every other table's do. *)
let test_verification_names_its_columns_in_capitals () =
  let header = Schedule.verification_header_row ~submitter_width:16 ~title_width:20 in
  List.iter
    (fun name ->
      check bool (name ^ " names a column") true (holds name header))
    [ "TASK"; "VERDICT"; "SUBMITTED BY"; "EVIDENCE"; "TITLE" ];
  List.iter
    (fun retired ->
      check bool (retired ^ " is gone") false (holds retired header))
    [ "Submitted by"; "What it asks for" ]

(* The Schedules list drew six columns and named one of them, inside the row:
   "wake:" sat on the wake's word and a dot separated the delivery's. Now the
   names are above the rows, where every other list on this screen puts them,
   and the row carries readings only. *)
let schedule_probe : Schedule.schedule_row_values =
  { srow_status = "[an overlong state word]"
  ; srow_due = "2026-08-25 19:00:00"
  ; srow_target = "a-keeper-name-longer-than-its-column"
  ; srow_wake = "succeeded"
  ; srow_delivery = "consumed_ack"
  ; srow_recurrence = String.concat "" (List.init 12 (fun _ -> "every 30 minutes "))
  }

let schedule_empty : Schedule.schedule_row_values =
  { srow_status = ""
  ; srow_due = ""
  ; srow_target = ""
  ; srow_wake = ""
  ; srow_delivery = ""
  ; srow_recurrence = ""
  }

let test_schedule_rows_stay_on_the_header_columns () =
  for inner_width = 60 to 240 do
    let target_width = 16 and wake_width = 9 in
    let recurrence_width =
      Schedule.schedule_recurrence_width ~inner_width ~target_width ~wake_width
    in
    let width text = Masc_tui_message_layout.display_width text in
    let header =
      width
        (Schedule.schedule_header_row ~target_width ~wake_width
           ~recurrence_width)
    in
    List.iter
      (fun (what, values) ->
        check int
          (Printf.sprintf "inner %d: %s matches the header" inner_width what)
          header
          (width
             (Schedule.schedule_row ~target_width ~wake_width ~recurrence_width
                values)))
      [ "an overlong row", schedule_probe; "an empty row", schedule_empty ];
    (* The styles a schedule row wears -- the state's colour, the wake's, the
       dim on the recurrence -- are escapes, and an escape occupies no cell. *)
    check int
      (Printf.sprintf "inner %d: a dressed row matches the header" inner_width)
      header
      (width
         (Schedule.schedule_row ~status_style:"\027[33m" ~wake_style:"\027[31m"
            ~recurrence_style:"\027[2m" ~target_width ~wake_width
            ~recurrence_width schedule_probe))
  done

(* The recurrence takes what the named columns leave, down to a floor. It is
   the column that carries the timezone, and the one the pane was cutting. *)
let test_schedule_recurrence_takes_the_remainder () =
  for inner_width = 20 to 300 do
    let target_width = 16 and wake_width = 9 in
    let recurrence_width =
      Schedule.schedule_recurrence_width ~inner_width ~target_width ~wake_width
    in
    let drawn =
      Masc_tui_message_layout.display_width
        (Schedule.schedule_header_row ~target_width ~wake_width
           ~recurrence_width)
    in
    if recurrence_width > Schedule.schedule_minimum_recurrence_width then
      check int
        (Printf.sprintf "inner %d is fully allocated" inner_width)
        inner_width drawn
    else
      check bool
        (Printf.sprintf "inner %d keeps the floor" inner_width)
        true
        (recurrence_width = Schedule.schedule_minimum_recurrence_width)
  done

(* Six names above the rows, and none of them left inside a row. *)
let test_schedule_names_its_columns_once () =
  let target_width = 16 and wake_width = 9 in
  let recurrence_width =
    Schedule.schedule_recurrence_width ~inner_width:120 ~target_width
      ~wake_width
  in
  let header =
    Schedule.schedule_header_row ~target_width ~wake_width ~recurrence_width
  in
  List.iter
    (fun name -> check bool (name ^ " names a column") true (holds name header))
    [ "STATUS"; "DUE"; "TARGET"; "WAKE"; "DELIVERY"; "RECURRENCE" ];
  let row =
    Schedule.schedule_row ~target_width ~wake_width ~recurrence_width
      { schedule_probe with srow_recurrence = "every 30 minutes" }
  in
  List.iter
    (fun label ->
      check bool (label ^ " no longer sits in the row") false (holds label row))
    [ "wake:"; "\xc2\xb7" ]

(* Escapes have no display width, so a dressed row measures exactly what an
   undressed one does -- and what the header does. A colour cannot move a
   column. *)
let test_system_log_colour_costs_no_cells () =
  for inner_width = 60 to 240 do
    let message_width = Schedule.system_log_message_width ~inner_width in
    let width text = Masc_tui_message_layout.display_width text in
    let header = width (Schedule.system_log_header_row ~message_width) in
    let plain =
      Schedule.system_log_row ~message_width ~level_style:""
        ~styles:Schedule.system_log_plain_styles system_log_probe
    in
    let dressed =
      Schedule.system_log_row ~message_width ~level_style:"\027[33m"
        ~styles:system_log_dressed system_log_probe
    in
    check int
      (Printf.sprintf "inner %d: plain matches the header" inner_width)
      header (width plain);
    check int
      (Printf.sprintf "inner %d: dressed matches the header" inner_width)
      header (width dressed);
    check int
      (Printf.sprintf "inner %d: an overflowing dressed row" inner_width)
      header
      (width
         (Schedule.system_log_row ~message_width ~level_style:"\027[31m"
            ~styles:system_log_dressed system_log_overflowing))
  done

(* The message takes the remainder, down to a floor below which a log line
   says nothing worth the row it costs. *)
let test_system_log_message_takes_the_remainder () =
  for inner_width = 20 to 300 do
    let message_width = Schedule.system_log_message_width ~inner_width in
    let drawn =
      Masc_tui_message_layout.display_width
        (Schedule.system_log_header_row ~message_width)
    in
    if message_width > Schedule.system_log_minimum_message_width then
      check int
        (Printf.sprintf "inner %d is fully allocated" inner_width)
        inner_width drawn
    else
      check bool
        (Printf.sprintf "inner %d keeps the message readable" inner_width)
        true
        (message_width = Schedule.system_log_minimum_message_width)
  done

(* The offsets the two format strings could disagree about. *)
let test_system_log_header_and_row_share_their_offsets () =
  for inner_width = 60 to 240 do
    let message_width = Schedule.system_log_message_width ~inner_width in
    let header = Schedule.system_log_header_row ~message_width in
    let row =
      Schedule.system_log_row ~message_width ~level_style:""
        ~styles:Schedule.system_log_plain_styles system_log_probe
    in
    check_left_cell "TIME" "T" ~header ~row ~inner_width;
    check_left_cell "LEVEL" "L" ~header ~row ~inner_width;
    check_left_cell "MODULE" "M" ~header ~row ~inner_width;
    check_left_cell "KEEPER" "K" ~header ~row ~inner_width;
    check_left_cell "CATEGORY" "C" ~header ~row ~inner_width;
    check_left_cell "MESSAGE" "G" ~header ~row ~inner_width
  done

(* Lane run and file change columns.

   Both wrote their widths twice, and both spliced colours into the row's copy
   so the two could not be compared by reading either. *)

let lane_probe =
  { Schedule.lrow_started = "A"
  ; lrow_subject = "B"
  ; lrow_status = "C"
  ; lrow_elapsed = "D"
  ; lrow_slot = "E"
  ; lrow_run_id = "F"
  }

let lane_overflowing =
  { Schedule.lrow_started = "2026-09-03 11:08:43.512"
  ; lrow_subject = "pinewood-pr-jira-checker"
  ; lrow_elapsed = "1234.5s"
  ; lrow_status = "cancelled-by-operator"
  ; lrow_slot = "antigravity_subscription.gemini-3-8-flash-high"
  ; lrow_run_id = "run-1788427841647-00000-abcdef"
  }

let change_probe =
  { Schedule.crow_turn = "A"
  ; crow_task = "B"
  ; crow_op = "C"
  ; crow_result = "D"
  ; crow_file = "E"
  ; crow_summary = "F"
  }

let change_overflowing =
  { Schedule.crow_turn = "1234567"
  ; crow_task = "task-1279-and-more"
  ; crow_op = "delete"
  ; crow_result = "attempted"
  ; crow_file = "bin/masc_tui_render_schedule.mli and a much longer path than fits"
  ; crow_summary = String.concat "" (List.init 20 (fun _ -> "summary "))
  }

let test_lane_columns_hold_their_offsets () =
  for inner_width = 80 to 240 do
    let run_id_width = Schedule.lane_run_id_width ~inner_width in
    let identity_header = "ACTOR" in
    let width text = Masc_tui_message_layout.display_width text in
    let header =
      Schedule.lane_run_header_row ~identity_header ~run_id_width
    in
    let row =
      Schedule.lane_run_row ~identity_header ~status_style:"" ~run_id_width
        lane_probe
    in
    check_left_cell "STARTED" "A" ~header ~row ~inner_width;
    check_left_cell identity_header "B" ~header ~row ~inner_width;
    check_left_cell "STATUS" "C" ~header ~row ~inner_width;
    check_left_cell "SLOT" "E" ~header ~row ~inner_width;
    check_left_cell "RUN ID" "F" ~header ~row ~inner_width;
    check int
      (Printf.sprintf "inner %d: a dressed overflowing run" inner_width)
      (width header)
      (width
         (Schedule.lane_run_row ~identity_header ~status_style:"\027[31m"
            ~run_id_width lane_overflowing))
  done

let test_change_columns_hold_their_offsets () =
  for inner_width = 80 to 240 do
    let summary_width = Schedule.change_summary_width ~inner_width in
    let width text = Masc_tui_message_layout.display_width text in
    let header = Schedule.change_header_row ~summary_width in
    let row =
      Schedule.change_row ~op_style:"" ~result_style:"" ~summary_width
        change_probe
    in
    check_right_cell "TURN" "A" ~header ~row ~inner_width;
    check_left_cell "TASK" "B" ~header ~row ~inner_width;
    check_left_cell "OP" "C" ~header ~row ~inner_width;
    check_left_cell "RESULT" "D" ~header ~row ~inner_width;
    check_left_cell "FILE" "E" ~header ~row ~inner_width;
    check_left_cell "WHAT" "F" ~header ~row ~inner_width;
    (* The file cell was padded and never fitted, so this row used to be wider
       than its header by the length of the path. *)
    check int
      (Printf.sprintf "inner %d: a long path no longer widens the row" inner_width)
      (width header)
      (width
         (Schedule.change_row ~op_style:"\027[33m" ~result_style:"\027[31m"
            ~summary_width change_overflowing))
  done

(* Every column name has to survive its own column.

   Header and row are padded through the same fit, so a name wider than the
   column it labels can no longer push the columns after it -- it folds
   instead. That trades a shifted table for an unreadable one: "Task ->
   Overview" in a column of fourteen would have been drawn "Task -> Ov...iew".
   Neither is acceptable, and only this notices the second. *)

(* The widest bracketed phase label the renderer computes; the columns after
   it are placed from this, so the sweep uses one value for both. *)
let planning_phase_width = 11

let test_headers_fit_their_columns () =
  for inner_width = 80 to 240 do
    let headers =
      [ ( "memory"
        , Schedule.memory_header_row
            (Schedule.allocate_memory_columns ~inner_width) )
      ; ( "workspace"
        , Schedule.workspace_header_row
            ~path_width:(Schedule.workspace_path_width ~inner_width) )
      ; ( "system log"
        , Schedule.system_log_header_row
            ~message_width:(Schedule.system_log_message_width ~inner_width) )
      ; ( "lane run"
        , Schedule.lane_run_header_row ~identity_header:"ACTOR"
            ~run_id_width:(Schedule.lane_run_id_width ~inner_width) )
      ; ( "change"
        , Schedule.change_header_row
            ~summary_width:(Schedule.change_summary_width ~inner_width) )
      ; ( "fusion"
        , let keeper_width = 16 in
          Schedule.fusion_header_row
            (Schedule.allocate_fusion_columns ~inner_width ~keeper_width) )
      ; ( "planning"
        , let phase_width = planning_phase_width in
          Schedule.planning_header_row ~phase_width
            ~title_width:
              (Schedule.planning_title_width ~inner_width ~phase_width) )
      ; ( "harness"
        , Schedule.harness_header_row
            ~reason_width:(Schedule.harness_reason_width ~inner_width) )
      ; ( "board"
        , Schedule.board_header_row ~age_header:"AGE"
            ~title_width:(Schedule.board_title_width ~inner_width) )
      ]
    in
    List.iter
      (fun (screen, header) ->
        check bool
          (Printf.sprintf "inner %d: %s names every column whole" inner_width
             screen)
          true
          (index_of header "\xe2\x80\xa6" = None))
      headers
  done

(* Harness verdict columns. The header called the task column
   "Task -> Overview" -- fifteen cells in a column of fourteen -- so it pushed
   every column after it one cell right of the rows it labelled. *)

let harness_probe =
  { Schedule.hrow_time = "A"
  ; hrow_task = "B"
  ; hrow_gate = "C"
  ; hrow_verdict = "D"
  ; hrow_evaluator = "E"
  ; hrow_reason = "F"
  }

let harness_overflowing =
  { Schedule.hrow_time = "2026-09-03 11:08:43.512"
  ; hrow_task = "task-1279-and-a-good-deal-more"
  ; hrow_gate = "completion-contract"
  ; hrow_verdict = "inconclusive"
  ; hrow_evaluator = "pinewood-pr-jira-checker-verifier"
  ; hrow_reason = String.concat "" (List.init 20 (fun _ -> "reason "))
  }

let test_harness_columns_hold_their_offsets () =
  for inner_width = 80 to 240 do
    let reason_width = Schedule.harness_reason_width ~inner_width in
    let width text = Masc_tui_message_layout.display_width text in
    let header = Schedule.harness_header_row ~reason_width in
    let row = Schedule.harness_row ~verdict_style:"" ~reason_width harness_probe in
    check_left_cell "TIME" "A" ~header ~row ~inner_width;
    check_left_cell "TASK" "B" ~header ~row ~inner_width;
    check_left_cell "GATE" "C" ~header ~row ~inner_width;
    check_left_cell "VERDICT" "D" ~header ~row ~inner_width;
    check_left_cell "EVALUATOR" "E" ~header ~row ~inner_width;
    check_left_cell "REASON" "F" ~header ~row ~inner_width;
    (* The task and gate cells were padded and never fitted, so a long id used
       to make this row wider than the header it sits under. *)
    check int
      (Printf.sprintf "inner %d: a long id no longer widens the row" inner_width)
      (width header)
      (width
         (Schedule.harness_row ~verdict_style:"\027[31m" ~reason_width
            harness_overflowing))
  done

(* Fusion run columns. The run id was unbounded where it was named and cut at
   fourteen where it was filled. *)

let fusion_probe =
  { Schedule.frow_time = "A"
  ; frow_age = "B"
  ; frow_state = "C"
  ; frow_keeper = "D"
  ; frow_preset = "E"
  ; frow_run = "F"
  }

let fusion_overflowing =
  { Schedule.frow_time = "2026-09-07 11:08"
  ; frow_age = "1234.5s"
  ; frow_state = "cancelled-by-the-operator"
  ; frow_keeper = "pinewood-pr-jira-checker"
  ; frow_preset = "antigravity-high"
  ; frow_run = "run-1788427841647-00000-abcdef"
  }

let test_fusion_columns_hold_their_offsets () =
  let keeper_width = 16 in
  for inner_width = 80 to 240 do
    let columns = Schedule.allocate_fusion_columns ~inner_width ~keeper_width in
    let width text = Masc_tui_message_layout.display_width text in
    let header = Schedule.fusion_header_row columns in
    let row =
      Schedule.fusion_row ~state_style:"" columns fusion_probe
    in
    check_left_cell "STARTED" "A" ~header ~row ~inner_width;
    check_right_cell "AGE" "B" ~header ~row ~inner_width;
    (* The Fusion table's state column is still headed STATE. Reading "ST"
       here found it inside STARTED, the column beside it, and placed the
       state cell at 0 -- see [offset_of], which now refuses a label that
       appears twice. *)
    check_left_cell "STATE" "C" ~header ~row ~inner_width;
    check_left_cell "KEEPER" "D" ~header ~row ~inner_width;
    if columns.fcol_show_preset then
      check_left_cell "PRESET" "E" ~header ~row ~inner_width;
    check_left_cell "RUN" "F" ~header ~row ~inner_width;
    check int
      (Printf.sprintf "inner %d: a dressed overflowing run" inner_width)
      (width header)
      (width
         (Schedule.fusion_row ~state_style:"\027[31m" columns
            fusion_overflowing))
  done

(* The keeper cell is sized to the names on screen, so a wider one has to come
   out of the run id rather than out of the frame. *)
let test_fusion_keeper_growth_comes_out_of_the_run_id () =
  let inner_width = 140 in
  let narrow = Schedule.allocate_fusion_columns ~inner_width ~keeper_width:16 in
  let wide = Schedule.allocate_fusion_columns ~inner_width ~keeper_width:26 in
  check int "ten cells move from the run id to the keeper" (narrow.fcol_run - 10) wide.fcol_run;
  check int "and the row is the same width either way"
    (Masc_tui_message_layout.display_width
       (Schedule.fusion_header_row narrow))
    (Masc_tui_message_layout.display_width
       (Schedule.fusion_header_row wide));
  let inner_width = 80 - 6 in
  let compact = Schedule.allocate_fusion_columns ~inner_width ~keeper_width:26 in
  let header = Schedule.fusion_header_row compact in
  let row = Schedule.fusion_row ~state_style:"" compact fusion_overflowing in
  check bool "80-column terminal keeps a complete table inside its frame" true
    (Masc_tui_message_layout.display_width header <= inner_width
     && Masc_tui_message_layout.display_width row <= inner_width);
  check bool "narrow table gives preset cells to identities" false compact.fcol_show_preset;
  check bool "the local start date remains whole" true
    (String.starts_with ~prefix:"2026-09-07 11:08" row)

(* A failed run's STATE cell draws its failure code, and the codes come from
   two closed sets the server writes: the judge's and the delivery's. The
   widest of them is [evidence_unavailable]; folded, it would read as some
   other code. *)
let test_the_widest_failure_code_fits_the_state_cell () =
  let code = "evidence_unavailable" in
  let columns =
    Schedule.allocate_fusion_columns ~inner_width:110 ~keeper_width:16
  in
  let row =
    Schedule.fusion_row ~state_style:"" columns
      { fusion_probe with frow_state = code }
  in
  check bool (Printf.sprintf "%s is drawn whole: %s" code row) true
    (Option.is_some (index_of row code))

let test_fusion_sidebar_label_format () =
  let label =
    Schedule.fusion_sidebar_label ~status:"done" ~time:"14:20:05"
      ~keeper:"edgar" ~run_id:"fusion-target-501"
  in
  check string "label starts with status, time, keeper, and run id"
    "[done] 14:20:05 @edgar fusion-target-501" label

let test_fusion_pipeline_diagram_stages () =
  let running_judge =
    Schedule.fusion_pipeline_diagram
      ~status:`Running ~stage:`Judge ~panel_answered:3 ~panel_expected:3 ()
  in
  check string "running judge diagram"
    "● 1 Question ▸ ● 2 Panel(3/3) ▸ ◐ 3 Judge ▸ ○ 4 Evidence"
    running_judge;
  let running_panel =
    Schedule.fusion_pipeline_diagram
      ~status:`Running ~stage:`Panel ~panel_answered:0 ~panel_expected:3 ()
  in
  check string "running panel diagram"
    "● 1 Question ▸ ◐ 2 Panel(3) ▸ ○ 3 Judge ▸ ○ 4 Evidence"
    running_panel;
  let completed =
    Schedule.fusion_pipeline_diagram
      ~status:`Completed ~stage:`Completed ~panel_answered:3 ~panel_expected:3 ()
  in
  check string "completed diagram"
    "● 1 Question ▸ ● 2 Panel ▸ ● 3 Judge ▸ ● 4 Evidence"
    completed;
  let failed =
    Schedule.fusion_pipeline_diagram
      ~status:`Failed ~stage:`Failed ~panel_answered:0 ~panel_expected:0 ()
  in
  check string "failed diagram"
    "● 1 Question ▸ × 2 Panel ▸ × 3 Judge ▸ × 4 Evidence"
    failed


(* The strip named five stops while the Planning walk had three: Schedules and
   Fusion had become tabs of the selected Keeper and nothing took their names
   off this row. A reader pressing 4 or 5 arrived nowhere. *)
let test_planning_strip_names_only_its_own_stops () =
  check (list string) "three stops, and Schedules and Fusion are not among them"
    [ "Goals"; "Task Review"; "Task Verdicts" ]
    (Schedule.planning_strip_plain ~tab:Schedule.Planning_goals
       ~review_count:None ~verifying_count:None ~window:"")

(* The numbers promised an order the surfaces do not have, and the key sheet
   joined them with arrows. A goal that enters [verifying] is judged against
   the goal ledger; it never appears on Task Review, which is the task
   protocol's queue. The two task stops keep a shared word instead, so the
   axis they belong to is what the strip says. *)
let test_planning_strip_does_not_number_its_stops () =
  let labels =
    Schedule.planning_strip_plain ~tab:Schedule.Planning_goals
      ~review_count:(Some 7) ~verifying_count:(Some 2) ~window:""
  in
  check (list string) "counts, no ordinals"
    [ "Goals\xc2\xb72"; "Task Review\xc2\xb77"; "Task Verdicts" ]
    labels

(* The verdict page count read as a Fusion count: it was appended after the
   whole strip, and the strip ended with "5 Fusion". A window belongs to the
   tab the reader is on and to no other. *)
let test_planning_window_rides_the_active_stop () =
  check (list string) "the window sits on Verdicts"
    [ "Goals"; "Task Review\xc2\xb7979"; "Task Verdicts (8 of 4223)" ]
    (Schedule.planning_strip_plain ~tab:Schedule.Planning_verdicts
       ~review_count:(Some 979) ~verifying_count:None ~window:" (8 of 4223)");
  check (list string) "and moves with the reader"
    [ "Goals"; "Task Review\xc2\xb7979 (20 of 979)"; "Task Verdicts" ]
    (Schedule.planning_strip_plain ~tab:Schedule.Planning_task_review
       ~review_count:(Some 979) ~verifying_count:None ~window:" (20 of 979)")

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

(* A held schedule keeps [due] as its status and the previous occurrence's
   wake as its last wake, so the hold reading is the only thing on the screen
   saying it waits (#38205). It names the held due and says what it waits for
   in words, not the wire's field name. *)
let test_a_held_schedule_says_what_it_waits_for () =
  let reading = Schedule.schedule_hold_reading ~due:"09-23 12:34" in
  let has needle =
    let n = String.length needle and m = String.length reading in
    let rec go i = i + n <= m && (String.sub reading i n = needle || go (i + 1)) in
    go 0
  in
  check bool "it opens with the word held" true
    (String.length reading >= 4 && String.sub reading 0 4 = "held");
  check bool "it names when the held occurrence came due" true (has "09-23 12:34");
  check bool "it says the keeper has the previous wake" true (has "previous wake");
  check bool "it does not print the wire field" false (has "runner_hold");
  let tag = Schedule.schedule_hold_tag ~due:"09-23 12:34" in
  check bool "the short tag leads the full reading" true
    (String.length reading >= String.length tag
     && String.sub reading 0 (String.length tag) = tag)
;;

(* #38411: while the runner is not ok, the hold on screen is the one it read
   at its last good tick. That reading names the time it was seen, and given
   the same time it must not come out as the current hold's tag, or a stale
   hold would read as the present again. *)
let test_a_hold_the_runner_has_not_reread_names_when_it_was_seen () =
  let checked = "09-23 12:40" in
  let tag = Schedule.schedule_hold_as_of_tag ~checked in
  let reading = Schedule.schedule_hold_as_of_reading ~checked in
  let has text needle =
    let n = String.length needle and m = String.length text in
    let rec go i = i + n <= m && (String.sub text i n = needle || go (i + 1)) in
    go 0
  in
  check bool "it names when the hold was seen" true (has tag checked);
  check bool "the short tag leads the full reading" true
    (String.length reading >= String.length tag
     && String.sub reading 0 (String.length tag) = tag);
  check bool "the tag is not the current hold's" false
    (String.equal tag (Schedule.schedule_hold_tag ~due:checked))
;;

(* Slack reaches the name and the runtime before the task id, and both stop at
   a cap so one very wide terminal does not spend eighty cells on a model
   name. *)
let test_keeper_columns_grow_identifiers_first () =
  let at width = Schedule.allocate_keeper_columns ~inner_width:width
      ~widest_runtime:old_runtime_ceiling in
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

(* Planning goal columns.

   The list named nothing and sized its title by subtracting a constant from
   the terminal, minus however wide the age and the due date happened to be.
   Both readings are optional, so the pair at the end of the row began at a
   different column on every row. *)

let planning_probe =
  { Schedule.prow_phase = "A"
  ; prow_proof = "B"
  ; prow_priority = "C"
  ; prow_open = "D"
  ; prow_title = "E"
  ; prow_age = "F"
  ; prow_due = "G"
  }

let planning_row_of ~title_width values =
  Schedule.planning_row ~phase_style:"" ~phase_width:planning_phase_width
    ~title_width values

let test_planning_columns_hold_their_offsets () =
  for inner_width = 80 to 240 do
    let title_width =
      Schedule.planning_title_width ~inner_width
        ~phase_width:planning_phase_width
    in
    let header =
      Schedule.planning_header_row ~phase_width:planning_phase_width
        ~title_width
    in
    let row = planning_row_of ~title_width planning_probe in
    check_left_cell "PHASE" "A" ~header ~row ~inner_width;
    (* The judge's column was the one column with a blank header, so nothing
       here could hold it in place. *)
    check_left_cell "JUDGE" "B" ~header ~row ~inner_width;
    check_left_cell "PRI" "C" ~header ~row ~inner_width;
    check_left_cell "OPEN" "D" ~header ~row ~inner_width;
    check_left_cell "TITLE" "E" ~header ~row ~inner_width;
    check_right_cell "AGE" "F" ~header ~row ~inner_width;
    check_left_cell "DUE" "G" ~header ~row ~inner_width
  done

let test_planning_columns_with_styles_hold_their_offsets () =
  for inner_width = 80 to 240 do
    let title_width =
      Schedule.planning_title_width ~inner_width
        ~phase_width:planning_phase_width
    in
    let header =
      Schedule.planning_header_row ~phase_width:planning_phase_width
        ~title_width
    in
    let row =
      Schedule.planning_row ~phase_style:"\027[32m" ~priority_style:"\027[31m"
        ~open_style:"\027[33m" ~phase_width:planning_phase_width ~title_width
        planning_probe
    in
    check_left_cell "PHASE" "A" ~header ~row ~inner_width;
    (* The judge's column was the one column with a blank header, so nothing
       here could hold it in place. *)
    check_left_cell "JUDGE" "B" ~header ~row ~inner_width;
    check_left_cell "PRI" "C" ~header ~row ~inner_width;
    check_left_cell "OPEN" "D" ~header ~row ~inner_width;
    check_left_cell "TITLE" "E" ~header ~row ~inner_width;
    check_right_cell "AGE" "F" ~header ~row ~inner_width;
    check_left_cell "DUE" "G" ~header ~row ~inner_width
  done

let board_probe =
  { Schedule.brow_mark = "@"
  ; brow_id = "A"
  ; brow_hearth = "B"
  ; brow_author = "C"
  ; brow_title = "D"
  ; brow_age = "E"
  ; brow_score = "F"
  ; brow_replies = "G"
  }

let board_row_of ~title_width values =
  Schedule.board_row ~styles:Schedule.board_no_styles ~age_header:"AGE" ~title_width values

let test_board_columns_hold_their_offsets () =
  for inner_width = 80 to 240 do
    let title_width = Schedule.board_title_width ~inner_width in
    let header = Schedule.board_header_row ~age_header:"AGE" ~title_width in
    let row = board_row_of ~title_width board_probe in
    check_left_cell "ID" "A" ~header ~row ~inner_width;
    check_left_cell "HEARTH" "B" ~header ~row ~inner_width;
    check_left_cell "AUTHOR" "C" ~header ~row ~inner_width;
    check_left_cell "TITLE" "D" ~header ~row ~inner_width;
    check_right_cell "AGE" "E" ~header ~row ~inner_width;
    check_left_cell "SCORE" "F" ~header ~row ~inner_width;
    check_left_cell "REPLIES" "G" ~header ~row ~inner_width
  done

let test_board_columns_with_styles_hold_their_offsets () =
  let styles =
    { Schedule.bstyle_id = "\027[36m"
    ; bstyle_hearth = "\027[34m"
    ; bstyle_author = "\027[36m"
    ; bstyle_age = "\027[2m"
    ; bstyle_score = "\027[32m"
    ; bstyle_replies = "\027[33m"
    }
  in
  for inner_width = 80 to 240 do
    let title_width = Schedule.board_title_width ~inner_width in
    let header = Schedule.board_header_row ~age_header:"AGE" ~title_width in
    let row = Schedule.board_row ~styles ~age_header:"AGE" ~title_width board_probe in
    check_left_cell "ID" "A" ~header ~row ~inner_width;
    check_left_cell "HEARTH" "B" ~header ~row ~inner_width;
    check_left_cell "AUTHOR" "C" ~header ~row ~inner_width;
    check_left_cell "TITLE" "D" ~header ~row ~inner_width;
    check_right_cell "AGE" "E" ~header ~row ~inner_width;
    check_left_cell "SCORE" "F" ~header ~row ~inner_width;
    check_left_cell "REPLIES" "G" ~header ~row ~inner_width
  done

(* The title is the one column on these two screens that carries a sentence.
   A post's subject is at the front of its title, so the title keeps its head
   and gives way at the tail. Every other column here names a thing -- an id,
   a hearth, an author -- and keeps both ends. *)
let test_a_title_gives_way_at_its_tail () =
  let title =
    "Verify: run-exact-output-lane-board-attention-9e327af211400cba719b59128"
  in
  (* The pane the Board draws in beside the roster: 114 cells. *)
  let title_width = Schedule.board_title_width ~inner_width:114 in
  let board = board_row_of ~title_width { board_probe with brow_title = title } in
  let planning =
    planning_row_of
      ~title_width:
        (Schedule.planning_title_width ~inner_width:114
           ~phase_width:planning_phase_width)
      { planning_probe with prow_title = title }
  in
  List.iter
    (fun (screen, row) ->
      check bool
        (Printf.sprintf "%s keeps the subject: %s" screen row)
        true
        (Option.is_some (index_of row "Verify: run-exact"));
      check bool
        (Printf.sprintf "%s does not keep the tail instead: %s" screen row)
        false
        (Option.is_some (index_of row "719b59128")))
    [ ("board", board); ("planning", planning) ]

(* The other four readings that are sentences rather than names. They are laid
   out on the same contract, and each is the last column of its screen, so the
   fold is the only thing that decides what a reader gets. *)
let test_every_sentence_column_gives_way_at_its_tail () =
  let sentence =
    "Verify: run-exact-output-lane-board-attention-9e327af211400cba719b59128"
  in
  let prose_width = 24 in
  let rows =
    [ ( "system log"
      , Schedule.system_log_row ~message_width:prose_width ~level_style:""
          ~styles:Schedule.system_log_plain_styles
          { system_log_probe with slog_message = sentence } )
    ; ( "verification"
      , Schedule.verification_row ~submitter_width:16
          ~title_width:prose_width
          { verification_probe with vrow_title = sentence } )
    ; ( "changes"
      , Schedule.change_row ~op_style:"" ~result_style:""
          ~summary_width:prose_width
          { change_probe with crow_summary = sentence } )
    ; ( "harness"
      , Schedule.harness_row ~verdict_style:"" ~reason_width:prose_width
          { harness_probe with hrow_reason = sentence } )
    ]
  in
  List.iter
    (fun (screen, row) ->
      check bool
        (Printf.sprintf "%s keeps the front: %s" screen row)
        true
        (Option.is_some (index_of row "Verify: run-"));
      check bool
        (Printf.sprintf "%s does not keep the tail instead: %s" screen row)
        false
        (Option.is_some (index_of row "719b59128")))
    rows

(* The id beside it is the reading whose two ends say which run it is. *)
let test_a_board_id_keeps_both_ends () =
  let row =
    board_row_of ~title_width:40
      { board_probe with brow_id = "p-6dc0a4e7eb813cc1" }
  in
  check bool "the head is drawn" true (Option.is_some (index_of row "p-6"));
  check bool "and so is the tail" true (Option.is_some (index_of row "813cc1"))

(* The defect this closes. The rows sized the title to the terminal minus a
   hand-summed constant and the header claimed its own, so at eighty columns
   the header ran long, pushed SCORE into the frame and REPLIES off it. Both
   read one description now, so a row is exactly as wide as the header over it
   whatever any reading measures. *)
let test_a_board_row_is_as_wide_as_its_header () =
  List.iter
    (fun inner_width ->
      let title_width = Schedule.board_title_width ~inner_width in
      let header = Schedule.board_header_row ~age_header:"AGE" ~title_width in
      let width text = Masc_tui_message_layout.display_width text in
      List.iter
        (fun (name, values) ->
          check int
            (Printf.sprintf "inner %d: %s stays on the header's width"
               inner_width name)
            (width header)
            (width (board_row_of ~title_width values)))
        [ ( "empty"
          , { Schedule.brow_mark = ""
            ; brow_id = ""
            ; brow_hearth = ""
            ; brow_author = ""
            ; brow_title = ""
            ; brow_age = ""
            ; brow_score = ""
            ; brow_replies = ""
            } )
        ; "probe", board_probe
        ; ( "an id past its column"
          , { board_probe with Schedule.brow_id = String.make 40 'x' } )
        ; ( "a title past its column"
          , { board_probe with Schedule.brow_title = String.make 300 'x' } )
        ; ( "an author past its column"
          , { board_probe with Schedule.brow_author = String.make 40 'x' } )
        ])
    [ 80; 100; 120; 200 ]

(* The gaps came back to one with the rest of the fleet. Board was spacing its
   columns two cells apart, which spent six cells of every title on being
   different from every other table on the screen.

   Measured with every column overfull, so nothing between two readings is a
   column's own padding: what is left between them is the gap, and one gap is
   one space. *)
let test_board_spaces_its_columns_like_every_other_table () =
  let inner_width = 120 in
  let title_width = Schedule.board_title_width ~inner_width in
  let fill char = String.make 60 char in
  let row =
    board_row_of ~title_width
      { Schedule.brow_mark = "@"
      ; brow_id = fill 'a'
      ; brow_hearth = fill 'b'
      ; brow_author = fill 'c'
      ; brow_title = fill 'd'
      ; brow_age = fill 'e'
      ; brow_score = fill 'f'
      ; brow_replies = fill 'g'
      }
  in
  check int "the contract's gap is what every table spaces by" 1
    Masc_tui_table.cell_gap;
  check bool "no two readings are further apart than that" false
    (index_of row "  " <> None)

(* The defect this closes. A goal with no due date used to pull the age and
   the date ten cells left of the goal above it, because the title was sized
   from what those two happened to measure on that row. *)
let test_an_absent_date_does_not_move_the_age () =
  let inner_width = 120 in
  let title_width =
    Schedule.planning_title_width ~inner_width ~phase_width:planning_phase_width
  in
  let with_both =
    planning_row_of ~title_width
      { planning_probe with Schedule.prow_age = "F"; prow_due = "2026-09-04" }
  in
  let without_date =
    planning_row_of ~title_width
      { planning_probe with Schedule.prow_age = "F"; prow_due = "" }
  in
  let long_title =
    planning_row_of ~title_width
      { planning_probe with
        Schedule.prow_title = String.make 200 'x'
      ; prow_age = "F"
      ; prow_due = ""
      }
  in
  let age_at row =
    match index_of row "F" with
    | Some at -> Masc_tui_message_layout.display_width (String.sub row 0 at)
    | None -> Alcotest.failf "the age is not in %S" row
  in
  check int "an absent date leaves the age where it was" (age_at with_both)
    (age_at without_date);
  check int "and a title past its column does not move it either"
    (age_at with_both) (age_at long_title);
  check int "every row is as wide as the others"
    (Masc_tui_message_layout.display_width with_both)
    (Masc_tui_message_layout.display_width without_date)

(* A post with no time has no age. Read as the epoch, it drew twenty thousand
   days folded into the column as "2…d09h". *)
let test_a_board_post_without_a_time_has_no_age () =
  check string "a known time is a span" "1h00m"
    (Schedule.board_age_text ~now:7200. (Some 3600.));
  check string "no time is a dash, not an age" "\xe2\x80\x94"
    (Schedule.board_age_text ~now:7200. None)

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
        ; test_case "team detail lines take only spare rows" `Quick
            test_team_detail_lines_take_only_spare_rows
        ; test_case "overview team block sits between panel and backlog" `Quick
            test_overview_team_block_sits_between_panel_and_backlog
        ; test_case "board read reserves comments and footer" `Quick
            test_board_read_rows_reserve_comments_and_footer
        ; test_case "board read reaches hidden comments" `Quick
            test_board_read_scroll_reaches_hidden_comments
        ; test_case "board read side layout falls back when narrow" `Quick
            test_board_read_side_layout_falls_back_when_narrow
        ; test_case "board read side allocation reserves the heading" `Quick
            test_board_read_side_allocation_reserves_the_heading
        ; test_case "board read side layout opens head-first" `Quick
            test_board_read_side_layout_opens_head_first
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
        ; test_case "the runtime column grows to the ids it holds" `Quick
            test_the_runtime_column_grows_to_the_ids_it_holds
        ; test_case "the runtime column stops at what it holds" `Quick
            test_the_runtime_column_stops_at_what_it_holds
        ; test_case "memory columns never exceed their width" `Quick
            test_memory_columns_never_exceed_their_width
        ; test_case "the memory delta column holds a pair of counts" `Quick
            test_the_memory_delta_column_holds_a_pair_of_counts
        ; test_case "memory header and row share their offsets" `Quick
            test_memory_header_and_row_share_their_offsets
        ; test_case "memory row width ignores its readings" `Quick
            test_memory_row_width_does_not_depend_on_its_readings
        ; test_case "memory empty readings still hold their cells" `Quick
            test_memory_empty_readings_still_hold_their_cells
        ; test_case "memory columns drop from the right" `Quick
            test_memory_columns_drop_from_the_right
        ; test_case "memory name width never shrinks" `Quick
            test_memory_name_width_never_shrinks_as_the_terminal_grows
        ; test_case "workspace path takes the remainder" `Quick
            test_workspace_path_takes_the_remainder
        ; test_case "workspace header and row share their offsets" `Quick
            test_workspace_header_and_row_share_their_offsets
        ; test_case "workspace row width ignores its readings" `Quick
            test_workspace_row_width_does_not_depend_on_its_readings
        ; test_case "system log colour costs no cells" `Quick
            test_system_log_colour_costs_no_cells
        ; test_case "verification rows stay on the header columns" `Quick
            test_verification_rows_stay_on_the_header_columns
        ; test_case "verification names its columns in capitals" `Quick
            test_verification_names_its_columns_in_capitals
        ; test_case "verification title takes the remainder" `Quick
            test_verification_title_takes_the_remainder
        ; test_case "schedule rows stay on the header columns" `Quick
            test_schedule_rows_stay_on_the_header_columns
        ; test_case "schedule recurrence takes the remainder" `Quick
            test_schedule_recurrence_takes_the_remainder
        ; test_case "schedule names its columns once" `Quick
            test_schedule_names_its_columns_once
        ; test_case "system log message takes the remainder" `Quick
            test_system_log_message_takes_the_remainder
        ; test_case "system log header and row share their offsets" `Quick
            test_system_log_header_and_row_share_their_offsets
        ; test_case "lane columns hold their offsets" `Quick
            test_lane_columns_hold_their_offsets
        ; test_case "change columns hold their offsets" `Quick
            test_change_columns_hold_their_offsets
        ; test_case "harness columns hold their offsets" `Quick
            test_harness_columns_hold_their_offsets
        ; test_case "planning columns hold their offsets" `Quick
            test_planning_columns_hold_their_offsets
        ; test_case "planning columns with styles hold their offsets" `Quick
            test_planning_columns_with_styles_hold_their_offsets
        ; test_case "board columns hold their offsets" `Quick
            test_board_columns_hold_their_offsets
        ; test_case "board columns with styles hold their offsets" `Quick
            test_board_columns_with_styles_hold_their_offsets
        ; test_case "a title gives way at its tail" `Quick
            test_a_title_gives_way_at_its_tail
        ; test_case "every sentence column gives way at its tail" `Quick
            test_every_sentence_column_gives_way_at_its_tail
        ; test_case "a board id keeps both ends" `Quick
            test_a_board_id_keeps_both_ends
        ; test_case "a board row is as wide as its header" `Quick
            test_a_board_row_is_as_wide_as_its_header
        ; test_case "board spaces its columns like every other table" `Quick
            test_board_spaces_its_columns_like_every_other_table
        ; test_case "an absent date does not move the age" `Quick
            test_an_absent_date_does_not_move_the_age
        ; test_case "every header fits its column" `Quick
            test_headers_fit_their_columns
        ; test_case "fusion columns hold their offsets" `Quick
            test_fusion_columns_hold_their_offsets
        ; test_case "fusion keeper growth comes out of the run id" `Quick
            test_fusion_keeper_growth_comes_out_of_the_run_id
        ; test_case "the widest failure code fits the state cell" `Quick
            test_the_widest_failure_code_fits_the_state_cell
        ; test_case "fusion sidebar label format" `Quick
            test_fusion_sidebar_label_format
        ; test_case "fusion pipeline diagram stages" `Quick
            test_fusion_pipeline_diagram_stages
        ; test_case "planning strip names only its own stops" `Quick
            test_planning_strip_names_only_its_own_stops
        ; test_case "planning strip does not number its stops" `Quick
            test_planning_strip_does_not_number_its_stops
        ; test_case "planning window rides the active stop" `Quick
            test_planning_window_rides_the_active_stop
        ; test_case "a capped page cannot report an empty store" `Quick
            test_capped_page_cannot_report_an_empty_store
        ; test_case "wake readings stay four separate answers" `Quick
            test_wake_readings_stay_four_separate_answers
        ; test_case "a board post without a time has no age" `Quick
            test_a_board_post_without_a_time_has_no_age
        ; test_case "a held schedule says what it waits for" `Quick
            test_a_held_schedule_says_what_it_waits_for
        ; test_case "a hold the runner has not reread names when it was seen"
            `Quick
            test_a_hold_the_runner_has_not_reread_names_when_it_was_seen
        ] )
    ]
