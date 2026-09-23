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
  | More_active of int
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

let lines ~height ~cursor tasks backlog =
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
    (* One line says how many rows were left out. It and the backlog line
       are drawn only while at least one task row is still drawn beside
       them; a single row is spent on a task. *)
    let count_line = 1 in
    let trailer =
      if height - trailer_count - count_line >= 1 then trailer else []
    in
    let count_lines = if height - count_line >= 1 then count_line else 0 in
    let visible = height - List.length trailer - count_lines in
    let first =
      min (max 0 (cursor - visible + 1)) (max 0 (held_count - visible))
    in
    let window = row_lines ~first ~count:visible in
    if count_lines = 0 then window
    else window @ (More_active (held_count - visible) :: trailer)

let age_text ~age_text ~now since =
  match since with
  | None -> "?"
  | Some at -> age_text (int_of_float (Float.max 0. (now -. at)))

let summary_text ~age_text:format ~now line =
  match line with
  | Task_row _ -> None
  | More_active count -> Some (Printf.sprintf "+%d more active" count)
  | Nothing_active -> Some "no task in progress"
  | Todo_backlog { todo_count; oldest_created_at } ->
      Some
        (Printf.sprintf "%d todo · oldest %s" todo_count
           (age_text ~age_text:format ~now oldest_created_at))
