(** ANSI escape codes and terminal helpers — split from masc_tui.ml (#3808) *)

(** ANSI escape codes *)
module Ansi = struct
  let clear = "\027[2J\027[H"
  let hide_cursor = "\027[?25l"
  let show_cursor = "\027[?25h"

  (* Colors *)
  let reset = "\027[0m"
  let bold = "\027[1m"
  let dim = "\027[2m"

  let _black = "\027[30m"
  let red = "\027[31m"
  let green = "\027[32m"
  let yellow = "\027[33m"
  let blue = "\027[34m"
  let magenta = "\027[35m"
  let cyan = "\027[36m"
  let white = "\027[37m"
  let gray = "\027[90m"

  let _bg_black = "\027[40m"
  let _bg_blue = "\027[44m"
  let bg_white = "\027[47m"

  (* Cursor movement *)
  let move_to row col = Printf.sprintf "\027[%d;%dH" row col

  (* Reverse video for selection highlight *)
  let reverse = "\027[7m"

  (* Box drawing characters *)
  let box_h = "\xe2\x94\x80"  (* horizontal line *)
  let box_v = "\xe2\x94\x82"  (* vertical line *)
  let box_tl = "\xe2\x94\x8c" (* top-left corner *)
  let box_tr = "\xe2\x94\x90" (* top-right corner *)
  let box_bl = "\xe2\x94\x94" (* bottom-left corner *)
  let box_br = "\xe2\x94\x98" (* bottom-right corner *)
  let _box_t = "\xe2\x94\xac"  (* top tee *)
  let _box_b = "\xe2\x94\xb4"  (* bottom tee *)
  let box_l = "\xe2\x94\x9c"  (* left tee *)
  let box_r = "\xe2\x94\xa4"  (* right tee *)
  let _box_x = "\xe2\x94\xbc"  (* cross *)
end

(** Terminal size changes only after SIGWINCH. Cache the process-backed probe so
    an idle TUI does not spawn [tput] twice per frame. *)
let terminal_size_cache =
  Masc_tui_render_schedule.Terminal_size_cache.create ~fallback:(24, 80)

let invalidate_terminal_size () =
  Masc_tui_render_schedule.Terminal_size_cache.invalidate terminal_size_cache

(** Writes outside the frame presenter make its cached screen untrustworthy.
    Direct producers mark before touching the TTY; the console sink observer
    marks after each attempted mirror write. *)
let terminal_write_outside_frame = Atomic.make false

let note_terminal_write_outside_frame () =
  Atomic.set terminal_write_outside_frame true

let consume_terminal_write_outside_frame () =
  Atomic.exchange terminal_write_outside_frame false

let terminal_write_outside_frame_pending () =
  Atomic.get terminal_write_outside_frame

let probe_terminal_size () =
  let read_tput arg =
    try
      let line, status =
        With_process.with_process_args_in "tput" [| "tput"; arg |]
          input_line
      in
      match status with
      | Unix.WEXITED 0 -> int_of_string_opt (String.trim line)
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> None
    with Unix.Unix_error _ | Sys_error _ | End_of_file -> None
  in
  match read_tput "cols", read_tput "lines" with
  | Some cols, Some rows -> Some (rows, cols)
  | _ -> None

(** Get terminal size (fallback to 80x24). *)
let get_terminal_size () =
  Masc_tui_render_schedule.Terminal_size_cache.get terminal_size_cache
    ~probe:probe_terminal_size

(** Draw horizontal line *)
let draw_hline width =
  String.concat "" (List.init width (fun _ -> Ansi.box_h))

(** Pad or truncate plain text without counting ANSI style bytes. *)
let fit_width = Masc_tui_message_layout.fit_width

(** External values become one printable logical row before renderer-owned ANSI
    styling or width calculation is applied. *)
module Terminal_text = struct
  let single_line text = Masc.Tui_decode.sanitize_terminal_text text
  let optional_single_line = Option.map single_line

  let single_line_or ~default value =
    Option.value ~default (optional_single_line value)
end

let is_keeper name =
  String.length name >= 7 && String.sub name 0 7 = "keeper-"

(** Agent icon — deterministic by name hash, vendor-agnostic *)
let agent_icon name =
  let icons = [| "\xf0\x9f\x9f\xa3"; "\xf0\x9f\x94\xb5"; "\xf0\x9f\x9f\xa2"; "\xf0\x9f\x9f\xa1"; "\xf0\x9f\x94\xb4" |] in
  if is_keeper name then "\xf0\x9f\x9b\xa1"  (* shield for keepers *)
  else icons.(Hashtbl.hash name mod Array.length icons)

(** Agent color — deterministic by name hash, vendor-agnostic *)
let agent_color name =
  let colors = [| Ansi.magenta; Ansi.blue; Ansi.green; Ansi.yellow; Ansi.cyan |] in
  if is_keeper name then Ansi.white
  else colors.(Hashtbl.hash name mod Array.length colors)

(** Status color *)
let status_color status =
  match status with
  | "working" | "in_progress" -> Ansi.yellow
  | "idle" | "online" -> Ansi.green
  | "offline" -> Ansi.gray
  | "error" -> Ansi.red
  | _ -> Ansi.white

(** Task status icon *)
let task_status_icon status =
  match status with
  | Masc_domain.Done _ -> "\xe2\x97\x8f"  (* filled circle *)
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.AwaitingVerification _ -> "\xe2\x97\x90"  (* half circle *)
  | Masc_domain.Todo -> "\xe2\x97\x8b"  (* empty circle *)
  | Masc_domain.Cancelled _ -> "\xc3\x97"

(** Priority indicator *)
let priority_indicator p =
  if p <= 1 then Ansi.red ^ "!!!" ^ Ansi.reset
  else if p <= 2 then Ansi.red ^ "!!" ^ Ansi.reset
  else if p <= 3 then Ansi.yellow ^ "!" ^ Ansi.reset
  else ""

(** Soul profile color *)
let soul_color profile =
  match profile with
  | "relationship" -> Ansi.magenta
  | "delivery" -> Ansi.green
  | "balanced" -> Ansi.cyan
  | "creative" -> Ansi.yellow
  | _ -> Ansi.white

(** Format a timestamp for display (show date portion or relative) *)
let short_ts s =
  if String.length s > 19 then String.sub s 0 19
  else if String.length s = 0 then "(never)"
  else s

(** Context ratio color: green < 50%, yellow 50-80%, red > 80% *)
let ctx_color ratio =
  if ratio >= 0.8 then Ansi.red
  else if ratio >= 0.5 then Ansi.yellow
  else Ansi.green

(** Format context ratio as a visual bar *)
let ctx_bar ratio width =
  let width = Masc_tui_render_schedule.nonnegative_width width in
  let filled = int_of_float (ratio *. float_of_int width) in
  let filled = max 0 (min width filled) in
  let empty = width - filled in
  let color = ctx_color ratio in
  Printf.sprintf "%s%s%s%s"
    color
    (String.make filled '#')
    (Ansi.gray ^ String.make empty '-' ^ Ansi.reset)
    Ansi.reset

(** Format channel name with color *)
let channel_color ch =
  match ch with
  | "heartbeat" -> Ansi.dim ^ "hb" ^ Ansi.reset
  | "turn" -> Ansi.cyan ^ "turn" ^ Ansi.reset
  | "compaction" -> Ansi.yellow ^ "comp" ^ Ansi.reset
  | "handoff" -> Ansi.magenta ^ "hand" ^ Ansi.reset
  | "initiative" -> Ansi.blue ^ "init" ^ Ansi.reset
  | s -> s

(** Shared helper: draw box top border *)
let box_top buf cols =
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_tl (draw_hline (cols - 2)) Ansi.box_tr Ansi.reset)

(** Shared helper: draw box bottom border *)
let box_bottom buf cols =
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_bl (draw_hline (cols - 2)) Ansi.box_br Ansi.reset)

(** Shared helper: draw box divider *)
let box_divider buf cols =
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset)

(** Shared helper: draw a line inside a box *)
let box_line buf cols content =
  let inner = cols - 4 in
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    (fit_width content inner)
    Ansi.gray Ansi.box_v Ansi.reset)

(** Fit plain content first, then add style bytes so ANSI escapes never count
    toward the terminal width. *)
let box_line_styled buf cols ~style content =
  let inner = cols - 4 in
  let content = fit_width content inner in
  Buffer.add_string buf
    (Printf.sprintf "%s%s%s %s%s%s %s%s%s\n" Ansi.gray Ansi.box_v
       Ansi.reset style content Ansi.reset Ansi.gray Ansi.box_v Ansi.reset)

(** Shared helper: empty line inside a box *)
let box_empty buf cols =
  let inner = cols - 4 in
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    (String.make inner ' ')
    Ansi.gray Ansi.box_v Ansi.reset)
