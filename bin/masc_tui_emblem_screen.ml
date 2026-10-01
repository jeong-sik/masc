module View = Masc_tui_portrait_view
module Draw = Keeper_portrait_draw

type drawn =
  | Moving
  | Still
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
  | Compact_at of Draw.size * Draw.pose
  | Dotted_at of Draw.size * int

let key_of style display box moment =
  match style, display with
  | Painted, View.Mosaic -> Compact_at (box.View.size, pose_of moment)
  | Painted, (View.Pixels _ | View.No_picture) -> Painted_at (box.View.size, pose_of moment)
  | Dotted, _ -> Dotted_at (dotted_size display box, sway_milliseconds_of moment)

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
        | Compact_at (size, pose) ->
            let body, equipment = Keeper_portrait_look.mascot in
            Draw.render_compact_posed body equipment pose size
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

(* The 150 ms motion step shared with the TUI reaches this frame after
   2.1 seconds. It is a terminal state: no later frame asks for a repaint. *)
let final_frame = 14

(* Only the candle changes pose during the arrival. Keeper portraits already
   use their 32-entry still-image cache; these sixteen entries cap the candle
   at 16 * 512 * 512 * 4 = 16,777,216 RGBA bytes in the largest dotted mode.
   The ordinary candle renderer still keeps only its last picture. *)
let about_frame_capacity = 16
let about_frame_cache : (picture_key * Draw.image) list ref = ref []
let about_cached_frames () = List.length !about_frame_cache

let render_about key =
  match List.assoc_opt key !about_frame_cache with
  | Some image -> image
  | None ->
      let image = render key in
      about_frame_cache :=
        (key, image) :: !about_frame_cache
        |> List.filteri (fun index _ -> index < about_frame_capacity);
      image

type about_laid_out = {
  drawn : drawn;
  lines : string list;
  placements : View.placement list;
  visible_keepers : int;
}

type scene_piece = {
  left : int;
  image_id : int;
  box : View.box;
  image : Draw.image;
  lines : string list;
}

let about_keeper_image_id = function
  | 0 -> Masc_tui_graphics.image_id Masc_tui_graphics.About_keeper_1
  | 1 -> Masc_tui_graphics.image_id Masc_tui_graphics.About_keeper_2
  | 2 -> Masc_tui_graphics.image_id Masc_tui_graphics.About_keeper_3
  | _ -> Masc_tui_graphics.image_id Masc_tui_graphics.About_keeper_4

(* Newest portrait by name and edge, with the existing 32-entry bound. At the
   largest pixel box here (160 square), this holds at most 3,276,800 RGBA
   bytes. The scene does not cache a frame for every animation tick. *)
let about_portraits = Masc_tui_keeper_portrait.cache ()

let about_rows ~style ~cols ~rows ~caption ~frame ~keepers
    ~display ~project ~origin:(origin_row, origin_col) =
  let picture_box =
    View.fit display ~max_cols:16 ~max_rows:(min 8 (max 0 (rows - List.length caption - 2)))
  in
  let picture_rows = match picture_box with Some box -> box.View.rows | None -> 0 in
  let max_portraits =
    match picture_box with
    | Some box when cols >= 5 * box.View.cols -> 4
    | Some box when cols >= 3 * box.View.cols -> 2
    | Some _ -> 0
    | None -> 4
  in
  let name_budget =
    max 0 (rows - picture_rows - List.length caption - (if picture_rows > 0 then 2 else 1))
  in
  let rec choose chosen used = function
    | ((name, _) as keeper) :: rest when List.length chosen < max_portraits ->
        let wrapped = Masc_tui_message_layout.wrap_words ~max_cells:(max 1 cols) name in
        let overflow_rows = if rest = [] then 0 else 1 in
        if used + List.length wrapped + overflow_rows <= name_budget then
          choose (keeper :: chosen) (used + List.length wrapped) rest
        else List.rev chosen
    | _ -> List.rev chosen
  in
  let visible = choose [] 0 keepers in
  let visible_count = List.length visible in
  let hidden_count = max 0 (List.length keepers - visible_count) in
  let frame = max 0 (min final_frame frame) in
  let proximity =
    if frame <= 7 then frame else if frame < final_frame then final_frame - frame else 0
  in
  let pieces =
    match picture_box with
    | None -> []
    | Some box ->
        let edge = box.View.cols in
        let centre = (cols - edge) / 2 in
        let candle =
          { left = centre;
            image_id = Masc_tui_graphics.image_id Masc_tui_graphics.Mascot;
            box;
            image = render_about (key_of style display box
              (if frame = final_frame then Held else At (frame * 150)));
            lines = [] }
        in
        let spread, gathered =
          match visible_count with
          | 0 -> ([], [])
          | 1 -> ([0], [centre - edge])
          | 2 -> ([0; cols - edge], [centre - edge; centre + edge])
          | 3 ->
              ([0; edge; cols - edge],
               [centre - (2 * edge); centre - edge; centre + edge])
          | _ ->
              ([0; edge; cols - (2 * edge); cols - edge],
               [centre - (2 * edge); centre - edge; centre + edge; centre + (2 * edge)])
        in
        let portraits =
          List.mapi
            (fun index (name, portrait) ->
              match portrait with
              | Keeper_portrait_equipment.Unavailable _ -> None
              | Keeper_portrait_equipment.Ready equipment ->
                  let far = List.nth spread index in
                  let near = List.nth gathered index in
                  let left = far + ((near - far) * proximity / 7) in
                  Some { left;
                    image_id = about_keeper_image_id index;
                    box;
                    image = Masc_tui_keeper_portrait.image about_portraits ~name ~equipment box.View.size;
                    lines = [] })
            visible
          |> List.filter_map Fun.id
        in
        List.map
          (fun piece ->
            { piece with lines = View.lines ~project display piece.box piece.image })
          (candle :: portraits)
  in
  let pieces = List.sort (fun a b -> Int.compare a.left b.left) pieces in
  let picture_lines =
    List.init picture_rows (fun row ->
      let rec gather column = function
        | [] -> ""
        | piece :: rest ->
            let left = max column piece.left in
            String.make (left - column) ' '
            ^ List.nth piece.lines row
            ^ gather (left + piece.box.View.cols) rest
      in
      gather 0 pieces)
  in
  let names =
    List.concat_map
      (Masc_tui_message_layout.wrap_words ~max_cells:(max 1 cols))
      (List.map fst visible)
    |> List.map (centred ~cols)
  in
  let overflow =
    if hidden_count = 0 then []
    else [centred ~cols (Printf.sprintf "+%d more Keepers" hidden_count)]
  in
  let gap = if picture_lines = [] then [] else [""] in
  let block = picture_lines @ gap @ names @ overflow @ List.map (centred ~cols) caption in
  let top = max 0 ((rows - List.length block) / 2) in
  let lines =
    List.filteri (fun index _ -> index < max 0 rows)
      (List.init top (fun _ -> "") @ block)
  in
  let placements =
    match display with
    | View.Pixels _ ->
        List.map
          (fun piece ->
            { View.image_id = piece.image_id;
              row = origin_row + top;
              column = origin_col + piece.left;
              box = piece.box;
              image = piece.image })
          pieces
    | View.Mosaic | View.No_picture -> []
  in
  { drawn = (if pieces = [] then Absent else if frame = final_frame then Still else Moving);
    lines; placements; visible_keepers = visible_count }

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

let about_body ~cols ~rows:height ~caption ~frame ~keepers ~origin =
  let laid_out =
    about_rows ~style:!chosen_style ~cols ~rows:height ~caption ~frame
      ~keepers ~display:(View.current_display ())
      ~project:Masc_tui_terminal_palette.best_color ~origin
  in
  last_drawn := laid_out.drawn;
  List.iter View.request laid_out.placements;
  laid_out.lines
