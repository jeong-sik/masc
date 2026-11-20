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
   indent, the selected entry's row has its mark before the name, and a
   list may draw the name in a style (Skills, #53864). *)
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
  ; esp_surface =
      (if composition then
         Masc.Keeper_skill_observability.Composition_skill
           Masc.Keeper_tool_composition_catalog.Inline
       else Masc.Keeper_skill_observability.Instruction_skill)
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
        ] )
    ]
