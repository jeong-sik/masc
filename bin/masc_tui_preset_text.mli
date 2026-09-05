(** The chat-pane text for the [/preset] commands. Pure. *)

val listing_lines : Masc.Tui_decode.presets_snapshot -> string list
(** One header, one line per preset with its counts and description, then
    one [!] line per unreadable directory; a single hint line when empty. *)

val saved_line : Masc.Tui_decode.preset_manifest -> string

val pane_row : Masc.Tui_decode.preset_manifest -> string
(** One row of the Config pane list: name, counts, saved-at. *)

val detail_lines :
  selected:Masc.Tui_decode.preset_manifest option ->
  detail:Masc.Tui_decode.preset_detail Masc_tui_fetched.view ->
  report:Masc.Tui_decode.preset_restore_report option ->
  string list
(** The pane's detail: what the selected preset holds, then the last restore
    report, which is the only place the skipped keys and the runtime.toml
    outcome are said.

    [detail] is what is known about the selected preset's contents. All four
    states are rendered: waiting says so, and a failure says why. Matching
    the answer to the selection is {!Masc_tui_fetched}'s job, so a late
    answer for a preset the cursor has left never reaches here. *)

val restore_lines : Masc.Tui_decode.preset_restore_report -> string list
(** The restored name and its autosave, then each surface with its effect
    and applied/skipped counts, every skipped key with its reason, and the
    runtime.toml outcome. *)

val restore_is_clean : Masc.Tui_decode.preset_restore_report -> bool
(** No surface skipped anything and runtime.toml did not fail. *)
