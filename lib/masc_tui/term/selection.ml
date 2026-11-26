open Masc_tui_core

let is_blank_cell (cell : Cell_grid.cell) =
  match cell.glyph with
  | Cell_grid.Empty -> true
  | Cell_grid.Braille mask -> Int.equal mask 0
  | Cell_grid.Ascii _ | Cell_grid.Utf8 _ | Cell_grid.Continuation -> false

let glyph_text (cell : Cell_grid.cell) =
  match cell.glyph with
  | Cell_grid.Empty -> " "
  | Cell_grid.Ascii ch -> String.make 1 ch
  | Cell_grid.Braille mask -> Cell_grid.braille_utf8 mask
  | Cell_grid.Utf8 s -> s
  | Cell_grid.Continuation -> ""

let trim_trailing_spaces s =
  let len = String.length s in
  let rec last_non_space i =
    if i <= 0 then 0
    else if String.get s (i - 1) = ' ' then last_non_space (i - 1)
    else i
  in
  let end_ = last_non_space len in
  if end_ = len then s else String.sub s 0 end_

let extract_row grid ~y ~x0 ~x1 =
  let buf = Buffer.create (Int.max 0 (x1 - x0)) in
  for x = x0 to x1 - 1 do
    Buffer.add_string buf (glyph_text (Cell_grid.get grid ~x ~y))
  done;
  trim_trailing_spaces (Buffer.contents buf)

let extract_text grid ~rect =
  if Rect.is_empty rect then ""
  else
    let y0 = rect.y in
    let y1 = Rect.bottom rect in
    let x0 = rect.x in
    let x1 = Rect.right rect in
    let rows =
      List.init (y1 - y0) (fun i -> extract_row grid ~y:(y0 + i) ~x0 ~x1)
    in
    let rec drop_rev = function
      | "" :: rest -> drop_rev rest
      | rows -> rows
    in
    String.concat "\n" (List.rev (drop_rev (List.rev rows)))

let paint grid ~rect ~fg ~bg =
  if not (Rect.is_empty rect) then
    let y0 = rect.y in
    let y1 = Rect.bottom rect in
    let x0 = rect.x in
    let x1 = Rect.right rect in
    for y = y0 to y1 - 1 do
      let last = ref (x0 - 1) in
      for x = x0 to x1 - 1 do
        let cell = Cell_grid.get grid ~x ~y in
        if not (is_blank_cell cell) then last := x
      done;
      let last = !last in
      if last >= x0 then
        for x = x0 to last do
          let cell = Cell_grid.get grid ~x ~y in
          (* Never overwrite a continuation half: the cell grid cleans up
             wide-glyph partners on overwrite, which would corrupt the
             glyph the extraction reads back. Continuations emit no output,
             so the lead cell's style carries the whole wide glyph. *)
          match cell.glyph with
          | Cell_grid.Continuation -> ()
          | Cell_grid.Empty
          | Cell_grid.Ascii _
          | Cell_grid.Braille _
          | Cell_grid.Utf8 _ ->
              let style =
                Style.make ~fg ~bg ~attrs:cell.style.attrs ()
              in
              Cell_grid.set_cell ~clip:rect grid ~x ~y { cell with style }
        done
    done
