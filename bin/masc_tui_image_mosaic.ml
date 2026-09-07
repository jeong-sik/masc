(** Masc_tui_image_mosaic — render a small RGB pixel grid as a truecolor
    half-block ("▀") mosaic. Each character cell stacks two vertical pixels: the
    upper half (foreground colour) is the top pixel, the lower half (background
    colour) the bottom pixel, so a [cols x rows] grid becomes [rows/2] lines of
    [cols] cells. Pure: no I/O, no terminal state -- unit-testable, and it draws
    as ordinary coloured text so it scrolls and redraws like any other card row
    on every truecolour terminal. *)

let upper_half_block = "\xe2\x96\x80" (* U+2580 ▀ *)
let reset = Masc_tui_theme.Sgr.reset
let bytes_per_pixel = 3

let fit_grid ~src_w ~src_h ~max_cols ~max_rows =
  if src_w <= 0 || src_h <= 0 || max_cols <= 0 || max_rows <= 1 then (0, 0)
  else begin
    let even n = n - (n land 1) in
    (* Fill the width and see whether the height that ratio asks for fits.
       When it does not, the height is the binding bound and the width
       follows from it. *)
    let rows_at_full_width = even (max_cols * src_h / src_w) in
    if rows_at_full_width > 0 && rows_at_full_width <= max_rows then
      (max_cols, rows_at_full_width)
    else begin
      let rows = even max_rows in
      let cols = rows * src_w / src_h in
      if rows <= 0 || cols <= 0 then (0, 0) else (min cols max_cols, rows)
    end
  end

let downscale ~src_w ~src_h ~cols ~rows (rgb : string) =
  if
    src_w <= 0 || src_h <= 0 || cols <= 0 || rows <= 0
    || String.length rgb < src_w * src_h * bytes_per_pixel
  then ""
  else begin
    let out = Bytes.create (cols * rows * bytes_per_pixel) in
    (* The half-open source span an output pixel covers. The [max] keeps the
       span non-empty when the grid is larger than the source in that axis,
       where the ratio would otherwise give a zero-width box. *)
    let span index count extent =
      let low = index * extent / count in
      (low, max (low + 1) ((index + 1) * extent / count))
    in
    for oy = 0 to rows - 1 do
      let y0, y1 = span oy rows src_h in
      for ox = 0 to cols - 1 do
        let x0, x1 = span ox cols src_w in
        let r = ref 0 and g = ref 0 and b = ref 0 and n = ref 0 in
        for y = y0 to min (src_h - 1) (y1 - 1) do
          for x = x0 to min (src_w - 1) (x1 - 1) do
            let i = ((y * src_w) + x) * bytes_per_pixel in
            r := !r + Char.code rgb.[i];
            g := !g + Char.code rgb.[i + 1];
            b := !b + Char.code rgb.[i + 2];
            incr n
          done
        done;
        let dst = ((oy * cols) + ox) * bytes_per_pixel in
        let mean total = if !n = 0 then '\000' else Char.chr (total / !n) in
        Bytes.set out dst (mean !r);
        Bytes.set out (dst + 1) (mean !g);
        Bytes.set out (dst + 2) (mean !b)
      done
    done;
    Bytes.to_string out
  end

(** [render ~cols ~rows rgb] renders row-major RGB bytes ([cols*rows*3] long)
    as [rows/2] mosaic lines. Returns [] when [rows] is odd or [rgb] is too
    short for the stated dimensions, so a malformed decode never draws garbage
    or raises. *)
let render ~cols ~rows (rgb : string) : string list =
  if cols <= 0 || rows <= 0 || rows land 1 = 1 then []
  else if String.length rgb < cols * rows * bytes_per_pixel then []
  else begin
    let px x y =
      let i = ((y * cols) + x) * bytes_per_pixel in
      (Char.code rgb.[i], Char.code rgb.[i + 1], Char.code rgb.[i + 2])
    in
    let out_rows = rows / 2 in
    let buf = Buffer.create (cols * 24) in
    let lines = ref [] in
    for cy = 0 to out_rows - 1 do
      Buffer.clear buf;
      for x = 0 to cols - 1 do
        let tr, tg, tb = px x (2 * cy) in
        let br, bg, bb = px x ((2 * cy) + 1) in
        Buffer.add_string buf
          (Masc_tui_theme.Sgr.truecolor_foreground ~r:tr ~g:tg ~b:tb
           ^ Masc_tui_theme.Sgr.truecolor_background ~r:br ~g:bg ~b:bb
           ^ upper_half_block)
      done;
      Buffer.add_string buf reset;
      lines := Buffer.contents buf :: !lines
    done;
    List.rev !lines
  end
