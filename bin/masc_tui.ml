(** MASC TUI - Terminal User Interface for Multi-Agent Coordination *)

[@@@warning "-32-69"]

open Masc_tui_types
module Ansi = Masc_tui_ansi
module Loader = Masc_tui_loader
module Render = Masc_tui_render

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

        (* Parse SSE response: look for data: lines *)
        let lines = String.split_on_char '\n' response in
        let result = Buffer.create 1024 in
        List.iter (fun line ->
          let line = String.trim line in
          if String.length line > 6 && String.sub line 0 6 = "data: " then begin
            let data = String.sub line 6 (String.length line - 6) in
            (* Try to parse JSON and extract delta *)
            (try
              let json = Yojson.Safe.from_string data in
              let open Yojson.Safe.Util in
              let typ = try json |> member "type" |> to_string with Type_error _ -> "" in
              if typ = "content_delta" || typ = "delta" then begin
                let delta = try json |> member "delta" |> to_string with Type_error _ -> "" in
                Buffer.add_string result delta
              end else if typ = "content_complete" || typ = "complete" then begin
                let text = try json |> member "text" |> to_string with Type_error _ -> "" in
                if text <> "" && Buffer.length result = 0 then
                  Buffer.add_string result text
              end
            with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ())
          end
        ) lines;

        let reply = Buffer.contents result in
        if String.length reply > 0 then reply
        else begin
          (* Fallback: look for JSON response body *)
          let body_start = try
            let idx = ref 0 in
            let found = ref false in
            while not !found && !idx < String.length response - 3 do
              if String.sub response !idx 4 = "\r\n\r\n" then begin
                found := true;
                idx := !idx + 4
              end else
                incr idx
            done;
            if !found then !idx else 0
          with Invalid_argument _ -> 0 in
          if body_start > 0 then begin
            let body_str = String.sub response body_start (String.length response - body_start) in
            (* Try parsing as JSON *)
            (try
              let json = Yojson.Safe.from_string (String.trim body_str) in
              let open Yojson.Safe.Util in
              let text = try json |> member "result" |> member "text" |> to_string with Type_error _ -> "" in
              if text <> "" then text
              else
                let msg = try json |> member "error" |> member "message" |> to_string with Type_error _ -> "" in
                if msg <> "" then "(error: " ^ msg ^ ")"
                else "(no response parsed)"
            with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> "(response parsing failed)")
          end else "(empty response)"
        end)
  with
  | Unix.Unix_error (err, _, _) ->
    Printf.sprintf "(connection failed: %s -- is MASC server running on port %d?)"
      (Unix.error_message err) state.port
  | exn ->
    Printf.sprintf "(error: %s)" (Printexc.to_string exn)

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
      Render.render state;

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
      Loader.load_from_masc_dir state base_path
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
  Loader.load_from_masc_dir state base_path;
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
           Loader.load_from_masc_dir state base_path;
           (* Also reload logs if in log view *)
           (match state.view with
            | Keeper_logs when state.keeper_cursor < List.length state.keepers ->
                let k = List.nth state.keepers state.keeper_cursor in
                state.log_entries <- Loader.load_keeper_logs base_path k.k_name 200
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
                  Loader.load_live_context state base_path k.k_name
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
                  Loader.load_live_context state base_path k.k_name
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
                  Loader.load_live_context state base_path k.k_name
                end
            | _ -> ())
       | Some "l" | Some "L" ->
           (* L opens log view from detail *)
           (match state.view with
            | Keeper_detail when state.keeper_cursor < List.length state.keepers ->
                let k = List.nth state.keepers state.keeper_cursor in
                state.log_entries <- Loader.load_keeper_logs base_path k.k_name 200;
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
        Loader.load_from_masc_dir state base_path;
        (* Also refresh logs if viewing them *)
        (match state.view with
         | Keeper_logs when state.keeper_cursor < List.length state.keepers ->
             let k = List.nth state.keepers state.keeper_cursor in
             state.log_entries <- Loader.load_keeper_logs base_path k.k_name 200
         | _ -> ());
        last_check := now
      end;

      (* Render *)
      Render.render state
    done
  with Exit -> ()

let () = main ()
