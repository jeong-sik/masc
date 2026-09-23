(* The picture half of a machine spectator: the MSX screen and the DOS screen
   both draw one frame the server handed over, full-terminal, with a title
   row, an optional notice row and a footer row. What differs between them is
   the words (title, footer) and what the keys do; the drawing -- kitty image
   or block mosaic, sizing against the cell, retained pixels -- is this
   module's, so both screens draw a frame the same way.

   Only one spectator owns the terminal at a time, so the retained frame, the
   image id and the size choice are this module's state, not each screen's.

   Write the whole screen directly, because the retained frame underneath
   would otherwise repaint rows over it; the render loop skips its own Render
   step while a spectator is open (the same way it does for [image_open]). *)

module Frame = Masc_tui_image_mosaic

(* Owned only by the serialized TUI loop. Commit after a successful write;
   a failed or interrupted write must force the next frame to repaint. *)
type retained_frame = {
  geometry : int * int * int * int * (int * int) option;
  pixels : Masc_tui_interactive.frame option;
}

let retained : retained_frame option ref = ref None
let invalidate () = retained := None
let image_may_exist = ref false
let image_id = 32
let placement_id = 1
let synchronized_output = ref false
let set_synchronized_output enabled = synchronized_output := enabled
let delete_image = Masc_tui_graphics.delete_image ~image_id

let write_batch ~write payload =
  if !synchronized_output then write ("\027[?2026h" ^ payload ^ "\027[?2026l")
  else write payload

(* Which image protocol this terminal speaks, as the boot probe found it. The
   value is owned by the executable -- the probe runs there and every other
   image surface reads it from the same place -- and set here once so the
   spectators do not need it threaded through each render as a parameter.
   Unsupported until told otherwise, so a terminal that never answered draws
   the mosaic. *)
let graphics_protocol = ref Masc_tui_graphics.Unsupported_protocol

let set_graphics_protocol p =
  invalidate ();
  graphics_protocol := p

(* What the terminal said one character cell measures, or [None] where it did
   not answer. Only the image path reads it: the mosaic already works in cells
   and needs no pixels. *)
let cell_pixels = ref None
let set_cell_pixels px = cell_pixels := px

(* Rows for an image placement that keeps the frame inside the screen.

   Kitty derives the width from the row count, so a row count that fills the
   height can put the width past the right edge, where it is cut. The height
   that fits both is the smaller of the height available and the height the
   available width allows at the frame's own shape; the row count is that
   height in whole cells, rounded down so the last row is not a partial one.

   Without a cell size there is nothing to compute with, and the caller keeps
   the rows it asked for. *)
let rows_that_fit ~cols ~rows ~frame_width ~frame_height =
  match !cell_pixels with
  | Some (cell_width, cell_height)
    when cell_width > 0 && cell_height > 0 && frame_width > 0 && frame_height > 0 ->
      let available_width = cols * cell_width in
      let available_height = rows * cell_height in
      let height_the_width_allows = available_width * frame_height / frame_width in
      let height = min available_height height_the_width_allows in
      max 1 (min rows (height / cell_height))
  | Some _ | None -> rows

let fit_line width s = String.sub s 0 (min (String.length s) (max width 1))

(* How much of the terminal the picture takes: 1.0 fills the screen, and the
   size keys step it in eighths between a quarter and full. A local view
   choice -- the machine and its frame are the server's; this only says how
   big this terminal draws them. *)
let size_steps = 8.0
let smallest_size_steps = 2.0
let screen_fraction = ref 1.0

(* One step by the size keys: [+1.0] grows, [-1.0] shrinks, an eighth of the
   screen each way. *)
let adjust_size d =
  let steps = Float.round (!screen_fraction *. size_steps) +. d in
  screen_fraction :=
    Float.min size_steps (Float.max smallest_size_steps steps) /. size_steps

let size_percent () = int_of_float (!screen_fraction *. 100.0)

(* The fewest rows the body keeps, and the fewest the picture keeps, however
   small the terminal is. *)
let minimum_screen_rows = 4
let minimum_picture_rows = 2

(* Draws [title], [notice] when there is one, the picture, and [footer] on the
   terminal's last row. [retain] says the picture is a machine's frame worth
   repainting from ([last_surface]); an empty screen is not retained, so the
   next frame is drawn in full. *)
let draw ~(write : string -> unit) ~title ?notice ~footer ~retain
    (surface : Masc_tui_interactive.frame option) =
  let dims =
    match surface with
    | Some (Pixels { width; height; rgb }) -> Some (width, height, rgb)
    | None -> None
  in
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  let header_rows = if Option.is_some notice then 2 else 1 in
  let screen_rows = max minimum_screen_rows (rows - header_rows - 1) in
  let picture_rows =
    max minimum_picture_rows
      ((screen_rows * int_of_float (Float.round (!screen_fraction *. size_steps)))
       / int_of_float size_steps)
  in
  let geometry = (rows, cols, header_rows, picture_rows, !cell_pixels) in
  let kitty = match dims, !graphics_protocol with
    | Some (width, height, rgb), Masc_tui_graphics.Kitty_protocol ->
        width > 0 && height > 0 && String.length rgb = width * height * 3
    | _ -> false
  in
  let previous = !retained in
  (* Invalidate before output so even a partially written batch cannot be
     mistaken for an accepted frame on the next call. *)
  invalidate ();
  let same_layout = match previous, dims with
    | Some old, Some (width, height, _) when kitty ->
        old.geometry = geometry
        && (match old.pixels with
            | Some (Pixels p) -> p.width = width && p.height = height
            | _ -> false)
    | _ -> false
  in
  let same_pixels = match previous, dims with
    | Some old, Some (_, _, rgb) when same_layout ->
        (match old.pixels with
         | Some (Pixels p) -> String.equal p.rgb rgb
         | _ -> false)
    | _ -> false
  in
  let buf = Buffer.create 1024 in
  if same_layout then Buffer.add_string buf "\027[H"
  else begin
    if kitty || !image_may_exist then Buffer.add_string buf delete_image;
    Buffer.add_string buf "\027[2J\027[H"
  end;
  Buffer.add_string buf (fit_line cols title);
  Buffer.add_string buf "\027[0K\r\n";
  (* A notice carries text from the server or the transport -- an HTML error
     body, an exception -- so it is made one clean line before it is drawn. *)
  Option.iter
    (fun message ->
      Buffer.add_string buf
        (fit_line cols (" " ^ Masc_tui_ansi.Terminal_text.single_line message));
      Buffer.add_string buf "\027[0K\r\n")
    notice;
  let blank_row () = Buffer.add_string buf "\027[0K\r\n" in
  (match dims with
   | Some (width, height, rgb) when kitty ->
       (* Keep full RGB detail. Stable image and placement IDs replace the
          previous picture; unchanged pixels need no encoding or transfer. *)
       let drawn_rows =
         rows_that_fit ~cols ~rows:picture_rows ~frame_width:width
           ~frame_height:height
       in
       (* The image is drawn where the cursor sits, so a smaller picture
          starts mid-screen: park the cursor on its first row, centred, and
          the footer still lands on the screen's last row. *)
       Buffer.add_string buf
         (Printf.sprintf "\027[%d;1H" (header_rows + 1 + ((screen_rows - drawn_rows) / 2)));
       let escape =
         if same_pixels then "" else
         Masc_tui_graphics.replace_rgb ~image_id ~placement_id ~data:rgb ~pixel_width:width
           ~pixel_height:height ~rows:drawn_rows
       in
       Buffer.add_string buf escape;
       Buffer.add_string buf (Printf.sprintf "\027[%d;1H" (header_rows + screen_rows + 1))
   | Some (width, height, rgb)
     when width > 0 && height > 0 && String.length rgb >= width * height * 3 ->
       (* The machine's frame has a shape of its own -- 256x192 for the MSX,
          640x400 or 640x480 for DOS -- and the terminal has another. Fitting
          the grid to the terminal alone drew that shape stretched to whatever
          the window happened to be. The grid keeps the frame's ratio and the
          leftover rows and columns stay blank, so the picture is the
          picture. *)
       let pcols, prows =
         Frame.fit_grid ~src_w:width ~src_h:height ~max_cols:cols
           ~max_rows:(2 * picture_rows)
       in
       let lines =
         Frame.render ~cols:pcols ~rows:prows
           (Frame.downscale ~src_w:width ~src_h:height ~cols:pcols
              ~rows:prows rgb)
       in
       let drawn = List.length lines in
       let above = (screen_rows - drawn) / 2 in
       let left = String.make ((cols - pcols) / 2) ' ' in
       for _ = 1 to above do blank_row () done;
       List.iter
         (fun line ->
           Buffer.add_string buf left;
           Buffer.add_string buf line;
           blank_row ())
         lines;
       for _ = 1 to screen_rows - drawn - above do blank_row () done
   | Some _ | None ->
       (* Nothing to draw: clear the body so a stale frame does not linger. *)
       for _ = 1 to screen_rows do blank_row () done);
  Buffer.add_string buf (fit_line cols footer);
  Buffer.add_string buf "\027[0K";
  image_may_exist := !image_may_exist || kitty;
  write_batch ~write (Buffer.contents buf);
  image_may_exist := kitty;
  (* Always retained, not just Kitty: a repaint redraws the last surface
     frame, and the mosaic path needs it too. *)
  if retain then retained := Some { geometry; pixels = surface }
;;

(* The last surface a draw retained -- a repaint redraws it. *)
let last_surface () =
  match !retained with Some r -> r.pixels | None -> None
;;

(* The spectator hands the terminal back: forget the retained frame and take
   the image off the screen, so the surface underneath is not drawn under a
   stale picture. *)
let release ~(write : string -> unit) =
  invalidate ();
  if !image_may_exist then write_batch ~write delete_image;
  image_may_exist := false
;;

(* A text screen drawn in the spectator's place (the MSX load menu): it clears
   any picture first, lets [fill] write the rows, and leaves no image behind. *)
let draw_text_screen ~(write : string -> unit) (fill : Buffer.t -> unit) =
  invalidate ();
  let buf = Buffer.create 1024 in
  if !image_may_exist then Buffer.add_string buf delete_image;
  Buffer.add_string buf "\027[2J\027[H";
  fill buf;
  write_batch ~write (Buffer.contents buf);
  image_may_exist := false
;;
