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
  mutable last_rendered_at_ns : int64 option;
}

let create ~min_interval_ns () =
  if Int64.compare min_interval_ns 0L < 0 then
    invalid_arg "render interval must be non-negative";
  { min_interval_ns;
    pending = Some Force;
    last_rendered_at_ns = None;
  }

let request schedule request =
  match request, schedule.pending with
  | Force, _ -> schedule.pending <- Some Force
  | Input, Some Force -> ()
  | Input, Some (Input | Background) | Input, None -> schedule.pending <- Some Input
  | Background, None -> schedule.pending <- Some Background
  | Background, Some (Input | Background | Force) -> ()

let deadline schedule =
  Option.map
    (fun rendered_at -> Int64.add rendered_at schedule.min_interval_ns)
    schedule.last_rendered_at_ns

let take ~input_pending schedule ~now_ns =
  let render () =
    schedule.pending <- None;
    schedule.last_rendered_at_ns <- Some now_ns;
    Render
  in
  match schedule.pending with
  | None -> Idle
  | Some Force -> render ()
  | Some Input when not input_pending -> render ()
  | Some (Input | Background) ->
    (* Available input can still be combined. A continuous stream keeps the
       frame interval; once it drains, the branch above presents its result
       without waiting for more input that may never arrive. *)
    match deadline schedule with
    | Some due when Int64.compare now_ns due < 0 ->
        Wait_until due
    | None | Some _ -> render ()

let input_timeout_seconds schedule ~now_ns ~maximum =
  let maximum = max 0.0 maximum in
  match schedule.pending with
  | None -> maximum
  | Some (Force | Input) -> 0.0
  | Some Background ->
    (match deadline schedule with
     | None -> 0.0
     | Some due ->
       let remaining_ns = Int64.sub due now_ns in
       if Int64.compare remaining_ns 0L <= 0 then 0.0
       else min maximum (Int64.to_float remaining_ns /. 1_000_000_000.0))

(* The shared clamp, not a second copy of it. This was written out here --
   the floor on both inputs, the maximum, the clamp -- and read the same as
   [Masc_tui_scroll.normalize] four lines above its own definition. A scroll
   rule kept in two places is a rule that can differ in one of them, and the
   count of views that clamp their own scroll is what an enumeration of the
   ones without a window reading has to walk (#38623). *)
let normalize_keeper_detail_scroll ~line_count ~content_height scroll =
  Masc_tui_scroll.normalize ~count:line_count ~height:content_height scroll

(* A repeated action writes the same line again and again — six manual
   refreshes spent six of the eleven event rows saying one thing. Consecutive
   runs with the same key fold into their newest element and a count, so a
   burst costs one row. *)
let collapse_consecutive ~key items =
  let fold collapsed item =
    match collapsed with
    | (newest, count) :: rest when String.equal (key newest) (key item) ->
        (newest, count + 1) :: rest
    | _ -> (item, 1) :: collapsed
  in
  List.rev (List.fold_left fold [] items)

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

(* Six cells fit [Message_layout.span_text]'s widest reading ("99d23h"). *)
let keeper_last_turn_width = 6
let keeper_minimum_name_width = 16
let keeper_maximum_name_width = 32
let keeper_minimum_runtime_width = 20
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

(* [widest_runtime] is the widest runtime cell the rows will draw, measured
   from those rows. A constant stood here before, and at 34 it was below what
   the cell holds: runtime ids reach 49 cells on the live catalogue
   ([antigravity_subscription.claude-opus-4-6-thinking]), so every long id was
   elided while the slack the row had left went on to the task column -- 49
   cells of it, for an id this file's own note calls short by construction. *)
let allocate_keeper_columns ~inner_width ~widest_runtime =
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
    let runtime_ceiling = max keeper_minimum_runtime_width widest_runtime in
    let runtime_growth, slack =
      if show_runtime then
        take
          (min (runtime_ceiling - keeper_minimum_runtime_width) slack)
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

let memory_state_width = 2
let memory_minimum_name_width = 16
let memory_maximum_name_width = 26
let memory_updated_width = 16
let memory_facts_width = 5
let memory_size_width = 9
let memory_source_width = 20
(* The column carries a pair of counts, and a cell that overruns folds in the
   middle, which takes the first count. Three digits each keeps a large
   revision whole; the widest pair on the live fleet (2026-09-22) was
   [+11 -16]. *)
let memory_delta_width = 9

type memory_columns = {
  mcol_show_updated : bool;
  mcol_show_source : bool;
  mcol_name : int;
}

type memory_row_values = {
  mrow_state : string;
  mrow_name : string;
  mrow_updated : string;
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
  ; mrow_updated = ""
  ; mrow_facts = ""
  ; mrow_size = ""
  ; mrow_source = ""
  ; mrow_delta = ""
  }

let memory_cells ?(state_style = "") ?(size_style = "") ?(delta_style = "")
    columns values =
  let revision =
    if columns.mcol_show_updated then
      [ Table.cell ~align:Table.Right ~header:"UPDATED"
          ~width:memory_updated_width values.mrow_updated
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
  [ Table.cell ~style:state_style ~header:"ST" ~width:memory_state_width
      values.mrow_state
  ; Table.cell ~header:"KEEPER" ~width:columns.mcol_name values.mrow_name
  ]
  @ revision
  @ [ Table.cell ~align:Table.Right ~header:"FACTS" ~width:memory_facts_width
        values.mrow_facts
    ; Table.cell ~align:Table.Right ~style:size_style ~header:"STORED"
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
    { mcol_show_updated = show_revision
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
    { mcol_show_updated = show_revision
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

(* A path keeps a readable floor while auxiliary columns give way. *)
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

type workspace_column =
  | Workspace_name
  | Workspace_branch
  | Workspace_status
  | Workspace_sync
  | Workspace_path

let workspace_column_width = function
  | Workspace_name -> workspace_name_width
  | Workspace_branch -> workspace_branch_width
  | Workspace_status -> workspace_status_width
  | Workspace_sync -> workspace_sync_width
  | Workspace_path -> workspace_minimum_path_width

let workspace_columns =
  [ Workspace_name; Workspace_branch; Workspace_status; Workspace_sync; Workspace_path ]

let workspace_minimum_width =
  Table.used_width
    (List.map (fun column -> Table.cell ~header:""
       ~width:(workspace_column_width column) "") workspace_columns)

let workspace_layout ~inner_width =
  Table.fit ~inner_width ~width:workspace_column_width ~flex:Workspace_path
    ~drop_order:[ Workspace_sync; Workspace_branch ] workspace_columns

let workspace_cells ~(layout : workspace_column Table.layout) values =
  List.map
    (function
      | Workspace_name ->
          Table.cell ~header:"NAME" ~width:workspace_name_width values.wrow_name
      | Workspace_branch ->
          Table.cell ~header:"BRANCH" ~width:workspace_branch_width values.wrow_branch
      | Workspace_status ->
          Table.cell ~header:"STATUS" ~width:workspace_status_width values.wrow_status
      | Workspace_sync ->
          Table.cell ~header:"SYNC" ~width:workspace_sync_width values.wrow_sync
      | Workspace_path ->
          Table.cell ~header:"PATH" ~width:layout.Table.flex_width values.wrow_path)
    layout.Table.shown

let workspace_header_row ~layout =
  Table.header_row (workspace_cells ~layout workspace_no_values)

let workspace_row ~layout values =
  Table.row (workspace_cells ~layout values)

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

type system_log_column =
  | Log_time
  | Log_level
  | Log_module
  | Log_keeper
  | Log_category
  | Log_message

let system_log_column_width = function
  | Log_time -> system_log_time_width
  | Log_level -> system_log_level_width
  | Log_module -> system_log_module_width
  | Log_keeper -> system_log_keeper_width
  | Log_category -> system_log_category_width
  | Log_message -> system_log_minimum_message_width

let system_log_layout ~inner_width =
  Table.fit ~inner_width ~width:system_log_column_width ~flex:Log_message
    ~drop_order:[ Log_category; Log_keeper; Log_module ]
    [ Log_time; Log_level; Log_module; Log_keeper; Log_category; Log_message ]

let system_log_cells ?(styles = system_log_plain_styles) ?(level_style = "")
    ~(layout : system_log_column Table.layout) values =
  List.map
    (function
      | Log_time ->
          Table.cell ~style:styles.slog_time_style ~header:"TIME"
            ~width:system_log_time_width values.slog_time
      | Log_level ->
          Table.cell ~style:level_style ~header:"LEVEL"
            ~width:system_log_level_width values.slog_level
      | Log_module ->
          Table.cell ~style:styles.slog_module_style ~header:"MODULE"
            ~width:system_log_module_width values.slog_module
      | Log_keeper ->
          Table.cell ~style:styles.slog_keeper_style ~header:"KEEPER"
            ~width:system_log_keeper_width values.slog_keeper
      | Log_category ->
          Table.cell ~style:styles.slog_category_style ~header:"CATEGORY"
            ~width:system_log_category_width values.slog_category
      | Log_message ->
          Table.cell ~fold:Table.Fold_tail ~header:"MESSAGE"
            ~width:layout.Table.flex_width values.slog_message)
    layout.Table.shown

let system_log_header_row ~layout =
  Table.header_row (system_log_cells ~layout system_log_no_values)

let system_log_row ~styles ~level_style ~layout values =
  Table.row (system_log_cells ~styles ~level_style ~layout values)

(* Task Review columns.

   The header and the rows carried the same widths in two format strings, and
   printf's width is a floor rather than a field: a task id past fourteen
   cells printed whole and pushed the three columns after it out of line,
   which is the pair this module was written to replace.

   The header also spelled its names in sentence case -- "Task  Submitted by
   Evidence  What it asks for" -- the one table in the TUI that did. Its
   sibling tab, one press of [v] away, reads TIME TASK GATE VERDICT EVALUATOR
   REASON, and all fifty-six columns declared through {!Masc_tui_table} are
   capitals.

   The last column carries the task's own title, which is what a verification
   request asks for: that this task be verified. *)
let verification_task_width = 14
let verification_evidence_width = 9
let verification_minimum_title_width = 16

type verification_row_values = {
  vrow_task : string;
  vrow_submitted_by : string;
  vrow_evidence : string;
  vrow_title : string;
}

let verification_no_values =
  { vrow_task = ""
  ; vrow_submitted_by = ""
  ; vrow_evidence = ""
  ; vrow_title = ""
  }

let verification_cells ~submitter_width ~title_width values =
  [ Table.cell ~header:"TASK" ~width:verification_task_width values.vrow_task
  ; Table.cell ~header:"SUBMITTED BY" ~width:submitter_width
      values.vrow_submitted_by
  ; Table.cell ~header:"EVIDENCE" ~width:verification_evidence_width
      values.vrow_evidence
  ; Table.cell ~fold:Table.Fold_tail ~header:"TITLE" ~width:title_width
      values.vrow_title
  ]

let verification_title_width ~inner_width ~submitter_width =
  let named =
    Table.used_width
      (verification_cells ~submitter_width ~title_width:0 verification_no_values)
  in
  max verification_minimum_title_width (inner_width - named)

let verification_header_row ~submitter_width ~title_width =
  Table.header_row
    (verification_cells ~submitter_width ~title_width verification_no_values)

let verification_row ~submitter_width ~title_width values =
  Table.row (verification_cells ~submitter_width ~title_width values)

(* Schedules list columns.

   The list drew six columns and named one of them, inside the row: the wake's
   word wore a "wake:" prefix and the delivery word followed it after a dot.
   The other five -- the state, when it is due, who the wake reaches, what the
   delivery ledger made of it, how it repeats -- were left for the reader to
   work out from the values, so a row read "alpha" without saying whether that
   was the target or the author.

   Every other list on this screen states its columns above them. Approvals is
   the one other headerless list and it has a reason: its three row kinds put
   different readings in the same cell, so a name over the column would be
   wrong for two of the three. A schedule row has one shape.

   With the names above the rows, the two labels inside them are the same
   words twice. Dropping "wake:" and the dot gives eight cells back to the
   recurrence, which is the column the pane was cutting and the one that
   carries the timezone. *)
let schedule_status_width = 12
let schedule_due_width = 19

(* The target column is measured by the caller from the names on the page.
   A target is a keeper name on every row that has one; a row without one
   falls back to its payload summary, which can be long, so the column is
   capped rather than given whatever that summary asks for. *)
let schedule_minimum_target_width = 16
let schedule_maximum_target_width = 40

(* What the delivery column drew before it was measured. It never goes under
   this, so a page of short words keeps the table it had. *)
let schedule_minimum_delivery_width = 12

(* And never past this, so one long word cannot take the recurrence's room. *)
let schedule_maximum_delivery_width = 20

(* The delivery column, measured from the words on the page.

   It was a literal 12. The projection's own words run past that --
   [turn_finished] is thirteen cells and drew as "tur...finished" on the live
   fleet, [terminal_cancelled] is eighteen and
   [conflicting_terminal_evidence] twenty-nine -- and unlike the wake column
   beside it there is no contract list to measure once and be done (#38350),
   so the page is what it has to fit. *)
let schedule_delivery_width words =
  List.fold_left
    (fun widest word -> max widest (Masc_tui_message_layout.display_width word))
    schedule_minimum_delivery_width words
  |> min schedule_maximum_delivery_width
let schedule_minimum_recurrence_width = 12

type schedule_row_values = {
  srow_status : string;
  srow_due : string;
  srow_target : string;
  srow_wake : string;
  srow_delivery : string;
  srow_recurrence : string;
}

let schedule_no_values =
  { srow_status = ""
  ; srow_due = ""
  ; srow_target = ""
  ; srow_wake = ""
  ; srow_delivery = ""
  ; srow_recurrence = ""
  }

(* The list's columns, named so a narrow list can say which it gives up. *)
type schedule_column =
  | Schedule_status
  | Schedule_due
  | Schedule_target
  | Schedule_wake
  | Schedule_delivery
  | Schedule_recurrence

let schedule_columns =
  [ Schedule_status
  ; Schedule_due
  ; Schedule_target
  ; Schedule_wake
  ; Schedule_delivery
  ; Schedule_recurrence
  ]

(* Preserve the operator's list priority: due time, target and recurrence.
   Delivery goes first, then wake, then state; full state is in the detail. *)
let schedule_drop_order =
  [ Schedule_delivery; Schedule_wake; Schedule_status ]

(* The target, wake and delivery columns are measured by the caller from the
   rows on the page, so the layout keeps the widths it was fitted with and
   the header and every row are drawn from the same ones. *)
type schedule_layout = {
  sl_columns : schedule_column Table.layout;
  sl_due_width : int;
  sl_target_width : int;
  sl_wake_width : int;
  sl_delivery_width : int;
}

let schedule_layout ~inner_width ~target_width ~wake_width ~delivery_width =
  let due_floor = Masc_tui_message_layout.display_width "DUE" in
  let target_floor = Masc_tui_message_layout.display_width "TARGET" in
  let primary_gaps = 2 * Table.cell_gap in
  let due_width = min schedule_due_width
      (max due_floor (inner_width - target_floor - schedule_minimum_recurrence_width - primary_gaps)) in
  (* A target takes at most a third of the row and leaves the operator's due
     and recurrence readings their floors before optional columns are fitted. *)
  let target_width = min target_width
      (max target_floor (min (inner_width / 3)
         (inner_width - due_width - schedule_minimum_recurrence_width - primary_gaps))) in
  let recurrence_floor = min schedule_minimum_recurrence_width
      (max 1 (inner_width - due_width - target_width - primary_gaps)) in
  let width = function
    | Schedule_status -> schedule_status_width
    | Schedule_due -> due_width
    | Schedule_target -> target_width
    | Schedule_wake -> wake_width
    | Schedule_delivery -> delivery_width
    | Schedule_recurrence -> recurrence_floor
  in
  { sl_columns =
      Table.fit ~inner_width ~width ~flex:Schedule_recurrence
        ~drop_order:schedule_drop_order schedule_columns
  ; sl_due_width = due_width
  ; sl_target_width = target_width
  ; sl_wake_width = wake_width
  ; sl_delivery_width = delivery_width
  }

let schedule_cell ~status_style ~wake_style ~recurrence_style
    ~(layout : schedule_layout) values = function
  | Schedule_status ->
      Table.cell ~style:status_style ~header:"STATUS"
        ~width:schedule_status_width values.srow_status
  | Schedule_due ->
      Table.cell ~header:"DUE" ~width:layout.sl_due_width values.srow_due
  | Schedule_target ->
      Table.cell ~header:"TARGET" ~width:layout.sl_target_width
        values.srow_target
  | Schedule_wake ->
      Table.cell ~style:wake_style ~header:"WAKE" ~width:layout.sl_wake_width
        values.srow_wake
  | Schedule_delivery ->
      Table.cell ~header:"DELIVERY" ~width:layout.sl_delivery_width
        values.srow_delivery
  | Schedule_recurrence ->
      Table.cell ~style:recurrence_style ~header:"RECURRENCE"
        ~width:layout.sl_columns.Table.flex_width values.srow_recurrence

let schedule_cells ?(status_style = "") ?(wake_style = "")
    ?(recurrence_style = "") ~layout values =
  List.map
    (schedule_cell ~status_style ~wake_style ~recurrence_style ~layout values)
    layout.sl_columns.Table.shown

let schedule_header_row ~layout =
  Table.header_row (schedule_cells ~layout schedule_no_values)

let schedule_row ?status_style ?wake_style ?recurrence_style ~layout values =
  Table.row
    (schedule_cells ?status_style ?wake_style ?recurrence_style ~layout values)

(* Keeper automation tab columns.

   The Keeper detail's Automation tab is the Schedules list read for one
   Keeper, and until it met this description it was the one list on the
   screen without the others' dress: no names above the rows, no colour on
   the state, and -- the reason for the columns below -- no reading of
   whether a schedule ever actually fired. The row said when a request was
   stored and how it repeats; the two facts an operator opens the tab for,
   when the last wake went out and when this Keeper took it, stayed in the
   projection the row never read.

   So the row tells the occurrence's story left to right: the state's mark
   and word, when the last wake started, what became of that wake, when the
   ledger saw the stimulus arrive. RECEIVED, not consumed: the clock is the
   arrival the ledger recorded, and the queue's acknowledgement of the same
   stimulus is a later, separate fact the detail surfaces -- the two part
   company exactly when the keeper sat on a wake before taking it, and a
   column that named one while reading the other would misdate the other.
   Then the schedule's own identity: how it repeats, what it asks for. The
   storage context -- who asked and when -- rides the last two named
   columns, because "why does this exist" is a question the tab could not
   answer before even though the projection carried both facts on every
   row.

   The mark is one cell of the vocabulary the Fusion pipeline already draws
   (done, active, waiting, failed), so a page of rows reads by shape before
   the reader reaches any word. Its colour is the state's own; the two
   always move together, one [schedule_status_color] for both cells. *)
let kauto_mark_width = 1

(* The recurrence keeps the floor the Schedules list gives it: below this the
   row is a schedule the reader cannot tell from a one-shot. *)
let kauto_minimum_recurrence_width = schedule_minimum_recurrence_width

(* The BY column carries the projection's own actor reading -- a display
   name and its kind, "won-chik (human_operator)". A floor of 16 holds the
   shortest names whole; the cap keeps one long identifier from taking the
   clocks' room, which are the columns this tab exists for. *)
let kauto_minimum_by_width = 16
let kauto_maximum_by_width = 26

(* A summary folded below this identifies no schedule. *)
let kauto_minimum_what_width = 16

type kauto_row_values = {
  krow_mark : string;
  krow_status : string;
  krow_triggered : string;
  krow_outcome : string;
  krow_received : string;
  krow_recurrence : string;
  krow_by : string;
  krow_requested : string;
  krow_what : string;
}

let kauto_no_values =
  { krow_mark = ""
  ; krow_status = ""
  ; krow_triggered = ""
  ; krow_outcome = ""
  ; krow_received = ""
  ; krow_recurrence = ""
  ; krow_by = ""
  ; krow_requested = ""
  ; krow_what = ""
  }

(* What a row wears whatever it says: the recurrence and the storage context
   recede, the way the Schedules list dims its recurrence. The three that
   change with the reading -- the mark, the state word, the outcome -- are
   the row's own per-row styles. *)
type kauto_row_styles = {
  kstyle_mark : string;
  kstyle_status : string;
  kstyle_outcome : string;
  kstyle_recurrence : string;
  kstyle_by : string;
}

let kauto_plain_styles =
  { kstyle_mark = ""
  ; kstyle_status = ""
  ; kstyle_outcome = ""
  ; kstyle_recurrence = ""
  ; kstyle_by = ""
  }

(* The list's columns, named so a narrow pane can say which it gives up. *)
type kauto_column =
  | Kauto_mark
  | Kauto_status
  | Kauto_triggered
  | Kauto_outcome
  | Kauto_received
  | Kauto_recurrence
  | Kauto_by
  | Kauto_requested
  | Kauto_what

let kauto_columns =
  [ Kauto_mark
  ; Kauto_status
  ; Kauto_triggered
  ; Kauto_outcome
  ; Kauto_received
  ; Kauto_recurrence
  ; Kauto_by
  ; Kauto_requested
  ; Kauto_what
  ]

(* What a narrow pane gives up, first to go first. The storage context leads
   the list -- on a narrow pane the occurrence still being told matters more
   than who filed it -- then the outcome word, whose failure colour the mark
   and the state word already carry, then the recurrence. The mark, the
   state, the two clocks and the summary never go: they are the four facts
   the tab was rewritten to state. *)
let kauto_drop_order =
  [ Kauto_by; Kauto_requested; Kauto_outcome; Kauto_recurrence ]

(* The BY column, measured from the actors on the page the way the delivery
   column is: the projection's actor list is open, so the page is what fits
   it. *)
let kauto_by_width words =
  List.fold_left
    (fun widest word -> max widest (Masc_tui_message_layout.display_width word))
    kauto_minimum_by_width words
  |> min kauto_maximum_by_width

(* The status, clock and outcome widths are the caller's: this module does
   not link the schedule contract, so the status comes measured from the
   contract's own word list, the clock from the stamp format, and the
   outcome from the words on the page ([schedule_delivery_width] holds the
   wake words too -- "terminal_cancelled" is wider than any of them). *)
type kauto_layout = {
  k_columns : kauto_column Table.layout;
  k_status_width : int;
  k_clock_width : int;
  k_outcome_width : int;
  k_by_width : int;
}

let kauto_layout ~inner_width ~status_width ~clock_width ~outcome_width
    ~by_width =
  let width = function
    | Kauto_mark -> kauto_mark_width
    | Kauto_status -> status_width
    | Kauto_triggered | Kauto_received | Kauto_requested -> clock_width
    | Kauto_outcome -> outcome_width
    | Kauto_recurrence -> kauto_minimum_recurrence_width
    | Kauto_by -> by_width
    | Kauto_what -> kauto_minimum_what_width
  in
  { k_columns =
      Table.fit ~inner_width ~width ~flex:Kauto_what
        ~drop_order:kauto_drop_order kauto_columns
  ; k_status_width = status_width
  ; k_clock_width = clock_width
  ; k_outcome_width = outcome_width
  ; k_by_width = by_width
  }

let kauto_cell ~styles ~(layout : kauto_layout) values = function
  | Kauto_mark ->
      (* A mark, like Board's kind mark: no name is narrower than the cell
         holding it, and the glyph carries its own dress. *)
      Table.cell ~style:styles.kstyle_mark ~header:" " ~width:kauto_mark_width
        values.krow_mark
  | Kauto_status ->
      Table.cell ~style:styles.kstyle_status ~header:"STATUS"
        ~width:layout.k_status_width values.krow_status
  | Kauto_triggered ->
      Table.cell ~header:"TRIGGERED" ~width:layout.k_clock_width
        values.krow_triggered
  | Kauto_outcome ->
      Table.cell ~style:styles.kstyle_outcome ~header:"OUTCOME"
        ~width:layout.k_outcome_width values.krow_outcome
  | Kauto_received ->
      Table.cell ~header:"RECEIVED" ~width:layout.k_clock_width
        values.krow_received
  | Kauto_recurrence ->
      Table.cell ~style:styles.kstyle_recurrence ~header:"RECURRENCE"
        ~width:kauto_minimum_recurrence_width values.krow_recurrence
  | Kauto_by ->
      Table.cell ~style:styles.kstyle_by ~header:"BY"
        ~width:layout.k_by_width values.krow_by
  | Kauto_requested ->
      Table.cell ~header:"REQUESTED" ~width:layout.k_clock_width
        values.krow_requested
  | Kauto_what ->
      Table.cell ~fold:Table.Fold_tail ~header:"WHAT"
        ~width:layout.k_columns.Table.flex_width values.krow_what

let kauto_cells ~styles ~(layout : kauto_layout) values =
  List.map (kauto_cell ~styles ~layout values) layout.k_columns.Table.shown

let kauto_header_row ~layout =
  Table.header_row (kauto_cells ~styles:kauto_plain_styles ~layout kauto_no_values)

let kauto_row ~styles ~layout values =
  Table.row (kauto_cells ~styles ~layout values)

(* The mark a schedule's state draws, from the projection's own status
   vocabulary. A word this build does not name keeps the middot: the mark
   says "the pane did not classify this" rather than claiming a liveness the
   pane never read, the same promise the status word makes by rendering as
   itself. *)
let kauto_status_mark = function
  | "scheduled" -> "\xe2\x97\x8b" (* waiting *)
  | "due" | "running" -> "\xe2\x97\x90" (* active *)
  | "succeeded" -> "\xe2\x97\x8f" (* done *)
  | "failed" -> "\xc3\x97" (* failed *)
  | "cancelled" | "expired" -> "\xe2\x97\x8b" (* inert; the colour dims it *)
  | _ -> "\xc2\xb7"

(* The label on the rule that parts the live rows from the closed ones. The
   parts are the page's own counts, in the order the statuses first appear,
   so the label describes the rows under it rather than a store-wide tally
   the header line above the list already states. *)
let kauto_group_label ~title parts =
  match parts with
  | [] -> title
  | _ -> Printf.sprintf "%s \xc2\xb7 %s" title (String.concat " \xc2\xb7 " parts)

(* Lane run columns.

   A row says when a run started, what or whom it was for, how it ended, how
   long it took, and which model slot served it. The row is opened with the
   cursor and Enter; the run's id heads the detail, whole where the frame
   holds it and folded in the middle where it does not. *)

let lane_started_width = 17
let lane_subject_width = 16
let lane_status_width = 11
let lane_elapsed_width = 8

(* The slot takes what the other columns leave. The slots the lanes reported
   on 2026-09-28 ran from 24 cells (glm-coding.glm-5.3-flash) to 45
   (ollama_cloud.ollama-cloud-deepseek-v4-1-flash). The floor holds the short
   one whole; a longer one folds in the middle, which keeps the provider at
   its head and the model at its tail. *)
let lane_minimum_slot_width = 24

type lane_run_row_values = {
  lrow_started : string;
  lrow_subject : string;
  lrow_status : string;
  lrow_elapsed : string;
  lrow_slot : string;
}

let lane_run_no_values =
  { lrow_started = ""
  ; lrow_subject = ""
  ; lrow_status = ""
  ; lrow_elapsed = ""
  ; lrow_slot = ""
  }

(* The run list's columns, named so a narrow list can say which it spares
   (workbench RFC section 5.4, #36347). *)
type lane_run_column =
  | Lane_started
  | Lane_subject
  | Lane_status
  | Lane_elapsed
  | Lane_slot

let lane_run_columns =
  [ Lane_started
  ; Lane_subject
  ; Lane_status
  ; Lane_elapsed
  ; Lane_slot
  ]

(* The slot's entry is its floor: it is the flexible column and takes what
   the others leave. *)
let lane_run_column_width = function
  | Lane_started -> lane_started_width
  | Lane_subject -> lane_subject_width
  | Lane_status -> lane_status_width
  | Lane_elapsed -> lane_elapsed_width
  | Lane_slot -> lane_minimum_slot_width

(* What a narrow list gives up, first to go first (operator, 2026-09-28): the
   start, then the elapsed time. The subject, the status and the slot never
   go: what the run was for, how it ended, and the model that served it. *)
let lane_run_drop_order = [ Lane_started; Lane_elapsed ]

let lane_run_layout ~inner_width =
  Table.fit ~inner_width ~width:lane_run_column_width ~flex:Lane_slot
    ~drop_order:lane_run_drop_order lane_run_columns

(* The identity column is named by the caller: the Verifier's runs are about a
   task or a goal, every other lane's about who asked. *)
let lane_run_cell ~identity_header ~status_style ~slot_width values = function
  | Lane_started ->
      Table.cell ~header:"STARTED" ~width:lane_started_width values.lrow_started
  | Lane_subject ->
      Table.cell ~header:identity_header ~width:lane_subject_width
        values.lrow_subject
  | Lane_status ->
      Table.cell ~style:status_style ~header:"STATUS" ~width:lane_status_width
        values.lrow_status
  | Lane_elapsed ->
      Table.cell ~align:Table.Right ~header:"ELAPSED" ~width:lane_elapsed_width
        values.lrow_elapsed
  | Lane_slot -> Table.cell ~header:"SLOT" ~width:slot_width values.lrow_slot

let lane_run_cells ~identity_header ?(status_style = "")
    ~(layout : lane_run_column Table.layout) values =
  List.map
    (lane_run_cell ~identity_header ~status_style
       ~slot_width:layout.Table.flex_width values)
    layout.Table.shown

let lane_run_header_row ~identity_header ~layout =
  Table.header_row (lane_run_cells ~identity_header ~layout lane_run_no_values)

let lane_run_row ~identity_header ~status_style ~layout values =
  Table.row (lane_run_cells ~identity_header ~status_style ~layout values)

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

(* Below this the summary says nothing a reader can act on. Below it the list
   gives up columns in its drop order rather than cut the summary. *)
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

(* The change list's columns, named so a narrow list can say which it spares
   (workbench RFC section 5.4, #36347). At eighty columns every column needed
   more than the frame held, and the summary -- the last column, and the one
   that says what the turn did -- was cut away whole. *)
type change_column =
  | Change_turn
  | Change_task
  | Change_op
  | Change_result
  | Change_file
  | Change_summary

let change_columns =
  [ Change_turn
  ; Change_task
  ; Change_op
  ; Change_result
  ; Change_file
  ; Change_summary
  ]

(* The summary's entry is its floor: it is the flexible column and takes what
   the others leave. *)
let change_column_width = function
  | Change_turn -> change_turn_width
  | Change_task -> change_task_width
  | Change_op -> change_op_width
  | Change_result -> change_result_width
  | Change_file -> change_file_width
  | Change_summary -> change_minimum_summary_width

(* What a narrow list gives up, first to go first (operator, 2026-09-28): the
   turn, the task, the operation, then the result. The file and the summary
   never go: which file the turn touched and what it did there. *)
let change_drop_order = [ Change_turn; Change_task; Change_op; Change_result ]

let change_layout ~inner_width =
  Table.fit ~inner_width ~width:change_column_width ~flex:Change_summary
    ~drop_order:change_drop_order change_columns

let change_cell ~op_style ~result_style ~summary_width values = function
  | Change_turn ->
      Table.cell ~align:Table.Right ~header:"TURN" ~width:change_turn_width
        values.crow_turn
  | Change_task ->
      Table.cell ~header:"TASK" ~width:change_task_width values.crow_task
  | Change_op ->
      Table.cell ~style:op_style ~header:"OP" ~width:change_op_width
        values.crow_op
  | Change_result ->
      Table.cell ~style:result_style ~header:"RESULT"
        ~width:change_result_width values.crow_result
  | Change_file ->
      Table.cell ~header:"FILE" ~width:change_file_width values.crow_file
  | Change_summary ->
      Table.cell ~fold:Table.Fold_tail ~header:"WHAT" ~width:summary_width
        values.crow_summary

let change_cells ?(op_style = "") ?(result_style = "")
    ~(layout : change_column Table.layout) values =
  List.map
    (change_cell ~op_style ~result_style ~summary_width:layout.Table.flex_width
       values)
    layout.Table.shown

let change_header_row ~layout =
  Table.header_row (change_cells ~layout change_no_values)

let change_row ~op_style ~result_style ~layout values =
  Table.row (change_cells ~op_style ~result_style ~layout values)

(* Fusion run columns.

   Six widths in the header and the same six in the row, the row's wrapped
   around the status colour. The run id was unbounded in the header and cut at
   fourteen in the row, so the column had no end where it was named and an
   invisible one where it was filled. *)

let fusion_time_width = 16
let fusion_age_width = 7
(* A running stage ("recording(3/1)") or how the run ended: a failed run draws
   a code from the delivery set or the judge set.

   The column is full. Three vocabularies share it, none of them written near
   here, and [Table.cell] fits what it is given without a word -- so the
   widths are checked in [test/test_tui_fusion_state_width.ml], which reads
   this number and all three sets out of the source. Naming today's longest
   string here instead would be a copy, and the copy is what goes stale while
   the screen quietly truncates. *)
let fusion_state_width = 20
let fusion_preset_width = 10
let fusion_minimum_run_width = 12

type fusion_columns = {
  fcol_keeper : int;
  fcol_run : int;
  fcol_show_preset : bool;
}

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

let fusion_cells ?(state_style = "") columns values =
  [ Table.cell ~header:"STARTED" ~width:fusion_time_width values.frow_time
  ; Table.cell ~align:Table.Right ~header:"AGE" ~width:fusion_age_width
      values.frow_age
  ; Table.cell ~style:state_style ~header:"STATE" ~width:fusion_state_width
      values.frow_state
  ; Table.cell ~header:"KEEPER" ~width:columns.fcol_keeper values.frow_keeper
  ]
  @ (if columns.fcol_show_preset then
       [Table.cell ~header:"PRESET" ~width:fusion_preset_width values.frow_preset]
     else [])
  @ [Table.cell ~header:"RUN" ~width:columns.fcol_run values.frow_run]

let allocate_fusion_columns ~inner_width ~keeper_width =
  let full = { fcol_keeper = keeper_width; fcol_run = fusion_minimum_run_width;
               fcol_show_preset = true } in
  let fcol_show_preset =
    Table.used_width (fusion_cells full fusion_no_values) <= inner_width
  in
  let named =
    Table.used_width
      (fusion_cells { fcol_keeper = 0; fcol_run = 0; fcol_show_preset } fusion_no_values)
  in
  (* Keep dates and state intact. The detail shows the omitted preset and
     complete identities; narrow tables first give those cells to the row. *)
  let fcol_keeper = min keeper_width (max 6 (inner_width - named - fusion_minimum_run_width)) in
  let fcol_run = max 3 (inner_width - named - fcol_keeper) in
  { fcol_keeper; fcol_run; fcol_show_preset }

let fusion_header_row columns =
  Table.header_row
    (fusion_cells columns fusion_no_values)

let fusion_row ~state_style columns values =
  Table.row
    (fusion_cells ~state_style columns values)

let fusion_sidebar_label ~status ~time ~keeper ~run_id =
  Printf.sprintf "[%s] %s @%s %s" status time keeper run_id

(* Task Review and Verdicts drew a row's task id and nothing else, and both
   lists hold a task once per submission. Measured on the live history
   2026-09-24: 200 Task Review rows carry 113 distinct ids, 45 of them more
   than once, and seven rows are task-1663 -- one submitter, no stated
   intent. The Verdicts list is shorter and collides too: of eight rows one
   task carries two verdicts, at the same gate, parted only by what each one
   said.

   [apart] is what parts this row from its siblings. It has to hold still
   while the reader looks at it, which an age does not: [age_text] spells
   seconds under an hour, so an index row read "5m03s" and was a different
   row a second later. And it has to be its own value rather than a reading
   of one, because two rows minutes apart round to the same age.

   A row with nothing to part it keeps the id alone rather than inventing a
   mark for it. *)
let task_history_sidebar_label ~task_id ~apart =
  match apart with None -> task_id | Some apart -> task_id ^ "  " ^ apart

let verdict_sidebar_labels rows =
  List.mapi
    (fun index (task_id, clock) ->
      let same (other_id, other_clock) =
        String.equal task_id other_id && String.equal clock other_clock
      in
      let siblings = List.length (List.filter same rows) in
      let apart =
        if siblings = 1 then clock
        else
          let earlier =
            List.filteri (fun other_index row -> other_index < index && same row) rows
            |> List.length
          in
          (* A second-resolution clock can name several verdicts. Keep the
             date and minute, then number those rows within this snapshot. *)
          let minute =
            if String.length clock > 3 then String.sub clock 0 (String.length clock - 3)
            else clock
          in
          Printf.sprintf "%s#%d" minute (earlier + 1)
      in
      task_history_sidebar_label ~task_id ~apart:(Some apart))
    rows

let fusion_pipeline_diagram
    ?(glyph_done = "●")
    ?(glyph_active = "◐")
    ?(glyph_waiting = "○")
    ?(glyph_failed = "×")
    ?(arrow = " ▸ ")
    ~status
    ~stage
    ~panel_answered
    ~panel_expected
    () =
  let step_question = glyph_done ^ " 1 Question" in
  let step_panel, step_judge, step_evidence =
    match status with
    | `Completed ->
        ( glyph_done ^ " 2 Panel"
        , glyph_done ^ " 3 Judge"
        , glyph_done ^ " 4 Evidence" )
    | `Failed ->
        (match stage with
         | `Accepted
         | `Panel ->
             ( glyph_failed ^ " 2 Panel"
             , glyph_waiting ^ " 3 Judge"
             , glyph_waiting ^ " 4 Evidence" )
         | `Judge ->
             ( glyph_done ^ " 2 Panel"
             , glyph_failed ^ " 3 Judge"
             , glyph_waiting ^ " 4 Evidence" )
         | `Evidence ->
             ( glyph_done ^ " 2 Panel"
             , glyph_done ^ " 3 Judge"
             , glyph_failed ^ " 4 Evidence" )
         | `Completed ->
             ( glyph_done ^ " 2 Panel"
             , glyph_done ^ " 3 Judge"
             , glyph_done ^ " 4 Evidence" )
         | `Failed ->
             ( glyph_failed ^ " 2 Panel"
             , glyph_failed ^ " 3 Judge"
             , glyph_failed ^ " 4 Evidence" ))
    | `Running ->
        (match stage with
         | `Accepted ->
             ( glyph_waiting ^ " 2 Panel"
             , glyph_waiting ^ " 3 Judge"
             , glyph_waiting ^ " 4 Evidence" )
         | `Panel ->
             ( Printf.sprintf "%s 2 Panel(%d)" glyph_active panel_expected
             , glyph_waiting ^ " 3 Judge"
             , glyph_waiting ^ " 4 Evidence" )
         | `Judge ->
             ( Printf.sprintf "%s 2 Panel(%d/%d)" glyph_done panel_answered panel_expected
             , glyph_active ^ " 3 Judge"
             , glyph_waiting ^ " 4 Evidence" )
         | `Evidence ->
             ( Printf.sprintf "%s 2 Panel(%d/%d)" glyph_done panel_answered panel_expected
             , glyph_done ^ " 3 Judge"
             , glyph_active ^ " 4 Evidence" )
         | `Completed ->
             ( glyph_done ^ " 2 Panel"
             , glyph_done ^ " 3 Judge"
             , glyph_done ^ " 4 Evidence" )
         | `Failed ->
             ( glyph_failed ^ " 2 Panel"
             , glyph_failed ^ " 3 Judge"
             , glyph_failed ^ " 4 Evidence" ))
  in
  step_question ^ arrow ^ step_panel ^ arrow ^ step_judge ^ arrow ^ step_evidence

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

(* Below this the reason says nothing a reader can act on. Below it the list
   gives up columns in its drop order rather than cut the reason. *)
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

(* The verdict list's columns, named so a narrow list can say which it
   spares (workbench RFC section 5.4, #36347). At eighty columns every column
   needed more than the frame held, and the reason -- the last column -- kept
   five cells. *)
type harness_column =
  | Harness_time
  | Harness_task
  | Harness_gate
  | Harness_verdict
  | Harness_evaluator
  | Harness_reason

let harness_columns =
  [ Harness_time
  ; Harness_task
  ; Harness_gate
  ; Harness_verdict
  ; Harness_evaluator
  ; Harness_reason
  ]

(* The reason's entry is its floor: it is the flexible column and takes what
   the others leave. *)
let harness_column_width = function
  | Harness_time -> harness_time_width
  | Harness_task -> harness_task_width
  | Harness_gate -> harness_gate_width
  | Harness_verdict -> harness_verdict_width
  | Harness_evaluator -> harness_evaluator_width
  | Harness_reason -> harness_minimum_reason_width

(* What a narrow list gives up, first to go first (operator, 2026-09-28): the
   evaluator, the time, then the gate. The task, the verdict and the reason
   never go: which task was judged, what the judge said, and why. *)
let harness_drop_order = [ Harness_evaluator; Harness_time; Harness_gate ]

let harness_layout ~inner_width =
  Table.fit ~inner_width ~width:harness_column_width ~flex:Harness_reason
    ~drop_order:harness_drop_order harness_columns

let harness_cell ~verdict_style ~reason_width values = function
  | Harness_time ->
      Table.cell ~header:"TIME" ~width:harness_time_width values.hrow_time
  | Harness_task ->
      Table.cell ~header:"TASK" ~width:harness_task_width values.hrow_task
  | Harness_gate ->
      Table.cell ~header:"GATE" ~width:harness_gate_width values.hrow_gate
  | Harness_verdict ->
      Table.cell ~style:verdict_style ~header:"VERDICT"
        ~width:harness_verdict_width values.hrow_verdict
  | Harness_evaluator ->
      Table.cell ~header:"EVALUATOR" ~width:harness_evaluator_width
        values.hrow_evaluator
  | Harness_reason ->
      Table.cell ~fold:Table.Fold_tail ~header:"REASON" ~width:reason_width
        values.hrow_reason

let harness_cells ?(verdict_style = "")
    ~(layout : harness_column Table.layout) values =
  List.map
    (harness_cell ~verdict_style ~reason_width:layout.Table.flex_width values)
    layout.Table.shown

let harness_header_row ~layout =
  Table.header_row (harness_cells ~layout harness_no_values)

let harness_row ~verdict_style ~layout values =
  Table.row (harness_cells ~verdict_style ~layout values)

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

(* Wide enough for its own name. The mark had a blank header because one
   cell holds no word, so the only column on the screen with no name was
   the one carrying the judge's answer -- the reader saw a stripe of
   glyphs and nothing saying what they were. Four more cells buys the
   header; the list draws the glyph legend under it. *)
let planning_proof_width = 5
let planning_priority_width = 3
let planning_open_width = 16
let planning_age_width = 6
let planning_due_width = 10

(* A title folded below this identifies no goal. Below it the list gives up
   columns in its drop order rather than cut the title. *)
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

(* The goal list's columns, named so a narrow list can say which it spares
   (workbench RFC section 5.4, #36347). The title sits in the middle, so when
   the row ran past the frame the cut fell on the age and the due date after
   it rather than on anything the list had chosen to give up. *)
type planning_column =
  | Planning_phase
  | Planning_proof
  | Planning_priority
  | Planning_open
  | Planning_title
  | Planning_age
  | Planning_due

let planning_columns =
  [ Planning_phase
  ; Planning_proof
  ; Planning_priority
  ; Planning_open
  ; Planning_title
  ; Planning_age
  ; Planning_due
  ]

(* The title's entry is its floor: it is the flexible column and takes what
   the others leave. The phase is as wide as the widest bracketed label the
   caller draws. *)
let planning_column_width ~phase_width = function
  | Planning_phase -> phase_width
  | Planning_proof -> planning_proof_width
  | Planning_priority -> planning_priority_width
  | Planning_open -> planning_open_width
  | Planning_title -> planning_minimum_title_width
  | Planning_age -> planning_age_width
  | Planning_due -> planning_due_width

(* What a narrow list gives up, first to go first (operator, 2026-09-28): the
   due date, the age, the open-work tally, then the judge's mark. The phase,
   the priority and the title never go: where the goal stands, how much it
   matters, and which goal it is. *)
let planning_drop_order =
  [ Planning_due; Planning_age; Planning_open; Planning_proof ]

let planning_layout ~inner_width ~phase_width =
  Table.fit ~inner_width ~width:(planning_column_width ~phase_width)
    ~flex:Planning_title ~drop_order:planning_drop_order planning_columns

let planning_cell ~phase_style ~priority_style ~open_style ~phase_width
    ~title_width values = function
  | Planning_phase ->
      Table.cell ~style:phase_style ~header:"PHASE" ~width:phase_width
        values.prow_phase
  | Planning_proof ->
      Table.cell ~header:"JUDGE" ~width:planning_proof_width values.prow_proof
  | Planning_priority ->
      Table.cell ~style:priority_style ~header:"PRI"
        ~width:planning_priority_width values.prow_priority
  | Planning_open ->
      Table.cell ~style:open_style ~header:"OPEN" ~width:planning_open_width
        values.prow_open
  | Planning_title ->
      Table.cell ~fold:Table.Fold_tail ~header:"TITLE" ~width:title_width
        values.prow_title
  | Planning_age ->
      Table.cell ~align:Table.Right ~header:"AGE" ~width:planning_age_width
        values.prow_age
  | Planning_due ->
      Table.cell ~header:"DUE" ~width:planning_due_width values.prow_due

let planning_cells ?(phase_style = "") ?(priority_style = "") ?(open_style = "")
    ~phase_width ~(layout : planning_column Table.layout) values =
  List.map
    (planning_cell ~phase_style ~priority_style ~open_style ~phase_width
       ~title_width:layout.Table.flex_width values)
    layout.Table.shown

let planning_header_row ~phase_width ~layout =
  Table.header_row (planning_cells ~phase_width ~layout planning_no_values)

let planning_row ?(priority_style = "") ?(open_style = "") ~phase_style
    ~phase_width ~layout values =
  Table.row
    (planning_cells ~phase_style ~priority_style ~open_style ~phase_width
       ~layout values)

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

(* The title is what the list is read for, so it is the last thing a narrow
   list takes cells from. Thirty cells hold about fifteen Hangul syllables,
   enough to tell one post from the next; below that the list gives up
   columns in its drop order rather than cutting the title (operator,
   2026-09-28). *)
let board_minimum_title_width = 30

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

(* The list's columns, named so the table can say which of them it spares
   when the row is narrow (workbench RFC section 5.4, #38988). *)
type board_column =
  | Board_mark
  | Board_id
  | Board_hearth
  | Board_author
  | Board_title
  | Board_age
  | Board_score
  | Board_replies

let board_columns =
  [ Board_mark
  ; Board_id
  ; Board_hearth
  ; Board_author
  ; Board_title
  ; Board_age
  ; Board_score
  ; Board_replies
  ]

(* The title's entry is its floor: it is the flexible column and takes what
   the others leave. *)
let board_column_width = function
  | Board_mark -> board_mark_width
  | Board_id -> board_id_width
  | Board_hearth -> board_hearth_width
  | Board_author -> board_author_width
  | Board_title -> board_minimum_title_width
  | Board_age -> board_age_width
  | Board_score -> board_score_width
  | Board_replies -> board_replies_width

(* What a narrow list gives up, first to go first (operator, 2026-09-28).
   - The id: the reader takes it with Y (workbench RFC section 5.6) and the
     post it opens shows it whole.
   - The hearth: the census row above the list already names the hearths and
     their counts.
   - The replies and then the score: counts a reader can do without before
     knowing who wrote the post.
   - The author last of all.
   The mark, the title and the age never go: the kind of post, what it is
   about, and how long ago it moved are what a row is for. *)
let board_drop_order =
  [ Board_id; Board_hearth; Board_replies; Board_score; Board_author ]

let board_layout ~inner_width =
  Table.fit ~inner_width ~width:board_column_width ~flex:Board_title
    ~drop_order:board_drop_order board_columns

let board_cell ~styles ~age_header ~title_width values = function
  | Board_mark ->
      (* The kind mark is a mark, like Planning's proof. A name would be
         wider than the cell holding it, and it carries its own dress: the
         glyph and its colour are chosen together. *)
      Table.cell ~header:" " ~width:board_mark_width values.brow_mark
  | Board_id ->
      Table.cell ~style:styles.bstyle_id ~header:"ID" ~width:board_id_width
        values.brow_id
  | Board_hearth ->
      Table.cell ~style:styles.bstyle_hearth ~header:"HEARTH"
        ~width:board_hearth_width values.brow_hearth
  | Board_author ->
      Table.cell ~style:styles.bstyle_author ~header:"AUTHOR"
        ~width:board_author_width values.brow_author
  | Board_title ->
      Table.cell ~fold:Table.Fold_tail ~header:"TITLE" ~width:title_width
        values.brow_title
  | Board_age ->
      (* Right, the way Planning's age reads. A span is a number and the two
         screens are read one after the other; left on one and right on the
         other is the drift this description exists to close. *)
      Table.cell ~align:Table.Right ~style:styles.bstyle_age
        ~header:age_header ~width:board_age_width values.brow_age
  | Board_score ->
      Table.cell ~style:styles.bstyle_score ~header:"SCORE"
        ~width:board_score_width values.brow_score
  | Board_replies ->
      Table.cell ~style:styles.bstyle_replies ~header:"REPLIES"
        ~width:board_replies_width values.brow_replies

let board_cells ?(styles = board_no_styles) ~age_header
    ~(layout : board_column Table.layout) values =
  List.map
    (board_cell ~styles ~age_header ~title_width:layout.Table.flex_width
       values)
    layout.Table.shown

(* How long ago the time the caller chose was, or a dash when the post carried
   no such time. Which of a post's two times that is belongs to the sort, not
   to this cell. *)
let board_age_text ~now = function
  | Some at -> Masc_tui_message_layout.span_text (now -. at)
  | None -> Masc_tui_theme.Glyph.no_value

(* A list pane's row label: what the row is about, then the reading that
   parts it from its neighbours. The pane folds a label from the middle and
   keeps its tail, so the parting reading goes last -- in front it folds away
   whenever the neighbours share an opening, which is the ordinary case for a
   column of rows that are alike enough to need parting at all.

   The full-width list rows put the same reading first, where nothing folds.
   These two orders are not a disagreement: one draws in the room it has, the
   other in the room a fold leaves.

   [apart] is an option because a row may have nothing to be parted by -- a
   verdict whose clock the codec could not read, an asker the wire did not
   name -- and that row keeps its subject alone rather than trailing a
   separator with nothing after it. An empty string would say the same thing
   in a second vocabulary, and would leave every caller deciding which of the
   two absences it holds. *)
let sidebar_row_label ~about ~apart =
  match apart with None -> about | Some apart -> about ^ "  " ^ apart

let board_header_row ~age_header ~layout =
  Table.header_row (board_cells ~age_header ~layout board_no_values)

let board_row ?close ~styles ~age_header ~layout values =
  Table.row ?close (board_cells ~styles ~age_header ~layout values)

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

(* The stops were numbered "1 Goals", "2 Task Review", "3 Evaluator Verdicts"
   and the key sheet joined them with arrows, which promised a pipeline: work
   a goal, hand it to review, read the verdict. They are not stages of one
   thing. Goals is the goal lifecycle, judged by the goal verifier against
   its own ledger; Review and Verdicts are the two halves of the task
   protocol -- what is waiting for a ruling, and what was ruled -- and a goal
   sitting in [verifying] never appears in either.

   Numbers gone, and the two task stops share a word so the axis they belong
   to is visible without a separator. Goals carries the count of goals with
   the judge, the way Review carries the count waiting for one: the reading
   an operator opens this screen for was the one it made them count by eye. *)
let planning_strip_plain ~tab ~review_count ~verifying_count ~window =
  let counted label = function
    | Some total when total > 0 -> Printf.sprintf "%s\xc2\xb7%d" label total
    | Some _ | None -> label
  in
  let stops =
    [ Planning_goals, counted "Goals" verifying_count
    ; Planning_task_review, counted "Task Review" review_count
    ; Planning_verdicts, "Task Verdicts"
    ]
  in
  List.map
    (fun (stop, label) -> (stop, if stop = tab then label ^ window else label))
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

(* A schedule the runner holds back (#38205). Its status stays [due] and its
   last wake is still the previous occurrence's, so without this reading a
   held heartbeat looks like a late one. *)
let schedule_hold_tag ~due = "held since " ^ due

let schedule_hold_reading ~due =
  schedule_hold_tag ~due ^ ": the keeper has not taken the previous wake yet"

(* #34642: a schedule held on its target's shutdown fence. *)
let schedule_fence_hold_reading ~due ~target ~fence_owner =
  Printf.sprintf
    "%s: %s is shutting down (%s) and takes no wakes until that finishes"
    (schedule_hold_tag ~due)
    target
    fence_owner

(* The same hold when the runner has not read its list again since (#38411).
   A tick that fails keeps the list without looking, so the hold is drawn at
   the time it was [checked], not as the present. The due column beside the
   row still says when the held occurrence came due. *)
let schedule_hold_as_of_tag ~checked = "held as of " ^ checked

let schedule_hold_as_of_reading ~checked =
  schedule_hold_as_of_tag ~checked
  ^ ": the keeper had not taken the previous wake by then"

(* The fence hold drawn the same way, at the time it was [checked]: a failed
   tick does not re-read why it held either (#38411, #34642). *)
let schedule_fence_hold_as_of_reading ~checked ~target ~fence_owner =
  Printf.sprintf
    "%s: %s was shutting down (%s) and took no wakes until that finished"
    (schedule_hold_as_of_tag ~checked)
    target
    fence_owner
