(* The Overview's GOALS section: is the fleet's work moving any goal? *)

module Tui_decode = Masc.Tui_decode
module Types = Masc_tui_types
open Masc_tui_ansi

let drawn_phase : Goal_phase.t -> bool = function
  | Goal_phase.Executing | Goal_phase.Verifying
  | Goal_phase.Awaiting_confirmation ->
      true
  | Goal_phase.Completed | Goal_phase.Dropped -> false

(* A calendar date as the server writes [due_date]. Anything else is drawn as
   written, without a countdown, and sorts with the goals that have no date. *)
let parse_due_date due =
  match Scanf.sscanf_opt due "%4d-%2d-%2d%!" (fun y m d -> (y, m, d)) with
  | None -> None
  | Some date -> Ptime.of_date date

let due_order (goal : Tui_decode.overview_goal) =
  Option.bind goal.og_due_date parse_due_date

let compare_due left right =
  match (left, right) with
  | Some l, Some r -> Ptime.compare l r
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0

let drawn_goals goals =
  goals
  |> List.filter (fun (goal : Tui_decode.overview_goal) ->
         drawn_phase goal.og_phase)
  |> List.stable_sort
       (fun (left : Tui_decode.overview_goal) (right : Tui_decode.overview_goal) ->
         match Int.compare left.og_priority right.og_priority with
         | 0 -> compare_due (due_order left) (due_order right)
         | order -> order)

type progress = { active : int; toward_goal : int }

let is_active (task : Tui_decode.task) =
  match task.status with
  | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _ -> true
  | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.Done _
  | Masc_domain.Cancelled _ ->
      false

let progress ~goals ~tasks =
  let listed id =
    List.exists
      (fun (goal : Tui_decode.overview_goal) ->
        List.exists (String.equal id) goal.og_task_ids)
      goals
  in
  let active_tasks = List.filter is_active tasks in
  { active = List.length active_tasks
  ; toward_goal =
      List.length
        (List.filter (fun (task : Tui_decode.task) -> listed task.id)
           active_tasks)
  }

let wanted_rows (reading : Types.overview_goals_reading) =
  match reading with
  | Types.Goals_unread | Types.Goals_failed _ -> 1
  | Types.Goals_read goals -> 1 + max 1 (List.length (drawn_goals goals))

(* Cells of the task bar. A width, not a threshold: nothing is decided by it. *)
let bar_cells = 16

(* Below this the title names no goal; the row runs past the frame's edge
   instead, where the frame's own fit cuts it. *)
let minimum_title_cells = 12

let column_gap = "  "

let task_bar (goal : Tui_decode.overview_goal) =
  if goal.og_task_count <= 0 then String.make bar_cells ' '
  else
    let filled =
      max 0
        (min bar_cells (goal.og_task_done_count * bar_cells / goal.og_task_count))
    in
    let repeat glyph count =
      String.concat "" (List.init (max 0 count) (fun _ -> glyph))
    in
    Theme.ok () ^ repeat "\xe2\x96\x88" filled ^ Ansi.reset ^ Ansi.dim
    ^ repeat "\xe2\x96\x91" (bar_cells - filled)
    ^ Ansi.reset

let task_count_text (goal : Tui_decode.overview_goal) =
  if goal.og_task_count <= 0 then "no tasks"
  else Printf.sprintf "%d/%d tasks" goal.og_task_done_count goal.og_task_count

let idle_text (goal : Tui_decode.overview_goal) =
  match goal.og_stagnation_seconds with
  | Some seconds -> "idle " ^ Masc_tui_render_prim.keeper_lane_idle_text seconds
  | None -> "idle \xe2\x80\x94"

let utc_today ~now =
  Option.bind (Ptime.of_float_s now) (fun instant ->
      Ptime.of_date (Ptime.to_date instant))

let due_text ~today (goal : Tui_decode.overview_goal) =
  match goal.og_due_date with
  | None -> None
  | Some raw -> (
      let raw = Terminal_text.single_line raw in
      match (parse_due_date raw, today) with
      | Some due, Some today ->
          let days, _ = Ptime.Span.to_d_ps (Ptime.diff due today) in
          let y, m, d = Ptime.to_date due in
          let today_year, _, _ = Ptime.to_date today in
          let date =
            if y = today_year then Printf.sprintf "%02d-%02d" m d
            else Printf.sprintf "%04d-%02d-%02d" y m d
          in
          let countdown =
            if days >= 0 then Printf.sprintf "D-%d" days
            else Printf.sprintf "D+%d" (-days)
          in
          Some (Printf.sprintf "due %s (%s)" date countdown)
      | None, _ | Some _, None -> Some ("due " ^ raw))

let widest texts =
  List.fold_left (fun acc text -> max acc (Masc_tui_message_layout.display_width text)) 0
    texts

let goal_rows ~now ~inner_width goals =
  let today = utc_today ~now in
  let counts = List.map task_count_text goals in
  let idles = List.map idle_text goals in
  let dues = List.map (due_text ~today) goals in
  let count_width = widest counts in
  let idle_width = widest idles in
  let due_width =
    widest
      (List.filter_map
         (Option.map (fun text -> column_gap ^ text))
         dues)
  in
  let gap = String.length column_gap in
  let title_width =
    max minimum_title_cells
      (inner_width - gap - (gap + bar_cells) - (gap + count_width)
     - (gap + idle_width) - due_width)
  in
  List.map2
    (fun (goal : Tui_decode.overview_goal) (count, (idle, due)) ->
      let due_cell =
        match due with Some text -> column_gap ^ text | None -> ""
      in
      String.concat ""
        [ column_gap
        ; fit_width (Terminal_text.single_line goal.og_title) title_width
        ; column_gap
        ; task_bar goal
        ; column_gap
        ; fit_width count count_width
        ; column_gap
        ; Ansi.dim ^ fit_width idle idle_width ^ Ansi.reset
        ; due_cell
        ])
    goals
    (List.combine counts (List.combine idles dues))

let title = Ansi.bold ^ "GOALS" ^ Ansi.reset

let take rows items = List.filteri (fun index _ -> index < rows) items

let lines ~now ~inner_width ~rows ~tasks (reading : Types.overview_goals_reading)
    =
  let rows = max 0 rows in
  let all =
    match reading with
    | Types.Goals_unread ->
        [ Printf.sprintf "%s   %sgoals not read yet%s" title Ansi.dim Ansi.reset ]
    | Types.Goals_failed reason ->
        [ Printf.sprintf "%s   %sgoals unavailable: %s%s" title (Theme.warn ())
            (Terminal_text.single_line reason) Ansi.reset ]
    | Types.Goals_read goals ->
        let drawn = drawn_goals goals in
        let goal_count = List.length drawn in
        let shown = min goal_count (max 0 (rows - 1)) in
        let cut =
          if shown < goal_count then
            Printf.sprintf "  %s\xc2\xb7 %d of %d goals shown%s" Ansi.dim shown
              goal_count Ansi.reset
          else ""
        in
        (* The backlog is read apart from the goals; a failed read is said,
           not counted as no active task. *)
        let headline =
          match tasks with
          | Ok tasks ->
              let { active; toward_goal } = progress ~goals:drawn ~tasks in
              Printf.sprintf "%s   active work toward a goal: %d of %d tasks%s"
                title toward_goal active cut
          | Error reason ->
              Printf.sprintf "%s   %sactive work unread: %s%s%s" title
                (Theme.warn ()) (Terminal_text.single_line reason) Ansi.reset cut
        in
        let body =
          match drawn with
          | [] ->
              [ Printf.sprintf "  %sno goal is executing, verifying or awaiting \
                                confirmation%s"
                  Ansi.dim Ansi.reset ]
          | _ :: _ -> goal_rows ~now ~inner_width drawn
        in
        headline :: body
  in
  take rows all

let draw buf ~cols ~rows ~now ~tasks reading =
  if rows > 0 then begin
    let inner_width = framed_inner_width cols in
    let drawn = lines ~now ~inner_width ~rows ~tasks reading in
    List.iter (box_line buf cols) drawn;
    (* [rows] is what the budget spent; a short list still fills it so the
       frame below starts where the budget says. *)
    for _ = List.length drawn to rows - 1 do
      box_line buf cols ""
    done;
    box_divider buf cols
  end
