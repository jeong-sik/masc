(** Fusion selections and reading projections. *)

open Masc_tui_types

let fusion_snapshot_entries (snapshot : Masc.Tui_decode_fusion.fusion_snapshot) =
  List.map (fun run -> Masc.Tui_decode_fusion.Fusion_retained_run run) snapshot.fus_runs
  @ List.map (fun evidence -> Masc.Tui_decode_fusion.Fusion_historical_evidence evidence)
      snapshot.fus_historical_evidence

let fusion_runs_view (state : state) =
  Masc_tui_fetched.view_for ~equal:Unit.equal state.fusion_runs ~key:()

(* The retained runs on screen: the last answer, also when the refresh after
   it failed -- that failure is drawn beside them, not instead of them. *)
let fusion_snapshot (state : state) =
  match fusion_runs_view state with
  | Masc_tui_fetched.Ready snapshot | Masc_tui_fetched.Stale (snapshot, _) -> Some snapshot
  | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _ -> None

let fusion_list_entries (state : state) =
  match fusion_snapshot state with
  | None -> []
  | Some snapshot -> fusion_snapshot_entries snapshot

let fusion_entry_identity = function
  | Masc.Tui_decode_fusion.Fusion_retained_run run -> "run:" ^ run.fur_run_id
  | Masc.Tui_decode_fusion.Fusion_historical_evidence evidence -> "board:" ^ evidence.fhe_post_id

let selected_fusion_entry state =
  List.nth_opt (fusion_list_entries state) state.fusion_cursor

let fusion_detail_entry_index state =
  fusion_list_entries state
  |> List.find_index (fun entry ->
      match state.fusion_mode, entry with
      | Fusion_detail id, Masc.Tui_decode_fusion.Fusion_retained_run run ->
          String.equal id run.fur_run_id
      | Fusion_historical_detail reference, Masc.Tui_decode_fusion.Fusion_historical_evidence candidate ->
          String.equal reference.fhe_post_id candidate.fhe_post_id
          && String.equal reference.fhe_run_id candidate.fhe_run_id
      | _ -> false)

let selected_keeper_runs (state : state) =
  match selected_keeper state, fusion_snapshot state with
  | Some keeper, Some snapshot ->
      List.filter (fun (run : Masc.Tui_decode_fusion.fusion_run) ->
          String.equal run.fur_keeper keeper.k_name) snapshot.fus_runs
  | _ -> []

let selected_keeper_run (state : state) =
  let runs = selected_keeper_runs state in
  let cursor = max 0 (min state.keeper_run_cursor (List.length runs - 1)) in
  Option.map (fun run -> cursor, run) (List.nth_opt runs cursor)

(* What the Keeper Runs tab knows about the retained runs: the Fusion list's
   own reading, narrowed to the selected Keeper. *)
let keeper_runs_view (state : state) =
  match fusion_runs_view state with
  | Masc_tui_fetched.Ready _ -> Masc_tui_fetched.Ready (selected_keeper_runs state)
  | Masc_tui_fetched.Stale (_, detail) -> Masc_tui_fetched.Stale (selected_keeper_runs state, detail)
  | Masc_tui_fetched.Absent -> Masc_tui_fetched.Absent
  | Masc_tui_fetched.Loading -> Masc_tui_fetched.Loading
  | Masc_tui_fetched.Failed detail -> Masc_tui_fetched.Failed detail
