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

type cost_tone = Cost_plain | Cost_muted | Cost_warn

type cost_words = { lead : string; details : string list; tone : cost_tone }

let cost_window_label minutes =
  if minutes mod 60 = 0 then Printf.sprintf "%dh" (minutes / 60)
  else Printf.sprintf "%dm" minutes

let cost_words (cost : Types.overview_cost_reading) =
  let plural count noun =
    Printf.sprintf "%d %s%s" count noun (if count = 1 then "" else "s")
  in
  match cost with
  | Types.Cost_unread ->
      { lead = "cost not read yet"; details = []; tone = Cost_muted }
  | Types.Cost_failed reason ->
      { lead = "cost unavailable"; details = [ reason ]; tone = Cost_warn }
  | Types.Cost_read { kcs_cache = Tui_decode.Keeper_costs_warming { last_error }; _ }
    ->
      (* Warming with an error is a server whose every read so far failed:
         a failure, not a read still to come. *)
      (match last_error with
       | Some reason ->
           { lead = "cost unavailable"; details = [ reason ]; tone = Cost_warn }
       | None -> { lead = "cost not read yet"; details = []; tone = Cost_muted })
  | Types.Cost_read
      ({ kcs_cache = Tui_decode.Keeper_costs_fresh | Tui_decode.Keeper_costs_stale _
       ; _
       } as costs) ->
      let fleet = Tui_decode.fleet_cost_of_keeper_costs costs in
      let window = cost_window_label costs.kcs_window_minutes in
      let shortfalls =
        List.filter_map
          (fun (count, text) -> if count > 0 then Some text else None)
          [ ( fleet.fc_unpriced_turns
            , plural fleet.fc_unpriced_turns "turn" ^ " unpriced" )
          ; ( fleet.fc_unreadable_rows
            , plural fleet.fc_unreadable_rows "row" ^ " unreadable" )
          ; ( fleet.fc_unread_keepers
            , plural fleet.fc_unread_keepers "keeper" ^ " unread" )
          ]
      in
      (* A stale reply whose refresh failed can be any age: the server keeps
         answering the last good sum. That goes in the lead, which a narrow
         title keeps, not in a detail it drops. *)
      let refresh_failed =
        match costs.kcs_cache with
        | Tui_decode.Keeper_costs_stale { last_error = Some _ } -> true
        | Tui_decode.Keeper_costs_stale { last_error = None }
        | Tui_decode.Keeper_costs_fresh | Tui_decode.Keeper_costs_warming _ ->
            false
      in
      let sum_lead, sum_tone =
        match fleet.fc_usd, shortfalls with
        | None, [] -> (Printf.sprintf "no turns in %s" window, Cost_muted)
        | None, _ :: _ -> (Printf.sprintf "cost unknown %s" window, Cost_plain)
        | Some usd, [] -> (Printf.sprintf "$%.2f %s" usd window, Cost_plain)
        | Some usd, _ :: _ ->
            (Printf.sprintf "at least $%.2f %s" usd window, Cost_plain)
      in
      let lead, tone =
        if refresh_failed then (sum_lead ^ " (refresh failing)", Cost_warn)
        else (sum_lead, sum_tone)
      in
      { lead; details = shortfalls; tone }
