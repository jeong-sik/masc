[@@@warning "-32-69"]
(* MASC TUI - Terminal User Interface for Multi-Agent Coordination

    A simple ANSI-based TUI dashboard that connects to the MASC server
    and displays real-time agent status, tasks, and events.

    Usage: masc-tui [--port PORT] [--room ROOM] [--refresh SECONDS]

    Modes:
    - Dashboard: agents/tasks/events overview (original)
    - Keepers: keeper list + detail view (Tab to switch)

    Layout (Dashboard):
    +---------------------------------------------+
    |            MASC Dashboard                   |
    +---------------------+-----------------------+
    |      Agents         |       Events          |
    |  - claude: working  |  [12:00:01] joined    |
    |  - gemini: idle     |  [12:00:05] task done |
    +---------------------+-----------------------+
    |              Tasks                          |
    |  [task-001] Fix bug (in_progress @claude)   |
    |  [task-002] Review PR (pending)             |
    +---------------------------------------------+

    Layout (Keepers):
    +---------------------------------------------+
    |            MASC Keepers                     |
    +---------------------------------------------+
    |  > sangsu       relationship  gen:0  llama  |
    |    dm-keeper    balanced      gen:0  llama  |
    |    qa-ui-smoke  delivery      gen:0  llama  |
    +---------------------------------------------+
    | j/k: move  Enter: detail  Tab: dashboard  q |
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
type agent = {
  name: string;
  status: string;
  current_task: string option;
  last_seen: string;
}

(** Task type *)
type task = {
  id: string;
  title: string;
  status: string;
  priority: int;
  claimed_by: string option;
}

(** Event for the event log *)
type event = {
  timestamp: string;
  event_type: string;
  content: string;
}

(** Keeper metadata parsed from perpetual-keepers/*.json *)
type keeper = {
  k_name: string;
  k_goal: string;
  k_short_goal: string;
  k_soul_profile: string;
  k_generation: int;
  k_active_model: string;
  k_models: string list;
  k_proactive_enabled: bool;
  k_initiative_enabled: bool;
  k_total_turns: int;
  k_total_tokens: int;
  k_total_cost_usd: float;
  k_last_turn_ts: string;
  k_compaction_count: int;
  k_compaction_ratio_gate: float;
  k_scope_kind: string;
  k_room_scope: string;
  k_trigger_mode: string;
  k_autonomy_level: string;
  k_context_budget: int;
  k_handoff_threshold: float;
  k_drift_enabled: bool;
  k_verify: bool;
  k_created_at: string;
  k_updated_at: string;
}

(** TUI view mode *)
type view_mode =
  | Dashboard
  | Keeper_list
  | Keeper_detail

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

(** Agent icon based on type *)
let agent_icon name =
  if String.length name >= 6 && String.sub name 0 6 = "claude" then "\xf0\x9f\x9f\xa3"  (* purple circle *)
  else if String.length name >= 6 && String.sub name 0 6 = "gemini" then "\xf0\x9f\x94\xb5"  (* blue circle *)
  else if String.length name >= 5 && String.sub name 0 5 = "codex" then "\xf0\x9f\x9f\xa2"  (* green circle *)
  else "\xf0\x9f\xa4\x96"  (* robot *)

(** Agent color based on type *)
let agent_color name =
  if String.length name >= 6 && String.sub name 0 6 = "claude" then Ansi.magenta
  else if String.length name >= 6 && String.sub name 0 6 = "gemini" then Ansi.blue
  else if String.length name >= 5 && String.sub name 0 5 = "codex" then Ansi.green
  else Ansi.white

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
    Buffer.add_string buf (Printf.sprintf "%s%s%s   %s(no keepers found in .masc/perpetual-keepers/)%s %s%s%s%s\n"
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
        let model_short = short_model k.k_active_model in
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

(** Render keeper detail view *)
let render_keeper_detail (state : state) =
  let (_rows, cols) = get_terminal_size () in
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

    (* Top border *)
    Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
      Ansi.gray Ansi.box_tl (draw_hline (cols - 2)) Ansi.box_tr Ansi.reset);

    (* Title *)
    let title = Printf.sprintf " Keeper: %s%s%s " Ansi.bold k.k_name Ansi.reset in
    Buffer.add_string buf (Printf.sprintf "%s%s%s %s%s%s%s%s\n"
      Ansi.gray Ansi.box_v Ansi.reset
      title
      (String.make (max 0 (inner - String.length title + 10)) ' ')
      Ansi.gray Ansi.box_v Ansi.reset);

    (* Divider *)
    Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
      Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset);

    (* Helper to add a labeled row *)
    let add_row label value =
      let line = Printf.sprintf "  %s%-22s%s %s" Ansi.cyan label Ansi.reset value in
      Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
        Ansi.gray Ansi.box_v Ansi.reset
        (fit_width line (inner))
        Ansi.gray Ansi.box_v Ansi.reset)
    in

    (* Empty row helper *)
    let add_empty () =
      Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
        Ansi.gray Ansi.box_v Ansi.reset
        (String.make inner ' ')
        Ansi.gray Ansi.box_v Ansi.reset)
    in

    (* Section header *)
    let add_section title =
      let line = Printf.sprintf "  %s%s%s" Ansi.bold title Ansi.reset in
      Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
        Ansi.gray Ansi.box_v Ansi.reset
        (fit_width line (inner))
        Ansi.gray Ansi.box_v Ansi.reset)
    in

    (* Identity section *)
    add_section "Identity";
    add_row "Name:" k.k_name;
    add_row "Soul Profile:" (Printf.sprintf "%s%s%s" (soul_color k.k_soul_profile) k.k_soul_profile Ansi.reset);
    add_row "Generation:" (string_of_int k.k_generation);
    add_row "Scope:" (Printf.sprintf "%s / %s" k.k_scope_kind k.k_room_scope);
    add_row "Trigger Mode:" k.k_trigger_mode;
    add_row "Autonomy Level:" (if k.k_autonomy_level = "" then "(default)" else k.k_autonomy_level);
    add_row "Verify:" (bool_indicator k.k_verify);
    add_empty ();

    (* Goals section *)
    add_section "Goals";
    add_row "Goal:" (fit_width k.k_goal (inner - 26));
    add_row "Short Goal:" (fit_width k.k_short_goal (inner - 26));
    add_empty ();

    (* Model section *)
    add_section "Model";
    add_row "Active Model:" k.k_active_model;
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
    add_row "Initiative:" (bool_indicator k.k_initiative_enabled);
    add_row "Drift:" (bool_indicator k.k_drift_enabled);
    add_empty ();

    (* Timestamps section *)
    add_section "Timestamps";
    add_row "Created:" (short_ts k.k_created_at);
    add_row "Updated:" (short_ts k.k_updated_at);

    (* Bottom border *)
    Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
      Ansi.gray Ansi.box_bl (draw_hline (cols - 2)) Ansi.box_br Ansi.reset);

    (* Footer *)
    Buffer.add_string buf (Printf.sprintf "%s  Esc:back  Tab:dashboard  q:quit  r:refresh%s\n"
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

(** Load keepers from .masc/perpetual-keepers/ *)
let load_keepers (base_path : string) : keeper list =
  let keepers_dir = Filename.concat (Filename.concat base_path ".masc") "perpetual-keepers" in
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
           let open Yojson.Safe.Util in
           let str key default = try json |> member key |> to_string with _ -> default in
           let int_ key default = try json |> member key |> to_int with _ -> default in
           let float_ key default = try json |> member key |> to_number with _ -> default in
           let bool_ key default = try json |> member key |> to_bool with _ -> default in
           let str_list key = try json |> member key |> to_list |> List.map to_string with _ -> [] in
           Some {
             k_name = str "name" (Filename.chop_suffix f ".json");
             k_goal = str "goal" "";
             k_short_goal = str "short_goal" "";
             k_soul_profile = str "soul_profile" "unknown";
             k_generation = int_ "generation" 0;
             k_active_model = str "active_model" "unknown";
             k_models = str_list "models";
             k_proactive_enabled = bool_ "proactive_enabled" false;
             k_initiative_enabled = bool_ "initiative_enabled" false;
             k_total_turns = int_ "total_turns" 0;
             k_total_tokens = int_ "total_tokens" 0;
             k_total_cost_usd = float_ "total_cost_usd" 0.0;
             k_last_turn_ts = str "last_turn_ts" "";
             k_compaction_count = int_ "compaction_count" 0;
             k_compaction_ratio_gate = float_ "compaction_ratio_gate" 0.5;
             k_scope_kind = str "scope_kind" "local";
             k_room_scope = str "room_scope" "current";
             k_trigger_mode = str "trigger_mode" "legacy";
             k_autonomy_level = str "autonomy_level" "";
             k_context_budget = int_ "context_budget" 0;
             k_handoff_threshold = float_ "handoff_threshold" 0.85;
             k_drift_enabled = bool_ "drift_enabled" false;
             k_verify = bool_ "verify" false;
             k_created_at = str "created_at" "";
             k_updated_at = str "updated_at" "";
           }
         with _ -> None
       )
    |> List.sort (fun a b -> String.compare a.k_name b.k_name)
  else []

(** Load state from .masc directory *)
let load_from_masc_dir (state : state) (base_path : string) =
  let masc_dir = Filename.concat base_path ".masc" in

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
             let open Yojson.Safe.Util in
             let name = json |> member "name" |> to_string in
             let status_val = json |> member "status" in
             let status = match status_val with
               | `List (s :: _) -> to_string s
               | `String s -> s
               | _ -> "unknown"
             in
             let current_task = json |> member "current_task" |> to_string_option in
             let last_seen = json |> member "last_seen" |> to_string in
             Some { name; status; current_task; last_seen }
           with _ -> None
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
             let open Yojson.Safe.Util in
             let id = json |> member "id" |> to_string in
             let title = json |> member "title" |> to_string in
             let status = json |> member "status" |> to_string in
             let priority = json |> member "priority" |> to_int_option |> Option.value ~default:3 in
             let claimed_by = json |> member "claimed_by" |> to_string_option in
             Some { id; title; status; priority; claimed_by }
           with _ -> None
         )
      |> List.sort (fun a b -> compare a.priority b.priority)
    else []
  );

  (* Load keepers *)
  state.keepers <- load_keepers base_path;

  (* Clamp cursor if keepers changed *)
  if state.keeper_cursor >= List.length state.keepers then
    state.keeper_cursor <- max 0 (List.length state.keepers - 1);

  state.last_refresh <- Unix.gettimeofday ()

(** Add event to the event log *)
let add_event (state : state) event_type content =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let ev = { timestamp; event_type; content } in
  state.events <- ev :: (List.filteri (fun i _ -> i < 10) state.events)

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
    else match Sys.getenv_opt "MASC_CLUSTER_NAME" with
      | Some n -> n
      | None -> Filename.basename base
  in

  (base, r, !port, !refresh)

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
       | Some "q" | Some "Q" -> raise Exit
       | Some "r" | Some "R" ->
           load_from_masc_dir state base_path;
           add_event state "system" "Manual refresh"
       | Some "\t" ->
           (* Tab toggles between Dashboard and Keeper_list *)
           (match state.view with
            | Dashboard -> state.view <- Keeper_list
            | Keeper_list -> state.view <- Dashboard
            | Keeper_detail -> state.view <- Dashboard)
       | Some "esc" ->
           (* Esc goes back from detail to list *)
           (match state.view with
            | Keeper_detail -> state.view <- Keeper_list
            | _ -> ())
       | Some "j" | Some "down" ->
           (* Move cursor down in keeper list *)
           (match state.view with
            | Keeper_list ->
                if state.keeper_cursor < List.length state.keepers - 1 then
                  state.keeper_cursor <- state.keeper_cursor + 1
            | _ -> ())
       | Some "k" | Some "up" ->
           (* Move cursor up in keeper list *)
           (match state.view with
            | Keeper_list ->
                if state.keeper_cursor > 0 then
                  state.keeper_cursor <- state.keeper_cursor - 1
            | _ -> ())
       | Some "\r" | Some "\n" ->
           (* Enter opens detail from list *)
           (match state.view with
            | Keeper_list ->
                if List.length state.keepers > 0 then
                  state.view <- Keeper_detail
            | _ -> ())
       | _ -> ());

      (* Periodic refresh *)
      let now = Unix.gettimeofday () in
      if now -. !last_check >= refresh then begin
        load_from_masc_dir state base_path;
        last_check := now
      end;

      (* Render *)
      render state
    done
  with Exit -> ()

let () = main ()
