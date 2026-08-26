(* [Unix.file_descr] is an int on every platform this builds for, which is the
   representation the stubs read with [Int_val]; declaring the externals over
   the abstract type keeps the conversion in C instead of an [Obj.magic]
   here. *)
external literal_next : Unix.file_descr -> int = "masc_tui_termios_literal_next"

external set_literal_next : Unix.file_descr -> int -> bool
  = "masc_tui_termios_set_literal_next"

external disable_literal_next : Unix.file_descr -> bool
  = "masc_tui_termios_disable_literal_next"
