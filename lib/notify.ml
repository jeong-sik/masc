(** macOS notification for a keeper mention, posted through
    terminal-notifier or, without it, osascript. See notify.mli. *)

(** Focus payload for click actions *)
type focus_payload = {
  target_agent: string option;
  from_agent: string option;
  task_id: string option;
}

(* A post returns in well under a second: three terminal-notifier posts
   measured on this machine on 2026-09-14 took 0.38 s, 0.38 s and 0.45 s. The
   slow failure is a notifier that never returns, blocked on a permission
   dialog or started where no window session can show it. This runs inside
   the keeper's masc_broadcast tool call, and while a tool call is active the
   turn's no-progress watchdog is off, so without a bound nothing ends that
   wait but an operator. A spent budget is logged as the failed notification
   it is; the tool call it rode on is not affected. *)
let notifier_timeout_sec = 10.

(* The one process this module starts. Anything but a clean exit is a log
   line: a desktop notification that did not post has no other consequence,
   and the keeper's tool call must not inherit one. *)
let run_notifier argv =
  let command () = String.concat " " argv in
  (try
     let status, _output =
       Process_eio.run_argv_with_status ~timeout_sec:notifier_timeout_sec argv
     in
     match Process_eio.exit_reason_of_status status with
     | Process_eio.Completed 0 -> ()
     | Process_eio.Timed_out ->
       Log.Misc.warn
         "notify command did not return within %.0fs and was stopped: %s"
         notifier_timeout_sec (command ())
     | Process_eio.Completed code ->
       Log.Misc.warn "notify command exited %d: %s" code (command ())
     | Process_eio.Signaled signal ->
       Log.Misc.warn "notify command was killed by signal %d: %s" signal (command ())
     | Process_eio.Stopped signal ->
       Log.Misc.warn "notify command was stopped by signal %d: %s" signal (command ())
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn -> Log.Misc.error "notify command failed to run: %s" (Printexc.to_string exn))

(** Get non-empty environment variable *)
let getenv_nonempty name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None

(** Sanitize token for shell-safe identifiers *)
let sanitize_token s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> Buffer.add_char buf c
    | _ -> ()
  ) s;
  Buffer.contents buf

let token_value = function
  | Some value -> sanitize_token value
  | None -> ""

let is_truthy value =
  match String.lowercase_ascii (String.trim value) with
  | "1" | "true" | "yes" | "on" | "y" -> true
  | _ -> false

let shell_execute_clicks_enabled () =
  match getenv_nonempty "MASC_NOTIFY_ALLOW_SHELL_EXECUTE" with
  | Some value -> is_truthy value
  | None -> false

let render_focus_template template payload =
  let replace token value acc =
    String_util.replace_substring ~needle:token ~by:value acc
  in
  template
  |> replace "{{target}}" (token_value payload.target_agent)
  |> replace "{{from}}" (token_value payload.from_agent)
  |> replace "{{task}}" (token_value payload.task_id)

type notifier =
  | Terminal_notifier
  | Osascript

(* Both programs exist only on macOS, so finding one is the platform check
   as well; a host with neither posts nothing and starts no process. The
   lookup is a PATH scan, not a spawned [which]: a probe that runs a program
   to ask whether a program can run puts a second unbounded process on the
   turn's path for an answer the scan already gives. *)
let available_notifier () =
  if Executable_path.command_available "terminal-notifier" then Some Terminal_notifier
  else if Executable_path.command_available "osascript" then Some Osascript
  else None

(** Escape string for shell *)
let escape_shell s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (fun c ->
    match c with
    | '\'' -> Buffer.add_string buf "'\\''"
    | '\n' -> Buffer.add_string buf " "
    | _ -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

(** Build click focus command from env config *)
let build_focus_command payload =
  if not (shell_execute_clicks_enabled ()) then
    None
  else
    match getenv_nonempty "MASC_NOTIFY_FOCUS_CMD" with
    | Some template -> Some (render_focus_template template payload)
    | None ->
      let focus_app = getenv_nonempty "MASC_NOTIFY_FOCUS_APP" in
      let tmux_session = getenv_nonempty "MASC_TMUX_SESSION" in
      if focus_app = None && tmux_session = None then
        None
      else
        let parts = ref [] in
        (match focus_app with
         | Some app ->
             let cmd = Printf.sprintf "open -a '%s' >/dev/null 2>&1" (escape_shell app) in
             parts := cmd :: !parts
         | None -> ());
        (match tmux_session with
         | Some session ->
             let session_token = sanitize_token session in
             let target_token = token_value payload.target_agent in
             let window_target =
               if session_token = "" then ""
               else if target_token = "" then session_token
               else Printf.sprintf "%s:%s" session_token target_token
             in
             if window_target <> "" then begin
               let select_window = Printf.sprintf
                 "command -v tmux >/dev/null 2>&1 && tmux select-window -t '%s' >/dev/null 2>&1 || true"
                 (escape_shell window_target)
               in
               parts := select_window :: !parts;
               if target_token <> "" then
                 let select_pane = Printf.sprintf
                   "command -v tmux >/dev/null 2>&1 && tmux select-pane -t '%s.0' >/dev/null 2>&1 || true"
                   (escape_shell window_target)
                 in
                 parts := select_pane :: !parts
             end
         | None -> ());
        Some (String.concat "; " (List.rev !parts))

(** Escape string for AppleScript *)
let escape_applescript s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf " "
    | _ -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

(** Agent emoji mapping for visual distinction.
    The table starts with only ["system"]; operator code registers
    per-agent emoji via {!register_agent_emoji} during init. The
    server holds no closed roster of MCP client names. *)
let agent_emoji_table : (string, string) Hashtbl.t =
  let t = Hashtbl.create 8 in
  Hashtbl.replace t "system" "⚙️";
  t

(** Register an agent-name → emoji mapping at startup.
    Call this from your provider adapter's init hook to extend the table
    without touching notify.ml. *)
let register_agent_emoji name emoji =
  Hashtbl.replace agent_emoji_table name emoji

(** Read-only lookup. Returns "🤖" for unknown agents. *)
let agent_emoji name =
  match Hashtbl.find_opt agent_emoji_table name with
  | Some emoji -> emoji
  | None -> "🤖"

(** Send notification via terminal-notifier (preferred) *)
let send_via_terminal_notifier ~title ~subtitle ~message ~sound ~focus_cmd =
  let argv =
    ["terminal-notifier";
     "-title"; title;
     "-subtitle"; subtitle;
     "-message"; message;
     "-group"; "masc"]
    |> fun base -> if sound then base @ ["-sound"; "default"] else base
    |> fun base ->
    match focus_cmd with
    | Some cmd when shell_execute_clicks_enabled () -> base @ ["-execute"; cmd]
    | Some _ | None -> base
  in
  run_notifier argv

(** Send notification via osascript (fallback) *)
let send_via_osascript ~title ~subtitle ~message =
  let title = escape_applescript title in
  let subtitle = escape_applescript subtitle in
  let message = escape_applescript message in
  let script = Printf.sprintf
    "display notification \"%s\" with title \"%s\" subtitle \"%s\""
    message title subtitle
  in
  run_notifier ["osascript"; "-e"; script]

(** Post the notification through whichever notifier this host has. *)
let send_notification ~sound ~focus_cmd ~title ~subtitle ~message =
  match available_notifier () with
  | None -> ()
  | Some Terminal_notifier ->
    send_via_terminal_notifier ~title ~subtitle ~message ~sound ~focus_cmd
  | Some Osascript ->
    (* The osascript path takes no focus_cmd: it can hold an operator's
       shell snippet, which would need `sh -c`. terminal-notifier runs click
       actions itself. *)
    send_via_osascript ~title ~subtitle ~message

let notify_mention ?target_agent ~from_agent ~message () =
  let emoji = agent_emoji from_agent in
  let focus_cmd =
    build_focus_command { target_agent; from_agent = Some from_agent; task_id = None }
  in
  send_notification
    ~title:(Printf.sprintf "%s MASC" emoji)
    ~subtitle:(Printf.sprintf "@%s mentioned you" from_agent)
    ~message
    ~focus_cmd
    ~sound:true

