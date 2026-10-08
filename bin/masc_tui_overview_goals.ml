(* The Overview's GOALS section: is the fleet's work moving any goal? *)

module Tui_decode = Masc.Tui_decode
module Types = Masc_tui_types
open Masc_tui_ansi

let drawn_phase : Goal_phase.t -> bool = function
  | Goal_phase.Executing | Goal_phase.Verifying
  | Goal_phase.Awaiting_confirmation | Goal_phase.Paused _ | Goal_phase.Blocked _ ->
      true
  | Goal_phase.Completed | Goal_phase.Dropped -> false

(* A goal sorts by the moment it falls due ({!Goal_due}). A value that is not a
   due date sorts with the goals that have none. *)
let due_order (goal : Tui_decode.overview_goal) =
  Goal_due.instant (Goal_due.read goal.og_due_date)

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

(* The countdown counts UTC days to the due date and reads the due date the
   way the server does ({!Goal_due}): it falls due at 23:59:59 UTC, whatever
   the operator's time zone is. The value is read as it arrived and only the
   text drawn is cleaned for the terminal, so a value the server cannot read
   never gets a countdown here. A value that is not a due date is drawn as
   written, without a countdown. *)
let due_text ~now (goal : Tui_decode.overview_goal) =
  match goal.og_due_date with
  | None -> None
  | Some raw -> (
      let shown = Terminal_text.single_line raw in
      let due = Goal_due.read (Some raw) in
      match (due, now) with
      | Goal_due.Due_date { date = (y, m, d); _ }, Some now -> (
          match Goal_due.days_left ~now due with
          | None -> Some ("due " ^ shown)
          | Some days ->
              let now_year, _, _ = Ptime.to_date now in
              let date =
                if y = now_year then Printf.sprintf "%02d-%02d" m d
                else Printf.sprintf "%04d-%02d-%02d" y m d
              in
              let countdown =
                if days >= 0 then Printf.sprintf "D-%d" days
                else Printf.sprintf "D+%d" (-days)
              in
              Some (Printf.sprintf "due %s (%s)" date countdown))
      | ( ( Goal_due.No_due_date | Goal_due.Unreadable_due_date _
          | Goal_due.Due_date _ ),
          _ ) ->
          Some ("due " ^ shown))

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
let is_overdue ~now (goal : Tui_decode.overview_goal) =
  match (goal.og_phase, goal.og_due_date, now) with
  | (Goal_phase.Executing | Goal_phase.Verifying), Some raw, Some now ->
      Goal_due.is_overdue ~now (Goal_due.read (Some raw))
  | _ -> false

let overdue_text ~now (goal : Tui_decode.overview_goal) =
  if is_overdue ~now goal then Some (Theme.warn () ^ "overdue" ^ Ansi.reset)
  else None

(* A row is a scan target, not a Goal progress meter. Task counts name
   linked task work only; the Goal metric lives in Planning. *)
let goal_rows ~now ~inner_width goals =
  let now = Ptime.of_float_s now in
  List.map
    (fun (goal : Tui_decode.overview_goal) ->
      let phase =
        match goal.og_phase with
        | Goal_phase.Executing -> []
        | Goal_phase.Verifying -> [ "verify" ]
        | Goal_phase.Paused _ -> [ "paused" ]
        | Goal_phase.Blocked _ -> [ "blocked" ]
        | Goal_phase.Awaiting_confirmation -> [ "confirm" ]
        | Goal_phase.Completed | Goal_phase.Dropped -> []
      in
      let attention =
        List.filter_map Fun.id
          [ refuted_text goal; overdue_text ~now goal ]
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
           @ Option.to_list (due_text ~now goal))
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

let lines ~now ~inner_width ~rows ~tasks (reading : Types.overview_goals_reading)
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
        let goal_lines = goal_rows ~now ~inner_width drawn in
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
    box_empty buf cols
  end
