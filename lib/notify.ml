(** macOS Notification via terminal-notifier (with osascript fallback)
    Sends native macOS notifications for MASC events with custom icons *)

(** Notification event types *)
type event =
  | Mention of { from_agent: string; target_agent: string option; message: string }
  | Interrupt of { agent: string; action: string }
  | PortalMessage of { from_agent: string; target_agent: string option; message: string }
  | TaskCompleted of { agent: string; task_id: string }
  | Custom of { title: string; subtitle: string; message: string }

(** Focus payload for click actions *)
type focus_payload = {
  target_agent: string option;
  from_agent: string option;
  task_id: string option;
}

let exec_gate_raw_source argv =
  String.concat " " (List.map Filename.quote argv)

(** {1 Non-blocking Shell Execution} *)

(** Run argv and get single line (Eio-native, no shell) *)
let run_argv_line argv =
  let output =
    Masc_exec.Exec_gate.run_argv
      ~actor:"system/notify"
      ~raw_source:(exec_gate_raw_source argv)
      ~summary:"notify argv"
      ~timeout_sec:10.0
      argv
  in
  match String.split_on_char '\n' output with
  | [] -> ""
  | h :: _ -> String.trim h

let string_of_process_status = function
  | Unix.WEXITED n -> Printf.sprintf "exited %d" n
  | Unix.WSIGNALED n -> Printf.sprintf "signaled %d" n
  | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n

let run_argv_ignore argv =
  (try
     let status, _output =
       Masc_exec.Exec_gate.run_argv_with_status
         ~actor:"system/notify"
         ~raw_source:(exec_gate_raw_source argv)
         ~summary:"notify argv"
         ~timeout_sec:60.0
         argv
     in
     match status with
     | Unix.WEXITED 0 -> ()
     | _ ->
         Log.Misc.warn "notify command exited with status %s: %s"
           (string_of_process_status status)
           (String.concat " " argv)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn -> Log.Misc.error "run_argv_ignore failed: %s" (Printexc.to_string exn))

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

let focus_on_osascript () =
  match getenv_nonempty "MASC_NOTIFY_FOCUS_ON_OSASCRIPT" with
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

(** Check if running on macOS *)
let is_macos () =
  try
    let os = run_argv_line ["uname"; "-s"] in
    os = "Darwin"
  with End_of_file | Unix.Unix_error _ -> false

(** Check if terminal-notifier is available *)
let has_terminal_notifier =
  Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let result = run_argv_line ["which"; "terminal-notifier"] in
    result <> ""
  )

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
    Agent names come from spawn_key in Provider_adapter.direct_adapters.
    Use {!register_agent_emoji} at startup to add provider-specific entries
    without modifying this file. *)
let agent_emoji_table : (string, string) Hashtbl.t =
  let t = Hashtbl.create 8 in
  List.iter (fun (k, v) -> Hashtbl.replace t k v)
    [ ("claude", "🟣");
      ("gemini", "🔵");
      ("codex",  "🟢");
      ("llama",  "🦙");
      ("system", "⚙️") ];
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
    |> fun base -> match focus_cmd with
      | Some cmd -> base @ ["-execute"; cmd]
      | None -> base
  in
  run_argv_ignore argv

(** Send notification via osascript (fallback) *)
let send_via_osascript ~title ~subtitle ~message =
  let title = escape_applescript title in
  let subtitle = escape_applescript subtitle in
  let message = escape_applescript message in
  let script = Printf.sprintf
    "display notification \"%s\" with title \"%s\" subtitle \"%s\""
    message title subtitle
  in
  run_argv_ignore ["osascript"; "-e"; script]

(** Send macOS notification - uses terminal-notifier if available *)
let send_notification ?(sound=false) ?focus_cmd ~title ~subtitle ~message () =
  if not (is_macos ()) then
    (* Silently skip on non-macOS *)
    ()
  else if Eio.Lazy.force has_terminal_notifier then
    send_via_terminal_notifier ~title ~subtitle ~message ~sound ~focus_cmd
  else begin
    send_via_osascript ~title ~subtitle ~message;
    (try let _ = focus_on_osascript () in ()
     with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Misc.error "focus_on_osascript failed: %s" (Printexc.to_string exn));
    (* NOTE: For osascript fallback, we intentionally do not execute focus_cmd.
       focus_cmd can contain arbitrary shell snippets (user-configured) and would
       require `sh -c` execution. terminal-notifier handles click actions. *)
  end

(** Send notification for MASC event *)
let notify event =
  match event with
  | Mention { from_agent; target_agent; message } ->
      let emoji = agent_emoji from_agent in
      let focus_cmd = build_focus_command {
        target_agent;
        from_agent = Some from_agent;
        task_id = None;
      } in
      send_notification
        ~title:(Printf.sprintf "%s MASC" emoji)
        ~subtitle:(Printf.sprintf "@%s mentioned you" from_agent)
        ~message
        ?focus_cmd
        ~sound:true  (* Sound for mentions! *)
        ()

  | Interrupt { agent; action } ->
      let focus_cmd = build_focus_command {
        target_agent = Some agent;
        from_agent = Some agent;
        task_id = None;
      } in
      send_notification
        ~title:"⚠️ MASC - Approval Needed"
        ~subtitle:agent
        ~message:(Printf.sprintf "Action: %s" action)
        ?focus_cmd
        ~sound:true  (* Sound for interrupts! *)
        ()

  | PortalMessage { from_agent; target_agent; message } ->
      let emoji = agent_emoji from_agent in
      let focus_cmd = build_focus_command {
        target_agent;
        from_agent = Some from_agent;
        task_id = None;
      } in
      send_notification
        ~title:(Printf.sprintf "%s MASC Portal" emoji)
        ~subtitle:(Printf.sprintf "From: %s" from_agent)
        ~message
        ?focus_cmd
        ()

  | TaskCompleted { agent; task_id } ->
      let emoji = agent_emoji agent in
      let focus_cmd = build_focus_command {
        target_agent = Some agent;
        from_agent = Some agent;
        task_id = Some task_id;
      } in
      send_notification
        ~title:(Printf.sprintf "%s MASC" emoji)
        ~subtitle:"✅ Task Completed"
        ~message:(Printf.sprintf "%s finished %s" agent task_id)
        ?focus_cmd
        ()

  | Custom { title; subtitle; message } ->
      let focus_cmd = build_focus_command {
        target_agent = None;
        from_agent = None;
        task_id = None;
      } in
      send_notification ~title ~subtitle ~message ?focus_cmd ()

(** Convenience functions for common notifications *)
let notify_mention ?target_agent ~from_agent ~message () =
  notify (Mention { from_agent; target_agent; message })

let notify_portal ?target_agent ~from_agent ~message () =
  notify (PortalMessage { from_agent; target_agent; message })

let notify_task_done ~agent ~task_id =
  notify (TaskCompleted { agent; task_id })
