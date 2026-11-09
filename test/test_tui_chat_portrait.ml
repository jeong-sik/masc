open Alcotest
module Chat = Masc_tui_chat_portrait
module View = Masc_tui_portrait_view
module Portrait = Masc_tui_keeper_portrait
module Look = Keeper_portrait_look

let project = Masc_tui_terminal_palette.For_testing.best_color_for_level
  ~level:Masc_tui_terminal_palette.True_color
let pixels = View.Pixels {cell_width = 10; cell_height = 20}

let prepare cache ?(display = pixels) ?(figure = Chat.Face) ?(rows = 28) ?(cols = 34)
    ?equipment ?(portrait = Keeper_portrait_equipment.Ready Keeper_portrait_look.bare) name =
  let portrait = match equipment with
    | Some value -> Keeper_portrait_equipment.Ready value
    | None -> portrait in
  Chat.prepare cache ~display ~project ~figure ~name ~portrait ~rows ~cols

let test_whole_body_uses_the_full_drawing () =
  let cache = Portrait.cache () in
  let face = Option.get (Option.get (prepare cache "alpha")).Chat.placement in
  let body =
    Option.get (Option.get (prepare cache ~figure:Chat.Whole_body "alpha")).Chat.placement in
  check bool "the whole body is not the face thumbnail" false
    (String.equal face.image.Keeper_portrait_draw.rgba body.image.Keeper_portrait_draw.rgba);
  let full = Portrait.image cache ~name:"alpha" ~equipment:Look.bare body.box.size in
  check bool "placed pixels draw the full portrait" true
    (String.equal full.Keeper_portrait_draw.rgba body.image.Keeper_portrait_draw.rgba)

let test_a_mosaic_whole_body_keeps_equipment_visible () =
  let cache = Portrait.cache () in
  let lines ?equipment figure =
    (Option.get (prepare cache ~display:View.Mosaic ~figure ?equipment "alpha")).Chat.picture_lines
  in
  check bool "a mosaic whole body takes a larger box than the face" true
    (List.length (lines Chat.Whole_body) > List.length (lines Chat.Face));
  let glasses = { Look.bare with face = Look.Glasses } in
  check bool "observed glasses change the mosaic whole body" false
    (lines ~equipment:glasses Chat.Whole_body = lines Chat.Whole_body)

let test_space_and_identity () =
  let cache = Portrait.cache () in
  let alpha = Option.get (prepare cache "alpha") in
  let p = Option.get alpha.Chat.placement in
  check int "roster, caption, image and bottom use the existing left pane" 28
    (alpha.roster_rows + 1 + List.length alpha.picture_lines + 1);
  check bool "at least four roster entries remain" true (Masc_tui_frame.content_height ~rows:alpha.roster_rows >= 4);
  check int "placement is directly below the conversation caption" 1 p.row;
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

let test_observed_equipment () =
  let cache = Portrait.cache () in
  let bare = Option.get (prepare cache "alpha") in
  let bare_image = (Option.get bare.placement).image in
  let equipment = { Look.bare with face = Look.Glasses; head = Look.Crown } in
  let dressed = Option.get (prepare cache ~equipment "alpha") in
  let dressed_placement = Option.get dressed.placement in
  check bool "same conversation reflects newly observed clothes" false
    (String.equal bare_image.Keeper_portrait_draw.rgba
      dressed_placement.image.Keeper_portrait_draw.rgba);
  check int "clothing preserves roster space" bare.roster_rows dressed.roster_rows;
  let repeat = Option.get (prepare cache ~equipment "alpha") in
  check bool "unchanged observed clothing reuses the picture" true
    (dressed_placement.image == (Option.get repeat.placement).image);
  let restored = Option.get (prepare cache "alpha") in
  check bool "restored outfit reuses its own cached picture" true
    (bare_image == (Option.get restored.placement).image)

let test_small_and_colourless () =
  let cache = Portrait.cache () in
  List.iter (fun display ->
    check bool "short pane gives all rows to the roster" true
      (Option.is_none (prepare cache ~display ~rows:12 "alpha"));
    check bool "narrow pane gives all columns to the roster" true
      (Option.is_none (prepare cache ~display ~cols:7 "alpha")))
    [pixels; View.Mosaic];
  check bool "NO_COLOR suppresses the portrait" true
    (Option.is_none (prepare cache ~display:View.No_picture "alpha"));
  let mosaic = Option.get (prepare cache ~display:View.Mosaic "alpha") in
  check bool "mosaic never requests Kitty graphics" true (Option.is_none mosaic.placement);
  List.iter (fun line ->
    check bool "mosaic cells stay inside the roster" true
      (Masc_tui_message_layout.display_width line <= 30)) mosaic.picture_lines

let test_observed_equipment_and_unavailable () =
  let cache = Portrait.cache () in
  let image portrait = (Option.get (Option.get portrait).Chat.placement).View.image in
  let bare = image (prepare cache "alpha") in
  let equipment = { Keeper_portrait_look.bare with face = Keeper_portrait_look.Glasses } in
  let equipped = image (prepare cache ~portrait:(Keeper_portrait_equipment.Ready equipment) "alpha") in
  check bool "same conversation displays the observed equipment" false
    (String.equal bare.Keeper_portrait_draw.rgba equipped.Keeper_portrait_draw.rgba);
  check bool "unchanged equipment reuses its pixels" true
    (equipped == image (prepare cache ~portrait:(Keeper_portrait_equipment.Ready equipment) "alpha"));
  check bool "unavailable reading does not reuse retained pixels" true
    (Option.is_none (prepare cache ~portrait:(Keeper_portrait_equipment.Unavailable "fixture unread") "alpha"))

let () = run "chat portrait" ["conversation identity and layout", [
  test_case "uses observed equipment and suppresses unavailable readings" `Quick test_observed_equipment_and_unavailable;
  test_case "owns its space and follows the conversation" `Quick test_space_and_identity;
  test_case "follows observed clothing without taking roster space" `Quick test_observed_equipment;
  test_case "yields to space and colour preferences" `Quick test_small_and_colourless;
  test_case "a whole body uses the full drawing" `Quick test_whole_body_uses_the_full_drawing;
  test_case "a mosaic whole body keeps equipment visible" `Quick
    test_a_mosaic_whole_body_keeps_equipment_visible]]
