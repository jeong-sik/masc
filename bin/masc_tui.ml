[@@@warning "-32-69"]
module Tui_decode = Masc_mcp.Tui_decode
open Tui_decode

(* MASC TUI - Terminal User Interface for Multi-Agent Coordination

    Phase 1: keeper selector + detail view
    Phase 2: keeper log viewer, message sending, live context status

    Usage: masc-tui [--port PORT] [--room ROOM] [--refresh SECONDS]

    Modes:
    - Dashboard: agents/tasks/events overview
    - Keepers: keeper list + detail view (Tab to switch)
    - Keeper Detail: identity, runtime stats, live context, behavior
    - Keeper Logs: recent heartbeat/metrics from JSONL files
    - Keeper Message: type and send messages to a keeper via HTTP API

    Layout (Keeper Logs):
    +---------------------------------------------+
    |  Keeper Logs: sangsu                        |
    +---------------------------------------------+
    |  14:31:08 hb  ctx:55% 70629/128000 msgs:430|
    |  14:31:32 hb  ctx:55% 70629/128000 msgs:430|
    |  14:33:03 hb  ctx:55% 70629/128000 msgs:430|
    +---------------------------------------------+
    | j/k:scroll  Esc:back  q:quit                |
    +---------------------------------------------+

    Layout (Message Input):
    +---------------------------------------------+
    |  Message to: sangsu                         |
    +---------------------------------------------+
    |  > hello, how are you?_                     |
    +---------------------------------------------+
    |  Response:                                  |
    |  (waiting for reply...)                     |
    +---------------------------------------------+
    | Enter:send  Esc:cancel  q:quit              |
    +---------------------------------------------+
*)

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
  let _move_to row col = Printf.sprintf "\027[%d;%dH" row col

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

(** Agent type with status *)
type agent = Tui_decode.agent

(** Task type *)
type task = Tui_decode.task

(** Event for the event log *)
type event = {
  timestamp: string;
  event_type: string;
  content: string;
}

(** Keeper metadata parsed from keepers/*.json *)
type keeper = Tui_decode.keeper

(** A single metrics/log entry parsed from JSONL *)
type log_entry = Tui_decode.log_entry

(** Message history entry *)
type msg_entry = {
  me_role: string;       (* "user" or "assistant" *)
  me_text: string;
  me_timestamp: string;
}

(** TUI view mode *)
type view_mode =
  | Dashboard
  | Keeper_list
  | Keeper_detail
  | Keeper_logs
  | Keeper_message

(** Dashboard state *)
type state = {
  mutable agents: agent list;
  mutable tasks: task list;
  mutable events: event list;
  mutable keepers: keeper list;
  mutable connection_status: string;
  mutable last_refresh: float;
  mutable view: view_mode;
  mutable keeper_cursor: int;
  (* Phase 2: log viewer state *)
  mutable log_entries: log_entry list;
  mutable log_scroll: int;
  (* Phase 2: live context from latest metrics *)
  mutable live_context_ratio: float;
  mutable live_context_tokens: int;
  mutable live_context_max: int;
  mutable live_message_count: int;
  (* Phase 2: message input state *)
  mutable msg_input: Buffer.t;
  mutable msg_history: msg_entry list;
  mutable msg_sending: bool;
  mutable detail_scroll: int;
  room: string;
  port: int;
  refresh_interval: float;
}

(** Create initial state *)
let create_state ~room ~port ~refresh_interval = {
  agents = [];
  tasks = [];
  events = [];
  keepers = [];
  connection_status = "disconnected";
  last_refresh = 0.0;
  view = Dashboard;
  keeper_cursor = 0;
  log_entries = [];
  log_scroll = 0;
  live_context_ratio = 0.0;
  live_context_tokens = 0;
  live_context_max = 0;
  live_message_count = 0;
  msg_input = Buffer.create 256;
  msg_history = [];
  msg_sending = false;
  detail_scroll = 0;
  room;
  port;
  refresh_interval;
}

(** Get terminal size (fallback to 80x24) *)
let get_terminal_size () =
  try
    let read_tput arg =
      let ic = Unix.open_process_args_in "tput" [| "tput"; arg |] in
      Fun.protect
        ~finally:(fun () -> ignore (Unix.close_process_in ic))
        (fun () -> int_of_string (String.trim (input_line ic)))
    in
    let cols = read_tput "cols" in
    let rows = read_tput "lines" in
    (rows, cols)
  with _ -> (24, 80)

(** Draw horizontal line *)
let draw_hline width =
  String.concat "" (List.init width (fun _ -> Ansi.box_h))

(** Pad or truncate string to width *)
let fit_width s width =
  let len = String.length s in
  if len >= width then String.sub s 0 (max 0 (width - 1)) ^ (if len > width then "~" else "")
  else s ^ String.make (width - len) ' '

(** Agent icon — deterministic by name hash, vendor-agnostic *)
let agent_icon name =
  let icons = [| "\xf0\x9f\x9f\xa3"; "\xf0\x9f\x94\xb5"; "\xf0\x9f\x9f\xa2"; "\xf0\x9f\x9f\xa1"; "\xf0\x9f\x94\xb4" |] in
  if String.length name >= 7 && String.sub name 0 7 = "keeper-" then "\xf0\x9f\x9b\xa1"  (* shield for keepers *)
  else icons.(Hashtbl.hash name mod Array.length icons)

(** Agent color — deterministic by name hash, vendor-agnostic *)
let agent_color name =
  let colors = [| Ansi.magenta; Ansi.blue; Ansi.green; Ansi.yellow; Ansi.cyan |] in
  if String.length name >= 7 && String.sub name 0 7 = "keeper-" then Ansi.white
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
  | "done" | "completed" -> "\xe2\x97\x8f"  (* filled circle *)
  | "in_progress" | "claimed" -> "\xe2\x97\x90"  (* half circle *)
  | "pending" | "todo" -> "\xe2\x97\x8b"  (* empty circle *)
  | _ -> "\xe2\x97\x8b"

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

(** Shorten model string for display *)
let short_model s =
  (* Extract the part after the last colon, or last slash, keeping it short *)
  let s = match String.index_opt s ':' with
    | Some i -> String.sub s (i + 1) (String.length s - i - 1)
    | None -> s
  in
  if String.length s > 24 then String.sub s 0 21 ^ "..."
  else s

(** Format a boolean as on/off indicator *)
let bool_indicator b =
  if b then Ansi.green ^ "on" ^ Ansi.reset
  else Ansi.gray ^ "off" ^ Ansi.reset

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

(** ---- RENDERING ---- *)

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

(** Shared helper: empty line inside a box *)
let box_empty buf cols =
  let inner = cols - 4 in
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    (String.make inner ' ')
    Ansi.gray Ansi.box_v Ansi.reset)

(** Render the dashboard (original view) *)
let render_dashboard (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  (* Clear screen *)
  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  (* Header *)
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf " MASC Dashboard  %s[%s]%s  %s  %s"
    Ansi.cyan state.room Ansi.reset timestamp
    (match state.connection_status with
     | "connected" -> Ansi.green ^ "[connected]" ^ Ansi.reset
     | "connecting" -> Ansi.yellow ^ "[connecting...]" ^ Ansi.reset
     | "reconnecting" -> Ansi.yellow ^ "[reconnecting...]" ^ Ansi.reset
     | _ -> Ansi.red ^ "[disconnected]" ^ Ansi.reset) in

  (* Top border *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_tl (draw_hline (cols - 2)) Ansi.box_tr Ansi.reset);

  (* Header line *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    (Ansi.bold ^ header)
    (String.make (max 0 (cols - String.length header - 20)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset));

  (* Divider after header *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset);

  (* Calculate panel sizes *)
  let panel_width = (cols - 3) / 2 in  (* -3 for borders *)
  let content_height = rows - 10 in  (* Reserve space for header/footer *)

  (* Agents panel (left side) *)
  let agents_title = " Agents " in
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s%s%s%s%s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.bold agents_title Ansi.reset
    (String.make (max 0 (panel_width - String.length agents_title)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset)
    " Events "
    (String.make (max 0 (panel_width - 8)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset));

  (* Agent/Event rows *)
  let agent_rows = min content_height (max 3 (List.length state.agents)) in
  for i = 0 to agent_rows - 1 do
    (* Agent column *)
    let agent_str =
      if i < List.length state.agents then
        let a = List.nth state.agents i in
        Printf.sprintf "%s %s%s%s %s%s%s"
          (agent_icon a.name)
          (agent_color a.name) a.name Ansi.reset
          (status_color a.status) a.status Ansi.reset
      else ""
    in
    (* Event column *)
    let event_str =
      if i < List.length state.events then
        let e = List.nth state.events i in
        Printf.sprintf "%s[%s]%s %s"
          Ansi.dim e.timestamp Ansi.reset
          (fit_width e.content (panel_width - 12))
      else ""
    in
    Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s %s %s%s%s\n"
      Ansi.gray Ansi.box_v Ansi.reset
      (fit_width agent_str (panel_width - 2))
      Ansi.gray Ansi.box_v Ansi.reset
      (fit_width event_str (panel_width - 2))
      Ansi.gray Ansi.box_v Ansi.reset)
  done;

  (* Tasks section divider *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset);

  (* Tasks header *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s %sTasks%s %s%s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.bold Ansi.reset
    (String.make (max 0 (cols - 10)) ' ')
    Ansi.gray Ansi.box_v Ansi.reset);

  (* Task rows *)
  let task_rows = min 5 (List.length state.tasks) in
  if task_rows = 0 then
    Buffer.add_string buf (Printf.sprintf "%s%s%s   %s(no tasks)%s %s%s%s%s\n"
      Ansi.gray Ansi.box_v Ansi.reset
      Ansi.dim Ansi.reset
      (String.make (max 0 (cols - 15)) ' ')
      Ansi.gray Ansi.box_v Ansi.reset)
  else
    for i = 0 to task_rows - 1 do
      let t = List.nth state.tasks i in
      let claimed_str = match t.claimed_by with
        | Some a -> Printf.sprintf " @%s" a
        | None -> ""
      in
      let task_line = Printf.sprintf "  %s [%s] %s (%s%s) %s"
        (task_status_icon t.status)
        t.id
        t.title
        t.status
        claimed_str
        (priority_indicator t.priority)
      in
      Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
        Ansi.gray Ansi.box_v Ansi.reset
        (fit_width task_line (cols - 4))
        Ansi.gray Ansi.box_v Ansi.reset)
    done;

  (* Bottom border *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_bl (draw_hline (cols - 2)) Ansi.box_br Ansi.reset);

  (* Footer *)
  Buffer.add_string buf (Printf.sprintf "%s  q:quit  r:refresh  Tab:keepers  | Refresh: %.0fs | Port: %d%s\n"
    Ansi.dim state.refresh_interval state.port Ansi.reset);

  print_string (Buffer.contents buf);
  flush stdout

(** Render the keeper list view *)
let render_keeper_list (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  (* Header *)
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let keeper_count = List.length state.keepers in
  let header = Printf.sprintf " MASC Keepers (%d)  %s" keeper_count timestamp in

  (* Top border *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_tl (draw_hline (cols - 2)) Ansi.box_tr Ansi.reset);

  (* Header line *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s%s%s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.bold header Ansi.reset
    (String.make (max 0 (cols - String.length header - 6)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset));

  (* Divider *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset);

  (* Column headers *)
  let col_header = Printf.sprintf "  %s  %-16s %-14s %5s  %-20s %s  %s"
    " " "Name" "Profile" "Gen" "Model" "Pro" "Goal" in
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s%s%s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    Ansi.dim (fit_width col_header (cols - 4)) Ansi.reset
    Ansi.gray Ansi.box_v Ansi.reset);

  (* Divider *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset);

  (* Keeper rows *)
  let content_height = rows - 8 in  (* header + column header + footer *)
  let visible_count = min content_height (List.length state.keepers) in
  (* Scroll offset: keep cursor visible *)
  let scroll_offset =
    if state.keeper_cursor >= content_height then
      state.keeper_cursor - content_height + 1
    else 0
  in

  if visible_count = 0 then begin
    Buffer.add_string buf (Printf.sprintf "%s%s%s   %s(no keepers found in .masc/keepers/)%s %s%s%s%s\n"
      Ansi.gray Ansi.box_v Ansi.reset
      Ansi.dim Ansi.reset
      (String.make (max 0 (cols - 50)) ' ')
      Ansi.gray Ansi.box_v Ansi.reset);
    for _ = 1 to max 0 (content_height - 1) do
      Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
        Ansi.gray Ansi.box_v Ansi.reset
        (String.make (cols - 4) ' ')
        Ansi.gray Ansi.box_v Ansi.reset)
    done
  end else begin
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < List.length state.keepers then begin
        let k = List.nth state.keepers idx in
        let is_selected = idx = state.keeper_cursor in
        let model_short = short_model (Option.value ~default:"-" k.k_active_model) in
        let proactive_str = if k.k_proactive_enabled then
          Ansi.green ^ "on" ^ Ansi.reset
        else
          Ansi.gray ^ "--" ^ Ansi.reset
        in
        (* Truncate goal to remaining space *)
        let goal_width = max 10 (cols - 68) in
        let goal_trunc = fit_width k.k_goal goal_width in
        let name_col = Printf.sprintf "%-16s" k.k_name in
        let profile_col = Printf.sprintf "%-14s" k.k_soul_profile in
        let gen_col = Printf.sprintf "%5d" k.k_generation in
        let model_col = Printf.sprintf "%-20s" model_short in
        let line_content =
          if is_selected then
            Ansi.reverse ^ ">" ^ Ansi.reset
            ^ "  " ^ Ansi.bold ^ name_col ^ Ansi.reset
            ^ " " ^ (soul_color k.k_soul_profile) ^ profile_col ^ Ansi.reset
            ^ " " ^ gen_col
            ^ "  " ^ model_col
            ^ " " ^ proactive_str
            ^ "  " ^ Ansi.dim ^ goal_trunc ^ Ansi.reset
          else
            " "
            ^ "  " ^ name_col
            ^ " " ^ (soul_color k.k_soul_profile) ^ profile_col ^ Ansi.reset
            ^ " " ^ gen_col
            ^ "  " ^ model_col
            ^ " " ^ proactive_str
            ^ "  " ^ Ansi.dim ^ goal_trunc ^ Ansi.reset
        in
        Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
          Ansi.gray Ansi.box_v Ansi.reset
          (fit_width line_content (cols - 4))
          Ansi.gray Ansi.box_v Ansi.reset)
      end else
        Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
          Ansi.gray Ansi.box_v Ansi.reset
          (String.make (cols - 4) ' ')
          Ansi.gray Ansi.box_v Ansi.reset)
    done
  end;

  (* Bottom border *)
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_bl (draw_hline (cols - 2)) Ansi.box_br Ansi.reset);

  (* Footer *)
  Buffer.add_string buf (Printf.sprintf "%s  j/k:move  Enter:detail  Tab:dashboard  q:quit  r:refresh%s\n"
    Ansi.dim Ansi.reset);

  print_string (Buffer.contents buf);
  flush stdout

(** Render keeper detail view with live context and scrolling *)
let render_keeper_detail (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    print_string (Buffer.contents buf);
    flush stdout
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let inner = cols - 4 in  (* width inside borders *)

    (* Build all detail lines first, then apply scroll *)
    let lines = ref [] in
    let add_line s = lines := s :: !lines in

    (* Helper to add a labeled row *)
    let add_row label value =
      add_line (Printf.sprintf "  %s%-22s%s %s" Ansi.cyan label Ansi.reset value)
    in
    let add_empty () = add_line "" in
    let add_section title =
      add_line (Printf.sprintf "  %s%s%s" Ansi.bold title Ansi.reset)
    in

    (* Identity section *)
    add_section "Identity";
    add_row "Name:" k.k_name;
    add_row "Soul Profile:" (Printf.sprintf "%s%s%s" (soul_color k.k_soul_profile) k.k_soul_profile Ansi.reset);
    add_row "Generation:" (string_of_int k.k_generation);
    add_row "Scope:" (Printf.sprintf "%s / %s" k.k_scope_kind k.k_room_scope);
    add_row "Trigger Mode:" k.k_trigger_mode;
    add_row "Verify:" (bool_indicator k.k_verify);
    add_empty ();

    (* Goals section *)
    add_section "Goals";
    add_row "Goal:" (fit_width k.k_goal (inner - 26));
    add_row "Short Goal:" (fit_width k.k_short_goal (inner - 26));
    add_empty ();

    (* Live Context section (Phase 2) *)
    add_section "Live Context";
    if state.live_context_max > 0 then begin
      let pct = state.live_context_ratio *. 100.0 in
      let bar_width = min 30 (inner - 40) in
      add_row "Context:" (Printf.sprintf "%s%.1f%%%s  %s  %d / %d tokens"
        (ctx_color state.live_context_ratio) pct Ansi.reset
        (ctx_bar state.live_context_ratio bar_width)
        state.live_context_tokens state.live_context_max);
      add_row "Messages:" (string_of_int state.live_message_count);
    end else begin
      add_row "Context:" (Ansi.dim ^ "(no metrics data)" ^ Ansi.reset);
    end;
    add_empty ();

    (* Model section *)
    add_section "Model";
    add_row "Active Model:" (Option.value ~default:"-" k.k_active_model);
    add_row "Available:" (String.concat ", " k.k_models);
    add_empty ();

    (* Runtime section *)
    add_section "Runtime Stats";
    add_row "Total Turns:" (string_of_int k.k_total_turns);
    add_row "Total Tokens:" (string_of_int k.k_total_tokens);
    add_row "Total Cost:" (Printf.sprintf "$%.4f" k.k_total_cost_usd);
    add_row "Last Turn:" (short_ts k.k_last_turn_ts);
    add_row "Compactions:" (string_of_int k.k_compaction_count);
    add_row "Compaction Gate:" (Printf.sprintf "%.0f%%" (k.k_compaction_ratio_gate *. 100.0));
    add_row "Context Budget:" (string_of_int k.k_context_budget);
    add_row "Handoff Threshold:" (Printf.sprintf "%.0f%%" (k.k_handoff_threshold *. 100.0));
    add_empty ();

    (* Behavior section *)
    add_section "Behavior";
    add_row "Proactive:" (bool_indicator k.k_proactive_enabled);
    add_row "Initiative:" (bool_indicator (Option.value ~default:false k.k_initiative_enabled));
    add_row "Drift:" (bool_indicator k.k_drift_enabled);
    add_empty ();

    (* Timestamps section *)
    add_section "Timestamps";
    add_row "Created:" (short_ts k.k_created_at);
    add_row "Updated:" (short_ts k.k_updated_at);

    (* Reverse to get correct order *)
    let all_lines = List.rev !lines in
    let total_lines = List.length all_lines in

    (* Top border *)
    box_top buf cols;

    (* Title *)
    let title = Printf.sprintf " Keeper: %s%s%s " Ansi.bold k.k_name Ansi.reset in
    Buffer.add_string buf (Printf.sprintf "%s%s%s %s%s%s%s%s\n"
      Ansi.gray Ansi.box_v Ansi.reset
      title
      (String.make (max 0 (inner - String.length title + 10)) ' ')
      Ansi.gray Ansi.box_v Ansi.reset);

    (* Divider *)
    box_divider buf cols;

    (* Content area with scrolling *)
    let content_height = rows - 6 in  (* header + title + divider + bottom + footer + extra *)
    let visible_lines = min content_height total_lines in
    let scroll = min state.detail_scroll (max 0 (total_lines - content_height)) in

    for i = 0 to visible_lines - 1 do
      let idx = i + scroll in
      if idx < total_lines then
        box_line buf cols (List.nth all_lines idx)
      else
        box_empty buf cols
    done;

    (* Fill remaining space *)
    for _ = visible_lines to content_height - 1 do
      box_empty buf cols
    done;

    (* Scroll indicator *)
    if total_lines > content_height then begin
      let indicator = Printf.sprintf "%s[%d/%d]%s" Ansi.dim (scroll + 1) (total_lines - content_height + 1) Ansi.reset in
      box_line buf cols indicator
    end;

    (* Bottom border *)
    box_bottom buf cols;

    (* Footer *)
    Buffer.add_string buf (Printf.sprintf "%s  j/k:scroll  l:logs  m:message  Esc:back  Tab:dashboard  q:quit  r:refresh%s\n"
      Ansi.dim Ansi.reset);

    print_string (Buffer.contents buf);
    flush stdout
  end

(** Render keeper log view *)
let render_keeper_logs (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.hide_cursor;

  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    print_string (Buffer.contents buf);
    flush stdout
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let total_entries = List.length state.log_entries in

    (* Header *)
    let header = Printf.sprintf " Keeper Logs: %s%s%s  (%d entries)"
      Ansi.bold k.k_name Ansi.reset total_entries in

    box_top buf cols;
    box_line buf cols header;
    box_divider buf cols;

    (* Column header *)
    let col_hdr = Printf.sprintf "%s  %-8s %-5s %-7s %12s %8s %7s %6s  %-10s%s"
      Ansi.dim "Time" "Chan" "Ctx" "Tokens" "In/Out" "Lat" "Cost" "Work" Ansi.reset in
    box_line buf cols col_hdr;
    box_divider buf cols;

    (* Content area *)
    let content_height = rows - 8 in
    let scroll = min state.log_scroll (max 0 (total_entries - content_height)) in

    if total_entries = 0 then begin
      box_line buf cols (Ansi.dim ^ "  (no log entries found)" ^ Ansi.reset);
      for _ = 1 to content_height - 1 do
        box_empty buf cols
      done
    end else begin
      for i = 0 to content_height - 1 do
        let idx = i + scroll in
        if idx < total_entries then begin
          let e = List.nth state.log_entries idx in
          (* Extract just the time portion from ts *)
          let time_str =
            if String.length e.le_ts >= 19 then
              String.sub e.le_ts 11 8  (* HH:MM:SS *)
            else e.le_ts
          in
          let pct = e.le_context_ratio *. 100.0 in
          let ctx_str = Printf.sprintf "%s%5.1f%%%s"
            (ctx_color e.le_context_ratio) pct Ansi.reset in
          let tokens_str = Printf.sprintf "%6d/%6d"
            e.le_context_tokens e.le_context_max in
          let io_str =
            match e.le_input_tokens, e.le_output_tokens with
            | Some input, Some output -> Printf.sprintf "%4d/%4d" input output
            | _ -> Ansi.dim ^ "   --/--" ^ Ansi.reset
          in
          let lat_str =
            match e.le_latency_ms with
            | Some latency when latency > 0 -> Printf.sprintf "%5dms" latency
            | _ -> Ansi.dim ^ "     --" ^ Ansi.reset
          in
          let cost_str =
            match e.le_cost_usd with
            | Some cost when cost > 0.0 -> Printf.sprintf "$%.3f" cost
            | _ -> Ansi.dim ^ "   --" ^ Ansi.reset
          in
          let tools_str =
            if List.length e.le_tools_used > 0 then
              " " ^ Ansi.dim ^ (String.concat "," (List.filteri (fun i _ -> i < 2) e.le_tools_used)) ^ Ansi.reset
            else ""
          in
          let guardrail_str =
            match e.le_guardrail_stop with
            | Some true -> Ansi.red ^ " STOP" ^ Ansi.reset
            | _ -> ""
          in
          let work_kind = Option.value ~default:"" e.le_work_kind in
          let line = Printf.sprintf "  %s %s %s %s %s %s %s  %-10s%s%s"
            time_str (channel_color e.le_channel) ctx_str tokens_str
            io_str lat_str cost_str work_kind tools_str guardrail_str
          in
          box_line buf cols line
        end else
          box_empty buf cols
      done
    end;

    (* Scroll indicator *)
    if total_entries > content_height then begin
      let indicator = Printf.sprintf "%s[%d/%d entries, scroll %d]%s"
        Ansi.dim total_entries (total_entries) scroll Ansi.reset in
      box_line buf cols indicator
    end;

    box_bottom buf cols;

    (* Footer *)
    Buffer.add_string buf (Printf.sprintf "%s  j/k:scroll  Esc:back  q:quit  r:refresh%s\n"
      Ansi.dim Ansi.reset);

    print_string (Buffer.contents buf);
    flush stdout
  end

(** Render message input/conversation view *)
let render_keeper_message (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in

  Buffer.add_string buf Ansi.clear;
  Buffer.add_string buf Ansi.show_cursor;  (* Show cursor for text input *)

  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    print_string (Buffer.contents buf);
    flush stdout
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in

    (* Header *)
    let header = Printf.sprintf " Message to: %s%s%s  (port %d)"
      Ansi.bold k.k_name Ansi.reset state.port in

    box_top buf cols;
    box_line buf cols header;
    box_divider buf cols;

    (* Message history *)
    let history_height = rows - 10 in  (* Reserve space for input area *)
    let msg_count = List.length state.msg_history in
    let start_idx = max 0 (msg_count - history_height) in

    if msg_count = 0 then begin
      box_line buf cols (Ansi.dim ^ "  (no messages yet -- type below and press Enter)" ^ Ansi.reset);
      for _ = 1 to history_height - 1 do
        box_empty buf cols
      done
    end else begin
      let displayed = ref 0 in
      List.iteri (fun i m ->
        if i >= start_idx && !displayed < history_height then begin
          let role_color = match m.me_role with
            | "user" -> Ansi.cyan
            | "assistant" -> Ansi.green
            | _ -> Ansi.white
          in
          let role_label = match m.me_role with
            | "user" -> "you"
            | "assistant" -> k.k_name
            | s -> s
          in
          let prefix = Printf.sprintf "  %s[%s] %s:%s "
            role_color m.me_timestamp role_label Ansi.reset in
          (* Word-wrap the message text across multiple lines *)
          let text_width = max 20 (cols - 30) in
          let text = m.me_text in
          let text_len = String.length text in
          if text_len <= text_width then begin
            box_line buf cols (prefix ^ text);
            incr displayed
          end else begin
            (* First line with prefix *)
            box_line buf cols (prefix ^ String.sub text 0 text_width);
            incr displayed;
            (* Continuation lines *)
            let indent = String.make (String.length "  [HH:MM:SS] xxxxxxx: ") ' ' in
            let pos = ref text_width in
            while !pos < text_len && !displayed < history_height do
              let chunk_len = min text_width (text_len - !pos) in
              box_line buf cols (indent ^ String.sub text !pos chunk_len);
              pos := !pos + chunk_len;
              incr displayed
            done
          end
        end
      ) state.msg_history;
      (* Fill remaining space *)
      for _ = !displayed to history_height - 1 do
        box_empty buf cols
      done
    end;

    (* Input area divider *)
    box_divider buf cols;

    (* Input line *)
    let input_text = Buffer.contents state.msg_input in
    let prompt =
      if state.msg_sending then
        Printf.sprintf "  %s(sending...)%s" Ansi.yellow Ansi.reset
      else
        Printf.sprintf "  %s>%s %s" Ansi.cyan Ansi.reset input_text
    in
    box_line buf cols prompt;

    box_bottom buf cols;

    (* Footer *)
    Buffer.add_string buf (Printf.sprintf "%s  Enter:send  Esc:back  Ctrl-U:clear line%s\n"
      Ansi.dim Ansi.reset);

    print_string (Buffer.contents buf);
    flush stdout
  end

(** Dispatch render based on current view *)
let render (state : state) =
  match state.view with
  | Dashboard -> render_dashboard state
  | Keeper_list -> render_keeper_list state
  | Keeper_detail -> render_keeper_detail state
  | Keeper_logs -> render_keeper_logs state
  | Keeper_message -> render_keeper_message state

(** Load keepers from .masc/keepers/ *)
let load_keepers (base_path : string) : keeper list =
  let keepers_dir = Filename.concat (Filename.concat base_path ".masc") "keepers" in
  let report path err =
    Printf.eprintf "[masc-tui] keeper decode failed for %s: %s\n%!" path err
  in
  if Sys.file_exists keepers_dir && Sys.is_directory keepers_dir then
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter (fun f ->
         Filename.check_suffix f ".json"
         && not (String.contains f '.'))  (* This won't work, use different filter *)
    |> (fun _ ->
         (* Re-filter: only files that are exactly <name>.json, not <name>.reward-model.json *)
         Sys.readdir keepers_dir
         |> Array.to_list
         |> List.filter (fun f ->
              Filename.check_suffix f ".json"
              && (let base = Filename.chop_suffix f ".json" in
                  not (String.contains base '.'))))
    |> List.filter_map (fun f ->
         try
           let path = Filename.concat keepers_dir f in
           let json = Yojson.Safe.from_file path in
           match Tui_decode.decode_keeper ~filename:f json with
           | Ok keeper -> Some keeper
           | Error err ->
               report path err;
               None
         with Yojson.Json_error err ->
           report (Filename.concat keepers_dir f) ("invalid JSON: " ^ err);
           None
         | Sys_error err ->
           report (Filename.concat keepers_dir f) err;
           None
       )
    |> List.sort (fun a b -> String.compare a.k_name b.k_name)
  else []

(** Read the last N lines from a file (tail) *)
let read_last_lines path n =
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        (* Read all lines then take last N -- simple for JSONL files < 1MB *)
        let lines = ref [] in
        (try while true do
           lines := input_line ic :: !lines
         done with End_of_file -> ());
        let all = List.rev !lines in
        let len = List.length all in
        if len <= n then all
        else
          List.filteri (fun i _ -> i >= len - n) all)
  with Sys_error _ -> []

(** Parse a single metrics JSONL line into a log_entry *)
let parse_log_entry (line : string) : log_entry option =
  match Tui_decode.parse_log_entry line with
  | Ok entry -> Some entry
  | Error err ->
      Printf.eprintf "[masc-tui] log decode failed: %s\n%!" err;
      None

(** Find the most recent metrics file for a keeper *)
let find_metrics_files (base_path : string) (keeper_name : string) : string list =
  let metrics_dir = Filename.concat
    (Filename.concat
       (Filename.concat base_path ".masc")
       "keepers")
    (Filename.concat keeper_name "metrics") in
  if not (Sys.file_exists metrics_dir && Sys.is_directory metrics_dir) then []
  else begin
    (* List year-month directories, pick the most recent *)
    let months = Sys.readdir metrics_dir
      |> Array.to_list
      |> List.filter (fun d ->
           let full = Filename.concat metrics_dir d in
           Sys.is_directory full)
      |> List.sort (fun a b -> String.compare b a)  (* Reverse sort: most recent first *)
    in
    match months with
    | [] -> []
    | month :: _ ->
      let month_dir = Filename.concat metrics_dir month in
      Sys.readdir month_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
      |> List.sort (fun a b -> String.compare b a)  (* Most recent first *)
      |> List.map (fun f -> Filename.concat month_dir f)
  end

(** Load log entries for the currently selected keeper *)
let load_keeper_logs (base_path : string) (keeper_name : string) (max_entries : int) : log_entry list =
  let files = find_metrics_files base_path keeper_name in
  let entries = ref [] in
  let remaining = ref max_entries in
  List.iter (fun path ->
    if !remaining > 0 then begin
      let lines = read_last_lines path !remaining in
      let parsed = List.filter_map parse_log_entry lines in
      entries := parsed @ !entries;
      remaining := !remaining - List.length parsed
    end
  ) files;
  (* Return in chronological order, limited to max_entries *)
  let all = List.rev !entries in
  let len = List.length all in
  if len <= max_entries then all
  else List.filteri (fun i _ -> i >= len - max_entries) all

(** Load live context status from the latest metrics entry *)
let load_live_context (state : state) (base_path : string) (keeper_name : string) =
  let files = find_metrics_files base_path keeper_name in
  match files with
  | [] ->
    state.live_context_ratio <- 0.0;
    state.live_context_tokens <- 0;
    state.live_context_max <- 0;
    state.live_message_count <- 0
  | latest_file :: _ ->
    (* Read just the last line *)
    let lines = read_last_lines latest_file 1 in
    (match lines with
     | [] ->
       state.live_context_ratio <- 0.0;
       state.live_context_tokens <- 0;
       state.live_context_max <- 0;
       state.live_message_count <- 0
     | line :: _ ->
       match parse_log_entry line with
       | None ->
         state.live_context_ratio <- 0.0;
         state.live_context_tokens <- 0;
         state.live_context_max <- 0;
         state.live_message_count <- 0
       | Some e ->
         state.live_context_ratio <- e.le_context_ratio;
         state.live_context_tokens <- e.le_context_tokens;
         state.live_context_max <- e.le_context_max;
         state.live_message_count <- e.le_message_count)

(** Load state from .masc directory *)
let load_from_masc_dir (state : state) (base_path : string) =
  let masc_dir = Filename.concat base_path ".masc" in
  let report path err =
    Printf.eprintf "[masc-tui] state decode failed for %s: %s\n%!" path err
  in

  (* Load agents *)
  let agents_dir = Filename.concat masc_dir "agents" in
  state.agents <- (
    if Sys.file_exists agents_dir && Sys.is_directory agents_dir then
      Sys.readdir agents_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.filter_map (fun f ->
           try
             let path = Filename.concat agents_dir f in
             let json = Yojson.Safe.from_file path in
             match Tui_decode.decode_agent json with
             | Ok agent -> Some agent
             | Error err ->
                 report path err;
                 None
           with Yojson.Json_error err ->
             report (Filename.concat agents_dir f) ("invalid JSON: " ^ err);
             None
           | Sys_error err ->
             report (Filename.concat agents_dir f) err;
             None
         )
    else []
  );

  (* Load tasks *)
  let tasks_dir = Filename.concat masc_dir "tasks" in
  state.tasks <- (
    if Sys.file_exists tasks_dir && Sys.is_directory tasks_dir then
      Sys.readdir tasks_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.filter_map (fun f ->
           try
             let path = Filename.concat tasks_dir f in
             let json = Yojson.Safe.from_file path in
             match Tui_decode.decode_task json with
             | Ok task -> Some task
             | Error err ->
                 report path err;
                 None
           with Yojson.Json_error err ->
             report (Filename.concat tasks_dir f) ("invalid JSON: " ^ err);
             None
           | Sys_error err ->
             report (Filename.concat tasks_dir f) err;
             None
         )
      |> List.sort (fun a b -> compare a.priority b.priority)
    else []
  );

  (* Load keepers *)
  state.keepers <- load_keepers base_path;

  (* Clamp cursor if keepers changed *)
  if state.keeper_cursor >= List.length state.keepers then
    state.keeper_cursor <- max 0 (List.length state.keepers - 1);

  (* Load live context for selected keeper *)
  if state.keeper_cursor < List.length state.keepers then begin
    let k = List.nth state.keepers state.keeper_cursor in
    load_live_context state base_path k.k_name
  end;

  state.last_refresh <- Unix.gettimeofday ()

(** Add event to the event log *)
let add_event (state : state) event_type content =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let ev = { timestamp; event_type; content } in
  state.events <- ev :: (List.filteri (fun i _ -> i < 10) state.events)

(** Send a message to a keeper via HTTP POST to /api/v1/keepers/chat/stream *)
let send_keeper_message (state : state) (keeper_name : string) (message : string) : string =
  try
    let host = "127.0.0.1" in
    let port = state.port in
    let addr = Unix.ADDR_INET (Unix.inet_addr_of_string host, port) in
    let (ic, oc) = Unix.open_connection addr in
    Fun.protect
      ~finally:(fun () ->
        Unix.shutdown_connection ic;
        close_in_noerr ic;
        close_out_noerr oc)
      (fun () ->
        (* Build JSON body *)
        let body = Printf.sprintf {|{"name":"%s","message":"%s","models":[]}|}
          (String.escaped keeper_name)
          (String.escaped message) in
        let body_len = String.length body in

        (* Send HTTP request *)
        let request = Printf.sprintf
          "POST /api/v1/keepers/chat/stream HTTP/1.1\r\n\
           Host: %s:%d\r\n\
           Content-Type: application/json\r\n\
           Content-Length: %d\r\n\
           Connection: close\r\n\
           \r\n\
           %s"
          host port body_len body in
        output_string oc request;
        flush oc;

        (* Read response *)
        let buf = Buffer.create 4096 in
        (try while true do
           let line = input_line ic in
           Buffer.add_string buf line;
           Buffer.add_char buf '\n'
         done with End_of_file -> ());

        let response = Buffer.contents buf in
        (match Tui_decode.parse_keeper_chat_response response with
         | Ok reply -> reply
         | Error err -> "(response parsing failed: " ^ err ^ ")"))
  with
  | Unix.Unix_error (err, _, _) ->
    Printf.sprintf "(connection failed: %s -- is MASC server running on port %d?)"
      (Unix.error_message err) state.port
  | exn ->
    Printf.sprintf "(error: %s)" (Printexc.to_string exn)

(** Read a single byte from stdin, returning Some char or None *)
let read_byte () : char option =
  let ready, _, _ = Unix.select [Unix.stdin] [] [] 0.1 in
  if List.length ready > 0 then begin
    let buf = Bytes.create 1 in
    let n = Unix.read Unix.stdin buf 0 1 in
    if n > 0 then Some (Bytes.get buf 0)
    else None
  end else
    None

(** Try to read an escape sequence. Returns a key description. *)
let read_key () : string option =
  match read_byte () with
  | None -> None
  | Some '\027' ->
    (* Escape sequence: try to read [ and then the code *)
    let ready2, _, _ = Unix.select [Unix.stdin] [] [] 0.05 in
    if List.length ready2 > 0 then begin
      let buf2 = Bytes.create 1 in
      let _ = Unix.read Unix.stdin buf2 0 1 in
      if Bytes.get buf2 0 = '[' then begin
        let ready3, _, _ = Unix.select [Unix.stdin] [] [] 0.05 in
        if List.length ready3 > 0 then begin
          let buf3 = Bytes.create 1 in
          let _ = Unix.read Unix.stdin buf3 0 1 in
          match Bytes.get buf3 0 with
          | 'A' -> Some "up"
          | 'B' -> Some "down"
          | 'Z' -> Some "shift-tab"
          | _ -> Some "unknown-esc"
        end else Some "esc"
      end else Some "esc"
    end else Some "esc"
  | Some c -> Some (String.make 1 c)

(** Parse command line arguments *)
let parse_args () =
  let port = ref 8935 in
  let room = ref "" in
  let refresh = ref 2.0 in
  let base_path = ref "" in

  let specs = [
    ("--port", Arg.Set_int port, "MASC server port (default: 8935)");
    ("--room", Arg.Set_string room, "Room name (default: from ME_ROOT)");
    ("--refresh", Arg.Set_float refresh, "Refresh interval in seconds (default: 2)");
    ("--base", Arg.Set_string base_path, "Base path (default: ME_ROOT or cwd)");
  ] in

  Arg.parse specs (fun _ -> ()) "masc-tui [OPTIONS]";

  (* Resolve base path *)
  let base = if !base_path <> "" then !base_path
    else match Sys.getenv_opt "ME_ROOT" with
      | Some p -> p
      | None -> Sys.getcwd ()
  in

  (* Resolve room *)
  let r = if !room <> "" then !room
    else match Env_config_core.cluster_name_opt () with
      | Some name -> name
      | None -> Filename.basename base
  in

  (base, r, !port, !refresh)

(** Handle key input for message mode *)
let handle_message_key (state : state) (base_path : string) (key : string) : bool =
  match key with
  | "esc" ->
    state.view <- Keeper_detail;
    state.detail_scroll <- 0;
    true
  | "\r" | "\n" ->
    (* Send the message *)
    let text = Buffer.contents state.msg_input in
    if String.length (String.trim text) > 0 then begin
      let keeper_name =
        if state.keeper_cursor < List.length state.keepers then
          (List.nth state.keepers state.keeper_cursor).k_name
        else "unknown"
      in
      (* Add user message to history *)
      let now = Unix.localtime (Unix.gettimeofday ()) in
      let ts = Printf.sprintf "%02d:%02d:%02d"
        now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
      state.msg_history <- state.msg_history @ [{
        me_role = "user";
        me_text = text;
        me_timestamp = ts;
      }];
      Buffer.clear state.msg_input;

      (* Render to show "sending..." *)
      state.msg_sending <- true;
      render state;

      (* Send and get reply *)
      let reply = send_keeper_message state keeper_name text in

      (* Add reply to history *)
      let now2 = Unix.localtime (Unix.gettimeofday ()) in
      let ts2 = Printf.sprintf "%02d:%02d:%02d"
        now2.Unix.tm_hour now2.Unix.tm_min now2.Unix.tm_sec in
      state.msg_history <- state.msg_history @ [{
        me_role = "assistant";
        me_text = reply;
        me_timestamp = ts2;
      }];
      state.msg_sending <- false;
      add_event state "message" (Printf.sprintf "Sent to %s" keeper_name);

      (* Refresh data after message *)
      load_from_masc_dir state base_path
    end;
    true
  | "\127" | "\b" ->
    (* Backspace: delete last character *)
    let len = Buffer.length state.msg_input in
    if len > 0 then begin
      let new_content = Buffer.sub state.msg_input 0 (len - 1) in
      Buffer.clear state.msg_input;
      Buffer.add_string state.msg_input new_content
    end;
    true
  | s when String.length s = 1 ->
    let c = Char.code s.[0] in
    if c = 21 then begin
      (* Ctrl-U: clear line *)
      Buffer.clear state.msg_input;
      true
    end else if c >= 32 && c < 127 then begin
      (* Printable character *)
      Buffer.add_string state.msg_input s;
      true
    end else
      true  (* Consume but ignore other control chars *)
  | _ -> true

(** Main loop *)
let main () =
  let (base_path, room, port, refresh) = parse_args () in
  let state = create_state ~room ~port ~refresh_interval:refresh in

  (* Setup terminal *)
  let old_term = Unix.tcgetattr Unix.stdin in
  let new_term = { old_term with Unix.c_icanon = false; c_echo = false } in
  Unix.tcsetattr Unix.stdin Unix.TCSANOW new_term;

  (* Cleanup on exit *)
  let cleanup () =
    print_string Ansi.show_cursor;
    print_string Ansi.clear;
    Unix.tcsetattr Unix.stdin Unix.TCSANOW old_term;
    print_endline "Goodbye!"
  in
  at_exit cleanup;
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> exit 0));

  (* Initial load *)
  load_from_masc_dir state base_path;
  add_event state "system" "TUI started";
  state.connection_status <- "connected";

  (* Main loop *)
  let last_check = ref (Unix.gettimeofday ()) in
  try
    while true do
      (* Check for input *)
      let key = read_key () in
      (match key with
       | Some k when state.view = Keeper_message ->
           let _handled = handle_message_key state base_path k in
           ()
       | Some "q" | Some "Q" -> raise Exit
       | Some "r" | Some "R" ->
           load_from_masc_dir state base_path;
           (* Also reload logs if in log view *)
           (match state.view with
            | Keeper_logs when state.keeper_cursor < List.length state.keepers ->
                let k = List.nth state.keepers state.keeper_cursor in
                state.log_entries <- load_keeper_logs base_path k.k_name 200
            | _ -> ());
           add_event state "system" "Manual refresh"
       | Some "\t" ->
           (* Tab toggles between Dashboard and Keeper_list *)
           (match state.view with
            | Dashboard -> state.view <- Keeper_list
            | Keeper_list -> state.view <- Dashboard
            | Keeper_detail ->
                state.view <- Dashboard;
                state.detail_scroll <- 0
            | Keeper_logs ->
                state.view <- Dashboard;
                state.log_scroll <- 0
            | Keeper_message ->
                state.view <- Dashboard)
       | Some "esc" ->
           (* Esc goes back *)
           (match state.view with
            | Keeper_detail ->
                state.view <- Keeper_list;
                state.detail_scroll <- 0
            | Keeper_logs ->
                state.view <- Keeper_detail;
                state.log_scroll <- 0;
                state.detail_scroll <- 0
            | Keeper_message ->
                state.view <- Keeper_detail;
                state.detail_scroll <- 0
            | _ -> ())
       | Some "j" | Some "down" ->
           (match state.view with
            | Keeper_list ->
                if state.keeper_cursor < List.length state.keepers - 1 then begin
                  state.keeper_cursor <- state.keeper_cursor + 1;
                  (* Update live context for new selection *)
                  let k = List.nth state.keepers state.keeper_cursor in
                  load_live_context state base_path k.k_name
                end
            | Keeper_detail ->
                state.detail_scroll <- state.detail_scroll + 1
            | Keeper_logs ->
                state.log_scroll <- state.log_scroll + 1
            | _ -> ())
       | Some "k" | Some "up" ->
           (match state.view with
            | Keeper_list ->
                if state.keeper_cursor > 0 then begin
                  state.keeper_cursor <- state.keeper_cursor - 1;
                  let k = List.nth state.keepers state.keeper_cursor in
                  load_live_context state base_path k.k_name
                end
            | Keeper_detail ->
                if state.detail_scroll > 0 then
                  state.detail_scroll <- state.detail_scroll - 1
            | Keeper_logs ->
                if state.log_scroll > 0 then
                  state.log_scroll <- state.log_scroll - 1
            | _ -> ())
       | Some "\r" | Some "\n" ->
           (* Enter opens detail from list *)
           (match state.view with
            | Keeper_list ->
                if List.length state.keepers > 0 then begin
                  state.view <- Keeper_detail;
                  state.detail_scroll <- 0;
                  let k = List.nth state.keepers state.keeper_cursor in
                  load_live_context state base_path k.k_name
                end
            | _ -> ())
       | Some "l" | Some "L" ->
           (* L opens log view from detail *)
           (match state.view with
            | Keeper_detail when state.keeper_cursor < List.length state.keepers ->
                let k = List.nth state.keepers state.keeper_cursor in
                state.log_entries <- load_keeper_logs base_path k.k_name 200;
                state.log_scroll <- max 0 (List.length state.log_entries - 1);
                state.view <- Keeper_logs
            | _ -> ())
       | Some "m" | Some "M" ->
           (* M opens message view from detail *)
           (match state.view with
            | Keeper_detail when state.keeper_cursor < List.length state.keepers ->
                Buffer.clear state.msg_input;
                state.view <- Keeper_message
            | _ -> ())
       | _ -> ());

      (* Periodic refresh *)
      let now = Unix.gettimeofday () in
      if now -. !last_check >= refresh then begin
        load_from_masc_dir state base_path;
        (* Also refresh logs if viewing them *)
        (match state.view with
         | Keeper_logs when state.keeper_cursor < List.length state.keepers ->
             let k = List.nth state.keepers state.keeper_cursor in
             state.log_entries <- load_keeper_logs base_path k.k_name 200
         | _ -> ());
        last_check := now
      end;

      (* Render *)
      render state
    done
  with Exit -> ()

let () = main ()
