module Reading = Masc.Tui_decode

(* The first column of the two Config list panes that carry one: the prompt
   registry and the params list. Here rather than in the renderer for the
   reason the other mark modules are here -- the row and the help sheet have
   to draw the same glyph, and a source added to
   {!Masc.Tui_decode.prompt_source} stops this module compiling until it has
   been given a mark and a word.

   Both panes drew their marks as literals inside the renderer, and the sheet
   under [?] carried seven legends and neither of these. A reader scanning
   twenty prompt rows could tell a marked row from an unmarked one and not
   what the mark said; the words were only in the detail pane below, for the
   one row the cursor was on. Colour is the caller's. *)

let held_back_glyph = "\xe2\x8a\x98" (* ⊘ saved, and not in force *)
let override_glyph = "*" (* the reader's text is what turns get *)
let missing_glyph = "!" (* no file behind the key *)

(* The shipped file draws a blank: it is what a key reads as until someone
   overrides it, and a glyph for that would mark every ordinary row. A state
   with no mark needs no word, so it is not in the legend either. *)
let file_glyph = " "

let prompt_glyph ~held_back (source : Reading.prompt_source) =
  if held_back then held_back_glyph
  else
    match source with
    | Reading.Prompt_override -> override_glyph
    | Reading.Prompt_file -> file_glyph
    | Reading.Prompt_missing -> missing_glyph

(* The word says what the row reads as, not what the glyph looks like. The
   override row carries the unmarked case too, because a sheet row whose left
   cell is a blank reads as a wrapped continuation of the row above it. *)
let prompt_legend =
  [ (override_glyph, "your override; unmarked is the file")
  ; (held_back_glyph, "saved, not applied; the file is used")
  ; (missing_glyph, "no prompt file behind this key")
  ]

let param_override_glyph = "\xe2\x97\x8f" (* ● *)
let param_default_glyph = "\xe2\x97\x8b" (* ○ *)

let param_glyph ~has_override =
  if has_override then param_override_glyph else param_default_glyph

(* Both marks, because neither is the absence of the other: the params list
   fills its column on every row, and a reader who sees only hollow circles
   has no second mark to read them against. *)
let param_legend =
  [ (param_override_glyph, "set by you; default shown beside it")
  ; (param_default_glyph, "the registered default")
  ]
