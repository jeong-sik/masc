(** Writes the generated key reference to stdout; committed over
    docs/guides/TUI-KEYS.md. *)

let () = print_string (Masc_tui_keys_doc.markdown ())
