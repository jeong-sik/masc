(** The chat-pane text for the [/preset] commands. Pure. *)

val listing_lines : Masc.Tui_decode.presets_snapshot -> string list
(** One header, one line per preset with its counts and description, then
    one [!] line per unreadable directory; a single hint line when empty. *)

val saved_line : Masc.Tui_decode.preset_manifest -> string

val restore_lines : Masc.Tui_decode.preset_restore_report -> string list
(** The restored name and its autosave, then each surface with its effect
    and applied/skipped counts, every skipped key with its reason, and the
    runtime.toml outcome. *)

val restore_is_clean : Masc.Tui_decode.preset_restore_report -> bool
(** No surface skipped anything and runtime.toml did not fail. *)
