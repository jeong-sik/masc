(* A page key moves a list by the height the frame reports it drew that list
   in, less one (RFC tui-one-screen-grammar §3.1). The key reads the report
   and nothing else, so the report has to be the rows the renderer drew for
   the list. These tests draw the lists at two terminal sizes and every
   selection, count the list's rows in the frame, and press PgDn and PgUp
   through the move keys' own choice ([Masc_tui_list_moves.moves]) to see
   the entry read last stay on screen. *)

open Masc_tui_types
module Prim = Masc_tui_render_prim
module Moves = Masc_tui_list_moves
module Key = Masc_tui_scroll

let sizes = [ 24, 80; 40, 120 ]

(* The terminal the frame is drawn for, put back afterwards. *)
let with_size (rows, cols) draw =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let previous_reserved = !Prim.acting_pane_reserved_cols in
  let set size =
    ignore
      (Masc_tui_render_schedule.Terminal_size_cache.refresh cache ~probe:(fun () -> Some size))
  in
  set (rows, cols);
  Prim.acting_pane_reserved_cols := 0;
  Fun.protect
    ~finally:(fun () ->
      set previous;
      Prim.acting_pane_reserved_cols := previous_reserved)
    draw

(* The frame's lines without colour, and the lists it reported drawn. *)
let draw render state =
  Prim.frame_lists := [];
  let frame, _ = render state in
  ( List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines
  , !Prim.frame_lists )

let rows_naming marker lines =
  let has line =
    let length = String.length marker in
    let rec at index =
      index + length <= String.length line
      && (String.sub line index length = marker || at (index + 1))
    in
    at 0
  in
  List.length (List.filter has lines)

let reported list lists =
  List.filter_map
    (fun (drawn : drawn_list) -> if drawn.dl_list = list then Some drawn.dl_height else None)
    lists

let board_post index : board_post =
  { bp_id = Printf.sprintf "post-%02d" index
  ; bp_author = "author"
  ; bp_title = Printf.sprintf "zq-%02d" index
  ; bp_body = ""
  ; bp_votes = 0
  ; bp_comment_count = 0
  ; bp_created_at = "2026-11-19T00:00:00Z"
  ; bp_created_at_unix = Some 1_790_000_000.
  ; bp_updated_at = Some 1_790_000_000.
  ; bp_hearth = None
  ; bp_kind = None
  ; bp_closed = None
  ; bp_attachments = [] }

(* QA N01's shape on the Board: the list is cut below a heading, and its page
   was the body less eight, so PgDn at 80x24 moved past rows nobody saw.
   Every selection reports the Board list once, as tall as the post rows the
   frame drew. *)
let test_board_reports_the_rows_it_drew () =
  let posts = List.init 40 board_post in
  List.iter
    (fun size ->
      with_size size (fun () ->
        let state = create_state ~workspace:"" ~port:0 () in
        state.view <- Board;
        state.board_listing <-
          Masc_tui_fetched.Ready { bl_query = board_query state; bl_posts = posts };
        List.iter
          (fun cursor ->
            state.board_cursor <- cursor;
            let lines, lists = draw Masc_tui_render_board.render_board_list state in
            Alcotest.(check (list int))
              (Printf.sprintf "%dx%d, post %d: the height reported is the post rows drawn"
                 (snd size) (fst size) cursor)
              [ rows_naming "zq-" lines ] (reported Board_post_rows lists);
            Alcotest.(check int) "no other list is reported" 1 (List.length lists))
          [ 0; 1; 20; 39 ]))
    sizes

let model_row index : Masc_tui_model_runtime_table.row =
  { model = Printf.sprintf "mq-%02d" index
  ; provider = "prov"
  ; api_name = None
  ; reasoning_effort = None
  ; temperature = None
  ; context = None
  ; model_context = None
  ; max_tokens = Some 1000
  ; same_login = []
  ; login_group = None
  ; account_label = None }

let models_state ~emails rows =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Config;
  state.config_pane <- Config_models;
  let metadata : Masc_tui_runtime_config_view.metadata =
    { source_revision = "r"
    ; validation =
        Checked
          { valid = true; schema_version = 1; current_schema_version = 1
          ; forward_schema = false; issues = [] }
    ; routing = Routing_active; routing_requires_restart = false
    ; keeper = Not_configured; keeper_requires_restart = false
    ; configured_count = 0; pending_keys = []; applied_keys = []; preempted_keys = [] }
  in
  state.runtime_config_view <-
    Some
      { rcv_path = "runtime.toml"; rcv_source_text = ""; rcv_rows = []
      ; rcv_metadata = metadata
      ; rcv_account_emails = emails };
  state.config_models_rows <- rows;
  state

(* The Models table draws its column names on its first line until the
   selection passes the first window, so a window shows one binding fewer at
   the top than further down. A page is the fewest bindings any window shows
   whole: the report is that, the same for every selection, and no window
   draws fewer. Reported as the pane's height, PgDn from the top window
   passed the binding under its last row. The account lines above the table
   take one row when the account is read and two when it is not, so the
   table's height is the drawing's and no fixed share of the body. *)
let test_models_report_the_fewest_bindings_a_window_draws () =
  let count = 60 in
  let accounts =
    [ "read", Ok (Masc_tui_account_login.Email_rows { rows = []; unattributed = 0 })
    ; "unread", Error "account evidence unavailable" ]
  in
  List.iter
    (fun (size, (account, emails)) ->
      with_size size (fun () ->
        let state = models_state ~emails (List.init count model_row) in
        let drawn_at cursor =
          state.config_models_cursor <- cursor;
          Option.iter
            (fun (list : Masc_tui_render_config.models_list) ->
              state.config_scroll <- list.ml_window ~cursor state.config_scroll)
            (Masc_tui_render_config.config_models_list state ~terminal_rows:(fst size)
               ~cols:(snd size));
          let lines, lists = draw Masc_tui_render_config.render_config_models state in
          (rows_naming "mq-" lines, reported Model_bindings lists)
        in
        let readings = List.init count drawn_at in
        let fewest = List.fold_left (fun fewest (rows, _) -> min fewest rows) count readings in
        Alcotest.(check bool)
          (Printf.sprintf "%dx%d: the pane is shorter than the bindings" (snd size) (fst size))
          true (fewest < count);
        List.iteri
          (fun cursor (_, report) ->
            Alcotest.(check (list int))
              (Printf.sprintf "%dx%d, account %s, binding %d: the report is the fewest bindings drawn"
                 (snd size) (fst size) account cursor)
              [ fewest ] report)
          readings))
    (List.concat_map (fun size -> List.map (fun account -> size, account) accounts) sizes)

(* The entry numbers a frame draws: the two digits after each [marker]. *)
let drawn_entries marker lines =
  let length = String.length marker in
  List.filter_map
    (fun line ->
      let rec at index =
        if index + length + 2 > String.length line then None
        else if String.sub line index length = marker then
          int_of_string_opt (String.sub line (index + length) 2)
        else at (index + 1)
      in
      at 0)
    lines

(* The Work lists cut their window around the cursor, one place per entry:
   a Task and a Goal take two rows an entry, a schedule one. [place] is the
   dispatcher's landing for the list: it moves the cursor, and the next
   frame windows around it. *)
type work_list =
  { wl_name : string
  ; wl_list : paged_list
  ; wl_marker : string
  ; wl_count : int
  ; wl_render : state -> Masc_tui_frame_presenter.frame * clamped_scroll option
  ; wl_place : state -> int -> unit
  ; wl_cursor : state -> int }

(* Every selection reports the list once, as many entries as the frame drew.
   From every selection PgDn keeps the last entry drawn on screen and PgUp
   the first, each a page of that report less one. *)
let check_work_list (list : work_list) state =
  List.iter
    (fun size ->
      with_size size (fun () ->
        let label cursor =
          Printf.sprintf "%dx%d, %s %d" (snd size) (fst size) list.wl_name cursor
        in
        for cursor = 0 to list.wl_count - 1 do
          list.wl_place state cursor;
          let lines, lists = draw list.wl_render state in
          let shown = drawn_entries list.wl_marker lines in
          Alcotest.(check bool) (label cursor ^ ": the list is cut") true
            (List.length shown < list.wl_count);
          Alcotest.(check (list int))
            (label cursor ^ ": the report is the entries drawn")
            [ List.length shown ] (reported list.wl_list lists);
          List.iter
            (fun (key, kept, name) ->
              list.wl_place state cursor;
              state.lists_drawn <- lists;
              let rows : Moves.row_list =
                { rl_count = list.wl_count; rl_cursor = list.wl_cursor state
                ; rl_place = list.wl_place state }
              in
              (match
                 Moves.moves state
                   ~on_screen:(fun () -> Some { Moves.os_list = list.wl_list; os_rows = Some rows })
                   ~follow:(fun _ -> Alcotest.fail "a Work list asked to follow")
               with
               | Some moves -> moves key
               | None -> Alcotest.fail "no list answered the move key");
              let after, _ = draw list.wl_render state in
              Alcotest.(check bool)
                (Printf.sprintf "%s: %s keeps entry %d on screen" (label cursor) name kept)
                true (List.mem kept (drawn_entries list.wl_marker after)))
            [ Key.Page_down, List.fold_left max 0 shown, "PgDn"
            ; Key.Page_up, List.fold_left min list.wl_count shown, "PgUp" ]
        done))
    sizes

let task index : Tui_decode.task =
  { id = Printf.sprintf "task-%02d" index; title = Printf.sprintf "tq-%02d" index
  ; status = Masc_domain.Todo; priority = 1; goal_ids = [] }

let test_tasks_report_the_entries_they_drew () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Planning;
  state.tasks <- List.init 40 task;
  let place state index =
    state.task_focus <-
      Masc_tui_overview_tasks.Task_focus
        { selected = Option.map (fun (task : Tui_decode.task) -> task.id) (List.nth_opt state.tasks index) }
  in
  check_work_list
    { wl_name = "Task"; wl_list = Task_entries; wl_marker = "tq-"; wl_count = 40
    ; wl_render = Masc_tui_render_work.render_work_tasks; wl_place = place
    ; wl_cursor =
        (fun state ->
          Option.value ~default:0
            (Masc_tui_overview_tasks.work_selected_index state.tasks
               ~selected:(Masc_tui_overview_tasks.selection state.task_focus))) }
    state

let goal index : planning_goal =
  { pg_id = Printf.sprintf "goal-%02d" index
  ; pg_criterion_revision = None
  ; pg_title = Printf.sprintf "gq-%02d" index
  ; pg_phase = Goal_phase.Executing
  ; pg_priority = 1
  ; pg_due_date = None
  ; pg_measure = Goal_measure_fixture.measure
  ; pg_procedure = "read the fixture"
  ; pg_criterion_review = Tui_decode.Criterion_unavailable "fixture has no criterion review"
  ; pg_proof = Tui_decode.Proof_idle
  ; pg_retry_binding = None
  ; pg_verifier_unreconciled = None
  ; pg_last_review_note = None
  ; pg_last_review_at = None
  ; pg_created_at = None
  ; pg_updated_at = None }

let test_goals_report_the_entries_they_drew () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Planning;
  let goals = List.init 40 goal in
  state.planning <-
    Some
      { pl_goals = goals
      ; pl_rollup =
          { pr_active = 40; pr_verifying = 0; pr_awaiting_confirmation = 0; pr_done = 0
          ; pr_dropped = 0; pr_paused = 0; pr_blocked = 0 }
      ; pl_backlog =
          { pb_todo = 0; pb_claimed = 0; pb_running = 0; pb_awaiting_verification = 0
          ; pb_done = 0; pb_cancelled = 0 }
      ; pl_goal_history = []
      ; pl_generated_at = "2026-11-19T00:00:00Z" };
  (* The cursor counts the visible Goals; the fixture keeps them in order, so
     an entry's number is its place. *)
  Alcotest.(check (list string)) "the visible Goals keep the fixture's order"
    (List.map (fun (goal : planning_goal) -> goal.pg_id) goals)
    (List.map (fun (goal : planning_goal) -> goal.pg_id)
       (planning_visible_goals ~filter:state.planning_filter ~sort:state.planning_sort goals));
  check_work_list
    { wl_name = "Goal"; wl_list = Goal_entries; wl_marker = "gq-"; wl_count = 40
    ; wl_render = Masc_tui_render_work.render_planning_list
    ; wl_place = (fun state index -> state.planning_cursor <- index)
    ; wl_cursor = (fun state -> state.planning_cursor) }
    state

let test_docked_preview_mode_and_vertical_split () =
  let open Alcotest in
  check bool "compact -> half" true
    (cycle_docked_preview_mode Preview_compact = Preview_half);
  check bool "half -> full" true
    (cycle_docked_preview_mode Preview_half = Preview_full);
  check bool "full -> compact" true
    (cycle_docked_preview_mode Preview_full = Preview_compact);
  List.iter
    (fun total_rows ->
       List.iter
         (fun mode ->
            let split =
              docked_vertical_split ~total_rows ~mode ~has_selection:true
            in
            check int
              (Printf.sprintf "split conserves total_rows=%d" total_rows)
              total_rows (split.list_rows + split.preview_rows);
            check bool "nonnegative list_rows" true (split.list_rows >= 0);
            check bool "nonnegative preview_rows" true (split.preview_rows >= 0);
            if total_rows < 6 then
              check int "short screen drops preview cleanly" 0 split.preview_rows)
         [ Preview_compact; Preview_half; Preview_full ];
       let compact = docked_vertical_split ~total_rows ~mode:Preview_compact ~has_selection:true in
       let half = docked_vertical_split ~total_rows ~mode:Preview_half ~has_selection:true in
       let full = docked_vertical_split ~total_rows ~mode:Preview_full ~has_selection:true in
       check bool "preview grows monotonically compact <= half <= full" true
         (compact.preview_rows <= half.preview_rows && half.preview_rows <= full.preview_rows);
       let empty_sel = docked_vertical_split ~total_rows ~mode:Preview_full ~has_selection:false in
       check int "unselected keeps 0 preview rows" 0 empty_sel.preview_rows)
    [ 0; 3; 5; 6; 12; 20; 36 ];
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Planning;
  let goals = List.init 40 goal in
  state.planning <-
    Some
      { pl_goals = goals
      ; pl_rollup =
          { pr_active = 40; pr_verifying = 0; pr_awaiting_confirmation = 0; pr_done = 0
          ; pr_dropped = 0; pr_paused = 0; pr_blocked = 0 }
      ; pl_backlog =
          { pb_todo = 0; pb_claimed = 0; pb_running = 0; pb_awaiting_verification = 0
          ; pb_done = 0; pb_cancelled = 0 }
      ; pl_goal_history = []
      ; pl_generated_at = "2026-11-19T00:00:00Z" };
  List.iter
    (fun mode ->
       state.planning_preview_mode <- mode;
       check_work_list
         { wl_name = "Goal stage"; wl_list = Goal_entries; wl_marker = "gq-"; wl_count = 40
         ; wl_render = Masc_tui_render_work.render_planning_list
         ; wl_place = (fun state index -> state.planning_cursor <- index)
         ; wl_cursor = (fun state -> state.planning_cursor) }
         state)
    [ Preview_half; Preview_full ]

let test_keeper_column_latch_monotonic () =
  let open Alcotest in
  let state = create_state ~workspace:"" ~port:0 () in
  let l1 =
    latch_keeper_column_widths None ~view:state.keeper_list_view
      ~density:state.keeper_list_density ~inner:100 ~widest_runtime:20
      ~widest_detail:30
  in
  check int "initial runtime" 20 l1.kcl_widest_runtime;
  check int "initial detail" 30 l1.kcl_widest_detail;
  let l2 =
    latch_keeper_column_widths (Some l1) ~view:state.keeper_list_view
      ~density:state.keeper_list_density ~inner:100 ~widest_runtime:12
      ~widest_detail:15
  in
  check int "latched runtime holds high-water mark" 20 l2.kcl_widest_runtime;
  check int "latched detail holds high-water mark" 30 l2.kcl_widest_detail;
  let l3 =
    latch_keeper_column_widths (Some l2) ~view:state.keeper_list_view
      ~density:state.keeper_list_density ~inner:100 ~widest_runtime:28
      ~widest_detail:25
  in
  check int "grows monotonically" 28 l3.kcl_widest_runtime;
  check int "keeps detail max" 30 l3.kcl_widest_detail;
  let l4 =
    latch_keeper_column_widths (Some l3) ~view:state.keeper_list_view
      ~density:state.keeper_list_density ~inner:120 ~widest_runtime:14
      ~widest_detail:18
  in
  check int "resets when inner width changes" 14 l4.kcl_widest_runtime;
  cycle_keeper_list_view state;
  let l5 =
    latch_keeper_column_widths (Some l4) ~view:state.keeper_list_view
      ~density:state.keeper_list_density ~inner:120 ~widest_runtime:10
      ~widest_detail:12
  in
  check int "resets when keeper_list_view changes" 10 l5.kcl_widest_runtime;
  cycle_keeper_list_density state;
  let l6 =
    latch_keeper_column_widths (Some l5) ~view:state.keeper_list_view
      ~density:state.keeper_list_density ~inner:120 ~widest_runtime:8
      ~widest_detail:9
  in
  check int "resets when keeper_list_density changes" 8 l6.kcl_widest_runtime

let schedule index : schedule_row =
  { sch_schedule_id = Printf.sprintf "schedule-%02d" index
  ; sch_schedule_instance_id = "instance"
  ; sch_status = "scheduled"
  ; sch_source = "operator_request"
  ; sch_requested_by = "operator"
  ; sch_scheduled_by = "operator"
  ; sch_requested_at_iso = "2026-11-19T00:00:00Z"
  ; sch_due_at_iso = None
  ; sch_next_due_at_iso = None
  ; sch_expires_at_iso = None
  ; sch_recurrence_summary = ""
  ; sch_recurrence = Ok Schedule_domain.One_shot
  ; sch_payload_digest = "digest"
  ; sch_payload = `Assoc []
  ; sch_payload_kind = None
  ; sch_payload_support = "supported"
  ; sch_payload_dispatch_tool = None
  ; sch_payload_target = None
  ; sch_payload_keeper_name = Some (Printf.sprintf "sq-%02d" index)
  ; sch_payload_summary = None
  ; sch_last_wake_status = None
  ; sch_last_wake_started_at_iso = None
  ; sch_last_wake_error = None
  ; sch_queue_projection_status = None
  ; sch_queue_pending_count = None
  ; sch_reaction_projection_status = None
  ; sch_reaction_latest_at_iso = None
  ; sch_reaction_kind = None
  ; sch_reaction_keeper_name = None
  ; sch_reaction_stimulus_id = None
  ; sch_reaction_post_id = None
  ; sch_reaction_reason = None
  ; sch_wake_seen = None
  ; sch_turn_started = None
  ; sch_turn_finished = None
  ; sch_queue_ack_seen = None
  ; sch_wake_cancelled = None
  ; sch_stimulus_recorded_at_iso = None
  ; sch_turn_started_recorded_at_iso = None
  ; sch_turn_finished_recorded_at_iso = None
  ; sch_queue_ack_recorded_at_iso = None
  ; sch_wake_cancelled_recorded_at_iso = None
  ; sch_reaction_quarantined = None
  ; sch_occurrence =
      { Masc.Tui_schedule_observation.stage = Masc.Tui_schedule_observation.No_occurrence
      ; due_at_iso = None }
  ; sch_runner_hold = None }

(* QA's case: the schedule list reported nothing, so its PgDn moved one
   row. *)
let test_schedules_report_the_rows_they_drew () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Schedules;
  let rows = List.init 40 schedule in
  state.schedules <-
    Some
      { scs_observed_at = 1795046400.
      ; scs_status = "ok"
      ; scs_read_error = None
      ; scs_request_count = Some 40
      ; scs_truncated = false
      ; scs_payload_target = None
      ; scs_paging = Schedule_paging_unavailable
      ; scs_next_due_iso = None
      ; scs_counts = None
      ; scs_rows = rows
      ; scs_runner_status = Masc.Tui_decode.Runner_status Schedule_contract_values.Runner_ok };
  check_work_list
    { wl_name = "schedule"; wl_list = Schedule_rows; wl_marker = "sq-"; wl_count = 40
    ; wl_render = Masc_tui_render_work.render_schedules
    ; wl_place = (fun state index -> state.schedule_cursor <- index)
    ; wl_cursor = (fun state -> state.schedule_cursor) }
    state

(* #53077: the Keeper link of a Keeper wake names the Keeper, not the
   "keeper:<name>" target the server derives from it, which no Keeper is
   called. *)
let test_schedule_keeper_link_names_the_keeper () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Schedules;
  let row =
    { (schedule 1) with
      sch_payload_kind = Some "masc.keeper_wake"
    ; sch_payload_target = Some "keeper:alice"
    ; sch_payload_keeper_name = Some "alice" }
  in
  state.schedules <-
    Some
      { scs_observed_at = 1795046400.
      ; scs_status = "ok"
      ; scs_read_error = None
      ; scs_request_count = Some 1
      ; scs_truncated = false
      ; scs_payload_target = None
      ; scs_paging = Schedule_paging_unavailable
      ; scs_next_due_iso = None
      ; scs_counts = None
      ; scs_rows = [ row ]
      ; scs_runner_status = Masc.Tui_decode.Runner_status Schedule_contract_values.Runner_ok };
  state.schedule_detail_id <- Some row.sch_schedule_id;
  with_size (120, 40) (fun () ->
    let lines, _ = draw Masc_tui_render_work.render_schedules state in
    let named marker = rows_naming marker lines > 0 in
    let link = Masc_tui_link.reference Masc_tui_link.Keeper "alice" in
    if not (named link) then
      List.iter (fun line -> if rows_naming "Keeper" [ line ] > 0 then prerr_endline line) lines;
    Alcotest.(check bool) "the link names the Keeper" true (named link);
    Alcotest.(check bool) "and not the target" false
      (named (Masc_tui_link.reference Masc_tui_link.Keeper "keeper:alice")))

(* Each notice is drawn at both sizes, so the list really shares the body
   with it. *)
let check_notices_drawn ~name render state notices =
  List.iter
    (fun size ->
      with_size size (fun () ->
        let lines, _ = draw render state in
        List.iter
          (fun notice ->
            Alcotest.(check bool)
              (Printf.sprintf "%dx%d, %s: %S is drawn" (snd size) (fst size) name notice)
              true (rows_naming notice lines > 0))
          notices))
    sizes

(* The rows above and under a Work list take its share of the body: a read
   that failed, a partial reading, a filter, an armed cancel, a refused
   form. The list is drawn in what is left, so the report has to be the
   entries drawn there and not the height the list has without them. *)
let test_tasks_with_notices_report_the_entries_they_drew () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Planning;
  state.tasks <- List.init 40 task;
  state.tasks_error <- Some "coverage read failed for one source";
  state.goal_task_links <- Goal_links_read_failed "goal links unreadable";
  let place state index =
    state.task_focus <-
      Masc_tui_overview_tasks.Task_focus
        { selected = Option.map (fun (task : Tui_decode.task) -> task.id) (List.nth_opt state.tasks index) }
  in
  check_notices_drawn ~name:"Tasks" Masc_tui_render_work.render_work_tasks state
    [ "coverage read failed"; "goal links unreadable" ];
  check_work_list
    { wl_name = "Task with notices"; wl_list = Task_entries; wl_marker = "tq-"; wl_count = 40
    ; wl_render = Masc_tui_render_work.render_work_tasks; wl_place = place
    ; wl_cursor =
        (fun state ->
          Option.value ~default:0
            (Masc_tui_overview_tasks.work_selected_index state.tasks
               ~selected:(Masc_tui_overview_tasks.selection state.task_focus))) }
    state

let test_goals_with_notices_report_the_entries_they_drew () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Planning;
  let goals = List.init 40 goal in
  state.planning <-
    Some
      { pl_goals = goals
      ; pl_rollup =
          { pr_active = 40; pr_verifying = 0; pr_awaiting_confirmation = 0; pr_done = 0
          ; pr_dropped = 0; pr_paused = 0; pr_blocked = 0 }
      ; pl_backlog =
          { pb_todo = 0; pb_claimed = 0; pb_running = 0; pb_awaiting_verification = 0
          ; pb_done = 0; pb_cancelled = 0 }
      ; pl_goal_history = []
      ; pl_generated_at = "2026-11-19T00:00:00Z" };
  (* A failed reload keeps the previous Goals and says so twice (scope and
     error rows); a filter other than the default draws the modes row. *)
  state.planning_error <- Some "goal reload failed";
  state.planning_filter <- Planning_filter_all;
  state.goal_task_links <- Goal_links_read_failed "goal links unreadable";
  Alcotest.(check (list string)) "the visible Goals keep the fixture's order"
    (List.map (fun (goal : planning_goal) -> goal.pg_id) goals)
    (List.map (fun (goal : planning_goal) -> goal.pg_id)
       (planning_visible_goals ~filter:state.planning_filter ~sort:state.planning_sort goals));
  check_notices_drawn ~name:"Goals" Masc_tui_render_work.render_planning_list state
    [ "goal reload failed"; "goal links unreadable" ];
  check_work_list
    { wl_name = "Goal with notices"; wl_list = Goal_entries; wl_marker = "gq-"; wl_count = 40
    ; wl_render = Masc_tui_render_work.render_planning_list
    ; wl_place = (fun state index -> state.planning_cursor <- index)
    ; wl_cursor = (fun state -> state.planning_cursor) }
    state

let test_schedules_with_notices_report_the_rows_they_drew () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Schedules;
  let rows = List.init 40 schedule in
  state.schedules <-
    Some
      { scs_observed_at = 1795046400.
      ; scs_status = "ok"
      ; scs_read_error = None
      ; scs_request_count = Some 40
      ; scs_truncated = false
      ; scs_payload_target = None
      ; scs_paging = Schedule_paging_unavailable
      ; scs_next_due_iso = None
      ; scs_counts = None
      ; scs_rows = rows
      ; scs_runner_status = Masc.Tui_decode.Runner_status Schedule_contract_values.Runner_ok };
  (* The source warning above the list, the armed cancel and the server's
     refusal under it, and a refused form long enough to wrap: every row the
     page spends outside the list. *)
  state.schedules_error <- Some "schedule reload failed";
  state.schedule_cancel_armed <- Some "schedule-03";
  state.schedule_cancel_error <- Some ("schedule-04", Request_failed "cancel refused");
  state.schedule_form_refusal <-
    Some
      { sfr_change = Schedule_create
      ; sfr_reason = Schedule_form_request (Request_failed (String.concat " " (List.init 40 (fun _ -> "refused"))))
      ; sfr_at = Unix.gettimeofday ()
      ; sfr_workspace = None };
  check_notices_drawn ~name:"Schedules" Masc_tui_render_work.render_schedules state
    [ "schedule reload failed"; "schedule-03"; "cancel refused"; "refused refused" ];
  check_work_list
    { wl_name = "schedule with notices"; wl_list = Schedule_rows; wl_marker = "sq-"; wl_count = 40
    ; wl_render = Masc_tui_render_work.render_schedules
    ; wl_place = (fun state index -> state.schedule_cursor <- index)
    ; wl_cursor = (fun state -> state.schedule_cursor) }
    state

(* The Tools lists are rows of one scrolling page, and an entry can wrap, so
   a page counts the entries a window of the frame's height holds whole
   ({!Masc_tui_render_tools.drawn_page}). The frame draws the window from
   [tools_scroll], which the dispatcher moves to the selected entry after
   every key by the landing and the rule it reads
   ({!Masc_tui_render_tools.skill_landing},
   {!Masc_tui_render_tools.request_landing},
   {!Masc_tui_render_tools.follow}), and these tests read the same. Each
   entry's rows are found in the page by its text, not taken from the
   renderer's count: from its first row, a group heading when it opens one,
   to its last. The window brings the whole top of the page in with the
   first entry.

   Above the list stands the selection's document: the Skill's source,
   package and revision, or the request's requester and Keeper. These wrap
   differently for different entries, so the fixtures give the entries
   values that wrap differently. *)
module Tools = Masc.Tui_decode_tools

(* Where an entry's rows are in the page. *)
type entry_rows = { er_first : int; er_last : int }

(* The rows of the window the frame draws the Tools page in, as
   [Masc_tui_render_runtime.render_tools] works it out, and the scroll past
   which it holds no more. *)
let tools_window state lines =
  let terminal_rows, _ = Prim.get_terminal_size () in
  let layout = Prim.tools_scrolled_for_lines state lines in
  let height =
    Key.content_height ~rows:(surface_body_rows state ~terminal_rows) ~chrome:layout.sc_chrome
      ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
  in
  height, max 0 (layout.sc_count - height)

(* Whether a page row starts the entry [name]: a row that wraps loses its
   indent, and the selected entry's row has its mark before the name. *)
let starts_entry name text =
  let text = String.trim (Masc_tui_theme.strip_sgr text) in
  let unmarked =
    List.fold_left
      (fun text mark ->
        if String.starts_with ~prefix:mark text then
          String.sub text (String.length mark) (String.length text - String.length mark)
        else text)
      text
      [ Masc_tui_theme.Glyph.current_entry ^ " "; "\xe2\x80\xba " ]
  in
  String.starts_with ~prefix:(name ^ " ") unmarked

(* The index in [lines] of the first row [starts] picks. *)
let row_where lines label starts =
  match List.find_index (fun (_, text) -> starts text) lines with
  | Some row -> row
  | None -> Alcotest.failf "%s is not in the page" label

(* Each entry's rows: from the row that starts it, less the [above] rows of
   its own above that row, to the row before the next entry's, and the last
   to the row before [below]. *)
let entry_rows lines ~names ~above ~below =
  let firsts =
    List.mapi (fun index name -> row_where lines name (starts_entry name) - above index) names
  in
  let after = row_where lines "the row under the list" below in
  List.mapi
    (fun index first ->
      { er_first = first
      ; er_last = Option.value ~default:after (List.nth_opt firsts (index + 1)) - 1 })
    firsts

(* One walk down the list with j and one back up with k, the window
   following the cursor. In every page the renderer's count of each entry's
   rows is the rows the page gives it, every entry stands on the rows it
   stood on for the first selection, and from every window PgDn keeps the
   last entry it held whole and PgUp the first. [rows display] are each
   entry's rows in that page; [prepare] lays the list out for the terminal's
   width, [landing] is the dispatcher's, and [cursor] / [place] are the
   selection. *)
let check_tools_pages ~name ~list ~count ~prepare ~rows ~landing ~cursor ~place state =
  List.iter
    (fun size ->
      with_size size (fun () ->
        let terminal_rows, cols = Prim.get_terminal_size () in
        prepare ~cols;
        let page () =
          let display = Masc_tui_render_tools.tools_display ~cols ~terminal_rows state in
          let height, max_scroll = tools_window state display.lines in
          display, rows display, height, max_scroll
        in
        let spans entries = List.map (fun entry -> entry.er_first, entry.er_last) entries in
        (* The scroll the dispatcher keeps, from [scroll], and the window the
           frame draws from it. *)
        let follow display ~height scroll =
          match landing state display with
          | Some landing -> Masc_tui_render_tools.follow landing ~height scroll
          | None -> Alcotest.failf "%s: the page has no landing for the selection" name
        in
        let window ~max_scroll scroll = max 0 (min scroll max_scroll) in
        (* The window brings the top of the page in with the first entry. *)
        let whole_in ~shown ~height index entry =
          (if index = 0 then 0 else entry.er_first) >= shown && entry.er_last < shown + height
        in
        let first_selection =
          place state 0;
          let _, entries, _, _ = page () in
          spans entries
        in
        let scroll = ref 0 in
        let visit at =
          place state at;
          let display, entries, height, max_scroll = page () in
          let label =
            Printf.sprintf "%dx%d, %s %d, window %d" (snd size) (fst size) name at !scroll
          in
          Alcotest.(check (option (pair bool (list (pair int int)))))
            (label ^ ": each entry takes the rows the page gives it")
            (Some (true, spans entries))
            (Option.map
               (fun (drawn, reported) ->
                 ( drawn = list
                 , List.map
                     (fun (entry : Masc_tui_render_tools.cursor_rows) ->
                       entry.first_row, entry.last_row)
                     reported ))
               display.entries);
          Alcotest.(check (list (pair int int)))
            (label ^ ": the entries stand where they stood for the first selection")
            first_selection (spans entries);
          let heights = List.map (fun entry -> entry.er_last - entry.er_first + 1) entries in
          Alcotest.(check bool) (label ^ ": the entries take different rows") true
            (List.length (List.sort_uniq compare (List.tl heights)) > 1);
          scroll := follow display ~height !scroll;
          let shown = window ~max_scroll !scroll in
          let whole =
            List.filter_map
              (fun (index, entry) ->
                if whole_in ~shown ~height index entry then Some index else None)
              (List.mapi (fun index entry -> index, entry) entries)
          in
          let reported =
            match Masc_tui_render_tools.drawn_page display ~rows:height with
            | Some (drawn, page) when drawn = list -> page
            | Some _ | None -> Alcotest.failf "%s: the page names no %s list" label name
          in
          Alcotest.(check bool) (label ^ ": the window cuts the list") true
            (List.length whole < count);
          List.iter
            (fun (key, kept, key_name) ->
              place state at;
              state.lists_drawn <- [ { dl_list = list; dl_height = reported } ];
              (match Moves.moves state ~on_screen:(fun () -> None) ~follow:ignore with
               | Some moves -> moves key
               | None -> Alcotest.fail "no list answered the move key");
              let landed = cursor state in
              let display, entries, height, max_scroll = page () in
              let shown = window ~max_scroll (follow display ~height !scroll) in
              Alcotest.(check bool)
                (Printf.sprintf "%s: %s to %d keeps entry %d whole" label key_name landed kept)
                true
                (whole_in ~shown ~height kept (List.nth entries kept)))
            [ Key.Page_down, List.fold_left max 0 whole, "PgDn"
            ; Key.Page_up, List.fold_left min count whole, "PgUp" ];
          place state at
        in
        for at = 0 to count - 1 do visit at done;
        for at = count - 1 downto 0 do visit at done))
    sizes

(* Where a Skill comes from: every third from a source whose id is long, and
   every third after it a package whose id is longer, so the row that names
   them above the list takes one, two or three rows. *)
let skill_reference index name =
  let source_id, package_id =
    match index mod 3 with
    | 0 -> "workspace", name
    | 1 -> "workspace-" ^ String.make 80 's', name
    | _ -> "workspace", name ^ "-" ^ String.make 150 'p'
  in
  match
    Skill_reference.of_yojson
      (`Assoc
         [ ( "identity"
           , `Assoc
               [ "source_id", `String source_id; "package_id", `String package_id
               ; "name", `String name ] )
         ; "content_revision", `String (String.make 64 'a') ])
  with
  | Ok reference -> reference
  | Error _ -> Alcotest.failf "the reference of %s does not decode" name

(* Instruction Skills first and Compositions after, the order the list draws
   them in, so a group heading sits inside the list. A Composition's row
   wraps at 80 columns; a Skill loaded for no reason it can name, or by a
   Keeper profile, takes a row saying so, and one loaded for a Task with a
   long id takes three at 80 columns. *)
let skill_count = 24

let skill index : Tools.effective_skill_profile =
  let composition = index >= skill_count / 2 in
  let reasons : Tools.effective_skill_load_reason list =
    match index mod 4 with
    | 0 -> []
    | 1 -> [ Skill_catalog_default ]
    | 2 -> [ Skill_task ("task-" ^ String.make 90 'x') ]
    | _ -> [ Skill_keeper_profile ]
  in
  let name = Printf.sprintf "sk-%02d" index in
  { esp_reference = skill_reference index name; esp_name = name
  ; esp_surface = Masc.Keeper_skill_observability.Instruction_skill
  ; esp_body_bytes = 0; esp_discovery_bytes = 0
  ; esp_load_reasons = reasons; esp_node_count = 0; esp_batch_count = 0
  ; esp_max_parallelism = 0; esp_flow = None
  ; esp_io =
      (if composition then Composition_io { input_schema = `Null; exports = [] }
       else Model_orchestrated) }

let test_skills_page_by_the_entries_a_window_holds () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.ui_language <- Lang_en;
  state.view <- Tools;
  state.tools_pane <- Tools_surface;
  state.tools_inventory <-
    Some
      { ts_tools = []; ts_count = 0; ts_freshness = Settled
      ; ts_effective =
          Some
            (Effective_surface_available
               { ets_keeper_name = "keeper"; ets_runtime_id = "runtime"
               ; ets_official_client_kind = "client"
               ; ets_tool_delivery = Effective_tools_delivered; ets_native_posture = None
               ; ets_skill_snapshot_revision = "snapshot"
               ; ets_skill_resource_read_max_bytes = None; ets_skills_left_out = []
               ; ets_unavailable_skill_names = []
               ; ets_skill_profiles = List.init skill_count skill
               ; ets_tool_surface_bytes = None; ets_skill_tool_surface_bytes = None
               ; ets_skill_discovery_bytes = 0; ets_skill_body_bytes = None; ets_tools = []
               ; ets_tool_surface_sha256 = None })
      ; ts_usage = None; ts_volume_gc_report = None
      ; ts_storage = { st_host_disk = Host_disk_absent; st_keeper_cleanup = Keeper_cleanup_absent } };
  (* A group's heading is the row above its first Skill and part of that
     Skill's entry. The selected Skill's measurement card stands under the
     list. *)
  let first_in_group index = index = 0 || index = skill_count / 2 in
  let rows (display : Masc_tui_render_tools.display) =
    entry_rows display.lines
      ~names:(List.init skill_count (Printf.sprintf "sk-%02d"))
      ~above:(fun index -> if first_in_group index then 1 else 0)
      ~below:(String.starts_with ~prefix:"\xe2\x94\x8c")
  in
  check_tools_pages ~name:"Skill" ~list:Skill_entries ~count:skill_count
    ~prepare:(fun ~cols:_ -> ()) ~rows ~landing:Masc_tui_render_tools.skill_landing
    ~cursor:(fun state -> state.tools_skill_cursor)
    ~place:(fun state index -> state.tools_skill_cursor <- index)
    state

let request_count = 30

(* Every fifth request names a Keeper long enough that the requester row
   above the list wraps at the terminal's width, and its own row with it;
   the others fit. Every third request's ownership is unknown, which says so
   in more words: with the shorter Keeper name that row wraps too. *)
let request ~cols index : Tui_decode.async_request_row =
  { ar_request_id = Printf.sprintf "rq-%02d" index
  ; ar_submitted_by = "operator"
  ; ar_keeper_name =
      (if index mod 5 = 2 then "keeper-" ^ String.make (cols - 30) 'v'
       else "keeper-" ^ String.make (cols - 62) 'k')
  ; ar_phase = Async_running; ar_submitted_at = 0.
  ; ar_ownership = (if index mod 3 = 0 then Async_ownership_unknown else Async_runtime_owned) }

let request_target ~cols index : Masc.Tui_decode_async_request.target =
  let request = request ~cols index in
  { submitted_by = request.ar_submitted_by; request_id = request.ar_request_id
  ; keeper_name = request.ar_keeper_name }

let test_requests_page_by_the_entries_a_window_holds () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.ui_language <- Lang_en;
  state.view <- Tools;
  state.tools_pane <- Tools_async;
  let width = ref 0 in
  let prepare ~cols =
    width := cols;
    let unknown = List.length (List.filter (fun index -> index mod 3 = 0) (List.init request_count Fun.id)) in
    state.tools_async_observation <-
      Some
        (Async_ready
           { summary =
               { ars_active = request_count; ars_runtime_owned = request_count - unknown
               ; ars_ownership_unknown = unknown; ars_record_errors = 0 }
           ; requests = List.init request_count (request ~cols); recovery = None })
  in
  let selected state =
    Option.value ~default:0
      (Option.bind state.tools_async_selection (fun target ->
         List.find_index
           (fun index ->
             Masc.Tui_decode_async_request.equal_target target (request_target ~cols:!width index))
           (List.init request_count Fun.id)))
  in
  (* The startup recovery row stands under the list. *)
  let rows (display : Masc_tui_render_tools.display) =
    entry_rows display.lines
      ~names:(List.init request_count (Printf.sprintf "rq-%02d"))
      ~above:(fun _ -> 0)
      ~below:(fun text -> String.starts_with ~prefix:"startup recovery" (String.trim text))
  in
  check_tools_pages ~name:"request" ~list:Async_request_entries ~count:request_count ~prepare
    ~rows ~landing:Masc_tui_render_tools.request_landing ~cursor:selected
    ~place:(fun state index ->
      state.tools_async_selection <- Some (request_target ~cols:!width index))
    state

let test_board_read_sidebar_reports_drawn_rows () =
  let open_post = { (board_post 0) with bp_title = "open-selected" } in
  let posts = open_post :: List.init 39 (fun i -> board_post (i + 1)) in
  with_size (40, 120) (fun () ->
    let state = create_state ~workspace:"" ~port:0 () in
    state.view <- Board;
    state.board_mode <- Board_read open_post.bp_id;
    state.board_listing <-
      Masc_tui_fetched.Ready { bl_query = board_query state; bl_posts = posts };
    let lines, lists = draw (fun s -> Masc_tui_render_board.render_board_read s open_post) state in
    (* Open post fills the first sidebar slot; the remaining sidebar slots draw "zq-*" rows. *)
    Alcotest.(check (list int))
      "Board_read split sidebar reports the exact post rows drawn"
      [ rows_naming "zq-" lines + 1 ] (reported Board_read_sidebar_rows lists))

let test_config_themes_and_voice_report_drawn_heights () =
  let measure size pane render list =
    with_size size (fun () ->
      let state = create_state ~workspace:"" ~port:0 () in
      state.view <- Config;
      state.config_pane <- pane;
      let _lines, lists = draw render state in
      match reported list lists with
      | [ h ] -> h
      | other ->
          Alcotest.failf "expected one reported height, got %d" (List.length other))
  in
  let themes_small =
    measure (24, 80) Config_themes Masc_tui_render_config.render_themes Config_themes_rows
  in
  let themes_large =
    measure (40, 120) Config_themes Masc_tui_render_config.render_themes Config_themes_rows
  in
  Alcotest.(check bool) "themes drawn height grows with terminal height" true
    (themes_small >= 1 && themes_small < themes_large);
  let voice_small =
    measure (24, 80) Config_voice Masc_tui_render_config.render_voice Config_voice_rows
  in
  let voice_large =
    measure (40, 120) Config_voice Masc_tui_render_config.render_voice Config_voice_rows
  in
  Alcotest.(check bool) "voice drawn height grows with terminal height" true
    (voice_small >= 1 && voice_small < voice_large)

let test_board_list_sticky_scroll () =
  let posts = List.init 40 board_post in
  with_size (24, 80) (fun () ->
    let state = create_state ~workspace:"" ~port:0 () in
    state.view <- Board;
    state.board_listing <-
      Masc_tui_fetched.Ready { bl_query = board_query state; bl_posts = posts };
    let render_and_apply () =
      Prim.frame_lists := [];
      let _frame, clamped = Masc_tui_render_board.render_board_list state in
      Option.iter (apply_clamped_scroll state) clamped;
      state.board_list_scroll
    in
    state.board_cursor <- 30;
    let s1 = render_and_apply () in
    Alcotest.(check bool) "scrolling down to row 30 advances viewport" true (s1 > 0);
    state.board_cursor <- 29;
    let s2 = render_and_apply () in
    Alcotest.(check int) "stepping up inside viewport keeps window stationary" s1 s2;
    state.board_cursor <- s1 - 1;
    let s3 = render_and_apply () in
    Alcotest.(check int) "stepping above viewport top scrolls by one row" (s1 - 1) s3)

let test_board_list_preview_modes_scroll_and_markdown () =
  let long_body =
    String.concat "\n"
      ( "## Overview"
      :: List.init 25 (fun i -> Printf.sprintf "- line %02d of post body" i) )
  in
  let closed_post =
    { (board_post 0) with
      bp_body = long_body
    ; bp_hearth = Some "code-review"
    ; bp_votes = 4
    ; bp_comment_count = 3
    ; bp_closed =
        Some
          { bpc_closed_by = "reviewer"
          ; bpc_closed_at = Some 1_790_000_000.
          ; bpc_summary = Some "**Resolved**: merged in follow-up"
          ; bpc_successor_id = None
          }
    }
  in
  let second_post =
    { (board_post 1) with bp_body = "Second post short body" }
  in
  let posts =
    closed_post :: second_post :: List.init 38 (fun i -> board_post (i + 2))
  in
  with_size (40, 120) (fun () ->
    let state = create_state ~workspace:"" ~port:0 () in
    state.ui_language <- Lang_en;
    state.view <- Board;
    state.board_listing <-
      Masc_tui_fetched.Ready { bl_query = board_query state; bl_posts = posts };
    let render_mode mode =
      state.board_preview_mode <- mode;
      Prim.frame_lists := [];
      let frame, clamped = Masc_tui_render_board.render_board_list state in
      Option.iter (apply_clamped_scroll state) clamped;
      let lines =
        List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines
      in
      let reported_rows = reported Board_post_rows !Prim.frame_lists in
      (lines, reported_rows)
    in
    let compact_lines, compact_rows = render_mode Preview_compact in
    let compact_body_rows = state.board_list_preview_body_rows in
    let compact_max_scroll = state.board_list_preview_max_scroll in
    Alcotest.(check (list int)) "compact mode reports exact drawn rows"
      [ rows_naming "zq-" compact_lines ] compact_rows;
    Alcotest.(check (option string)) "preview binds to post-00"
      (Some "post-00") state.board_list_preview_post_id;
    Alcotest.(check bool) "long post has positive preview max_scroll"
      true (compact_max_scroll > 0);
    let has_text needle lines =
      let nlen = String.length needle in
      List.exists
        (fun line ->
          let rec scan i =
            i + nlen <= String.length line
            && (String.equal (String.sub line i nlen) needle || scan (i + 1))
          in
          scan 0)
        lines
    in
    Alcotest.(check bool) "closed resolution renders ahead of body"
      true (has_text "Resolution" compact_lines);
    Alcotest.(check bool) "rich metadata includes hearth and comments"
      true
      (has_text "#code-review" compact_lines
       && has_text "3 comments" compact_lines);
    Alcotest.(check bool) "scrollable preview advertises J/K scroll hint"
      true (has_text "J/K" compact_lines);
    (* Scrolling past max_scroll clamps cleanly to max_scroll. *)
    state.board_list_preview_scroll <- compact_max_scroll + 50;
    let _, _ = render_mode Preview_compact in
    Alcotest.(check int) "overscroll clamps to preview_max_scroll"
      compact_max_scroll state.board_list_preview_scroll;
    (* Expanding to half then full grows preview body rows and shrinks list rows monotonically. *)
    let half_lines, half_rows = render_mode Preview_half in
    let half_body_rows = state.board_list_preview_body_rows in
    Alcotest.(check (list int)) "half mode reports exact drawn rows"
      [ rows_naming "zq-" half_lines ] half_rows;
    let full_lines, full_rows = render_mode Preview_full in
    let full_body_rows = state.board_list_preview_body_rows in
    Alcotest.(check (list int)) "full mode reports exact drawn rows"
      [ rows_naming "zq-" full_lines ] full_rows;
    Alcotest.(check bool) "preview body grows compact < half < full"
      true (compact_body_rows < half_body_rows && half_body_rows < full_body_rows);
    (* Moving to another post automatically resets preview scroll to 0 and binds new post_id. *)
    state.board_list_preview_scroll <- 5;
    state.board_cursor <- 1;
    let second_lines, _ = render_mode Preview_compact in
    Alcotest.(check (option string)) "preview rebinds to post-01"
      (Some "post-01") state.board_list_preview_post_id;
    Alcotest.(check int) "switching post resets preview scroll to 0"
      0 state.board_list_preview_scroll;
    Alcotest.(check int) "short post has 0 preview max_scroll"
      0 state.board_list_preview_max_scroll;
    Alcotest.(check bool) "short post renders its own body"
      true (has_text "Second post short body" second_lines);
    (* Missing timestamps omit a dangling em-dash from preview header metadata. *)
    let undated_post =
      { (board_post 2) with
        bp_body = "Undated body"
      ; bp_created_at_unix = None
      ; bp_updated_at = None
      }
    in
    state.board_listing <-
      Masc_tui_fetched.Ready { bl_query = board_query state; bl_posts = [ undated_post ] };
    state.board_cursor <- 0;
    let undated_lines, _ = render_mode Preview_compact in
    Alcotest.(check bool) "missing age omits em-dash from preview meta"
      false (has_text (" \xc2\xb7 " ^ Masc_tui_theme.Glyph.no_value ^ " \xc2\xb7 ") undated_lines);
    (* Empty list clears preview binding and scroll bounds. *)
    state.board_listing <-
      Masc_tui_fetched.Ready { bl_query = board_query state; bl_posts = [] };
    let _, _ = render_mode Preview_compact in
    Alcotest.(check (option string)) "empty list clears preview post_id"
      None state.board_list_preview_post_id;
    Alcotest.(check int) "empty list resets preview max_scroll"
      0 state.board_list_preview_max_scroll);
  (* Short terminal where docked_vertical_split drops preview clears binding. *)
  with_size (10, 80) (fun () ->
    let state = create_state ~workspace:"" ~port:0 () in
    state.view <- Board;
    state.board_listing <-
      Masc_tui_fetched.Ready { bl_query = board_query state; bl_posts = posts };
    state.board_list_preview_post_id <- Some "post-00";
    state.board_list_preview_scroll <- 3;
    state.board_list_preview_max_scroll <- 10;
    Prim.frame_lists := [];
    let _frame, clamped = Masc_tui_render_board.render_board_list state in
    Option.iter (apply_clamped_scroll state) clamped;
    Alcotest.(check (option string)) "short terminal drops preview and clears post_id"
      None state.board_list_preview_post_id;
    Alcotest.(check int) "short terminal resets preview max_scroll"
      0 state.board_list_preview_max_scroll)

(* A frame that draws no schedule rows must not store [0] over the offset the
   reader was holding: the snapshot can be unread for a frame (a refresh after
   an error, or a view entered before the first read) while the stored viewport
   offset still describes where the reader was. *)
let test_schedules_keep_the_offset_when_no_rows_are_drawn () =
  let rows = List.init 40 schedule in
  with_size (24, 80) (fun () ->
    let state = create_state ~workspace:"" ~port:0 () in
    state.view <- Schedules;
    state.schedules <-
      Some
        { scs_observed_at = 1795046400.
        ; scs_status = "ok"
        ; scs_read_error = None
        ; scs_request_count = Some 40
        ; scs_truncated = false
        ; scs_payload_target = None
        ; scs_paging = Schedule_paging_unavailable
        ; scs_next_due_iso = None
        ; scs_counts = None
        ; scs_rows = rows
        ; scs_runner_status =
            Masc.Tui_decode.Runner_status Schedule_contract_values.Runner_ok
        };
    let render_schedules () =
      Prim.frame_lists := [];
      let _frame, clamped = Masc_tui_render_work.render_schedules state in
      Option.iter (apply_clamped_scroll state) clamped;
      state.schedule_list_scroll
    in
    state.schedule_cursor <- 30;
    let held = render_schedules () in
    Alcotest.(check bool) "the reader has an offset to lose" true (held > 0);
    state.schedules <- None;
    let after = render_schedules () in
    Alcotest.(check int) "a frame with no rows keeps the stored offset" held after)

let test_schedules_and_themes_keep_sticky_viewport_scroll () =
  let rows = List.init 40 schedule in
  with_size (24, 80) (fun () ->
    let state = create_state ~workspace:"" ~port:0 () in
    state.view <- Schedules;
    state.schedules <-
      Some
        { scs_observed_at = 1795046400.
        ; scs_status = "ok"
        ; scs_read_error = None
        ; scs_request_count = Some 40
        ; scs_truncated = false
        ; scs_payload_target = None
        ; scs_paging = Schedule_paging_unavailable
        ; scs_next_due_iso = None
        ; scs_counts = None
        ; scs_rows = rows
        ; scs_runner_status =
            Masc.Tui_decode.Runner_status Schedule_contract_values.Runner_ok
        };
    let render_schedules () =
      Prim.frame_lists := [];
      let _frame, clamped = Masc_tui_render_work.render_schedules state in
      Option.iter (apply_clamped_scroll state) clamped;
      state.schedule_list_scroll
    in
    state.schedule_cursor <- 30;
    let s1 = render_schedules () in
    Alcotest.(check bool) "schedules scrolling to row 30 advances viewport" true (s1 > 0);
    state.schedule_cursor <- 29;
    let s2 = render_schedules () in
    Alcotest.(check int) "schedules stepping up inside viewport keeps window stationary" s1 s2;
    state.schedule_cursor <- s1 - 1;
    let s3 = render_schedules () in
    Alcotest.(check int) "schedules stepping above viewport top scrolls by one row" (s1 - 1) s3;
    (* Config Themes uses the same sticky List_window_scroll contract. *)
    let theme_state = create_state ~workspace:"" ~port:0 () in
    theme_state.view <- Config;
    theme_state.config_pane <- Config_themes;
    let render_themes () =
      Prim.frame_lists := [];
      let _frame, clamped = Masc_tui_render_config.render_themes theme_state in
      Option.iter (apply_clamped_scroll theme_state) clamped;
      theme_state.theme_list_scroll
    in
    theme_state.theme_cursor <- 25;
    let t1 = render_themes () in
    Alcotest.(check bool) "themes scrolling to row 25 advances viewport" true (t1 > 0);
    theme_state.theme_cursor <- 24;
    let t2 = render_themes () in
    Alcotest.(check int) "themes stepping up inside viewport keeps window stationary" t1 t2;
    theme_state.theme_cursor <- t1 - 1;
    let t3 = render_themes () in
    Alcotest.(check int) "themes stepping above viewport top scrolls by one row" (t1 - 1) t3;
    (* Mouse wheel notches must keep routing to list cursor movement, never swallowed. *)
    List.iter
      (fun owner ->
        let reader = Prim.clamped_scroll_now state (List_window_scroll (owner, 0)) in
        Alcotest.(check bool) "wheel notch passes through List_window_scroll" true
          (Option.is_none
             (Prim.reader_after_wheel reader Masc.Tui_mouse_protocol.Wheel_down)))
      [ Schedule_list; Approval_list; Fusion_list_scroll; Config_themes_list
      ; Workspace_activity_list; Code_tree_list ];
    (* Workspace / scope / directory transitions reset their sticky list scroll cleanly. *)
    state.fusion_list_scroll <- 14;
    withdraw_fusion_workspace state;
    Alcotest.(check int) "withdraw_fusion_workspace resets fusion_list_scroll" 0
      state.fusion_list_scroll;
    state.code_tree_scroll <- 18;
    set_code_scope state (Code_scope_repo "repo-1");
    Alcotest.(check int) "set_code_scope resets code_tree_scroll" 0
      state.code_tree_scroll;
    state.code_tree_scroll <- 12;
    enter_keeper_code_file state ~keeper:"keeper-1" ~path:"dir/file.ml";
    Alcotest.(check int) "enter_keeper_code_file resets code_tree_scroll" 0
      state.code_tree_scroll)

let test_prompts_refresh_over_held_snapshot_keeps_frame_stable () =
  let row : Masc.Tui_decode.prompt_row =
    { pr_key = "librarian.main"
    ; pr_category = "librarian"
    ; pr_operator_surface = Masc.Tui_decode.Prompt_primary
    ; pr_description = "Librarian prompt"
    ; pr_effective = "Prompt body"
    ; pr_file_path = "config/prompts/librarian.md"
    ; pr_source = Masc.Tui_decode.Prompt_file
    ; pr_authoring_issues = []
    ; pr_template_variables = []
    ; pr_override_default_moved = false
    }
  in
  let asset : Masc.Tui_decode.runtime_prompt_asset =
    { pra_path = "runtime/base.txt"
    ; pra_file_path = "config/prompts/base.txt"
    ; pra_value = "Asset text"
    ; pra_file_exists = true
    }
  in
  let snapshot : Masc.Tui_decode.prompts_snapshot =
    { ps_rows = [ row ]; ps_runtime_assets = [ asset ]; ps_held_back = [] }
  in
  with_size (40, 120) (fun () ->
    List.iter
      (fun lang ->
        List.iter
          (fun show_assets ->
            let state = create_state ~workspace:"" ~port:0 () in
            state.view <- Config;
            state.config_pane <- Config_prompts;
            state.ui_language <- lang;
            state.prompts_show_runtime_assets <- show_assets;
            state.prompts_librarian_input <- Some ("librarian.main", [ "sample input" ]);
            (match Masc_tui_fetched.start ~equal:Unit.equal state.prompts ~key:() with
             | Masc_tui_fetched.Already_loading -> Alcotest.fail "fresh state already loading"
             | Masc_tui_fetched.Started (next, req) ->
                 state.prompts <-
                   Masc_tui_fetched.complete ~equal:Unit.equal next req (Ok snapshot));
            let idle_lines, _ = draw Masc_tui_render_config.render_prompts state in
            (match Masc_tui_fetched.start ~equal:Unit.equal state.prompts ~key:() with
             | Masc_tui_fetched.Already_loading -> Alcotest.fail "ready state already loading"
             | Masc_tui_fetched.Started (refreshing, _req) ->
                 state.prompts <- refreshing);
            state.prompts_librarian_input_loading <- true;
            let refreshing_lines, _ = draw Masc_tui_render_config.render_prompts state in
            Alcotest.(check (list string))
              (Printf.sprintf "prompts refresh keeps frame identical (assets=%b)" show_assets)
              idle_lines refreshing_lines)
          [ false; true ])
      [ Lang_ko; Lang_en ])

let () =
  Alcotest.run "tui render list heights"
    [ ( "reported heights"
      , [ Alcotest.test_case "the Board reports the rows it drew" `Quick
            test_board_reports_the_rows_it_drew
        ; Alcotest.test_case "the Models table reports the fewest bindings a window draws" `Quick
            test_models_report_the_fewest_bindings_a_window_draws
        ; Alcotest.test_case "the Task list reports the entries it drew" `Quick
            test_tasks_report_the_entries_they_drew
        ; Alcotest.test_case "the Goal list reports the entries it drew" `Quick
            test_goals_report_the_entries_they_drew
        ; Alcotest.test_case "docked preview modes split height and preserve Goal page counts" `Quick
            test_docked_preview_mode_and_vertical_split
        ; Alcotest.test_case "keeper column latch is monotonic within a view and width" `Quick
            test_keeper_column_latch_monotonic
        ; Alcotest.test_case "the schedule list reports the rows it drew" `Quick
            test_schedules_report_the_rows_they_drew
        ; Alcotest.test_case "a schedule's Keeper link names the Keeper" `Quick
            test_schedule_keeper_link_names_the_keeper
        ; Alcotest.test_case "the Task list with notices reports the entries it drew" `Quick
            test_tasks_with_notices_report_the_entries_they_drew
        ; Alcotest.test_case "the Goal list with notices reports the entries it drew" `Quick
            test_goals_with_notices_report_the_entries_they_drew
        ; Alcotest.test_case "the schedule list with notices reports the rows it drew" `Quick
            test_schedules_with_notices_report_the_rows_they_drew
        ; Alcotest.test_case "the Skill list pages by the entries a window holds" `Quick
            test_skills_page_by_the_entries_a_window_holds
        ; Alcotest.test_case "the request list pages by the entries a window holds" `Quick
            test_requests_page_by_the_entries_a_window_holds
        ; Alcotest.test_case "the Board_read sidebar reports the post rows it drew" `Quick
            test_board_read_sidebar_reports_drawn_rows
        ; Alcotest.test_case "Config themes and voice report their drawn heights" `Quick
            test_config_themes_and_voice_report_drawn_heights
        ; Alcotest.test_case "Board list keeps viewport stationary on in-window cursor moves" `Quick
            test_board_list_sticky_scroll
        ; Alcotest.test_case "Board list docked preview renders Markdown, grows across modes, scrolls, and resets on post change" `Quick
            test_board_list_preview_modes_scroll_and_markdown
        ; Alcotest.test_case "Schedules and Config themes keep viewport stationary on in-window cursor moves" `Quick
            test_schedules_and_themes_keep_sticky_viewport_scroll
        ; Alcotest.test_case "the schedule list keeps its offset when a frame draws no rows" `Quick
            test_schedules_keep_the_offset_when_no_rows_are_drawn
        ; Alcotest.test_case "Prompts and runtime assets keep frame identical during refresh over held snapshot" `Quick
            test_prompts_refresh_over_held_snapshot_keeps_frame_stable
        ] )
    ]
