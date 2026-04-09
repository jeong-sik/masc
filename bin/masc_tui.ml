[@@@warning "-32-69"]
open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render
open Masc_tui_loader

(** Send a message to a keeper via HTTP POST to /api/v1/keepers/chat/stream *)
let send_keeper_message (state : state) (keeper_name : string) (message : string) : string =
  try
    let host = Env_config_core.masc_host () in
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
  let port = ref (Env_config_core.masc_http_port_int ()) in
  let room = ref "" in
  let refresh = ref 2.0 in
  let base_path = ref "" in

  let specs = [
    ("--port", Arg.Set_int port, Printf.sprintf "MASC server port (default: %d)" (Env_config_core.masc_http_port_int ()));
    ("--room", Arg.Set_string room, "Room name (default: from base path)");
    ("--refresh", Arg.Set_float refresh, "Refresh interval in seconds (default: 2)");
    ("--base", Arg.Set_string base_path, "Base path (default: MASC_BASE_PATH or cwd)");
  ] in

  Arg.parse specs (fun _ -> ()) "masc-tui [OPTIONS]";

  (* Resolve base path *)
  let base = if !base_path <> "" then !base_path
    else match Sys.getenv_opt "MASC_BASE_PATH" with
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
