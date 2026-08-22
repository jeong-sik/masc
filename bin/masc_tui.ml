open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render
open Masc_tui_loader

module Approval = Masc_tui_operator_projection
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_recovery = Masc_tui_keeper_chat_recovery

(** Local exception for breaking the main TUI loop without using Exit. *)
exception Break

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

(** One byte of pushback keeps an invalid UTF-8 continuation from swallowing
    the next independent ASCII key. *)
type input_reader = { mutable pending_byte : char option }

let create_input_reader () = { pending_byte = None }

let take_input_byte reader ~timeout =
  match reader.pending_byte with
  | Some byte ->
      reader.pending_byte <- None;
      Some byte
  | None -> read_byte_unix ~timeout ()

let is_utf8_continuation byte =
  let code = Char.code byte in
  code >= 0x80 && code <= 0xBF

let read_utf8_scalar reader first expected_length =
  let bytes = Bytes.create expected_length in
  Bytes.set bytes 0 first;
  let rec fill index =
    if index >= expected_length then
      let scalar = Bytes.to_string bytes in
      if String.is_valid_utf_8 scalar then Some scalar else Some "invalid-utf8"
    else
      match take_input_byte reader ~timeout:0.05 with
      | None -> Some "invalid-utf8"
      | Some byte when is_utf8_continuation byte ->
          Bytes.set bytes index byte;
          fill (index + 1)
      | Some byte ->
          reader.pending_byte <- Some byte;
          Some "invalid-utf8"
  in
  fill 1

(** Try to read an escape sequence. Returns a key description. *)
let read_key reader () : string option =
  Eio_guard.run_in_systhread (fun () ->
      match take_input_byte reader ~timeout:0.1 with
      | None -> None
      | Some '\027' -> (
          (* Escape sequence: try to read [ and then the code. *)
          match take_input_byte reader ~timeout:0.05 with
          | Some '[' -> (
              match take_input_byte reader ~timeout:0.05 with
              | Some 'A' -> Some "up"
              | Some 'B' -> Some "down"
              | Some 'Z' -> Some "shift-tab"
              | Some _ -> Some "unknown-esc"
              | None -> Some "esc")
          | Some _ | None -> Some "esc")
      | Some byte -> (
          match Masc_tui_message_layout.utf8_scalar_byte_length byte with
          | Some 1 -> Some (String.make 1 byte)
          | Some expected_length -> read_utf8_scalar reader byte expected_length
          | None -> Some "invalid-utf8"))

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

let save_message_draft state =
  match state.msg_target_keeper_name with
  | None -> ()
  | Some keeper_name ->
      let other_drafts =
        List.filter
          (fun (name, _) -> not (String.equal name keeper_name))
          state.msg_drafts
      in
      let text = Buffer.contents state.msg_input in
      state.msg_drafts <-
        if String.equal text "" then other_drafts
        else (keeper_name, text) :: other_drafts

let open_message_for_keeper state keeper_name =
  save_message_draft state;
  state.msg_target_keeper_name <- Some keeper_name;
  Buffer.clear state.msg_input;
  List.assoc_opt keeper_name state.msg_drafts
  |> Option.iter (Buffer.add_string state.msg_input)

let clear_current_message_draft state =
  Buffer.clear state.msg_input;
  save_message_draft state

(** Handle local editing keys for message mode. Network submission is injected
    so the input path never owns a blocking HTTP effect. *)
let handle_message_key (state : state) ~(submit_message : string -> unit)
    ~(retry_message : unit -> unit) (key : string) : bool =
  match key with
  | "esc" ->
    save_message_draft state;
    state.view <- Keepers Keeper_detail;
    state.detail_scroll <- 0;
    true
  | "\r" | "\n" ->
    let text = Buffer.contents state.msg_input in
    if String.trim text <> "" then submit_message text;
    true
  | "\127" | "\b" ->
    let new_content =
      Buffer.contents state.msg_input
      |> Masc_tui_message_layout.drop_last_utf8_scalar
    in
    Buffer.clear state.msg_input;
    Buffer.add_string state.msg_input new_content;
    true
  | s ->
    let c = if String.length s = 1 then Some (Char.code s.[0]) else None in
    if c = Some 18 then begin
      (* Ctrl-R: reconnect using the exact unverified request identity. *)
      retry_message ();
      true
    end else if c = Some 21 then begin
      (* Ctrl-U: clear line *)
      Buffer.clear state.msg_input;
      true
    end else if Masc_tui_message_layout.is_printable_utf8_scalar s then begin
      Buffer.add_string state.msg_input s;
      true
    end else
      true  (* Consume but ignore other control chars *)

let keeper_message_input_supported state =
  let rows, cols = get_terminal_size () in
  Masc_tui_message_layout.message_viewport_supported ~terminal_rows:rows
    ~terminal_cols:cols ~status_rows:(keeper_message_status_rows state)

let approval_decision_key = function
  | Confirm -> "y"
  | Deny -> "n"

let approval_decision_done = function
  | Confirm -> "Confirmed"
  | Deny -> "Denied"

let approval_decision_unverified = function
  | Confirm -> "Confirmation outcome unverified"
  | Deny -> "Denial outcome unverified"

type approval_observation = {
  ao_generation: Approval.Flow.generation;
  ao_result: (approval_snapshot, string) result;
}

type http_surface_results = {
  http_overview: (overview_snapshot, string) result;
  http_approvals: approval_observation option;
  http_board: (board_post list, string) result;
  http_planning: (planning_snapshot, string) result;
}

type async_msg =
  | Http_refresh_done of http_surface_results
  | Http_refresh_failed of string * Approval.Flow.generation option
  | Board_post_refresh_done of string * (board_post * board_comment list, string) result
  | Board_post_refresh_failed of string * string
  | Approval_decision_done of
      approval_item
      * approval_decision
      * (Approval.confirm_outcome, string) result
      * approval_observation
  | Keeper_chat_done of
      Keeper_chat.request * (Keeper_chat.response, Keeper_chat.error) result
  | Keeper_chat_reconciled of
      Keeper_chat.request
      * (Keeper_chat.operation_reconciliation, Keeper_chat.error) result

let enqueue_async mailbox msg = Eio.Stream.add mailbox msg

let current_clock_text () =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
    now.Unix.tm_sec

let append_chat_history state request role text =
  let text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text in
  state.msg_history <-
    state.msg_history
    @ [ {
          me_role = role;
          me_text = text;
          me_timestamp = current_clock_text ();
          me_keeper_name = request.Keeper_chat.keeper_name;
          me_request_id = request.request_id;
        } ]

let launch_keeper_request state ~mailbox request =
  state.msg_inflight <- Some request;
  let run () =
    let result =
      try
        Masc_tui_http.post_keeper_chat
          ~host:(Env_config_core.masc_host ()) ~port:state.port request
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Keeper_chat.Transport_error (Printexc.to_string exn))
    in
    enqueue_async mailbox (Keeper_chat_done (request, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_done
           ( request
           , Error
               (Keeper_chat.Transport_error "Eio switch is unavailable") ))

let start_keeper_message state ~base_path ~mailbox text =
  match state.msg_recovery_error with
  | Some detail ->
      add_event state "error"
        ("Cannot send while Keeper chat recovery is invalid: " ^ detail)
  | None ->
  match state.msg_inflight with
  | Some request ->
      add_event state "system"
        (Printf.sprintf "Keeper message already in progress: %s"
           request.request_id)
  | None -> (
      match state.msg_unverified with
      | Some request ->
          add_event state "error"
            (Printf.sprintf
               "Keeper request %s has an unverified outcome; use Ctrl-R to reconnect with the same request ID"
               request.request_id)
      | None ->
      match state.msg_target_keeper_name with
      | None -> add_event state "error" "Cannot send: no Keeper is selected"
      | Some keeper_name
        when not
               (List.exists
                  (fun (keeper : keeper) ->
                    String.equal keeper.k_name keeper_name)
                  state.keepers) ->
          add_event state "error"
            (Printf.sprintf "Cannot send: Keeper %s is no longer registered"
               (Keeper_chat.terminal_safe_text keeper_name))
      | Some keeper_name ->
          let request =
            Keeper_chat.create_request ~keeper_name ~message:text
          in
          (match Keeper_chat_recovery.persist_pending ~base_path request with
           | Error detail ->
               state.msg_recovery_error <- Some detail;
               add_event state "error"
                 ("Keeper message was not sent because its recovery fence could not be persisted: "
                ^ detail)
           | Ok () ->
               append_chat_history state request Message_user text;
               clear_current_message_draft state;
               add_event state "message"
                 (Printf.sprintf "Keeper message durably fenced: %s"
                    request.request_id);
               launch_keeper_request state ~mailbox request))

let launch_keeper_reconciliation state ~mailbox request =
  state.msg_inflight <- Some request;
  let run clock =
    let rec poll remaining =
      let result =
        try
          Masc_tui_http.fetch_keeper_chat_operation
            ~host:(Env_config_core.masc_host ()) ~port:state.port request
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Keeper_chat.Transport_error (Printexc.to_string exn))
      in
      match result with
      | Ok (Keeper_chat.Operation_pending _ as pending) ->
          (match Keeper_chat_recovery.next_reconciliation_poll ~remaining with
           | `Poll remaining ->
               Eio.Time.sleep clock 1.5;
               poll remaining
           | `Stop ->
               enqueue_async mailbox
                 (Keeper_chat_reconciled (request, Ok pending)))
      | Error (Keeper_chat.Http_error { status = 404; _ })
        as not_found ->
          (match Keeper_chat_recovery.next_reconciliation_poll ~remaining with
           | `Poll remaining ->
               Eio.Time.sleep clock 1.5;
               poll remaining
           | `Stop ->
               enqueue_async mailbox
                 (Keeper_chat_reconciled (request, not_found)))
      | (Ok
          (Keeper_chat.Operation_succeeded _ | Keeper_chat.Operation_failed _
          | Keeper_chat.Operation_cancelled)
        | Error _) as settled ->
          enqueue_async mailbox (Keeper_chat_reconciled (request, settled))
    in
    poll Keeper_chat_recovery.max_reconciliation_polls
  in
  match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
  | Some sw, Some clock ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run clock;
          `Stop_daemon)
  | Some _, None | None, Some _ | None, None ->
      enqueue_async mailbox
        (Keeper_chat_reconciled
           ( request
           , Error
               (Keeper_chat.Transport_error
                  "Eio switch or clock is unavailable") ))

let retry_keeper_message state ~mailbox =
  match state.msg_inflight, state.msg_unverified with
  | Some request, _ ->
      add_event state "system"
        (Printf.sprintf "Keeper message already in progress: %s"
           request.request_id)
  | None, None ->
      add_event state "system" "No unverified Keeper request to reconnect"
  | None, Some request ->
      add_event state "message"
        (Printf.sprintf "Reconciling Keeper request by exact ID: %s"
           request.request_id);
      launch_keeper_reconciliation state ~mailbox request

let chat_status_text completed =
  let turn_ref = completed.Keeper_chat.turn_ref in
  match completed.turn_outcome with
  | Keeper_chat.Visible_reply when String.trim completed.reply <> "" ->
      completed.reply
  | Keeper_chat.Visible_reply ->
      Printf.sprintf "Turn completed with non-text visible content (turn %s)"
        turn_ref
  | Keeper_chat.Continuation_checkpoint ->
      Printf.sprintf "Continuation checkpoint recorded (turn %s)" turn_ref
  | Keeper_chat.External_effect_completed ->
      Printf.sprintf "External effect completed (turn %s)" turn_ref
  | Keeper_chat.External_effect_pending ->
      Printf.sprintf "External effect remains pending (turn %s)" turn_ref
  | Keeper_chat.No_visible_reply ->
      Printf.sprintf "Turn completed without a visible reply (turn %s)" turn_ref

let clear_keeper_chat_recovery state ~base_path request =
  match Keeper_chat_recovery.clear_pending ~base_path request with
  | Ok () -> state.msg_recovery_error <- None
  | Error detail ->
      state.msg_recovery_error <- Some detail;
      add_event state "error"
        ("Keeper chat settled, but its recovery fence could not be cleared: "
       ^ detail)

let apply_keeper_chat_result state ~base_path request result =
  match state.msg_inflight with
  | Some current when Keeper_chat.same_request_identity current request ->
      let reconnecting_unverified =
        match state.msg_unverified with
        | Some pending -> Keeper_chat.same_request_identity pending request
        | None -> false
      in
      state.msg_inflight <- None;
      (match result with
       | Ok (Keeper_chat.Turn_completed completed) ->
           state.msg_unverified <- None;
           clear_keeper_chat_recovery state ~base_path request;
           let role =
             match completed.turn_outcome with
             | Keeper_chat.Visible_reply
               when String.trim completed.reply <> "" ->
                 Message_keeper
             | Keeper_chat.Visible_reply
             | Keeper_chat.Continuation_checkpoint
             | Keeper_chat.External_effect_completed
             | Keeper_chat.External_effect_pending
             | Keeper_chat.No_visible_reply -> Message_status
           in
           append_chat_history state request role (chat_status_text completed);
           add_event state "message"
             (Printf.sprintf "Keeper turn finished: %s" request.request_id)
       | Ok (Keeper_chat.Replayed_succeeded _) ->
           state.msg_unverified <- None;
           clear_keeper_chat_recovery state ~base_path request;
           append_chat_history state request Message_status
             "Request was already completed; canonical reply is not present in this replay stream";
           add_event state "message"
             (Printf.sprintf "Keeper request already completed: %s"
                request.request_id)
       | Error error ->
           let certainty =
             Keeper_chat.error_certainty
               ~was_unverified:reconnecting_unverified error
           in
           let detail =
             Keeper_chat.error_to_string error
             |> Keeper_chat.terminal_safe_text
           in
           let detail =
             match certainty with
             | Keeper_chat.Verified_rejected | Keeper_chat.Verified_failed ->
                 state.msg_unverified <- None;
                 clear_keeper_chat_recovery state ~base_path request;
                 detail
             | Keeper_chat.Outcome_unverified ->
                 state.msg_unverified <- Some request;
                 Printf.sprintf
                   "Outcome unverified for %s; the operation may still execute. Do not resend with a new ID; use Ctrl-R to reconnect. %s"
                   request.request_id detail
           in
           append_chat_history state request Message_error detail;
           add_event state "error"
             (Printf.sprintf "Keeper message %s: %s" request.request_id detail));
      true
  | Some _ | None -> false

let apply_keeper_chat_reconciliation state ~base_path request result =
  match state.msg_inflight with
  | Some current when Keeper_chat.same_request_identity current request ->
      state.msg_inflight <- None;
      (match result with
       | Ok (Keeper_chat.Operation_succeeded { outcome_ref }) ->
           state.msg_unverified <- None;
           clear_keeper_chat_recovery state ~base_path request;
           append_chat_history state request Message_status
             (Printf.sprintf
                "Operation settled successfully (%s); canonical reply is unavailable after transport recovery"
                outcome_ref);
           add_event state "message"
             (Printf.sprintf "Keeper operation reconciled: %s"
                request.request_id)
       | Ok
           (Keeper_chat.Operation_failed
             { failure_kind; detail; outcome_ref }) ->
           state.msg_unverified <- None;
           clear_keeper_chat_recovery state ~base_path request;
           let outcome =
             match outcome_ref with
             | None -> ""
             | Some value -> "; outcome " ^ value
           in
           let detail =
             Printf.sprintf "Operation failed (%s%s): %s" failure_kind outcome
               detail
           in
           append_chat_history state request Message_error detail;
           add_event state "error"
             (Printf.sprintf "Keeper operation failed: %s" request.request_id)
       | Ok Keeper_chat.Operation_cancelled ->
           state.msg_unverified <- None;
           clear_keeper_chat_recovery state ~base_path request;
           append_chat_history state request Message_status
             "Operation was cancelled";
           add_event state "message"
             (Printf.sprintf "Keeper operation cancelled: %s"
                request.request_id)
       | Ok (Keeper_chat.Operation_pending state_value) ->
           state.msg_unverified <- Some request;
           append_chat_history state request Message_error
             (Printf.sprintf
                "Operation reconciliation stopped while still %s; outcome remains unverified"
                (match state_value with
                 | Keeper_chat.Queued -> "queued"
                 | Keeper_chat.Running -> "running"
                 | Keeper_chat.Succeeded | Keeper_chat.Failed
                 | Keeper_chat.Cancelled -> "in an unexpected terminal state"))
       | Error error ->
           state.msg_unverified <- Some request;
           let detail =
             Keeper_chat.error_to_string error
             |> Keeper_chat.terminal_safe_text
           in
           append_chat_history state request Message_error
             ("Operation reconciliation failed; outcome remains unverified. "
            ^ detail);
           add_event state "error"
             (Printf.sprintf "Keeper operation reconciliation failed: %s"
                request.request_id));
      true
  | Some _ | None -> false

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

let apply_approvals_load state = function
  | Ok snapshot ->
      let approval_cursor =
        Approval.reconcile_cursor ~current_items:(approval_items state)
          ~cursor:state.approval_cursor ~next_items:snapshot.aps_items
      in
      state.approval_snapshot <- Some snapshot;
      state.approvals_error <- None;
      state.approval_cursor <- approval_cursor;
      (match state.pending_approval_action with
       | Some pending
         when not
                (List.exists
                   (fun item -> String.equal item.ap_token pending.paa_token)
                   snapshot.aps_items) ->
           state.pending_approval_action <- None
       | Some _ | None -> ())
  | Error err ->
      state.approval_snapshot <- None;
      state.approval_cursor <- 0;
      state.pending_approval_action <- None;
      remember_surface_error state ~surface:"approvals"
        ~current_error:state.approvals_error
        ~set_error:(fun value -> state.approvals_error <- value)
        err

let apply_approval_observation state observation =
  if Approval.Flow.is_current state.approval_flow observation.ao_generation then
    apply_approvals_load state observation.ao_result

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
  | 0, _ -> Masc_tui_types.Disconnected
  | n, total when n = total -> Masc_tui_types.Connected
  | _ -> Masc_tui_types.Degraded

let load_http_surfaces ~host ~port ~approval_generation =
  let http_overview = load_overview ~host ~port in
  let http_approvals =
    Option.map
      (fun ao_generation ->
         { ao_generation; ao_result = load_approvals ~host ~port })
      approval_generation
  in
  let http_board = load_board_list ~host ~port in
  let http_planning = load_planning ~host ~port in
  { http_overview; http_approvals; http_board; http_planning }

let apply_http_surfaces state results =
  apply_overview_load state results.http_overview;
  Option.iter (apply_approval_observation state) results.http_approvals;
  apply_board_list_load state results.http_board;
  apply_planning_load state results.http_planning;
  let approval_status =
    Option.map
      (fun observation ->
         Result.map (fun _ -> ()) observation.ao_result
         |> Result.map_error (fun _ -> ()))
      results.http_approvals
    |> Option.to_list
  in
  state.connection_status <-
    refresh_status
      (
      [
        Result.map (fun _ -> ()) results.http_overview
        |> Result.map_error (fun _ -> ());
        Result.map (fun _ -> ()) results.http_board
        |> Result.map_error (fun _ -> ());
        Result.map (fun _ -> ()) results.http_planning
        |> Result.map_error (fun _ -> ());
      ] @ approval_status)

let start_http_refresh state ~host ~port ~refresh_inflight ~mailbox =
  if not !refresh_inflight then begin
    refresh_inflight := true;
    let flow, approval_generation =
      Approval.Flow.reserve_refresh state.approval_flow
    in
    state.approval_flow <- flow;
    state.connection_status <-
      (match state.connection_status with
       | Connected | Degraded -> Masc_tui_types.Reconnecting
       | Disconnected | Connecting | Reconnecting -> Masc_tui_types.Connecting);
    let run_refresh () =
      try
        enqueue_async mailbox
          (Http_refresh_done
             (load_http_surfaces ~host ~port ~approval_generation))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        enqueue_async mailbox
          (Http_refresh_failed
             ( Printf.sprintf "HTTP refresh failed: %s" (Printexc.to_string exn)
             , approval_generation ))
    in
    match Eio_context.get_switch_opt () with
    | Some sw ->
        Eio.Fiber.fork ~sw run_refresh
    | None ->
        Fun.protect
          ~finally:(fun () -> refresh_inflight := false)
          (fun () ->
             apply_http_surfaces state
               (load_http_surfaces ~host ~port ~approval_generation))
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

let apply_approval_decision_result state approval decision approvals result =
  (match result with
   | Ok (Approval.Completed _) ->
       add_event state "system"
         (Printf.sprintf "%s: %s" (approval_decision_done decision)
            approval.ap_summary)
   | Ok (Approval.Deferred _) ->
       add_event state "system"
         (Printf.sprintf "Confirmation accepted; action deferred: %s"
            approval.ap_summary)
   | Ok (Approval.Execution_failed (_, detail)) ->
       add_event state "error"
         (Printf.sprintf "Confirmation accepted; action failed: %s" detail)
   | Error err ->
       add_event state "error"
         (Printf.sprintf "%s: %s" (approval_decision_unverified decision) err));
  apply_approvals_load state approvals

let apply_approval_decision_completion state generation approval decision result
    approvals =
  state.pending_approval_action <- None;
  let flow, owns_action =
    Approval.Flow.finish_action state.approval_flow generation
  in
  state.approval_flow <- flow;
  if owns_action then
    apply_approval_decision_result state approval decision approvals result

let start_approval_decision state approval decision ~mailbox =
  match Approval.Flow.begin_action state.approval_flow with
  | Error `Already_inflight ->
      state.pending_approval_action <- None;
      add_event state "system" "Approval action already in progress"
  | Ok (flow, generation) ->
    let () = state.approval_flow <- flow in
    let () = state.pending_approval_action <- None in
    let host = Env_config_core.masc_host () in
    let port = state.port in
    let run_action () =
      let result =
        try
          Masc_tui_http.post_operator_confirm ~host ~port
            ~token:approval.ap_token ~decision
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn)
      in
      let approvals =
        try load_approvals ~host ~port with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error ("approvals reload failed: " ^ Printexc.to_string exn)
      in
      let approvals = { ao_generation = generation; ao_result = approvals } in
      enqueue_async mailbox
        (Approval_decision_done (approval, decision, result, approvals))
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> Eio.Fiber.fork ~sw run_action
    | None ->
        let result =
          try
            Masc_tui_http.post_operator_confirm ~host ~port
              ~token:approval.ap_token ~decision
          with exn -> Error (Printexc.to_string exn)
        in
        let approvals =
          try load_approvals ~host ~port with
          | exn -> Error ("approvals reload failed: " ^ Printexc.to_string exn)
        in
        apply_approval_decision_completion state generation approval decision
          result approvals

(* TEL-OK: TUI-local confirmation gate emits user-visible events here; the
   operator confirmation endpoint owns durable approval telemetry. *)
let handle_approval_decision state approval decision ~mailbox =
  match
    Approval.approval_gate_transition
      ~inflight:(Approval.Flow.action_inflight state.approval_flow)
      ~pending:state.pending_approval_action ~token:approval.ap_token ~decision
  with
  | Approval.Gate_blocked_inflight ->
      state.pending_approval_action <- None;
      add_event state "system" "Approval action already in progress"
  | Approval.Gate_submit ->
      start_approval_decision state approval decision ~mailbox
  | Approval.Gate_arm pending ->
      state.pending_approval_action <- Some pending;
      add_event state "system"
        (Printf.sprintf "Press %s again: %s"
           (approval_decision_key decision)
           approval.ap_summary)

let apply_async_message state ~base_path ~http_refresh_inflight
    ~board_post_refresh_inflight = function
  | Http_refresh_done results ->
      http_refresh_inflight := false;
      apply_http_surfaces state results
  | Http_refresh_failed (err, approval_generation) ->
      http_refresh_inflight := false;
      Option.iter
        (fun ao_generation ->
           apply_approval_observation state
             { ao_generation; ao_result = Error err })
        approval_generation;
      state.connection_status <- Masc_tui_types.Disconnected;
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
  | Approval_decision_done (approval, decision, result, approvals) ->
      apply_approval_decision_completion state approvals.ao_generation approval
        decision result approvals.ao_result
  | Keeper_chat_done (request, result) ->
      if apply_keeper_chat_result state ~base_path request result then
        load_from_masc_dir state base_path
  | Keeper_chat_reconciled (request, result) ->
      if apply_keeper_chat_reconciliation state ~base_path request result then
        load_from_masc_dir state base_path

let drain_async_messages state ~base_path ~http_refresh_inflight
    ~board_post_refresh_inflight mailbox =
  let rec loop () =
    match Eio.Stream.take_nonblocking mailbox with
    | None -> ()
    | Some msg ->
        apply_async_message state ~base_path ~http_refresh_inflight
          ~board_post_refresh_inflight msg;
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
  let async_messages = Eio.Stream.create 32 in
  (match Keeper_chat_recovery.load_pending ~base_path with
   | Ok None -> ()
   | Error detail ->
       state.msg_recovery_error <- Some detail;
       add_event state "error"
         ("Keeper chat recovery is invalid; new sends are blocked: " ^ detail)
   | Ok (Some request) ->
       state.msg_unverified <- Some request;
       append_chat_history state request Message_status
         "Recovered an unsettled request; reconciling the exact durable operation";
       add_event state "message"
         (Printf.sprintf "Recovered Keeper request: %s" request.request_id);
       launch_keeper_reconciliation state ~mailbox:async_messages request);
  start_http_refresh state ~host ~port ~refresh_inflight:http_refresh_inflight
    ~mailbox:async_messages;
  add_event state "system" "TUI started";

  (* Main loop *)
  let last_check = ref (Unix.gettimeofday ()) in
  let input_reader = create_input_reader () in
  try
    while true do
      drain_async_messages state ~base_path ~http_refresh_inflight
        ~board_post_refresh_inflight async_messages;
      (* Check for input *)
      let key = read_key input_reader () in
      (match state.view, key with
       | Approvals, Some ("y" | "Y" | "n" | "N") -> ()
       | Approvals, Some _ -> state.pending_approval_action <- None
       | _ -> ());
      (match key with
       | Some k when state.view = Keepers Keeper_message ->
           if keeper_message_input_supported state || String.equal k "esc" then
             let _handled =
               handle_message_key state
                 ~submit_message:
                   (start_keeper_message state ~base_path
                      ~mailbox:async_messages)
                 ~retry_message:(fun () ->
                   retry_keeper_message state ~mailbox:async_messages)
                 k
             in
             ()
       | Some "q" | Some "Q" -> raise Break
       | Some "y" | Some "Y" ->
           (match state.view with
            | Approvals ->
                (match List.nth_opt (approval_items state) state.approval_cursor with
                 | Some a ->
                     handle_approval_decision state a Confirm
                       ~mailbox:async_messages
                 | None -> ())
            | _ -> ())
       | Some "n" | Some "N" ->
           (match state.view with
            | Approvals ->
                (match List.nth_opt (approval_items state) state.approval_cursor with
                 | Some a ->
                     handle_approval_decision state a Deny
                       ~mailbox:async_messages
                 | None -> ())
            | _ -> ())
       | Some "r" | Some "R" ->
           state.pending_approval_action <- None;
           load_from_masc_dir state base_path;
           let host = Env_config_core.masc_host () in
           let port = state.port in
           start_http_refresh state ~host ~port
             ~refresh_inflight:http_refresh_inflight
             ~mailbox:async_messages;
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
            | Approvals ->
                state.pending_approval_action <- None;
                state.view <- Board
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
                let count = List.length (approval_items state) in
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
                let keeper = List.nth state.keepers state.keeper_cursor in
                open_message_for_keeper state keeper.k_name;
                state.view <- Keepers Keeper_message
            | Keepers Keeper_detail | Overview | Keepers Keeper_list | Keepers Keeper_logs | Keepers Keeper_message
            | Board | Approvals | Planning -> ())
      | _ -> ());

      Eio.Fiber.yield ();
      drain_async_messages state ~base_path ~http_refresh_inflight
        ~board_post_refresh_inflight async_messages;

      (* Periodic refresh *)
      let now = Unix.gettimeofday () in
      if now -. !last_check >= refresh then begin
        state.pending_approval_action <- None;
        load_from_masc_dir state base_path;
        let host = Env_config_core.masc_host () in
        let port = state.port in
        start_http_refresh state ~host ~port
          ~refresh_inflight:http_refresh_inflight
          ~mailbox:async_messages;
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
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_context.set_env env;
  Eio_context.set_switch sw;
  Eio_context.set_net (Eio.Stdenv.net env);
  Eio_context.set_clock (Eio.Stdenv.clock env);
  Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
  f ()

let () = run_with_eio_context main
