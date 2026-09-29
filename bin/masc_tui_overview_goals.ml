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

let task_count_text (goal : Tui_decode.overview_goal) =
  if goal.og_task_count <= 0 then "no tasks"
  else Printf.sprintf "%d/%d tasks" goal.og_task_done_count goal.og_task_count

(* [due_date] is a calendar date with no zone, so it is compared with the
   operator's own calendar date: the day [localtime] puts [now] on. *)
let local_today ~now ~localtime =
  let tm : Unix.tm = localtime now in
  Ptime.of_date (tm.Unix.tm_year + 1900, tm.Unix.tm_mon + 1, tm.Unix.tm_mday)

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

(* A Goal whose latest verdict was a rejection (#39571). The verification
   ledger's current completion state is [proof_refuted]; the phase alone cannot
   tell it apart from a Goal that is simply executing again. *)
let refuted_text (goal : Tui_decode.overview_goal) =
  match goal.og_completion with
  | Some "proof_refuted" -> Some (Theme.warn () ^ "refuted" ^ Ansi.reset)
  | _ -> None

(* A Goal past its [due_date] while still executing or verifying (#39571). A
   completed or dropped Goal is not drawn at all, so it can never read as
   overdue. *)
let is_overdue ~today (goal : Tui_decode.overview_goal) =
  match (goal.og_phase, goal.og_due_date) with
  | (Goal_phase.Executing | Goal_phase.Verifying), Some raw -> (
      match (parse_due_date (Terminal_text.single_line raw), today) with
      | Some due, Some today -> Ptime.compare due today < 0
      | _ -> false)
  | _ -> false

let overdue_text ~today (goal : Tui_decode.overview_goal) =
  if is_overdue ~today goal then Some (Theme.warn () ^ "overdue" ^ Ansi.reset)
  else None

(* A row is a scan target, not a Goal progress meter. Task counts name
   linked task work only; the Goal metric and ownership live in Planning. *)
let goal_rows ~now ~localtime ~inner_width goals =
  let today = local_today ~now ~localtime in
  List.map
    (fun (goal : Tui_decode.overview_goal) ->
      let phase =
        match goal.og_phase with
        | Goal_phase.Executing -> []
        | Goal_phase.Verifying -> [ "verify" ]
        | Goal_phase.Awaiting_confirmation -> [ "confirm" ]
        | Goal_phase.Completed | Goal_phase.Dropped -> []
      in
      let attention =
        List.filter_map Fun.id
          [ refuted_text goal; overdue_text ~today goal ]
      in
      (* Keep enough of the title to identify the Goal even when several
         attention flags compete for a narrow row. The suffix puts warnings
         first, so its less urgent task/due tail yields when space runs out. *)
      let title_floor = max 1 (inner_width / 3) in
      let suffix_budget = max 0 (inner_width - 4 - title_floor) in
      let separator = " · " in
      let separator_width = Masc_tui_message_layout.display_width separator in
      let rec select_suffix width selected = function
        | [] -> List.rev selected
        | clause :: rest ->
            let next_width =
              width + (if selected = [] then 0 else separator_width)
              + Masc_tui_message_layout.display_width clause
            in
            if next_width > suffix_budget then List.rev selected
            else select_suffix next_width (clause :: selected) rest
      in
      let suffix =
        select_suffix 0 []
          (attention @ phase @ [ task_count_text goal ]
           @ Option.to_list (due_text ~today goal))
        |> String.concat separator
      in
      let suffix_width = Masc_tui_message_layout.display_width suffix in
      let title_width = max 1 (inner_width - 4 - suffix_width) in
      "  " ^ fit_width (Terminal_text.single_line goal.og_title) title_width
      ^ "  " ^ suffix)
    goals

let wanted_rows (reading : Types.overview_goals_reading) =
  match reading with
  | Types.Goals_unread -> 1
  | Types.Goals_failed _ -> 1
  | Types.Goals_read goals ->
      let goals = drawn_goals goals in
      if goals = [] then 1
      else 1 + List.length goals

let title count =
  Ansi.bold
  ^ (match count with
    | None -> "Goals"
    | Some count -> Printf.sprintf "Goals (%d)" count)
  ^ Ansi.reset

let take rows items = List.filteri (fun index _ -> index < rows) items

let lines ~now ~localtime ~inner_width ~rows ~tasks (reading : Types.overview_goals_reading)
    =
  let rows = max 0 rows in
  let all =
    match reading with
    | Types.Goals_unread ->
        [ title None ^ "   " ^ Ansi.dim ^ "No goal data read yet." ^ Ansi.reset ]
    | Types.Goals_failed reason ->
        [ Theme.warn () ^ "Goals unavailable: "
          ^ Terminal_text.single_line reason ^ Ansi.reset
        ]
    | Types.Goals_read goals ->
        let drawn = drawn_goals goals in
        let goal_count = List.length drawn in
        let title = title (Some goal_count) in
        let goal_lines = goal_rows ~now ~localtime ~inner_width drawn in
        let shown_lines = take (max 0 (rows - 1)) goal_lines in
        let shown = List.length shown_lines in
        let cut =
          if shown < goal_count then
            Printf.sprintf "  %s\xc2\xb7 %d of %d goals shown%s" Ansi.dim shown
              goal_count Ansi.reset
          else ""
        in
        (* The backlog is read apart from the goals; a read not made yet or
           failed is said, not counted as no active task. *)
        let headline =
          match tasks with
          | Masc_tui_overview_tasks.Rows_unread ->
              Printf.sprintf "%s   %sactive work unread%s%s" title Ansi.dim
                Ansi.reset cut
          | Masc_tui_overview_tasks.Rows_read tasks ->
              let { active; toward_goal } = progress ~goals:drawn ~tasks in
              Printf.sprintf "%s   active tasks linked: %d/%d%s"
                title toward_goal active cut
          | Masc_tui_overview_tasks.Rows_unavailable reason ->
              Printf.sprintf "%s   %sactive work unread: %s%s%s" title
                (Theme.warn ()) (Terminal_text.single_line reason) Ansi.reset cut
        in
        if goal_count = 0 then
          [ title ^ "   No goal is executing or verifying." ]
        else headline :: shown_lines
  in
  take rows all

let draw buf ~cols ~rows ~now ~localtime ~tasks reading =
  if rows > 0 then begin
    let inner_width = framed_inner_width cols in
    let drawn = lines ~now ~localtime ~inner_width ~rows ~tasks reading in
    List.iter (box_line buf cols) drawn;
    (* [rows] is what the budget spent; a short list still fills it so the
       frame below starts where the budget says. *)
    for _ = List.length drawn to rows - 1 do
      box_line buf cols ""
    done;
    box_empty buf cols
  end
