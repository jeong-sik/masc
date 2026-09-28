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

let pose_at elapsed =
  if Float.is_finite elapsed then Draw.pose_at ~seconds:(Float.max 0.0 elapsed)
  (* A time that is not finite says nothing about where in the loop the
     candle is, so it stands still. *)
  else Draw.still

(* The last picture rendered, by size and pose. A frame that is repainted
   for something else -- the clock, a key -- asks for the pose it already
   drew, and the renderer is the cost of a step. *)
let last_render : (Draw.size * Draw.pose * Draw.image) option ref = ref None

let render size pose =
  match !last_render with
  | Some (s, p, image) when s = size && p = pose -> image
  | Some _ | None ->
      let body, equipment = Keeper_portrait_look.mascot in
      let image = Draw.render_posed body equipment pose size in
      last_render := Some (size, pose, image);
      image

let centred ~cols line =
  let width = Masc_tui_message_layout.display_width line in
  if width >= cols then Masc_tui_message_layout.fit_width line cols
  else String.make ((cols - width) / 2) ' ' ^ line

(* The blank row between the candle and its caption. *)
let caption_gap_rows = 1

let rows ~cols ~rows ~caption ~elapsed ~display ~project ~origin:(origin_row, origin_col) =
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
        let image = render box.View.size (pose_at elapsed) in
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
            View.image_id = View.mascot_image_id;
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

let body ~cols ~rows:height ~caption ~elapsed ~origin =
  let laid_out =
    rows ~cols ~rows:height ~caption ~elapsed ~display:(View.current_display ())
      ~project:Masc_tui_terminal_palette.best_color ~origin
  in
  last_drawn := laid_out.drawn;
  Option.iter View.request laid_out.placement;
  laid_out.lines
