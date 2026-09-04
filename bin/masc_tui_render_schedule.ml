type decision =
  | Idle
  | Wait_until of int64
  | Render

type request =
  | Input
  | Background
  | Force

type t = {
  min_interval_ns : int64;
  mutable pending : request option;
  mutable preempt_deadline : bool;
  mutable last_rendered_at_ns : int64 option;
}

let create ~min_interval_ns () =
  if Int64.compare min_interval_ns 0L < 0 then
    invalid_arg "render interval must be non-negative";
  { min_interval_ns;
    pending = Some Force;
    preempt_deadline = true;
    last_rendered_at_ns = None;
  }

let request schedule request =
  match request, schedule.pending with
  | Force, _ ->
      schedule.pending <- Some Force;
      schedule.preempt_deadline <- true
  | Input, Some Background ->
      (* User input supersedes a scheduled background paint, matching pi's
         immediate-render path without turning a byte burst into one write per
         byte. Subsequent input inside the same frame window still coalesces. *)
      schedule.pending <- Some Input;
      schedule.preempt_deadline <- true
  | Input, Some Force -> ()
  | Input, Some Input | Input, None -> schedule.pending <- Some Input
  | Background, None -> schedule.pending <- Some Background
  | Background, Some (Input | Background | Force) -> ()

let deadline schedule =
  Option.map
    (fun rendered_at -> Int64.add rendered_at schedule.min_interval_ns)
    schedule.last_rendered_at_ns

let take schedule ~now_ns =
  match schedule.pending with
  | None -> Idle
  | Some _ ->
    match deadline schedule with
    | Some due
      when (not schedule.preempt_deadline) && Int64.compare now_ns due < 0 ->
        Wait_until due
    | None | Some _ ->
        schedule.pending <- None;
        schedule.preempt_deadline <- false;
        schedule.last_rendered_at_ns <- Some now_ns;
        Render

let input_timeout_seconds schedule ~now_ns ~maximum =
  let maximum = max 0.0 maximum in
  match schedule.pending with
  | None -> maximum
  | Some _ when schedule.preempt_deadline -> 0.0
  | Some _ ->
    match deadline schedule with
    | None -> 0.0
    | Some due ->
        let remaining_ns = Int64.sub due now_ns in
        if Int64.compare remaining_ns 0L <= 0 then 0.0
        else
          min maximum (Int64.to_float remaining_ns /. 1_000_000_000.0)

let nonnegative_width width = max 0 width

let keeper_context_bar_width ~inner_width =
  nonnegative_width (min 30 (inner_width - 40))

let normalize_keeper_detail_scroll ~line_count ~content_height scroll =
  let line_count = max 0 line_count in
  let content_height = max 0 content_height in
  let maximum_scroll = max 0 (line_count - content_height) in
  max 0 (min scroll maximum_scroll)

(* A repeated action writes the same line again and again — six manual
   refreshes spent six of the eleven event rows saying one thing. Consecutive
   runs with the same key fold into their newest element and a count; the
   window and scroll then move over folded rows, so a burst costs one row. *)
let collapse_consecutive ~key items =
  let fold collapsed item =
    match collapsed with
    | (newest, count) :: rest when String.equal (key newest) (key item) ->
        (newest, count + 1) :: rest
    | _ -> (item, 1) :: collapsed
  in
  List.rev (List.fold_left fold [] items)

type overview_event_window = {
  oew_offset : int;
  oew_first_position : int;
  oew_last_position : int;
}

let project_overview_event_window ~event_count ~visible_rows scroll =
  let event_count = max 0 event_count in
  let visible_rows = max 0 visible_rows in
  let maximum_offset = max 0 (event_count - visible_rows) in
  let oew_offset = max 0 (min scroll maximum_offset) in
  let visible_count = min visible_rows (event_count - oew_offset) in
  let oew_first_position = if visible_count = 0 then 0 else oew_offset + 1 in
  let oew_last_position = if visible_count = 0 then 0 else oew_offset + visible_count in
  { oew_offset; oew_first_position; oew_last_position }

let scroll_overview_events_older ~event_count ~visible_rows scroll =
  let event_count = max 0 event_count in
  let visible_rows = max 0 visible_rows in
  let current = project_overview_event_window ~event_count ~visible_rows scroll in
  let next_offset =
    if current.oew_offset >= event_count then current.oew_offset
    else current.oew_offset + 1
  in
  (project_overview_event_window ~event_count ~visible_rows
     next_offset).oew_offset

let scroll_overview_events_newer ~event_count ~visible_rows scroll =
  let current = project_overview_event_window ~event_count ~visible_rows scroll in
  (project_overview_event_window ~event_count ~visible_rows
     (current.oew_offset - 1)).oew_offset

let overview_event_offset_after_prepend ~retained_count scroll =
  let retained_count = max 0 retained_count in
  let maximum_offset = if retained_count = 0 then 0 else retained_count - 1 in
  if scroll <= 0 || maximum_offset = 0 then 0
  else
    let bounded = min scroll maximum_offset in
    if bounded = maximum_offset then maximum_offset else bounded + 1

module Input_wait = struct
  type 'a poll_result =
    | Ready of 'a
    | Timed_out
    | Interrupted

  let nanoseconds_per_second = 1_000_000_000.0

  let await ~now_ns ~timeout_ns ~poll =
    if Int64.compare timeout_ns 0L < 0 then
      invalid_arg "input wait must be non-negative";
    let deadline_ns = Int64.add (now_ns ()) timeout_ns in
    let rec loop () =
      let remaining_ns = Int64.sub deadline_ns (now_ns ()) in
      let remaining_seconds =
        if Int64.compare remaining_ns 0L <= 0 then 0.0
        else Int64.to_float remaining_ns /. nanoseconds_per_second
      in
      match poll remaining_seconds with
      | Ready value -> Some value
      | Timed_out -> None
      | Interrupted ->
          if Int64.compare (now_ns ()) deadline_ns >= 0 then None else loop ()
    in
    loop ()
end

module Input_shortcut = struct
  let is_quit ~message_mode key =
    (not message_mode) && (String.equal key "q" || String.equal key "Q")
end

module Viewport = struct
  (* This is the largest fixed-row budget declared by a surface, not a promise
     that every variable section already accounts for the viewport. *)
  let minimum_fixed_chrome_rows = 14
  let requires_compact_frame ~rows = rows < minimum_fixed_chrome_rows
end

type overview_allocation = {
  attention_rows : int;
  task_error_rows : int;
  task_rows : int;
  filler_rows : int;
}

(* Rows the Attention / Recent Events panel may take. A reader scans this panel
   for what needs attention now, not for history; past six rows the older rows
   are scrolled to, not read at a glance. *)
let overview_panel_row_cap = 6

let allocate_overview ~terminal_rows ~has_cluster ~attention_count ~event_count
    ~task_count ~has_task_error =
  (* Ten rows are invariant chrome; the cluster/project row is present only
     after a briefing has loaded. What is left is shared by the Attention /
     Recent Events panel and the task block, and whatever neither needs becomes
     filler so the frame reaches the bottom of the terminal.

     The blocks are bounded by how many items they have, not by a constant.
     They used to stop at six and five rows whatever the terminal offered, so a
     44-row window drew 22 rows of frame and left its own footer sitting in the
     middle of the screen with the backlog cut off above it. *)
  let fixed_rows = 10 + (if has_cluster then 1 else 0) in
  let available = max 0 (terminal_rows - fixed_rows) in
  let desired_panel_rows = max 1 (max attention_count event_count) in
  let desired_task_error_rows = if has_task_error then 1 else 0 in
  let desired_task_rows =
    if task_count <= 0 then if has_task_error then 0 else 1 else task_count
  in
  let desired_task_block_rows =
    desired_task_error_rows + desired_task_rows
  in
  (* The task block is held back before the panel is measured: what it wants,
     but never more than half the viewport. The panel then takes what is left.

     The panel used to stop at six rows whatever the terminal offered, which
     wasted a tall window; removing that cap let it grow without bound, and on
     a short viewport it starved the backlog -- eight events pushed the fifth
     task off a 23-row screen. Reserving by what the tasks want rather than by
     a fixed fraction keeps all three cases: a tall terminal gives both blocks
     everything they ask for and turns the rest into filler, a 23-row one still
     shows five tasks however many events arrive, and a viewport with three
     spare rows still spends two of them on attention, which is the alert
     surface and wins when almost nothing fits. *)
  (* The panel keeps its six-row ceiling. #29696 removed it so a tall window
     would not waste rows, but the rows it wasted were the frame's, not the
     panel's -- the filler below fixes that -- and letting the panel grow
     changed how a contended viewport is shared, which cost the backlog rows
     the Overview scenarios pin. Growth here bought nothing the filler does not
     already give and broke what the cap was holding. *)
  let desired_panel_rows = min overview_panel_row_cap desired_panel_rows in
  let reserved_task_rows = min desired_task_block_rows 1 in
  let attention_rows =
    min desired_panel_rows (max 0 (available - reserved_task_rows))
  in
  let task_block_rows =
    min desired_task_block_rows (max 0 (available - attention_rows))
  in
  let task_error_rows = min desired_task_error_rows task_block_rows in
  let task_rows =
    min desired_task_rows (max 0 (task_block_rows - task_error_rows))
  in
  let filler_rows =
    max 0 (available - attention_rows - task_error_rows - task_rows)
  in
  { attention_rows; task_error_rows; task_rows; filler_rows }

type board_read_allocation = {
  body_rows : int;
  comment_rows : int;
}

(* What the comments may take. Five rows was a flat constant, so a forty-reply
   thread got five rows on an eighty-row terminal exactly as it did on a
   twenty-row one, and reading it meant scrolling the whole post past first.

   Two claims replace it. Rows the body does not need belong to the comments:
   a ten-line post on a sixty-row pane left twenty-four rows of filler under
   it while the thread was cut at five. And where the body does want the whole
   pane, the comments still take a share of it rather than a constant.

   A third, not a half: at a half the two are the same size and the post one
   came to read stops being the larger thing on the screen. The floor keeps
   every short pane drawing exactly what it drew before. *)
let board_comment_share = 3
let board_comment_floor_rows = 5

let allocate_board_read ~terminal_rows ~body_line_count ~comment_count =
  (* Eight rows are invariant chrome. A visible Comments section adds its
     divider and heading; keep one body row when the post has body text, then
     give comments the smaller of what they need and what they may take. *)
  let comment_count = max 0 comment_count in
  let comment_chrome_rows = if comment_count > 0 then 2 else 0 in
  let available = max 0 (terminal_rows - 8 - comment_chrome_rows) in
  let minimum_body_rows = if body_line_count > 0 then 1 else 0 in
  let comment_ceiling =
    max board_comment_floor_rows
      (max
         (available - max 0 body_line_count)
         (available / board_comment_share))
  in
  let comment_rows =
    min (min comment_ceiling comment_count) (max 0 (available - minimum_body_rows))
  in
  let body_rows = max 0 (available - comment_rows) in
  { body_rows; comment_rows }

type board_read_scroll = {
  normalized_scroll : int;
  body_offset : int;
  comment_offset : int;
}

let project_board_read_scroll ~body_line_count ~body_rows ~comment_count
    ~comment_rows scroll =
  let body_line_count = max 0 body_line_count in
  let body_rows = max 0 body_rows in
  let comment_count = max 0 comment_count in
  let comment_rows = max 0 comment_rows in
  let maximum_body_offset = max 0 (body_line_count - body_rows) in
  let maximum_comment_offset = max 0 (comment_count - comment_rows) in
  let maximum_scroll = maximum_body_offset + maximum_comment_offset in
  let normalized_scroll = max 0 (min scroll maximum_scroll) in
  let body_offset = min normalized_scroll maximum_body_offset in
  let comment_offset =
    min maximum_comment_offset (normalized_scroll - body_offset)
  in
  { normalized_scroll; body_offset; comment_offset }

(* Keeper roster columns.

   Cell widths, not text. Every width here is a plain-text budget the renderer
   fits its cells to, so a long keeper name or model id cannot push the columns
   to its right out of the frame.

   Columns drop from the right as the terminal narrows, and the two that never
   drop are what the surface exists to answer: which keeper, and what state it
   is in. Above the minimum, slack goes to the columns that hold identifiers
   worth reading whole -- the keeper's name first, then the runtime it is on --
   before it goes to the task id, which is short by construction. *)

let keeper_marker_width = 3
let keeper_status_width = 10
(* "A P S": autoboot, proactive, sandbox. The width and the inner-width
   threshold below move together -- widening the cell without raising the
   threshold spends two columns the layout had already promised to the name and
   task cells, and the row grows past the frame at exactly the widths where
   flags first appear. *)
let keeper_flags_width = 5

(* Six cells fit [Message_layout.span_text]'s widest reading under a hundred
   days ("99d23h"). *)
let keeper_last_turn_width = 6
let keeper_minimum_name_width = 16
let keeper_maximum_name_width = 32
let keeper_minimum_runtime_width = 20
let keeper_maximum_runtime_width = 34
let keeper_minimum_task_width = 10
let keeper_flags_minimum_inner_width = 98
let keeper_runtime_minimum_inner_width = 118

type keeper_columns = {
  kcol_show_flags : bool;
  kcol_show_runtime : bool;
  kcol_name : int;
  kcol_runtime : int;
  kcol_task : int;
}

let keeper_columns_used_width columns =
  keeper_marker_width + keeper_status_width + 1 + columns.kcol_name
  + (if columns.kcol_show_flags then 1 + keeper_flags_width else 0)
  + 1 + keeper_last_turn_width
  + (if columns.kcol_show_runtime then 1 + columns.kcol_runtime else 0)
  + 1 + columns.kcol_task

let allocate_keeper_columns ~inner_width =
  let inner_width = max 0 inner_width in
  let show_flags = inner_width >= keeper_flags_minimum_inner_width in
  let show_runtime = inner_width >= keeper_runtime_minimum_inner_width in
  let base =
    { kcol_show_flags = show_flags
    ; kcol_show_runtime = show_runtime
    ; kcol_name = keeper_minimum_name_width
    ; kcol_runtime = (if show_runtime then keeper_minimum_runtime_width else 0)
    ; kcol_task = keeper_minimum_task_width
    }
  in
  let slack = inner_width - keeper_columns_used_width base in
  if slack <= 0 then base
  else
    let take budget available = (min budget available, available - budget) in
    let name_growth, slack =
      take
        (min (keeper_maximum_name_width - keeper_minimum_name_width) slack)
        slack
    in
    let runtime_growth, slack =
      if show_runtime then
        take
          (min (keeper_maximum_runtime_width - keeper_minimum_runtime_width)
             slack)
          slack
      else (0, slack)
    in
    { base with
      kcol_name = base.kcol_name + name_growth
    ; kcol_runtime = base.kcol_runtime + runtime_growth
    ; kcol_task = base.kcol_task + slack
    }

module Table = Masc_tui_table

(* Memory fleet columns.

   The Keepers table's rule, applied to a screen that had none: every cell
   declares a width, slack goes to the name, and the columns answering a
   second question drop first.

   What differs is the values. A keeper's memory reading is three numbers in
   three units -- which revision, how many facts, how many bytes -- and the
   screen printed all three into one cell joined by slashes. No header can
   name a cell like that, and a reading wider than the cell pushed every cell
   after it: "r6476/139/94.4 KB" is seventeen cells in a fourteen-cell budget,
   so most rows sat three cells right of their own header. Each number gets a
   cell here.

   [memory_cells] is this screen's description of its columns; {!Masc_tui_table}
   draws both the header and the rows from it, so the two cannot drift. *)

let memory_state_width = 10
let memory_minimum_name_width = 16
let memory_maximum_name_width = 26
let memory_revision_width = 6
let memory_facts_width = 5
let memory_size_width = 9
let memory_source_width = 20
let memory_delta_width = 6

type memory_columns = {
  mcol_show_revision : bool;
  mcol_show_source : bool;
  mcol_name : int;
}

type memory_row_values = {
  mrow_state : string;
  mrow_name : string;
  mrow_revision : string;
  mrow_facts : string;
  mrow_size : string;
  mrow_source : string;
  mrow_delta : string;
}

(* The header carries no values, and the row carries no labels; one shape
   holds both so neither can be built without the other's widths. *)
let memory_no_values =
  { mrow_state = ""
  ; mrow_name = ""
  ; mrow_revision = ""
  ; mrow_facts = ""
  ; mrow_size = ""
  ; mrow_source = ""
  ; mrow_delta = ""
  }

let memory_cells ?(state_style = "") ?(size_style = "") ?(delta_style = "")
    columns values =
  let revision =
    if columns.mcol_show_revision then
      [ Table.cell ~align:Table.Right ~header:"REV"
          ~width:memory_revision_width values.mrow_revision
      ]
    else []
  in
  let source =
    if columns.mcol_show_source then
      [ Table.cell ~header:"SOURCE" ~width:memory_source_width
          values.mrow_source
      ]
    else []
  in
  [ Table.cell ~style:state_style ~header:"STATE" ~width:memory_state_width
      values.mrow_state
  ; Table.cell ~header:"KEEPER" ~width:columns.mcol_name values.mrow_name
  ]
  @ revision
  @ [ Table.cell ~align:Table.Right ~header:"FACTS" ~width:memory_facts_width
        values.mrow_facts
    ; Table.cell ~align:Table.Right ~style:size_style ~header:"SIZE"
        ~width:memory_size_width values.mrow_size
    ]
  @ source
  @ [ Table.cell ~align:Table.Right ~style:delta_style ~header:"\xce\x94"
        ~width:memory_delta_width values.mrow_delta
    ]

let memory_columns_used_width columns =
  Table.used_width (memory_cells columns memory_no_values)

(* The source-bound reading answers "is anything pinned to a file", and the
   revision answers "how far has the snapshot moved". Neither is the question
   the screen exists for -- which keeper remembers how much -- so they are the
   two that leave, in that order, and a dropped one returns only once it fits
   beside a keeper name at its widest.

   Both used to return at a hand-typed width measured against the narrowest
   name, so the returning column took back cells the name had already grown
   into: at 61 cells the name held 23, at 62 the revision returned and left it
   16, and the same keeper read worse on the wider terminal. *)
let memory_columns_minimum_inner_width ~show_revision ~show_source =
  memory_columns_used_width
    { mcol_show_revision = show_revision
    ; mcol_show_source = show_source
    ; mcol_name = memory_maximum_name_width
    }

let allocate_memory_columns ~inner_width =
  let inner_width = max 0 inner_width in
  let show_revision =
    inner_width
    >= memory_columns_minimum_inner_width ~show_revision:true ~show_source:false
  in
  let show_source =
    inner_width
    >= memory_columns_minimum_inner_width ~show_revision:true ~show_source:true
  in
  let base =
    { mcol_show_revision = show_revision
    ; mcol_show_source = show_source
    ; mcol_name = memory_minimum_name_width
    }
  in
  let slack = inner_width - memory_columns_used_width base in
  if slack <= 0 then base
  else
    (* Unlike the roster there is no cell here that grows without bound: every
       column has a reading whose widest form is known, so surplus width stays
       margin rather than padding one cell out to the frame. *)
    let growth =
      min (memory_maximum_name_width - memory_minimum_name_width) slack
    in
    { base with mcol_name = base.mcol_name + growth }

let memory_header_row columns =
  Table.header_row (memory_cells columns memory_no_values)

let memory_row ?state_style ?size_style ?delta_style ?close columns values =
  Table.row ?close
    (memory_cells ?state_style ?size_style ?delta_style columns values)

(* Workspace repository columns.

   This screen wrote one format string twice -- once for the header and once
   for the rows -- so the two were a copy-paste apart from disagreeing, and the
   path cell was sized by subtracting 55 from the terminal width, a number that
   matched the other four columns only by hand. The columns are declared here
   and the leftover is computed from them. *)

let workspace_name_width = 18
let workspace_branch_width = 12
let workspace_status_width = 9
let workspace_sync_width = 6

(* A path is the one reading here with no widest form; it takes what the named
   columns leave. Below this it is folded so hard that neither end identifies
   the repository, and the screen is better off dropping cells from the frame
   than showing a path nobody can place. *)
let workspace_minimum_path_width = 8

type workspace_row_values = {
  wrow_name : string;
  wrow_branch : string;
  wrow_status : string;
  wrow_sync : string;
  wrow_path : string;
}

let workspace_no_values =
  { wrow_name = ""
  ; wrow_branch = ""
  ; wrow_status = ""
  ; wrow_sync = ""
  ; wrow_path = ""
  }

let workspace_cells ~path_width values =
  [ Table.cell ~header:"NAME" ~width:workspace_name_width values.wrow_name
  ; Table.cell ~header:"BRANCH" ~width:workspace_branch_width values.wrow_branch
  ; Table.cell ~header:"STATUS" ~width:workspace_status_width values.wrow_status
  ; Table.cell ~header:"SYNC" ~width:workspace_sync_width values.wrow_sync
  ; Table.cell ~header:"PATH" ~width:path_width values.wrow_path
  ]

let workspace_path_width ~inner_width =
  let named =
    Table.used_width
      (workspace_cells ~path_width:0 workspace_no_values)
  in
  max workspace_minimum_path_width (inner_width - named)

let workspace_header_row ~path_width =
  Table.header_row
    (workspace_cells ~path_width workspace_no_values)

let workspace_row ~path_width values =
  Table.row (workspace_cells ~path_width values)

(* System log columns.

   The header wrote its widths in one format string and the rows in another,
   and the row's had grown a second job: it interleaved five colours with the
   five readings, so the widths sat between escape sequences where nothing
   could check them against the header's. The row had already been taught to
   fit its module and keeper cells -- a comment there records a long module
   name pushing every column right of it -- but the header it was fitting to
   was a separate string.

   The colours ride the cells now. Four of them never vary and are passed once;
   the level's changes with the reading, which is the one thing on this screen
   a colour is for. *)

let system_log_time_width = 8
let system_log_level_width = 7
let system_log_module_width = 16
let system_log_keeper_width = 12
let system_log_category_width = 9
let system_log_minimum_message_width = 12

type system_log_row_values = {
  slog_time : string;
  slog_level : string;
  slog_module : string;
  slog_keeper : string;
  slog_category : string;
  slog_message : string;
}

(* The four dresses a log row wears whatever it says: a timestamp is always
   receded, a module is always the accent, a keeper is always its origin
   colour, a category is always dim. Passed once rather than per row, because
   nothing in a reading changes them. *)
type system_log_styles = {
  slog_time_style : string;
  slog_module_style : string;
  slog_keeper_style : string;
  slog_category_style : string;
}

let system_log_plain_styles =
  { slog_time_style = ""
  ; slog_module_style = ""
  ; slog_keeper_style = ""
  ; slog_category_style = ""
  }

let system_log_no_values =
  { slog_time = ""
  ; slog_level = ""
  ; slog_module = ""
  ; slog_keeper = ""
  ; slog_category = ""
  ; slog_message = ""
  }

let system_log_cells ?(styles = system_log_plain_styles) ?(level_style = "")
    ~message_width values =
  [ Table.cell ~style:styles.slog_time_style ~header:"TIME"
      ~width:system_log_time_width values.slog_time
  ; Table.cell ~style:level_style ~header:"LEVEL"
      ~width:system_log_level_width values.slog_level
  ; Table.cell ~style:styles.slog_module_style ~header:"MODULE"
      ~width:system_log_module_width values.slog_module
  ; Table.cell ~style:styles.slog_keeper_style ~header:"KEEPER"
      ~width:system_log_keeper_width values.slog_keeper
  ; Table.cell ~style:styles.slog_category_style ~header:"CATEGORY"
      ~width:system_log_category_width values.slog_category
  ; Table.cell ~header:"MESSAGE" ~width:message_width values.slog_message
  ]

let system_log_message_width ~inner_width =
  let named =
    Table.used_width
      (system_log_cells ~message_width:0 system_log_no_values)
  in
  max system_log_minimum_message_width (inner_width - named)

let system_log_header_row ~message_width =
  Table.header_row
    (system_log_cells ~message_width system_log_no_values)

let system_log_row ~styles ~level_style ~message_width values =
  Table.row
    (system_log_cells ~styles ~level_style ~message_width values)

(* Lane run columns.

   The header and the rows carried the same six widths in two format strings,
   the row's with the status colour spliced between two of them. The run id was
   the tail of the header and a twelve-cell fit in the row, so the column the
   header opened had no end and the reading in it had one nobody could see. *)

let lane_started_width = 17
let lane_subject_width = 16
let lane_status_width = 11
let lane_elapsed_width = 8
let lane_slot_width = 16

(* A run id truncated below this identifies nothing; the screen is better off
   dropping the frame's last cells than showing half of one. *)
let lane_minimum_run_id_width = 12

type lane_run_row_values = {
  lrow_started : string;
  lrow_subject : string;
  lrow_status : string;
  lrow_elapsed : string;
  lrow_slot : string;
  lrow_run_id : string;
}

let lane_run_no_values =
  { lrow_started = ""
  ; lrow_subject = ""
  ; lrow_status = ""
  ; lrow_elapsed = ""
  ; lrow_slot = ""
  ; lrow_run_id = ""
  }

(* The identity column is named by the caller: this table lists runs of one
   keeper under one heading and runs of many under another. *)
let lane_run_cells ~identity_header ?(status_style = "") ~run_id_width values =
  [ Table.cell ~header:"STARTED" ~width:lane_started_width values.lrow_started
  ; Table.cell ~header:identity_header ~width:lane_subject_width
      values.lrow_subject
  ; Table.cell ~style:status_style ~header:"STATUS" ~width:lane_status_width
      values.lrow_status
  ; Table.cell ~align:Table.Right ~header:"ELAPSED" ~width:lane_elapsed_width
      values.lrow_elapsed
  ; Table.cell ~header:"SLOT" ~width:lane_slot_width values.lrow_slot
  ; Table.cell ~header:"RUN ID" ~width:run_id_width values.lrow_run_id
  ]

let lane_run_id_width ~inner_width =
  let named =
    Table.used_width
      (lane_run_cells ~identity_header:"" ~run_id_width:0 lane_run_no_values)
  in
  max lane_minimum_run_id_width (inner_width - named)

let lane_run_header_row ~identity_header ~run_id_width =
  Table.header_row
    (lane_run_cells ~identity_header ~run_id_width lane_run_no_values)

let lane_run_row ~identity_header ~status_style ~run_id_width values =
  Table.row
    (lane_run_cells ~identity_header ~status_style ~run_id_width values)

(* File change columns.

   Six widths in the header's format string and the same six in the row's, the
   row's split around two colours. The file cell was padded but never fitted,
   so a path longer than its budget pushed the summary beside it off the frame
   -- the one column an operator reads to know what the turn did. *)

let change_turn_width = 6
let change_task_width = 10
let change_op_width = 5
let change_result_width = 8
let change_file_width = 38
let change_minimum_summary_width = 12

type change_row_values = {
  crow_turn : string;
  crow_task : string;
  crow_op : string;
  crow_result : string;
  crow_file : string;
  crow_summary : string;
}

let change_no_values =
  { crow_turn = ""
  ; crow_task = ""
  ; crow_op = ""
  ; crow_result = ""
  ; crow_file = ""
  ; crow_summary = ""
  }

let change_cells ?(op_style = "") ?(result_style = "") ~summary_width values =
  [ Table.cell ~align:Table.Right ~header:"TURN" ~width:change_turn_width
      values.crow_turn
  ; Table.cell ~header:"TASK" ~width:change_task_width values.crow_task
  ; Table.cell ~style:op_style ~header:"OP" ~width:change_op_width
      values.crow_op
  ; Table.cell ~style:result_style ~header:"RESULT" ~width:change_result_width
      values.crow_result
  ; Table.cell ~header:"FILE" ~width:change_file_width values.crow_file
  ; Table.cell ~header:"WHAT" ~width:summary_width values.crow_summary
  ]

let change_summary_width ~inner_width =
  let named =
    Table.used_width
      (change_cells ~summary_width:0 change_no_values)
  in
  max change_minimum_summary_width (inner_width - named)

let change_header_row ~summary_width =
  Table.header_row
    (change_cells ~summary_width change_no_values)

let change_row ~op_style ~result_style ~summary_width values =
  Table.row
    (change_cells ~op_style ~result_style ~summary_width values)

(* Fusion run columns.

   Six widths in the header and the same six in the row, the row's wrapped
   around the status colour. The run id was unbounded in the header and cut at
   fourteen in the row, so the column had no end where it was named and an
   invisible one where it was filled. *)

let fusion_time_width = 8
let fusion_age_width = 7
let fusion_state_width = 18
let fusion_preset_width = 10
let fusion_minimum_run_width = 12

type fusion_row_values = {
  frow_time : string;
  frow_age : string;
  frow_state : string;
  frow_keeper : string;
  frow_preset : string;
  frow_run : string;
}

let fusion_no_values =
  { frow_time = ""
  ; frow_age = ""
  ; frow_state = ""
  ; frow_keeper = ""
  ; frow_preset = ""
  ; frow_run = ""
  }

let fusion_cells ?(state_style = "") ~keeper_width ~run_width values =
  [ Table.cell ~header:"TIME" ~width:fusion_time_width values.frow_time
  ; Table.cell ~align:Table.Right ~header:"AGE" ~width:fusion_age_width
      values.frow_age
  ; Table.cell ~style:state_style ~header:"STATE" ~width:fusion_state_width
      values.frow_state
  ; Table.cell ~header:"KEEPER" ~width:keeper_width values.frow_keeper
  ; Table.cell ~header:"PRESET" ~width:fusion_preset_width values.frow_preset
  ; Table.cell ~header:"RUN" ~width:run_width values.frow_run
  ]

let fusion_run_width ~inner_width ~keeper_width =
  let named =
    Table.used_width
      (fusion_cells ~keeper_width ~run_width:0 fusion_no_values)
  in
  max fusion_minimum_run_width (inner_width - named)

let fusion_header_row ~keeper_width ~run_width =
  Table.header_row
    (fusion_cells ~keeper_width ~run_width fusion_no_values)

let fusion_row ~state_style ~keeper_width ~run_width values =
  Table.row
    (fusion_cells ~state_style ~keeper_width ~run_width values)

(* Harness verdict columns.

   Six widths in the header and the same six in the rows. The header called
   the task column "Task -> Overview" -- fifteen cells in a column of
   fourteen -- so the header itself ran over and pushed Gate and every column
   after it one cell right of the rows they labelled. The arrow was also
   saying something the footer already says: it names the cursor's task as a
   link on every draw. The task and gate cells were padded and never cut, so
   an id longer than its column moved those same columns again from the row
   side. *)

let harness_time_width = 8
let harness_task_width = 14
let harness_gate_width = 9
let harness_verdict_width = 9
let harness_evaluator_width = 24
let harness_minimum_reason_width = 12

type harness_row_values = {
  hrow_time : string;
  hrow_task : string;
  hrow_gate : string;
  hrow_verdict : string;
  hrow_evaluator : string;
  hrow_reason : string;
}

let harness_no_values =
  { hrow_time = ""
  ; hrow_task = ""
  ; hrow_gate = ""
  ; hrow_verdict = ""
  ; hrow_evaluator = ""
  ; hrow_reason = ""
  }

let harness_cells ?(verdict_style = "") ~reason_width values =
  [ Table.cell ~header:"TIME" ~width:harness_time_width values.hrow_time
  ; Table.cell ~header:"TASK" ~width:harness_task_width values.hrow_task
  ; Table.cell ~header:"GATE" ~width:harness_gate_width values.hrow_gate
  ; Table.cell ~style:verdict_style ~header:"VERDICT"
      ~width:harness_verdict_width values.hrow_verdict
  ; Table.cell ~header:"EVALUATOR" ~width:harness_evaluator_width
      values.hrow_evaluator
  ; Table.cell ~header:"REASON" ~width:reason_width values.hrow_reason
  ]

let harness_reason_width ~inner_width =
  let named =
    Table.used_width
      (harness_cells ~reason_width:0 harness_no_values)
  in
  max harness_minimum_reason_width (inner_width - named)

let harness_header_row ~reason_width =
  Table.header_row
    (harness_cells ~reason_width harness_no_values)

let harness_row ~verdict_style ~reason_width values =
  Table.row
    (harness_cells ~verdict_style ~reason_width values)

(* Planning goal columns.

   This list named no columns at all. A reader met "[shaping] * P2  3 open 1
   ver" and had to work out every field from its shape, and the two fields
   whose shape says least -- a priority and a tally -- are the two a reader
   scans a list of goals for.

   The title took the terminal minus forty-seven minus however wide the age and
   the due date happened to be, and both of those are optional, so the pair at
   the end of the row began at a different column on every row: a goal with no
   due date started them ten cells left of the goal above it. Each has a widest
   form and each gets a column.

   The phase carries the brackets it is drawn in, so the caller passes the
   width of the bracketed label rather than the label's own. *)

let planning_proof_width = 1
let planning_priority_width = 3
let planning_open_width = 16
let planning_age_width = 6
let planning_due_width = 10
let planning_minimum_title_width = 12

type planning_row_values = {
  prow_phase : string;
  prow_proof : string;
  prow_priority : string;
  prow_open : string;
  prow_title : string;
  prow_age : string;
  prow_due : string;
}

let planning_no_values =
  { prow_phase = ""
  ; prow_proof = ""
  ; prow_priority = ""
  ; prow_open = ""
  ; prow_title = ""
  ; prow_age = ""
  ; prow_due = ""
  }

let planning_cells ?(phase_style = "") ~phase_width ~title_width values =
  [ Table.cell ~style:phase_style ~header:"PHASE" ~width:phase_width
      values.prow_phase
    (* The proof mark is a mark, like the roster's. A name would be four cells
       wider than the cell it names, and the contract folds a header that does
       not fit rather than letting it push the columns after it. *)
  ; Table.cell ~header:" " ~width:planning_proof_width values.prow_proof
  ; Table.cell ~header:"PRI" ~width:planning_priority_width values.prow_priority
  ; Table.cell ~header:"OPEN" ~width:planning_open_width values.prow_open
  ; Table.cell ~header:"TITLE" ~width:title_width values.prow_title
  ; Table.cell ~align:Table.Right ~header:"AGE" ~width:planning_age_width
      values.prow_age
  ; Table.cell ~header:"DUE" ~width:planning_due_width values.prow_due
  ]

let planning_title_width ~inner_width ~phase_width =
  let named =
    Table.used_width
      (planning_cells ~phase_width ~title_width:0 planning_no_values)
  in
  max planning_minimum_title_width (inner_width - named)

let planning_header_row ~phase_width ~title_width =
  Table.header_row (planning_cells ~phase_width ~title_width planning_no_values)

let planning_row ~phase_style ~phase_width ~title_width values =
  Table.row (planning_cells ~phase_style ~phase_width ~title_width values)

(* Board post columns.

   The list sized its title as [cols] minus a constant summed by hand from ten
   widths and their gaps, and its header carried a second copy of the same
   arithmetic. They disagreed: the rows sized the title to [cols - 68] while
   the header claimed a fixed twenty, so at eighty columns the header ran eight
   cells long, pushed SCORE into the frame and REPLIES off it -- two columns
   still drawn on every row with nothing left saying what they were. The
   repair at the time was a third number.

   The gaps came back to one with the rest of the fleet. Board was spacing its
   columns two cells apart, which is six cells of the title spent on being
   different from every other table on the screen. *)

let board_mark_width = 1
let board_id_width = 12
let board_hearth_width = 12
let board_author_width = 16
let board_age_width = 6
let board_score_width = 5
let board_replies_width = 7
let board_minimum_title_width = 12

type board_row_values = {
  brow_mark : string;
  brow_id : string;
  brow_hearth : string;
  brow_author : string;
  brow_title : string;
  brow_age : string;
  brow_score : string;
  brow_replies : string;
}

type board_row_styles = {
  bstyle_id : string;
  bstyle_hearth : string;
  bstyle_author : string;
  bstyle_age : string;
  bstyle_score : string;
  bstyle_replies : string;
}

let board_no_values =
  { brow_mark = ""
  ; brow_id = ""
  ; brow_hearth = ""
  ; brow_author = ""
  ; brow_title = ""
  ; brow_age = ""
  ; brow_score = ""
  ; brow_replies = ""
  }

let board_no_styles =
  { bstyle_id = ""
  ; bstyle_hearth = ""
  ; bstyle_author = ""
  ; bstyle_age = ""
  ; bstyle_score = ""
  ; bstyle_replies = ""
  }

let board_cells ?(styles = board_no_styles) ~title_width values =
  [ (* The kind mark is a mark, like Planning's proof. A name would be wider
       than the cell holding it, and it carries its own dress: the glyph and
       its colour are chosen together. *)
    Table.cell ~header:" " ~width:board_mark_width values.brow_mark
  ; Table.cell ~style:styles.bstyle_id ~header:"ID" ~width:board_id_width
      values.brow_id
  ; Table.cell ~style:styles.bstyle_hearth ~header:"HEARTH"
      ~width:board_hearth_width values.brow_hearth
  ; Table.cell ~style:styles.bstyle_author ~header:"AUTHOR"
      ~width:board_author_width values.brow_author
  ; Table.cell ~header:"TITLE" ~width:title_width values.brow_title
    (* Right, the way Planning's age reads. A span is a number and the two
       screens are read one after the other; left on one and right on the
       other is the drift this description exists to close. *)
  ; Table.cell ~align:Table.Right ~style:styles.bstyle_age ~header:"AGE"
      ~width:board_age_width values.brow_age
  ; Table.cell ~style:styles.bstyle_score ~header:"SCORE"
      ~width:board_score_width values.brow_score
  ; Table.cell ~style:styles.bstyle_replies ~header:"REPLIES"
      ~width:board_replies_width values.brow_replies
  ]

let board_title_width ~inner_width =
  let named = Table.used_width (board_cells ~title_width:0 board_no_values) in
  max board_minimum_title_width (inner_width - named)

let board_header_row ~title_width =
  Table.header_row (board_cells ~title_width board_no_values)

let board_row ?close ~styles ~title_width values =
  Table.row ?close (board_cells ~styles ~title_width values)

module Terminal_size_cache = struct
  type refresh =
    | Changed of (int * int)
    | Unchanged of (int * int)

  type t = {
    fallback : int * int;
    mutable cached : (int * int) option;
    mutable invalidated : bool;
  }

  (* Box rows require two borders and one space on each side. Clamping a
     transient tiny resize keeps every renderer total without inventing
     surface-specific fallbacks. *)
  let normalize (rows, cols) = max 1 rows, max 4 cols

  let valid (rows, cols) = rows > 0 && cols > 0

  let create ~fallback =
    if not (valid fallback) then invalid_arg "terminal fallback must be positive";
    { fallback = normalize fallback; cached = None; invalidated = true }

  let invalidate cache = cache.invalidated <- true

  let probe_or_last cache ~probe =
    match probe () with
    | Some size when valid size ->
        let size = normalize size in
        cache.cached <- Some size;
        size
    | Some _ | None ->
        (match cache.cached with
         | Some size -> size
         | None ->
             cache.cached <- Some cache.fallback;
             cache.fallback)

  let get cache ~probe =
    match cache.cached, cache.invalidated with
    | Some size, false -> size
    | None, false -> cache.fallback
    | (Some _ | None), true ->
        cache.invalidated <- false;
        probe_or_last cache ~probe

  let refresh cache ~probe =
    let previous = cache.cached in
    cache.invalidated <- false;
    let current = probe_or_last cache ~probe in
    match previous with
    | Some size when size = current -> Unchanged current
    | Some _ | None -> Changed current
end

(* The Planning strip and the per-Keeper schedule page, as plain text. Both
   were inline in the renderer, where nothing could reach them: the strip
   spent a release naming two stops that had moved to the Keeper detail tabs,
   and the page count it carried attached itself to the last of those names.
   Kept here they are ordinary values a test can read. *)

type planning_tab =
  | Planning_goals
  | Planning_task_review
  | Planning_verdicts

let planning_strip_plain ~tab ~review_count ~window =
  let review_label =
    match review_count with
    | Some total when total > 0 -> Printf.sprintf "2 Task Review\xc2\xb7%d" total
    | Some _ | None -> "2 Task Review"
  in
  let stops =
    [ Planning_goals, "1 Goals"
    ; Planning_task_review, review_label
    ; Planning_verdicts, "3 Evaluator Verdicts"
    ]
  in
  List.map
    (fun (stop, label) -> if stop = tab then label ^ window else label)
    stops

(* Why a Keeper's Automation tab is empty. The projection caps its page and
   sorts active rows first, so a filter that matches nothing has two readings
   that a single "(none)" would merge: the store holds none for this Keeper,
   or the page the server sent does not reach them. *)
type keeper_schedule_absence =
  | Store_has_none
  | Page_capped of { shown : int; total : int option }

let classify_keeper_schedule_absence ~truncated ~shown ~total =
  if truncated then Page_capped { shown; total } else Store_has_none

(* Which wake reading the schedule detail has. The pane had one shape because
   only one wake was ever projected; with the history arriving separately it has
   four, and three of them are not "this schedule never woke". *)
type wake_reading =
  | Wake_history of { count : int; retention : int }
  | Wake_never
  | Wake_last_only
  | Wake_history_failed of string

let classify_wake_reading ~history_error ~history =
  match history_error, history with
  | Some err, _ -> Wake_history_failed err
  | None, None -> Wake_last_only
  | None, Some (0, _) -> Wake_never
  | None, Some (count, retention) -> Wake_history { count; retention }
