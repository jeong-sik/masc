(* A Keeper's own portrait beside its Identity facts: when a pane is big
   enough for it, how the facts sit beside it, where real pixels go and when
   they do not, and how many rendered portraits the session keeps. *)

open Alcotest
module Portrait = Masc_tui_keeper_portrait
module View = Masc_tui_portrait_view
module Draw = Keeper_portrait_draw
module Look = Keeper_portrait_look
module Layout = Masc_tui_message_layout
module Palette = Masc_tui_terminal_palette

let project = Palette.For_testing.best_color_for_level ~level:Palette.True_color
let pixels = View.Pixels { cell_width = 10; cell_height = 20 }

(* Body names are stable; equipment is an explicit server snapshot. *)
let alpha = "alpha"
let beta = "beta"

let image_id = Masc_tui_graphics.image_id Masc_tui_graphics.Keeper_portrait
let size_on display = Option.get (Portrait.band_size display)
let mosaic_size = size_on View.Mosaic
let pixel_size = size_on pixels

let band ?(equipment = Look.bare) ?(cache = Portrait.cache ()) ?(display = View.Mosaic) ?(name = alpha)
    ?(content_rows = Portrait.min_content_rows (size_on display))
    ?(content_cols = Portrait.min_content_cols (size_on display)) () =
  Portrait.band cache ~display ~project ~name ~equipment ~content_rows ~content_cols

let shows ?display ?content_rows ?content_cols () =
  Option.is_some (band ?display ?content_rows ?content_cols ())

let test_a_small_pane_keeps_its_rows_for_facts () =
  List.iter
    (fun display ->
      let size = size_on display in
      check bool "at the thresholds" true (shows ~display ());
      check bool "one row under it, none" false
        (shows ~display ~content_rows:(Portrait.min_content_rows size - 1) ());
      check bool "one cell under it, none" false
        (shows ~display ~content_cols:(Portrait.min_content_cols size - 1) ());
      check bool "the threshold leaves rows below the band" true
        (Portrait.min_content_rows size > size.Portrait.rows);
      check bool "and cells beside it" true
        (Portrait.min_content_cols size > size.Portrait.cols))
    [ View.Mosaic; pixels ]

let test_no_picture_is_no_band () =
  check bool "no band size" true (Option.is_none (Portrait.band_size View.No_picture));
  check bool "NO_COLOR, or no colour to draw in" false
    (shows ~display:View.No_picture ~content_rows:400 ~content_cols:400 ())

let test_the_band_is_compact () =
  let mosaic = Option.get (band ()) in
  check int "a mosaic takes every band row" mosaic_size.Portrait.rows mosaic.Portrait.box.View.rows;
  check int "and every band cell" mosaic_size.Portrait.cols mosaic.Portrait.box.View.cols;
  check int "a line per row" mosaic_size.Portrait.rows (List.length mosaic.Portrait.lines);
  List.iter
    (fun line ->
      check int "each the band wide" mosaic_size.Portrait.cols (Layout.display_width line))
    mosaic.Portrait.lines;
  let placed = Option.get (band ~display:pixels ()) in
  check bool "real pixels fit their band's rows" true
    (placed.Portrait.box.View.rows <= pixel_size.Portrait.rows);
  check bool "and its cells" true (placed.Portrait.box.View.cols <= pixel_size.Portrait.cols);
  check bool "placed pixels take fewer rows than a mosaic" true
    (pixel_size.Portrait.rows < mosaic_size.Portrait.rows);
  check (list string) "the cells a picture covers are blank"
    (List.init placed.Portrait.box.View.rows (fun _ ->
         String.make placed.Portrait.box.View.cols ' '))
    placed.Portrait.lines

let test_the_still_portrait_the_name_draws () =
  let shown = Option.get (band ~display:pixels ()) in
  let body = Look.body_of_name alpha and equipment = Look.bare in
  let drawn = Draw.render body equipment shown.Portrait.box.View.size in
  check bool "placed pixels keep the full portrait" true
    (String.equal drawn.Draw.rgba shown.Portrait.image.Draw.rgba);
  let mosaic = Option.get (band ()) in
  let compact = Draw.render_compact_posed body equipment Draw.still mosaic.Portrait.box.View.size in
  check bool "mosaic draws the compact face" true
    (String.equal compact.Draw.rgba mosaic.Portrait.image.Draw.rgba);
  check bool "a compact face differs from the full backdrop" false
    (String.equal compact.Draw.rgba
       (Draw.render body equipment mosaic.Portrait.box.View.size).Draw.rgba);
  let other = Option.get (band ~display:pixels ~name:beta ()) in
  check bool "another Keeper draws another portrait" false
    (String.equal other.Portrait.image.Draw.rgba shown.Portrait.image.Draw.rgba)

let facts n = List.init n (fun index -> Printf.sprintf "  fact %d" index)

let test_facts_stand_beside_the_portrait () =
  let shown = Option.get (band ()) in
  let band_rows = mosaic_size.Portrait.rows in
  let fact_column = 2 + mosaic_size.Portrait.cols in
  let rows = Portrait.beside shown (facts 3) in
  check int "as tall as the portrait" band_rows (List.length rows);
  List.iteri
    (fun index row ->
      check bool "each fact beside the portrait's row" true
        (String.ends_with ~suffix:(Printf.sprintf "  fact %d" index) row);
      check int "starting after the indent and the portrait" (fact_column + String.length "  fact 0")
        (Layout.display_width row))
    (List.filteri (fun index _ -> index < 3) rows);
  let long = Portrait.beside shown (facts (band_rows + 2)) in
  check int "as tall as the facts when they are taller" (band_rows + 2) (List.length long);
  check string "a fact past the portrait keeps the column"
    (String.make fact_column ' ' ^ Printf.sprintf "  fact %d" band_rows)
    (List.nth long band_rows)

let test_pixels_go_only_where_the_whole_portrait_shows () =
  let placed = Option.get (band ~display:pixels ()) in
  let rows = placed.Portrait.box.View.rows in
  let at ~scroll ~visible_rows =
    Portrait.placement placed ~scroll ~visible_rows ~origin:(4, 2)
  in
  (match at ~scroll:0 ~visible_rows:rows with
   | None -> fail "no placement for a portrait fully on screen"
   | Some p ->
       check int "under the portrait's own id" image_id p.View.image_id;
       check int "on the content's first row" 4 p.View.row;
       check int "after the indent" (2 + 2) p.View.column;
       check bool "the band's picture" true (p.View.image == placed.Portrait.image));
  check bool "scrolled, it would cover facts" true (Option.is_none (at ~scroll:1 ~visible_rows:rows));
  check bool "cut short, it cannot draw half" true
    (Option.is_none (at ~scroll:0 ~visible_rows:(rows - 1)));
  let mosaic = Option.get (band ()) in
  check bool "a mosaic is drawn in the rows, not placed" true
    (Option.is_none
       (Portrait.placement mosaic ~scroll:0 ~visible_rows:mosaic_size.Portrait.rows ~origin:(4, 2)))

(* The TUI's frame protocol: every frame starts empty, the pane asks for its
   portrait, and the flush after the frame places or deletes it. *)
let frame requests =
  View.begin_frame ();
  List.iter View.request requests;
  let written = Buffer.create 4096 in
  View.flush Masc_tui_frame_presenter.Unchanged ~write:(Buffer.add_string written);
  Buffer.contents written

let placed name =
  let shown = Option.get (band ~display:pixels ~name ()) in
  Option.get
    (Portrait.placement shown ~scroll:0 ~visible_rows:shown.Portrait.box.View.rows ~origin:(4, 2))

let test_the_picture_leaves_with_the_detail () =
  ignore (frame []);
  let alpha_placed = placed alpha in
  check string "the detail places its portrait" (View.placement_bytes alpha_placed)
    (frame [ alpha_placed ]);
  let beta_placed = placed beta in
  check string "another Keeper's detail replaces it under the same id"
    (View.placement_bytes beta_placed) (frame [ beta_placed ]);
  check string "a frame without the detail deletes it"
    (Masc_tui_graphics.delete_image ~image_id)
    (frame [])

let test_the_cache_is_bounded () =
  let cache = Portrait.cache () in
  let size = Option.get (Draw.size_of_int Draw.min_size) in
  let name index = Printf.sprintf "keeper-%d" index in
  let drawn = Array.init Portrait.cache_capacity (fun index -> Portrait.image cache ~equipment:Look.bare ~name:(name index) size) in
  check int "full" Portrait.cache_capacity (Portrait.cached cache);
  check bool "a portrait already drawn comes from the cache" true
    (Portrait.image cache ~equipment:Look.bare ~name:(name 0) size == drawn.(0));
  (* keeper-0 was the oldest; used again it is the newest, so the next new
     name pushes out keeper-1 instead. *)
  ignore (Portrait.image cache ~equipment:Look.bare ~name:"one-more" size);
  check int "never more than its capacity" Portrait.cache_capacity (Portrait.cached cache);
  check bool "the one used last is kept" true (Portrait.image cache ~equipment:Look.bare ~name:(name 0) size == drawn.(0));
  check bool "the one used longest ago is drawn again" false
    (Portrait.image cache ~equipment:Look.bare ~name:(name 1) size == drawn.(1));
  let bigger = Option.get (Draw.size_of_int (Draw.min_size * 2)) in
  check bool "another size is another picture" false
    (Portrait.image cache ~equipment:Look.bare ~name:(name 0) bigger == drawn.(0));
  let compact = Portrait.image ~compact:true cache ~equipment:Look.bare ~name:(name 0) size in
  check bool "the compact drawing does not reuse placed pixels" false (compact == drawn.(0));
  check bool "the compact drawing is cached" true
    (Portrait.image ~compact:true cache ~equipment:Look.bare ~name:(name 0) size == compact)

let test_equipment_change_replaces_same_keeper_pixels () =
  let cache = Portrait.cache () in
  let first = Option.get (band ~cache ~display:pixels ~equipment:Look.bare ()) in
  let equipped = {Look.bare with head=Look.Crown; hand=Look.Book} in
  let second = Option.get (band ~cache ~display:pixels ~equipment:equipped ()) in
  check bool "same name and edge reuse neither old pixels nor equipment" false
    (first.Portrait.image == second.Portrait.image);
  let expected = Draw.render (Look.body_of_name alpha) equipped second.Portrait.box.View.size in
  check string "server equipment determines actual pixels" expected.Draw.rgba second.Portrait.image.Draw.rgba;
  let unchanged = Option.get (band ~cache ~display:pixels ~equipment:equipped ()) in
  check bool "unchanged equipment reuses the cache" true (second.Portrait.image == unchanged.Portrait.image);
  let placement band = Option.get (Portrait.placement band ~scroll:0
    ~visible_rows:band.Portrait.box.View.rows ~origin:(4,2)) in
  ignore (frame []);
  ignore (frame [placement first]);
  check string "equipping refreshes the same terminal image id"
    (View.placement_bytes (placement second)) (frame [placement second]);
  check string "unavailable snapshot removes the old picture"
    (Masc_tui_graphics.delete_image ~image_id) (frame [])

let test_mosaic_previews_every_catalog_accessory () =
  let cache = Portrait.cache () in
  let bare = Option.get (band ~cache ()) in
  let full_bare = Draw.render (Look.body_of_name alpha) Look.bare bare.Portrait.box.View.size in
  List.iter (fun item ->
    let equipment = Keeper_portrait_item.preview item Look.bare in
    let shown = Option.get (band ~cache ~equipment ()) in
    let id = Keeper_portrait_item.id item in
    check bool (id ^ " changes the Mosaic portrait") false
      (String.equal bare.Portrait.image.Draw.rgba shown.Portrait.image.Draw.rgba);
    (* Switching drawing style alone must not pass an accessory test. *)
    check bool (id ^ " remains visible beyond a full empty portrait") false
      (String.equal full_bare.Draw.rgba shown.Portrait.image.Draw.rgba))
    Keeper_portrait_item.all

let test_observed_items_remain_visible_in_the_info_mosaic () =
  let cache = Portrait.cache () in
  let bare = Option.get (band ~cache ()) in
  let body = Look.body_of_name alpha in
  let check_equipment label equipment =
    let equipped = Option.get (band ~cache ~equipment ()) in
    check int (label ^ ": retains the mosaic rows") bare.Portrait.box.View.rows
      equipped.Portrait.box.View.rows;
    check int (label ^ ": retains the mosaic columns") bare.Portrait.box.View.cols
      equipped.Portrait.box.View.cols;
    check bool (label ^ ": changes the observed picture") false
      (String.equal bare.Portrait.image.Draw.rgba equipped.Portrait.image.Draw.rgba);
    check bool (label ^ ": changes the emitted terminal cells") false
      (bare.Portrait.lines = equipped.Portrait.lines);
    equipped
  in
  let check_accessory_pixels label equipment equipped =
    let without_accessories =
      Draw.For_testing.render_in_frame_of body Look.bare ~frame_of:equipment
        Draw.still equipped.Portrait.box.View.size
    in
    check bool (label ^ ": accessory changes pixels within the same frame") false
      (String.equal without_accessories.Draw.rgba equipped.Portrait.image.Draw.rgba);
    let without_accessory_cells =
      View.lines ~project View.Mosaic equipped.Portrait.box without_accessories
    in
    check bool (label ^ ": accessory remains visible in terminal cells") false
      (without_accessory_cells = equipped.Portrait.lines)
  in
  List.iter
    (fun item ->
      let equipment = Keeper_portrait_item.preview item Look.bare in
      let label = Keeper_portrait_item.id item in
      let equipped = check_equipment label equipment in
      match Keeper_portrait_item.slot item with
      | Keeper_portrait_item.Base ->
          let expected =
            Draw.render_compact_posed body equipment Draw.still equipped.Portrait.box.View.size
          in
          check string (label ^ ": keeps the compact body and dish")
            expected.Draw.rgba equipped.Portrait.image.Draw.rgba
      | Keeper_portrait_item.Face | Keeper_portrait_item.Neck
      | Keeper_portrait_item.Head | Keeper_portrait_item.Hand ->
          check_accessory_pixels label equipment equipped)
    Keeper_portrait_item.all;
  let outfit = { Look.bare with face = Look.Glasses; neck = Look.Scarf;
                  head = Look.Crown; hand = Look.Book } in
  let equipped = check_equipment "complete outfit" outfit in
  check_accessory_pixels "complete outfit" outfit equipped;
  let restored = Option.get (band ~cache ()) in
  check bool "removing the outfit restores the cached compact body" true
    (restored.Portrait.image == bare.Portrait.image)

let () =
  run "tui_keeper_portrait"
    [ ( "band"
      , [ test_case "a small pane keeps its rows for facts" `Quick
            test_a_small_pane_keeps_its_rows_for_facts
        ; test_case "no picture is no band" `Quick test_no_picture_is_no_band
        ; test_case "the band is compact" `Quick test_the_band_is_compact
        ; test_case "the still portrait the name draws" `Quick
            test_the_still_portrait_the_name_draws
        ; test_case "observed Items remain visible in the Info mosaic" `Quick
            test_observed_items_remain_visible_in_the_info_mosaic
        ; test_case "facts stand beside the portrait" `Quick test_facts_stand_beside_the_portrait
        ] )
    ; ( "placement"
      , [ test_case "pixels go only where the whole portrait shows" `Quick
            test_pixels_go_only_where_the_whole_portrait_shows
        ; test_case "the picture leaves with the detail" `Quick
            test_the_picture_leaves_with_the_detail
        ] )
    ; ("cache", [ test_case "the cache is bounded" `Quick test_the_cache_is_bounded;
        test_case "equipment replaces same Keeper pixels" `Quick test_equipment_change_replaces_same_keeper_pixels;
        test_case "Mosaic previews every catalog accessory" `Quick test_mosaic_previews_every_catalog_accessory ])
    ]
