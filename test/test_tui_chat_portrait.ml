open Alcotest
module Chat = Masc_tui_chat_portrait
module View = Masc_tui_portrait_view
module Portrait = Masc_tui_keeper_portrait

let project = Masc_tui_terminal_palette.For_testing.best_color_for_level
  ~level:Masc_tui_terminal_palette.True_color
let pixels = View.Pixels {cell_width = 10; cell_height = 20}

let prepare cache ?(display = pixels) ?(rows = 28) ?(cols = 34) name =
  Chat.prepare cache ~display ~project ~name ~rows ~cols

let test_space_and_identity () =
  let cache = Portrait.cache () in
  let alpha = Option.get (prepare cache "alpha") in
  let p = Option.get alpha.Chat.placement in
  check int "roster, caption, image and bottom use the existing left pane" 28
    (alpha.roster_rows + 1 + List.length alpha.picture_lines + 1);
  check bool "at least four roster entries remain" true (Masc_tui_frame.content_height ~rows:alpha.roster_rows >= 4);
  check int "nominal placement reserves the caption row" (alpha.roster_rows + 1) p.row;
  check bool "pixels stay inside the roster border" true
    (p.column >= 2 && p.column + p.box.cols <= 32);
  check bool "pixels stay above the bottom border" true (p.row + p.box.rows < 28);
  let repeat = Option.get (prepare cache "alpha") in
  check bool "unchanged chat reuses the image" true
    (p.image == (Option.get repeat.placement).image);
  let beta = Option.get (prepare cache "beta") in
  check bool "changing the conversation changes the portrait" false
    (String.equal p.image.Keeper_portrait_draw.rgba
      (Option.get beta.placement).image.Keeper_portrait_draw.rgba)

let test_four_selectable_roster_rows_are_the_boundary () =
  let cache = Portrait.cache () in
  List.iter (fun display ->
    let band = Option.get (Portrait.band_size display) in
    let minimum_rows = Masc_tui_frame.chrome_rows + 4 + band.rows + 2 in
    check bool "one fewer row gives the space back to the roster" true
      (Option.is_none (prepare cache ~display ~rows:(minimum_rows - 1) "alpha"));
    let portrait = Option.get (prepare cache ~display ~rows:minimum_rows "alpha") in
    check int "the first fitting portrait leaves four selectable rows" 4
      (Masc_tui_frame.content_height ~rows:portrait.roster_rows))
    [pixels; View.Mosaic]

let test_small_and_colourless () =
  let cache = Portrait.cache () in
  List.iter (fun display ->
    check bool "short pane gives all rows to the roster" true
      (Option.is_none (prepare cache ~display ~rows:12 "alpha"));
    check bool "narrow pane gives all columns to the roster" true
      (Option.is_none (prepare cache ~display ~cols:15 "alpha")))
    [pixels; View.Mosaic];
  check bool "NO_COLOR suppresses the portrait" true
    (Option.is_none (prepare cache ~display:View.No_picture "alpha"));
  let mosaic = Option.get (prepare cache ~display:View.Mosaic "alpha") in
  check bool "mosaic never requests Kitty graphics" true (Option.is_none mosaic.placement);
  List.iter (fun line ->
    check bool "mosaic cells stay inside the roster" true
      (Masc_tui_message_layout.display_width line <= 30)) mosaic.picture_lines

let () = run "chat portrait" ["conversation identity and layout", [
  test_case "owns its space and follows the conversation" `Quick test_space_and_identity;
  test_case "reserves four selectable roster rows at the boundary" `Quick test_four_selectable_roster_rows_are_the_boundary;
  test_case "yields to space and colour preferences" `Quick test_small_and_colourless]]
