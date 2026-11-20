(** Startup preference loading, session pick tracking, and writer completion
    draining for [[tui]] settings. *)

val store : Masc_tui_types.state -> Masc.Tui_preference.change -> unit
(** Record a session pick and submit it to the server preference writer unless
    connected to an account-only multi-account server. *)

val drain_completions : Masc_tui_types.state -> can_take:(unit -> bool) -> bool
(** Drain finished [tui] preference writes into UI state and notices, returning
    whether anything changed. *)

val drain_keeper_completions : Masc_tui_types.state -> can_take:(unit -> bool) -> bool
(** Drain finished [tui-keepers.toml] writes into UI state and notices. *)

val apply_stored_picks
  :  on_midi_soundfont:(string option -> unit)
  -> on_audio_input_device:(string option -> unit)
  -> set_table_frame:(bool -> unit)
  -> Masc_tui_types.state
  -> Masc.Tui_preference.settings
  -> unit
(** Apply stored [[tui]] picks that have not yet been overridden in this
    session. *)

val apply_startup_settings
  :  on_midi_soundfont:(string option -> unit)
  -> on_audio_input_device:(string option -> unit)
  -> set_table_frame:(bool -> unit)
  -> Masc_tui_types.state
  -> Masc_tui_config.t
  -> unit
(** Apply startup settings read before terminal ownership begins. *)
