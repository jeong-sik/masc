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
   floor [Masc_tui_theme] lifts against, so the count counts the colours the
   lift would raise.

   Whether it does raise them is a separate answer -- [tui] lift_colours, held
   in [Masc_tui_theme]. This count does not consult it, because the count is a
   property of the scheme and stays true either way: with the lift on these
   are the colours it raises, with it off these are the colours left under the
   floor. The screen that shows the count is what has to say which. *)
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

let cached_entries : entry list option ref = ref None

let invalidate_cache () = cached_entries := None

let entries () =
  match !cached_entries with
  | Some list -> list
  | None ->
    let entries =
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
        (Catalog.all ())
    in
    (* Put the schemes that already clear the readable floor first. The old
       catalog order was explicitly "no particular order", which hid native
       high-contrast candidates among thirty-seven rows and made the picker
       look like an unsorted filename dump. Within the same assistance cost,
       names are alphabetical so the order stays predictable. *)
    let sorted =
      List.sort
        (fun left right ->
          match Int.compare left.lifted right.lifted with
          | 0 -> String.compare left.name right.name
          | order -> order)
        entries
    in
    cached_entries := Some sorted;
    sorted
;;

(* A zero is a result, not the absence of one: every measured colour already
   clears the floor without masc touching it. For a non-zero count the same
   scheme has two honest readings, depending on whether the reader enabled
   the lift. Keep that distinction beside the measurement so the chooser
   cannot drift back to the ambiguous "none" / "3 of 7" pair. *)
let contrast_status ~lift_on (entry : entry) =
  if entry.lifted = 0 then Printf.sprintf "native %d/%d" entry.measured entry.measured
  else if lift_on then Printf.sprintf "lift %d/%d" entry.lifted entry.measured
  else Printf.sprintf "%d/%d low" entry.lifted entry.measured
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
