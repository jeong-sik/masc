module World = Masc_tui_memory_world
module Wire = Masc.Tui_decode_workspace_memory
module Health = Masc.Tui_decode_memory_health
module Ladder = Masc_tui_keeper_age_ladder
module Model = Masc_tui_keeper_list_model
module Layout = Masc_tui_message_layout
module Terminal_text = Masc_tui_ansi.Terminal_text

type row_cells = { pulse : string; now_cell : string; strip : string; due : string; right : string }

let briefing_word = function
  | Wire.Pending -> "◷ pending"
  | Wire.Current -> "✓ current"
  | Wire.Stale -> "! stale"
  | Wire.Unavailable -> "? unavailable"

let now_word = function
  | World.Not_read -> "? not read"
  | World.Reading -> "? reading"
  | World.Read_failed _ -> "? read failed"
  | World.Loaded { world; refresh_failure } ->
      let word = match world with
        | Wire.Missing _ -> "— no ledger"
        | Wire.Available world -> briefing_word world.Wire.briefing.status in
      word ^ (match refresh_failure with None -> "" | Some _ -> " !")

let fleet_ladder snapshot =
  Ladder.fleet_of ~refused_rows:(List.length snapshot.Health.mhs_refused_keepers)
    snapshot.Health.mhs_keepers

let age_strip = function
  | None -> "?"
  | Some snapshot ->
      (match fleet_ladder snapshot with
       | Ladder.Nobody_measured _ -> "?"
       | Ladder.Measured { unmeasured_keepers = 0; bins } -> Ladder.strip bins
       | Ladder.Measured { unmeasured_keepers = _; bins = _ } -> "?")

let row_cells ~health_error ~view snapshot world =
  let age = match view with
    | Model.By_age -> true
    | Model.Plain | Model.By_state | Model.By_cause | Model.By_time
    | Model.By_memory | Model.By_runtime | Model.Day_wall -> false in
  { pulse = if age then age_strip snapshot else "ledger + briefing"
  ; now_cell = (match health_error with Some _ -> "mem! " | None -> "") ^ now_word world
  ; strip = "? absent"
  ; due = if age then (match snapshot with
      | Some snapshot -> let count = snapshot.Health.mhs_total_source_invalidations
          + snapshot.mhs_total_support_invalidations in
          if count = 0 then "" else "×" ^ Layout.compact_count count
      | None -> "?") else "?"
  ; right = if age then (match snapshot with
      | Some snapshot -> Layout.compact_count snapshot.Health.mhs_total_facts
      | None -> "?") else "?" }

let health_partial = function
  | None -> false
  | Some snapshot -> snapshot.Health.mhs_total_read_errors > 0
      || snapshot.mhs_total_source_read_errors > 0
      || snapshot.mhs_refused_keepers <> []

let memory_summary ~health_error snapshot =
  let qualifiers = (match health_error with
    | Some _ -> ["read failed; earlier totals"] | None -> [])
    @ (if health_partial snapshot then ["partial counts"] else []) in
  qualifiers @ (match snapshot with
    | None -> ["?"]
    | Some snapshot -> [Printf.sprintf "%s ordinary + %s source facts"
        (Layout.compact_count snapshot.Health.mhs_total_facts)
        (Layout.compact_count snapshot.mhs_total_source_facts)])

let world_failed = function
  | World.Read_failed _ | World.Loaded { refresh_failure = Some _; _ } -> true
  | World.Not_read | World.Reading | World.Loaded { refresh_failure = None; _ } -> false

let inventory_summary world =
  let qualifier = if world_failed world then ["read failed; earlier inventory"] else [] in
  qualifier @ (match world with
    | World.Not_read -> ["? not read"]
    | World.Reading -> ["? reading"]
    | World.Read_failed _ -> ["?"]
    | World.Loaded { world = Wire.Missing _; _ } -> ["no ledger"]
    | World.Loaded { world = Wire.Available world; _ } ->
        [Printf.sprintf "%s claims / %s conflicts"
          (Layout.compact_count world.Wire.claim_count) (Layout.compact_count world.conflict_count)])

let detail_lines ~health_error ~cells snapshot world =
  let health = match health_error with None -> [] | Some error ->
    ["memory read failed · " ^ Terminal_text.single_line error] in
  let inventory = if world_failed world then
    [String.concat " · " (World.clauses ~ko:false ~room:cells world)] else [] in
  let memory = match snapshot with
    | None -> []
    | Some snapshot ->
        [Printf.sprintf "Keeper rows %d / refused %d / ordinary read errors %d / source read errors %d"
          (List.length snapshot.Health.mhs_keepers) (List.length snapshot.mhs_refused_keepers)
          snapshot.mhs_total_read_errors snapshot.mhs_total_source_read_errors
        ; "ordinary facts by age · " ^ String.concat " · "
            (Ladder.fleet_clauses ~ko:false (fleet_ladder snapshot))] in
  let inventory_details = match world with
    | World.Not_read | World.Reading | World.Read_failed _
    | World.Loaded { world = Wire.Missing _; _ } -> []
    | World.Loaded { world = Wire.Available world; _ } ->
        [Printf.sprintf "ledger · %d excluded / %d classified"
          world.Wire.excluded_count world.classified_count]
        @ (match world.briefing.building with None -> [] | Some pass ->
            [Printf.sprintf "briefing building · %d of %d left" pass.Wire.remaining pass.target]) in
  health @ inventory @ memory @ inventory_details
    @ ["absent Keeper facts · ?"; "▹ Next · no time announced"]

let dock_lines ~health_error ~cells ~max_lines snapshot world =
  let stage tag clauses = Layout.join_fitting ~sep:" · " ~cells (tag :: clauses) in
  let memory = memory_summary ~health_error snapshot in
  let ledger = inventory_summary world in
  let briefing = now_word world in
  let core = [stage "◂ Keepers" memory; stage "↓ Ledger" ledger; stage "● Briefing" [briefing]] in
  if max_lines <= 0 then []
  else if max_lines >= List.length core then
    let details = detail_lines ~health_error ~cells snapshot world
      |> List.concat_map (Layout.wrap_words ~max_cells:(max 1 cells)) in
    core @ List.take (max_lines - List.length core) details
  else
    let combined = "Keepers " ^ String.concat ", " memory ^ " → Ledger "
      ^ String.concat ", " ledger ^ " → " ^ briefing in
    let wrapped = Layout.wrap_words ~max_cells:(max 1 cells) combined in
    if List.length wrapped <= max_lines then wrapped
    else [stage (match health_error with Some _ -> "memory read failed"
       | None -> if world_failed world then "world read failed" else "world") ["partial view"]]
