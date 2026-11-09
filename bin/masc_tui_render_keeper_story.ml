open Masc_tui_ansi

module Message_layout = Masc_tui_message_layout
module Story = Masc_tui_keeper_story
module Memory_reading = Masc_tui_keeper_memory_reading

(* The window is a rule, a title and up to seven lines: the story page of a
   failing Keeper with a last wake is that long. The list keeps four rows
   whenever the window can keep its own four beside them, which takes eight
   rows. On a shorter screen the window takes every row and covers the list --
   the overlay RFC-0515 section 2.5 gives a screen too short for both -- rather
   than leave a list of one to three rows. *)
let target_rows = 9
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

let draw buf ~cols ~rows ~lead ~current lines =
  let inner = max 1 (framed_inner_width cols) in
  let body_rows = max 0 (rows - 2) in
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

let schedule_row_line ~now ((row : Masc_tui_types.schedule_row), due) =
  let color = Masc_tui_render_work.schedule_status_color row.sch_status in
  let status = Terminal_text.single_line row.sch_status in
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
   reading and not the Keeper's present one. The note sits at the head of the
   line, where a narrow screen's cut does not reach it. *)
let refresh_note = function
  | Current -> ""
  | Refreshing -> dim " (reading again)"
  | Refresh_failed _ -> warn " (schedule read failed)"
;;

(* The newest wake among the Keeper's schedules. A schedule that is closed or
   held still counts: its wake happened. *)
let wake_text ~now ~head (wake : Masc_tui_keeper_last_wake.t) =
  let row = Masc_tui_keeper_last_wake.row wake in
  let outcome = Terminal_text.single_line (Masc_tui_render_work.schedule_outcome_word row) in
  let outcome_text =
    if String.equal outcome Masc_tui_theme.Glyph.no_value then ""
    else
      dim " · " ^ Masc_tui_render_prim.semantic_status_color outcome ^ outcome ^ Ansi.reset
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
  head
  ^ dim
      (Printf.sprintf " %s · %s"
         (ago ~now (Masc_tui_keeper_last_wake.at wake))
         (Terminal_text.single_line
            (Option.value ~default:row.sch_schedule_id row.sch_payload_summary)))
  ^ outcome_text ^ error_text
;;

let last_wake_entry (state : Masc_tui_types.state) ~now ~keeper_name =
  match schedules state ~keeper_name with
  | Not_read -> Some (dim "last wake not read yet")
  | Reading -> Some (dim "last wake reading…")
  | Read_failed _ -> Some (warn "last wake unknown, the schedule read failed")
  | Store_unreadable _ -> Some (warn "last wake unknown, the schedule store is unreadable")
  | Page { snapshot; refresh } ->
      let note = refresh_note refresh in
      (match
         Masc_tui_keeper_last_wake.of_page ~truncated:snapshot.scs_truncated snapshot.scs_rows
       with
       | Masc_tui_keeper_last_wake.Newest wake ->
           Some (wake_text ~now ~head:(dim "last wake" ^ note) wake)
       | Masc_tui_keeper_last_wake.Newest_on_first_page wake ->
           Some (wake_text ~now ~head:(dim "last wake on the first page" ^ note) wake)
       | Masc_tui_keeper_last_wake.Not_on_first_page ->
           Some (dim "last wake not on the first page" ^ note)
       | Masc_tui_keeper_last_wake.Unplaced ->
           Some (warn "last wake unknown, a wake time is unreadable" ^ note)
       | Masc_tui_keeper_last_wake.No_wake ->
           (match refresh with
            | Current | Refreshing -> None
            (* The earlier reading found no wake; whether one came since is
               not known. *)
            | Refresh_failed _ -> Some (warn "last wake unknown, the schedule read failed")))
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
      let entries = Masc_tui_types.chat_schedule_entries ~keeper_name snapshot in
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
