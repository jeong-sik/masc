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

(* Two of the prompt marks are states, so they wear the status marks of RFC
   tui-one-screen-grammar 7.2: an override the registry declined is 반려 and a
   key with no file behind it fails, both [✕], told apart by their words (7.2
   lets two domain states share a mark). The override mark is not a state, so
   it stays a plain asterisk. *)
let held_back_glyph = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Failed
let override_glyph = "*" (* the reader's text is what turns get *)
let missing_glyph = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Failed

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
let prompt_legend_for ~ko =
  if ko then
    [ (override_glyph, "직접 재정의한 값 · 기호 없음은 기본 파일")
    ; (held_back_glyph, "저장됐지만 미적용 · 기본 파일 사용 중")
    ; (missing_glyph, "이 키에 대응하는 프롬프트 파일 없음")
    ]
  else
    [ (override_glyph, "your override; unmarked is the file")
    ; (held_back_glyph, "saved, not applied; the file is used")
    ; (missing_glyph, "no prompt file behind this key")
    ]

let prompt_legend = prompt_legend_for ~ko:false

(* A param the reader set takes the prompt registry's override mark, and the
   registered default draws a blank, as a shipped prompt file does. The two
   were ● and ○, the settled and waiting status marks (7.2), which a value's
   source is not. *)
let param_override_glyph = override_glyph
let param_default_glyph = file_glyph

let param_glyph ~has_override =
  if has_override then param_override_glyph else param_default_glyph

(* The default draws a blank, so the override row names the unmarked case,
   the way the prompt legend does. *)
let param_legend_for ~ko =
  if ko then
    [ (param_override_glyph, "직접 설정한 값 · 기호 없음은 등록된 기본값") ]
  else
    [ (param_override_glyph, "set by you; unmarked is the registered default") ]

let param_legend = param_legend_for ~ko:false
