(** Settlement of HTTP surface datasets, health pacing, roster, usage, and planning loads. *)

val note_read
  :  Masc_tui_types.state
  -> Masc_tui_read_failure.read
  -> ('a, Masc_tui_types.request_failure) result
  -> unit

val fail_refresh_pace : Masc_tui_types.state -> unit

val note_server_health
  :  Masc_tui_types.state
  -> answered:(Masc_tui_refresh_pace.t -> Masc_tui_refresh_pace.t)
  -> ('a, string) result
  -> unit

val apply_overview_load
  :  Masc_tui_types.state
  -> (Masc_tui_types.overview_snapshot, string) result
  -> unit

val apply_overview_goals_load
  :  Masc_tui_types.state
  -> (Masc.Tui_decode.overview_goal list, string) result
  -> unit

val apply_keeper_roster_load
  :  before_view_change:(unit -> unit)
  -> Masc_tui_types.state
  -> ( Masc_tui_keeper_control.roster * (Masc.Tui_decode.candle_reading, string) result
     , Masc_tui_keeper_control.roster_failure )
     result
  -> unit

val apply_planning_load
  :  Masc_tui_types.state
  -> (Masc_tui_types.planning_snapshot, string) result
  -> unit

val apply_http_scoped_data
  :  before_view_change:(unit -> unit)
  -> Masc_tui_types.state
  -> datasets:Masc_tui_types.Surface_read_order.dataset list
  -> 'a Masc_tui_async_protocol.http_scoped_surface_readings
  -> bool

val apply_http_dataset
  :  Masc_tui_types.state
  -> Masc_tui_async_protocol.http_dataset
  -> Masc_tui_types.board_posts_application option
