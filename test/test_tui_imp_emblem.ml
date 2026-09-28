(** Masc_tui_imp_emblem: the turning imp emblem drawn in Braille. *)

open Alcotest
module Emblem = Masc_tui_imp_emblem
module Shape = Masc_tui_imp_shape
module Palette = Masc_tui_terminal_palette

let size_exn ~cols ~rows =
  match Emblem.fit ~cols ~rows with
  | Some size -> size
  | None -> fail (Printf.sprintf "fit %dx%d" cols rows)

let pose_exn phase =
  match Emblem.turning phase with
  | Some pose -> pose
  | None -> fail (Printf.sprintf "turning %f" phase)

let rgb red green blue = Palette.make_rgb ~red ~green ~blue

let palette ~ink ~page =
  match Palette.of_responses ~foreground:(Some ink) ~background:(Some page) ~ansi:[||] with
  | Some palette -> palette
  | None -> fail "palette"

let dark_page = Emblem.lighting (Emblem.Known (palette ~ink:(rgb 220 220 220) ~page:(rgb 16 16 20)))
let light_page = Emblem.lighting (Emblem.Known (palette ~ink:(rgb 30 30 36) ~page:(rgb 250 248 244)))

(* Every colour kept as it is, as on a truecolour terminal. *)
let truecolor = Emblem.ink_projected_by (Palette.For_testing.best_color_for_level ~level:Palette.True_color)

(* Every colour projected to nothing, as on a sixteen-colour terminal. *)
let no_colour = Emblem.ink_projected_by (fun (_ : Palette.rgb) -> None)

(* One renderer for every case: its buffers carry over between frames, which
   is what a caller does too. *)
let renderer = Emblem.create ()
let largest = size_exn ~cols:Emblem.max_cols ~rows:Emblem.max_rows
let imp_front = pose_exn 0.0

(* Both halves of a turn end facing the viewer; by the end of the first the
   imp has become the lantern. *)
let lantern_front = pose_exn 0.45

let has_escape line = String.contains line '\027'

let dot_lit (frame : Emblem.frame) pose point =
  match Emblem.For_testing.dot_of_front_point frame.Emblem.size pose point with
  | None -> fail "feature point is off the frame"
  | Some (col, row, bit) ->
    frame.Emblem.cells.((row * frame.Emblem.size.Emblem.cols) + col).Emblem.dots land bit <> 0

let offset (point : Shape.point) ~dy = { point with Shape.y = point.Shape.y +. dy }

let test_same_input_same_frame () =
  let first = Emblem.lines ~ink:truecolor (Emblem.frame renderer largest (pose_exn 0.3) dark_page) in
  (* Draw something else in between, as the next animation step would. *)
  ignore (Emblem.frame renderer largest lantern_front light_page : Emblem.frame);
  let again = Emblem.lines ~ink:truecolor (Emblem.frame renderer largest (pose_exn 0.3) dark_page) in
  check (list string) "same size, pose and lighting draw the same rows" first again

let test_a_frame_does_not_change_after_the_next () =
  let kept = Emblem.frame renderer largest imp_front dark_page in
  let rows_before = Emblem.lines ~ink:truecolor kept in
  ignore (Emblem.frame renderer largest lantern_front dark_page : Emblem.frame);
  check (list string) "an earlier frame keeps its cells" rows_before
    (Emblem.lines ~ink:truecolor kept)

(* The grin is a thin cut; perspective lets its walls fill a dot at either
   edge, so ask only that it opens at one of a few points up its middle. *)
let grin_open ?(offsets = [ -0.03; -0.015; 0.0 ]) frame pose =
  List.exists
    (fun dy -> not (dot_lit frame pose (offset Shape.imp_grin_middle ~dy)))
    offsets

let test_front_imp_shows_its_face () =
  let frame = Emblem.frame renderer largest imp_front dark_page in
  check bool "brow is drawn" true (dot_lit frame imp_front Shape.imp_brow);
  check bool "left horn is drawn" true (dot_lit frame imp_front Shape.imp_left_horn);
  check bool "left eye is open" false (dot_lit frame imp_front Shape.imp_left_eye);
  check bool "right eye is open" false (dot_lit frame imp_front Shape.imp_right_eye);
  check bool "grin cuts through the face" true (grin_open frame imp_front)

(* Turned a little, the slab's far side sits behind the lower half of the
   grin. It faces away, so it must not be drawn there. *)
let test_a_turned_imp_keeps_its_grin_open () =
  let turned = pose_exn 0.05 in
  check bool "far side does not fill the grin" true
    (grin_open ~offsets:[ -0.015; 0.0 ] (Emblem.frame renderer largest turned dark_page) turned)

let test_the_imp_becomes_the_lantern () =
  let imp = Emblem.frame renderer largest imp_front dark_page in
  let lantern = Emblem.frame renderer largest lantern_front dark_page in
  check bool "imp has a horn" true (dot_lit imp imp_front Shape.imp_left_horn);
  check bool "lantern has no horn" false (dot_lit lantern lantern_front Shape.imp_left_horn);
  check bool "lantern has its handle" true
    (dot_lit lantern lantern_front Shape.lantern_handle_top);
  check bool "imp has nothing where the handle goes" false
    (dot_lit imp imp_front Shape.lantern_handle_top)

let test_every_row_fits () =
  let sizes =
    [ size_exn ~cols:(2 * Emblem.min_rows) ~rows:Emblem.min_rows
    ; size_exn ~cols:31 ~rows:15
    ; size_exn ~cols:200 ~rows:9
    ; largest
    ]
  in
  let poses = [ imp_front; pose_exn 0.13; pose_exn 0.27; lantern_front; pose_exn 0.71; Emblem.settled ] in
  List.iter
    (fun (size : Emblem.size) ->
      List.iter
        (fun pose ->
          let rows = Emblem.lines ~ink:truecolor (Emblem.frame renderer size pose dark_page) in
          check int "one string per row" size.Emblem.rows (List.length rows);
          List.iter
            (fun row ->
              check int "row is exactly the box's width" size.Emblem.cols
                (Masc_tui_message_layout.display_width row))
            rows)
        poses)
    sizes

let test_no_colour_writes_no_escape () =
  let frame = Emblem.frame renderer largest (pose_exn 0.2) dark_page in
  check bool "a colour projected to nothing writes no escape" false
    (List.exists has_escape (Emblem.lines ~ink:no_colour frame));
  let unknown = Emblem.frame renderer largest (pose_exn 0.2) (Emblem.lighting Emblem.Unknown) in
  check bool "an unknown page gets dots and no colour" false
    (List.exists has_escape (Emblem.lines ~ink:truecolor unknown));
  check bool "the dots are still drawn" true
    (Array.exists (fun (cell : Emblem.cell) -> cell.Emblem.dots <> 0) unknown.Emblem.cells)

let test_page_colour_changes_the_ink_not_the_shape () =
  let dark = Emblem.frame renderer largest (pose_exn 0.2) dark_page in
  let light = Emblem.frame renderer largest (pose_exn 0.2) light_page in
  check bool "same dots on either page" true
    (Array.for_all2
       (fun (a : Emblem.cell) (b : Emblem.cell) -> a.Emblem.dots = b.Emblem.dots)
       dark.Emblem.cells light.Emblem.cells);
  let differs (a : Emblem.cell) (b : Emblem.cell) =
    match a.Emblem.ink, b.Emblem.ink with
    | Some x, Some y ->
      Palette.red x <> Palette.red y
      || Palette.green x <> Palette.green y
      || Palette.blue x <> Palette.blue y
    | None, None -> false
    | Some _, None | None, Some _ -> true
  in
  check bool "the ink follows the page" true
    (Array.exists2 differs dark.Emblem.cells light.Emblem.cells)

let test_fit () =
  check bool "too short to read" true (Option.is_none (Emblem.fit ~cols:80 ~rows:(Emblem.min_rows - 1)));
  check bool "too narrow to read" true
    (Option.is_none (Emblem.fit ~cols:((2 * Emblem.min_rows) - 1) ~rows:40));
  let wide = size_exn ~cols:200 ~rows:9 in
  check (pair int int) "a wide space gives a box two columns per row" (18, 9)
    (wide.Emblem.cols, wide.Emblem.rows);
  let huge = size_exn ~cols:500 ~rows:500 in
  check (pair int int) "never past the largest box" (Emblem.max_cols, Emblem.max_rows)
    (huge.Emblem.cols, huge.Emblem.rows)

let test_turning () =
  check bool "a phase that is not a number" true (Option.is_none (Emblem.turning Float.nan));
  check bool "an infinite phase" true (Option.is_none (Emblem.turning Float.infinity));
  let rows pose = Emblem.lines ~ink:truecolor (Emblem.frame renderer largest pose dark_page) in
  check (list string) "whole loops are dropped" (rows (pose_exn 0.25)) (rows (pose_exn 3.25));
  check (list string) "a negative phase counts back from the loop's end" (rows (pose_exn 0.75))
    (rows (pose_exn (-0.25)))

let test_settled_is_the_imp () =
  let frame = Emblem.frame renderer largest Emblem.settled dark_page in
  check bool "settled imp shows its brow" true (dot_lit frame Emblem.settled Shape.imp_brow);
  check bool "settled imp shows its horn" true (dot_lit frame Emblem.settled Shape.imp_left_horn)

(* ---- a row read back as a terminal would draw it ---- *)

(* Whether each glyph of a row is drawn in a colour set by an escape, and
   whether one is still set when the row ends. Only SGR 38 (set) and 39
   (terminal's own colour) may appear. *)
let read_row row =
  let length = String.length row in
  let rec go i coloured drawn =
    if i >= length
    then List.rev drawn, coloured
    else if row.[i] = '\027'
    then (
      let close = String.index_from row i 'm' in
      let params = String.sub row (i + 2) (close - i - 2) in
      if String.equal params "39"
      then go (close + 1) false drawn
      else if String.starts_with ~prefix:"38;" params
      then go (close + 1) true drawn
      else fail ("unexpected escape: " ^ String.escaped params))
    else if row.[i] = ' '
    then go (i + 1) coloured (None :: drawn)
    else
      (* A Braille glyph: three UTF-8 bytes. *)
      go (i + 3) coloured (Some coloured :: drawn)
  in
  go 0 false []

(* A colour projected to nothing between two that are drawn must be drawn in
   the terminal's own colour, not the one before it, and no row may leave a
   colour set behind it. *)
let test_a_row_ends_in_the_terminal_colour () =
  let project colour =
    if Palette.red colour >= 128
    then Palette.For_testing.best_color_for_level ~level:Palette.True_color colour
    else None
  in
  let frame = Emblem.frame renderer largest imp_front dark_page in
  let rows = Emblem.lines ~ink:(Emblem.ink_projected_by project) frame in
  let cols = frame.Emblem.size.Emblem.cols in
  let expected row col =
    let cell = frame.Emblem.cells.((row * cols) + col) in
    if cell.Emblem.dots = 0
    then None
    else
      Some
        (match cell.Emblem.ink with
         | Some colour -> Option.is_some (project colour)
         | None -> false)
  in
  let mixed = ref false in
  List.iteri
    (fun row text ->
      if Masc_tui_theme.colors_enabled
      then (
        let drawn, left_coloured = read_row text in
        check bool "the row does not leave a colour set" false left_coloured;
        let wanted = List.init cols (expected row) in
        check (list (option bool)) "each glyph in its own colour" wanted drawn;
        if List.mem (Some true) wanted && List.mem (Some false) wanted then mixed := true)
      else check bool "colours off: no escape" false (has_escape text))
    rows;
  if Masc_tui_theme.colors_enabled
  then check bool "some row mixes drawn and undrawn colours" true !mixed

(* Read off the cells, not through the renderer's projection: the horns are
   the top of the front imp and the chin its bottom, and the drawing fills
   most of the box without touching its edges. An upside-down or mis-scaled
   projection moves all of the feature probes with it, but not this. *)
let test_the_front_imp_stands_upright () =
  let frame = Emblem.frame renderer largest imp_front dark_page in
  let size = frame.Emblem.size in
  let cols = size.Emblem.cols and rows = size.Emblem.rows in
  let lit row col = frame.Emblem.cells.((row * cols) + col).Emblem.dots <> 0 in
  let row_lit row = List.exists (lit row) (List.init cols Fun.id) in
  let lit_rows = List.filter row_lit (List.init rows Fun.id) in
  let first = List.hd lit_rows and last = List.nth lit_rows (List.length lit_rows - 1) in
  let middle = cols / 2 in
  let centre row = lit row (middle - 1) || lit row middle in
  let outer row =
    List.exists (lit row) (List.init (cols / 4) Fun.id)
    || List.exists (lit row) (List.init (cols / 4) (fun i -> cols - 1 - i))
  in
  let left row = List.exists (lit row) (List.init middle Fun.id) in
  let right row = List.exists (lit row) (List.init middle (fun i -> middle + i)) in
  check bool "the top row holds two horn tips" true
    (left first && right first && not (centre first));
  check bool "the bottom row is the chin" true (centre last && not (outer last));
  check bool "room above the horns" true (first >= 1);
  check bool "room below the chin" true (last <= rows - 2);
  check bool "the imp fills most of the box's height" true ((last - first + 1) * 10 >= rows * 7)

let luminance colour =
  (0.2126 *. Float.of_int (Palette.red colour))
  +. (0.7152 *. Float.of_int (Palette.green colour))
  +. (0.0722 *. Float.of_int (Palette.blue colour))

let inks (frame : Emblem.frame) =
  Array.to_list frame.Emblem.cells
  |> List.filter_map (fun (cell : Emblem.cell) -> cell.Emblem.ink)

let mean_luminance frame =
  let inks = inks frame in
  List.fold_left (fun sum ink -> sum +. luminance ink) 0.0 inks /. Float.of_int (List.length inks)

(* A terminal that says only whether its page is dark or light: the ink is
   still there, darker on a light page than on a dark one, and without a page
   colour to fade toward it differs from the same dark page with its colour
   known. *)
let test_a_page_known_only_as_dark_or_light () =
  let at lighting = Emblem.frame renderer largest imp_front lighting in
  let dark = at (Emblem.lighting (Emblem.Page Palette.Dark)) in
  let light = at (Emblem.lighting (Emblem.Page Palette.Light)) in
  let lit_without_ink (frame : Emblem.frame) =
    Array.exists
      (fun (cell : Emblem.cell) -> cell.Emblem.dots <> 0 && Option.is_none cell.Emblem.ink)
      frame.Emblem.cells
  in
  check bool "every lit cell has ink on a dark page" false (lit_without_ink dark);
  check bool "every lit cell has ink on a light page" false (lit_without_ink light);
  check bool "the ink is darker on a light page" true (mean_luminance light < mean_luminance dark);
  let known = at dark_page in
  check bool "no fade without the page colour" true
    (List.exists2 (fun a b -> luminance a <> luminance b) (inks dark) (inks known))

(* The lights shade the face: a single flat colour would pass every other
   ink test. *)
let test_the_lights_shade_the_face () =
  let frame = Emblem.frame renderer largest imp_front dark_page in
  let distinct =
    List.sort_uniq compare
      (List.map (fun c -> Palette.red c, Palette.green c, Palette.blue c) (inks frame))
  in
  check bool "many shades across the face" true (List.length distinct >= 20)

let () =
  let started = Unix.gettimeofday () in
  let frames = 20 in
  for i = 1 to frames do
    ignore
      (Emblem.frame renderer largest (pose_exn (Float.of_int i /. Float.of_int frames)) dark_page
        : Emblem.frame)
  done;
  Printf.printf "imp emblem: %.2f ms per %dx%d frame (mean of %d)\n%!"
    ((Unix.gettimeofday () -. started) *. 1000.0 /. Float.of_int frames)
    largest.Emblem.cols largest.Emblem.rows frames;
  run "TUI imp emblem"
    [ ( "frames"
      , [ test_case "same input, same frame" `Quick test_same_input_same_frame
        ; test_case "a frame outlives the next" `Quick test_a_frame_does_not_change_after_the_next
        ; test_case "front imp shows its face" `Quick test_front_imp_shows_its_face
        ; test_case "turned imp keeps its grin open" `Quick
            test_a_turned_imp_keeps_its_grin_open
        ; test_case "imp becomes the lantern" `Quick test_the_imp_becomes_the_lantern
        ; test_case "settled pose is the imp" `Quick test_settled_is_the_imp
        ; test_case "front imp stands upright" `Quick test_the_front_imp_stands_upright
        ] )
    ; ( "text"
      , [ test_case "every row fits its box" `Quick test_every_row_fits
        ; test_case "no colour, no escape" `Quick test_no_colour_writes_no_escape
        ; test_case "page colour moves ink only" `Quick
            test_page_colour_changes_the_ink_not_the_shape
        ; test_case "a row ends in the terminal colour" `Quick
            test_a_row_ends_in_the_terminal_colour
        ] )
    ; ( "lighting"
      , [ test_case "page known only as dark or light" `Quick
            test_a_page_known_only_as_dark_or_light
        ; test_case "the lights shade the face" `Quick test_the_lights_shade_the_face
        ] )
    ; ( "inputs"
      , [ test_case "fit" `Quick test_fit; test_case "turning" `Quick test_turning ] )
    ]
