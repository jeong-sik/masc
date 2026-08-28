(* Choosing a set of colours, and remembering it. See the interface. *)

module Palette = Masc_tui_terminal_palette
module Catalog = Masc_tui_theme_catalog
module Color = Masc_tui_color

type entry =
  { name : string
  ; light : bool
  ; measured : int
  ; lifted : int
  ; swatch : Palette.rgb list
  }

(* What a status or role colour has to clear to be read as text. The same
   floor [Masc_tui_theme] lifts against, so the count shown beside a theme is
   the count that will actually be lifted. *)
let text_floor = 4.5

(* The colours a reader sees a meaning in. Not every ANSI slot -- a theme is
   judged on what masc draws through it. *)
let measured_slots = [ 9; 10; 11; 12; 13; 14; 8 ]

let lifted_count palette =
  let background = Palette.background palette in
  List.fold_left
    (fun total slot ->
      match Palette.ansi palette slot with
      | None -> total
      | Some color ->
        if Color.contrast_ratio color background >= text_floor then total
        else total + 1)
    0 measured_slots
;;

let entries () =
  List.filter_map
    (fun scheme ->
      match Catalog.to_palette scheme with
      | None -> None
      | Some palette ->
        Some
          { name = Catalog.name scheme
          ; light = Catalog.light scheme
          ; measured = List.length measured_slots
          ; lifted = lifted_count palette
          ; swatch =
              (* The page first, then the colours masc reads meaning from, so
                 a row shows the scheme the way the screen will. *)
              Palette.background palette
              :: List.filter_map (Palette.ansi palette) measured_slots
          })
    Catalog.bundled
;;

(* The reader's own choice, held beside the terminal's answer rather than
   inside it: the terminal keeps reporting whatever it reports, and this says
   whether masc listens. Publishing goes through the same generation the OSC
   answers use, so picking a theme repaints exactly the way a theme switch
   reported by the terminal does. *)
let apply name =
  match Catalog.find name with
  | None -> false
  | Some scheme ->
    (match Catalog.to_palette scheme with
     | None -> false
     | Some palette ->
       Palette.set_current (Some palette);
       true)
;;

let follow_terminal () = Palette.set_current None
