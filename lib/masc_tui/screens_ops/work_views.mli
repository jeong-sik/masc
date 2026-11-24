(** The 5 sub-tabs of [[2] Work]:
    1. [render_pipeline]: Goals Master-Detail with closed-sum [Goal_phase] badge,
       measure ratio gauge, unlinked-task/unattributed-Candle callout, rich
       Markdown measure & procedure (OSC 8 links, zero raw [board:p-...]),
       Pipeline Stage Stepper, linked tasks, criterion review, and structured
       Rejection Diff.
    2. [render_tasks]: Filterable status pills and Task detail pane
       ([started_at], verification evidence, goal link status, [[x]] cancel,
       [[h]] harness overrule).
    3. [render_schedules]: Dedicated Schedules table with last wake disposition,
       output summary, detail inspector, and [[n]] new schedule — always
       reachable even when empty.
    4. [render_inbox]: Rapid-fire triage split (Held Tool Calls -> Keeper Asks
       -> Goal Confirmations) with Markdown preview,
       structured tool args via [Json_tree], instant [a..d] choices, and clean
       empty-state 24h Recent Decisions Audit + Approval/Sandbox Policy Summary.
    5. [render_candle_scorecard]: Decaying balances + half-life decay curve
       ([Chart.Time_series]), append-only [candle-ledger.jsonl] event table,
       root-cause banner for [unattributed]/[backlog_fenced] Goals, contract
       note (portrait accessories only), and Company/Keeper Leaderboard. *)

open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

val draw_goal_pipeline_stepper :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  model:Model.t ->
  Wire_work.goal_phase ->
  int
(** Paint the 5-stage Goal completion stepper ([Executing -> Verifying ->
    Awaiting Confirmation -> Completed -> Candle Mint]) inside [rect] and return
    rows used. *)

val build_rejection_diff_rows :
  model:Model.t ->
  Wire_work.verification_request ->
  Diff.numbered list
(** Build a structured rejection diff comparing expected contract/required
    artifacts against observed evidence and verifier critique. *)

val render_pipeline :
  model:Model.t ->
  cache:Card.Cache.t ->
  rect:Rect.t ->
  Cell_grid.t ->
  unit

val render_tasks :
  model:Model.t ->
  cache:Card.Cache.t ->
  rect:Rect.t ->
  Cell_grid.t ->
  unit

val render_schedules :
  model:Model.t ->
  cache:Card.Cache.t ->
  rect:Rect.t ->
  Cell_grid.t ->
  unit

val render_inbox :
  model:Model.t ->
  cache:Card.Cache.t ->
  rect:Rect.t ->
  Cell_grid.t ->
  unit

val render_candle_scorecard :
  model:Model.t ->
  cache:Card.Cache.t ->
  rect:Rect.t ->
  Cell_grid.t ->
  unit

val render_harness :
  model:Model.t ->
  cache:Card.Cache.t ->
  rect:Rect.t ->
  Cell_grid.t ->
  unit
