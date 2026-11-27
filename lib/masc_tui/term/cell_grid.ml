module Rect = Masc_tui_core.Rect
module Glyph = Masc_tui_core.Glyph
module Ba1 = Bigarray.Array1

type int_buf = (int, Bigarray.int_elt, Bigarray.c_layout) Ba1.t

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

let ascii_glyph_lut =
  Array.init 128 (fun i ->
      if i > 0x20 && i <= 0x7E then Ascii (Char.chr i) else Empty)

let cell_equal a b =
  a == b
  || (Int.equal a.width b.width
      && (a.glyph == b.glyph || glyph_equal a.glyph b.glyph)
      && Style.equal a.style b.style)

(* Packed SoA cell encoding stored in unboxed C-layout Bigarray.Array1 buffers
   (zero GC write barriers, memcpy blits, zero major-GC scanning):
   glyphs.{idx}:
     0                         : Empty (width 1)
     1                         : Continuation (width 0)
     0x21..0x7E                : Ascii char (width 1)
     0x100..0x1FF              : Braille (mask = g land 0xFF, width 1)
     (1 lsl 24) lor cp         : Single-scalar Utf8, width 1 (cp <= 0x10FFFF)
     (2 lsl 24) lor cp         : Single-scalar Utf8, width 2 (cp <= 0x10FFFF)
     (1 lsl 24) lor 0x20_0000  : Extra multi-scalar Utf8, width 1 (extra_utf8.(idx))
     (2 lsl 24) lor 0x20_0000  : Extra multi-scalar Utf8, width 2 (extra_utf8.(idx))

   styles.{idx}:
     bits 0..25  : fg color (2-bit tag at 24..25: 0=Default, 1=Ansi16, 2=Ansi256, 3=Rgb; 24-bit payload)
     bits 26..51 : bg color (same 26-bit encoding)
     bits 52..56 : attrs (5-bit mask)
     bit 57      : has_link (1 iff link_ids.(idx) <> 0) *)

let glyph_empty = 0
let glyph_continuation = 1
let glyph_braille_base = 0x100
let glyph_utf8_w1_base = 1 lsl 24
let glyph_utf8_w2_base = 2 lsl 24
let glyph_extra_flag = 1 lsl 21
let glyph_extra_w1 = glyph_utf8_w1_base lor glyph_extra_flag
let glyph_extra_w2 = glyph_utf8_w2_base lor glyph_extra_flag
let glyph_wide_min = glyph_utf8_w2_base
let glyph_ellipsis = glyph_utf8_w1_base lor 0x2026

let style_color_mask = 0x3FF_FFFF
let style_bg_shift = 26
let style_bg_mask = style_color_mask lsl style_bg_shift
let style_attrs_shift = 52
let style_has_link_bit = 1 lsl 57

let style_el0_forbidden_mask =
  style_bg_mask
  lor ((4 lor 8 lor 16) lsl style_attrs_shift)
  lor style_has_link_bit

let[@inline] pack_color = function
  | Color.Default -> 0
  | Color.Ansi16 idx -> (1 lsl 24) lor (idx land 0xFFFFFF)
  | Color.Ansi256 idx -> (2 lsl 24) lor (idx land 0xFFFFFF)
  | Color.Rgb rgb -> (3 lsl 24) lor (rgb land 0xFFFFFF)

let[@inline] unpack_color bits =
  match bits lsr 24 with
  | 0 -> Color.Default
  | 1 -> Color.Ansi16 (bits land 0xFFFFFF)
  | 2 -> Color.Ansi256 (bits land 0xFFFFFF)
  | _ -> Color.Rgb (bits land 0xFFFFFF)

let attr_of_bits_lut =
  Array.init 32 (fun bits ->
      let a = Attr.none in
      let a = if bits land 1 <> 0 then Attr.(a lor bold) else a in
      let a = if bits land 2 <> 0 then Attr.(a lor italic) else a in
      let a = if bits land 4 <> 0 then Attr.(a lor underline) else a in
      let a = if bits land 8 <> 0 then Attr.(a lor reverse) else a in
      let a = if bits land 16 <> 0 then Attr.(a lor strike) else a in
      a)

let[@inline] pack_style (style : Style.t) =
  if style == Style.default then 0
  else
    let fg = pack_color style.fg in
    let bg = pack_color style.bg in
    let attrs = Attr.to_bits style.attrs land 0x1F in
    let link = if style.hyperlink_id <> 0 then style_has_link_bit else 0 in
    fg lor (bg lsl style_bg_shift) lor (attrs lsl style_attrs_shift) lor link

let unpack_style ~link_id bits =
  if bits = 0 && link_id = 0 then Style.default
  else
    let fg = unpack_color (bits land style_color_mask) in
    let bg = unpack_color ((bits lsr style_bg_shift) land style_color_mask) in
    let attrs = Array.unsafe_get attr_of_bits_lut ((bits lsr style_attrs_shift) land 0x1F) in
    { Style.fg; bg; attrs; hyperlink_id = link_id }

let utf8_of_scalar cp =
  if cp < 0x80 then String.make 1 (Char.unsafe_chr cp)
  else if cp < 0x800 then
    let b = Bytes.create 2 in
    Bytes.unsafe_set b 0 (Char.unsafe_chr (0xC0 lor (cp lsr 6)));
    Bytes.unsafe_set b 1 (Char.unsafe_chr (0x80 lor (cp land 0x3F)));
    Bytes.unsafe_to_string b
  else if cp < 0x10000 then
    let b = Bytes.create 3 in
    Bytes.unsafe_set b 0 (Char.unsafe_chr (0xE0 lor (cp lsr 12)));
    Bytes.unsafe_set b 1 (Char.unsafe_chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Bytes.unsafe_set b 2 (Char.unsafe_chr (0x80 lor (cp land 0x3F)));
    Bytes.unsafe_to_string b
  else
    let b = Bytes.create 4 in
    Bytes.unsafe_set b 0 (Char.unsafe_chr (0xF0 lor (cp lsr 18)));
    Bytes.unsafe_set b 1 (Char.unsafe_chr (0x80 lor ((cp lsr 12) land 0x3F)));
    Bytes.unsafe_set b 2 (Char.unsafe_chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Bytes.unsafe_set b 3 (Char.unsafe_chr (0x80 lor (cp land 0x3F)));
    Bytes.unsafe_to_string b

let[@inline] pack_utf8_slice ~width s off span =
  if span > 0 && span <= 4 then
    let d = String.get_utf_8_uchar s off in
    if Uchar.utf_decode_is_valid d && Uchar.utf_decode_length d = span then
      let base = if width = 2 then glyph_utf8_w2_base else glyph_utf8_w1_base in
      base lor Uchar.to_int (Uchar.utf_decode_uchar d)
    else if width = 2 then glyph_extra_w2
    else glyph_extra_w1
  else if width = 2 then glyph_extra_w2
  else glyph_extra_w1

let[@inline] pack_utf8_string ~width s =
  pack_utf8_slice ~width s 0 (String.length s)

let[@inline] fill_int_buf (buf : int_buf) ~pos ~len v =
  for i = pos to pos + len - 1 do
    Ba1.unsafe_set buf i v
  done

module Hit_map = struct
  type 'a entry = {
    rect : Rect.t;
    target : 'a;
  }

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
  | Retained_png of string

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
  glyphs : int_buf;
  styles : int_buf;
  row_has_wide : bool array;
  mutable has_extra_utf8 : bool;
  mutable extra_utf8 : string array;
  mutable has_links : bool;
  mutable link_ids : int_buf;
  mutable links : string array;
  mutable link_count : int;
  mutable image_progress : document_image_progress option;
  mutable document_placements : document_placement list;
}

let empty_int_buf = Ba1.create Bigarray.int Bigarray.c_layout 0

let create ~cols ~rows =
  let cols = Int.max 0 cols in
  let rows = Int.max 0 rows in
  let n = cols * rows in
  let glyphs = Ba1.create Bigarray.int Bigarray.c_layout n in
  let styles = Ba1.create Bigarray.int Bigarray.c_layout n in
  if n > 0 then begin
    Ba1.fill glyphs glyph_empty;
    Ba1.fill styles 0
  end;
  {
    cols;
    rows;
    glyphs;
    styles;
    row_has_wide = Array.make rows false;
    has_extra_utf8 = false;
    extra_utf8 = [||];
    has_links = false;
    link_ids = empty_int_buf;
    links = [||];
    link_count = 0;
    image_progress = None;
    document_placements = [];
  }

let cols t = t.cols
let rows t = t.rows
let bounds t = Rect.make ~x:0 ~y:0 ~w:t.cols ~h:t.rows

let ensure_extra_utf8 t =
  let n = Ba1.dim t.glyphs in
  if Array.length t.extra_utf8 < n then
    t.extra_utf8 <- Array.make n "";
  t.has_extra_utf8 <- true;
  t.extra_utf8

let ensure_link_ids t =
  let n = Ba1.dim t.glyphs in
  if Ba1.dim t.link_ids < n then begin
    let ids = Ba1.create Bigarray.int Bigarray.c_layout n in
    if n > 0 then Ba1.fill ids 0;
    t.link_ids <- ids
  end;
  t.has_links <- true;
  t.link_ids

let clear ?(style = Style.default) t =
  let n = Ba1.dim t.glyphs in
  let ps = pack_style style in
  if n > 0 then begin
    Ba1.fill t.glyphs glyph_empty;
    Ba1.fill t.styles ps
  end;
  Array.fill t.row_has_wide 0 t.rows false;
  if t.has_extra_utf8 then begin
    Array.fill t.extra_utf8 0 n "";
    t.has_extra_utf8 <- false
  end;
  if style.hyperlink_id <> 0 then begin
    let ids = ensure_link_ids t in
    if n > 0 then Ba1.fill ids style.hyperlink_id
  end
  else t.has_links <- false;
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
    let n = Ba1.dim src.glyphs in
    if n > 0 then begin
      Ba1.blit src.glyphs dst.glyphs;
      Ba1.blit src.styles dst.styles
    end;
    Array.blit src.row_has_wide 0 dst.row_has_wide 0 src.rows;
    if src.has_extra_utf8 then begin
      let dst_extra = ensure_extra_utf8 dst in
      Array.blit src.extra_utf8 0 dst_extra 0 n
    end
    else if dst.has_extra_utf8 then begin
      Array.fill dst.extra_utf8 0 n "";
      dst.has_extra_utf8 <- false
    end;
    if src.has_links then begin
      let dst_ids = ensure_link_ids dst in
      if n > 0 then Ba1.blit src.link_ids dst_ids
    end
    else dst.has_links <- false;
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

let get_linear t idx =
  let g = Ba1.get t.glyphs idx in
  let s = Ba1.get t.styles idx in
  if g = glyph_empty && s = 0 then blank_cell
  else
    let link_id =
      if (s land style_has_link_bit) <> 0 && t.has_links then
        Ba1.unsafe_get t.link_ids idx
      else 0
    in
    let style = unpack_style ~link_id s in
    if g = glyph_empty then { glyph = Empty; width = 1; style }
    else if g = glyph_continuation then { glyph = Continuation; width = 0; style }
    else if g < glyph_braille_base then
      { glyph = Array.unsafe_get ascii_glyph_lut g; width = 1; style }
    else if g < 0x200 then
      { glyph = Braille (g land 0xFF); width = 1; style }
    else
      let width = g lsr 24 in
      let str =
        if (g land glyph_extra_flag) <> 0 then Array.unsafe_get t.extra_utf8 idx
        else utf8_of_scalar (g land 0x1FFFFF)
      in
      { glyph = Utf8 str; width; style }

let get t ~x ~y =
  if x < 0 || y < 0 || x >= t.cols || y >= t.rows then blank_cell
  else get_linear t ((y * t.cols) + x)

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

let[@inline] blank_keeping_bg t idx =
  Ba1.unsafe_set t.glyphs idx glyph_empty;
  let old_s = Ba1.unsafe_get t.styles idx in
  Ba1.unsafe_set t.styles idx (old_s land style_bg_mask)

let[@inline] cleanup_partner_at t ~x ~idx =
  let existing = Ba1.unsafe_get t.glyphs idx in
  if existing = glyph_continuation then begin
    if x > 0 then blank_keeping_bg t (idx - 1)
  end
  else if existing >= glyph_wide_min then begin
    if x + 1 < t.cols then blank_keeping_bg t (idx + 1)
  end

let[@inline] set_link_at t idx link_id =
  let ids = ensure_link_ids t in
  Ba1.unsafe_set ids idx link_id

let[@inline] write_narrow_raw t ~x ~y ~idx ~pg ~ps ~link_id =
  if Array.unsafe_get t.row_has_wide y then cleanup_partner_at t ~x ~idx;
  Ba1.unsafe_set t.glyphs idx pg;
  Ba1.unsafe_set t.styles idx ps;
  if link_id <> 0 then set_link_at t idx link_id

let write_wide_utf8_in_clip t ~cx1 ~x ~y ~pg ~extra_opt ~ps ~link_id =
  let idx = (y * t.cols) + x in
  if x + 1 < cx1 then begin
    if Array.unsafe_get t.row_has_wide y then begin
      cleanup_partner_at t ~x ~idx;
      cleanup_partner_at t ~x:(x + 1) ~idx:(idx + 1)
    end;
    Array.unsafe_set t.row_has_wide y true;
    Ba1.unsafe_set t.glyphs idx pg;
    Ba1.unsafe_set t.styles idx ps;
    (match extra_opt with
     | Some s ->
         let extra = ensure_extra_utf8 t in
         Array.unsafe_set extra idx s
     | None -> ());
    Ba1.unsafe_set t.glyphs (idx + 1) glyph_continuation;
    Ba1.unsafe_set t.styles (idx + 1) ps;
    if link_id <> 0 then begin
      let ids = ensure_link_ids t in
      Ba1.unsafe_set ids idx link_id;
      Ba1.unsafe_set ids (idx + 1) link_id
    end
  end
  else begin
    if Array.unsafe_get t.row_has_wide y then cleanup_partner_at t ~x ~idx;
    Ba1.unsafe_set t.glyphs idx glyph_ellipsis;
    Ba1.unsafe_set t.styles idx ps;
    if link_id <> 0 then set_link_at t idx link_id
  end

let[@inline] in_clip t clip ~x ~y =
  match clip with
  | None -> x >= 0 && y >= 0 && x < t.cols && y < t.rows
  | Some (c : Rect.t) ->
      x >= 0 && y >= 0 && x < t.cols && y < t.rows
      && x >= c.x && y >= c.y && x < c.x + c.w && y < c.y + c.h

let[@inline] clip_right_bound t clip =
  match clip with
  | None -> t.cols
  | Some (c : Rect.t) -> Int.min t.cols (c.x + Int.max 0 c.w)

let set_cell ?clip t ~x ~y cell =
  if not (in_clip t clip ~x ~y) then ()
  else
    let ps = pack_style cell.style in
    let link_id = cell.style.hyperlink_id in
    match cell.glyph with
    | Continuation -> ()
    | Utf8 s when cell.width = 2 ->
        let cx1 = clip_right_bound t clip in
        let pg = pack_utf8_string ~width:2 s in
        let extra_opt = if pg = glyph_extra_w2 then Some s else None in
        write_wide_utf8_in_clip t ~cx1 ~x ~y ~pg ~extra_opt ~ps ~link_id
    | Empty ->
        let idx = (y * t.cols) + x in
        write_narrow_raw t ~x ~y ~idx ~pg:glyph_empty ~ps ~link_id
    | Ascii ch ->
        let code = Char.code ch in
        let pg = if code > 0x20 && code <= 0x7E then code else glyph_empty in
        let idx = (y * t.cols) + x in
        write_narrow_raw t ~x ~y ~idx ~pg ~ps ~link_id
    | Braille mask ->
        let pg = glyph_braille_base lor (mask land 0xFF) in
        let idx = (y * t.cols) + x in
        write_narrow_raw t ~x ~y ~idx ~pg ~ps ~link_id
    | Utf8 s ->
        let idx = (y * t.cols) + x in
        let pg = pack_utf8_string ~width:1 s in
        write_narrow_raw t ~x ~y ~idx ~pg ~ps ~link_id;
        if pg = glyph_extra_w1 then begin
          let extra = ensure_extra_utf8 t in
          Array.unsafe_set extra idx s
        end

let put_ascii ?clip t ~x ~y ~style ch =
  if in_clip t clip ~x ~y then
    let code = Char.code ch in
    let pg = if code > 0x20 && code <= 0x7E then code else glyph_empty in
    let ps = pack_style style in
    let idx = (y * t.cols) + x in
    write_narrow_raw t ~x ~y ~idx ~pg ~ps ~link_id:style.hyperlink_id

let put_braille ?clip t ~x ~y ~style mask =
  if in_clip t clip ~x ~y then
    let pg = glyph_braille_base lor (mask land 0xFF) in
    let ps = pack_style style in
    let idx = (y * t.cols) + x in
    write_narrow_raw t ~x ~y ~idx ~pg ~ps ~link_id:style.hyperlink_id

let put_uchar_w1 ?clip t ~x ~y ~style cp =
  if in_clip t clip ~x ~y then
    let pg =
      if cp < 0x80 then
        if cp > 0x20 && cp <= 0x7E then cp else glyph_empty
      else glyph_utf8_w1_base lor (cp land 0x1FFFFF)
    in
    let ps = pack_style style in
    let idx = (y * t.cols) + x in
    write_narrow_raw t ~x ~y ~idx ~pg ~ps ~link_id:style.hyperlink_id

let put_glyph ?clip t ~x ~y ~style g =
  if in_clip t clip ~x ~y then
    let s = Glyph.to_utf8 g in
    let slen = String.length s in
    let pg =
      if slen = 1 then
        let code = Char.code (String.unsafe_get s 0) in
        if code > 0x20 && code <= 0x7E then code else glyph_empty
      else pack_utf8_slice ~width:1 s 0 slen
    in
    let ps = pack_style style in
    let idx = (y * t.cols) + x in
    write_narrow_raw t ~x ~y ~idx ~pg ~ps ~link_id:style.hyperlink_id;
    if pg = glyph_extra_w1 then begin
      let extra = ensure_extra_utf8 t in
      Array.unsafe_set extra idx s
    end

exception Stop_clip

(* Hoisted zero-allocation loop for simple ASCII + UI symbols + Hangul/CJK.
   Explicit [int_buf] annotations ensure ocamlopt emits direct unboxed Bigarray
   loads/stores instead of polymorphic C FFI calls. *)
let rec put_simple_loop (t : t) (glyphs : int_buf) (styles : int_buf) text len y
    row_base cx0 cx1 had_wide ps link_id i cx =
  if i >= len || cx >= cx1 then cx
  else
    let b0 = Char.code (String.unsafe_get text i) in
    if b0 < 0x80 then begin
      if cx >= cx0 then begin
        let idx = row_base + cx in
        if had_wide then cleanup_partner_at t ~x:cx ~idx;
        Ba1.unsafe_set glyphs idx (if b0 > 0x20 then b0 else glyph_empty);
        Ba1.unsafe_set styles idx ps;
        if link_id <> 0 then set_link_at t idx link_id
      end;
      put_simple_loop t glyphs styles text len y row_base cx0 cx1 had_wide ps
        link_id (i + 1) (cx + 1)
    end
    else if b0 = 0xC2 || b0 = 0xC3 then begin
      if cx >= cx0 then begin
        let b1 = Char.code (String.unsafe_get text (i + 1)) in
        let cp = ((b0 land 0x1F) lsl 6) lor (b1 land 0x3F) in
        let idx = row_base + cx in
        if had_wide then cleanup_partner_at t ~x:cx ~idx;
        Ba1.unsafe_set glyphs idx (glyph_utf8_w1_base lor cp);
        Ba1.unsafe_set styles idx ps;
        if link_id <> 0 then set_link_at t idx link_id
      end;
      put_simple_loop t glyphs styles text len y row_base cx0 cx1 had_wide ps
        link_id (i + 2) (cx + 1)
    end
    else if b0 = 0xE2 then begin
      if cx >= cx0 then begin
        let b1 = Char.code (String.unsafe_get text (i + 1)) in
        let b2 = Char.code (String.unsafe_get text (i + 2)) in
        let cp =
          ((b0 land 0x0F) lsl 12)
          lor ((b1 land 0x3F) lsl 6)
          lor (b2 land 0x3F)
        in
        let idx = row_base + cx in
        if had_wide then cleanup_partner_at t ~x:cx ~idx;
        Ba1.unsafe_set glyphs idx (glyph_utf8_w1_base lor cp);
        Ba1.unsafe_set styles idx ps;
        if link_id <> 0 then set_link_at t idx link_id
      end;
      put_simple_loop t glyphs styles text len y row_base cx0 cx1 had_wide ps
        link_id (i + 3) (cx + 1)
    end
    else begin
      if cx >= cx0 then begin
        let idx = row_base + cx in
        if cx + 1 < cx1 then begin
          let b1 = Char.code (String.unsafe_get text (i + 1)) in
          let b2 = Char.code (String.unsafe_get text (i + 2)) in
          let cp =
            ((b0 land 0x0F) lsl 12)
            lor ((b1 land 0x3F) lsl 6)
            lor (b2 land 0x3F)
          in
          if had_wide then begin
            cleanup_partner_at t ~x:cx ~idx;
            cleanup_partner_at t ~x:(cx + 1) ~idx:(idx + 1)
          end;
          Array.unsafe_set t.row_has_wide y true;
          Ba1.unsafe_set glyphs idx (glyph_utf8_w2_base lor cp);
          Ba1.unsafe_set styles idx ps;
          Ba1.unsafe_set glyphs (idx + 1) glyph_continuation;
          Ba1.unsafe_set styles (idx + 1) ps;
          if link_id <> 0 then begin
            let ids = ensure_link_ids t in
            Ba1.unsafe_set ids idx link_id;
            Ba1.unsafe_set ids (idx + 1) link_id
          end
        end
        else begin
          if had_wide then cleanup_partner_at t ~x:cx ~idx;
          Ba1.unsafe_set glyphs idx glyph_ellipsis;
          Ba1.unsafe_set styles idx ps;
          if link_id <> 0 then set_link_at t idx link_id
        end
      end
      else if cx + 1 = cx0 then begin
        let idx = row_base + cx0 in
        if had_wide then cleanup_partner_at t ~x:cx0 ~idx;
        Ba1.unsafe_set glyphs idx glyph_empty;
        Ba1.unsafe_set styles idx ps;
        if link_id <> 0 then set_link_at t idx link_id
      end;
      let next_cx = cx + 2 in
      put_simple_loop t glyphs styles text len y row_base cx0 cx1 had_wide ps
        link_id (i + 3) (if next_cx > cx1 then cx1 else next_cx)
    end

let put_text ?clip t ~x ~y ~style text =
  let cx0 = match clip with None -> 0 | Some (c : Rect.t) -> Int.max 0 c.x in
  let cy0 = match clip with None -> 0 | Some (c : Rect.t) -> Int.max 0 c.y in
  let cx1 =
    match clip with
    | None -> t.cols
    | Some (c : Rect.t) -> Int.min t.cols (c.x + Int.max 0 c.w)
  in
  let cy1 =
    match clip with
    | None -> t.rows
    | Some (c : Rect.t) -> Int.min t.rows (c.y + Int.max 0 c.h)
  in
  if y < cy0 || y >= cy1 || cx0 >= cx1 then 0
  else
    let len = String.length text in
    if len = 0 || x >= cx1 then 0
    else
      let ps = pack_style style in
      let link_id = style.hyperlink_id in
      let row_base = y * t.cols in
      let glyphs = t.glyphs in
      let styles = t.styles in
      if Grapheme.is_all_printable_ascii text then begin
        let start_i = Int.max 0 (cx0 - x) in
        let stop_i = Int.min len (cx1 - x) in
        if start_i < stop_i then begin
          if Array.unsafe_get t.row_has_wide y then begin
            cleanup_partner_at t ~x:(x + start_i) ~idx:(row_base + x + start_i);
            if stop_i - 1 > start_i then
              cleanup_partner_at t ~x:(x + stop_i - 1) ~idx:(row_base + x + stop_i - 1)
          end;
          let base = row_base + x in
          if link_id = 0 then
            for i = start_i to stop_i - 1 do
              let idx = base + i in
              let c = Char.code (String.unsafe_get text i) in
              Ba1.unsafe_set glyphs idx (if c > 0x20 then c else glyph_empty);
              Ba1.unsafe_set styles idx ps
            done
          else begin
            let ids = ensure_link_ids t in
            for i = start_i to stop_i - 1 do
              let idx = base + i in
              let c = Char.code (String.unsafe_get text i) in
              Ba1.unsafe_set glyphs idx (if c > 0x20 then c else glyph_empty);
              Ba1.unsafe_set styles idx ps;
              Ba1.unsafe_set ids idx link_id
            done
          end
        end;
        Int.min cx1 (x + len) - x
      end
      else if Grapheme.is_simple_ascii_or_cjk_hangul text then
        let had_wide = Array.unsafe_get t.row_has_wide y in
        let end_cx =
          put_simple_loop t glyphs styles text len y row_base cx0 cx1 had_wide ps
            link_id 0 x
        in
        end_cx - x
      else begin
        let clean = Grapheme.sanitize_controls text in
        let col = ref x in
        (try
           Grapheme.iter_sanitized_clusters clean
             (fun ~start_offset ~end_offset ~cell_width ->
               let cx = !col in
               if cx >= cx1 then raise_notrace Stop_clip
               else begin
                 let span = end_offset - start_offset in
                 if cx >= cx0 then begin
                   if cell_width = 1 && span = 1 then begin
                     let code = Char.code (String.unsafe_get clean start_offset) in
                     let pg = if code > 0x20 && code <= 0x7E then code else glyph_empty in
                     let idx = row_base + cx in
                     write_narrow_raw t ~x:cx ~y ~idx ~pg ~ps ~link_id
                   end
                   else if cell_width = 2 then begin
                     let pg = pack_utf8_slice ~width:2 clean start_offset span in
                     let extra_opt =
                       if pg = glyph_extra_w2 then Some (String.sub clean start_offset span)
                       else None
                     in
                     write_wide_utf8_in_clip t ~cx1 ~x:cx ~y ~pg ~extra_opt ~ps ~link_id
                   end
                   else begin
                     let idx = row_base + cx in
                     let pg = pack_utf8_slice ~width:1 clean start_offset span in
                     write_narrow_raw t ~x:cx ~y ~idx ~pg ~ps ~link_id;
                     if pg = glyph_extra_w1 then begin
                       let extra = ensure_extra_utf8 t in
                       Array.unsafe_set extra idx (String.sub clean start_offset span)
                     end
                   end
                 end
                 else if cell_width = 2 && cx + 1 = cx0 then begin
                   let idx = row_base + cx0 in
                   write_narrow_raw t ~x:cx0 ~y ~idx ~pg:glyph_empty ~ps ~link_id
                 end;
                 let next_col = cx + cell_width in
                 col := if next_col > cx1 then cx1 else next_col
               end)
         with Stop_clip -> ());
        !col - x
      end

let fill_rect ?clip t ~(rect : Rect.t) ~style ?(glyph = Empty) () =
  let cx0 = match clip with None -> 0 | Some (c : Rect.t) -> Int.max 0 c.x in
  let cy0 = match clip with None -> 0 | Some (c : Rect.t) -> Int.max 0 c.y in
  let cx1 =
    match clip with
    | None -> t.cols
    | Some (c : Rect.t) -> Int.min t.cols (c.x + Int.max 0 c.w)
  in
  let cy1 =
    match clip with
    | None -> t.rows
    | Some (c : Rect.t) -> Int.min t.rows (c.y + Int.max 0 c.h)
  in
  let tx = Int.max cx0 rect.x in
  let ty = Int.max cy0 rect.y in
  let tx1 = Int.min cx1 (rect.x + Int.max 0 rect.w) in
  let ty1 = Int.min cy1 (rect.y + Int.max 0 rect.h) in
  if tx1 <= tx || ty1 <= ty then ()
  else
    let tw = tx1 - tx in
    let th = ty1 - ty in
    if t.document_placements <> [] || Option.is_some t.image_progress then
      occlude_document_images t ~rect:{ Rect.x = tx; y = ty; w = tw; h = th };
    let pg, extra_opt =
      match glyph with
      | Empty | Continuation -> (glyph_empty, None)
      | Ascii ch ->
          let code = Char.code ch in
          ((if code > 0x20 && code <= 0x7E then code else glyph_empty), None)
      | Braille mask -> (glyph_braille_base lor (mask land 0xFF), None)
      | Utf8 s ->
          let pg = pack_utf8_string ~width:1 s in
          (pg, if pg = glyph_extra_w1 then Some s else None)
    in
    let ps = pack_style style in
    let link_id = style.hyperlink_id in
    let right_last = tx1 - 1 in
    let full_row = tx = 0 && tw = t.cols in
    let glyphs = t.glyphs in
    let styles = t.styles in
    let row_has_wide = t.row_has_wide in
    if full_row && ty = 0 && ty1 = t.rows then begin
      Array.fill row_has_wide 0 t.rows false;
      Ba1.fill glyphs pg;
      Ba1.fill styles ps;
      (match extra_opt with
       | Some s ->
           let extra = ensure_extra_utf8 t in
           Array.fill extra 0 (Ba1.dim glyphs) s
       | None -> ());
      if link_id <> 0 then begin
        let ids = ensure_link_ids t in
        Ba1.fill ids link_id
      end
    end
    else
      for y = ty to ty1 - 1 do
        let row_base = y * t.cols in
        if Array.unsafe_get row_has_wide y then begin
          cleanup_partner_at t ~x:tx ~idx:(row_base + tx);
          if right_last > tx then
            cleanup_partner_at t ~x:right_last ~idx:(row_base + right_last);
          if full_row then Array.unsafe_set row_has_wide y false
        end;
        let start = row_base + tx in
        for i = start to start + tw - 1 do
          Ba1.unsafe_set glyphs i pg;
          Ba1.unsafe_set styles i ps
        done;
        (match extra_opt with
         | Some s ->
             let extra = ensure_extra_utf8 t in
             Array.fill extra start tw s
         | None -> ());
        if link_id <> 0 then begin
          let ids = ensure_link_ids t in
          fill_int_buf ids ~pos:start ~len:tw link_id
        end
      done

let dim_rect ?clip t ~(rect : Rect.t) ~fg ~bg =
  let cx0 = match clip with None -> 0 | Some (c : Rect.t) -> Int.max 0 c.x in
  let cy0 = match clip with None -> 0 | Some (c : Rect.t) -> Int.max 0 c.y in
  let cx1 =
    match clip with
    | None -> t.cols
    | Some (c : Rect.t) -> Int.min t.cols (c.x + Int.max 0 c.w)
  in
  let cy1 =
    match clip with
    | None -> t.rows
    | Some (c : Rect.t) -> Int.min t.rows (c.y + Int.max 0 c.h)
  in
  let tx = Int.max cx0 rect.x in
  let ty = Int.max cy0 rect.y in
  let tx1 = Int.min cx1 (rect.x + Int.max 0 rect.w) in
  let ty1 = Int.min cy1 (rect.y + Int.max 0 rect.h) in
  if tx1 <= tx || ty1 <= ty then ()
  else
    let tw = tx1 - tx in
    let th = ty1 - ty in
    if t.document_placements <> [] || Option.is_some t.image_progress then
      occlude_document_images t ~rect:{ Rect.x = tx; y = ty; w = tw; h = th };
    let ps = pack_color fg lor (pack_color bg lsl style_bg_shift) in
    let styles = t.styles in
    for y = ty to ty1 - 1 do
      fill_int_buf styles ~pos:((y * t.cols) + tx) ~len:tw ps
    done

module Raw = struct
  type nonrec int_buf = int_buf

  let glyphs t = t.glyphs
  let styles t = t.styles
  let row_has_wide t = t.row_has_wide
  let has_extra_utf8 t = t.has_extra_utf8
  let has_links t = t.has_links
  let extra_utf8_at t idx = Array.unsafe_get t.extra_utf8 idx
  let link_id_at t idx =
    if t.has_links then Ba1.unsafe_get t.link_ids idx else 0

  let glyph_empty = glyph_empty
  let glyph_continuation = glyph_continuation
  let glyph_extra_flag = glyph_extra_flag
  let glyph_wide_min = glyph_wide_min
  let style_has_link_bit = style_has_link_bit
  let style_el0_forbidden_mask = style_el0_forbidden_mask
end
