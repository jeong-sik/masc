module Tui_decode = Masc.Tui_decode

(* Drawing order of the held statuses. [None] for a status that gets no row.
   The match names every status so a new one has to be placed here. *)
let group (status : Masc_domain.task_status) =
  match status with
  | Masc_domain.InProgress _ -> Some 0
  | Masc_domain.AwaitingVerification _ -> Some 1
  | Masc_domain.Claimed _ -> Some 2
  | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> None

let held_since (task : Tui_decode.task) =
  match task.status with
  | Masc_domain.InProgress { started_at; _ } ->
      Masc_domain.parse_iso8601_opt started_at
  | Masc_domain.AwaitingVerification { submitted_at; _ } ->
      Masc_domain.parse_iso8601_opt submitted_at
  | Masc_domain.Claimed { claimed_at; _ } ->
      Masc_domain.parse_iso8601_opt claimed_at
  | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> None

(* Earlier first; an instant that did not parse after every one that did. *)
let compare_since left right =
  match left, right with
  | Some l, Some r -> Float.compare l r
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0

let rows tasks =
  tasks
  |> List.filter_map (fun (task : Tui_decode.task) ->
         Option.map (fun rank -> (rank, held_since task, task)) (group task.status))
  |> List.stable_sort (fun (rank_l, since_l, _) (rank_r, since_r, _) ->
         match Int.compare rank_l rank_r with
         | 0 -> compare_since since_l since_r
         | order -> order)
  |> List.map (fun (_, _, task) -> task)

type backlog = { todo_count : int; oldest_created_at : float option }

let backlog (tasks : Masc_domain.task list) =
  List.fold_left
    (fun acc (task : Masc_domain.task) ->
      match task.task_status with
      | Masc_domain.Todo ->
          let oldest_created_at =
            match
              acc.oldest_created_at,
              Masc_domain.parse_iso8601_opt task.created_at
            with
            | Some held, Some created -> Some (Float.min held created)
            | None, created -> created
            | held, None -> held
          in
          { todo_count = acc.todo_count + 1; oldest_created_at }
      | Masc_domain.Claimed _ | Masc_domain.InProgress _
      | Masc_domain.AwaitingVerification _ | Masc_domain.Done _
      | Masc_domain.Cancelled _ ->
          acc)
    { todo_count = 0; oldest_created_at = None }
    tasks

type line =
  | Task_row of { index : int; task : Tui_decode.task }
  | Nothing_active
  | Todo_backlog of backlog

let backlog_lines backlog =
  if backlog.todo_count > 0 then [ Todo_backlog backlog ] else []

let line_count tasks backlog =
  match tasks with
  | [] -> 0
  | _ :: _ ->
      let held = List.length (rows tasks) in
      max held 1 + List.length (backlog_lines backlog)

let take count items = List.filteri (fun index _ -> index < count) items

let lines ~height ~selected tasks backlog =
  let height = max 0 height in
  let held = rows tasks in
  let held_count = List.length held in
  let trailer = backlog_lines backlog in
  let trailer_count = List.length trailer in
  let row_lines ~first ~count =
    List.filteri
      (fun index _ -> index >= first && index < first + count)
      (List.mapi (fun index task -> Task_row { index; task }) held)
  in
  if held_count = 0 then
    (* The title already reads zero held, so the backlog line is the one
       kept when only one of the two fits. *)
    if height >= 1 + trailer_count then Nothing_active :: trailer
    else take height trailer
  else if held_count + trailer_count <= height then
    row_lines ~first:0 ~count:held_count @ trailer
  else if held_count <= height then row_lines ~first:0 ~count:held_count
  else
    (* How many rows were left out is said in the title, which is drawn
       whatever the height. It used to be a line here, and a line costs a
       row: at the heights where the pane is squeezed to one, that row was
       spent on the count and then the count itself was dropped -- the pane
       drew one of twenty-three and said nothing. *)
    let trailer = if height - trailer_count >= 1 then trailer else [] in
    let visible = height - List.length trailer in
    let first =
      match selected with
      | None -> 0
      | Some index ->
          min (max 0 (index - visible + 1)) (max 0 (held_count - visible))
    in
    row_lines ~first ~count:visible @ trailer

(* How many held rows the pane could not draw at this height. The title says
   it, the way the Team title above says its own. *)
let held_back ~height ~selected tasks backlog =
  let drawn =
    List.length
      (List.filter
         (function Task_row _ -> true | Nothing_active | Todo_backlog _ -> false)
         (lines ~height ~selected tasks backlog))
  in
  max 0 (List.length (rows tasks) - drawn)

let row_of tasks ~task_id =
  let rec find index = function
    | [] -> None
    | (task : Tui_decode.task) :: rest ->
        if String.equal task.id task_id then Some index
        else find (index + 1) rest
  in
  find 0 (rows tasks)

let selected_index tasks ~selected =
  Option.bind selected (fun task_id -> row_of tasks ~task_id)

let id_at tasks index =
  Option.map
    (fun (task : Tui_decode.task) -> task.id)
    (List.nth_opt (rows tasks) index)

let selected_task tasks ~selected =
  Option.bind (selected_index tasks ~selected) (fun index ->
      List.nth_opt (rows tasks) index)

type step = Next | Previous

let step tasks ~selected direction =
  let last = List.length (rows tasks) - 1 in
  match selected_index tasks ~selected with
  | None -> id_at tasks 0
  | Some index ->
      let target =
        match direction with
        | Next -> min (index + 1) last
        | Previous -> max (index - 1) 0
      in
      id_at tasks target

type focus = No_task_focus | Task_focus of { selected : string option }

let selection = function
  | No_task_focus -> None
  | Task_focus { selected } -> selected

let is_focused = function No_task_focus -> false | Task_focus _ -> true

let focus_list tasks = Task_focus { selected = id_at tasks 0 }

let toggle tasks = function
  | No_task_focus -> focus_list tasks
  | Task_focus _ -> No_task_focus

let land_on tasks ~task_id =
  match row_of tasks ~task_id with
  | Some _ -> Task_focus { selected = Some task_id }
  | None -> No_task_focus

let move tasks focus direction =
  match focus with
  | No_task_focus -> No_task_focus
  | Task_focus { selected } ->
      Task_focus { selected = step tasks ~selected direction }

let reconcile tasks focus =
  match focus with
  | No_task_focus | Task_focus { selected = None } -> (focus, None)
  | Task_focus { selected = Some task_id } -> (
      match row_of tasks ~task_id with
      | Some _ -> (focus, None)
      | None -> (Task_focus { selected = None }, Some task_id))

type rows_reading =
  | Rows_unread
  | Rows_read of Tui_decode.task list
  | Rows_unavailable of string

let after_read reading focus =
  match reading with
  | Rows_unread | Rows_unavailable _ -> (focus, None)
  | Rows_read rows -> reconcile rows focus

type opening = Open of Tui_decode.task | No_held_task | No_selection

let opening tasks focus =
  match focus with
  | No_task_focus -> None
  | Task_focus { selected } -> (
      match selected_task tasks ~selected, rows tasks with
      | Some task, _ -> Some (Open task)
      | None, [] -> Some No_held_task
      | None, _ :: _ -> Some No_selection)

let age_text ~age_text ~now since =
  match since with
  | None -> Masc_tui_theme.Glyph.no_value
  | Some at -> age_text (int_of_float (Float.max 0. (now -. at)))

let summary_text ~age_text:format ~now line =
  match line with
  | Task_row _ -> None
  | Nothing_active -> Some "no task in progress"
  | Todo_backlog { todo_count; oldest_created_at } ->
      Some
        (Printf.sprintf "%d todo · oldest %s" todo_count
           (age_text ~age_text:format ~now oldest_created_at))
