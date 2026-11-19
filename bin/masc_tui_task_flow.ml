type counts = {
  todo : int;
  claimed : int;
  in_progress : int;
  awaiting_verification : int;
  completed : int;
  cancelled : int;
}

type window = { created : int; completed : int; cancelled : int }

type assignee_flow = {
  af_assignee : string;
  af_done : int;
  af_open : int;
  af_median_lead_hours : float option;
}

type day = {
  d_start : float;
  d_created : int;
  d_completed : int;
  d_cancelled : int;
}

let seconds_per_day = 86400.
let daily_days = 14

type t = {
  observed_at : float;
  window_started_at : float;
  current : counts;
  recent : window;
  oldest_open_created_at : float option;
  unparseable_timestamps : int;
  by_assignee : assignee_flow list;
  daily : day list;
}

let open_count c = c.todo + c.claimed + c.in_progress + c.awaiting_verification
let total_count (c : counts) = open_count c + c.completed + c.cancelled

(* Accumulated per assignee while folding, before the lead-time samples
   collapse into one median. *)
type raw_assignee = { ra_done : int; ra_open : int; ra_lead_hours : float list }

type raw_day = { rd_created : int; rd_completed : int; rd_cancelled : int }

let no_assignee = { ra_done = 0; ra_open = 0; ra_lead_hours = [] }
let quiet_day = { rd_created = 0; rd_completed = 0; rd_cancelled = 0 }

(* Even sample counts average the two middle values rather than picking one
   side, so one added task cannot move the reported median by a whole sample. *)
let median = function
  | [] -> None
  | values ->
    let sorted = Array.of_list values in
    Array.sort Float.compare sorted;
    let n = Array.length sorted in
    if n mod 2 = 1 then Some sorted.(n / 2)
    else Some ((sorted.((n / 2) - 1) +. sorted.(n / 2)) /. 2.)

let day_index at = int_of_float (floor (at /. seconds_per_day))

let bump key empty table f =
  let current = Option.value ~default:empty (List.assoc_opt key table) in
  (key, f current) :: List.remove_assoc key table

let finalize_assignees assignees =
  List.map
    (fun (name, raw) ->
      { af_assignee = name;
        af_done = raw.ra_done;
        af_open = raw.ra_open;
        af_median_lead_hours = median raw.ra_lead_hours })
    assignees
  |> List.sort (fun a b ->
       match compare b.af_done a.af_done with
       | 0 -> (
         match compare b.af_open a.af_open with
         | 0 -> String.compare a.af_assignee b.af_assignee
         | order -> order)
       | order -> order)

(* Every day in the span is emitted, so a day nothing happened on is a row of
   zeroes instead of an absent row the reader would have to notice is missing. *)
let finalize_days ~today_index days =
  List.init daily_days (fun offset ->
    let index = today_index - (daily_days - 1) + offset in
    let raw = Option.value ~default:quiet_day (List.assoc_opt index days) in
    { d_start = float_of_int index *. seconds_per_day;
      d_created = raw.rd_created;
      d_completed = raw.rd_completed;
      d_cancelled = raw.rd_cancelled })

module StringSet = Set.Make (String)

(* A task's time as the windows read it: parsed once, or counted as one the
   windows cannot place. *)
type instant =
  | At of float
  | Unparseable

let instant_of_text text =
  match Masc_domain.parse_iso8601_opt text with
  | Some at when Float.is_finite at -> At at
  | Some _ | None -> Unparseable

type ending =
  | Open
  | Completed_at of instant
  | Cancelled_at of instant

let ending_of_status : Masc_domain.task_status -> ending = function
  | Todo | Claimed _ | InProgress _ | AwaitingVerification _ -> Open
  | Done { completed_at; _ } -> Completed_at (instant_of_text completed_at)
  | Cancelled { cancelled_at; _ } -> Cancelled_at (instant_of_text cancelled_at)

module Archived = struct
  type entry = { id : string; created : instant; ending : ending }

  type t = entry list

  let empty = []

  let add archived (task : Masc_domain.task) =
    { id = task.id;
      created = instant_of_text task.created_at;
      ending = ending_of_status task.task_status }
    :: archived
end

let of_tasks ~now ~archived tasks =
  let window_started_at = now -. (24. *. 60. *. 60.) in
  let empty =
    { observed_at = now; window_started_at;
      current = { todo = 0; claimed = 0; in_progress = 0;
                  awaiting_verification = 0; completed = 0; cancelled = 0 };
      recent = { created = 0; completed = 0; cancelled = 0 };
      oldest_open_created_at = None; unparseable_timestamps = 0;
      by_assignee = []; daily = [] }
  in
  let recent = function
    | Some at -> at >= window_started_at && at <= now
    | None -> false
  in
  let place state = function
    | At at -> state, Some at
    | Unparseable ->
      { state with unparseable_timestamps = state.unparseable_timestamps + 1 }, None
  in
  let today_index = day_index now in
  let oldest_index = today_index - (daily_days - 1) in
  let bump_day days at f =
    let index = day_index at in
    if index < oldest_index || index > today_index then days
    else bump index quiet_day days f
  in
  (* What a task's two times add to the windows, live or archived alike:
     the 24 hour counts, the day bars, the times that cannot be placed and
     the oldest open registration. *)
  let count_times (state, days) ~created ~ending =
    let state, created_at = place state created in
    let state =
      if recent created_at then
        { state with recent = { state.recent with created = state.recent.created + 1 } }
      else state
    in
    let days =
      match created_at with
      | Some at -> bump_day days at (fun d -> { d with rd_created = d.rd_created + 1 })
      | None -> days
    in
    let terminal =
      match ending with
      | Open -> None
      | Completed_at at -> Some (`Completed, at)
      | Cancelled_at at -> Some (`Cancelled, at)
    in
    let state, terminal_at =
      match terminal with
      | Some (_, at) -> place state at
      | None -> state, None
    in
    let days =
      match terminal, terminal_at with
      | Some (kind, _), Some at ->
        bump_day days at (fun d ->
          match kind with
          | `Completed -> { d with rd_completed = d.rd_completed + 1 }
          | `Cancelled -> { d with rd_cancelled = d.rd_cancelled + 1 })
      | Some _, None | None, _ -> days
    in
    let state =
      match terminal, terminal_at with
      | Some (kind, _), at when recent at ->
        let counts =
          match kind with
          | `Completed -> { state.recent with completed = state.recent.completed + 1 }
          | `Cancelled -> { state.recent with cancelled = state.recent.cancelled + 1 }
        in
        { state with recent = counts }
      | Some _, _ | None, _ -> state
    in
    let state =
      match terminal with
      | Some _ -> state
      | None ->
        let oldest =
          match state.oldest_open_created_at, created_at with
          | oldest, Some at when at <= now ->
            Some (Option.fold ~none:at ~some:(Float.min at) oldest)
          | oldest, _ -> oldest
        in
        { state with oldest_open_created_at = oldest }
    in
    (state, days), created_at, terminal_at
  in
  (* The current counts and the assignee rows are the backlog's: they
     describe what is on the board now. *)
  let (state, days), assignees =
    List.fold_left
      (fun (counted, assignees) (task : Masc_domain.task) ->
        let (state, days), created_at, terminal_at =
          count_times counted ~created:(instant_of_text task.created_at)
            ~ending:(ending_of_status task.task_status)
        in
        let current, who =
          match task.task_status with
          | Masc_domain.Todo -> { state.current with todo = state.current.todo + 1 }, None
          | Claimed { assignee; _ } ->
            { state.current with claimed = state.current.claimed + 1 }, Some (`Open, assignee)
          | InProgress { assignee; _ } ->
            { state.current with in_progress = state.current.in_progress + 1 },
            Some (`Open, assignee)
          | AwaitingVerification { assignee; _ } ->
            { state.current with awaiting_verification = state.current.awaiting_verification + 1 },
            Some (`Open, assignee)
          | Done { assignee; _ } ->
            { state.current with completed = state.current.completed + 1 }, Some (`Done, assignee)
          (* [Cancelled] carries [cancelled_by], which answers who cancelled
             rather than who held the task, so no assignee row grows here. *)
          | Cancelled _ ->
            { state.current with cancelled = state.current.cancelled + 1 }, None
        in
        let assignees =
          match who with
          | None -> assignees
          | Some (`Open, name) ->
            bump name no_assignee assignees (fun r -> { r with ra_open = r.ra_open + 1 })
          | Some (`Done, name) ->
            bump name no_assignee assignees (fun r ->
              let ra_done = r.ra_done + 1 in
              match created_at, terminal_at with
              | Some created, Some completed ->
                { r with ra_done;
                  ra_lead_hours = ((completed -. created) /. 3600.) :: r.ra_lead_hours }
              | (None, _) | (_, None) -> { r with ra_done })
        in
        ({ state with current }, days), assignees)
      ((empty, []), []) tasks
  in
  (* [masc_gc] moves finished tasks out of the backlog into the archive. They
     still happened on the days they happened, so the windows count them. A
     task the GC put back into the backlog but left in the archive is counted
     once, as live. *)
  let live_ids =
    List.fold_left
      (fun ids (task : Masc_domain.task) -> StringSet.add task.id ids)
      StringSet.empty tasks
  in
  let state, days =
    List.fold_left
      (fun counted (entry : Archived.entry) ->
        if StringSet.mem entry.Archived.id live_ids then counted
        else
          let counted, _, _ =
            count_times counted ~created:entry.Archived.created ~ending:entry.Archived.ending
          in
          counted)
      (state, days) archived
  in
  { state with
    by_assignee = finalize_assignees assignees;
    daily = finalize_days ~today_index days }
