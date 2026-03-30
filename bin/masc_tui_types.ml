(** Types and core helper functions for MASC TUI *)

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

(** Keeper metadata parsed from keepers/*.json *)
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
  k_context_budget: int;
  k_handoff_threshold: float;
  k_drift_enabled: bool;
  k_verify: bool;
  k_created_at: string;
  k_updated_at: string;
}

(** A single metrics/log entry parsed from JSONL *)
type log_entry = {
  le_ts: string;
  le_channel: string;
  le_context_ratio: float;
  le_context_tokens: int;
  le_context_max: int;
  le_message_count: int;
  le_model_used: string;
  le_input_tokens: int;
  le_output_tokens: int;
  le_latency_ms: int;
  le_cost_usd: float;
  le_work_kind: string;
  le_tools_used: string list;
  le_compacted: bool;
  le_goal_alignment: float;
  le_repetition_risk: float;
  le_guardrail_stop: bool;
}

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
  String.concat "" (List.init width (fun _ -> Masc_tui_ansi.box_h))

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
  let colors = [| Masc_tui_ansi.magenta; Masc_tui_ansi.blue; Masc_tui_ansi.green; Masc_tui_ansi.yellow; Masc_tui_ansi.cyan |] in
  if String.length name >= 7 && String.sub name 0 7 = "keeper-" then Masc_tui_ansi.white
  else colors.(Hashtbl.hash name mod Array.length colors)

(** Status color *)
let status_color status =
  match status with
  | "working" | "in_progress" -> Masc_tui_ansi.yellow
  | "idle" | "online" -> Masc_tui_ansi.green
  | "offline" -> Masc_tui_ansi.gray
  | "error" -> Masc_tui_ansi.red
  | _ -> Masc_tui_ansi.white

(** Task status icon *)
let task_status_icon status =
  match status with
  | "done" | "completed" -> "\xe2\x97\x8f"  (* filled circle *)
  | "in_progress" | "claimed" -> "\xe2\x97\x90"  (* half circle *)
  | "pending" | "todo" -> "\xe2\x97\x8b"  (* empty circle *)
  | _ -> "\xe2\x97\x8b"

(** Priority indicator *)
let priority_indicator p =
  if p <= 1 then Masc_tui_ansi.red ^ "!!!" ^ Masc_tui_ansi.reset
  else if p <= 2 then Masc_tui_ansi.red ^ "!!" ^ Masc_tui_ansi.reset
  else if p <= 3 then Masc_tui_ansi.yellow ^ "!" ^ Masc_tui_ansi.reset
  else ""

(** Soul profile color *)
let soul_color profile =
  match profile with
  | "relationship" -> Masc_tui_ansi.magenta
  | "delivery" -> Masc_tui_ansi.green
  | "balanced" -> Masc_tui_ansi.cyan
  | "creative" -> Masc_tui_ansi.yellow
  | _ -> Masc_tui_ansi.white

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
  if b then Masc_tui_ansi.green ^ "on" ^ Masc_tui_ansi.reset
  else Masc_tui_ansi.gray ^ "off" ^ Masc_tui_ansi.reset

(** Format a timestamp for display (show date portion or relative) *)
let short_ts s =
  if String.length s > 19 then String.sub s 0 19
  else if String.length s = 0 then "(never)"
  else s

(** Context ratio color: green < 50%, yellow 50-80%, red > 80% *)
let ctx_color ratio =
  if ratio >= 0.8 then Masc_tui_ansi.red
  else if ratio >= 0.5 then Masc_tui_ansi.yellow
  else Masc_tui_ansi.green

(** Format context ratio as a visual bar *)
let ctx_bar ratio width =
  let filled = int_of_float (ratio *. float_of_int width) in
  let filled = max 0 (min width filled) in
  let empty = width - filled in
  let color = ctx_color ratio in
  Printf.sprintf "%s%s%s%s"
    color
    (String.make filled '#')
    (Masc_tui_ansi.gray ^ String.make empty '-' ^ Masc_tui_ansi.reset)
    Masc_tui_ansi.reset

(** Format channel name with color *)
let channel_color ch =
  match ch with
  | "heartbeat" -> Masc_tui_ansi.dim ^ "hb" ^ Masc_tui_ansi.reset
  | "turn" -> Masc_tui_ansi.cyan ^ "turn" ^ Masc_tui_ansi.reset
  | "compaction" -> Masc_tui_ansi.yellow ^ "comp" ^ Masc_tui_ansi.reset
  | "handoff" -> Masc_tui_ansi.magenta ^ "hand" ^ Masc_tui_ansi.reset
  | "initiative" -> Masc_tui_ansi.blue ^ "init" ^ Masc_tui_ansi.reset
  | s -> s

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
    else match Env_config_core.cluster_name_opt () with
      | Some name -> name
      | None -> Filename.basename base
  in

  (base, r, !port, !refresh)
