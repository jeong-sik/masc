module Draw = Keeper_portrait_draw

type display =
  | Pixels of { cell_width : int; cell_height : int }
  | Mosaic
  | No_picture

(* A placed picture's box is counted in cells from the cell size, and the
   terminal scales the picture into it. Without a size the box would be a
   guess that lands the picture beside or over the text around it, so a
   Kitty terminal that did not say draws the mosaic, which is laid out in
   cells. *)
let display_of ~kitty ~cell_pixels ~colors_enabled ~projects_colour =
  if not colors_enabled then No_picture
  else
    match kitty, cell_pixels with
    | true, Some (cell_width, cell_height) when cell_width > 0 && cell_height > 0 ->
        Pixels { cell_width; cell_height }
    | true, (Some _ | None) | false, _ -> if projects_colour then Mosaic else No_picture

type box = { cols : int; rows : int; size : Draw.size }

(* Under four cell rows a placed picture is a smudge: the face is a pixel or
   two once the terminal scales it into the box. *)
let min_pixel_rows = 4

(* The renderer draws 160 px in about 17 ms and 240 px in about 34 ms
   (#39704). The /about candle steps every 150 ms, and the terminal scales the
   picture into its box anyway, so 160 keeps a step's render small. *)
let pixel_edge_cap = 160

(* A mosaic draws one pixel per cell across, so its edge is also its width in
   cells; 96 cells is wider than any portrait surface leaves for it. *)
let mosaic_edge_cap = 96

let clamp lo hi v = max lo (min hi v)

let fit display ~max_cols ~max_rows =
  match display with
  | No_picture -> None
  | Pixels { cell_width; cell_height } ->
      (* Square picture: [rows] cells tall is [rows * cell_height] pixels,
         and as many pixels across takes that many over [cell_width] cells. *)
      let rows = min max_rows (max_cols * cell_width / cell_height) in
      if rows < min_pixel_rows then None
      else
        let cols = ((rows * cell_height) + cell_width - 1) / cell_width in
        Draw.size_of_int (clamp Draw.min_size pixel_edge_cap (rows * cell_height))
        |> Option.map (fun size -> { cols; rows; size })
  | Mosaic ->
      (* One pixel across per cell, two down; the edge is kept even so every
         cell row stacks two pixel rows. *)
      let edge = min mosaic_edge_cap (min max_cols (2 * max_rows)) in
      let edge = edge - (edge land 1) in
      Draw.size_of_int edge |> Option.map (fun size -> { cols = edge; rows = edge / 2; size })

let lines ~project display box image =
  match display with
  | No_picture -> []
  | Pixels _ -> List.init box.rows (fun _ -> String.make box.cols ' ')
  | Mosaic ->
      Masc_tui_image_mosaic.render_rgba ~project ~cols:image.Draw.edge
        ~rows:image.Draw.edge image.Draw.rgba

type placement = {
  image_id : int;
  row : int;
  column : int;
  box : box;
  image : Draw.image;
}

(* A picture the terminal is asked to show: where, how many cells, and what
   the pixels are. The candle portraits are RGBA frames this process drew; an
   evidence picture is a PNG file as it arrived. Both are placed, kept, moved
   and deleted by the same bookkeeping below, so the two kinds cannot disagree
   about when a clear screen or a rewritten row costs a picture. *)
type source =
  | Candle_pixels of Draw.image
  | Png_file of { data : string; key : string }

type entry = {
  e_id : int;
  e_row : int;
  e_column : int;
  e_cols : int;
  e_rows : int;
  e_crop : Masc_tui_graphics.crop option;
  e_source : source;
}

let entry_of_placement p =
  { e_id = p.image_id; e_row = p.row; e_column = p.column; e_cols = p.box.cols;
    e_rows = p.box.rows; e_crop = None; e_source = Candle_pixels p.image }

type png_placement = {
  png_image_id : int;
  png_row : int;
  png_column : int;
  png_cols : int;
  png_rows : int;
  png_crop : Masc_tui_graphics.crop option;
  png_key : string;
  png_data : string;
}

let entry_of_png p =
  { e_id = p.png_image_id; e_row = p.png_row; e_column = p.png_column;
    e_cols = p.png_cols; e_rows = p.png_rows; e_crop = p.png_crop;
    e_source = Png_file { data = p.png_data; key = p.png_key } }

(* One placement per image: a second transfer or put under the same pair
   replaces the picture instead of stacking a copy. *)
let placement_id = 1

let save_cursor = "\0277"
let restore_cursor = "\0278"

let at_corner e bytes =
  save_cursor
  ^ Printf.sprintf "\027[%d;%dH" (e.e_row + 1) (e.e_column + 1)
  ^ bytes ^ restore_cursor

let entry_bytes e =
  let pixels =
    match e.e_source with
    | Candle_pixels image ->
        Masc_tui_graphics.replace_rgba ~image_id:e.e_id ~placement_id ~data:image.Draw.rgba
          ~pixel_width:image.Draw.edge ~pixel_height:image.Draw.edge ~rows:e.e_rows
    | Png_file { data; key = _ } ->
        Masc_tui_graphics.replace_png ~image_id:e.e_id ~placement_id ~data ~rows:e.e_rows
          ~cols:e.e_cols ~crop:e.e_crop
  in
  match pixels with
  | "" -> ""
  | bytes -> at_corner e bytes

let entry_put_bytes e =
  at_corner e
    (match e.e_source with
     | Candle_pixels _ -> Masc_tui_graphics.put ~image_id:e.e_id ~placement_id ~rows:e.e_rows
     | Png_file _ ->
         Masc_tui_graphics.put_png ~image_id:e.e_id ~placement_id ~rows:e.e_rows
           ~cols:e.e_cols ~crop:e.e_crop)

let placement_bytes p = entry_bytes (entry_of_placement p)
let put_bytes p = entry_put_bytes (entry_of_placement p)

let display = ref No_picture
let set_display d = display := d
let current_display () = !display

(* What the frame being built asked for, newest first, and what the terminal
   was last sent, one entry per image id. *)
let requested : entry list ref = ref []
let on_screen : entry list ref = ref []

(* Pictures the view still has but shows none of this frame (scrolled wholly
   out of the window), as (image id, key). Their pixels stay with the terminal
   without a placement, so scrolling back is a [put], not a transfer. *)
let held : (int * string) list ref = ref []

(* Pictures whose pixels the terminal holds without a placement. *)
let unplaced : entry list ref = ref []

let begin_frame () =
  requested := [];
  held := []

let request_entry e =
  requested := e :: List.filter (fun q -> q.e_id <> e.e_id) !requested

let request p = request_entry (entry_of_placement p)
let request_png p = request_entry (entry_of_png p)

let hold_png ~image_id ~key = held := (image_id, key) :: !held

type send =
  | Keep
  | Put
  | Transmit

(* Equal keys stand for equal bytes, so a 200 KB picture is not compared
   byte by byte on every frame. *)
let same_pixels a b =
  match a.e_source, b.e_source with
  | Candle_pixels x, Candle_pixels y ->
      x.Draw.edge = y.Draw.edge && String.equal x.Draw.rgba y.Draw.rgba
  | Png_file x, Png_file y -> String.equal x.key y.key
  | Candle_pixels _, Png_file _ | Png_file _, Candle_pixels _ -> false

let same_place a b =
  a.e_row = b.e_row && a.e_column = b.e_column && a.e_cols = b.e_cols && a.e_rows = b.e_rows
  && a.e_crop = b.e_crop

let crosses rows e = List.exists (fun row -> row >= e.e_row && row < e.e_row + e.e_rows) rows

(* The protocol (kitty graphics-protocol, "Interaction with other terminal
   actions"): the clear screen escape clears every image, and "the other
   commands to erase text must have no effect on graphics". Kitty and
   Ghostty go further on a clear and free the pixels of an image left
   without placements, so after one only a transfer brings it back. A row
   erased and written again leaves Kitty and Ghostty's placement standing,
   but WezTerm ties a placement to the cells it covered when placed and
   text written over them takes those parts of the picture (wezterm #986);
   a put restores them from the pixels it still holds, in a few dozen
   bytes, and is a no-op replacement where nothing was taken. *)
let send_entry presented ~shown e =
  match shown with
  | None -> Transmit
  | Some shown -> (
      if not (same_pixels shown e) then Transmit
      else
        match presented with
        | Masc_tui_frame_presenter.Presented Masc_tui_frame_presenter.Whole_screen -> Transmit
        | Masc_tui_frame_presenter.Presented (Masc_tui_frame_presenter.Rows rows) ->
            if same_place shown e && not (crosses rows e) then Keep else Put
        | Masc_tui_frame_presenter.Unchanged -> if same_place shown e then Keep else Put)

let send presented ~shown p =
  send_entry presented ~shown:(Option.map entry_of_placement shown) (entry_of_placement p)

let is_held e =
  match e.e_source with
  | Png_file { key; _ } -> List.exists (fun (id, k) -> id = e.e_id && String.equal k key) !held
  | Candle_pixels _ -> false

let flush presented ~write =
  let wanted = !requested in
  let is_wanted e = List.exists (fun w -> w.e_id = e.e_id) wanted in
  (* A clear screen takes the pixels of an image left without placements, so
     after one nothing is held. *)
  let cleared =
    match presented with
    | Masc_tui_frame_presenter.Presented Masc_tui_frame_presenter.Whole_screen -> true
    | Masc_tui_frame_presenter.Presented (Masc_tui_frame_presenter.Rows _)
    | Masc_tui_frame_presenter.Unchanged -> false
  in
  if cleared then unplaced := [];
  let shown_under id = List.find_opt (fun shown -> shown.e_id = id) !on_screen in
  let previously_unplaced = !unplaced in
  let unplaced_under id = List.find_opt (fun held -> held.e_id = id) previously_unplaced in
  let newly_unplaced = ref [] in
  List.iter
    (fun shown ->
      if not (is_wanted shown) then
        if is_held shown && not cleared then begin
          write (Masc_tui_graphics.delete_placement ~image_id:shown.e_id ~placement_id);
          newly_unplaced := shown :: !newly_unplaced
        end
        else write (Masc_tui_graphics.delete_image ~image_id:shown.e_id))
    !on_screen;
  (* Pixels held for a picture the view dropped, or replaced by other bytes. *)
  List.iter
    (fun kept ->
      if (not (is_wanted kept)) && not (is_held kept) then
        write (Masc_tui_graphics.delete_image ~image_id:kept.e_id))
    previously_unplaced;
  unplaced :=
    List.filter (fun kept -> (not (is_wanted kept)) && is_held kept) previously_unplaced
    @ !newly_unplaced;
  on_screen :=
    List.filter_map
      (fun e ->
        let transmit ~stale =
          match entry_bytes e with
          | "" ->
              (* Nothing of this picture reached the terminal. An older one
                 under the same id would stand where this one is not, so it
                 comes down, and the next frame tries this one again. *)
              Option.iter
                (fun stale -> write (Masc_tui_graphics.delete_image ~image_id:stale.e_id))
                stale;
              None
          | bytes ->
              write bytes;
              Some e
        in
        match shown_under e.e_id, unplaced_under e.e_id with
        | Some shown, _ -> (
            match send_entry presented ~shown:(Some shown) e with
            | Keep -> Some e
            | Put ->
                write (entry_put_bytes e);
                Some e
            | Transmit -> transmit ~stale:(Some shown))
        | None, Some kept ->
            if same_pixels kept e then begin
              write (entry_put_bytes e);
              Some e
            end
            else transmit ~stale:(Some kept)
        | None, None -> transmit ~stale:None)
      wanted
