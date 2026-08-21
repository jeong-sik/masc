type cursor =
  | Hidden
  | Visible_at of {
      row : int;
      column : int;
    }

type frame = {
  surface_key : string;
  terminal_rows : int;
  terminal_cols : int;
  cursor : cursor;
  lines : string list;
}

type snapshot = {
  surface_key : string;
  terminal_rows : int;
  terminal_cols : int;
  cursor : cursor;
  screen : string array;
}

type t = {
  synchronized_output : bool;
  mutable invalidated : bool;
  mutable previous : snapshot option;
}

let begin_synchronized_output = "\027[?2026h"
let end_synchronized_output = "\027[?2026l"
let disable_autowrap = "\027[?7l"
let enable_autowrap = "\027[?7h"
let reset_style = "\027[0m"
let clear_screen = "\027[2J"
let erase_line = "\027[2K"
let hide_cursor = "\027[?25l"
let show_cursor = "\027[?25h"

let create ~synchronized_output () =
  { synchronized_output; invalidated = true; previous = None }

let invalidate presenter = presenter.invalidated <- true

let cleanup presenter ~write ~flush =
  try
    write
      ((if presenter.synchronized_output then end_synchronized_output else "")
       ^ reset_style ^ show_cursor ^ enable_autowrap ^ clear_screen ^ "\027[H");
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
  && previous.terminal_rows = max 1 frame.terminal_rows
  && previous.terminal_cols = max 1 frame.terminal_cols
  && same_cursor_mode previous.cursor frame.cursor

let changed_rows ~full_redraw ~(previous : snapshot option) screen =
  let rows = Array.length screen in
  List.init rows Fun.id
  |> List.filter (fun row ->
       full_redraw
       ||
       match previous with
       | None -> true
       | Some previous -> not (String.equal previous.screen.(row) screen.(row)))

let append_row buffer row line =
  Printf.bprintf buffer "\027[%d;1H%s%s%s%s" (row + 1) reset_style erase_line
    line reset_style

let append_cursor buffer ~terminal_rows ~terminal_cols = function
  | Hidden -> Buffer.add_string buffer hide_cursor
  | Visible_at { row; column } ->
      let row = max 1 (min terminal_rows row) in
      let column = max 1 (min terminal_cols column) in
      Printf.bprintf buffer "\027[%d;%dH%s" row column show_cursor

let present presenter ~invalidate_before ~write ~flush (frame : frame) =
  if invalidate_before then invalidate presenter;
  let terminal_rows = max 1 frame.terminal_rows in
  let terminal_cols = max 1 frame.terminal_cols in
  let screen = screen_of_frame frame in
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
  let rows =
    changed_rows ~full_redraw ~previous:presenter.previous screen
  in
  match rows, cursor_changed with
  | [], false -> ()
  | _ ->
      let buffer = Buffer.create 4096 in
      if presenter.synchronized_output then
        Buffer.add_string buffer begin_synchronized_output;
      Buffer.add_string buffer disable_autowrap;
      if full_redraw then Buffer.add_string buffer clear_screen;
      List.iter (fun row -> append_row buffer row screen.(row)) rows;
      append_cursor buffer ~terminal_rows ~terminal_cols frame.cursor;
      Buffer.add_string buffer enable_autowrap;
      if presenter.synchronized_output then
        Buffer.add_string buffer end_synchronized_output;
      let output = Buffer.contents buffer in
      let snapshot =
        { surface_key = frame.surface_key;
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
         presenter.invalidated <- false
       with exn ->
         presenter.invalidated <- true;
         raise exn)
