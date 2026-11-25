module Rect = Masc_tui_core.Rect
module Glyph = Masc_tui_core.Glyph

type glyph =
  | Empty
  | Ascii of char
  | Braille of int
  | Utf8 of string
  | Continuation

type cell = {
  glyph : glyph;
  width : int;
  style : Style.t;
}

let braille_lut =
  Array.init 256 (fun mask ->
      let b = Bytes.create 3 in
      Bytes.unsafe_set b 0 (Char.chr 0xE2);
      Bytes.unsafe_set b 1 (Char.chr (0xA0 lor (mask lsr 6)));
      Bytes.unsafe_set b 2 (Char.chr (0x80 lor (mask land 0x3F)));
      Bytes.unsafe_to_string b)

let braille_utf8 mask = braille_lut.(mask land 0xFF)

let blank_cell = { glyph = Empty; width = 1; style = Style.default }

let glyph_equal a b =
  match a, b with
  | Empty, Empty | Continuation, Continuation -> true
  | Ascii x, Ascii y -> Char.equal x y
  | Braille x, Braille y -> Int.equal x y
  | Utf8 x, Utf8 y -> String.equal x y
  | Empty, (Ascii _ | Braille _ | Utf8 _ | Continuation)
  | Ascii _, (Empty | Braille _ | Utf8 _ | Continuation)
  | Braille _, (Empty | Ascii _ | Utf8 _ | Continuation)
  | Utf8 _, (Empty | Ascii _ | Braille _ | Continuation)
  | Continuation, (Empty | Ascii _ | Braille _ | Utf8 _) ->
      false

let cell_equal a b =
  Int.equal a.width b.width
  && glyph_equal a.glyph b.glyph
  && Style.equal a.style b.style

module Hit_map = struct
  type 'a entry = {
    rect : Rect.t;
    target : 'a;
  }

  (* Stored newest-first so painter-order overlays hit-test first in O(n). *)
  type 'a t = 'a entry list

  let empty = []

  let add ~rect ~target map =
    if Rect.is_empty rect then map else { rect; target } :: map

  let rec hit_test map ~x ~y =
    match map with
    | [] -> None
    | entry :: rest ->
        if Rect.contains entry.rect ~x ~y then Some entry.target
        else hit_test rest ~x ~y

  let entries map = List.rev map
end

type document_image =
  | Mermaid of string
  | Embedded_png of Graphics.embedded_png

type document_image_rows = {
  source : document_image;
  count : int;
}

type document_image_part = {
  rows : document_image_rows;
  index : int;
  left_inset : int;
}

type document_placement = {
  image : document_image;
  rect : Rect.t;
}

type document_image_progress = {
  rows : document_image_rows;
  next_index : int;
  rect : Rect.t;
}

type t = {
  cols : int;
  rows : int;
  cells : cell array;
  mutable links : string array;
  mutable link_count : int;
  mutable image_progress : document_image_progress option;
  mutable document_placements : document_placement list;
}

let create ~cols ~rows =
  let cols = Int.max 0 cols in
  let rows = Int.max 0 rows in
  {
    cols;
    rows;
    cells = Array.make (cols * rows) blank_cell;
    links = [||];
    link_count = 0;
    image_progress = None;
    document_placements = [];
  }

let cols t = t.cols
let rows t = t.rows
let bounds t = Rect.make ~x:0 ~y:0 ~w:t.cols ~h:t.rows

let clear ?(style = Style.default) t =
  let fill_cell =
    if Style.equal style Style.default then blank_cell
    else { glyph = Empty; width = 1; style }
  in
  Array.fill t.cells 0 (Array.length t.cells) fill_cell;
  t.link_count <- 0;
  t.image_progress <- None;
  t.document_placements <- []

let resize ~cols ~rows t =
  let cols = Int.max 0 cols in
  let rows = Int.max 0 rows in
  if cols = t.cols && rows = t.rows then begin
    clear t;
    t
  end
  else create ~cols ~rows

let copy_into ~src ~dst =
  if src.cols = dst.cols && src.rows = dst.rows then begin
    Array.blit src.cells 0 dst.cells 0 (Array.length src.cells);
    if Array.length dst.links < src.link_count then
      dst.links <- Array.make (Int.max 8 src.link_count) "";
    if src.link_count > 0 then
      Array.blit src.links 0 dst.links 0 src.link_count;
    dst.link_count <- src.link_count
  end

let document_placements t = List.rev t.document_placements

let register_document_image_part t ~(rect : Rect.t) (part : document_image_part) =
  let rect = Rect.inset ~left:part.left_inset rect in
  let complete ~next_index ~rect =
    if next_index = part.rows.count then begin
      t.document_placements <- { image = part.rows.source; rect } :: t.document_placements;
      t.image_progress <- None
    end
    else t.image_progress <- Some { rows = part.rows; next_index; rect }
  in
  if rect.h <> 1 || Rect.is_empty rect
     || not (Rect.equal rect (Rect.intersect rect (bounds t))) then
    t.image_progress <- None
  else if part.index = 0 then complete ~next_index:1 ~rect
  else
    match t.image_progress with
    | Some previous
      when previous.rows == part.rows && previous.next_index = part.index
           && Rect.bottom previous.rect = rect.y ->
        let x = Int.max previous.rect.x rect.x in
        let right = Int.min (Rect.right previous.rect) (Rect.right rect) in
        if right <= x then t.image_progress <- None
        else
          let rect = Rect.make ~x ~y:previous.rect.y ~w:(right - x)
              ~h:(previous.rect.h + 1) in
          complete ~next_index:(part.index + 1) ~rect
    | None | Some _ -> t.image_progress <- None

let occlude_document_images t ~rect =
  let overlaps other = not (Rect.is_empty (Rect.intersect other rect)) in
  t.document_placements <-
    List.filter (fun (p : document_placement) -> not (overlaps p.rect)) t.document_placements;
  match t.image_progress with
  | Some p when overlaps p.rect -> t.image_progress <- None
  | None | Some _ -> ()

let get t ~x ~y =
  if x < 0 || y < 0 || x >= t.cols || y >= t.rows then blank_cell
  else t.cells.((y * t.cols) + x)

let get_linear t idx = t.cells.(idx)

let intern_hyperlink t raw_uri =
  let uri = Grapheme.sanitize_controls raw_uri in
  if String.length uri = 0 then 0
  else
    let rec find i =
      if i >= t.link_count then None
      else if String.equal t.links.(i) uri then Some (i + 1)
      else find (i + 1)
    in
    match find 0 with
    | Some id -> id
    | None ->
        if t.link_count >= Array.length t.links then begin
          let next_cap = Int.max 8 (Array.length t.links * 2) in
          let next = Array.make next_cap "" in
          if t.link_count > 0 then Array.blit t.links 0 next 0 t.link_count;
          t.links <- next
        end;
        let idx = t.link_count in
        t.links.(idx) <- uri;
        t.link_count <- idx + 1;
        idx + 1

let hyperlink_uri t id =
  if id <= 0 || id > t.link_count then None else Some t.links.(id - 1)

let effective_clip t clip =
  let grid_rect = bounds t in
  match clip with
  | None -> grid_rect
  | Some c -> Rect.intersect grid_rect c

let blank_keeping_bg t idx =
  let old = t.cells.(idx) in
  let style = { Style.default with bg = old.style.bg } in
  t.cells.(idx) <- { glyph = Empty; width = 1; style }

(* Atomic partner cleanup: if overwriting a Continuation, blank its left wide
   lead cell; if overwriting a width-2 lead cell, blank its right Continuation. *)
let cleanup_partner t ~x ~y =
  let idx = (y * t.cols) + x in
  let existing = t.cells.(idx) in
  match existing.glyph with
  | Continuation -> if x > 0 then blank_keeping_bg t (idx - 1)
  | Utf8 _ when existing.width = 2 ->
      if x + 1 < t.cols then blank_keeping_bg t (idx + 1)
  | Empty | Ascii _ | Braille _ | Utf8 _ -> ()

let write_cell_in_clip t ~clip ~x ~y cell =
  if not (Rect.contains clip ~x ~y) then ()
  else
    match cell.glyph with
    | Continuation -> ()
    | Utf8 _ when cell.width = 2 ->
        let idx = (y * t.cols) + x in
        if x + 1 < Rect.right clip && x + 1 < t.cols then begin
          cleanup_partner t ~x ~y;
          cleanup_partner t ~x:(x + 1) ~y;
          t.cells.(idx) <- { cell with width = 2 };
          t.cells.(idx + 1) <-
            { glyph = Continuation; width = 0; style = cell.style }
        end
        else begin
          (* Rightmost edge cannot fit width-2 cleanly: emit 1-cell ellipsis. *)
          cleanup_partner t ~x ~y;
          t.cells.(idx) <-
            { glyph = Utf8 (Glyph.to_utf8 Glyph.Ellipsis); width = 1; style = cell.style }
        end
    | Empty | Ascii _ | Braille _ | Utf8 _ ->
        let idx = (y * t.cols) + x in
        cleanup_partner t ~x ~y;
        let normalized_glyph =
          match cell.glyph with
          | Ascii ' ' -> Empty
          | Ascii c when c < '!' || c > '~' -> Empty
          | Ascii _ as g -> g
          | Braille mask -> Braille (mask land 0xFF)
          | (Empty | Utf8 _ | Continuation) as other -> other
        in
        t.cells.(idx) <- { glyph = normalized_glyph; width = 1; style = cell.style }

let set_cell ?clip t ~x ~y cell =
  let clip = effective_clip t clip in
  write_cell_in_clip t ~clip ~x ~y cell

let put_ascii ?clip t ~x ~y ~style ch =
  let clip = effective_clip t clip in
  let glyph = if ch > ' ' && ch <= '~' then Ascii ch else Empty in
  write_cell_in_clip t ~clip ~x ~y { glyph; width = 1; style }

let put_braille ?clip t ~x ~y ~style mask =
  let clip = effective_clip t clip in
  write_cell_in_clip t ~clip ~x ~y
    { glyph = Braille (mask land 0xFF); width = 1; style }

let put_glyph ?clip t ~x ~y ~style g =
  let clip = effective_clip t clip in
  let s = Glyph.to_utf8 g in
  let glyph =
    if String.length s = 1 then
      let c = s.[0] in
      if c > ' ' && c <= '~' then Ascii c else Empty
    else Utf8 s
  in
  write_cell_in_clip t ~clip ~x ~y { glyph; width = 1; style }

let put_text ?clip t ~x ~y ~style text =
  let clip = effective_clip t clip in
  if y < clip.y || y >= Rect.bottom clip || Rect.is_empty clip then 0
  else
    let clean = Grapheme.sanitize_controls text in
    let clip_right = Rect.right clip in
    let col = ref x in
    Grapheme.iter_sanitized_clusters clean
      (fun ~start_offset ~end_offset ~cell_width ->
        let cx = !col in
        if cx < clip_right then begin
          let span = end_offset - start_offset in
          if cx >= clip.x then begin
            if cell_width = 1 && span = 1 then begin
              let ch = clean.[start_offset] in
              let glyph = if ch > ' ' && ch <= '~' then Ascii ch else Empty in
              write_cell_in_clip t ~clip ~x:cx ~y { glyph; width = 1; style }
            end
            else begin
              let s = String.sub clean start_offset span in
              write_cell_in_clip t ~clip ~x:cx ~y
                { glyph = Utf8 s; width = cell_width; style }
            end
          end
          else if cell_width = 2 && cx + 1 = clip.x then
            (* Wide glyph straddles the left clip boundary: blank clip.x so no
               stale glyph or orphaned Continuation remains on the left edge. *)
            write_cell_in_clip t ~clip ~x:clip.x ~y
              { glyph = Empty; width = 1; style };
          col := Int.min clip_right (cx + cell_width)
        end);
    !col - x

let fill_rect ?clip t ~rect ~style ?(glyph = Empty) () =
  let target = Rect.intersect (effective_clip t clip) rect in
  if Rect.is_empty target then ()
  else
    let () = occlude_document_images t ~rect:target in
    let fill_cell =
      match glyph with
      | Continuation -> { glyph = Empty; width = 1; style }
      | (Empty | Ascii _ | Braille _ | Utf8 _) as g ->
          { glyph = g; width = 1; style }
    in
    for y = target.y to Rect.bottom target - 1 do
      for x = target.x to Rect.right target - 1 do
        write_cell_in_clip t ~clip:target ~x ~y fill_cell
      done
    done

let dim_rect ?clip t ~rect ~fg ~bg =
  let target = Rect.intersect (effective_clip t clip) rect in
  if Rect.is_empty target then ()
  else
    let () = occlude_document_images t ~rect:target in
    let scrim_style = Style.make ~fg ~bg () in
    for y = target.y to Rect.bottom target - 1 do
      let row_base = y * t.cols in
      for x = target.x to Rect.right target - 1 do
        let idx = row_base + x in
        let existing = t.cells.(idx) in
        t.cells.(idx) <- { existing with style = scrim_style }
      done
    done
