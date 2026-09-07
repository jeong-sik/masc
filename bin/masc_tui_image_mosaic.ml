(** Masc_tui_image_mosaic — render a small RGB pixel grid as a truecolor
    half-block ("▀") mosaic. Each character cell stacks two vertical pixels: the
    upper half (foreground colour) is the top pixel, the lower half (background
    colour) the bottom pixel, so a [cols x rows] grid becomes [rows/2] lines of
    [cols] cells. Pure: no I/O, no terminal state -- unit-testable, and it draws
    as ordinary coloured text so it scrolls and redraws like any other card row
    on every truecolour terminal. *)

let upper_half_block = "\xe2\x96\x80" (* U+2580 ▀ *)
let reset = "\027[0m"
let bytes_per_pixel = 3

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
          (Printf.sprintf "\027[38;2;%d;%d;%dm\027[48;2;%d;%d;%dm%s" tr tg tb br
             bg bb upper_half_block)
      done;
      Buffer.add_string buf reset;
      lines := Buffer.contents buf :: !lines
    done;
    List.rev !lines
  end
