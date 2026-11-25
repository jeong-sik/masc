open Masc_tui_core
open Masc_tui_store

let render ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    match model.work.active_tab with
    | Nav.Work_pipeline ->
        Work_views.render_pipeline ~model ~cache ~rect grid
    | Nav.Work_tasks ->
        Work_views.render_tasks ~model ~cache ~rect grid
    | Nav.Work_schedules ->
        Work_views.render_schedules ~model ~cache ~rect grid
    | Nav.Work_inbox ->
        Work_views.render_inbox ~model ~cache ~rect grid
    | Nav.Work_candle_scorecard ->
        Work_views.render_candle_scorecard ~model ~cache ~rect grid
    | Nav.Work_harness ->
        Work_views.render_harness ~model ~cache ~rect grid

let render_verification ~req_id ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  Work_dive.render ~req_id ~model ~cache ~rect grid
