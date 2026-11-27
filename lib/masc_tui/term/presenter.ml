module Clock = Masc_tui_core.Clock
module Raw = Cell_grid.Raw
module Ba1 = Bigarray.Array1

type capabilities = {
  synchronized_output : bool;
  color_depth : Color.depth;
  braille_safe : bool;
  unicode_blocks : bool;
  osc8_hyperlinks : bool;
  osc52_clipboard : bool;
  kitty_keyboard : bool;
  graphics : Probe.graphics_reply option;
  cell_pixels : (int * int) option;
}

type cursor_shape =
  | Block
  | Bar
  | Underline

type cursor = {
  x : int;
  y : int;
  visible : bool;
  shape : cursor_shape;
}

type diff_stats = {
  dirty_cells : int;
  dirty_runs : int;
  bytes_emitted : int;
  diff_us : int;
  full_repaint : bool;
}

let default_capabilities =
  {
    synchronized_output = true;
    color_depth = Color.Truecolor;
    braille_safe = true;
    unicode_blocks = true;
    osc8_hyperlinks = true;
    osc52_clipboard = true;
    kitty_keyboard = true;
    graphics = None;
    cell_pixels = None;
  }

let apply_probe_observation (obs : Probe.observation) (caps : capabilities) =
  let graphics =
    match obs.graphics with
    | Some _ as g -> g
    | None -> caps.graphics
  in
  let cell_pixels =
    match obs.cell_pixels with
    | Some _ as px -> px
    | None -> caps.cell_pixels
  in
  { caps with graphics; cell_pixels }

let hidden_cursor = { x = 0; y = 0; visible = false; shape = Block }

let cursor_shape_equal a b =
  match a, b with
  | Block, Block | Bar, Bar | Underline, Underline -> true
  | Block, (Bar | Underline)
  | Bar, (Block | Underline)
  | Underline, (Block | Bar) ->
      false

let cursor_equal a b =
  Int.equal a.x b.x
  && Int.equal a.y b.y
  && Bool.equal a.visible b.visible
  && cursor_shape_equal a.shape b.shape

type t = {
  mutable front : Cell_grid.t;
  mutable back : Cell_grid.t;
  mutable caps : capabilities;
  mutable force_full : bool;
  mutable last_cursor : cursor option;
  mutable dirty_row_flags : bool array;
  utf8_scratch : Bytes.t;
  buf : Buffer.t;
}

let initial_buffer_bytes = 65_536
let run_bridge_max_clean = 3

let create ~cols ~rows ~capabilities =
  let cols = Int.max 0 cols in
  let rows = Int.max 0 rows in
  {
    front = Cell_grid.create ~cols ~rows;
    back = Cell_grid.create ~cols ~rows;
    caps = capabilities;
    force_full = true;
    last_cursor = None;
    dirty_row_flags = Array.make cols false;
    utf8_scratch = Bytes.create 4;
    buf = Buffer.create initial_buffer_bytes;
  }

let capabilities t = t.caps
let set_capabilities t caps =
  t.caps <- caps;
  t.force_full <- true

let back_grid t = t.back
let front_grid t = t.front

let resize t ~cols ~rows =
  let cols = Int.max 0 cols in
  let rows = Int.max 0 rows in
  t.front <- Cell_grid.create ~cols ~rows;
  t.back <- Cell_grid.create ~cols ~rows;
  t.dirty_row_flags <- Array.make cols false;
  t.force_full <- true;
  t.last_cursor <- None

let invalidate t = t.force_full <- true

let int_str_lut = Array.init 256 Int.to_string

let[@inline] add_int buf n =
  if n >= 0 && n < 256 then
    Buffer.add_string buf (Array.unsafe_get int_str_lut n)
  else if n >= 256 && n < 1000 then begin
    let q = n / 10 in
    Buffer.add_char buf (Char.unsafe_chr (48 + (q / 10)));
    Buffer.add_char buf (Char.unsafe_chr (48 + (q mod 10)));
    Buffer.add_char buf (Char.unsafe_chr (48 + (n mod 10)))
  end
  else Buffer.add_string buf (Int.to_string n)

let emit_cup buf ~row ~col =
  Buffer.add_string buf "\x1b[";
  add_int buf (row + 1);
  Buffer.add_char buf ';';
  add_int buf (col + 1);
  Buffer.add_char buf 'H'

let[@inline] downscale_packed_color ~depth packed =
  match depth with
  | Color.Truecolor -> packed
  | Color.Ansi256 ->
      if packed lsr 24 = 3 then
        (2 lsl 24) lor Color.rgb_to_ansi256 (packed land 0xFFFFFF)
      else packed
  | Color.Ansi16 ->
      let tag = packed lsr 24 in
      if tag = 3 then
        (1 lsl 24) lor Color.rgb_to_ansi16 (packed land 0xFFFFFF)
      else if tag = 2 then
        let idx = packed land 0xFFFFFF in
        if idx >= 0 && idx < 16 then (1 lsl 24) lor idx
        else (1 lsl 24) lor Color.rgb_to_ansi16 (Color.ansi256_to_rgb idx)
      else packed

let emit_fg_packed buf packed =
  match packed lsr 24 with
  | 0 -> Buffer.add_string buf "\x1b[39m"
  | 1 ->
      let idx = packed land 0xFFFFFF in
      let code = if idx < 8 then 30 + idx else 90 + (idx - 8) in
      Buffer.add_string buf "\x1b[";
      add_int buf code;
      Buffer.add_char buf 'm'
  | 2 ->
      Buffer.add_string buf "\x1b[38;5;";
      add_int buf (packed land 0xFFFFFF);
      Buffer.add_char buf 'm'
  | _ ->
      let rgb = packed land 0xFFFFFF in
      Buffer.add_string buf "\x1b[38;2;";
      add_int buf ((rgb lsr 16) land 0xFF);
      Buffer.add_char buf ';';
      add_int buf ((rgb lsr 8) land 0xFF);
      Buffer.add_char buf ';';
      add_int buf (rgb land 0xFF);
      Buffer.add_char buf 'm'

let emit_bg_packed buf packed =
  match packed lsr 24 with
  | 0 -> Buffer.add_string buf "\x1b[49m"
  | 1 ->
      let idx = packed land 0xFFFFFF in
      let code = if idx < 8 then 40 + idx else 100 + (idx - 8) in
      Buffer.add_string buf "\x1b[";
      add_int buf code;
      Buffer.add_char buf 'm'
  | 2 ->
      Buffer.add_string buf "\x1b[48;5;";
      add_int buf (packed land 0xFFFFFF);
      Buffer.add_char buf 'm'
  | _ ->
      let rgb = packed land 0xFFFFFF in
      Buffer.add_string buf "\x1b[48;2;";
      add_int buf ((rgb lsr 16) land 0xFF);
      Buffer.add_char buf ';';
      add_int buf ((rgb lsr 8) land 0xFF);
      Buffer.add_char buf ';';
      add_int buf (rgb land 0xFF);
      Buffer.add_char buf 'm'

(* Never emits SGR dim (CSI 2m) — Attr bits 0..4 are bold/italic/underline/reverse/strike. *)
let emit_attr_bits buf bits =
  if bits land 1 <> 0 then Buffer.add_string buf "\x1b[1m";
  if bits land 2 <> 0 then Buffer.add_string buf "\x1b[3m";
  if bits land 4 <> 0 then Buffer.add_string buf "\x1b[4m";
  if bits land 8 <> 0 then Buffer.add_string buf "\x1b[7m";
  if bits land 16 <> 0 then Buffer.add_string buf "\x1b[9m"

let[@inline] emit_utf8_scalar buf scratch cp =
  if cp < 0x80 then Buffer.add_char buf (Char.unsafe_chr cp)
  else if cp < 0x800 then begin
    Bytes.unsafe_set scratch 0 (Char.unsafe_chr (0xC0 lor (cp lsr 6)));
    Bytes.unsafe_set scratch 1 (Char.unsafe_chr (0x80 lor (cp land 0x3F)));
    Buffer.add_subbytes buf scratch 0 2
  end
  else if cp < 0x10000 then begin
    Bytes.unsafe_set scratch 0 (Char.unsafe_chr (0xE0 lor (cp lsr 12)));
    Bytes.unsafe_set scratch 1 (Char.unsafe_chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Bytes.unsafe_set scratch 2 (Char.unsafe_chr (0x80 lor (cp land 0x3F)));
    Buffer.add_subbytes buf scratch 0 3
  end
  else begin
    Bytes.unsafe_set scratch 0 (Char.unsafe_chr (0xF0 lor (cp lsr 18)));
    Bytes.unsafe_set scratch 1 (Char.unsafe_chr (0x80 lor ((cp lsr 12) land 0x3F)));
    Bytes.unsafe_set scratch 2 (Char.unsafe_chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Bytes.unsafe_set scratch 3 (Char.unsafe_chr (0x80 lor (cp land 0x3F)));
    Buffer.add_subbytes buf scratch 0 4
  end

let popcount8 mask =
  let x = mask land 0xFF in
  let x = x - ((x lsr 1) land 0x55) in
  let x = (x land 0x33) + ((x lsr 2) land 0x33) in
  (x + (x lsr 4)) land 0x0F

let ascii_fallback_of_braille mask =
  match popcount8 mask with
  | 0 -> ' '
  | 1 | 2 -> '.'
  | 3 | 4 -> ':'
  | 5 | 6 -> '='
  | _ -> '#'

let ensure_row_flags t cols =
  if Array.length t.dirty_row_flags < cols then
    t.dirty_row_flags <- Array.make cols false

let[@inline] cells_differ_slow ~front ~back ~(f_glyphs : Raw.int_buf)
    ~(b_glyphs : Raw.int_buf) ~(f_styles : Raw.int_buf)
    ~(b_styles : Raw.int_buf) idx =
  let fg = Ba1.unsafe_get f_glyphs idx in
  let bg = Ba1.unsafe_get b_glyphs idx in
  let fs = Ba1.unsafe_get f_styles idx in
  let bs = Ba1.unsafe_get b_styles idx in
  if fg <> bg || fs <> bs then true
  else
    let extra_diff =
      if (fg land Raw.glyph_extra_flag) <> 0 then
        not (String.equal (Raw.extra_utf8_at front idx) (Raw.extra_utf8_at back idx))
      else false
    in
    if extra_diff then true
    else if (fs land Raw.style_has_link_bit) <> 0 then
      let fid = Raw.link_id_at front idx in
      let bid = Raw.link_id_at back idx in
      fid <> bid
      || not
           (Option.equal String.equal
              (Cell_grid.hyperlink_uri front fid)
              (Cell_grid.hyperlink_uri back bid))
    else false

(* Hoisted zero-allocation scanners (monomorphic [Raw.int_buf] avoids
   polymorphic Bigarray C FFI calls and closure allocation). *)
let rec find_first_diff_linear (f_glyphs : Raw.int_buf) (b_glyphs : Raw.int_buf)
    (f_styles : Raw.int_buf) (b_styles : Raw.int_buf) idx n =
  if idx + 4 <= n then
    if
      Ba1.unsafe_get f_glyphs idx <> Ba1.unsafe_get b_glyphs idx
      || Ba1.unsafe_get f_styles idx <> Ba1.unsafe_get b_styles idx
    then idx
    else if
      Ba1.unsafe_get f_glyphs (idx + 1) <> Ba1.unsafe_get b_glyphs (idx + 1)
      || Ba1.unsafe_get f_styles (idx + 1) <> Ba1.unsafe_get b_styles (idx + 1)
    then idx + 1
    else if
      Ba1.unsafe_get f_glyphs (idx + 2) <> Ba1.unsafe_get b_glyphs (idx + 2)
      || Ba1.unsafe_get f_styles (idx + 2) <> Ba1.unsafe_get b_styles (idx + 2)
    then idx + 2
    else if
      Ba1.unsafe_get f_glyphs (idx + 3) <> Ba1.unsafe_get b_glyphs (idx + 3)
      || Ba1.unsafe_get f_styles (idx + 3) <> Ba1.unsafe_get b_styles (idx + 3)
    then idx + 3
    else find_first_diff_linear f_glyphs b_glyphs f_styles b_styles (idx + 4) n
  else if idx >= n then -1
  else if
    Ba1.unsafe_get f_glyphs idx = Ba1.unsafe_get b_glyphs idx
    && Ba1.unsafe_get f_styles idx = Ba1.unsafe_get b_styles idx
  then find_first_diff_linear f_glyphs b_glyphs f_styles b_styles (idx + 1) n
  else idx

let rec find_first_diff_general front back (f_glyphs : Raw.int_buf)
    (b_glyphs : Raw.int_buf) (f_styles : Raw.int_buf) (b_styles : Raw.int_buf)
    extra_flag link_bit idx n =
  if idx >= n then -1
  else
    let fg = Ba1.unsafe_get f_glyphs idx in
    let bg = Ba1.unsafe_get b_glyphs idx in
    let fs = Ba1.unsafe_get f_styles idx in
    let bs = Ba1.unsafe_get b_styles idx in
    if fg <> bg || fs <> bs then idx
    else if (fg land extra_flag) = 0 && (fs land link_bit) = 0 then
      find_first_diff_general front back f_glyphs b_glyphs f_styles b_styles
        extra_flag link_bit (idx + 1) n
    else if
      ((fg land extra_flag) <> 0
       && not
            (String.equal (Raw.extra_utf8_at front idx)
               (Raw.extra_utf8_at back idx)))
      || ((fs land link_bit) <> 0
          &&
          let fid = Raw.link_id_at front idx in
          let bid = Raw.link_id_at back idx in
          fid <> bid
          || not
               (Option.equal String.equal
                  (Cell_grid.hyperlink_uri front fid)
                  (Cell_grid.hyperlink_uri back bid)))
    then idx
    else
      find_first_diff_general front back f_glyphs b_glyphs f_styles b_styles
        extra_flag link_bit (idx + 1) n

let rec find_first_dirty_simple (f_glyphs : Raw.int_buf) (b_glyphs : Raw.int_buf)
    (f_styles : Raw.int_buf) (b_styles : Raw.int_buf) row_base cols col =
  if col >= cols then -1
  else
    let idx = row_base + col in
    if Ba1.unsafe_get f_glyphs idx = Ba1.unsafe_get b_glyphs idx
       && Ba1.unsafe_get f_styles idx = Ba1.unsafe_get b_styles idx
    then
      find_first_dirty_simple f_glyphs b_glyphs f_styles b_styles row_base cols
        (col + 1)
    else col

let rec find_first_dirty_slow front back (f_glyphs : Raw.int_buf)
    (b_glyphs : Raw.int_buf) (f_styles : Raw.int_buf) (b_styles : Raw.int_buf)
    row_base cols col =
  if col >= cols then -1
  else if
    cells_differ_slow ~front ~back ~f_glyphs ~b_glyphs ~f_styles ~b_styles
      (row_base + col)
  then col
  else
    find_first_dirty_slow front back f_glyphs b_glyphs f_styles b_styles
      row_base cols (col + 1)

let rec find_tail_start_loop (b_glyphs : Raw.int_buf) (b_styles : Raw.int_buf)
    glyph_empty el0_mask row_base col =
  if col <= 0 then 0
  else
    let idx = row_base + col - 1 in
    if Ba1.unsafe_get b_glyphs idx = glyph_empty
       && (Ba1.unsafe_get b_styles idx land el0_mask) = 0
    then
      find_tail_start_loop b_glyphs b_styles glyph_empty el0_mask row_base
        (col - 1)
    else col

let diff_and_emit t ~next_grid ~cursor ~write =
  let t0 = Clock.Mono.now () in
  let cols = Cell_grid.cols next_grid in
  let rows = Cell_grid.rows next_grid in
  let full_repaint =
    t.force_full
    || cols <> Cell_grid.cols t.front
    || rows <> Cell_grid.rows t.front
  in
  if cols <> Cell_grid.cols t.front || rows <> Cell_grid.rows t.front then
    t.front <- Cell_grid.create ~cols ~rows;
  ensure_row_flags t cols;
  let cursor_changed =
    match t.last_cursor with
    | None -> true
    | Some prev -> not (cursor_equal prev cursor)
  in
  let f_glyphs = Raw.glyphs t.front in
  let f_styles = Raw.styles t.front in
  let b_glyphs = Raw.glyphs next_grid in
  let b_styles = Raw.styles next_grid in
  let simple_grids =
    not
      (Raw.has_extra_utf8 t.front || Raw.has_extra_utf8 next_grid
       || Raw.has_links t.front || Raw.has_links next_grid)
  in
  (* Zero-allocation NO-OP fast path + first-dirty-row skip before allocating
     any emission refs/closures (works for both simple grids and grids with
     hyperlinks / multi-scalar graphemes). *)
  let pre_first_idx =
    if full_repaint then 0
    else if simple_grids then
      find_first_diff_linear f_glyphs b_glyphs f_styles b_styles 0 (cols * rows)
    else
      find_first_diff_general t.front next_grid f_glyphs b_glyphs f_styles
        b_styles Raw.glyph_extra_flag Raw.style_has_link_bit 0 (cols * rows)
  in
  if (not full_repaint) && pre_first_idx < 0 && not cursor_changed then
    let diff_us = Clock.Mono.us_since (Clock.Mono.now ()) ~since:t0 in
    {
      dirty_cells = 0;
      dirty_runs = 0;
      bytes_emitted = 0;
      diff_us = Int.max 0 diff_us;
      full_repaint = false;
    }
  else
  let buf = t.buf in
  let scratch = t.utf8_scratch in
  let header_emitted = ref false in
  let ensure_header () =
    if not !header_emitted then begin
      header_emitted := true;
      Buffer.clear buf;
      if t.caps.synchronized_output then Buffer.add_string buf "\x1b[?2026h";
      Buffer.add_string buf "\x1b[?25l";
      Buffer.add_string buf "\x1b[?7l";
      if full_repaint then Buffer.add_string buf "\x1b[0m"
    end
  in
  let pen_fg = ref 0 in
  let pen_bg = ref 0 in
  let pen_attrs = ref 0 in
  let pen_link = ref 0 in
  let pen_packed = ref (-1) in
  let pen_x = ref (-1) in
  let pen_y = ref (-1) in
  let dirty_runs = ref 0 in
  let total_dirty = ref 0 in
  let color_depth = t.caps.color_depth in
  let is_truecolor = color_depth = Color.Truecolor in
  let osc8 = t.caps.osc8_hyperlinks in
  let braille_safe = t.caps.braille_safe in
  let b_row_has_wide = Raw.row_has_wide next_grid in
  let el0_mask = Raw.style_el0_forbidden_mask in
  let glyph_empty = Raw.glyph_empty in
  let glyph_cont = Raw.glyph_continuation in
  let glyph_wide_min = Raw.glyph_wide_min in
  let glyph_extra_flag = Raw.glyph_extra_flag in
  let link_bit = Raw.style_has_link_bit in
  let reset_pen_for_clear () =
    if !pen_link <> 0 && osc8 then begin
      Buffer.add_string buf "\x1b]8;;\x1b\\";
      pen_link := 0;
      pen_packed := -1
    end;
    if !pen_bg <> 0 || !pen_attrs <> 0 then begin
      Buffer.add_string buf "\x1b[0m";
      pen_fg := 0;
      pen_bg := 0;
      pen_attrs := 0;
      pen_packed := 0
    end
  in
  let apply_packed_style s idx =
    let fg_raw = s land 0x3FF_FFFF in
    let bg_raw = (s lsr 26) land 0x3FF_FFFF in
    let next_bits = (s lsr 52) land 0x1F in
    let target_fg =
      if is_truecolor then fg_raw
      else downscale_packed_color ~depth:color_depth fg_raw
    in
    let target_bg =
      if is_truecolor then bg_raw
      else downscale_packed_color ~depth:color_depth bg_raw
    in
    let target_link =
      if osc8 && (s land link_bit) <> 0 then Raw.link_id_at next_grid idx
      else 0
    in
    let cur_bits = !pen_attrs in
    if cur_bits land lnot next_bits <> 0 then begin
      Buffer.add_string buf "\x1b[0m";
      pen_fg := 0;
      pen_bg := 0;
      pen_attrs := next_bits;
      if next_bits <> 0 then emit_attr_bits buf next_bits
    end
    else if cur_bits <> next_bits then begin
      emit_attr_bits buf (next_bits land lnot cur_bits);
      pen_attrs := next_bits
    end;
    if !pen_fg <> target_fg then begin
      emit_fg_packed buf target_fg;
      pen_fg := target_fg
    end;
    if !pen_bg <> target_bg then begin
      emit_bg_packed buf target_bg;
      pen_bg := target_bg
    end;
    if !pen_link <> target_link then begin
      (match Cell_grid.hyperlink_uri next_grid target_link with
       | Some uri ->
           Buffer.add_string buf "\x1b]8;;";
           Buffer.add_string buf uri;
           Buffer.add_string buf "\x1b\\"
       | None -> Buffer.add_string buf "\x1b]8;;\x1b\\");
      pen_link := target_link
    end;
    pen_packed := if target_link = 0 && (s land link_bit) = 0 then s else -1
  in
  let[@inline] emit_cell_at idx =
    let g = Ba1.unsafe_get b_glyphs idx in
    if g = glyph_cont then ()
    else begin
      let s = Ba1.unsafe_get b_styles idx in
      if s <> !pen_packed then apply_packed_style s idx;
      if g = glyph_empty then begin
        Buffer.add_char buf ' ';
        pen_x := !pen_x + 1
      end
      else if g < 0x100 then begin
        Buffer.add_char buf (Char.unsafe_chr g);
        pen_x := !pen_x + 1
      end
      else if g < 0x200 then begin
        let mask = g land 0xFF in
        if braille_safe then
          Buffer.add_string buf (Array.unsafe_get Cell_grid.braille_lut mask)
        else Buffer.add_char buf (ascii_fallback_of_braille mask);
        pen_x := !pen_x + 1
      end
      else if (g land glyph_extra_flag) = 0 then begin
        emit_utf8_scalar buf scratch (g land 0x1FFFFF);
        pen_x := !pen_x + (g lsr 24)
      end
      else begin
        Buffer.add_string buf (Raw.extra_utf8_at next_grid idx);
        pen_x := !pen_x + (g lsr 24)
      end
    end
  in
  if full_repaint then begin
    total_dirty := cols * rows;
    if cols > 0 && rows > 0 then begin
      ensure_header ();
      for row = 0 to rows - 1 do
        let row_base = row * cols in
        let tail_start =
          find_tail_start_loop b_glyphs b_styles glyph_empty el0_mask row_base cols
        in
        if tail_start > 0 then begin
          if !pen_y <> row || !pen_x <> 0 then begin
            emit_cup buf ~row ~col:0;
            pen_y := row;
            pen_x := 0
          end;
          incr dirty_runs;
          for c = 0 to tail_start - 1 do
            emit_cell_at (row_base + c)
          done
        end;
        if tail_start < cols then begin
          if !pen_y <> row || !pen_x <> tail_start then begin
            emit_cup buf ~row ~col:tail_start;
            pen_y := row;
            pen_x := tail_start
          end;
          reset_pen_for_clear ();
          Buffer.add_string buf "\x1b[K";
          incr dirty_runs;
          pen_x := cols
        end
      done
    end
  end
  else begin
    let flags = t.dirty_row_flags in
    let start_row, first_row_col =
      if pre_first_idx < 0 then (rows, -1)
      else (pre_first_idx / cols, pre_first_idx mod cols)
    in
    for row = start_row to rows - 1 do
      let row_base = row * cols in
      let first_dirty =
        if row = start_row && first_row_col >= 0 then first_row_col
        else if simple_grids then
          find_first_dirty_simple f_glyphs b_glyphs f_styles b_styles row_base cols 0
        else
          find_first_dirty_slow t.front next_grid f_glyphs b_glyphs f_styles
            b_styles row_base cols 0
      in
      if first_dirty >= 0 then begin
        ensure_header ();
        if first_dirty > 0 then Array.fill flags 0 first_dirty false;
        Array.unsafe_set flags first_dirty true;
        let row_dirty = ref 1 in
        if simple_grids then
          for col = first_dirty + 1 to cols - 1 do
            let idx = row_base + col in
            let d =
              Ba1.unsafe_get f_glyphs idx <> Ba1.unsafe_get b_glyphs idx
              || Ba1.unsafe_get f_styles idx <> Ba1.unsafe_get b_styles idx
            in
            Array.unsafe_set flags col d;
            if d then incr row_dirty
          done
        else
          for col = first_dirty + 1 to cols - 1 do
            let d =
              cells_differ_slow ~front:t.front ~back:next_grid
                ~f_glyphs ~b_glyphs ~f_styles ~b_styles (row_base + col)
            in
            Array.unsafe_set flags col d;
            if d then incr row_dirty
          done;
        total_dirty := !total_dirty + !row_dirty;
        let row_has_wide = Array.unsafe_get b_row_has_wide row in
        if row_has_wide then
          for col = first_dirty to cols - 1 do
            if Array.unsafe_get flags col then begin
              let g = Ba1.unsafe_get b_glyphs (row_base + col) in
              if g = glyph_cont && col > 0 then
                Array.unsafe_set flags (col - 1) true
              else if g >= glyph_wide_min && col + 1 < cols then
                Array.unsafe_set flags (col + 1) true
            end
          done;
        let tail_start =
          find_tail_start_loop b_glyphs b_styles glyph_empty el0_mask row_base cols
        in
        let tail_dirty = ref false in
        if tail_start < cols then begin
          let c = ref (Int.max tail_start first_dirty) in
          while !c < cols && not !tail_dirty do
            if Array.unsafe_get flags !c then tail_dirty := true;
            incr c
          done
        end;
        let emit_limit = if !tail_dirty then tail_start else cols in
        let start_scan =
          if first_dirty > 0 && Array.unsafe_get flags (first_dirty - 1) then
            first_dirty - 1
          else first_dirty
        in
        let col = ref start_scan in
        while !col < emit_limit do
          if not (Array.unsafe_get flags !col) then incr col
          else begin
            let run_start = !col in
            let run_end = ref run_start in
            let scan = ref (run_start + 1) in
            let clean_gap = ref 0 in
            while !scan < emit_limit && !clean_gap <= run_bridge_max_clean do
              if Array.unsafe_get flags !scan then begin
                run_end := !scan;
                clean_gap := 0
              end
              else incr clean_gap;
              incr scan
            done;
            let start_c =
              if row_has_wide && run_start > 0
                 && Ba1.unsafe_get b_glyphs (row_base + run_start) = glyph_cont
              then run_start - 1
              else run_start
            in
            let end_c =
              if row_has_wide && !run_end + 1 < emit_limit
                 && Ba1.unsafe_get b_glyphs (row_base + !run_end) >= glyph_wide_min
              then !run_end + 1
              else !run_end
            in
            if !pen_y <> row || !pen_x <> start_c then begin
              emit_cup buf ~row ~col:start_c;
              pen_y := row;
              pen_x := start_c
            end;
            incr dirty_runs;
            for c = start_c to end_c do
              emit_cell_at (row_base + c)
            done;
            col := end_c + 1
          end
        done;
        if !tail_dirty && tail_start < cols then begin
          if !pen_y <> row || !pen_x <> tail_start then begin
            emit_cup buf ~row ~col:tail_start;
            pen_y := row;
            pen_x := tail_start
          end;
          reset_pen_for_clear ();
          Buffer.add_string buf "\x1b[K";
          incr dirty_runs;
          pen_x := cols
        end
      end
    done
  end;
  if not !header_emitted && not cursor_changed then
    let diff_us = Clock.Mono.us_since (Clock.Mono.now ()) ~since:t0 in
    {
      dirty_cells = 0;
      dirty_runs = 0;
      bytes_emitted = 0;
      diff_us = Int.max 0 diff_us;
      full_repaint = false;
    }
  else begin
    ensure_header ();
    if !pen_link <> 0 && osc8 then
      Buffer.add_string buf "\x1b]8;;\x1b\\";
    Buffer.add_string buf "\x1b[0m";
    Buffer.add_string buf "\x1b[?7h";
    if cursor.visible then begin
      let shape_seq =
        match cursor.shape with
        | Block -> "\x1b[2 q"
        | Underline -> "\x1b[4 q"
        | Bar -> "\x1b[6 q"
      in
      Buffer.add_string buf shape_seq;
      let cx = Int.max 0 (Int.min (Int.max 0 (cols - 1)) cursor.x) in
      let cy = Int.max 0 (Int.min (Int.max 0 (rows - 1)) cursor.y) in
      emit_cup buf ~row:cy ~col:cx;
      Buffer.add_string buf "\x1b[?25h"
    end;
    if t.caps.synchronized_output then Buffer.add_string buf "\x1b[?2026l";
    let payload = Buffer.contents buf in
    let bytes_emitted = String.length payload in
    write payload;
    t.force_full <- false;
    t.last_cursor <- Some cursor;
    let diff_us = Clock.Mono.us_since (Clock.Mono.now ()) ~since:t0 in
    {
      dirty_cells = !total_dirty;
      dirty_runs = !dirty_runs;
      bytes_emitted;
      diff_us = Int.max 0 diff_us;
      full_repaint;
    }
  end

let present_back t ~cursor ~write =
  let stats = diff_and_emit t ~next_grid:t.back ~cursor ~write in
  let old_front = t.front in
  t.front <- t.back;
  t.back <- old_front;
  stats

let present t ~grid ~cursor ~write =
  let stats = diff_and_emit t ~next_grid:grid ~cursor ~write in
  if Cell_grid.cols grid <> Cell_grid.cols t.front
     || Cell_grid.rows grid <> Cell_grid.rows t.front
  then t.front <- Cell_grid.create ~cols:(Cell_grid.cols grid) ~rows:(Cell_grid.rows grid);
  Cell_grid.copy_into ~src:grid ~dst:t.front;
  stats
