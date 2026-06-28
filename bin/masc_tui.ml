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

(** Read a single byte from stdin, returning Some char or None. *)
let read_byte_unix ?(timeout = 0.1) () : char option =
  let ready, _, _ = Unix.select [Unix.stdin] [] [] timeout in
  if ready <> [] then begin
    let buf = Bytes.create 1 in
    let n = Unix.read Unix.stdin buf 0 1 in
    if n > 0 then Some (Bytes.get buf 0)
    else None
  end else
    None

(** Read a single byte from stdin, returning Some char or None. *)
let read_byte () : char option =
  Eio_guard.run_in_systhread (fun () -> read_byte_unix ())

(** Try to read an escape sequence. Returns a key description. *)
let read_key () : string option =
  Eio_guard.run_in_systhread (fun () ->
      match read_byte_unix () with
      | None -> None
      | Some '\027' -> (
          (* Escape sequence: try to read [ and then the code. *)
          match read_byte_unix ~timeout:0.05 () with
          | Some '[' -> (
              match read_byte_unix ~timeout:0.05 () with
              | Some 'A' -> Some "up"
              | Some 'B' -> Some "down"
              | Some 'Z' -> Some "shift-tab"
              | Some _ -> Some "unknown-esc"
              | None -> Some "esc")
          | Some _ | None -> Some "esc")
      | Some c -> Some (String.make 1 c))

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

type http_surface_results = {
  http_overview: (overview_snapshot, string) result;
  http_board: (board_post list, string) result;
  http_planning: (planning_snapshot, string) result;
}

type async_msg =
  | Http_refresh_done of http_surface_results
  | Http_refresh_failed of string
  | Board_post_refresh_done of string * (board_post * board_comment list, string) result
  | Board_post_refresh_failed of string * string
  | Approval_decision_done of
      approval_item
      * approval_decision
      * (Yojson.Safe.t, string) result
      * (overview_snapshot, string) result option
  | Approval_decision_failed of approval_item * approval_decision * string

let enqueue_async mailbox msg = Eio.Stream.add mailbox msg

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
      let goals = planning_visible_goals planning.pl_goals in
      if state.planning_cursor >= List.length goals then
        state.planning_cursor <- max 0 (List.length goals - 1)
  | Error err ->
      state.planning <- None;
      state.planning_mode <- Planning_list;
      remember_surface_error state ~surface:"planning"
        ~current_error:state.planning_error
        ~set_error:(fun value -> state.planning_error <- value)
        err

let refresh_status results =
  let successes =
    List.fold_left
      (fun count -> function
        | Ok () -> count + 1
        | Error () -> count)
      0 results
  in
  match (successes, List.length results) with
  | 0, _ -> "disconnected"
  | n, total when n = total -> "connected"
  | _ -> "degraded"

let load_http_surfaces ~host ~port =
  {
    http_overview = load_overview ~host ~port;
    http_board = load_board_list ~host ~port;
    http_planning = load_planning ~host ~port;
  }

let apply_http_surfaces state results =
  apply_overview_load state results.http_overview;
  apply_board_list_load state results.http_board;
  apply_planning_load state results.http_planning;
  state.connection_status <-
    refresh_status
      [
        Result.map (fun _ -> ()) results.http_overview
        |> Result.map_error (fun _ -> ());
        Result.map (fun _ -> ()) results.http_board
        |> Result.map_error (fun _ -> ());
        Result.map (fun _ -> ()) results.http_planning
        |> Result.map_error (fun _ -> ());
      ]

let start_http_refresh state ~host ~port ~refresh_inflight ~mailbox =
  if not !refresh_inflight then begin
    refresh_inflight := true;
    state.connection_status <-
      (match state.connection_status with
      | "connected" | "degraded" -> "reconnecting"
      | _ -> "connecting");
    let run_refresh () =
      try enqueue_async mailbox (Http_refresh_done (load_http_surfaces ~host ~port)) with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        enqueue_async mailbox
          (Http_refresh_failed
             (Printf.sprintf "HTTP refresh failed: %s" (Printexc.to_string exn)))
    in
    match Eio_context.get_switch_opt () with
    | Some sw ->
        Eio.Fiber.fork ~sw run_refresh
    | None ->
        Fun.protect
          ~finally:(fun () -> refresh_inflight := false)
          (fun () -> apply_http_surfaces state (load_http_surfaces ~host ~port))
  end

let board_detail_still_current state post_id =
  match state.view, state.board_mode with
  | Board, Board_read current -> String.equal current post_id
  | _ -> false

let apply_board_post_load state ~post_id = function
  | Ok (post, comments) when board_detail_still_current state post_id ->
      state.board_error <- None;
      state.board_comments <- comments;
      state.board_posts <-
        post :: List.filter (fun p -> p.bp_id <> post_id) state.board_posts
  | Ok _ -> ()
  | Error err ->
      if board_detail_still_current state post_id then
        remember_surface_error state ~surface:"board"
          ~current_error:state.board_error
          ~set_error:(fun value -> state.board_error <- value)
          err

let same_inflight_post inflight post_id =
  match inflight with
  | Some current -> String.equal current post_id
  | None -> false

let start_board_post_refresh state ~host ~port ~post_id ~refresh_inflight
    ~mailbox =
  if not (same_inflight_post !refresh_inflight post_id) then begin
    refresh_inflight := Some post_id;
    let clear_inflight () =
      if same_inflight_post !refresh_inflight post_id then refresh_inflight := None
    in
    let run_refresh () =
      try
        enqueue_async mailbox
          (Board_post_refresh_done
             (post_id, load_board_post ~host ~port ~post_id))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        enqueue_async mailbox
          (Board_post_refresh_failed
             ( post_id,
               Printf.sprintf "board post refresh failed: %s"
                 (Printexc.to_string exn) ))
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> Eio.Fiber.fork ~sw run_refresh
    | None ->
        Fun.protect ~finally:clear_inflight (fun () ->
            apply_board_post_load state ~post_id
              (load_board_post ~host ~port ~post_id))
  end

let apply_approval_decision_result state approval decision overview = function
  | Ok _ ->
      add_event state "system"
        (Printf.sprintf "%s: %s" (approval_decision_done decision)
           approval.ap_summary);
      Option.iter (apply_overview_load state) overview;
      state.approval_cursor <- 0
  | Error err ->
      add_event state "error"
        (Printf.sprintf "%s: %s" (approval_decision_failed decision) err)

let start_approval_decision state approval decision ~action_inflight ~mailbox =
  if !action_inflight then
    add_event state "system" "Approval action already in progress"
  else
    let () = action_inflight := true in
    let () = state.pending_approval_action <- None in
    let host = Env_config_core.masc_host () in
    let port = state.port in
    let decision_wire = approval_decision_wire decision in
    let clear_inflight () = action_inflight := false in
    let run_action () =
      try
        let result =
          Masc_tui_http.post_operator_confirm ~host ~port ~token:approval.ap_token
            ~decision:decision_wire
        in
        let overview =
          match result with
          | Ok _ -> Some (load_overview ~host ~port)
          | Error _ -> None
        in
        enqueue_async mailbox
          (Approval_decision_done (approval, decision, result, overview))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        enqueue_async mailbox
          (Approval_decision_failed
             (approval, decision, Printexc.to_string exn))
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> Eio.Fiber.fork ~sw run_action
    | None ->
        Fun.protect ~finally:clear_inflight (fun () ->
            let result =
              Masc_tui_http.post_operator_confirm ~host ~port
                ~token:approval.ap_token ~decision:decision_wire
            in
            let overview =
              match result with
              | Ok _ -> Some (load_overview ~host ~port)
              | Error _ -> None
            in
            apply_approval_decision_result state approval decision overview result)

(* TEL-OK: TUI-local confirmation gate emits user-visible events here; the
   operator confirmation endpoint owns durable approval telemetry. *)
let handle_approval_decision state approval decision ~action_inflight ~mailbox =
  if pending_approval_matches state.pending_approval_action approval decision then
    start_approval_decision state approval decision ~action_inflight ~mailbox
  else begin
    state.pending_approval_action <-
      Some { paa_token = approval.ap_token; paa_decision = decision };
    add_event state "system"
      (Printf.sprintf "Press %s again: %s"
         (approval_decision_key decision)
         approval.ap_summary)
  end

let apply_async_message state ~http_refresh_inflight
    ~board_post_refresh_inflight ~approval_action_inflight = function
  | Http_refresh_done results ->
      http_refresh_inflight := false;
      apply_http_surfaces state results
  | Http_refresh_failed err ->
      http_refresh_inflight := false;
      state.connection_status <- "disconnected";
      add_event state "error" err
  | Board_post_refresh_done (post_id, result) ->
      if same_inflight_post !board_post_refresh_inflight post_id then
        board_post_refresh_inflight := None;
      apply_board_post_load state ~post_id result
  | Board_post_refresh_failed (post_id, err) ->
      if same_inflight_post !board_post_refresh_inflight post_id then
        board_post_refresh_inflight := None;
      if board_detail_still_current state post_id then
        remember_surface_error state ~surface:"board"
          ~current_error:state.board_error
          ~set_error:(fun value -> state.board_error <- value)
          err
  | Approval_decision_done (approval, decision, result, overview) ->
      approval_action_inflight := false;
      apply_approval_decision_result state approval decision overview result
  | Approval_decision_failed (approval, decision, err) ->
      approval_action_inflight := false;
      add_event state "error"
        (Printf.sprintf "%s: %s" (approval_decision_failed decision) err)

let drain_async_messages state ~http_refresh_inflight
    ~board_post_refresh_inflight ~approval_action_inflight mailbox =
  let rec loop () =
    match Eio.Stream.take_nonblocking mailbox with
    | None -> ()
    | Some msg ->
        apply_async_message state ~http_refresh_inflight
          ~board_post_refresh_inflight ~approval_action_inflight msg;
        loop ()
  in
  loop ()

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
  let http_refresh_inflight = ref false in
  let board_post_refresh_inflight = ref None in
  let approval_action_inflight = ref false in
  let async_messages = Eio.Stream.create 32 in
  start_http_refresh state ~host ~port ~refresh_inflight:http_refresh_inflight
    ~mailbox:async_messages;
  add_event state "system" "TUI started";

  (* Main loop *)
  let last_check = ref (Unix.gettimeofday ()) in
  try
    while true do
      drain_async_messages state ~http_refresh_inflight
        ~board_post_refresh_inflight ~approval_action_inflight async_messages;
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
                      | Some a ->
                          handle_approval_decision state a Confirm
                            ~action_inflight:approval_action_inflight
                            ~mailbox:async_messages
                      | None -> ()))
            | _ -> ())
       | Some "n" | Some "N" ->
           (match state.view with
            | Approvals ->
                (match state.overview with
                 | None -> ()
                 | Some o ->
                     (match List.nth_opt o.ov_pending_confirms state.approval_cursor with
                      | Some a ->
                          handle_approval_decision state a Deny
                            ~action_inflight:approval_action_inflight
                            ~mailbox:async_messages
                      | None -> ()))
            | _ -> ())
       | Some "r" | Some "R" ->
           state.pending_approval_action <- None;
           load_from_masc_dir state base_path;
           let host = Env_config_core.masc_host () in
           let port = state.port in
           start_http_refresh state ~host ~port
             ~refresh_inflight:http_refresh_inflight ~mailbox:async_messages;
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
                     start_board_post_refresh state ~host ~port ~post_id
                       ~refresh_inflight:board_post_refresh_inflight
                       ~mailbox:async_messages
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
            | Approvals -> ());
           add_event state "system" "Manual refresh"
       | Some "\t" ->
           (* Tab cycles through primary surfaces *)
           (match state.view with
            | Overview -> state.view <- Keepers Keeper_list
            | Keepers _ -> state.view <- Approvals
            | Approvals -> state.view <- Board
            | Board -> state.view <- Planning
            | Planning -> state.view <- Overview)
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
            | Overview | Keepers Keeper_list | Approvals -> ())
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
                     let goals =
                       match state.planning with
                       | None -> []
                       | Some p -> planning_visible_goals p.pl_goals
                     in
                     if state.planning_cursor < List.length goals - 1 then
                       state.planning_cursor <- state.planning_cursor + 1
                 | Planning_detail _ ->
                     state.planning_scroll <- state.planning_scroll + 1)
            | Overview | Keepers Keeper_message -> ())
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
            | Overview | Keepers Keeper_message -> ())
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
                          state.board_mode <- Board_read p.bp_id;
                          state.board_scroll <- 0;
                          start_board_post_refresh state ~host ~port
                            ~post_id:p.bp_id
                            ~refresh_inflight:board_post_refresh_inflight
                            ~mailbox:async_messages
                      | None -> ())
                 | Board_read _ -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_list ->
                     let goals =
                       match state.planning with
                       | None -> []
                       | Some p -> planning_visible_goals p.pl_goals
                     in
                     (match List.nth_opt goals state.planning_cursor with
                      | Some g ->
                          state.planning_mode <- Planning_detail g.pg_id;
                          state.planning_scroll <- 0
                      | None -> ())
                 | Planning_detail _ -> ())
            | Overview | Keepers Keeper_detail | Keepers Keeper_logs | Keepers Keeper_message
            | Approvals -> ())
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
            | Board | Approvals | Planning -> ())
       | Some "m" | Some "M" ->
           (* M opens message view from detail *)
           (match state.view with
            | Keepers Keeper_detail when state.keeper_cursor < List.length state.keepers ->
                Buffer.clear state.msg_input;
                state.view <- Keepers Keeper_message
            | Keepers Keeper_detail | Overview | Keepers Keeper_list | Keepers Keeper_logs | Keepers Keeper_message
            | Board | Approvals | Planning -> ())
      | _ -> ());

      Eio.Fiber.yield ();
      drain_async_messages state ~http_refresh_inflight
        ~board_post_refresh_inflight ~approval_action_inflight async_messages;

      (* Periodic refresh *)
      let now = Unix.gettimeofday () in
      if now -. !last_check >= refresh then begin
        state.pending_approval_action <- None;
        load_from_masc_dir state base_path;
        let host = Env_config_core.masc_host () in
        let port = state.port in
        start_http_refresh state ~host ~port
          ~refresh_inflight:http_refresh_inflight ~mailbox:async_messages;
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
                  start_board_post_refresh state ~host ~port ~post_id
                    ~refresh_inflight:board_post_refresh_inflight
                    ~mailbox:async_messages
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
         | Approvals -> ());
        last_check := now
      end;

      (* Render *)
      render state
    done
  with Break -> ()

let run_with_eio_context f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Eio_guard.enable ();
  Eio.Switch.on_release sw Eio_guard.disable;
  Eio_context.set_env env;
  Eio_context.set_switch sw;
  Eio_context.set_net (Eio.Stdenv.net env);
  Eio_context.set_clock (Eio.Stdenv.clock env);
  Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
  f ()

let () = run_with_eio_context main
