type cursor =
  | Hidden
  | Visible_at of {
      row : int;
      column : int;
    }

type frame = {
  surface_key : string;
  compact_frame : bool;
  terminal_rows : int;
  terminal_cols : int;
  cursor : cursor;
  lines : string list;
}

type present_result =
  | Presented
  | Unchanged

type snapshot = {
  surface_key : string;
  compact_frame : bool;
  terminal_rows : int;
  terminal_cols : int;
  cursor : cursor;
  screen : string array;
}

type t = {
  synchronized_output : bool;
  output_buffer : Buffer.t;
  mutable invalidated : bool;
  mutable previous : snapshot option;
}

let begin_synchronized_output = "\027[?2026h"
let end_synchronized_output = "\027[?2026l"
let disable_autowrap = "\027[?7l"
let enable_autowrap = "\027[?7h"
let reset_style = "\027[0m"
let clear_screen = "\027[2J"

(* The frame gets its own screen. Sharing the shell's buffer means the wheel
   scrolls the terminal's scrollback and takes the frame with it, the shell's
   own output sits above whatever the first paint clears, and quitting leaves
   the last frame where the prompt should be. Every full-screen program that
   draws at absolute coordinates does this; nothing else makes row 1 of the
   frame reliably row 1 of the window. *)
let enter_alternate_screen = "\027[?1049h"
let leave_alternate_screen = "\027[?1049l"
(* OSC 10 and 11 are the terminal's own text and page colours; 110 and 111 put
   them back. Both belong here rather than in the theme module: a scheme is a
   set of colours, and painting the window those colours live in is the
   renderer's job. A terminal that does not know these ignores them, which is
   why they can be sent unconditionally.

   They are set as a pair, and the type below makes that the only thing a
   caller can do. Sending one alone is not a smaller version of the change,
   it is the readable case turned into the unreadable one: paint the page
   white and leave the reader's near-white default text on it and masc draws
   white on white. That was live between #31196 and this change.

   The reset matters more than the set. A terminal keeps whatever colours it
   was last told to use, so an exit that skips 110 and 111 leaves the reader's
   shell wearing masc's until they close the window. *)
type page =
  { foreground : Masc_tui_terminal_palette.rgb
  ; background : Masc_tui_terminal_palette.rgb
  }

let osc_color code rgb =
  Printf.sprintf "\027]%d;rgb:%02x/%02x/%02x\027\\" code
    (Masc_tui_terminal_palette.red rgb)
    (Masc_tui_terminal_palette.green rgb)
    (Masc_tui_terminal_palette.blue rgb)
;;

let set_page_colors { foreground; background } =
  osc_color 10 foreground ^ osc_color 11 background
;;

let reset_page_colors = "\027]110\027\\\027]111\027\\"

let hide_cursor = "\027[?25l"
let show_cursor = "\027[?25h"

let create ~synchronized_output () =
  { synchronized_output;
    output_buffer = Buffer.create 4096;
    invalidated = true;
    previous = None;
  }

let invalidate presenter = presenter.invalidated <- true

let last_frame_is_compact presenter =
  presenter.invalidated
  ||
  match presenter.previous with
  | None -> true
  | Some previous -> previous.compact_frame

(* Sent when a scheme is picked and when one is dropped. [None] is "follow the
   terminal", which is a reset rather than a colour: masc has no opinion to
   send once the reader has withdrawn theirs. *)
let sync_page ~write ~flush page =
  try
    write
      (match page with
       | Some page -> set_page_colors page
       | None -> reset_page_colors);
    flush ()
  with _ -> ()
;;

let setup presenter ~write ~flush =
  presenter.invalidated <- true;
  try
    write enter_alternate_screen;
    flush ()
  with _ -> ()

let cleanup presenter ~write ~flush =
  try
    write
      ((if presenter.synchronized_output then end_synchronized_output else "")
       ^ reset_style ^ show_cursor ^ enable_autowrap
       (* Before leaving the alternate screen, so the shell that comes back is
          already wearing its own colours rather than masc's. *)
       ^ reset_page_colors ^ leave_alternate_screen
       (* Started at probe time so a theme switch would be reported. Left on,
          the terminal keeps reporting to whatever runs next, which receives
          [CSI ? 997 ; n n] as typed input it never asked for. *)
       ^ Masc_tui_terminal_palette.theme_mode_unsubscribe);
    flush ()
  with _ -> ()

let screen_of_frame (frame : frame) =
  let terminal_rows = max 1 frame.terminal_rows in
  let screen = Array.make terminal_rows "" in
  let rec fill row = function
    | _ when row >= terminal_rows -> ()
    | [] -> ()
    | line :: rest ->
        screen.(row) <- line;
        fill (row + 1) rest
  in
  fill 0 frame.lines;
  screen

let same_cursor_mode left right =
  match left, right with
  | Hidden, Hidden | Visible_at _, Visible_at _ -> true
  | Hidden, Visible_at _ | Visible_at _, Hidden -> false

let same_geometry (previous : snapshot) (frame : frame) =
  String.equal previous.surface_key frame.surface_key
  && Bool.equal previous.compact_frame frame.compact_frame
  && previous.terminal_rows = max 1 frame.terminal_rows
  && previous.terminal_cols = max 1 frame.terminal_cols
  && same_cursor_mode previous.cursor frame.cursor

let row_prefix_cache_size = 256

let row_prefixes =
  Array.init row_prefix_cache_size (fun row ->
    Printf.sprintf "\027[%d;1H\027[0m\027[2K" (row + 1))

let append_row buffer row line =
  if row >= 0 && row < row_prefix_cache_size then
    Buffer.add_string buffer row_prefixes.(row)
  else
    Printf.bprintf buffer "\027[%d;1H\027[0m\027[2K" (row + 1);
  Buffer.add_string buffer line;
  Buffer.add_string buffer reset_style

let append_cursor buffer ~terminal_rows ~terminal_cols = function
  | Hidden -> Buffer.add_string buffer hide_cursor
  | Visible_at { row; column } ->
      let row = max 1 (min terminal_rows row) in
      let column = max 1 (min terminal_cols column) in
      Printf.bprintf buffer "\027[%d;%dH%s" row column show_cursor

let lines_equal_to_screen (lines : string list) (screen : string array) ~terminal_rows =
  let rec loop row = function
    | [] ->
        let rec all_empty r =
          if r >= terminal_rows then true
          else if String.equal screen.(r) "" then all_empty (r + 1)
          else false
        in
        all_empty row
    | _ when row >= terminal_rows -> true
    | line :: rest ->
        if String.equal screen.(row) line then loop (row + 1) rest
        else false
  in
  loop 0 lines

let present presenter ~invalidate_before ~write ~flush (frame : frame) =
  if invalidate_before then invalidate presenter;
  let terminal_rows = max 1 frame.terminal_rows in
  let terminal_cols = max 1 frame.terminal_cols in
  let cursor_changed =
    match presenter.previous with
    | None -> true
    | Some previous -> previous.cursor <> frame.cursor
  in
  let full_redraw =
    presenter.invalidated
    ||
    match presenter.previous with
    | None -> true
    | Some previous -> not (same_geometry previous frame)
  in
  let unchanged =
    (not full_redraw)
    && (not cursor_changed)
    && (match presenter.previous with
        | Some previous ->
            lines_equal_to_screen frame.lines previous.screen ~terminal_rows
        | None -> false)
  in
  if unchanged then
    Unchanged
  else begin
    let screen = screen_of_frame frame in
    let prev_screen =
      match presenter.previous with
      | Some previous -> Some previous.screen
      | None -> None
    in
    let buffer = presenter.output_buffer in
    Buffer.clear buffer;
    if presenter.synchronized_output then
      Buffer.add_string buffer begin_synchronized_output;
    Buffer.add_string buffer disable_autowrap;
    if full_redraw then Buffer.add_string buffer clear_screen;
    (match prev_screen with
     | Some prev when not full_redraw ->
         for row = 0 to terminal_rows - 1 do
           if not (String.equal prev.(row) screen.(row)) then
             append_row buffer row screen.(row)
         done
     | _ ->
         for row = 0 to terminal_rows - 1 do
           append_row buffer row screen.(row)
         done);
    append_cursor buffer ~terminal_rows ~terminal_cols frame.cursor;
    Buffer.add_string buffer enable_autowrap;
    if presenter.synchronized_output then
      Buffer.add_string buffer end_synchronized_output;
    let output = Buffer.contents buffer in
    let snapshot =
      { surface_key = frame.surface_key;
        compact_frame = frame.compact_frame;
        terminal_rows;
        terminal_cols;
        cursor = frame.cursor;
        screen;
      }
    in
    (try
       write output;
       flush ();
       presenter.previous <- Some snapshot;
       presenter.invalidated <- false;
       Presented
     with exn ->
       presenter.invalidated <- true;
       raise exn)
  end
