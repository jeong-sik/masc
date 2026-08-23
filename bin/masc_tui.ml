open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render
open Masc_tui_loader

module Approval = Masc_tui_operator_projection
module Board_detail = Masc_tui_board_detail
module Board_selection = Masc_tui_board_selection
module Frame_presenter = Masc_tui_frame_presenter
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_history = Masc_tui_keeper_chat_history
module Chat_queue = Masc_tui_keeper_chat_queue
module Keeper_chat_live = Masc_tui_keeper_chat_live
module Keeper_chat_recovery = Masc_tui_keeper_chat_recovery
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Composer = Masc_tui_composer
module Keeper_control = Masc_tui_keeper_control
module Metrics_tail = Masc_tui_metrics_tail
module Planning_selection = Masc_tui_planning_selection
module Render_schedule = Masc_tui_render_schedule
module Terminal_write_repair = Masc_tui_terminal_write_repair

(** Local exception for breaking the main TUI loop without using Exit. *)
exception Break

(** One 60 Hz frame window: bursts are coalesced without delaying an idle
    terminal's first changed frame. *)
let frame_interval_ns = 16_000_000L
let maximum_input_wait_seconds = 0.016
let nanoseconds_per_second = 1_000_000_000.0

let synchronized_output_enabled () =
  match Sys.getenv_opt "MASC_TUI_SYNC" with
  | Some value ->
      (match String.lowercase_ascii (String.trim value) with
       | "0" | "false" | "no" | "off" -> false
       | "" | "1" | "true" | "yes" | "on" | _ -> true)
  | None -> true

let require_interactive_terminal () =
  let term =
    Sys.getenv_opt "TERM"
    |> Option.value ~default:""
    |> String.lowercase_ascii
    |> String.trim
  in
  if
    (not (Unix.isatty Unix.stdin))
    || not (Unix.isatty Unix.stdout)
    || String.equal term "dumb"
  then begin
    prerr_endline
      "masc-tui requires interactive TTY stdin/stdout and TERM other than dumb";
    exit 2
  end

let keeper_log_content_height (state : state) =
  let rows, _columns = get_terminal_size () in
  Metrics_tail.content_height ~terminal_rows:rows ~error:state.log_error

(** Read a single byte from stdin, returning Some char or None. *)
let read_byte_unix ?(timeout = 0.1) () : char option =
  let timeout_ns =
    Int64.of_float (max 0.0 timeout *. nanoseconds_per_second)
  in
  let poll remaining =
    match Unix.select [Unix.stdin] [] [] remaining with
    | ready, _, _ when ready <> [] ->
        let buf = Bytes.create 1 in
        (match Unix.read Unix.stdin buf 0 1 with
         | n when n > 0 -> Render_schedule.Input_wait.Ready (Bytes.get buf 0)
         | _ -> Render_schedule.Input_wait.Timed_out
         | exception Unix.Unix_error (Unix.EINTR, _, _) ->
             Render_schedule.Input_wait.Interrupted)
    | _ -> Render_schedule.Input_wait.Timed_out
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
        Render_schedule.Input_wait.Interrupted
  in
  Render_schedule.Input_wait.await ~now_ns:Mtime_clock.elapsed_ns ~timeout_ns
    ~poll

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
let read_key ?(timeout = 0.1) reader () : string option =
  Eio_guard.run_in_systhread (fun () ->
      match take_input_byte reader ~timeout with
      | None -> None
      | Some '\027' -> (
          (* CSI: parameter bytes, then one final byte in 0x40-0x7E. Reading to
             the final byte is what keeps a parameterised key from leaving its
             tail in the stream -- Page Up is ESC [ 5 ~, and stopping at the 5
             left the ~ to be typed as text. *)
          match take_input_byte reader ~timeout:0.05 with
          | Some '[' ->
              let parameters = Buffer.create 4 in
              let rec read_csi () =
                match take_input_byte reader ~timeout:0.05 with
                | None -> None
                | Some byte when Char.code byte >= 0x40 && Char.code byte <= 0x7E
                  -> Some (Buffer.contents parameters, byte)
                | Some byte ->
                    Buffer.add_char parameters byte;
                    if Buffer.length parameters > 16 then None else read_csi ()
              in
              (match read_csi () with
               | None -> Some "esc"
               | Some ("", 'A') -> Some "up"
               | Some ("", 'B') -> Some "down"
               | Some ("", 'H') -> Some "home"
               | Some ("", 'F') -> Some "end"
               | Some ("", 'Z') -> Some "shift-tab"
               | Some ("1", '~') -> Some "home"
               | Some ("4", '~') -> Some "end"
               | Some ("5", '~') -> Some "pageup"
               | Some ("6", '~') -> Some "pagedown"
               | Some (_, _) -> Some "unknown-esc")
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

let consume_dispatched_message_draft state request =
  state.msg_drafts <-
    List.filter
      (fun (keeper_name, text) ->
        not
          (String.equal keeper_name request.Keeper_chat.keeper_name
           && String.equal text request.message))
      state.msg_drafts;
  match state.msg_target_keeper_name with
  | Some keeper_name
    when String.equal keeper_name request.Keeper_chat.keeper_name
         && String.equal (Buffer.contents state.msg_input) request.message ->
      clear_current_message_draft state
  | Some _ | None -> save_message_draft state

(** Handle local editing keys for message mode. Network submission is injected
    so the input path never owns a blocking HTTP effect. *)
(* One page of the transcript. Measured from the terminal rather than fixed,
   so the jump is a screenful on every window; a page smaller than the pane
   would leave rows the reader has to catch with the arrow keys anyway. *)
let keeper_message_page_rows state =
  let rows, _cols = get_terminal_size () in
  let chrome = Masc_tui_message_layout.composer_max_rows + 6 in
  max 1 (rows - chrome - keeper_message_status_rows state)

let handle_message_key (state : state) ~(submit_message : string -> unit)
    ~(retry_message : unit -> unit)
    ~(answer_approval : tool_call_id:string -> allow:bool -> unit)
    ~(load_older : before:float -> unit) (key : string) : bool =
  (* y and n answer a held call, and only while one is held -- otherwise they
     are letters someone is typing. The prompt on screen is what makes them
     mean anything, so it is also what decides whether they are taken. *)
  match state.msg_live, key with
  | Some live, ("y" | "Y" | "n" | "N")
    when Option.is_some (Keeper_chat_transcript.awaiting_approval live) -> (
      match Keeper_chat_transcript.awaiting_approval live with
      | Some awaiting ->
          answer_approval ~tool_call_id:awaiting.Keeper_chat_transcript.call_id
            ~allow:(String.lowercase_ascii key = "y");
          true
      | None -> true)
  | _ ->
  match key with
  | "esc" ->
    save_message_draft state;
    let target_registered =
      match state.msg_target_keeper_name with
      | Some keeper_name ->
          keeper_available_for_new_message state keeper_name
      | None -> false
    in
    state.view <-
      Keepers (if target_registered then Keeper_detail else Keeper_list);
    state.detail_scroll <- 0;
    if not target_registered then state.log_scroll <- 0;
    true
  | "\r" ->
    let text = Buffer.contents state.msg_input in
    if String.trim text <> "" then begin
      (* Back to the newest row: the turn that is about to start is drawn
         there, and staying scrolled back would hide the send. *)
      state.msg_scroll <- 0;
      submit_message text
    end;
    true
  | "\n" ->
    (* Ctrl-J, or Return on a terminal that still translates it. A composer
       that cannot hold two lines makes an operator send two messages for one
       thought. *)
    Buffer.add_char state.msg_input '\n';
    true
  | "up" ->
    state.msg_scroll <- state.msg_scroll + 1;
    (* Scrolling into the oldest rows is the ask for older ones. Fetching on
       the keypress rather than on reaching an exact row means the page is
       usually there before the reader arrives; the render clamps the position
       either way, so an early fetch costs nothing on screen. *)
    (match state.msg_older_cursor with
     | Some before
       when state.msg_older_exist && not state.msg_older_loading ->
         load_older ~before
     | Some _ | None -> ());
    true
  | "down" ->
    state.msg_scroll <- max 0 (state.msg_scroll - 1);
    true
  | "pageup" ->
    (* A keeper's turn is many rows, so one row per press walks back through a
       single message. A page is the unit the reader actually moves in. *)
    state.msg_scroll <- state.msg_scroll + keeper_message_page_rows state;
    true
  | "pagedown" ->
    state.msg_scroll <-
      max 0 (state.msg_scroll - keeper_message_page_rows state);
    true
  | "end" ->
    state.msg_scroll <- 0;
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
      (* Ctrl-U: clear the composer *)
      Buffer.clear state.msg_input;
      true
    end else if c = Some 5 then begin
      (* Ctrl-E: back to the newest row. Scrolling down one row at a time from
         far back is worse than a key that ends the trip. *)
      state.msg_scroll <- 0;
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
  http_transport: (Tui_decode.transport_health, string) result option;
  http_approvals: approval_observation option;
  http_board: (board_post list, string) result;
  http_planning: (planning_snapshot, string) result;
  http_system_logs: (system_log_snapshot, string) result;
  http_fleet_safety: (Tui_decode.fleet_safety, string) result;
  (* [None] on surfaces that do not show it: the roster costs a request and
     only the Keepers surface reads it, so leaving it out keeps whatever the
     last Keepers refresh observed rather than dropping it. *)
  http_keeper_roster:
    (Keeper_control.roster, Keeper_control.roster_failure) result option;
}

type async_msg =
  | Http_refresh_done of http_surface_results
  | Http_refresh_failed of string * Approval.Flow.generation option
  | Board_post_refresh_done of
      Board_detail.request * (board_post * board_comment list, string) result
  | Board_post_refresh_failed of Board_detail.request * string
  | Approval_decision_done of
      approval_item
      * approval_decision
      * (Approval.confirm_outcome, string) result
      * approval_observation
  | Keeper_chat_dispatch_started of
      Keeper_chat.request * bool * bool Eio.Promise.u
  | Keeper_chat_done of
      Keeper_chat.request
      * bool
      * (Keeper_chat.response, Keeper_chat.error) result
      * unit Eio.Promise.u
  | Keeper_chat_stream_deltas of Keeper_chat.request * Keeper_chat_live.delta list
  | Keeper_chat_stream_unavailable of Keeper_chat.request * string
  | Keeper_chat_interrupt_done of
      Keeper_chat.request * (Masc_tui_http.interrupt_signal, string) result
  | Keeper_chat_history_loaded of
      string * (Keeper_chat_history.decoded, string) result
  | Keeper_chat_older_loaded of
      string * float * (Keeper_chat_history.page, string) result
  | Verification_loaded of (Masc.Tui_decode.verification_snapshot, string) result
  | Keeper_chat_approval_answered of
      Keeper_chat.request * string * bool * (bool, string) result
  | Keeper_chat_dispatch_reconcile of Keeper_chat.request
  | Keeper_chat_dispatch_blocked of Keeper_chat.request * string
  | Keeper_chat_cleanup_done of Keeper_chat.request * (unit, string) result
  | Keeper_chat_reconciled of
      Keeper_chat.request
      * (Keeper_chat.operation_reconciliation, Keeper_chat.error) result
  | Keeper_action_done of
      string
      * Keeper_control.action
      * (Keeper_control.outcome, string) result
  | Board_new_post_done of (string, string) result

let enqueue_async mailbox msg = Eio.Stream.add mailbox msg

let current_clock_text () =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
    now.Unix.tm_sec

let clock_text_of_unix at =
  let time = Unix.localtime at in
  Printf.sprintf "%02d:%02d:%02d" time.Unix.tm_hour time.Unix.tm_min
    time.Unix.tm_sec

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
          me_at = Unix.gettimeofday ();
        } ]

let remember_unverified state request = state.msg_unverified <- Some request

let append_user_history_once state (request : Keeper_chat.request) =
  let expected_text =
    Keeper_chat.terminal_safe_text ~preserve_newlines:true request.message
  in
  let already_present =
    List.exists
      (fun entry ->
        (match entry.me_role with Message_user _ -> true | _ -> false)
        && String.equal entry.me_request_id request.Keeper_chat.request_id
        && String.equal entry.me_keeper_name request.keeper_name
        && String.equal entry.me_text expected_text)
      state.msg_history
  in
  if not already_present then
    append_chat_history state request (Message_user "you") request.message

let enqueue_dispatch_ack mailbox make_message =
  let acknowledged, acknowledge = Eio.Promise.create () in
  enqueue_async mailbox (make_message acknowledge);
  Eio.Promise.await acknowledged

let enqueue_dispatch_start mailbox request was_replay =
  let acknowledged, acknowledge = Eio.Promise.create () in
  enqueue_async mailbox
    (Keeper_chat_dispatch_started (request, was_replay, acknowledge));
  Eio.Promise.await acknowledged

(* Send the turn and read it as it arrives.

   Bounding the silence needs a clock. Without one the buffered send is used
   instead -- it is what shipped before this and stays correct, so a missing
   clock costs the live view and nothing else. It is said out loud rather than
   passed over: a pane that quietly stops drawing looks like a keeper that
   stopped working. *)
let post_keeper_chat_watching ~mailbox ~port request =
  let host = Env_config_core.masc_host () in
  match Eio_context.get_clock_opt () with
  | None ->
      enqueue_async mailbox
        (Keeper_chat_stream_unavailable
           ( request
           , "sending without a live view: no Eio clock to bound the stream" ));
      Masc_tui_http.post_keeper_chat ~host ~port request
  | Some clock ->
      let decoder = Keeper_chat_live.create () in
      (* Runs on this fiber between reads, so it only decodes and hands the
         result to the render loop; drawing happens there. *)
      let on_chunk chunk =
        match Keeper_chat_live.feed decoder chunk with
        | [] -> ()
        | deltas ->
            enqueue_async mailbox (Keeper_chat_stream_deltas (request, deltas))
      in
      Masc_tui_http.post_keeper_chat_streaming ~clock ~host ~port ~on_chunk
        request

(* The strict decode carries no tool information, so the rows the live pane
   drew are the only record of what the turn did. They are committed before
   the reply lands so the scrollback reads in the order it happened. *)
let settle_live_turn state (request : Keeper_chat.request) =
  match state.msg_live with
  | Some live
    when String.equal
           (Keeper_chat_transcript.request_id live)
           request.Keeper_chat.request_id ->
      (match Keeper_chat_transcript.tool_rows live with
       | [] -> ()
       | rows ->
           append_chat_history state request Message_tool
             (String.concat "\n" rows));
      state.msg_live <- None
  | Some _ | None -> ()

(* Ask the server to interrupt the turn this request opened.

   Nothing here decides that the turn stopped. The server reports whether it
   signalled the running fiber, and a turn parked in an uncancellable section
   keeps going after that (masc #29229). The stream ending is the proof, so the
   pane keeps drawing until it does. *)
(* Load the keeper's durable transcript. Runs on its own fiber: the pane stays
   responsive, and a slow or unreachable server costs the scrollback rather than
   the keypress that asked for it. *)
(* Answer the call the keeper is held at. Runs on its own fiber: the pane stays
   responsive, and a slow server costs the answer rather than the keypress. *)
let launch_keeper_approval state ~mailbox (request : Keeper_chat.request)
    ~tool_call_id ~allow =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let keeper_name = request.Keeper_chat.keeper_name in
  let run () =
    let result =
      try
        Masc_tui_http.post_keeper_tool_approval ~host ~port ~keeper_name
          ~tool_call_id ~allow
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (Keeper_chat_approval_answered (request, tool_call_id, allow, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_approval_answered
           (request, tool_call_id, allow, Error "Eio switch is unavailable"))

(* Fetch the page before [before]. One at a time: msg_older_loading gates the
   caller, so scrolling fast cannot open a request per keypress and land the
   pages out of order. *)
(* Load the verification queue. Its own fiber, like every other surface fetch:
   the pane stays responsive and a slow server costs the list rather than the
   keypress that asked for it. *)
let launch_verification_load state ~mailbox =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_verification ~host ~port ~limit:200 with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Verification_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (Verification_loaded (Error "Eio switch is unavailable"))

let launch_keeper_older_page state ~mailbox ~keeper_name ~before =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  state.msg_older_loading <- true;
  let run () =
    let result =
      try
        Masc_tui_http.fetch_keeper_chat_history_page ~host ~port ~keeper_name
          ~before
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_chat_older_loaded (keeper_name, before, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_older_loaded
           (keeper_name, before, Error "Eio switch is unavailable"))

let launch_keeper_history_load state ~mailbox ~keeper_name =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_http.fetch_keeper_chat_history ~host ~port ~keeper_name with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_chat_history_loaded (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_history_loaded
           (keeper_name, Error "Eio switch is unavailable"))

(* Rows this session wrote that the transcript now carries. Dropped so the same
   turn is not drawn twice, once from each source.

   Notices are kept: the server has no row for "the dispatch was blocked" or
   "the recovery fence needs Ctrl-R". A transport failure is the one overlap --
   the server records those too -- so one can show twice. Keeping a duplicate
   error beats dropping one the server never saw. *)
let forget_session_rows_the_transcript_holds state keeper_name =
  state.msg_history <-
    List.filter
      (fun entry ->
        (not (String.equal entry.me_keeper_name keeper_name))
        ||
        match entry.me_role with
        | Message_status | Message_error -> true
        | Message_user _ | Message_keeper | Message_tool -> false)
      state.msg_history

let msg_entry_of_history_row keeper_name (row : Keeper_chat_history.row) =
  let role, text =
    match row.Keeper_chat_history.kind with
    | Keeper_chat_history.Addressed_to_keeper { speaker; surface } ->
        ( Message_user (Keeper_chat_history.addressed_label speaker surface)
        , row.text )
    | Keeper_chat_history.Said_by_keeper -> (Message_keeper, row.text)
    | Keeper_chat_history.Delivery_failed -> (Message_error, row.text)
    | Keeper_chat_history.Tool_calls rows ->
        (Message_tool, String.concat "\n" rows)
  in
  { me_role = role
  ; me_text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text
  ; me_timestamp = clock_text_of_unix row.Keeper_chat_history.at
  ; me_keeper_name = keeper_name
  ; (* The transcript carries no request id: these rows predate this session, or
       came from another client. The pane shows the compacted id beside a row,
       so an empty one is what says "not from a request this session made". *)
    me_request_id = ""
  ; me_at = row.Keeper_chat_history.at
  }

let launch_keeper_interrupt state ~mailbox (request : Keeper_chat.request) =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let keeper_name = request.Keeper_chat.keeper_name in
  let run () =
    let result =
      try Masc_tui_http.post_keeper_turn_interrupt ~host ~port ~keeper_name
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_chat_interrupt_done (request, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_interrupt_done (request, Error "Eio switch is unavailable"))

let launch_keeper_request state ~base_path ~mailbox request =
  state.msg_inflight <- Some request;
  state.msg_inflight_kind <- Some Dispatch_claim;
  let run () =
    match
      Keeper_chat_recovery.with_dispatch_claim ~base_path request (function
        | Keeper_chat_recovery.Accepted_dispatch ->
            enqueue_async mailbox (Keeper_chat_dispatch_reconcile request)
        | Keeper_chat_recovery.Reconcile_dispatch ->
            enqueue_async mailbox (Keeper_chat_dispatch_reconcile request)
        | Keeper_chat_recovery.Rejected_dispatch ->
            let result =
              Keeper_chat_recovery.clear_pending ~base_path request
            in
            enqueue_async mailbox (Keeper_chat_cleanup_done (request, result))
        | (Keeper_chat_recovery.First_dispatch
          | Keeper_chat_recovery.Replay_dispatch) as claim ->
            let was_replay =
              match claim with
              | Keeper_chat_recovery.First_dispatch -> false
              | Keeper_chat_recovery.Replay_dispatch -> true
              | Keeper_chat_recovery.Reconcile_dispatch
              | Keeper_chat_recovery.Accepted_dispatch
              | Keeper_chat_recovery.Rejected_dispatch -> assert false
            in
            if enqueue_dispatch_start mailbox request was_replay
            then begin
              let result =
                try
                  post_keeper_chat_watching ~mailbox ~port:state.port request
                with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn ->
                    Error
                      (Keeper_chat.Transport_error (Printexc.to_string exn))
              in
              enqueue_dispatch_ack mailbox (fun acknowledge ->
                Keeper_chat_done (request, was_replay, result, acknowledge))
            end)
    with
    | Ok () -> ()
    | Error detail ->
        enqueue_async mailbox (Keeper_chat_dispatch_blocked (request, detail))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_dispatch_blocked
           (request, "Eio switch is unavailable"))

let persist_keeper_message_fence ~base_path request =
  (* [Fs_compat.save_file_atomic_strict] can report a close failure directly to
     stderr. This action already owns an input-triggered frame, so marking the
     cached frame before the persistence attempt is sufficient to make that
     presentation a full redraw without adding another wake-up. *)
  Terminal_write_repair.note ();
  Keeper_chat_recovery.persist_pending ~base_path request

let queue_keeper_message state ~keeper_name text =
  match Chat_queue.push state.msg_queued ~keeper_name text with
  | Error _ as error -> error
  | Ok (queue, waiting) ->
      state.msg_queued <- queue;
      Ok waiting
;;

let rec start_keeper_message ?keeper_name state ~base_path ~mailbox text =
  match state.msg_prepared with
  | Some request ->
      add_event state "error"
        (Printf.sprintf
           "Keeper request %s is prepared for its first serialized dispatch; use Ctrl-R to retry its recovery fence"
           request.request_id)
  | None ->
  match state.msg_cleanup_pending with
  | Some request ->
      add_event state "error"
        (Printf.sprintf
           "Keeper request %s is settled but its durable cleanup is incomplete; use Ctrl-R to finish cleanup"
           request.request_id)
  | None ->
  match state.msg_recovery_error with
  | Some (Recovery_blocked detail) ->
      add_event state "error"
        ("Cannot send while Keeper chat recovery is blocked; use Ctrl-R to reload the durable state: "
       ^ detail)
  | None ->
  match state.msg_inflight with
  | Some request -> (
      (* A turn is running. Hold the line rather than refusing it: the operator
         pressed Enter meaning "send this next", and the turn settling is what
         "next" is. *)
      match
        match keeper_name with
        | Some _ -> keeper_name
        | None -> state.msg_target_keeper_name
      with
      | None -> add_event state "error" "Cannot queue: no Keeper is selected"
      | Some target -> (
          match queue_keeper_message state ~keeper_name:target text with
          | Error detail -> add_event state "error" detail
          | Ok waiting ->
              clear_current_message_draft state;
              add_event state "message"
                (Printf.sprintf
                   "Queued for %s behind %s (%d waiting)"
                   (Keeper_chat.terminal_safe_text target)
                   request.request_id
                   waiting)))
  | None -> (
      match state.msg_unverified with
      | Some request ->
          add_event state "error"
            (Printf.sprintf
               "Keeper request %s has an unverified outcome; use Ctrl-R to reconnect with the same request ID"
               request.request_id)
      | None ->
      match
        (match keeper_name with Some _ -> keeper_name | None -> state.msg_target_keeper_name)
      with
      | None -> add_event state "error" "Cannot send: no Keeper is selected"
      | Some _ when Option.is_some state.keepers_error ->
          add_event state "error"
            "Cannot send while the Keeper roster is unavailable"
      | Some keeper_name
        when not (keeper_available_for_new_message state keeper_name) ->
          add_event state "error"
            (Printf.sprintf "Cannot send: Keeper %s is no longer registered"
               (Keeper_chat.terminal_safe_text keeper_name))
      | Some keeper_name ->
          let request =
            Keeper_chat.create_request ~keeper_name ~message:text
          in
          (match persist_keeper_message_fence ~base_path request with
           | Error detail ->
               state.msg_recovery_error <- Some (Recovery_blocked detail);
               add_event state "error"
                 ("Keeper message was not sent because its recovery fence could not be persisted; Ctrl-R rechecks the durable state: "
                ^ detail)
           | Ok (Keeper_chat_recovery.Visible_sync_unconfirmed detail) ->
               state.msg_prepared <- Some request;
               state.msg_recovery_error <- Some (Recovery_blocked detail);
               add_event state "error"
                 (Printf.sprintf
                    "Keeper request %s is prepared, but parent-directory sync was not confirmed; no POST was issued. Ctrl-R retries the exact fence"
                    request.request_id)
           | Ok (Keeper_chat_recovery.Durable_write_cancelled detail) ->
               state.msg_prepared <- Some request;
               state.msg_recovery_error <- Some (Recovery_blocked detail);
               add_event state "error"
                 (Printf.sprintf
                    "Keeper request %s is durably prepared, but dispatch was cancelled; no POST was issued. Ctrl-R retries the exact fence"
                    request.request_id)
           | Ok Keeper_chat_recovery.Dispatching_already ->
               state.msg_prepared <- None;
               remember_unverified state request;
               add_event state "message"
                 (Printf.sprintf
                    "Keeper request %s was claimed by another dispatcher; entering serialized phase recheck"
                    request.request_id);
               launch_keeper_request state ~base_path ~mailbox request
           | Ok Keeper_chat_recovery.Accepted_already ->
               remember_unverified state request;
               append_user_history_once state request;
               consume_dispatched_message_draft state request;
               add_event state "message"
                 (Printf.sprintf
                    "Keeper request %s was accepted by another process; reconciling the exact operation"
                    request.request_id);
               launch_keeper_reconciliation state ~mailbox request
           | Ok Keeper_chat_recovery.Fsync_completed ->
               state.msg_prepared <- Some request;
               add_event state "message"
                 (Printf.sprintf "Keeper message durably fenced: %s"
                    request.request_id);
               launch_keeper_request state ~base_path ~mailbox request))

and launch_keeper_reconciliation state ~mailbox request =
  state.msg_inflight <- Some request;
  state.msg_inflight_kind <- Some Operation_get;
  state.msg_recovery_error <- None;
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

let launch_keeper_cleanup state ~base_path ~mailbox request =
  state.msg_prepared <- None;
  state.msg_cleanup_pending <- None;
  state.msg_unverified <- None;
  state.msg_recovery_error <- None;
  state.msg_inflight <- Some request;
  state.msg_inflight_kind <- Some Cleanup_delete;
  let run () =
    let result =
      match
        Keeper_chat_recovery.with_dispatch_lock ~base_path (fun () ->
          Keeper_chat_recovery.clear_pending ~base_path request)
      with
      | Ok result -> result
      | Error _ as error -> error
    in
    enqueue_async mailbox (Keeper_chat_cleanup_done (request, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
        run ();
        `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_cleanup_done
           (request, Error "Eio switch is unavailable"))

(* Send the oldest waiting line, once. Only one at a time: dispatch is
   serialized on a single in-flight request, and the next settle drains the
   next. Nothing is sent while a prepared fence, an unverified outcome, or a
   blocked recovery is standing — those want the operator's Ctrl-R, and
   pushing a queued line into them would turn a wait into an error. The queue
   keeps its place and drains when the block clears. *)
let drain_queued_message state ~base_path ~mailbox =
  (* One send per settle: dispatch is serialized on a single in-flight request
     and the next settle drains the next. The loop is only for lines that
     cannot be sent at all — it skips past them to reach one that can, rather
     than stopping the whole queue behind a keeper that left.

     Recursion stays inside so the exported name has no self-call: a wiring
     test that counts calls to it would otherwise be satisfied by this
     function calling itself, and pass with nothing else calling it at all. *)
  let rec next () =
    match Chat_queue.pop state.msg_queued with
    | None -> ()
    | Some ((keeper_name, text), rest) ->
        (* Nothing is sent while a prepared fence, an unverified outcome, or a
           blocked recovery is standing — those want the operator's Ctrl-R, and
           pushing a queued line into them would turn a wait into an error. The
           queue keeps its place and drains when the block clears. *)
        if
          Option.is_none state.msg_inflight
          && Option.is_none state.msg_prepared
          && Option.is_none state.msg_unverified
          && Option.is_none state.msg_recovery_error
        then
          if keeper_available_for_new_message state keeper_name
          then (
            state.msg_queued <- rest;
            start_keeper_message ~keeper_name state ~base_path ~mailbox text)
          else (
            (* The keeper this was written to is no longer registered. Sending
               it would fail; holding it would leave a count reporting work that
               never moves. Say what is being let go, and let it go. *)
            let before = Chat_queue.length state.msg_queued in
            state.msg_queued <-
              Chat_queue.drop_for_keeper state.msg_queued ~keeper_name;
            add_event state "error"
              (Printf.sprintf
                 "Keeper %s is no longer registered; %d queued message(s) for \
                  it were not sent"
                 (Keeper_chat.terminal_safe_text keeper_name)
                 (before - Chat_queue.length state.msg_queued));
            next ())
  in
  next ()
;;

let clear_keeper_chat_recovery state ~base_path request =
  match Keeper_chat_recovery.clear_pending ~base_path request with
  | Ok () ->
      state.msg_cleanup_pending <- None;
      state.msg_unverified <- None;
      state.msg_recovery_error <- None
  | Error detail ->
      state.msg_cleanup_pending <- Some request;
      state.msg_unverified <- None;
      state.msg_recovery_error <- Some (Recovery_blocked detail);
      add_event state "error"
        ("Keeper chat settled, but its recovery fence could not be cleared: "
       ^ detail)

let rec retry_keeper_message state ~base_path ~mailbox =
  match state.msg_cleanup_pending with
  | Some request ->
      (match state.msg_inflight with
       | Some inflight ->
           add_event state "system"
             (Printf.sprintf "Keeper message already in progress: %s"
                inflight.request_id)
       | None ->
           add_event state "message"
             (Printf.sprintf "Retrying Keeper recovery cleanup: %s"
                request.request_id);
           launch_keeper_cleanup state ~base_path ~mailbox request)
  | None ->
  match state.msg_inflight, state.msg_prepared, state.msg_unverified with
  | Some request, _, _ ->
      add_event state "system"
        (Printf.sprintf "Keeper message already in progress: %s"
           request.request_id)
  | None, Some request, _ ->
      add_event state "message"
        (Printf.sprintf
           "Rechecking prepared Keeper request under the exclusive dispatch lock: %s"
           request.request_id);
      launch_keeper_request state ~base_path ~mailbox request
  | None, None, None ->
      (match state.msg_recovery_error with
       | None ->
           add_event state "system" "No unverified Keeper request to reconnect"
       | Some _ ->
           (match Keeper_chat_recovery.load_pending ~base_path with
            | Error detail ->
                state.msg_recovery_error <- Some (Recovery_blocked detail);
                add_event state "error"
                  ("Keeper recovery reload still fails: " ^ detail)
            | Ok None ->
                state.msg_recovery_error <- None;
                add_event state "message"
                  "Keeper recovery has no pending fence; new sends are enabled"
            | Ok (Some pending) ->
                state.msg_recovery_error <- None;
                Keeper_chat_recovery.resume_pending pending
                  ~retry_prepared:(fun request ->
                    state.msg_unverified <- None;
                    state.msg_prepared <- Some request;
                    retry_keeper_message state ~base_path ~mailbox)
                  ~reconcile_dispatching:(fun request ->
                    state.msg_prepared <- None;
                    remember_unverified state request;
                    append_user_history_once state request;
                    add_event state "message"
                      (Printf.sprintf
                         "Dispatch result was not durably classified; waiting for serialized GET-only reconciliation: %s"
                         request.request_id);
                    launch_keeper_request state ~base_path ~mailbox request)
                  ~retry_replayable:(fun request ->
                    state.msg_prepared <- None;
                    remember_unverified state request;
                    launch_keeper_request state ~base_path ~mailbox request)
                  ~reconcile_accepted:(fun request ->
                    remember_unverified state request;
                    append_user_history_once state request;
                    launch_keeper_reconciliation state ~mailbox request)
                  ~cleanup_rejected:(fun request ->
                    add_event state "message"
                      (Printf.sprintf
                         "Removing definitively rejected Keeper recovery fence: %s"
                         request.request_id);
                    launch_keeper_cleanup state ~base_path ~mailbox request)))
  | None, None, Some request ->
      (match Keeper_chat_recovery.load_pending ~base_path with
       | Error detail ->
           state.msg_recovery_error <- Some (Recovery_blocked detail);
           add_event state "error"
             ("Keeper recovery phase could not be reloaded: " ^ detail)
       | Ok None ->
           state.msg_prepared <- None;
           state.msg_unverified <- None;
           state.msg_recovery_error <- None;
           add_event state "message"
             "Keeper recovery fence was cleared by the serialized dispatcher; new sends are enabled"
       | Ok (Some pending)
         when Keeper_chat.same_request_identity pending.request request ->
           Keeper_chat_recovery.resume_pending pending
             ~retry_prepared:(fun prepared ->
               state.msg_unverified <- None;
               state.msg_prepared <- Some prepared;
               retry_keeper_message state ~base_path ~mailbox)
             ~reconcile_dispatching:(fun dispatching ->
               state.msg_prepared <- None;
               remember_unverified state dispatching;
               append_user_history_once state dispatching;
               add_event state "message"
                 (Printf.sprintf
                    "Waiting to reconcile unclassified dispatch by exact ID without POST: %s"
                    dispatching.request_id);
               launch_keeper_request state ~base_path ~mailbox dispatching)
             ~retry_replayable:(fun dispatching ->
               state.msg_prepared <- None;
               remember_unverified state dispatching;
               launch_keeper_request state ~base_path ~mailbox dispatching)
             ~reconcile_accepted:(fun accepted ->
               append_user_history_once state accepted;
               add_event state "message"
                 (Printf.sprintf "Reconciling Keeper request by exact ID: %s"
                    accepted.request_id);
               launch_keeper_reconciliation state ~mailbox accepted)
             ~cleanup_rejected:(fun rejected ->
               add_event state "message"
                 (Printf.sprintf
                    "Removing definitively rejected Keeper recovery fence: %s"
                    rejected.request_id);
               launch_keeper_cleanup state ~base_path ~mailbox rejected)
       | Ok (Some pending) ->
           state.msg_recovery_error <-
             Some
               (Recovery_blocked
                  (Printf.sprintf
                     "durable request %s differs from in-memory request %s"
                     pending.request.request_id request.request_id));
           add_event state "error"
             "Keeper recovery identity mismatch; no POST or GET was issued")

let mark_keeper_chat_accepted state ~base_path request =
  match Keeper_chat_recovery.mark_accepted ~base_path request with
  | Ok Keeper_chat_recovery.Fsync_completed
  | Ok Keeper_chat_recovery.Dispatching_already
  | Ok Keeper_chat_recovery.Accepted_already -> true
  | Ok (Keeper_chat_recovery.Durable_write_cancelled detail) ->
      add_event state "system"
        ("Keeper acceptance is durable, but the write completion was cancelled: "
       ^ detail);
      false
  | Ok (Keeper_chat_recovery.Visible_sync_unconfirmed detail) ->
      add_event state "system"
        ("Keeper acceptance is visible, but parent-directory sync was not confirmed: "
       ^ detail);
      true
  | Error detail ->
      add_event state "error"
        ("Keeper request was accepted, but its recovery phase did not advance to accepted; recovery remains GET-only: "
       ^ detail);
      true

let mark_keeper_chat_rejected state ~base_path request =
  match Keeper_chat_recovery.mark_rejected ~base_path request with
  | Ok Keeper_chat_recovery.Fsync_completed -> true
  | Ok (Keeper_chat_recovery.Durable_write_cancelled detail) ->
      add_event state "system"
        ("Keeper rejection is durable, but the write completion was cancelled: "
       ^ detail);
      false
  | Ok (Keeper_chat_recovery.Visible_sync_unconfirmed detail) ->
      add_event state "system"
        ("Keeper rejection is visible, but parent-directory sync was not confirmed: "
       ^ detail);
      true
  | Ok Keeper_chat_recovery.Dispatching_already
  | Ok Keeper_chat_recovery.Accepted_already ->
      add_event state "error"
        "Keeper rejection reached an impossible persistence outcome; cleanup is deferred";
      false
  | Error detail ->
      add_event state "error"
        ("Keeper request was rejected, but its durable terminal phase could not be recorded; cleanup is deferred and recovery remains GET-only: "
       ^ detail);
      false

let mark_keeper_chat_replayable state ~base_path request =
  match Keeper_chat_recovery.mark_replayable ~base_path request with
  | Ok Keeper_chat_recovery.Fsync_completed -> ()
  | Ok (Keeper_chat_recovery.Durable_write_cancelled detail) ->
      state.msg_recovery_error <- Some (Recovery_blocked detail);
      add_event state "system"
        ("Exact-ID replay permission is durable, but write completion was cancelled: "
       ^ detail)
  | Ok (Keeper_chat_recovery.Visible_sync_unconfirmed detail) ->
      state.msg_recovery_error <- Some (Recovery_blocked detail);
      add_event state "system"
        ("Exact-ID replay permission is visible, but parent-directory sync was not confirmed: "
       ^ detail)
  | Ok Keeper_chat_recovery.Dispatching_already
  | Ok Keeper_chat_recovery.Accepted_already ->
      let detail =
        "exact-ID replay permission reached an impossible persistence outcome"
      in
      state.msg_recovery_error <- Some (Recovery_blocked detail);
      add_event state "error" detail
  | Error detail ->
      state.msg_recovery_error <- Some (Recovery_blocked detail);
      add_event state "error"
        ("Keeper outcome is unverified, but exact-ID replay permission was not recorded; recovery is GET-only: "
       ^ detail)

let defer_keeper_chat_cleanup state request detail =
  state.msg_cleanup_pending <- Some request;
  state.msg_unverified <- None;
  state.msg_recovery_error <- Some (Recovery_blocked detail);
  add_event state "error"
    ("Keeper request settled, but cancellation deferred its durable cleanup: "
   ^ detail)

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

let apply_keeper_chat_result state ~base_path ~dispatch_was_replay request result =
  match state.msg_inflight with
  | Some current when Keeper_chat.same_request_identity current request ->
      let reconnecting_unverified =
        dispatch_was_replay
        ||
        match state.msg_unverified with
        | Some pending -> Keeper_chat.same_request_identity pending request
        | None -> false
      in
      state.msg_inflight <- None;
      state.msg_inflight_kind <- None;
      (match result with
       | Ok (Keeper_chat.Turn_completed completed) ->
           if mark_keeper_chat_accepted state ~base_path request
           then clear_keeper_chat_recovery state ~base_path request
           else
             defer_keeper_chat_cleanup state request
               "Ctrl-R retries only recovery-fence removal";
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
           if mark_keeper_chat_accepted state ~base_path request
           then clear_keeper_chat_recovery state ~base_path request
           else
             defer_keeper_chat_cleanup state request
               "Ctrl-R retries only recovery-fence removal";
           append_chat_history state request Message_status
             "Request was already completed; canonical reply is not present in this replay stream";
           add_event state "message"
             (Printf.sprintf "Keeper request already completed: %s"
                request.request_id)
       | Error error ->
           let acceptance_observed =
             Keeper_chat.error_acceptance_observed error
           in
           let acceptance_mark_allows_cleanup =
             if acceptance_observed
             then mark_keeper_chat_accepted state ~base_path request
             else true
           in
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
             | Keeper_chat.Verified_rejected ->
                 if mark_keeper_chat_rejected state ~base_path request
                 then clear_keeper_chat_recovery state ~base_path request
                 else
                   defer_keeper_chat_cleanup state request
                     "Ctrl-R retries only recovery-fence removal";
                 detail
             | Keeper_chat.Verified_failed ->
                 if acceptance_mark_allows_cleanup
                 then clear_keeper_chat_recovery state ~base_path request
                 else
                   defer_keeper_chat_cleanup state request
                     "Ctrl-R retries only recovery-fence removal";
                 detail
             | Keeper_chat.Outcome_unverified ->
                 if not acceptance_observed
                 then mark_keeper_chat_replayable state ~base_path request;
                 remember_unverified state request;
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
      state.msg_inflight_kind <- None;
      (match result with
       | Ok (Keeper_chat.Operation_succeeded { outcome_ref }) ->
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
           clear_keeper_chat_recovery state ~base_path request;
           append_chat_history state request Message_status
             "Operation was cancelled";
           add_event state "message"
             (Printf.sprintf "Keeper operation cancelled: %s"
                request.request_id)
       | Ok (Keeper_chat.Operation_pending state_value) ->
           remember_unverified state request;
           append_chat_history state request Message_error
             (Printf.sprintf
                "Operation reconciliation stopped while still %s; outcome remains unverified"
                (match state_value with
                 | Keeper_chat.Queued -> "queued"
                 | Keeper_chat.Running -> "running"
                 | Keeper_chat.Succeeded | Keeper_chat.Failed
                 | Keeper_chat.Cancelled -> "in an unexpected terminal state"))
       | Error error ->
           remember_unverified state request;
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

let apply_transport_load state = function
  | Ok transport ->
      state.transport <- Some transport;
      state.transport_error <- None
  | Error err ->
      state.transport <- None;
      remember_surface_error state ~surface:"transport health"
        ~current_error:state.transport_error
        ~set_error:(fun value -> state.transport_error <- value)
        err

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

let replace_board_posts state posts =
  let source =
    match state.board_mode with
    | Board_list | Board_compose -> Board_selection.List_cursor
    | Board_read post_id -> Board_selection.Detail_post post_id
  in
  let post_ids posts = List.map (fun post -> post.bp_id) posts in
  let cursor =
    Board_selection.reconcile_cursor
      ~current_ids:(post_ids state.board_posts)
      ~cursor:state.board_cursor ~source ~next_ids:(post_ids posts)
  in
  state.board_posts <- posts;
  state.board_cursor <- cursor

let leave_board_detail state =
  state.board_mode <- Board_list;
  state.board_scroll <- 0;
  state.board_detail <- Board_detail.clear state.board_detail

let leave_missing_board_detail state =
  match state.board_mode with
  | Board_read post_id
    when not (List.exists (fun post -> String.equal post.bp_id post_id) state.board_posts) ->
      leave_board_detail state
  | Board_list | Board_read _ | Board_compose -> ()

let apply_board_list_load state = function
  | Ok posts ->
      replace_board_posts state posts;
      state.board_list_error <- None;
      leave_missing_board_detail state
  | Error err ->
      remember_surface_error state ~surface:"board list"
        ~current_error:state.board_list_error
        ~set_error:(fun value -> state.board_list_error <- value)
        err

(* One request per refresh returns this many lines. The server caps the
   parameter at 3000; a screenful of scrollback is what the surface can show
   without holding the whole ring in memory. *)
let system_log_page = 300

let apply_system_logs_load state = function
  | Ok snapshot ->
      state.system_logs <- Some snapshot;
      state.system_logs_error <- None
  | Error detail ->
      (* The previous page stays on screen; the error line says the count above
         it is stale rather than letting it read as a fresh zero. *)
      state.system_logs_error <- Some detail

let apply_fleet_safety_load state = function
  | Ok fleet ->
      state.fleet_safety <- Some fleet;
      state.fleet_safety_error <- None
  | Error err ->
      (* The last good reading is dropped: a stale fleet line is worse than an
         absent one, because it reports keepers as running after the reading
         that said so stopped arriving. *)
      state.fleet_safety <- None;
      remember_surface_error state ~surface:"fleet safety"
        ~current_error:state.fleet_safety_error
        ~set_error:(fun value -> state.fleet_safety_error <- value)
        err

let apply_keeper_roster_load state = function
  | Ok roster ->
      state.keeper_roster <- roster;
      state.keeper_roster_error <- None
  | Error failure ->
      (* The last good roster is dropped rather than kept: a stale one reports
         fibers as running after the reading that said so stopped arriving,
         and every lifecycle action on this surface is chosen from it. Going
         back to unobserved withdraws the actions instead of offering the
         wrong one. *)
      state.keeper_roster <- Keeper_control.Roster_unobserved;
      remember_surface_error state ~surface:"keeper roster"
        ~current_error:state.keeper_roster_error
        ~set_error:(fun value -> state.keeper_roster_error <- value)
        (Keeper_control.roster_failure_message failure)

let apply_planning_load state = function
  | Ok planning ->
      let goal_ids planning =
        planning_visible_goals planning.pl_goals
        |> List.map (fun goal -> goal.pg_id)
      in
      let current =
        match state.planning_mode with
        | Planning_list ->
            Planning_selection.List_cursor state.planning_cursor
        | Planning_detail goal_id ->
            Planning_selection.Detail_goal
              { goal_id; cursor = state.planning_cursor }
      in
      let current_ids =
        match state.planning with
        | None -> []
        | Some current_planning -> goal_ids current_planning
      in
      let navigation =
        Planning_selection.reconcile ~current_ids
          ~next_ids:(goal_ids planning) ~current
      in
      state.planning <- Some planning;
      state.planning_error <- None;
      (match navigation with
       | Planning_selection.List_cursor cursor ->
           state.planning_cursor <- cursor;
           state.planning_mode <- Planning_list;
           state.planning_scroll <- 0
       | Planning_selection.Detail_goal { goal_id; cursor } ->
           state.planning_cursor <- cursor;
           state.planning_mode <- Planning_detail goal_id)
  | Error err ->
      state.planning <- None;
      state.planning_mode <- Planning_list;
      state.planning_scroll <- 0;
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

let load_http_surfaces ~host ~port ~approval_generation ~wants_transport
    ~wants_keeper_roster =
  let http_overview = load_overview ~host ~port in
  (* Only the Overview row shows this, so a refresh on another surface does not
     spend a request on it. [None] leaves whatever the last read observed. *)
  let http_transport =
    if wants_transport then Some (load_transport_health ~host ~port) else None
  in
  let http_approvals =
    Option.map
      (fun ao_generation ->
         { ao_generation; ao_result = load_approvals ~host ~port })
      approval_generation
  in
  let http_board = load_board_list ~host ~port in
  let http_planning = load_planning ~host ~port in
  let http_system_logs = load_system_logs ~host ~port ~limit:system_log_page in
  let http_fleet_safety = load_fleet_safety ~host ~port in
  let http_keeper_roster =
    if wants_keeper_roster then Some (load_keeper_roster ~host ~port) else None
  in
  { http_overview
  ; http_transport
  ; http_approvals
  ; http_board
  ; http_planning
  ; http_system_logs
  ; http_fleet_safety
  ; http_keeper_roster
  }

let apply_http_surfaces state results =
  apply_overview_load state results.http_overview;
  Option.iter (apply_transport_load state) results.http_transport;
  Option.iter (apply_approval_observation state) results.http_approvals;
  apply_board_list_load state results.http_board;
  apply_planning_load state results.http_planning;
  apply_system_logs_load state results.http_system_logs;
  apply_fleet_safety_load state results.http_fleet_safety;
  Option.iter (apply_keeper_roster_load state) results.http_keeper_roster;
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
    let needs = Masc_tui_types.surface_needs state.view in
    let wants_transport = needs.needs_transport in
    let wants_keeper_roster = needs.needs_keeper_roster in
    let run_refresh () =
      try
        enqueue_async mailbox
          (Http_refresh_done
             (load_http_surfaces ~host ~port ~approval_generation ~wants_transport
                ~wants_keeper_roster))
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
               (load_http_surfaces ~host ~port ~approval_generation ~wants_transport
                ~wants_keeper_roster))
  end

let board_detail_request_still_current state request =
  Board_detail.is_current state.board_detail request
  &&
  match state.board_mode with
  | Board_read post_id ->
      String.equal post_id (Board_detail.request_post_id request)
  | Board_list | Board_compose -> false

let apply_board_post_load state request result =
  if board_detail_request_still_current state request then
    let post_id = Board_detail.request_post_id request in
    let fail err =
      state.board_detail <-
        Board_detail.complete state.board_detail request (Error err);
      if state.view <> Board then
        add_event state "error" (Printf.sprintf "Board detail unavailable: %s" err)
    in
    match result with
    | Ok (post, comments) when String.equal post.bp_id post_id ->
        state.board_detail <-
          Board_detail.complete state.board_detail request (Ok (post, comments));
        replace_board_posts state
          (post :: List.filter (fun p -> p.bp_id <> post_id) state.board_posts)
    | Ok (post, _) ->
        fail
          (Printf.sprintf
             "Board detail response ID mismatch: expected %s, received %s"
             post_id post.bp_id)
    | Error err -> fail err

let start_board_post_refresh state ~host ~port ~post_id ~mailbox =
  match Board_detail.start state.board_detail ~post_id with
  | Board_detail.Already_loading -> ()
  | Board_detail.Started (detail, request) ->
    state.board_detail <- detail;
    let run_refresh () =
      try
        enqueue_async mailbox
          (Board_post_refresh_done
             (request, load_board_post ~host ~port ~post_id))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        enqueue_async mailbox
          (Board_post_refresh_failed
             ( request,
               Printf.sprintf "board post refresh failed: %s"
                 (Printexc.to_string exn) ))
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> Eio.Fiber.fork ~sw run_refresh
    | None ->
        let result =
          try load_board_post ~host ~port ~post_id with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
              Error
                (Printf.sprintf "board post refresh failed: %s"
                   (Printexc.to_string exn))
        in
        apply_board_post_load state request result

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

(* Run one lifecycle action's steps against the server.

   The steps come from [Keeper_control.plan]; this only performs them and
   reports the first answer that ends the sequence. The 409 branch is the one
   piece of routing here: /boot refuses a keeper whose owner is durably
   paused, and the pause only clears through the directive endpoint, so a
   conflict on an action that names a recovery continues into it instead of
   surfacing as a failure. Recovery runs once — a conflict raised by the
   recovery itself is the operator's to read. *)
let run_keeper_action_steps ~host ~port ~keeper_name ~operator_operation_id
    action =
  let perform = function
    | Keeper_control.Lifecycle lifecycle_action ->
        Masc_tui_http.post_keeper_lifecycle ~host ~port ~keeper_name
          ~action:lifecycle_action
    | Keeper_control.Directive directive_action ->
        Masc_tui_http.post_keeper_directive ~host ~port ~keeper_name
          ~action:directive_action ~operator_operation_id
  in
  let rec walk ~recovery_available last_outcome steps =
    match steps with
    | [] -> (
        match last_outcome with
        | Some outcome -> Ok outcome
        | None ->
            (* [plan] never returns an empty step list; if it ever did, an
               empty walk must not read as success. *)
            Error
              (Printf.sprintf "%s has no request to send"
                 (Keeper_control.action_label action)))
    | step :: rest -> (
        match perform step with
        | Error transport -> Error transport
        | Ok (status, body) -> (
            match Keeper_control.classify_response ~status ~body with
            | Keeper_control.Accepted _ as outcome ->
                walk ~recovery_available (Some outcome) rest
            | Keeper_control.Paused_owner_conflict detail -> (
                match
                  ( recovery_available
                  , Keeper_control.recovers_from_conflict action )
                with
                | true, Some recovery_steps ->
                    walk ~recovery_available:false last_outcome recovery_steps
                | true, None | false, _ -> Error detail)
            | Keeper_control.Rejected { status; detail } ->
                Error (Printf.sprintf "HTTP %d: %s" status detail)))
  in
  walk ~recovery_available:true None (Keeper_control.plan action)

let apply_keeper_action_result state ~base_path keeper_name action result =
  state.keeper_action_inflight <- None;
  (match result with
   | Ok (Keeper_control.Accepted { already_live = true }) ->
       add_event state "system"
         (Printf.sprintf "%s was already running; woke it instead of starting a second fiber"
            keeper_name)
   | Ok (Keeper_control.Accepted { already_live = false }) ->
       add_event state "system"
         (Printf.sprintf "%s %s accepted" keeper_name
            (Keeper_control.action_label action))
   | Ok (Keeper_control.Paused_owner_conflict detail)
   | Ok (Keeper_control.Rejected { detail; _ }) ->
       (* [run_keeper_action_steps] returns these as [Error]; keeping the
          branch exhaustive rather than wildcarded means a future outcome
          member has to be answered here too. *)
       add_event state "error"
         (Printf.sprintf "%s %s refused: %s" keeper_name
            (Keeper_control.action_label action) detail)
   | Error detail ->
       add_event state "error"
         (Printf.sprintf "%s %s failed: %s" keeper_name
            (Keeper_control.action_label action) detail));
  (* Both readings the row is built from moved: pause is durable metadata on
     disk, the fiber is in the roster. Reloading the local half here shows the
     change without waiting a refresh interval; the roster arrives with the
     HTTP refresh the caller starts. *)
  load_from_masc_dir state base_path

let start_keeper_action state ~base_path:_ ~mailbox keeper_name action =
  let serial = state.keeper_action_serial + 1 in
  state.keeper_action_serial <- serial;
  state.keeper_action_inflight <- Some (keeper_name, action);
  state.keeper_action_pending <- None;
  add_event state "system"
    (Printf.sprintf "%s %s" (Keeper_control.action_gerund action) keeper_name);
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let operator_operation_id =
    Keeper_control.mint_operation_id ~keeper:keeper_name ~serial
  in
  let run_action () =
    let result =
      try
        run_keeper_action_steps ~host ~port ~keeper_name
          ~operator_operation_id action
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_action_done (keeper_name, action, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_action
  | None ->
      let result =
        try
          run_keeper_action_steps ~host ~port ~keeper_name
            ~operator_operation_id action
        with exn -> Error (Printexc.to_string exn)
      in
      enqueue_async mailbox (Keeper_action_done (keeper_name, action, result))

(* The Board draft splits at the first newline: commit-message shape, one
   buffer covering title and body. Trimming the title keeps a draft whose
   first line has stray spaces publishable without surprising the operator. *)
let split_board_draft (text : string) : string * string =
  match String.index_opt text '\n' with
  | None -> (String.trim text, "")
  | Some idx ->
      ( String.trim (String.sub text 0 idx)
      , String.sub text (idx + 1) (String.length text - idx - 1) )

(* Post the draft through the tools endpoint. Runs in a fiber like a keeper
   action: the compose pane must keep accepting keys while the request is
   out, and the outcome lands in the same mailbox everything else does. *)
let start_board_post state ~mailbox ~(title : string) ~(body : string) =
  state.board_post_error <- None;
  add_event state "system" "posting to Board";
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run_post () =
    let result =
      match Masc_tui_http.post_board_new ~host ~port ~title ~body with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    enqueue_async mailbox (Board_new_post_done result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_post
  | None -> run_post ()

(* Compose-mode keys. Sending is armed rather than pressed: esc offers
   send-or-discard, so a stray key during writing cannot publish. Returns
   false for keys this pane does not own, so Tab and quit keep their global
   meaning. *)
let handle_board_compose_key state ~mailbox (key : string) : bool =
  if
    state.board_compose_armed
    && not
         (List.mem key [ "s"; "S"; "d"; "D"; "esc" ])
  then state.board_compose_armed <- false;
  match key with
  | "esc" ->
      state.board_compose_armed <- not state.board_compose_armed;
      true
  | "s" | "S" when state.board_compose_armed -> (
      let title, body = split_board_draft (Buffer.contents state.board_draft) in
      match String.split_on_char '\n' (String.trim title) with
      | [] | [ "" ] ->
          state.board_compose_armed <- false;
          state.board_post_error <- Some "the first line (title) is empty";
          true
      | _ ->
          state.board_compose_armed <- false;
          start_board_post state ~mailbox ~title ~body;
          true )
  | "d" | "D" when state.board_compose_armed ->
      Buffer.clear state.board_draft;
      state.board_compose_armed <- false;
      state.board_post_error <- None;
      state.board_mode <- Board_list;
      add_event state "system" "Board draft discarded";
      true
  | "\r" | "\n" ->
      Buffer.add_char state.board_draft '\n';
      true
  | "\127" | "\b" ->
      let new_content =
        Buffer.contents state.board_draft
        |> Masc_tui_message_layout.drop_last_utf8_scalar
      in
      Buffer.clear state.board_draft;
      Buffer.add_string state.board_draft new_content;
      true
  | "\t" -> false
  | s when String.length s = 1 ->
      Buffer.add_string state.board_draft s;
      true
  | _ -> true

(* The keypress path. The reading decides which actions exist at all, so a key
   that names an action the reading does not offer says why instead of sending
   a request the server would refuse. *)
let handle_keeper_action state ~base_path ~mailbox action =
  match selected_keeper state with
  | None -> ()
  | Some keeper ->
      let reading = keeper_reading state keeper in
      if not (List.mem action (Keeper_control.available reading)) then
        add_event state "system"
          (Printf.sprintf "%s cannot %s right now (%s)" keeper.k_name
             (Keeper_control.action_label action)
             (match reading.Keeper_control.liveness with
              | Keeper_control.Unobserved ->
                  "the live roster has not been read"
              | Keeper_control.Absent | Keeper_control.Present _ ->
                  Keeper_control.status_label reading ^ " keeper"))
      else
        match
          Keeper_control.gate_transition
            ~inflight:(Option.is_some state.keeper_action_inflight)
            ~pending:state.keeper_action_pending ~keeper:keeper.k_name action
        with
        | Keeper_control.Gate_blocked_inflight ->
            add_event state "system" "A keeper action is already in progress"
        | Keeper_control.Gate_arm pending ->
            state.keeper_action_pending <- Some pending;
            add_event state "system"
              (Printf.sprintf "Press %s again to %s %s"
                 (Keeper_control.action_key action)
                 (Keeper_control.action_label action) keeper.k_name)
        | Keeper_control.Gate_submit ->
            start_keeper_action state ~base_path ~mailbox keeper.k_name action

(* The composer as the key loop sees it. The renderer builds the same reading
   for the row it draws, so the key that lands and the row the operator read
   before pressing it agree on who the recipient is. *)
let composer_state (state : state) : Composer.t =
  let target =
    match selected_keeper state with
    | None -> Composer.No_target
    | Some keeper ->
        if keeper_available_for_new_message state keeper.k_name then
          Composer.Ready keeper.k_name
        else
          Composer.Unreachable
            { keeper = keeper.k_name
            ; reason =
                (match state.keepers_error with
                 | Some _ -> "keeper list unread"
                 | None -> "no longer in the roster")
            }
  in
  { Composer.target
  ; focus =
      (if state.composer_focused then Composer.Focused else Composer.Unfocused)
  ; draft = Buffer.contents state.msg_input
  }

(* Apply one keystroke the composer claimed. Sending routes through the same
   chat surface the [c] key opens, so a message typed on the roster and one
   typed in the chat view take the identical dispatch path. *)
let handle_composer_key state ~base_path ~mailbox key =
  let composer = composer_state state in
  match Composer.classify_key composer key with
  | Composer.Pass_to_surface -> false
  | Composer.Take_focus ->
      (match composer.Composer.target with
       | Composer.Ready keeper_name ->
           (* Taking focus is what names the recipient: the draft that follows
              belongs to the keeper the row showed at that moment. *)
           if
             state.msg_target_keeper_name <> Some keeper_name
           then open_message_for_keeper state keeper_name;
           state.composer_focused <- true
       | Composer.No_target | Composer.Unreachable _ -> ());
      true
  | Composer.Release_focus ->
      save_message_draft state;
      state.composer_focused <- false;
      true
  | Composer.Send ->
      state.composer_focused <- false;
      let text = Buffer.contents state.msg_input in
      state.msg_scroll <- 0;
      state.view <- Keepers Keeper_message;
      start_keeper_message state ~base_path ~mailbox text;
      true
  | Composer.Edit ->
      let _handled =
        handle_message_key state
          ~submit_message:(fun _ -> ())
          ~retry_message:(fun () -> ())
          ~answer_approval:(fun ~tool_call_id:_ ~allow:_ -> ())
          ~load_older:(fun ~before:_ -> ())
          key
      in
      true

let apply_async_message state ~base_path ~http_refresh_inflight ~mailbox =
  function
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
  | Board_post_refresh_done (request, result) ->
      apply_board_post_load state request result
  | Board_post_refresh_failed (request, err) ->
      apply_board_post_load state request (Error err)
  | Keeper_action_done (keeper_name, action, result) ->
      apply_keeper_action_result state ~base_path keeper_name action result;
      (* The roster is the half of the row this refresh cannot read from disk,
         and it is what decides which action the row offers next. Asking for it
         now means the row stops offering the action that just ran without
         waiting out the refresh interval. *)
      start_http_refresh state ~host:(Env_config_core.masc_host ())
        ~port:state.port ~refresh_inflight:http_refresh_inflight ~mailbox
  | Board_new_post_done result -> (
      match result with
      | Ok message ->
          Buffer.clear state.board_draft;
          state.board_compose_armed <- false;
          state.board_post_error <- None;
          state.board_mode <- Board_list;
          add_event state "system" ("Board: " ^ message);
          (* The posted row is the half the periodic refresh has not fetched
             yet; without this the operator returns to a list that does not
             contain what they just published. *)
          start_http_refresh state ~host:(Env_config_core.masc_host ())
            ~port:state.port ~refresh_inflight:http_refresh_inflight ~mailbox
      | Error err ->
          state.board_compose_armed <- false;
          (* The draft stays: a rejected post is usually one field short, and
             losing the text over it would make the error a dead end. *)
          state.board_post_error <- Some err)
  | Approval_decision_done (approval, decision, result, approvals) ->
      apply_approval_decision_completion state approvals.ao_generation approval
        decision result approvals.ao_result
  | Keeper_chat_dispatch_started (request, was_replay, acknowledge) ->
      let proceed = ref false in
      Fun.protect
        ~finally:(fun () -> Eio.Promise.resolve acknowledge !proceed)
        (fun () ->
          match state.msg_inflight with
          | Some current
            when Keeper_chat.same_request_identity current request ->
              state.msg_prepared <- None;
              state.msg_inflight_kind <- Some Chat_post;
              state.msg_recovery_error <- None;
              if was_replay
              then remember_unverified state request
              else state.msg_unverified <- None;
              append_user_history_once state request;
              consume_dispatched_message_draft state request;
              add_event state "message"
                (Printf.sprintf "%s Keeper request: %s"
                   (if was_replay then "Replaying exact" else "Dispatching")
                   request.request_id);
              state.msg_live <-
                Some
                  (Keeper_chat_transcript.create
                     ~keeper_name:request.Keeper_chat.keeper_name
                     ~request_id:request.request_id);
              proceed := true
          | Some _ | None -> ())
  | Keeper_chat_done (request, was_replay, result, acknowledge) ->
      settle_live_turn state request;
      (* The server persists the user row, the reply and the tool calls before
         it ends the stream, so by now the transcript holds this turn. Reloading
         makes the record the thing on screen; the rows settle_live_turn just
         committed are what stands if the load fails. *)
      launch_keeper_history_load state ~mailbox
        ~keeper_name:request.Keeper_chat.keeper_name;
      let applied =
        Fun.protect
          ~finally:(fun () -> Eio.Promise.resolve acknowledge ())
          (fun () ->
            apply_keeper_chat_result state ~base_path
              ~dispatch_was_replay:was_replay request result)
      in
      if applied then load_from_masc_dir state base_path;
      (* The turn settled, so "next" has arrived for whatever was waiting. *)
      drain_queued_message state ~base_path ~mailbox
  | Keeper_chat_stream_deltas (request, deltas) ->
      (* Identity-guarded: a late chunk from a superseded turn must not draw
         into the one now running. *)
      (match state.msg_live with
       | Some live
         when String.equal
                (Keeper_chat_transcript.request_id live)
                request.Keeper_chat.request_id ->
           List.iter (Keeper_chat_transcript.apply live) deltas
       | Some _ | None -> ())
  | Keeper_chat_stream_unavailable (request, detail) ->
      append_chat_history state request Message_status detail
  | Keeper_chat_approval_answered (request, tool_call_id, allow, result) ->
      let text =
        match result with
        | Ok true ->
            Printf.sprintf "%s %s"
              (if allow then "allowed" else "denied")
              (Keeper_chat.compact_request_id tool_call_id)
        | Ok false ->
            (* The wait was gone: it timed out, or something answered it
               first. Said plainly rather than shown as taken, so an operator
               is not told a call was allowed when nothing was listening. *)
            Printf.sprintf
              "too late for %s; the call was no longer waiting"
              (Keeper_chat.compact_request_id tool_call_id)
        | Error detail -> "could not answer the held call: " ^ detail
      in
      append_chat_history state request
        (match result with Ok true -> Message_status | _ -> Message_error)
        text
  | Keeper_chat_interrupt_done (request, result) ->
      (match state.msg_live with
       | Some live
         when String.equal
                (Keeper_chat_transcript.request_id live)
                request.Keeper_chat.request_id ->
           let noted =
             match result with
             | Ok (Masc_tui_http.Signalled { turn_id }) ->
                 Keeper_chat_transcript.Signal_sent { turn_id }
             | Ok (Masc_tui_http.Not_signalled { reason; detail }) ->
                 Keeper_chat_transcript.Signal_declined
                   (match detail with
                    | None -> reason
                    | Some detail -> reason ^ ": " ^ detail)
             | Error detail -> Keeper_chat_transcript.Signal_error detail
           in
           Keeper_chat_transcript.note_interrupt live noted
       | Some _ | None ->
           (* The turn settled before the answer came back. Nothing to mark,
              and the outcome the transcript already recorded is the one that
              counts. *)
           ())
  | Keeper_chat_dispatch_reconcile request ->
      (match state.msg_inflight with
       | Some current when Keeper_chat.same_request_identity current request ->
           state.msg_prepared <- None;
           remember_unverified state request;
           append_user_history_once state request;
           consume_dispatched_message_draft state request;
           add_event state "message"
             (Printf.sprintf
                "Keeper request %s does not authorize a POST; switching to exact operation reconciliation"
                request.request_id);
           launch_keeper_reconciliation state ~mailbox request
       | Some _ | None -> ())
  | Keeper_chat_dispatch_blocked (request, detail) ->
      settle_live_turn state request;
      (match state.msg_inflight with
       | Some current when Keeper_chat.same_request_identity current request ->
           state.msg_inflight <- None;
           state.msg_inflight_kind <- None;
           (match Keeper_chat_recovery.load_pending ~base_path with
            | Ok None ->
                state.msg_prepared <- None;
                state.msg_unverified <- None;
                state.msg_recovery_error <- None;
                add_event state "error"
                  ("Keeper request was not dispatched; its fence was cleared: "
                 ^ detail)
            | Ok (Some pending)
              when not
                     (Keeper_chat.same_request_identity pending.request request) ->
                state.msg_prepared <- None;
                state.msg_unverified <- None;
                state.msg_recovery_error <-
                  Some
                    (Recovery_blocked
                       (Printf.sprintf
                          "another durable request %s replaced dispatch %s"
                          pending.request.request_id request.request_id));
                add_event state "error"
                  "Keeper dispatch identity changed; no POST was issued"
            | Ok (Some { phase = Keeper_chat_recovery.Prepared; _ }) ->
                state.msg_prepared <- Some request;
                state.msg_unverified <- None;
                state.msg_recovery_error <- Some (Recovery_blocked detail);
                add_event state "error"
                  ("Keeper dispatch is blocked before its first POST: " ^ detail)
            | Ok (Some { phase = Keeper_chat_recovery.Dispatching; _ }) ->
                state.msg_prepared <- None;
                remember_unverified state request;
                state.msg_recovery_error <- Some (Recovery_blocked detail);
                append_user_history_once state request;
                consume_dispatched_message_draft state request;
                add_event state "error"
                  ("Keeper dispatch is held or not durably classified; Ctrl-R reconciles the exact operation without POST: "
                 ^ detail)
            | Ok (Some { phase = Keeper_chat_recovery.Replayable; _ }) ->
                state.msg_prepared <- None;
                remember_unverified state request;
                state.msg_recovery_error <- Some (Recovery_blocked detail);
                append_user_history_once state request;
                consume_dispatched_message_draft state request;
                add_event state "error"
                  ("Keeper exact-ID replay is waiting for the serialized dispatch lock; Ctrl-R retries: "
                 ^ detail)
            | Ok (Some { phase = Keeper_chat_recovery.Accepted; _ }) ->
                state.msg_prepared <- None;
                remember_unverified state request;
                append_user_history_once state request;
                consume_dispatched_message_draft state request;
                launch_keeper_reconciliation state ~mailbox request
            | Ok (Some { phase = Keeper_chat_recovery.Rejected; _ }) ->
                add_event state "message"
                  (Printf.sprintf
                     "Keeper request %s was definitively rejected; removing only its durable fence"
                     request.request_id);
                launch_keeper_cleanup state ~base_path ~mailbox request
            | Error recovery_detail ->
                state.msg_recovery_error <-
                  Some (Recovery_blocked recovery_detail);
                add_event state "error"
                  ("Keeper dispatch failed and recovery could not be reloaded: "
                 ^ recovery_detail))
       | Some _ | None -> ())
  | Keeper_chat_cleanup_done (request, result) ->
      (match state.msg_inflight with
       | Some current when Keeper_chat.same_request_identity current request ->
           state.msg_inflight <- None;
           state.msg_inflight_kind <- None;
           state.msg_prepared <- None;
           (match result with
            | Ok () ->
                state.msg_cleanup_pending <- None;
                state.msg_unverified <- None;
                state.msg_recovery_error <- None;
                add_event state "message"
                  (Printf.sprintf "Keeper recovery cleanup completed: %s"
                     request.request_id)
            | Error detail ->
                state.msg_prepared <- None;
                state.msg_cleanup_pending <- Some request;
                state.msg_unverified <- None;
                state.msg_recovery_error <- Some (Recovery_blocked detail);
                add_event state "error"
                  ("Keeper recovery cleanup retry failed: " ^ detail))
       | Some _ | None -> ())
  | Keeper_chat_history_loaded (keeper_name, result) -> (
      match result with
      | Ok { Keeper_chat_history.rows; dropped } ->
          state.msg_loaded <-
            List.map (msg_entry_of_history_row keeper_name) rows;
          state.msg_loaded_keeper <- Some keeper_name;
          state.msg_loaded_error <- None;
          state.msg_loaded_dropped <- dropped;
          (* Where reading further back starts. The oldest row this load
             carried is the cursor; if it carried none there is nothing to page
             back from. Whether older rows exist is only learned by asking, so
             the pane assumes they might and finds out on the first page. *)
          state.msg_older_cursor <-
            List.fold_left
              (fun oldest (row : Keeper_chat_history.row) ->
                match oldest with
                | None -> Some row.Keeper_chat_history.at
                | Some at -> Some (Float.min at row.Keeper_chat_history.at))
              None rows;
          state.msg_older_exist <- Option.is_some state.msg_older_cursor;
          state.msg_older_error <- None;
          forget_session_rows_the_transcript_holds state keeper_name
      | Error detail ->
          (* The transcript is left as it was and the session rows stay: a
             failed load must not be the reason the pane goes blank. *)
          state.msg_loaded_error <- Some detail)
  | Verification_loaded result -> (
      match result with
      | Ok snapshot ->
          state.verification <- Some snapshot;
          state.verification_error <- None
      | Error detail ->
          (* The previous list stays: a failed reload must not make the queue
             look empty, which reads as "nothing is waiting". *)
          state.verification_error <- Some detail)
  | Keeper_chat_older_loaded (keeper_name, before, result) ->
      state.msg_older_loading <- false;
      (* A page that arrived for a keeper the pane has since left, or after a
         reload moved the cursor, is dropped: prepending it would put rows
         above a transcript they do not belong to. *)
      let still_current =
        (match state.msg_loaded_keeper with
         | Some loaded -> String.equal loaded keeper_name
         | None -> false)
        && state.msg_older_cursor = Some before
      in
      if still_current then (
        match result with
        | Ok page ->
            let rows =
              List.map
                (msg_entry_of_history_row keeper_name)
                page.Keeper_chat_history.decoded.Keeper_chat_history.rows
            in
            (* Prepended, not merged: these are strictly older than everything
               loaded, and the pane orders the whole list by time anyway. *)
            state.msg_loaded <- rows @ state.msg_loaded;
            state.msg_loaded_dropped <-
              state.msg_loaded_dropped
              + page.Keeper_chat_history.decoded.Keeper_chat_history.dropped;
            state.msg_older_cursor <- page.Keeper_chat_history.next_before;
            (* A page with no cursor cannot be paged past even if the server
               says more exist, so both have to hold for the pane to offer
               another. *)
            state.msg_older_exist <-
              page.Keeper_chat_history.has_more
              && Option.is_some page.Keeper_chat_history.next_before;
            state.msg_older_error <- None
        | Error detail ->
            (* The cursor is kept so the same page can be asked for again;
               what is on screen is untouched. *)
            state.msg_older_error <- Some detail)
  | Keeper_chat_reconciled (request, result) ->
      if apply_keeper_chat_reconciliation state ~base_path request result then
        load_from_masc_dir state base_path

let drain_async_messages state ~base_path ~http_refresh_inflight mailbox =
  let rec loop changed =
    match Eio.Stream.take_nonblocking mailbox with
    | None -> changed
    | Some msg ->
        apply_async_message state ~base_path ~http_refresh_inflight ~mailbox
          msg;
        loop true
  in
  loop false

let invalidate_frame_for_resize frame_presenter render_schedule =
  invalidate_terminal_size ();
  Frame_presenter.invalidate frame_presenter;
  Render_schedule.request render_schedule Render_schedule.Force

let request_console_write_repair render_schedule =
  Terminal_write_repair.request_repaint render_schedule

let enter_terminal_session ~cleanup ~terminate ~request_full_repaint ~suspend
    ~new_term =
  at_exit cleanup;
  Sys.set_signal Sys.sigint (Sys.Signal_handle terminate);
  Sys.set_signal Sys.sigterm (Sys.Signal_handle terminate);
  Sys.set_signal Sys.sighup (Sys.Signal_handle terminate);
  Sys.set_signal Sys.sigquit (Sys.Signal_handle terminate);
  Sys.set_signal Sys.sigwinch (Sys.Signal_handle request_full_repaint);
  Sys.set_signal Sys.sigcont (Sys.Signal_handle request_full_repaint);
  Sys.set_signal Sys.sigtstp (Sys.Signal_handle suspend);
  Unix.tcsetattr Unix.stdin Unix.TCSANOW new_term

(** Main loop *)
let main () =
  let (base_path, workspace, port, refresh) = parse_args () in
  require_interactive_terminal ();
  let state = create_state ~workspace ~port ~refresh_interval:refresh in
  state.view <- Overview;

  (* Setup terminal *)
  let old_term = Unix.tcgetattr Unix.stdin in
  (* c_icrnl off so Return and Ctrl-J arrive as themselves. With the terminal's
     default translation on, Return is delivered as LF -- the same byte Ctrl-J
     sends -- and the composer cannot tell "send this" from "start a new line".
     LF still submits below if some terminal sends it for Return, so this only
     ever adds a key. *)
  let new_term =
    { old_term with Unix.c_icanon = false; c_echo = false; c_icrnl = false }
  in

  let frame_presenter =
    Frame_presenter.create
      ~synchronized_output:(synchronized_output_enabled ()) ()
  in
  let resize_requested = Atomic.make false in

  let restore_terminal () =
    Frame_presenter.cleanup frame_presenter ~write:(output_string stdout)
      ~flush:(fun () -> flush stdout);
    Unix.tcsetattr Unix.stdin Unix.TCSANOW old_term
  in

  (* Cleanup on exit *)
  let cleanup_started = Atomic.make false in
  let cleanup () =
    if Atomic.compare_and_set cleanup_started false true then begin
      Console_sink.set_after_write_observer None;
      restore_terminal ();
      print_endline "Goodbye!"
    end
  in

  let request_full_repaint _ = Atomic.set resize_requested true in
  let terminate _ = exit 0 in
  let rec suspend _ =
    restore_terminal ();
    Sys.set_signal Sys.sigtstp Sys.Signal_default;
    Fun.protect
      ~finally:(fun () ->
        Sys.set_signal Sys.sigtstp (Sys.Signal_handle suspend);
        Unix.tcsetattr Unix.stdin Unix.TCSANOW new_term;
        request_full_repaint 0)
      (fun () -> Unix.kill (Unix.getpid ()) Sys.sigtstp)
  in
  enter_terminal_session ~cleanup ~terminate ~request_full_repaint ~suspend
    ~new_term;
  let render_schedule =
    Render_schedule.create ~min_interval_ns:frame_interval_ns ()
  in
  if Terminal_write_repair.console_sink_writes_to_terminal () then
    Console_sink.set_after_write_observer
      (Some (fun () -> Terminal_write_repair.note ()));

  (* Initial load *)
  load_from_masc_dir state base_path;
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let http_refresh_inflight = ref false in
  let async_messages = Eio.Stream.create 32 in
  (match Keeper_chat_recovery.load_pending ~base_path with
   | Ok None -> ()
   | Error detail ->
       state.msg_recovery_error <- Some (Recovery_blocked detail);
       add_event state "error"
         ("Keeper chat recovery could not be loaded; new sends are blocked: "
        ^ detail)
   | Ok (Some pending) ->
       Keeper_chat_recovery.resume_pending pending
         ~retry_prepared:(fun request ->
            state.msg_unverified <- None;
            state.msg_prepared <- Some request;
            append_chat_history state request Message_status
              "Recovered a prepared request; claiming its first serialized dispatch";
            add_event state "message"
              (Printf.sprintf "Recovered prepared Keeper request: %s"
                 request.request_id);
            retry_keeper_message state ~base_path ~mailbox:async_messages)
         ~reconcile_dispatching:(fun request ->
            state.msg_prepared <- None;
            remember_unverified state request;
            append_user_history_once state request;
            append_chat_history state request Message_status
              "Recovered an unclassified dispatch; waiting for serialized exact-operation reconciliation without POST";
            add_event state "message"
              (Printf.sprintf "Recovered dispatching Keeper request: %s"
                 request.request_id);
            launch_keeper_request state ~base_path ~mailbox:async_messages request)
         ~retry_replayable:(fun request ->
            state.msg_prepared <- None;
            remember_unverified state request;
            append_chat_history state request Message_status
              "Recovered a replayable request; replaying the exact ID under the cross-process lock";
            add_event state "message"
              (Printf.sprintf "Recovered replayable Keeper request: %s"
                 request.request_id);
            launch_keeper_request state ~base_path ~mailbox:async_messages
              request)
         ~reconcile_accepted:(fun request ->
            remember_unverified state request;
            append_user_history_once state request;
            append_chat_history state request Message_status
              "Recovered an accepted request; reconciling the exact durable operation";
            add_event state "message"
              (Printf.sprintf "Recovered accepted Keeper request: %s"
                 request.request_id);
            launch_keeper_reconciliation state ~mailbox:async_messages request)
         ~cleanup_rejected:(fun request ->
            append_chat_history state request Message_status
              "Recovered a definitively rejected request; removing its durable fence without POST or GET";
            add_event state "message"
              (Printf.sprintf "Recovered rejected Keeper request: %s"
                 request.request_id);
            launch_keeper_cleanup state ~base_path ~mailbox:async_messages
              request));
  start_http_refresh state ~host ~port ~refresh_inflight:http_refresh_inflight
    ~mailbox:async_messages;
  add_event state "system" "TUI started";

  (* Main loop *)
  let refresh_interval_ns =
    Int64.of_float (max 0.0 refresh *. nanoseconds_per_second)
  in
  let last_check_ns = ref (Mtime_clock.elapsed_ns ()) in
  let input_reader = create_input_reader () in
  let run_loop () =
    while true do
      request_console_write_repair render_schedule;
      if Atomic.exchange resize_requested false then begin
        invalidate_frame_for_resize frame_presenter render_schedule
      end;
      if
        drain_async_messages state ~base_path ~http_refresh_inflight
          async_messages
      then Render_schedule.request render_schedule Render_schedule.Background;
      (* Check for input *)
      let input_timeout =
        Render_schedule.input_timeout_seconds render_schedule
          ~now_ns:(Mtime_clock.elapsed_ns ())
          ~maximum:maximum_input_wait_seconds
      in
      let key = read_key ~timeout:input_timeout input_reader () in
      if Option.is_some key then
        Render_schedule.request render_schedule Render_schedule.Input;
      let terminal_rows, _terminal_columns = get_terminal_size () in
      let compact_viewport =
        Render_schedule.Viewport.requires_compact_frame ~rows:terminal_rows
      in
      let message_mode =
        (not compact_viewport) && state.view = Keepers Keeper_message
      in
      (match state.view, key with
       | _ when compact_viewport -> ()
       | Approvals, Some ("y" | "Y" | "n" | "N") -> ()
       | Approvals, Some _ -> state.pending_approval_action <- None
       (* An armed shutdown expires on the next unrelated key. Otherwise it
          waits indefinitely and a later press of the same key -- after the
          cursor has moved, after a refresh -- submits work the operator armed
          minutes ago for something else. *)
       | Keepers _, Some ("s" | "S") -> ()
       | Keepers _, Some _ -> state.keeper_action_pending <- None
       | _ -> ());
      (* The composer sees the key first, and takes it only when it has one to
         take: unfocused it claims a single key, and only with somewhere to
         send. Everything it does not claim reaches the surface with its
         meaning unchanged, so no existing binding moved when the row
         appeared. The chat surface is excluded — it draws its own composer. *)
      let composer_claimed =
        (not compact_viewport)
        && state.view <> Keepers Keeper_message
        &&
        match key with
        | Some k -> handle_composer_key state ~base_path ~mailbox:async_messages k
        | None -> false
      in
      (match key with
       | Some _ when composer_claimed -> ()
       | Some k when Render_schedule.Input_shortcut.is_quit ~message_mode k ->
           raise Break
       | Some _ when compact_viewport -> ()
       | Some k when message_mode ->
           let recovery_key =
             String.length k = 1 && Char.code k.[0] = 18
           in
           if
             keeper_message_input_supported state
             || String.equal k "esc"
             || recovery_key
           then
             let _handled =
               handle_message_key state
                 ~submit_message:
                   (start_keeper_message state ~base_path
                      ~mailbox:async_messages)
                 ~retry_message:(fun () ->
                   retry_keeper_message state ~base_path
                     ~mailbox:async_messages)
                 ~answer_approval:(fun ~tool_call_id ~allow ->
                   match state.msg_inflight with
                   | Some request ->
                       launch_keeper_approval state ~mailbox:async_messages
                         request ~tool_call_id ~allow
                   | None ->
                       (* No request in flight means no turn to answer for.
                          The prompt belongs to a turn, so this is
                          unreachable while one is shown. *)
                       ())
                 ~load_older:(fun ~before ->
                   match state.msg_target_keeper_name with
                   | Some keeper_name ->
                       launch_keeper_older_page state ~mailbox:async_messages
                         ~keeper_name ~before
                   | None -> ())
                 k
             in
             ()
       | Some k
         when (not message_mode)
              && state.view = Board
              && state.board_mode = Board_compose ->
           (* Same shape as the chat pane: while a draft is being written,
              printable keys belong to the draft. Tab falls through so the
              surface cycle keeps working, and quit was answered above. *)
           let _handled = handle_board_compose_key state ~mailbox:async_messages k in
           ()
       | Some k when Render_schedule.Input_shortcut.opens_keepers ~message_mode k ->
           state.view <- Keepers Keeper_list
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
           (* Also reload logs / Board detail if viewing them. *)
           (match state.view with
            | Keepers Keeper_logs ->
                load_selected_keeper_logs state base_path 200
                  (List.nth_opt state.keepers state.keeper_cursor)
            | Board ->
                (match state.board_mode with
                 | Board_read post_id ->
                     start_board_post_refresh state ~host ~port ~post_id
                       ~mailbox:async_messages
                 | Board_list | Board_compose -> ())
            | Keepers Keeper_message ->
                (match state.msg_target_keeper_name with
                 | Some keeper_name ->
                     launch_keeper_history_load state ~mailbox:async_messages
                       ~keeper_name
                 | None -> ())
            | Verification ->
                launch_verification_load state ~mailbox:async_messages
            | Overview | Keepers Keeper_list | Keepers Keeper_detail
            | Approvals | Planning | System_logs -> ());
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
            | Planning ->
                (* Loaded on arrival: the queue is what the surface is, so
                   showing it empty until a refresh would read as "nothing is
                   waiting". *)
                launch_verification_load state ~mailbox:async_messages;
                state.view <- Verification
            | Verification -> state.view <- System_logs
            | System_logs -> state.view <- Overview)
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
                (* While a turn is streaming, Esc interrupts it instead of
                   leaving: leaving is one keypress away again once it settles,
                   and a turn an operator wants stopped is the more urgent of
                   the two. Asking twice does not stack -- the second press is
                   ignored while the first is unanswered. *)
                (match state.msg_live with
                 | Some live
                   when Keeper_chat_transcript.interrupt live
                        = Keeper_chat_transcript.Not_requested ->
                     (match state.msg_inflight with
                      | Some request ->
                          launch_keeper_interrupt state
                            ~mailbox:async_messages request
                      | None ->
                          state.view <- Keepers Keeper_detail;
                          state.detail_scroll <- 0)
                 | Some _ ->
                     (* An interrupt is already outstanding for this turn. *)
                     ()
                 | None ->
                     state.view <- Keepers Keeper_detail;
                     state.detail_scroll <- 0)
            | Board ->
                (match state.board_mode with
                 | Board_read _ ->
                     leave_board_detail state
                 | Board_list | Board_compose -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_detail _ ->
                     state.planning_mode <- Planning_list;
                     state.planning_scroll <- 0
                 | Planning_list -> ())
            | Overview ->
                (* Back out one level: an open task detail closes to the panel,
                   a focused task panel hands j/k back to the event log. *)
                if Option.is_some state.task_detail_id then begin
                  state.task_detail_id <- None;
                  state.task_detail_scroll <- 0
                end
                else state.task_focus <- false
            | Keepers Keeper_list | Approvals | Verification | System_logs -> ())
       | Some "j" | Some "down" ->
           (match state.view with
            | Keepers Keeper_list ->
                if state.keeper_cursor < List.length state.keepers - 1 then begin
                  state.keeper_cursor <- state.keeper_cursor + 1;
                  (match List.nth_opt state.keepers state.keeper_cursor with
                   | Some k -> load_live_context state base_path k
                   | None -> ())
                end
            | Keepers Keeper_detail ->
                state.detail_scroll <- state.detail_scroll + 1
            | Keepers Keeper_logs ->
                state.log_scroll <-
                  Metrics_tail.scroll_down
                    ~entry_count:(List.length state.log_entries)
                    ~content_height:(keeper_log_content_height state)
                    state.log_scroll
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
                     state.board_scroll <- state.board_scroll + 1
                 | Board_compose -> ())
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
            | Overview ->
                if Option.is_some state.task_detail_id then
                  state.task_detail_scroll <- state.task_detail_scroll + 1
                else if state.task_focus then begin
                  if state.task_cursor < List.length state.tasks - 1 then
                    state.task_cursor <- state.task_cursor + 1
                end
                else begin
                  let _, _, row_budget =
                    overview_layout state ~terminal_rows
                  in
                  state.overview_event_scroll <-
                    Render_schedule.scroll_overview_events_older
                      ~event_count:(List.length state.events)
                      ~visible_rows:row_budget.attention_rows
                      state.overview_event_scroll
                end
            | Verification ->
                state.verification_scroll <- state.verification_scroll + 1
            | System_logs -> state.system_logs_scroll <- state.system_logs_scroll + 1
            | Keepers Keeper_message -> ())
       | Some "k" | Some "up" ->
           (match state.view with
            | Keepers Keeper_list ->
                if state.keeper_cursor > 0 then begin
                  state.keeper_cursor <- state.keeper_cursor - 1;
                  (match List.nth_opt state.keepers state.keeper_cursor with
                   | Some k -> load_live_context state base_path k
                   | None -> ())
                end
            | Keepers Keeper_detail ->
                if state.detail_scroll > 0 then
                  state.detail_scroll <- state.detail_scroll - 1
            | Keepers Keeper_logs ->
                state.log_scroll <-
                  Metrics_tail.scroll_up
                    ~entry_count:(List.length state.log_entries)
                    ~content_height:(keeper_log_content_height state)
                    state.log_scroll
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
                       state.board_scroll <- state.board_scroll - 1
                 | Board_compose -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_list ->
                     if state.planning_cursor > 0 then
                       state.planning_cursor <- state.planning_cursor - 1
                 | Planning_detail _ ->
                     if state.planning_scroll > 0 then
                       state.planning_scroll <- state.planning_scroll - 1)
            | Overview ->
                if Option.is_some state.task_detail_id then begin
                  if state.task_detail_scroll > 0 then
                    state.task_detail_scroll <- state.task_detail_scroll - 1
                end
                else if state.task_focus then begin
                  if state.task_cursor > 0 then
                    state.task_cursor <- state.task_cursor - 1
                end
                else begin
                  let _, _, row_budget =
                    overview_layout state ~terminal_rows
                  in
                  state.overview_event_scroll <-
                    Render_schedule.scroll_overview_events_newer
                      ~event_count:(List.length state.events)
                      ~visible_rows:row_budget.attention_rows
                      state.overview_event_scroll
                end
            | Verification ->
                if state.verification_scroll > 0 then
                  state.verification_scroll <- state.verification_scroll - 1
            | System_logs ->
                if state.system_logs_scroll > 0 then
                  state.system_logs_scroll <- state.system_logs_scroll - 1
            | Keepers Keeper_message -> ())
       | Some "\r" | Some "\n" ->
           (* Enter opens detail from list *)
           (match state.view with
            | Overview ->
                (* Only under task focus: Enter while the events own j/k would
                   open whatever row the cursor happens to rest on. *)
                if state.task_focus then
                  (match List.nth_opt state.tasks state.task_cursor with
                   | Some task ->
                       state.task_detail_id <- Some task.id;
                       state.task_detail_scroll <- 0
                   | None -> ())
            | Keepers Keeper_list ->
                (match List.nth_opt state.keepers state.keeper_cursor with
                 | Some k ->
                     state.view <- Keepers Keeper_detail;
                     state.detail_scroll <- 0;
                     load_live_context state base_path k;
                     load_selected_keeper_logs state base_path 200 (Some k)
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
                            ~mailbox:async_messages
                      | None -> ())
                 | Board_read _ | Board_compose -> ())
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
            | Keepers Keeper_detail | Keepers Keeper_logs | Keepers Keeper_message
            | Approvals | Verification | System_logs -> ())
       | Some "t" | Some "T" ->
           (* Focus the Overview task panel. The list is always on screen, but
              j/k belong to the event log until the operator asks for tasks. *)
           (match state.view with
            | Overview when Option.is_none state.task_detail_id ->
                state.task_focus <- not state.task_focus;
                if not state.task_focus then state.task_cursor <- 0
            | Overview | Keepers _ | Board | Approvals | Planning
            | Verification | System_logs -> ())
       | Some "l" | Some "L" ->
           (* Logs, from the roster as well as from detail, for the same reason
              chat is reachable from both: the keeper an operator wants the
              logs of is the one under the cursor. *)
           (match state.view with
            | Keepers (Keeper_list | Keeper_detail) ->
                let keeper = selected_keeper state in
                load_selected_keeper_logs state base_path 200 keeper;
                (match keeper with
                 | Some _ ->
                     state.log_scroll <-
                       Metrics_tail.maximum_scroll
                         ~entry_count:(List.length state.log_entries)
                         ~content_height:(keeper_log_content_height state);
                     state.view <- Keepers Keeper_logs
                 | None -> ())
            | Overview | Keepers Keeper_logs | Keepers Keeper_message
            | Board | Approvals | Planning | Verification | System_logs -> ())
       | Some "m" | Some "M" | Some "c" | Some "C" ->
           (* Chat, from detail only. Opening detail is the act that names the
              target: on the roster the cursor moves by itself when a refresh
              drops a row, so a keeper that disappears while the operator is
              reaching for this key would hand the message to whichever keeper
              slid under the cursor. [c] is an alias for [m] because the footer
              names the action rather than the mnemonic. *)
           (match state.view with
            | Keepers Keeper_detail
              when Option.is_none state.keepers_error
                   && state.keeper_cursor < List.length state.keepers ->
                let keeper = List.nth state.keepers state.keeper_cursor in
                open_message_for_keeper state keeper.k_name;
                launch_keeper_history_load state ~mailbox:async_messages
                  ~keeper_name:keeper.k_name;
                state.view <- Keepers Keeper_message
            | Keepers Keeper_detail | Keepers Keeper_list
            | Overview | Keepers Keeper_logs | Keepers Keeper_message
            | Board | Approvals | Planning | Verification | System_logs -> ())
       | Some "p" | Some "P" ->
           (* The toggle: whichever of pause / resume / boot this reading
              offers first. One key for "stop" and "play" because which one
              applies is a fact about the keeper, not a choice the operator
              should have to make. *)
           (match state.view with
            | Keepers (Keeper_list | Keeper_detail) -> (
                match
                  Option.map (keeper_reading state) (selected_keeper state)
                  |> Option.map Keeper_control.primary
                with
                | Some (Some action) ->
                    handle_keeper_action state ~base_path
                      ~mailbox:async_messages action
                | Some None ->
                    add_event state "system"
                      "No lifecycle action applies to this keeper yet"
                | None -> ())
            | Overview | Keepers Keeper_logs | Keepers Keeper_message
            | Board | Approvals | Planning | Verification | System_logs -> ())
       | Some "s" | Some "S" ->
           (match state.view with
            | Keepers (Keeper_list | Keeper_detail) ->
                handle_keeper_action state ~base_path ~mailbox:async_messages
                  Keeper_control.Shutdown
            | Overview | Keepers Keeper_logs | Keepers Keeper_message
            | Board | Approvals | Planning | Verification | System_logs -> ())
       | Some "w" | Some "W" ->
           (* Two unrelated bindings share a key: "write" on the Board list,
              "wake up" on a keeper row. The surface decides which one is
              live, and Board compose takes the key only from the list --
              inside the compose pane the letter is draft text. *)
           (match state.view with
            | Board ->
                (match state.board_mode with
                 | Board_list ->
                     state.board_mode <- Board_compose;
                     state.board_compose_armed <- false;
                     state.board_post_error <- None
                 | Board_read _ | Board_compose -> ())
            | Keepers (Keeper_list | Keeper_detail) ->
                handle_keeper_action state ~base_path ~mailbox:async_messages
                  Keeper_control.Wakeup
            | Overview | Keepers Keeper_logs | Keepers Keeper_message
            | Approvals | Planning | Verification | System_logs -> ())
      | _ -> ());

      Eio.Fiber.yield ();
      if
        drain_async_messages state ~base_path ~http_refresh_inflight
          async_messages
      then Render_schedule.request render_schedule Render_schedule.Background;

      (* Periodic refresh *)
      let now_ns = Mtime_clock.elapsed_ns () in
      if
        Int64.compare (Int64.sub now_ns !last_check_ns) refresh_interval_ns >= 0
      then begin
        state.pending_approval_action <- None;
        load_from_masc_dir state base_path;
        let host = Env_config_core.masc_host () in
        let port = state.port in
        start_http_refresh state ~host ~port
          ~refresh_inflight:http_refresh_inflight
          ~mailbox:async_messages;
        (* Also refresh logs / Board detail if viewing them. *)
        (match state.view with
         | Keepers (Keeper_logs | Keeper_detail) ->
             load_selected_keeper_logs state base_path 200
               (List.nth_opt state.keepers state.keeper_cursor)
         | Board ->
             (match state.board_mode with
              | Board_read post_id ->
                  start_board_post_refresh state ~host ~port ~post_id
                    ~mailbox:async_messages
              | Board_list | Board_compose -> ())
         | Verification ->
             (* The queue moves while an operator watches it -- a task settles,
                another arrives. Refreshed on the same tick as the surfaces
                above rather than only on a keypress. *)
             launch_verification_load state ~mailbox:async_messages
         | Overview | Keepers Keeper_list | Keepers Keeper_message
         | Approvals | Planning | System_logs -> ());
        last_check_ns := now_ns;
        Render_schedule.request render_schedule Render_schedule.Background
      end;

      (match
         Render_schedule.take render_schedule
           ~now_ns:(Mtime_clock.elapsed_ns ())
       with
       | Render_schedule.Render ->
           let frame = render state in
           Frame_presenter.present frame_presenter
             ~invalidate_before:(Terminal_write_repair.consume_damage ())
             ~write:(output_string stdout)
             ~flush:(fun () -> flush stdout) frame
       | Render_schedule.Idle | Render_schedule.Wait_until _ -> ())
    done
  in
  run_loop ()

let run_with_eio_context f =
  try
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            Eio_guard.enable ();
            Eio.Switch.on_release sw Eio_guard.disable;
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            Eio_context.set_env env;
            Eio_context.set_switch sw;
            Eio_context.set_net (Eio.Stdenv.net env);
            Eio_context.set_clock (Eio.Stdenv.clock env);
            Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
            f ()))
  with Break -> ()

let () = run_with_eio_context main
