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
let memory_cell_gap = 2

(* The source-bound reading answers "is anything pinned to a file", and the
   revision answers "how far has the snapshot moved". Neither is the question
   the screen exists for -- which keeper remembers how much -- so they are the
   two that leave, in that order. *)
let memory_source_minimum_inner_width = 84
let memory_revision_minimum_inner_width = 62

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
  Table.used_width ~gap:memory_cell_gap (memory_cells columns memory_no_values)

let allocate_memory_columns ~inner_width =
  let inner_width = max 0 inner_width in
  let show_source = inner_width >= memory_source_minimum_inner_width in
  let show_revision = inner_width >= memory_revision_minimum_inner_width in
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
  Table.header_row ~gap:memory_cell_gap (memory_cells columns memory_no_values)

let memory_row ?state_style ?size_style ?delta_style ?close columns values =
  Table.row ~gap:memory_cell_gap ?close
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
let workspace_cell_gap = 1

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
    Table.used_width ~gap:workspace_cell_gap
      (workspace_cells ~path_width:0 workspace_no_values)
  in
  max workspace_minimum_path_width (inner_width - named)

let workspace_header_row ~path_width =
  Table.header_row ~gap:workspace_cell_gap
    (workspace_cells ~path_width workspace_no_values)

let workspace_row ~path_width values =
  Table.row ~gap:workspace_cell_gap (workspace_cells ~path_width values)

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
let system_log_cell_gap = 1

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
    Table.used_width ~gap:system_log_cell_gap
      (system_log_cells ~message_width:0 system_log_no_values)
  in
  max system_log_minimum_message_width (inner_width - named)

let system_log_header_row ~message_width =
  Table.header_row ~gap:system_log_cell_gap
    (system_log_cells ~message_width system_log_no_values)

let system_log_row ~styles ~level_style ~message_width values =
  Table.row ~gap:system_log_cell_gap
    (system_log_cells ~styles ~level_style ~message_width values)

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
