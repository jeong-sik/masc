module View = Masc_tui_portrait_view
module Draw = Keeper_portrait_draw

type drawn =
  | Moving
  | Absent

type laid_out = {
  drawn : drawn;
  lines : string list;
  placement : View.placement option;
}

type style =
  | Painted
  | Dotted

let style_of_string = function
  | "painted" -> Some Painted
  | "dotted" -> Some Dotted
  | _ -> None

let string_of_style = function
  | Painted -> "painted"
  | Dotted -> "dotted"

let next_style = function
  | Painted -> Dotted
  | Dotted -> Painted

let milliseconds_per_second = 1000.0

(* Where on its loop the candle is drawn. A time that is not finite says
   nothing about where that is, so the candle stands still. *)
type moment =
  | At of int
  | Held

let moment_of elapsed =
  if Float.is_finite elapsed then
    (* Past the int range (some 146 million years on screen) the moment is
       unspecified, but every int is a moment of the loop. *)
    At (Float.to_int (Float.round (Float.max 0.0 elapsed *. milliseconds_per_second)))
  else Held

let pose_of = function
  | At milliseconds -> Draw.pose_at ~milliseconds
  | Held -> Draw.still

(* A dotted candle held still faces front: the start of its sway. *)
let sway_milliseconds_of = function
  | At milliseconds -> milliseconds mod Keeper_portrait_solid.sway_period_ms
  | Held -> 0

(* A dotted candle is drawn as many pixels tall as the terminal shows it, so
   the terminal never scales it and every dot stays a square. A mosaic draws
   one pixel a cell, which is the box's own size. *)
let dotted_size display (box : View.box) =
  match display with
  | View.Pixels { cell_height; cell_width = _ } -> (
      let shown = Int.max Draw.min_size (Int.min Draw.max_size (box.View.rows * cell_height)) in
      match Draw.size_of_int shown with
      | Some size -> size
      (* [shown] is inside the range size_of_int accepts. *)
      | None -> box.View.size)
  | View.Mosaic | View.No_picture -> box.View.size

type picture_key =
  | Painted_at of Draw.size * Draw.pose
  | Dotted_at of Draw.size * int

let key_of style display box moment =
  match style with
  | Painted -> Painted_at (box.View.size, pose_of moment)
  | Dotted -> Dotted_at (dotted_size display box, sway_milliseconds_of moment)

(* The last picture rendered. A frame that is repainted for something else
   -- the clock, a key -- asks for the picture it already drew, and the
   renderer is the cost of a step. *)
let last_render : (picture_key * Draw.image) option ref = ref None

let render key =
  match !last_render with
  | Some (drawn, image) when drawn = key -> image
  | Some _ | None ->
      let image =
        match key with
        | Painted_at (size, pose) ->
            let body, equipment = Keeper_portrait_look.mascot in
            Draw.render_posed body equipment pose size
        | Dotted_at (size, milliseconds) -> Keeper_portrait_solid.mascot ~milliseconds size
      in
      last_render := Some (key, image);
      image

let centred ~cols line =
  let width = Masc_tui_message_layout.display_width line in
  if width >= cols then Masc_tui_message_layout.fit_width line cols
  else String.make ((cols - width) / 2) ' ' ^ line

(* The blank row between the candle and its caption. *)
let caption_gap_rows = 1

let rows ~style ~cols ~rows ~caption ~elapsed ~display ~project ~origin:(origin_row, origin_col) =
  let caption_rows = List.length caption in
  let picture_rows =
    match caption with
    | [] -> rows
    | _ :: _ -> rows - caption_rows - caption_gap_rows
  in
  let picture =
    match View.fit display ~max_cols:cols ~max_rows:picture_rows with
    | None -> None
    | Some box ->
        let image = render (key_of style display box (moment_of elapsed)) in
        Some (box, image, View.lines ~project display box image)
  in
  let picture_lines, left =
    match picture with
    | None -> ([], 0)
    | Some (box, _, lines) ->
        let left = (cols - box.View.cols) / 2 in
        (List.map (fun line -> String.make left ' ' ^ line) lines, left)
  in
  let block =
    match picture_lines, caption with
    | [], _ | _, [] -> picture_lines @ List.map (centred ~cols) caption
    | _ :: _, _ :: _ ->
        picture_lines
        @ List.init caption_gap_rows (fun _ -> "")
        @ List.map (centred ~cols) caption
  in
  let top = Int.max 0 ((rows - List.length block) / 2) in
  let lines =
    List.filteri (fun index _ -> index < Int.max 0 rows) (List.init top (fun _ -> "") @ block)
  in
  let placement =
    match picture, display with
    | Some (box, image, _), View.Pixels _ ->
        Some
          {
            View.image_id = Masc_tui_graphics.image_id Masc_tui_graphics.Mascot;
            row = origin_row + top;
            column = origin_col + left;
            box;
            image;
          }
    | Some _, (View.Mosaic | View.No_picture) | None, _ -> None
  in
  { drawn = (match picture with Some _ -> Moving | None -> Absent); lines; placement }

type keeper_count =
  | Keepers_read of int
  | Keepers_unreadable
  | Keepers_unread

let about_facts ~theme keepers =
  let count =
    match keepers with
    | Keepers_read count -> string_of_int count
    | Keepers_unreadable -> "unavailable"
    | Keepers_unread -> "not loaded"
  in
  Printf.sprintf "Theme: %s  \xc2\xb7  Keepers: %s" theme count

let last_drawn = ref Absent
let begin_frame () = last_drawn := Absent
let drawn () = !last_drawn
let chosen_style = ref Painted
let set_style style = chosen_style := style
let style () = !chosen_style

let body ~cols ~rows:height ~caption ~elapsed ~origin =
  let laid_out =
    rows ~style:!chosen_style ~cols ~rows:height ~caption ~elapsed
      ~display:(View.current_display ()) ~project:Masc_tui_terminal_palette.best_color ~origin
  in
  last_drawn := laid_out.drawn;
  Option.iter View.request laid_out.placement;
  laid_out.lines
