(** Recovered-paste send locks and workspace spill staging/expansion. *)

type prepared_spill =
  { ps_spill : Masc_tui_types.message_spill
  ; ps_source : Masc_tui_types.saved_message_spill
  ; ps_directory : (string * Keeper_sandbox_config.sandbox_profile) option
  }

val recovered_paste_send_locked_for
  :  Masc_tui_types.state
  -> string option
  -> bool

val recovered_paste_send_locked : Masc_tui_types.state -> bool

val discard_recovered_paste_lock : Masc_tui_types.state -> unit

val protect_recovered_paste_for_current_keeper : Masc_tui_types.state -> unit

val inline_spilled_paste
  :  Masc_tui_types.saved_message_spill option
  -> string
  -> string

val materialise_spilled_paste
  :  Masc_tui_types.state
  -> Masc_tui_message_input.snapshot
  -> string

val place_spilled_paste
  :  Masc_tui_types.state
  -> keeper_name:string
  -> staging_dir:(string * Keeper_sandbox_config.sandbox_profile) option
  -> Masc_tui_types.saved_message_spill
  -> string

val prepare_spilled_paste
  :  Masc_tui_types.state
  -> base_path:string
  -> keeper_name:string
  -> still_allowed:(unit -> bool)
  -> Masc_tui_types.saved_message_spill option
  -> (prepared_spill option, string) result
