[@@@warning "-32-69"]
(* MASC TUI - Terminal User Interface for Multi-Agent Coordination

    A simple ANSI-based TUI dashboard that connects to the MASC server
    and displays real-time agent status, tasks, and events.

    Usage: masc-tui [--port PORT] [--room ROOM] [--refresh SECONDS]

    Layout:
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

  let black = "\027[30m"
  let red = "\027[31m"
  let green = "\027[32m"
  let yellow = "\027[33m"
  let blue = "\027[34m"
  let magenta = "\027[35m"
  let cyan = "\027[36m"
  let white = "\027[37m"
  let gray = "\027[90m"

  let bg_black = "\027[40m"
  let bg_blue = "\027[44m"

  (* Cursor movement *)
  let move_to row col = Printf.sprintf "\027[%d;%dH" row col

  (* Box drawing characters *)
  let box_h = "\xe2\x94\x80"  (* ─ *)
  let box_v = "\xe2\x94\x82"  (* │ *)
  let box_tl = "\xe2\x94\x8c" (* ┌ *)
  let box_tr = "\xe2\x94\x90" (* ┐ *)
  let box_bl = "\xe2\x94\x94" (* └ *)
  let box_br = "\xe2\x94\x98" (* ┘ *)
  let box_t = "\xe2\x94\xac"  (* ┬ *)
  let box_b = "\xe2\x94\xb4"  (* ┴ *)
  let box_l = "\xe2\x94\x9c"  (* ├ *)
  let box_r = "\xe2\x94\xa4"  (* ┤ *)
  let box_x = "\xe2\x94\xbc"  (* ┼ *)
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

(** Dashboard state *)
type state = {
  mutable agents: agent list;
  mutable tasks: task list;
  mutable events: event list;
  mutable connection_status: string;
  mutable last_refresh: float;
  room: string;
  port: int;
  refresh_interval: float;
}

(** Create initial state *)
let create_state ~room ~port ~refresh_interval = {
  agents = [];
  tasks = [];
  events = [];
  connection_status = "disconnected";
  last_refresh = 0.0;
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

(** Render the dashboard *)
let render (state : state) =
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
  Buffer.add_string buf (Printf.sprintf "%s  Press q to quit | Refresh: %.0fs | Port: %d%s\n"
    Ansi.dim state.refresh_interval state.port Ansi.reset);

  print_string (Buffer.contents buf);
  flush stdout

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

  state.last_refresh <- Unix.gettimeofday ()

(** Add event to the event log *)
let add_event (state : state) event_type content =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let ev = { timestamp; event_type; content } in
  state.events <- ev :: (List.filteri (fun i _ -> i < 10) state.events)

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
      let ready, _, _ = Unix.select [Unix.stdin] [] [] 0.1 in
      if List.length ready > 0 then begin
        let buf = Bytes.create 1 in
        let _ = Unix.read Unix.stdin buf 0 1 in
        match Bytes.get buf 0 with
        | 'q' | 'Q' -> raise Exit
        | 'r' | 'R' ->
            load_from_masc_dir state base_path;
            add_event state "system" "Manual refresh"
        | _ -> ()
      end;

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
