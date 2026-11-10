(* Shim: the test writes [open Masc]; the real Masc library pulls masc.auth,
   which requires jose (absent in this lane). This module exposes only the two
   modules the test touches, so the test source compiles unmodified. *)
module String_util = String_util
module Tui_terminal_text = Tui_terminal_text
