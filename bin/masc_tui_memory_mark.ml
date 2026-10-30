module Reading = Masc_tui_types

(* The ST column on the Memory roster: what a keeper's memory reading is.
   Here rather than in the renderer for the reason the other mark modules are
   here -- the column and the help sheet have to draw the same glyph, and a
   state added to {!Masc_tui_types.memory_state} stops this module compiling
   until it has been given a mark and a word.

   The words were a literal row the surface drew above every roster, spelled
   apart from the glyphs the rows below it drew. Colour is the caller's:
   {!Masc_tui_render_memory} paints the deviation. *)

let ready_glyph = "+"
let attention_glyph = "!"
let no_snapshot_glyph = "-"
let source_only_glyph = "s"
let failed_glyph = "x"

let glyph : Reading.memory_state -> string = function
  | Reading.Memory_ordinary -> ready_glyph
  | Reading.Memory_warning | Reading.Memory_degraded -> attention_glyph
  | Reading.Memory_no_current -> no_snapshot_glyph
  | Reading.Memory_source_only -> source_only_glyph
  | Reading.Memory_starving | Reading.Memory_read_error -> failed_glyph

(* One row per mark, not per state: two states share the attention mark and
   two share the failure mark, and a sheet that listed them separately would
   print the same glyph twice with two words beside it. The word says what the
   reading is, not what the glyph looks like. *)
let legend =
  [ (ready_glyph, "a current snapshot")
  ; (attention_glyph, "read, with something to look at")
  ; (no_snapshot_glyph, "no current snapshot")
  ; (source_only_glyph, "source facts only")
  ; (failed_glyph, "starving, or the read failed")
  ]
