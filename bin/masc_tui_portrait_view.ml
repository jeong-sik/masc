module Draw = Keeper_portrait_draw

type display =
  | Pixels of { cell_width : int; cell_height : int }
  | Mosaic
  | No_picture

(* Most terminal fonts draw a cell twice as tall as it is wide. Only used to
   size a picture's box when the terminal did not report its cell. *)
let default_cell = (10, 20)

let display_of ~kitty ~cell_pixels ~colors_enabled ~projects_colour =
  if not colors_enabled then No_picture
  else if kitty then
    let cell_width, cell_height =
      match cell_pixels with
      | Some (w, h) when w > 0 && h > 0 -> (w, h)
      | Some _ | None -> default_cell
    in
    Pixels { cell_width; cell_height }
  else if projects_colour then Mosaic
  else No_picture

type box = { cols : int; rows : int; size : Draw.size }

(* Under four cell rows a placed picture is a smudge: the face is a pixel or
   two once the terminal scales it into the box. *)
let min_pixel_rows = 4

(* The renderer draws 160 px in about 17 ms and 240 px in about 34 ms
   (#39704). The splash steps every 150 ms, and the terminal scales the
   picture into its box anyway, so 160 keeps a step's render small. *)
let pixel_edge_cap = 160

(* A mosaic draws one pixel per cell across, so its edge is also its width in
   cells; 96 cells is wider than any splash leaves for it. *)
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

(* One placement per image: a second transfer under the same pair replaces
   the picture instead of stacking a copy. *)
let placement_id = 1

let save_cursor = "\0277"
let restore_cursor = "\0278"

let placement_bytes p =
  let transfer =
    Masc_tui_graphics.replace_rgba ~image_id:p.image_id ~placement_id ~data:p.image.Draw.rgba
      ~pixel_width:p.image.Draw.edge ~pixel_height:p.image.Draw.edge ~rows:p.box.rows
  in
  match transfer with
  | "" -> ""
  | bytes ->
      save_cursor
      ^ Printf.sprintf "\027[%d;%dH" (p.row + 1) (p.column + 1)
      ^ bytes ^ restore_cursor

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

let same_picture a b =
  a.row = b.row && a.column = b.column && a.box = b.box
  && a.image.Draw.edge = b.image.Draw.edge
  && String.equal a.image.Draw.rgba b.image.Draw.rgba

let flush ~presented ~write =
  let wanted = !requested in
  List.iter
    (fun shown ->
      if not (List.exists (fun p -> p.image_id = shown.image_id) wanted) then
        write (Masc_tui_graphics.delete_image ~image_id:shown.image_id))
    !on_screen;
  List.iter
    (fun p ->
      let unchanged =
        List.exists (fun shown -> shown.image_id = p.image_id && same_picture shown p) !on_screen
      in
      if presented || not unchanged then write (placement_bytes p))
    wanted;
  on_screen := wanted
