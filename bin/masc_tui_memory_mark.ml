module Reading = Masc_tui_types

(* The ST column on the Memory roster: what a keeper's memory reading is.
   Here rather than in the renderer for the reason the other mark modules are
   here -- the column and the help sheet have to draw the same glyph, and a
   state added to {!Masc_tui_types.memory_state} stops this module compiling
   until it has been given a mark and a word.

   The words were a literal row the surface drew above every roster, spelled
   apart from the glyphs the rows below it drew. The glyphs were their own
   alphabet, [+ ! - s x], where RFC tui-one-screen-grammar 7.2 gives every
   screen seven marks with one meaning each. The states that share a mark are
   told apart beside it: the picking rows draw the state's word, and the
   detail table's facts and source columns read a dash without a current
   snapshot. Colour is the caller's: {!Masc_tui_render_memory} paints the
   deviation. *)

module Mark = Masc_tui_value.Mark

let mark : Reading.memory_state -> Mark.t = function
  | Reading.Memory_ordinary -> Mark.Settled
  | Reading.Memory_warning | Reading.Memory_degraded | Reading.Memory_no_current
  | Reading.Memory_source_only ->
      Mark.Caution
  | Reading.Memory_starving | Reading.Memory_read_error -> Mark.Failed

let glyph state = Mark.glyph (mark state)

(* One row per mark, not per state: four states share the caution mark and
   two share the failure mark, and a sheet that listed them separately would
   print the same glyph four times with four words beside it. The word says
   what the reading is, not what the glyph looks like. *)
let legend_for ~ko =
  (if ko then
     [ (Mark.glyph Mark.Settled, "최신 스냅샷 있음")
     ; ( Mark.glyph Mark.Caution
       , "조회됨 · 확인 필요(경고, Librarian 중지, 최신 스냅샷 없음, 또는 원본 사실만 있음)" )
     ; (Mark.glyph Mark.Failed, "기억 부족 또는 조회 실패")
     ]
   else
     [ (Mark.glyph Mark.Settled, "a current snapshot")
     ; ( Mark.glyph Mark.Caution
       , "read, with something to look at: a warning, a stopped Librarian, no \
          current snapshot, or source facts only" )
     ; (Mark.glyph Mark.Failed, "starving, or the read failed")
     ])
  (* The words of the header's world line follow the marks, its `?` among them:
     they are what a reader of that line would look up. *)
  @ Masc_tui_memory_world.legend_for ~ko

let legend = legend_for ~ko:false
