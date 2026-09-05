(** The chat-pane text for the [/preset] commands. Pure. *)

val listing_lines : Masc.Tui_decode.presets_snapshot -> string list
(** One header, one line per preset with its counts and description, then
    one [!] line per unreadable directory; a single hint line when empty. *)

val saved_line : Masc.Tui_decode.preset_manifest -> string

val pane_row : Masc.Tui_decode.preset_manifest -> string
(** One row of the Config pane list: name, counts, saved-at. *)

val detail_lines :
  selected:Masc.Tui_decode.preset_manifest option ->
  detail:Masc.Tui_decode.preset_detail option ->
  report:Masc.Tui_decode.preset_restore_report option ->
  string list
(** The pane's detail: what the selected preset holds, then the last restore
    report, which is the only place the skipped keys and the runtime.toml
    outcome are said.

    [detail] is the server's answer for the selected preset, and it is shown
    only when its name matches the selection -- a late answer for a preset
    the cursor has left would otherwise be read as this one's contents. *)

val restore_lines : Masc.Tui_decode.preset_restore_report -> string list
(** The restored name and its autosave, then each surface with its effect
    and applied/skipped counts, every skipped key with its reason, and the
    runtime.toml outcome. *)

val restore_is_clean : Masc.Tui_decode.preset_restore_report -> bool
(** No surface skipped anything and runtime.toml did not fail. *)
