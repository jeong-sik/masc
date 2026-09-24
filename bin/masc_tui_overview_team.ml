module Types = Masc_tui_types
module Tui_decode = Masc.Tui_decode

type group = Needs_you | Working | Idle | No_phase | Paused | Stopped

type detail =
  | Blocker of { summary : string; item : Types.attention_item; held : int }
  | Phase_word of { word : string; held : int }
  | Working_on of { task : Tui_decode.task; more : int; awaiting : int }
  | No_open_task of { awaiting : int }

type row = { keeper : Types.overview_keeper; group : group; detail : detail }

type t = {
  rows : row list;
  no_phase : (string * int) list;
  paused : (string * int) list;
  stopped : (string * int) list;
  other_holders : (string * int) list;
}

(* Held work splits into what the holder is doing and what waits on someone
   else's verdict; the two answer different questions on the row. *)
type holding = { working : Tui_decode.task list; awaiting : int }

let holding_of ~tasks name =
  List.fold_right
    (fun (task : Tui_decode.task) acc ->
      match task.status with
      | Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ }
        when String.equal assignee name ->
          { acc with working = task :: acc.working }
      | Masc_domain.AwaitingVerification { assignee; _ }
        when String.equal assignee name ->
          { acc with awaiting = acc.awaiting + 1 }
      | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
      | Masc_domain.AwaitingVerification _ | Masc_domain.Done _
      | Masc_domain.Cancelled _ ->
          acc)
    tasks
    { working = []; awaiting = 0 }

let held holding = List.length holding.working + holding.awaiting

(* An info item names a Keeper without saying it is stuck (the connector's
   "<name> has N external messages waiting" is one); it neither moves the row
   to Needs_you nor stands in for the cause. *)
let asks_for_the_operator (item : Types.attention_item) =
  match item.ai_severity with
  | Types.Attention_critical | Types.Attention_bad | Types.Attention_warning ->
      true
  | Types.Attention_info -> false

let first_blocker ~attention name =
  List.find_map
    (fun (item : Types.attention_item) ->
      match item.ai_target with
      | Types.Attention_keeper target
        when String.equal target name && asks_for_the_operator item ->
          Some item
      | Types.Attention_keeper _ | Types.Attention_other _ -> None)
    attention

let blocker ~holding (item : Types.attention_item) =
  Blocker
    { summary = Option.value ~default:item.ai_summary item.ai_blocker_summary
    ; item
    ; held = held holding
    }

let stuck ~attention ~holding ~word name =
  match first_blocker ~attention name with
  | Some item -> blocker ~holding item
  | None -> Phase_word { word; held = held holding }

let alive holding =
  match holding.working with
  | task :: rest ->
      ( Working,
        Working_on { task; more = List.length rest; awaiting = holding.awaiting }
      )
  | [] -> (Idle, No_open_task { awaiting = holding.awaiting })

(* Where a Keeper is drawn: on a row of its own, or by name on the no-phase,
   the paused or the stopped line. *)
type placement =
  | On_row of group * detail
  | No_phase_name
  | Paused_name
  | Stopped_name

let classify ~attention ~holding (keeper : Types.overview_keeper) =
  let name = keeper.okp_name in
  match (keeper.okp_paused, keeper.okp_phase) with
  | Some true, _ ->
      (* The operator paused it. The status bridge still raises a "paused"
         item for it, and after a server restart autoboot skips it so the
         phase is null; neither is a stop the operator has not seen. *)
      Paused_name
  | (Some false | None), Types.Keeper_phase phase -> (
      let word = Tui_decode.keeper_phase_to_string phase in
      match Tui_decode.keeper_phase_band phase with
      | Tui_decode.Phase_stuck ->
          On_row (Needs_you, stuck ~attention ~holding ~word name)
      | Tui_decode.Phase_alive ->
          let group, detail = alive holding in
          On_row (group, detail)
      | Tui_decode.Phase_paused -> Paused_name
      | Tui_decode.Phase_stopped -> Stopped_name)
  | (Some false | None), Types.Keeper_phase_unreadable word ->
      On_row (Needs_you, stuck ~attention ~holding ~word name)
  | (Some false | None), Types.Keeper_phase_absent -> (
      (* No registry entry and not paused. With an item asking for the
         operator the row follows it; without one, the briefing has said
         nothing about where the Keeper is, and that is not a stop. *)
      match first_blocker ~attention name with
      | Some item -> On_row (Needs_you, blocker ~holding item)
      | None -> No_phase_name)

let band = function
  | Needs_you -> 0
  | Working -> 1
  | Idle -> 2
  | No_phase -> 3
  | Paused -> 4
  | Stopped -> 5

let by_name names = List.sort (fun (left, _) (right, _) -> String.compare left right) names

let project ~keepers ~tasks ~attention =
  let rows, no_phase, paused, stopped =
    List.fold_left
      (fun (rows, no_phase, paused, stopped) (keeper : Types.overview_keeper) ->
        let holding = holding_of ~tasks keeper.okp_name in
        let entry = (keeper.okp_name, held holding) in
        match classify ~attention ~holding keeper with
        | On_row (group, detail) ->
            ({ keeper; group; detail } :: rows, no_phase, paused, stopped)
        | No_phase_name -> (rows, entry :: no_phase, paused, stopped)
        | Paused_name -> (rows, no_phase, entry :: paused, stopped)
        | Stopped_name -> (rows, no_phase, paused, entry :: stopped))
      ([], [], [], []) keepers
  in
  let rows =
    List.stable_sort
      (fun left right ->
        let by_band = Int.compare (band left.group) (band right.group) in
        if by_band <> 0 then by_band
        else String.compare left.keeper.okp_name right.keeper.okp_name)
      rows
  in
  let keeper_names =
    List.map (fun (keeper : Types.overview_keeper) -> keeper.okp_name) keepers
  in
  let other_holders =
    List.fold_left
      (fun acc (task : Tui_decode.task) ->
        match Masc_domain.task_assignee_of_status task.status with
        | Some assignee when not (List.mem assignee keeper_names) ->
            let count = Option.value ~default:0 (List.assoc_opt assignee acc) in
            (assignee, count + 1) :: List.remove_assoc assignee acc
        | Some _ | None -> acc)
      [] tasks
    |> List.stable_sort (fun (left_name, left) (right_name, right) ->
           let by_count = Int.compare right left in
           if by_count <> 0 then by_count else String.compare left_name right_name)
  in
  { rows
  ; no_phase = by_name no_phase
  ; paused = by_name paused
  ; stopped = by_name stopped
  ; other_holders
  }

let line_if_any = function [] -> 0 | _ :: _ -> 1

let drawn_rows t =
  List.length t.rows + line_if_any t.no_phase + line_if_any t.paused
  + line_if_any t.stopped + line_if_any t.other_holders

let count t group =
  match group with
  | No_phase -> List.length t.no_phase
  | Paused -> List.length t.paused
  | Stopped -> List.length t.stopped
  | Needs_you | Working | Idle ->
      List.length (List.filter (fun row -> row.group = group) t.rows)

let drawn_items t ~rows =
  List.filter (fun row -> row.group = Needs_you) t.rows
  |> List.filteri (fun index _ -> index < rows)
  |> List.filter_map (fun row ->
         match row.detail with
         | Blocker { item; _ } -> Some item
         | Phase_word _ | Working_on _ | No_open_task _ -> None)

(* Removes the one instance each drawn row carries, by identity: a second
   item naming the same Keeper is a different item even when its words are
   the same, and it has no other place on screen. *)
let rec without_instance item = function
  | [] -> []
  | head :: rest when head == item -> rest
  | head :: rest -> head :: without_instance item rest

let settle t ~attention ~allocate ~team_rows =
  (* Fewer panel items never shrink the Team block (the panel is sized
     before the block and only by its item count), so starting from the
     budget that keeps every item and handing the drawn rows' items over
     only ever grows the rows drawn: each step's items are still drawn after
     the next allocation, and the rows stop growing within [drawn_rows t]
     steps. *)
  let rec go rows =
    let panel =
      List.fold_left
        (fun remaining item -> without_instance item remaining)
        attention (drawn_items t ~rows)
    in
    let budget = allocate panel in
    let drawn = team_rows budget in
    if drawn <= rows then (panel, budget) else go drawn
  in
  go (team_rows (allocate attention))

let phase_word (keeper : Types.overview_keeper) =
  match keeper.okp_phase with
  | Types.Keeper_phase phase -> Tui_decode.keeper_phase_to_string phase
  | Types.Keeper_phase_unreadable word -> word
  | Types.Keeper_phase_absent -> "no phase"

type shut_window = {
  sw_scope : string option;
  sw_runtimes : int;
  sw_resets_at : float option;
}

let later left right =
  match (left, right) with
  | Some l, Some r -> Some (Float.max l r)
  | Some at, None | None, Some at -> Some at
  | None, None -> None

let shut_windows (options : Tui_decode.runtime_option list) =
  List.fold_left
    (fun windows (option : Tui_decode.runtime_option) ->
      if not option.ro_quota_exhausted then windows
      else
        let scope = option.ro_quota_scope in
        match
          List.partition
            (fun window -> Option.equal String.equal window.sw_scope scope)
            windows
        with
        | [ window ], rest ->
            { window with
              sw_runtimes = window.sw_runtimes + 1
            ; sw_resets_at = later window.sw_resets_at option.ro_quota_resets_at
            }
            :: rest
        | _, _ ->
            { sw_scope = scope; sw_runtimes = 1; sw_resets_at = option.ro_quota_resets_at }
            :: windows)
    [] options
  |> List.stable_sort (fun left right ->
         match (left.sw_resets_at, right.sw_resets_at) with
         | Some l, Some r when not (Float.equal l r) -> Float.compare l r
         | Some _, None -> -1
         | None, Some _ -> 1
         | Some _, Some _ | None, None ->
             Option.compare String.compare left.sw_scope right.sw_scope)
