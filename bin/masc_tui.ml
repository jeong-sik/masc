open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render
open Masc_tui_loader

(** Local exception for breaking the main TUI loop without using Exit. *)
exception Break

(** Send a message to a keeper via HTTP POST to /api/v1/keepers/chat/stream *)
let send_keeper_message (state : state) (keeper_name : string) (message : string) : string =
  try
    let host = Env_config_core.masc_host () in
    let port = state.port in
    let body =
      Yojson.Safe.to_string
        (`Assoc
          [
            ("name", `String keeper_name);
            ("message", `String message);
            ("models", `List []);
          ])
    in
    match
      Masc_tui_http.post_raw_json ~host ~port
        ~path:"/api/v1/keepers/chat/stream" ~body
    with
    | Ok response -> (
        match Tui_decode.parse_keeper_chat_response response with
        | Ok reply -> reply
        | Error err -> "(response parsing failed: " ^ err ^ ")")
    | Error err -> err
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
  let workspace = ref "" in
  let refresh = ref 2.0 in
  let base_path = ref "" in

  let specs = [
    ("--port", Arg.Set_int port, Printf.sprintf "MASC server port (default: %d)" (Env_config_core.masc_http_port_int ()));
    ("--workspace", Arg.Set_string workspace, "Workspace name (default: from base path)");
    ("--refresh", Arg.Set_float refresh, "Refresh interval in seconds (default: 2)");
    ( "--base-path",
      Arg.Set_string base_path,
      "Workspace/base path; .masc lives below it (default: MASC_BASE_PATH or cwd)" );
    ( "--base",
      Arg.Set_string base_path,
      "Alias for --base-path" );
  ] in

  Arg.parse specs (fun _ -> ()) "masc-tui [OPTIONS]";

  (* Resolve base path *)
  let base =
    if !base_path <> "" then (
      match Env_config_core.normalize_masc_base_path_input !base_path with
      | "" -> Config_dir_resolver.base_path_or_cwd ()
      | p -> p)
    else Config_dir_resolver.base_path_or_cwd ()
  in

  (* Resolve workspace *)
  let r = if !workspace <> "" then !workspace
    else match Env_config_core.cluster_name_opt () with
      | Some name -> name
      | None -> Filename.basename base
  in

  (base, r, !port, !refresh)

(** Handle key input for message mode *)
let handle_message_key (state : state) (base_path : string) (key : string) : bool =
  match key with
  | "esc" ->
    state.view <- Keepers Keeper_detail;
    state.detail_scroll <- 0;
    true
  | "\r" | "\n" ->
    (* Send the message *)
    let text = Buffer.contents state.msg_input in
    if String.length (String.trim text) > 0 then begin
      let keeper_name =
        match List.nth_opt state.keepers state.keeper_cursor with
        | Some k -> k.k_name
        | None -> "unknown"
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

let approval_decision_wire = function
  | Confirm -> "confirm"
  | Deny -> "deny"

let approval_decision_key = function
  | Confirm -> "y"
  | Deny -> "n"

let approval_decision_done = function
  | Confirm -> "Confirmed"
  | Deny -> "Denied"

let approval_decision_failed = function
  | Confirm -> "Confirm failed"
  | Deny -> "Deny failed"

let pending_approval_matches pending approval decision =
  match pending with
  | Some p ->
      String.equal p.paa_token approval.ap_token && p.paa_decision = decision
  | None -> false

let remember_surface_error state ~surface ~current_error ~set_error err =
  let changed =
    match current_error with
    | Some current -> not (String.equal current err)
    | None -> true
  in
  set_error (Some err);
  if changed then
    add_event state "error"
      (Printf.sprintf "%s data unreliable: %s" surface err)

let apply_overview_load state = function
  | Ok overview ->
      state.overview <- Some overview;
      state.overview_error <- None
  | Error err ->
      state.overview <- None;
      remember_surface_error state ~surface:"overview"
        ~current_error:state.overview_error
        ~set_error:(fun value -> state.overview_error <- value)
        err

let apply_board_list_load state = function
  | Ok posts ->
      state.board_posts <- posts;
      state.board_error <- None;
      if state.board_cursor >= List.length posts then
        state.board_cursor <- max 0 (List.length posts - 1)
  | Error err ->
      state.board_posts <- [];
      state.board_comments <- [];
      state.board_mode <- Board_list;
      remember_surface_error state ~surface:"board"
        ~current_error:state.board_error
        ~set_error:(fun value -> state.board_error <- value)
        err

let apply_planning_load state = function
  | Ok planning ->
      state.planning <- Some planning;
      state.planning_error <- None;
      if state.planning_cursor >= List.length planning.pl_goals then
        state.planning_cursor <- max 0 (List.length planning.pl_goals - 1)
  | Error err ->
      state.planning <- None;
      state.planning_mode <- Planning_list;
      remember_surface_error state ~surface:"planning"
        ~current_error:state.planning_error
        ~set_error:(fun value -> state.planning_error <- value)
        err

let refresh_http_surfaces state ~host ~port =
  apply_overview_load state (load_overview ~host ~port);
  apply_board_list_load state (load_board_list ~host ~port);
  apply_planning_load state (load_planning ~host ~port)

let apply_board_post_load state ~post_id = function
  | Ok (post, comments) ->
      state.board_mode <- Board_read post_id;
      state.board_error <- None;
      state.board_comments <- comments;
      state.board_posts <-
        post :: List.filter (fun p -> p.bp_id <> post_id) state.board_posts
  | Error err ->
      remember_surface_error state ~surface:"board"
        ~current_error:state.board_error
        ~set_error:(fun value -> state.board_error <- value)
        err

let execute_approval_decision state approval decision =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let decision_wire = approval_decision_wire decision in
  match
    Masc_tui_http.post_operator_confirm ~host ~port ~token:approval.ap_token
      ~decision:decision_wire
  with
  | Ok _ ->
      state.pending_approval_action <- None;
      add_event state "system"
        (Printf.sprintf "%s: %s" (approval_decision_done decision)
           approval.ap_summary);
      apply_overview_load state (load_overview ~host ~port);
      state.approval_cursor <- 0
  | Error err ->
      state.pending_approval_action <- None;
      add_event state "error"
        (Printf.sprintf "%s: %s" (approval_decision_failed decision) err)

let handle_approval_decision state approval decision =
  if pending_approval_matches state.pending_approval_action approval decision then
    execute_approval_decision state approval decision
  else begin
    state.pending_approval_action <-
      Some { paa_token = approval.ap_token; paa_decision = decision };
    add_event state "system"
      (Printf.sprintf "Press %s again: %s"
         (approval_decision_key decision)
         approval.ap_summary)
  end

(** Main loop *)
let main () =
  let (base_path, workspace, port, refresh) = parse_args () in
  let state = create_state ~workspace ~port ~refresh_interval:refresh in
  state.view <- Overview;

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
  let host = Env_config_core.masc_host () in
  let port = state.port in
  refresh_http_surfaces state ~host ~port;
  add_event state "system" "TUI started";
  state.connection_status <- "connected";

  (* Main loop *)
  let last_check = ref (Unix.gettimeofday ()) in
  try
    while true do
      (* Check for input *)
      let key = read_key () in
      (match key with
       | Some k when state.view = Keepers Keeper_message ->
           let _handled = handle_message_key state base_path k in
           ()
       | Some "q" | Some "Q" -> raise Break
       | Some "y" | Some "Y" ->
           (match state.view with
            | Approvals ->
                (match state.overview with
                 | None -> ()
                 | Some o ->
                     (match List.nth_opt o.ov_pending_confirms state.approval_cursor with
                      | Some a -> handle_approval_decision state a Confirm
                      | None -> ()))
            | _ -> ())
       | Some "n" | Some "N" ->
           (match state.view with
            | Approvals ->
                (match state.overview with
                 | None -> ()
                 | Some o ->
                     (match List.nth_opt o.ov_pending_confirms state.approval_cursor with
                      | Some a -> handle_approval_decision state a Deny
                      | None -> ()))
            | _ -> ())
       | Some "r" | Some "R" ->
           state.pending_approval_action <- None;
           load_from_masc_dir state base_path;
           let host = Env_config_core.masc_host () in
           let port = state.port in
           refresh_http_surfaces state ~host ~port;
           (* Also reload logs / board / planning detail if viewing them *)
           (match state.view with
            | Keepers Keeper_logs ->
                (match List.nth_opt state.keepers state.keeper_cursor with
                 | Some k ->
                     state.log_entries <- load_keeper_logs base_path k.k_name 200
                 | None -> ())
            | Board ->
                (match state.board_mode with
                 | Board_read post_id ->
                     (match load_board_post ~host ~port ~post_id with
                      | Ok _ as result -> apply_board_post_load state ~post_id result
                      | Error _ as result ->
                          apply_board_post_load state ~post_id result;
                          state.board_mode <- Board_list)
                 | Board_list -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_detail goal_id ->
                     (match state.planning with
                      | Some p ->
                          (match List.find_opt (fun g -> g.pg_id = goal_id) p.pl_goals with
                           | Some _ -> ()
                           | None -> state.planning_mode <- Planning_list)
                      | None -> state.planning_mode <- Planning_list)
                 | Planning_list -> ())
            | Overview | Keepers Keeper_list | Keepers Keeper_detail | Keepers Keeper_message
            | Approvals | Command | Workspace _ | Lab _ | Logs | Monitoring _ -> ());
           add_event state "system" "Manual refresh"
       | Some "\t" ->
           (* Tab cycles through primary surfaces *)
           (match state.view with
            | Overview -> state.view <- Keepers Keeper_list
            | Keepers _ -> state.view <- Approvals
            | Approvals -> state.view <- Board
            | Board -> state.view <- Planning
            | Planning -> state.view <- Command
            | Command -> state.view <- Workspace Work
            | Workspace _ -> state.view <- Lab Tools
            | Lab _ -> state.view <- Logs
            | Logs -> state.view <- Overview
            | Monitoring _ -> state.view <- Overview)
       | Some "esc" ->
           (* Esc goes back *)
           (match state.view with
            | Keepers Keeper_detail ->
                state.view <- Keepers Keeper_list;
                state.detail_scroll <- 0
            | Keepers Keeper_logs ->
                state.view <- Keepers Keeper_detail;
                state.log_scroll <- 0;
                state.detail_scroll <- 0
            | Keepers Keeper_message ->
                state.view <- Keepers Keeper_detail;
                state.detail_scroll <- 0
            | Board ->
                (match state.board_mode with
                 | Board_read _ ->
                     state.board_mode <- Board_list;
                     state.board_scroll <- 0
                 | Board_list -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_detail _ ->
                     state.planning_mode <- Planning_list;
                     state.planning_scroll <- 0
                 | Planning_list -> ())
            | Overview | Keepers Keeper_list | Approvals | Command | Workspace _ | Lab _ | Logs | Monitoring _ -> ())
       | Some "j" | Some "down" ->
           (match state.view with
            | Keepers Keeper_list ->
                if state.keeper_cursor < List.length state.keepers - 1 then begin
                  state.keeper_cursor <- state.keeper_cursor + 1;
                  (match List.nth_opt state.keepers state.keeper_cursor with
                   | Some k -> load_live_context state base_path k.k_name
                   | None -> ())
                end
            | Keepers Keeper_detail ->
                state.detail_scroll <- state.detail_scroll + 1
            | Keepers Keeper_logs ->
                state.log_scroll <- state.log_scroll + 1
            | Approvals ->
                let count = match state.overview with None -> 0 | Some o -> List.length o.ov_pending_confirms in
                if state.approval_cursor < count - 1 then begin
                  state.pending_approval_action <- None;
                  state.approval_cursor <- state.approval_cursor + 1
                end
            | Board ->
                (match state.board_mode with
                 | Board_list ->
                     if state.board_cursor < List.length state.board_posts - 1 then
                       state.board_cursor <- state.board_cursor + 1
                 | Board_read _ ->
                     state.board_scroll <- state.board_scroll + 1)
            | Planning ->
                (match state.planning_mode with
                 | Planning_list ->
                     let goals = match state.planning with None -> [] | Some p -> p.pl_goals in
                     if state.planning_cursor < List.length goals - 1 then
                       state.planning_cursor <- state.planning_cursor + 1
                 | Planning_detail _ ->
                     state.planning_scroll <- state.planning_scroll + 1)
            | Overview | Keepers Keeper_message | Command | Workspace _ | Lab _ | Logs | Monitoring _ -> ())
       | Some "k" | Some "up" ->
           (match state.view with
            | Keepers Keeper_list ->
                if state.keeper_cursor > 0 then begin
                  state.keeper_cursor <- state.keeper_cursor - 1;
                  (match List.nth_opt state.keepers state.keeper_cursor with
                   | Some k -> load_live_context state base_path k.k_name
                   | None -> ())
                end
            | Keepers Keeper_detail ->
                if state.detail_scroll > 0 then
                  state.detail_scroll <- state.detail_scroll - 1
            | Keepers Keeper_logs ->
                if state.log_scroll > 0 then
                  state.log_scroll <- state.log_scroll - 1
            | Approvals ->
                if state.approval_cursor > 0 then begin
                  state.pending_approval_action <- None;
                  state.approval_cursor <- state.approval_cursor - 1
                end
            | Board ->
                (match state.board_mode with
                 | Board_list ->
                     if state.board_cursor > 0 then
                       state.board_cursor <- state.board_cursor - 1
                 | Board_read _ ->
                     if state.board_scroll > 0 then
                       state.board_scroll <- state.board_scroll - 1)
            | Planning ->
                (match state.planning_mode with
                 | Planning_list ->
                     if state.planning_cursor > 0 then
                       state.planning_cursor <- state.planning_cursor - 1
                 | Planning_detail _ ->
                     if state.planning_scroll > 0 then
                       state.planning_scroll <- state.planning_scroll - 1)
            | Overview | Keepers Keeper_message | Command | Workspace _ | Lab _ | Logs | Monitoring _ -> ())
       | Some "\r" | Some "\n" ->
           (* Enter opens detail from list *)
           (match state.view with
            | Keepers Keeper_list ->
                (match List.nth_opt state.keepers state.keeper_cursor with
                 | Some k ->
                     state.view <- Keepers Keeper_detail;
                     state.detail_scroll <- 0;
                     load_live_context state base_path k.k_name
                 | None -> ())
            | Board ->
                (match state.board_mode with
                 | Board_list ->
                     (match List.nth_opt state.board_posts state.board_cursor with
                      | Some p ->
                          let host = Env_config_core.masc_host () in
                          let port = state.port in
                          (match load_board_post ~host ~port ~post_id:p.bp_id with
                           | Ok _ as result ->
                               state.board_scroll <- 0;
                               apply_board_post_load state ~post_id:p.bp_id result
                           | Error err as result ->
                               apply_board_post_load state ~post_id:p.bp_id result;
                               add_event state "error"
                                 (Printf.sprintf "Failed to load board post %s: %s"
                                    p.bp_id err))
                      | None -> ())
                 | Board_read _ -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_list ->
                     let goals = match state.planning with None -> [] | Some p -> p.pl_goals in
                     (match List.nth_opt goals state.planning_cursor with
                      | Some g ->
                          state.planning_mode <- Planning_detail g.pg_id;
                          state.planning_scroll <- 0
                      | None -> ())
                 | Planning_detail _ -> ())
            | Overview | Keepers Keeper_detail | Keepers Keeper_logs | Keepers Keeper_message
            | Approvals | Command | Workspace _ | Lab _ | Logs | Monitoring _ -> ())
       | Some "l" | Some "L" ->
           (* L opens log view from detail *)
           (match state.view with
            | Keepers Keeper_detail ->
                (match List.nth_opt state.keepers state.keeper_cursor with
                 | Some k ->
                     state.log_entries <- load_keeper_logs base_path k.k_name 200;
                     state.log_scroll <- max 0 (List.length state.log_entries - 1);
                     state.view <- Keepers Keeper_logs
                 | None -> ())
            | Overview | Keepers Keeper_list | Keepers Keeper_logs | Keepers Keeper_message
            | Board | Approvals | Planning | Command | Workspace _ | Lab _ | Logs | Monitoring _ -> ())
       | Some "m" | Some "M" ->
           (* M opens message view from detail *)
           (match state.view with
            | Keepers Keeper_detail when state.keeper_cursor < List.length state.keepers ->
                Buffer.clear state.msg_input;
                state.view <- Keepers Keeper_message
            | Keepers Keeper_detail | Overview | Keepers Keeper_list | Keepers Keeper_logs | Keepers Keeper_message
            | Board | Approvals | Planning | Command | Workspace _ | Lab _ | Logs | Monitoring _ -> ())
       | _ -> ());

      (* Periodic refresh *)
      let now = Unix.gettimeofday () in
      if now -. !last_check >= refresh then begin
        state.pending_approval_action <- None;
        load_from_masc_dir state base_path;
        let host = Env_config_core.masc_host () in
        let port = state.port in
        refresh_http_surfaces state ~host ~port;
        (* Also refresh logs / board / planning detail if viewing them *)
        (match state.view with
         | Keepers Keeper_logs ->
             (match List.nth_opt state.keepers state.keeper_cursor with
              | Some k ->
                  state.log_entries <- load_keeper_logs base_path k.k_name 200
              | None -> ())
         | Board ->
             (match state.board_mode with
              | Board_read post_id ->
                  (match load_board_post ~host ~port ~post_id with
                   | Ok _ as result -> apply_board_post_load state ~post_id result
                   | Error _ as result ->
                       apply_board_post_load state ~post_id result;
                       state.board_mode <- Board_list)
              | Board_list -> ())
         | Planning ->
             (match state.planning_mode with
              | Planning_detail goal_id ->
                  (match state.planning with
                   | Some p ->
                       (match List.find_opt (fun g -> g.pg_id = goal_id) p.pl_goals with
                        | Some _ -> ()
                        | None -> state.planning_mode <- Planning_list)
                   | None -> state.planning_mode <- Planning_list)
              | Planning_list -> ())
         | Overview | Keepers Keeper_list | Keepers Keeper_detail | Keepers Keeper_message
         | Approvals | Command | Workspace _ | Lab _ | Logs | Monitoring _ -> ());
        last_check := now
      end;

      (* Render *)
      render state
    done
  with Break -> ()

let run_with_eio_context f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.set_env env;
  Eio_context.set_switch sw;
  Eio_context.set_net (Eio.Stdenv.net env);
  Eio_context.set_clock (Eio.Stdenv.clock env);
  Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
  f ()

let () = run_with_eio_context main
