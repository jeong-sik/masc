module Clock = Masc_tui_core.Clock

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
    buf = Buffer.create initial_buffer_bytes;
  }

let capabilities t = t.caps
let set_capabilities t caps =
  t.caps <- caps;
  t.force_full <- true

let back_grid t = t.back

let resize t ~cols ~rows =
  let cols = Int.max 0 cols in
  let rows = Int.max 0 rows in
  t.front <- Cell_grid.create ~cols ~rows;
  t.back <- Cell_grid.create ~cols ~rows;
  t.dirty_row_flags <- Array.make cols false;
  t.force_full <- true;
  t.last_cursor <- None

let invalidate t = t.force_full <- true

let add_int buf n = Buffer.add_string buf (Int.to_string n)

let emit_cup buf ~row ~col =
  Buffer.add_string buf "\x1b[";
  add_int buf (row + 1);
  Buffer.add_char buf ';';
  add_int buf (col + 1);
  Buffer.add_char buf 'H'

let emit_fg buf color =
  match color with
  | Color.Default -> Buffer.add_string buf "\x1b[39m"
  | Color.Ansi16 idx ->
      let code = if idx < 8 then 30 + idx else 90 + (idx - 8) in
      Buffer.add_string buf "\x1b[";
      add_int buf code;
      Buffer.add_char buf 'm'
  | Color.Ansi256 idx ->
      Buffer.add_string buf "\x1b[38;5;";
      add_int buf idx;
      Buffer.add_char buf 'm'
  | Color.Rgb rgb ->
      Buffer.add_string buf "\x1b[38;2;";
      add_int buf (Color.red rgb);
      Buffer.add_char buf ';';
      add_int buf (Color.green rgb);
      Buffer.add_char buf ';';
      add_int buf (Color.blue rgb);
      Buffer.add_char buf 'm'

let emit_bg buf color =
  match color with
  | Color.Default -> Buffer.add_string buf "\x1b[49m"
  | Color.Ansi16 idx ->
      let code = if idx < 8 then 40 + idx else 100 + (idx - 8) in
      Buffer.add_string buf "\x1b[";
      add_int buf code;
      Buffer.add_char buf 'm'
  | Color.Ansi256 idx ->
      Buffer.add_string buf "\x1b[48;5;";
      add_int buf idx;
      Buffer.add_char buf 'm'
  | Color.Rgb rgb ->
      Buffer.add_string buf "\x1b[48;2;";
      add_int buf (Color.red rgb);
      Buffer.add_char buf ';';
      add_int buf (Color.green rgb);
      Buffer.add_char buf ';';
      add_int buf (Color.blue rgb);
      Buffer.add_char buf 'm'

(* Never emits SGR dim (CSI 2m) — Attr contains only bold/italic/underline/reverse/strike. *)
let emit_attr_flags buf added =
  if Attr.has added Attr.bold then Buffer.add_string buf "\x1b[1m";
  if Attr.has added Attr.italic then Buffer.add_string buf "\x1b[3m";
  if Attr.has added Attr.underline then Buffer.add_string buf "\x1b[4m";
  if Attr.has added Attr.reverse then Buffer.add_string buf "\x1b[7m";
  if Attr.has added Attr.strike then Buffer.add_string buf "\x1b[9m"

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

let is_el0_erasable (cell : Cell_grid.cell) =
  match cell.glyph with
  | Cell_grid.Empty ->
      Color.equal cell.style.bg Color.Default
      && Int.equal cell.style.hyperlink_id 0
      && not (Attr.has cell.style.attrs Attr.reverse)
      && not (Attr.has cell.style.attrs Attr.underline)
      && not (Attr.has cell.style.attrs Attr.strike)
  | Ascii _ | Braille _ | Utf8 _ | Continuation -> false

let cells_differ ~front ~back idx =
  let fc = Cell_grid.get_linear front idx in
  let bc = Cell_grid.get_linear back idx in
  if not (Cell_grid.cell_equal fc bc) then true
  else if bc.style.hyperlink_id = 0 then false
  else
    not
      (Option.equal String.equal
         (Cell_grid.hyperlink_uri front fc.style.hyperlink_id)
         (Cell_grid.hyperlink_uri back bc.style.hyperlink_id))

let ensure_row_flags t cols =
  if Array.length t.dirty_row_flags < cols then
    t.dirty_row_flags <- Array.make cols false

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
  let total_dirty = ref 0 in
  if full_repaint then total_dirty := cols * rows
  else begin
    let total_cells = cols * rows in
    for idx = 0 to total_cells - 1 do
      if cells_differ ~front:t.front ~back:next_grid idx then incr total_dirty
    done
  end;
  let cursor_changed =
    match t.last_cursor with
    | None -> true
    | Some prev -> not (cursor_equal prev cursor)
  in
  if !total_dirty = 0 && not cursor_changed then
    let diff_us = Clock.Mono.us_since (Clock.Mono.now ()) ~since:t0 in
    {
      dirty_cells = 0;
      dirty_runs = 0;
      bytes_emitted = 0;
      diff_us = Int.max 0 diff_us;
      full_repaint = false;
    }
  else begin
    let buf = t.buf in
    Buffer.clear buf;
    if t.caps.synchronized_output then Buffer.add_string buf "\x1b[?2026h";
    Buffer.add_string buf "\x1b[?25l";
    Buffer.add_string buf "\x1b[?7l";
    if full_repaint then Buffer.add_string buf "\x1b[0m";
    let pen_fg = ref Color.Default in
    let pen_bg = ref Color.Default in
    let pen_attrs = ref Attr.none in
    let pen_link = ref 0 in
    let pen_x = ref (-1) in
    let pen_y = ref (-1) in
    let dirty_runs = ref 0 in
    let reset_pen_for_clear () =
      if !pen_link <> 0 && t.caps.osc8_hyperlinks then begin
        Buffer.add_string buf "\x1b]8;;\x1b\\";
        pen_link := 0
      end;
      if
        not (Color.equal !pen_bg Color.Default)
        || not (Attr.equal !pen_attrs Attr.none)
      then begin
        Buffer.add_string buf "\x1b[0m";
        pen_fg := Color.Default;
        pen_bg := Color.Default;
        pen_attrs := Attr.none
      end
    in
    let apply_style (style : Style.t) =
      let target_fg = Color.downscale ~depth:t.caps.color_depth style.fg in
      let target_bg = Color.downscale ~depth:t.caps.color_depth style.bg in
      let target_attrs = style.attrs in
      let target_link =
        if t.caps.osc8_hyperlinks then style.hyperlink_id else 0
      in
      let cur_bits = Attr.to_bits !pen_attrs in
      let next_bits = Attr.to_bits target_attrs in
      if cur_bits land lnot next_bits <> 0 then begin
        Buffer.add_string buf "\x1b[0m";
        pen_fg := Color.Default;
        pen_bg := Color.Default;
        pen_attrs := Attr.none;
        emit_attr_flags buf target_attrs;
        pen_attrs := target_attrs
      end
      else if cur_bits <> next_bits then begin
        let added_bits = next_bits land lnot cur_bits in
        if added_bits land Attr.to_bits Attr.bold <> 0 then
          Buffer.add_string buf "\x1b[1m";
        if added_bits land Attr.to_bits Attr.italic <> 0 then
          Buffer.add_string buf "\x1b[3m";
        if added_bits land Attr.to_bits Attr.underline <> 0 then
          Buffer.add_string buf "\x1b[4m";
        if added_bits land Attr.to_bits Attr.reverse <> 0 then
          Buffer.add_string buf "\x1b[7m";
        if added_bits land Attr.to_bits Attr.strike <> 0 then
          Buffer.add_string buf "\x1b[9m";
        pen_attrs := target_attrs
      end;
      if not (Color.equal !pen_fg target_fg) then begin
        emit_fg buf target_fg;
        pen_fg := target_fg
      end;
      if not (Color.equal !pen_bg target_bg) then begin
        emit_bg buf target_bg;
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
      end
    in
    let emit_cell (cell : Cell_grid.cell) =
      match cell.glyph with
      | Cell_grid.Continuation -> ()
      | Empty ->
          apply_style cell.style;
          Buffer.add_char buf ' ';
          pen_x := !pen_x + 1
      | Ascii ch ->
          apply_style cell.style;
          Buffer.add_char buf ch;
          pen_x := !pen_x + 1
      | Braille mask ->
          apply_style cell.style;
          if t.caps.braille_safe then
            Buffer.add_string buf (Cell_grid.braille_utf8 mask)
          else Buffer.add_char buf (ascii_fallback_of_braille mask);
          pen_x := !pen_x + 1
      | Utf8 s ->
          apply_style cell.style;
          Buffer.add_string buf s;
          pen_x := !pen_x + cell.width
    in
    let flags = t.dirty_row_flags in
    for row = 0 to rows - 1 do
      let row_base = row * cols in
      let row_has_dirty = ref false in
      for col = 0 to cols - 1 do
        let d = full_repaint || cells_differ ~front:t.front ~back:next_grid (row_base + col) in
        flags.(col) <- d;
        if d then row_has_dirty := true
      done;
      if !row_has_dirty then begin
        (* Wide-glyph dirty coupling: ensure lead and continuation halves always
           re-emit together as an atomic pair. *)
        for col = 0 to cols - 1 do
          if flags.(col) then begin
            let cell = Cell_grid.get_linear next_grid (row_base + col) in
            (match cell.glyph with
             | Cell_grid.Continuation when col > 0 -> flags.(col - 1) <- true
             | Cell_grid.Utf8 _ when cell.width = 2 && col + 1 < cols ->
                 flags.(col + 1) <- true
             | Cell_grid.Empty
             | Cell_grid.Ascii _
             | Cell_grid.Braille _
             | Cell_grid.Utf8 _
             | Cell_grid.Continuation ->
                 ())
          end
        done;
        (* Find trailing EL0-erasable blank suffix [tail_start .. cols - 1]. *)
        let rec find_tail_start col =
          if col <= 0 then 0
          else if is_el0_erasable (Cell_grid.get_linear next_grid (row_base + col - 1)) then
            find_tail_start (col - 1)
          else col
        in
        let tail_start = find_tail_start cols in
        let tail_dirty = ref false in
        for col = tail_start to cols - 1 do
          if flags.(col) then tail_dirty := true
        done;
        let emit_limit = if !tail_dirty then tail_start else cols in
        let col = ref 0 in
        while !col < emit_limit do
          if not flags.(!col) then incr col
          else begin
            let run_start = !col in
            let run_end = ref run_start in
            let scan = ref (run_start + 1) in
            let clean_gap = ref 0 in
            while !scan < emit_limit && !clean_gap <= run_bridge_max_clean do
              if flags.(!scan) then begin
                run_end := !scan;
                clean_gap := 0
              end
              else incr clean_gap;
              incr scan
            done;
            (* Keep wide glyphs whole at run boundaries. *)
            let start_c =
              match (Cell_grid.get_linear next_grid (row_base + run_start)).glyph with
              | Cell_grid.Continuation when run_start > 0 -> run_start - 1
              | Cell_grid.Empty
              | Cell_grid.Ascii _
              | Cell_grid.Braille _
              | Cell_grid.Utf8 _
              | Cell_grid.Continuation ->
                  run_start
            in
            let end_c =
              let last_cell = Cell_grid.get_linear next_grid (row_base + !run_end) in
              if last_cell.width = 2 && !run_end + 1 < emit_limit then
                !run_end + 1
              else !run_end
            in
            if !pen_y <> row || !pen_x <> start_c then begin
              emit_cup buf ~row ~col:start_c;
              pen_y := row;
              pen_x := start_c
            end;
            incr dirty_runs;
            for c = start_c to end_c do
              emit_cell (Cell_grid.get_linear next_grid (row_base + c))
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
    done;
    if !pen_link <> 0 && t.caps.osc8_hyperlinks then
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
