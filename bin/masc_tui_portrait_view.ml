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

(* One placement per image: a second transfer or put under the same pair
   replaces the picture instead of stacking a copy. *)
let placement_id = 1

let save_cursor = "\0277"
let restore_cursor = "\0278"

let at_corner p bytes =
  save_cursor
  ^ Printf.sprintf "\027[%d;%dH" (p.row + 1) (p.column + 1)
  ^ bytes ^ restore_cursor

let placement_bytes p =
  match
    Masc_tui_graphics.replace_rgba ~image_id:p.image_id ~placement_id ~data:p.image.Draw.rgba
      ~pixel_width:p.image.Draw.edge ~pixel_height:p.image.Draw.edge ~rows:p.box.rows
  with
  | "" -> ""
  | bytes -> at_corner p bytes

let put_bytes p =
  at_corner p (Masc_tui_graphics.put ~image_id:p.image_id ~placement_id ~rows:p.box.rows)

let display = ref No_picture
let set_display d = display := d
let current_display () = !display

(* What the frame being built asked for, newest first, and what the terminal
   was last sent, one entry per image id. *)
let requested : placement list ref = ref []
let on_screen : placement list ref = ref []

let begin_frame () = requested := []

let request p =
  requested := p :: List.filter (fun q -> q.image_id <> p.image_id) !requested

type send =
  | Keep
  | Put
  | Transmit

let same_pixels a b =
  a.image.Draw.edge = b.image.Draw.edge && String.equal a.image.Draw.rgba b.image.Draw.rgba

let same_place a b = a.row = b.row && a.column = b.column && a.box = b.box

let crosses rows p = List.exists (fun row -> row >= p.row && row < p.row + p.box.rows) rows

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
let send presented ~shown p =
  match shown with
  | None -> Transmit
  | Some shown -> (
      if not (same_pixels shown p) then Transmit
      else
        match presented with
        | Masc_tui_frame_presenter.Presented Masc_tui_frame_presenter.Whole_screen -> Transmit
        | Masc_tui_frame_presenter.Presented (Masc_tui_frame_presenter.Rows rows) ->
            if same_place shown p && not (crosses rows p) then Keep else Put
        | Masc_tui_frame_presenter.Unchanged -> if same_place shown p then Keep else Put)

let flush presented ~write =
  let wanted = !requested in
  let shown_under image_id = List.find_opt (fun shown -> shown.image_id = image_id) !on_screen in
  List.iter
    (fun shown ->
      if not (List.exists (fun p -> p.image_id = shown.image_id) wanted) then
        write (Masc_tui_graphics.delete_image ~image_id:shown.image_id))
    !on_screen;
  on_screen :=
    List.filter_map
      (fun p ->
        let shown = shown_under p.image_id in
        match send presented ~shown p with
        | Keep -> Some p
        | Put ->
            write (put_bytes p);
            Some p
        | Transmit -> (
            match placement_bytes p with
            | "" ->
                (* Nothing of this picture reached the terminal. An older one
                   under the same id would stand where this one is not, so it
                   comes down, and the next frame tries this one again. *)
                Option.iter
                  (fun shown -> write (Masc_tui_graphics.delete_image ~image_id:shown.image_id))
                  shown;
                None
            | bytes ->
                write bytes;
                Some p))
      wanted
