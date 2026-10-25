type t = { width : int; height : int; zoom : float; center_x : float; center_y : float }
type action = Zoom_in | Zoom_out | Fit | Left | Right | Up | Down
type window = { x : int; y : int; width : int; height : int;
  columns : int; rows : int }
let create ~width ~height =
  if width <= 0 || height <= 0 then None
  else Some {width;height;zoom=1.;center_x=float_of_int width/.2.;center_y=float_of_int height/.2.}
let zoom t = t.zoom
let clamp lower upper value = max lower (min upper value)
let window ~cell_pixels:(cw,ch) ~columns ~rows (t : t) =
  let cw = max 1 cw and ch = max 1 ch in
  let columns = max 1 columns and rows = max 1 rows in
  let iw = float_of_int t.width and ih = float_of_int t.height in
  let fit = min (float_of_int columns *. float_of_int cw /. iw)
    (float_of_int rows *. float_of_int ch /. ih) in
  let scale = fit *. t.zoom in
  let width = if t.zoom = 1. then t.width else
    max 1 (min t.width (int_of_float (floor (float_of_int columns *. float_of_int cw /. scale)))) in
  let height = if t.zoom = 1. then t.height else
    max 1 (min t.height (int_of_float (floor (float_of_int rows *. float_of_int ch /. scale)))) in
  let x = clamp 0 (t.width-width) (int_of_float (floor (t.center_x -. float_of_int width/.2.))) in
  let y = clamp 0 (t.height-height) (int_of_float (floor (t.center_y -. float_of_int height/.2.))) in
  {x;y;width;height;
   columns=max 1 (min columns (int_of_float (ceil (float_of_int width *. scale /. float_of_int cw))));
   rows=max 1 (min rows (int_of_float (ceil (float_of_int height *. scale /. float_of_int ch))))}
let apply ~cell_pixels ~columns ~rows action (t : t) =
  let shown = window ~cell_pixels ~columns ~rows t in
  let center_x = float_of_int shown.x +. float_of_int shown.width /. 2. in
  let center_y = float_of_int shown.y +. float_of_int shown.height /. 2. in
  let x_step = max 1. (float_of_int shown.width /. float_of_int shown.columns) in
  let y_step = max 1. (float_of_int shown.height /. float_of_int shown.rows) in
  match action with
  | Fit -> {t with zoom=1.;center_x=float_of_int t.width/.2.;center_y=float_of_int t.height/.2.}
  | Zoom_in -> {t with zoom=min (float_of_int (max t.width t.height)) (t.zoom*.2.);center_x;center_y}
  | Zoom_out -> {t with zoom=max 1. (t.zoom/.2.);center_x;center_y}
  | Left -> {t with center_x=center_x-.x_step;center_y}
  | Right -> {t with center_x=center_x+.x_step;center_y}
  | Up -> {t with center_x;center_y=center_y-.y_step}
  | Down -> {t with center_x;center_y=center_y+.y_step}
