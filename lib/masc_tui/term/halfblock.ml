open Masc_tui_core

type viewport = {
  src_x : int;
  src_y : int;
  src_w : int;
  src_h : int;
}

let upper_half_block = "\xe2\x96\x80"

let fit_cells ~image_pixels:(iw, ih) ~columns ~rows =
  let max_cols = Int.max 1 columns in
  let max_rows = Int.max 1 rows in
  if iw <= 0 || ih <= 0 then (max_cols, max_rows)
  else
    (* Each cell is 1 horizontal subpixel by 2 vertical subpixels, so a 1:2
       monospace cell gives 1:1 square subpixels. *)
    let box_w = float_of_int max_cols in
    let box_h = float_of_int (max_rows * 2) in
    let scale = Float.min (box_w /. float_of_int iw) (box_h /. float_of_int ih) in
    let cols =
      int_of_float (Float.floor ((float_of_int iw *. scale) +. 1e-9))
    in
    let sub_h =
      int_of_float (Float.floor ((float_of_int ih *. scale) +. 1e-9))
    in
    let out_rows = (sub_h + 1) / 2 in
    (Int.max 1 (Int.min max_cols cols), Int.max 1 (Int.min max_rows out_rows))

let unpack_rgb hex =
  ((hex lsr 16) land 0xFF, (hex lsr 8) land 0xFF, hex land 0xFF)

let sample_box ~(img : Png_decode.rgba_image) ~bg_r ~bg_g ~bg_b ~x0 ~y0 ~x1 ~y1 =
  let ix0 = Int.max 0 (Int.min (img.width - 1) x0) in
  let iy0 = Int.max 0 (Int.min (img.height - 1) y0) in
  let ix1 = Int.max (ix0 + 1) (Int.min img.width x1) in
  let iy1 = Int.max (iy0 + 1) (Int.min img.height y1) in
  let step_x = Int.max 1 ((ix1 - ix0) / 8) in
  let step_y = Int.max 1 ((iy1 - iy0) / 8) in
  let sum_r = ref 0 in
  let sum_g = ref 0 in
  let sum_b = ref 0 in
  let count = ref 0 in
  let rgba = img.rgba in
  let w = img.width in
  let y = ref iy0 in
  while !y < iy1 do
    let row_off = !y * w * 4 in
    let x = ref ix0 in
    while !x < ix1 do
      let off = row_off + (!x * 4) in
      let r = Char.code (Bytes.get rgba off) in
      let g = Char.code (Bytes.get rgba (off + 1)) in
      let b = Char.code (Bytes.get rgba (off + 2)) in
      let a = Char.code (Bytes.get rgba (off + 3)) in
      let cr, cg, cb =
        if a = 255 then (r, g, b)
        else if a = 0 then (bg_r, bg_g, bg_b)
        else
          let inv = 255 - a in
          ( ((r * a) + (bg_r * inv) + 127) / 255
          , ((g * a) + (bg_g * inv) + 127) / 255
          , ((b * a) + (bg_b * inv) + 127) / 255 )
      in
      sum_r := !sum_r + cr;
      sum_g := !sum_g + cg;
      sum_b := !sum_b + cb;
      incr count;
      x := !x + step_x
    done;
    y := !y + step_y
  done;
  let n = Int.max 1 !count in
  (!sum_r / n, !sum_g / n, !sum_b / n)

let draw_rgba ?viewport ?(bg_rgb = 0x111111) grid ~(rect : Rect.t)
    (img : Png_decode.rgba_image) =
  if Rect.is_empty rect || img.width <= 0 || img.height <= 0 then ()
  else
    let vx, vy, vw, vh =
      match viewport with
      | None -> (0, 0, img.width, img.height)
      | Some vp ->
          let x = Int.max 0 (Int.min (img.width - 1) vp.src_x) in
          let y = Int.max 0 (Int.min (img.height - 1) vp.src_y) in
          let w = Int.max 1 (Int.min (img.width - x) vp.src_w) in
          let h = Int.max 1 (Int.min (img.height - y) vp.src_h) in
          (x, y, w, h)
    in
    let draw_cols, draw_rows =
      fit_cells ~image_pixels:(vw, vh) ~columns:rect.w ~rows:rect.h
    in
    let off_x = rect.x + ((rect.w - draw_cols) / 2) in
    let off_y = rect.y + ((rect.h - draw_rows) / 2) in
    let sub_h = draw_rows * 2 in
    let bg_r, bg_g, bg_b = unpack_rgb bg_rgb in
    for r = 0 to draw_rows - 1 do
      let top_sy0 = vy + ((r * 2 * vh) / sub_h) in
      let top_sy1 = vy + ((((r * 2) + 1) * vh) / sub_h) in
      let bot_sy0 = top_sy1 in
      let bot_sy1 = vy + ((((r * 2) + 2) * vh) / sub_h) in
      let py = off_y + r in
      for c = 0 to draw_cols - 1 do
        let sx0 = vx + ((c * vw) / draw_cols) in
        let sx1 = vx + (((c + 1) * vw) / draw_cols) in
        let tr, tg, tb =
          sample_box ~img ~bg_r ~bg_g ~bg_b ~x0:sx0 ~y0:top_sy0 ~x1:sx1
            ~y1:top_sy1
        in
        let br, bg, bb =
          sample_box ~img ~bg_r ~bg_g ~bg_b ~x0:sx0 ~y0:bot_sy0 ~x1:sx1
            ~y1:bot_sy1
        in
        let style =
          Style.make ~fg:(Color.rgb ~r:tr ~g:tg ~b:tb)
            ~bg:(Color.rgb ~r:br ~g:bg ~b:bb) ()
        in
        Cell_grid.set_cell ~clip:rect grid ~x:(off_x + c) ~y:py
          { glyph = Cell_grid.Utf8 upper_half_block; width = 1; style }
      done
    done
