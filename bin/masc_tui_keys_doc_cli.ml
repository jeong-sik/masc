(** Writes the generated key reference to stdout. The native TUI proof
    workflow keeps it as [key-reference.md]. *)

let () = print_string (Masc_tui_keymap.Keymap.render_markdown_reference ())
