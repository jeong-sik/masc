open Masc_tui_ansi

module Message_layout = Masc_tui_message_layout
module Story = Masc_tui_keeper_story
module Memory_reading = Masc_tui_keeper_memory_reading

(* The window is a rule, a title and up to six lines. The list keeps four rows
   when the screen can spare them, and the window keeps four when it can: on a
   short screen both give way together instead of one taking the other's. *)
let target_rows = 8
let least_rows = 4
let list_floor = 4

let rows ~budget =
  if budget <= 0 then 0
  else min budget (min target_rows (max least_rows (budget - list_floor)))
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

let schedule_lines (state : Masc_tui_types.state) ~now ~keeper_name =
  match state.schedules_agenda, state.schedules_agenda_error with
  | None, Some detail -> [ warn ("  ◷ schedule agenda not read: " ^ Terminal_text.single_line detail) ]
  | None, None -> [ dim "  ◷ the schedule agenda is not read yet" ]
  | Some snapshot, _ when Option.is_some snapshot.scs_read_error ->
      [ warn
          ("  ◷ schedule store unreadable"
           ^ (match snapshot.scs_read_error with
              | Some detail -> ": " ^ Terminal_text.single_line detail
              | None -> ""))
      ]
  | Some snapshot, error ->
      let entries = Masc_tui_types.chat_schedule_entries ~keeper_name snapshot in
      (* The cell the list draws for this Keeper, so the header and the list
         row cannot disagree about the next run. *)
      let lead =
        match next_run_cell state ~now ~keeper_name with
        | Some cell -> cell.Masc_tui_keeper_axis_cell.text
        | None -> "◷ none"
      in
      let count = Message_layout.count_noun (List.length entries) "schedule" in
      let notes =
        (if snapshot.scs_truncated then [ "partial" ] else [])
        @ (match error with
           | Some _ -> [ "read failed, last reading kept" ]
           | None -> [])
        |> function
        | [] -> []
        | _ :: _ as flags ->
            [ warn
                ("  agenda: " ^ String.concat " · " flags
                 ^ (match error with
                    | Some detail -> ": " ^ Terminal_text.single_line detail
                    | None -> "")) ]
      in
      (* The window cuts its body to the available rows. Keep failed/partial
         read provenance ahead of the entries so that cut cannot hide it. *)
      notes
      @ (dim ("  " ^ lead ^ " · " ^ count ^ " aimed at " ^ Terminal_text.single_line keeper_name)
         :: List.map (schedule_row_line ~now) entries)
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
          (dim (String.concat " · " (Masc_tui_keeper_age_ladder.keeper_clauses ~ko:false age_bins)))
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
