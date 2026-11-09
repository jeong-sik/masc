open Masc_tui_ansi

module Message_layout = Masc_tui_message_layout
module Story = Masc_tui_keeper_story
module Memory_reading = Masc_tui_keeper_memory_reading

(* The window is a rule, a title and up to ten lines: the story page of a
   Keeper whose feed holds its newest turns, its newest wakes and its last
   digest is that long. A page with more lines gives the feed's oldest events
   up first. The list keeps four rows whenever the window can keep its own four
   beside them, which takes eight rows. On a shorter screen the window takes
   every row and covers the list -- the overlay RFC-0515 section 2.5 gives a
   screen too short for both -- rather than leave a list of one to three
   rows. *)
let target_rows = 12
let least_rows = 4
let list_floor = 4

let rows ~budget =
  if budget <= 0 then 0
  else if budget < list_floor + least_rows then budget
  else min target_rows (budget - list_floor)
;;

let dim text = Ansi.dim ^ text ^ Ansi.reset
let warn text = Theme.warn () ^ text ^ Ansi.reset

let tab ~current page =
  let text = " " ^ Story.tab_label page ^ " " in
  if page = current then Ansi.reverse ^ text ^ Ansi.reset else dim text
;;

(* Every tab when the title has room for them beside its lead, the current one
   alone when it has not. *)
let title ~inner ~lead ~current =
  let all = String.concat " " (List.map (tab ~current) Story.pages) in
  let tabs =
    if Message_layout.display_width lead + 1 + Message_layout.display_width all <= inner
    then all
    else tab ~current current
  in
  let gap = max 1 (inner - Message_layout.display_width lead - Message_layout.display_width tabs) in
  lead ^ String.make gap ' ' ^ tabs
;;

(* The lines a window of [rows] rows holds: all but its rule and its title. *)
let body_rows ~rows = max 0 (rows - 2)

let draw buf ~cols ~rows ~lead ~current lines =
  let inner = max 1 (framed_inner_width cols) in
  let body_rows = body_rows ~rows in
  if rows >= 1 then box_divider buf cols;
  if rows >= 2 then box_line buf cols (title ~inner ~lead ~current);
  let total = List.length lines in
  let shown =
    if total <= body_rows then lines
    else if body_rows = 0 then []
    else
      List.take (body_rows - 1) lines
      @ [ dim (Printf.sprintf "  … %d more" (total - (body_rows - 1))) ]
  in
  List.iter (box_line buf cols) shown;
  for _ = 1 to body_rows - List.length shown do
    box_empty buf cols
  done
;;

(* One label column, so the values of a page start at one column. *)
let label_cells = 11

let labelled label value =
  "  " ^ dim (Message_layout.fit_width label label_cells) ^ value
;;

let ago ~now at =
  match Message_layout.age_text ~now ~since:at with
  | Some span -> span ^ " ago"
  | None -> Masc_tui_theme.Glyph.no_value
;;

let status_cells = 9
let clock_cells = 11
let relative_cells = 12

let clock_text = function
  | None -> Masc_tui_theme.Glyph.no_value
  | Some at ->
      let tm = Unix.localtime at in
      Printf.sprintf "%02d-%02d %02d:%02d" (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
        tm.Unix.tm_hour tm.Unix.tm_min
;;

(* A schedule that has not run reads [in 5m], or [late 5m] once its time has
   passed. A closed one reads [5m ago]. A status this build does not know says
   nothing about the time. *)
let relative_text ~now (row : Masc_tui_types.schedule_row) = function
  | None -> Masc_tui_theme.Glyph.no_value
  | Some at ->
      (match Masc_tui_agenda.standing_of_wire row.sch_status with
       | Masc_tui_agenda.Coming ->
           if at >= now then "in " ^ Message_layout.span_text (at -. now)
           else "late " ^ Message_layout.span_text (now -. at)
       | Masc_tui_agenda.Settled -> ago ~now at
       | Masc_tui_agenda.Unrecognised _ -> Masc_tui_theme.Glyph.no_value)
;;

(* A held row, or a row whose delivered wake has not settled, is one
   [Masc_tui_types.chat_schedule_entries] ranks first. The tab keeps every
   row in time order, so the word in the status column says it instead of
   the request status: a one-shot whose request succeeded can still hold a
   wake that sat in the queue for days. The stages are those
   [Tui_schedule_observation.needs_attention] names. *)
let attention_word (row : Masc_tui_types.schedule_row) =
  match row.sch_runner_hold with
  | Some _ -> Some "held"
  | None ->
      let open Masc.Tui_schedule_observation in
      (match row.sch_occurrence.stage with
       | Dispatching -> Some "sending"
       | Dispatch_failed _ -> Some "send fail"
       | Queued | Queued_at _ -> Some "queued"
       | Missing -> Some "missing"
       | Turn_started -> Some "running"
       | Turn_ended | Consumed | Settling _ -> Some "settling"
       | Transferring _ -> Some "handoff"
       | Unknown _ -> Some "unknown"
       | No_occurrence | Completed | Cancelled _ -> None)
;;

(* One time line, oldest first, the way the Story page reads past to next. A
   row with no time goes last. *)
let by_time (_, left) (_, right) =
  match left, right with
  | Some left, Some right -> Float.compare left right
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0
;;

let schedule_row_line ~now ((row : Masc_tui_types.schedule_row), due) =
  let color, status =
    match attention_word row with
    | Some word -> Theme.warn (), word
    | None ->
        ( Masc_tui_render_work.schedule_status_color row.sch_status
        , Terminal_text.single_line row.sch_status )
  in
  let what =
    Terminal_text.single_line (Option.value ~default:row.sch_schedule_id row.sch_payload_summary)
  in
  String.concat ""
    [ "  "
    ; color
    ; Message_layout.fit_width status status_cells
    ; Ansi.reset
    ; " "
    ; Message_layout.fit_width (clock_text due) clock_cells
    ; " "
    ; Message_layout.fit_width (relative_text ~now row due) relative_cells
    ; " "
    ; dim (Terminal_text.single_line row.sch_recurrence_summary ^ " · ")
    ; what
    ]
;;

let next_run_cell (state : Masc_tui_types.state) ~now ~keeper_name =
  Masc_tui_keeper_next_run.cell ~now
    (Masc_tui_keeper_next_run.find
       (Masc_tui_keeper_next_run.index_of_agenda
          ~freshness:state.schedules_agenda_freshness
          state.schedules_agenda)
       ~keeper_name)
;;

let memory_reading (state : Masc_tui_types.state) ~keeper_name =
  Memory_reading.find (Memory_reading.index_of_snapshot state.memory_health) ~keeper_name
;;

(* One Keeper's own schedule page as the window holds it: the first page of the
   Automation tab's read, which the window asks for while it is open. [Not_read]
   is the moment before that read starts, or a server that cannot be asked. The
   fleet agenda is not a source here: its page is capped with live rows first,
   so a Keeper whose schedules are closed or further down is missing from it. *)
type schedules =
  | Not_read
  | Reading
  | Read_failed of string
  | Store_unreadable of string option
  | Page of { snapshot : Masc_tui_types.schedule_snapshot; refresh : refresh }

(* Whether a page drawn from an earlier read is being read again. *)
and refresh =
  | Current
  | Refreshing
  | Refresh_failed of string

let schedules (state : Masc_tui_types.state) ~keeper_name =
  (* A page another pane left (the Automation tab on its third page) is not the
     first page this window asked for. *)
  let first_page =
    match state.keeper_schedules with
    | Some (name, snapshot) when String.equal name keeper_name ->
        (match snapshot.scs_paging with
         | Masc_tui_types.Schedule_paging_unavailable
         | Masc_tui_types.Schedule_paging { page_cursor = None; _ } -> Some snapshot
         | Masc_tui_types.Schedule_paging { page_cursor = Some _; _ } -> None)
    | Some _ | None -> None
  in
  let failure =
    match state.keeper_schedules_error with
    | Some (name, detail) when String.equal name keeper_name -> Some detail
    | Some _ | None -> None
  in
  let waiting =
    Masc_tui_types.detail_read_waiting state ~tab:Masc_tui_types.Detail_automation
      ~keeper:keeper_name
  in
  match first_page, failure with
  | None, Some detail -> Read_failed detail
  | None, None -> if waiting then Reading else Not_read
  | Some snapshot, (Some _ | None)
    when Option.is_some snapshot.scs_read_error || Option.is_none snapshot.scs_request_count ->
      Store_unreadable snapshot.scs_read_error
  | Some snapshot, Some detail -> Page { snapshot; refresh = Refresh_failed detail }
  | Some snapshot, None -> Page { snapshot; refresh = (if waiting then Refreshing else Current) }
;;

(* A page drawn from an earlier reading, or whose re-read failed, is the last
   reading and not the Keeper's present one. *)
let refresh_suffix = function
  | Current -> ""
  | Refreshing -> " (reading again)"
  | Refresh_failed _ -> " (schedule read failed)"
;;

(* What a source says about itself where its events may be missing from the
   feed. A [Caution] is a source whose read failed or whose answer cannot be
   placed in time. A [Notice] is a source not read yet, being read, cut, or
   drawn from an earlier reading. *)
type note =
  | Caution of string
  | Notice of string

let note_line = function
  | Caution text -> warn text
  | Notice text -> dim text
;;

(* One wake the way the schedule row tells it: how it ended, and the schedule
   that woke the Keeper. A schedule that is closed or held still counts: its
   wake happened. *)
let wake_item_text wake =
  let row = Masc_tui_keeper_wakes.row wake in
  let outcome = Terminal_text.single_line (Masc_tui_render_work.schedule_outcome_word row) in
  let outcome_text =
    if String.equal outcome Masc_tui_theme.Glyph.no_value then ""
    else " " ^ Masc_tui_render_prim.semantic_status_color outcome ^ outcome ^ Ansi.reset
  in
  let error_text =
    match row.sch_last_wake_status with
    | Some Schedule_contract_values.Wake_failed ->
        (match row.sch_last_wake_error with
         | Some error -> dim (" · " ^ Terminal_text.single_line error)
         | None -> "")
    | Some (Schedule_contract_values.Wake_running | Schedule_contract_values.Wake_succeeded)
    | None -> ""
  in
  dim "wake" ^ outcome_text
  ^ dim
      (" · "
       ^ Terminal_text.single_line (Option.value ~default:row.sch_schedule_id row.sch_payload_summary))
  ^ error_text
;;

(* One turn the way the receipt tells it: the stop reason as it wrote it. A
   record without a stop reason is told as that, in the warning colour. No
   reason is sorted into ok or failed here. *)
let turn_item_text (turn : Masc_tui_keeper_turns.turn) =
  match turn.stop with
  | Masc_tui_keeper_turns.Stopped reason -> dim ("turn " ^ Terminal_text.single_line reason)
  | Masc_tui_keeper_turns.No_stop_reason -> warn "turn no stop reason"
;;

let feed_item_text = function
  | Masc_tui_keeper_feed.Wake wake -> wake_item_text wake
  | Masc_tui_keeper_feed.Turn turn -> turn_item_text turn
  | Masc_tui_keeper_feed.Digest _ -> dim "digest ok · librarian"
;;

(* The column of ages, wide enough for the longest the ladder writes (a hundred
   days, or ninety-nine days and 23 hours) and the word after it. *)
let feed_age_cells = 11

let feed_item_line ~now item =
  dim (Message_layout.fit_width (ago ~now (Masc_tui_keeper_feed.at item)) feed_age_cells)
  ^ feed_item_text item
;;

(* The reason a read stored when it failed, after the words that say what
   failed. A reason with no text once on one line adds nothing. *)
let with_detail text detail =
  match Terminal_text.single_line detail with
  | "" -> text
  | detail -> text ^ ": " ^ detail
;;

(* The Keeper's newest turns, and a note for a read that has not answered or
   that failed. A failed read with nothing held to show leaves it unknown
   whether a turn came, and a failed re-read leaves the held turns as the last
   reading. *)
let turns_source (state : Masc_tui_types.state) ~keeper_name =
  match
    Masc_tui_fetched.view_for ~equal:String.equal state.keeper_story_turns ~key:keeper_name
  with
  | Masc_tui_fetched.Absent -> [], [ Notice "turns not read yet" ]
  | Masc_tui_fetched.Loading -> [], [ Notice "turns reading…" ]
  | Masc_tui_fetched.Ready turns -> turns, []
  | Masc_tui_fetched.Stale ([], detail) | Masc_tui_fetched.Failed detail ->
      [], [ Caution (with_detail "turns unknown, the read failed" detail) ]
  | Masc_tui_fetched.Stale ((_ :: _ as turns), detail) ->
      turns, [ Caution (with_detail "turns (read failed)" detail) ]
;;

(* The note of a schedule page that is not the Keeper's present reading. *)
let refresh_note refresh text =
  match refresh with
  | Current | Refreshing -> Notice (text ^ refresh_suffix refresh)
  | Refresh_failed detail -> Caution (with_detail (text ^ refresh_suffix refresh) detail)
;;

(* The Keeper's wakes on its schedule page, newest first, and a note for a
   page that is not read, not readable, cut, being read again or whose re-read
   failed. A wake whose time cannot be read leaves the newest unknown. *)
let wakes_source (state : Masc_tui_types.state) ~keeper_name =
  match schedules state ~keeper_name with
  | Not_read -> [], [ Notice "wakes not read yet" ]
  | Reading -> [], [ Notice "wakes reading…" ]
  | Read_failed detail ->
      [], [ Caution (with_detail "wakes unknown, the schedule read failed" detail) ]
  | Store_unreadable detail ->
      let text = "wakes unknown, the schedule store is unreadable" in
      ( []
      , [ Caution
            (match detail with
             | Some detail -> with_detail text detail
             | None -> text)
        ] )
  | Page { snapshot; refresh } ->
      (match
         Masc_tui_keeper_wakes.of_page ~truncated:snapshot.scs_truncated snapshot.scs_rows
       with
       | Masc_tui_keeper_wakes.Unplaced ->
           let text = "wakes unknown, a wake time is unreadable" ^ refresh_suffix refresh in
           ( []
           , [ Caution
                 (match refresh with
                  | Refresh_failed detail -> with_detail text detail
                  | Current | Refreshing -> text)
             ] )
       | Masc_tui_keeper_wakes.Wakes { newest_first; coverage } ->
           ( newest_first
           , (match coverage, refresh with
              | Masc_tui_keeper_wakes.Whole_page, Current -> []
              | Masc_tui_keeper_wakes.Whole_page, (Refreshing | Refresh_failed _) ->
                  [ refresh_note refresh "wakes" ]
              | Masc_tui_keeper_wakes.First_page, (Current | Refreshing | Refresh_failed _) ->
                  [ refresh_note refresh "wakes from the first page only" ]) ))
;;

(* The librarian's last digest from the memory-health reading, and a note for a
   reading that is not there. A reading that says the Keeper has no digest, or
   no memory-health row, has nothing to note. *)
let digest_source (state : Masc_tui_types.state) ~keeper_name =
  match memory_reading state ~keeper_name with
  | Memory_reading.Row { digest_at; _ } -> digest_at, []
  | Memory_reading.No_row -> None, []
  | Memory_reading.Unknown -> None, [ Notice "digest not read yet" ]
  | Memory_reading.Refused reason ->
      None, [ Caution (with_detail "digest unknown, the memory-health row was refused" reason) ]
;;

(* The past group of the story page as one feed: the newest turns, the newest
   wakes and the last digest, oldest first, so that the newest ends the feed. A
   source that is not read, or whose read failed, has no event to put in its
   place, so it gets a line of its own after the events, whatever the width. The
   cautions come before the notices. The notes keep their lines and the oldest
   events give way to the window's height; a window too short for every note
   keeps the cautions. With no line to spare the feed is empty, notes included. *)
let feed_lines (state : Masc_tui_types.state) ~now ~max_lines ~keeper_name =
  let turns, turn_notes = turns_source state ~keeper_name in
  let wakes, wake_notes = wakes_source state ~keeper_name in
  let digest_at, digest_notes = digest_source state ~keeper_name in
  let cautions, notices =
    List.partition
      (function Caution _ -> true | Notice _ -> false)
      (turn_notes @ wake_notes @ digest_notes)
  in
  let item_lines =
    List.map (feed_item_line ~now) (Masc_tui_keeper_feed.of_sources ~turns ~wakes ~digest_at)
  in
  if max_lines <= 0 then []
  else
    let note_lines = List.take max_lines (List.map note_line (cautions @ notices)) in
    let room = max_lines - List.length note_lines in
    List.drop (max 0 (List.length item_lines - room)) item_lines @ note_lines
;;

let schedule_lines (state : Masc_tui_types.state) ~now ~keeper_name =
  (* The cell the list draws for this Keeper, so the header and the list row
     cannot disagree about the next run. *)
  let lead =
    match next_run_cell state ~now ~keeper_name with
    | Some cell -> cell.Masc_tui_keeper_axis_cell.text
    | None -> "◷ none"
  in
  match schedules state ~keeper_name with
  | Not_read -> [ dim "  ◷ this Keeper's schedules are not read yet" ]
  | Reading -> [ dim "  ◷ reading this Keeper's schedules…" ]
  | Read_failed detail ->
      [ warn ("  ◷ schedule read failed: " ^ Terminal_text.single_line detail) ]
  | Store_unreadable detail ->
      [ warn
          ("  ◷ schedule store unreadable"
           ^ (match detail with
              | Some detail -> ": " ^ Terminal_text.single_line detail
              | None -> ""))
      ]
  | Page { snapshot; refresh } ->
      let counts =
        match snapshot.scs_counts with
        | Some counts -> " · " ^ Masc_tui_types.schedule_counts_line counts
        | None -> ""
      in
      let entries =
        List.stable_sort by_time (Masc_tui_types.chat_schedule_entries ~keeper_name snapshot)
      in
      let rows =
        match entries, snapshot.scs_rows with
        | [], [] ->
            (match
               Masc_tui_render_schedule.classify_keeper_schedule_absence
                 ~truncated:snapshot.scs_truncated ~shown:0 ~total:snapshot.scs_request_count
             with
             | Masc_tui_render_schedule.Store_has_none -> [ dim "  no schedules for this Keeper" ]
             | Masc_tui_render_schedule.Page_capped _ ->
                 [ warn "  none on the first page: more schedules may exist" ])
        | [], _ :: _ -> [ dim "  nothing live or recent on this page" ]
        | _ :: _, ([] | _ :: _) -> List.map (schedule_row_line ~now) entries
      in
      let observed = Terminal_text.short_timestamp snapshot.scs_observed_at_iso in
      let notes =
        (if snapshot.scs_truncated then [ warn "  the page is cut: more schedules may exist" ] else [])
        @ (match refresh with
           | Current -> []
           | Refreshing -> [ dim (Printf.sprintf "  showing the reading of %s, reading again" observed) ]
           | Refresh_failed detail ->
               [ warn
                   (Printf.sprintf "  read failed, showing the reading of %s: %s" observed
                      (Terminal_text.single_line detail))
               ])
      in
      (* The window cuts its body to the available rows. Keep the read's
         provenance ahead of the rows so that cut cannot hide it. *)
      notes @ (dim ("  " ^ lead ^ counts) :: rows)
;;

let memory_state_style : Masc_tui_types.memory_state -> string = function
  | Masc_tui_types.Memory_ordinary -> Theme.recede ()
  | Masc_tui_types.Memory_warning | Masc_tui_types.Memory_degraded
  | Masc_tui_types.Memory_no_current | Masc_tui_types.Memory_source_only -> Theme.warn ()
  | Masc_tui_types.Memory_starving | Masc_tui_types.Memory_read_error -> Theme.bad ()
;;

let lag_text = function
  | Memory_reading.Lag turns -> Message_layout.count_noun turns "unread turn"
  | Memory_reading.Lag_unmeasured -> "unread turns not measured"
;;

let gap_text = function
  | Memory_reading.No_gap -> "none"
  | Memory_reading.Gap { first_atom; past_last_atom } ->
      Printf.sprintf "%s the librarian has not digested"
        (Message_layout.count_noun (past_last_atom - first_atom) "atom")
  | Memory_reading.Gap_unmeasured -> "not measured"
;;

let memory_lines (state : Masc_tui_types.state) ~now ~keeper_name =
  match memory_reading state ~keeper_name with
  | Memory_reading.Unknown -> [ dim "  memory health is not read yet" ]
  | Memory_reading.No_row -> [ dim "  no memory-health row for this Keeper" ]
  | Memory_reading.Refused reason ->
      [ warn ("  memory-health row refused: " ^ Terminal_text.single_line reason) ]
  | Memory_reading.Row
      { state = memory; lag; gap; digest_at; updated_at; added; removed
      ; source_invalidations; age_bins } ->
      let updated =
        match updated_at with
        | Some at -> "updated " ^ ago ~now at
        | None -> "update time not recorded"
      in
      let digest =
        match digest_at with
        | Some at -> "last digest " ^ ago ~now at
        | None -> "no digest recorded"
      in
      [ labelled "memory"
          (memory_state_style memory
           ^ Masc_tui_types.memory_state_label memory
           ^ Ansi.reset
           ^ dim (Printf.sprintf " · %s · +%d -%d" updated added removed))
      ; labelled "facts"
          (dim (String.concat " · " (Masc_tui_keeper_age_ladder.keeper_clauses ~ko:(state.ui_language = Masc_tui_types.Lang_ko) age_bins)))
      ; labelled "librarian" (lag_text lag ^ dim (" · " ^ digest))
      ; labelled "gap"
          (match gap with
           | Memory_reading.No_gap -> dim (gap_text gap)
           | Memory_reading.Gap _ | Memory_reading.Gap_unmeasured -> Theme.warn () ^ gap_text gap ^ Ansi.reset)
      ]
      @ (if source_invalidations > 0 then
           [ labelled "stale"
               (Theme.warn ()
                ^ Printf.sprintf "%d source invalidation%s" source_invalidations
                    (if source_invalidations = 1 then "" else "s")
                ^ Ansi.reset)
           ]
         else [])
;;
