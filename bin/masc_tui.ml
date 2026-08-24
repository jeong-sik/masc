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
(* What one wheel detent moves. Terminals report three lines per detent, so a
   notch here is worth what a notch is worth in a pager. *)
let wheel_notch_rows = 3

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

(* The bound comes from [scrolled_surface], which the drawing reads too, so a
   keypress cannot move past what the frame can show. Surfaces the state
   cannot count keep their old unbounded step; the drawing still clamps those
   on the way past. *)
let move_surface_scroll (state : state) ~rows ~delta ~current =
  match scrolled_surface state state.view with
  | None -> current + delta
  | Some { sc_count; sc_chrome } ->
      let height = max 1 (rows - sc_chrome) in
      if delta >= 0 then Masc_tui_scroll.down ~count:sc_count ~height current
      else Masc_tui_scroll.up ~count:sc_count ~height current

(* The rows a surface has to draw in: the terminal's, less the composer's,
   which owns the last row. The same arithmetic the drawing does -- a bound
   worked out from a different height than the frame uses is not a bound.
   Reading the terminal's own rows here, as this did, left the log surface's
   keypress bound one row looser than the frame it moved within. *)
let surface_rows () =
  let terminal_rows, _columns = get_terminal_size () in
  max 1 (terminal_rows - Composer.rows_for ~terminal_rows)

let keeper_log_content_height (state : state) =
  Metrics_tail.content_height ~terminal_rows:(surface_rows ())
    ~error:state.log_error

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
               (* A parameter span starting with [<] is an SGR mouse report.
                  Wheel reports become the same keys the arrows make, so every
                  surface's scroll binding answers the wheel; a report nothing
                  consumes stays unclaimed rather than leaking into a key. *)
               | Some (params, final)
                 when String.length params > 0 && params.[0] = '<' -> (
                   match Masc.Tui_decode.sgr_wheel_key params final with
                   | Some key -> Some key
                   | None -> Some "unknown-esc")
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

let open_message_for_keeper ?(return_to = Keeper_chat_return_detail) state
    keeper_name =
  save_message_draft state;
  state.msg_target_keeper_name <- Some keeper_name;
  state.msg_return <- return_to;
  Buffer.clear state.msg_input;
  List.assoc_opt keeper_name state.msg_drafts
  |> Option.iter (Buffer.add_string state.msg_input)

let leave_keeper_message state =
  save_message_draft state;
  let target_registered =
    match state.msg_target_keeper_name with
    | Some keeper_name -> keeper_available_for_new_message state keeper_name
    | None -> false
  in
  state.view <-
    Keepers
      (match state.msg_return, target_registered with
       | Keeper_chat_return_detail, true -> Keeper_detail
       | Keeper_chat_return_list, _ | Keeper_chat_return_detail, false ->
           Keeper_list);
  state.detail_scroll <- 0;
  if not target_registered then state.log_scroll <- 0

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

(* What this pane has sent to the keeper on screen, oldest first. The arrows
   walk it the way a shell walks its own history. That is why the wheel no
   longer arrives as the same key: one of the two had to be wrong while they
   shared it, and scrolling has the wheel and the page keys. *)
let own_sent_messages (state : state) =
  let target = Option.value ~default:"" state.msg_target_keeper_name in
  state.msg_history
  |> List.filter (fun entry ->
         (match entry.me_role with
          | Message_user label -> String.equal label "you"
          | Message_keeper | Message_status | Message_error | Message_tool
          | Message_thinking ->
              false)
         && String.equal entry.me_keeper_name target)
  |> List.map (fun entry -> entry.me_text)

let set_composer_text (state : state) text =
  Buffer.clear state.msg_input;
  Buffer.add_string state.msg_input text

(* The draft is put aside on the first step back and handed over on the way
   forward past the newest, so a walk through the history never costs what was
   already typed. *)
let recall_older (state : state) =
  let sent = own_sent_messages state in
  let count = List.length sent in
  if count = 0 then ()
  else begin
    let at =
      match state.msg_recall_at with
      | None ->
          state.msg_recall_draft <- Buffer.contents state.msg_input;
          0
      | Some at -> min (at + 1) (count - 1)
    in
    state.msg_recall_at <- Some at;
    set_composer_text state (List.nth sent (count - 1 - at))
  end

let recall_newer (state : state) =
  match state.msg_recall_at with
  | None -> ()
  | Some 0 ->
      state.msg_recall_at <- None;
      set_composer_text state state.msg_recall_draft
  | Some at ->
      let sent = own_sent_messages state in
      let at = at - 1 in
      state.msg_recall_at <- Some at;
      let count = List.length sent in
      if count > at then set_composer_text state (List.nth sent (count - 1 - at))

(* Typing makes the composer the operator's again: the walk is over, so a step
   forward must not replace what they just wrote with a draft from before it. *)
let forget_recall (state : state) = state.msg_recall_at <- None

let handle_message_key (state : state) ~(submit_message : string -> unit)
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
    leave_keeper_message state;
    true
  | "\r" ->
    let text = Buffer.contents state.msg_input in
    if String.trim text <> "" then begin
      (* Back to the newest row: the turn that is about to start is drawn
         there, and staying scrolled back would hide the send. *)
      state.msg_scroll <- 0;
      forget_recall state;
      submit_message text
    end;
    true
  | "\n" ->
    (* Ctrl-J, or Return on a terminal that still translates it. A composer
       that cannot hold two lines makes an operator send two messages for one
       thought. *)
    forget_recall state;
    Buffer.add_char state.msg_input '\n';
    true
  | "up" ->
    recall_older state;
    true
  | "down" ->
    recall_newer state;
    true
  | "wheel-up" ->
    (* A notch is worth more than a row. The wheel used to arrive as the arrow
       key and moved one row with it, so reading back through a keeper turn --
       hundreds of rows -- took hundreds of notches. Three is what a terminal
       reports per detent, so a notch here covers what a notch covers
       everywhere else. *)
    state.msg_scroll <- state.msg_scroll + wheel_notch_rows;
    (match state.msg_older_cursor with
     | Some before when state.msg_older_exist && not state.msg_older_loading ->
         load_older ~before
     | Some _ | None -> ());
    true
  | "wheel-down" ->
    state.msg_scroll <- max 0 (state.msg_scroll - wheel_notch_rows);
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
    forget_recall state;
    let new_content =
      Buffer.contents state.msg_input
      |> Masc_tui_message_layout.drop_last_utf8_scalar
    in
    Buffer.clear state.msg_input;
    Buffer.add_string state.msg_input new_content;
    true
  | s ->
    let c = if String.length s = 1 then Some (Char.code s.[0]) else None in
    (* Ctrl-R reconnected an unverified request against the durable fence.
       Both are gone: the server keys operations by request id and the
       transcript reloads after every settle, so there is nothing here for a
       key to reconcile. *)
    if c = Some 21 then begin
      (* Ctrl-U: clear the composer *)
      Buffer.clear state.msg_input;
      true
    end else if c = Some 5 then begin
      (* Ctrl-E: back to the newest row. Scrolling down one row at a time from
         far back is worse than a key that ends the trip. *)
      state.msg_scroll <- 0;
      true
    end else if c = Some 11 then begin
      (* Ctrl-K: drop the newest waiting line without sending it. The queue
         shows what waits in the order it will go; the newest is the one a
         mis-send just hit, and dropping it is local — nothing was
         dispatched. *)
      (match Chat_queue.take_newest state.msg_queued with
       | None -> () (* nothing waits; consume quietly like Ctrl-U on empty *)
       | Some ((queued_keeper, _), rest) ->
         state.msg_queued <- rest;
         add_event state "info"
           (Printf.sprintf "Cancelled queued message to %s"
              (Keeper_chat.terminal_safe_text queued_keeper)));
      true
    end else if c = Some 16 then begin
      (* Ctrl-P: pull the newest waiting line back into the composer. That is
         the edit: fix it and Enter queues it again. *)
      (match Chat_queue.take_newest state.msg_queued with
       | None -> ()
       | Some ((_, text), rest) ->
         state.msg_queued <- rest;
         Buffer.clear state.msg_input;
         Buffer.add_string state.msg_input text);
      true
    end else if Masc_tui_message_layout.is_printable_utf8_scalar s then begin
      forget_recall state;
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
  (* [None] on surfaces that do not draw them. Each is read by one surface, and
     leaving it out keeps whatever that surface last observed rather than
     dropping it. *)
  http_board: (board_post list, string) result option;
  http_planning: (planning_snapshot, string) result option;
  http_system_logs: (system_log_snapshot, string) result option;
  http_fleet_safety: (Tui_decode.fleet_safety, string) result option;
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
      int * string * (Keeper_chat_history.decoded, string) result
  | Keeper_chat_older_loaded of
      int * string * float * (Keeper_chat_history.page, string) result
  | Lanes_loaded of (Masc.Tui_decode.keeper_lanes_snapshot, string) result
  | Verification_loaded of (Masc.Tui_decode.verification_snapshot, string) result
  | Harness_loaded of (Masc.Tui_decode.harness_snapshot, string) result
  | Repositories_loaded of (Masc.Tui_decode.repository_snapshot, string) result
  | Connectors_loaded of (Masc.Tui_decode.connector_snapshot, string) result
  | Tools_loaded of (Masc.Tui_decode.tool_snapshot, string) result
  | Keeper_chat_approval_answered of
      Keeper_chat.request * string * bool * (bool, string) result
  | Keeper_tool_approvals_loaded of
      (Tui_decode.keeper_tool_approval list, string) result
  | Surface_tool_approval_answered of
      string * string * bool * (bool, string) result
  | Keeper_tool_modes_loaded of ((string * string) list, string) result
  | Keeper_tool_mode_set of string * string * (unit, string) result
      (** keeper, tool call id, allow, and whether a wait was released — the
          Approvals-surface twin of [Keeper_chat_approval_answered], which
          needs the chat request this path does not have. *)
  | Keeper_chat_dispatch_blocked of Keeper_chat.request * string
  | Keeper_action_done of
      string
      * Keeper_control.action
      * (Keeper_control.outcome, string) result
  | Board_new_post_done of (string, string) result
  | Board_vote_done of (string, string) result
  | Goal_transition_done of (string, string) result
  | Schedules_loaded of (schedule_snapshot, string) result
  | Schedule_cancel_done of (string, string) result
  | Keeper_calls_loaded of
      string * (Masc.Tui_decode.keeper_calls_snapshot, string) result
  | Observer_opened of string
  | Observer_received of Masc_tui_observer.decoded list
  | Observer_closed of string
  | Task_dispatched of {
      keeper : string;
      task_id : string;
      title : string;
      body : string;
    }
  | Task_dispatch_failed of {
      keeper : string;
      detail : string;
      original : string;
    }

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
(* The Approvals-surface twin of [launch_keeper_approval]: same route, no chat
   request to correlate with, so the outcome lands in Recent Events instead of
   a pane's transcript. *)
let launch_surface_tool_approval state ~mailbox ~keeper_name ~tool_call_id
    ~allow =
  let host = Env_config_core.masc_host () in
  let port = state.port in
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
      (Surface_tool_approval_answered (keeper_name, tool_call_id, allow, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Surface_tool_approval_answered
           (keeper_name, tool_call_id, allow, Error "Eio switch is unavailable"))

(* Fetch the held tool calls for the Approvals surface. Its own fiber for the
   same reason every loader runs on one: a slow server costs the refresh, not
   the keypress. *)
let launch_keeper_tool_approvals_load state ~mailbox =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_keeper_tool_approvals ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_tool_approvals_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_tool_approvals_loaded (Error "Eio switch is unavailable"))

let launch_keeper_tool_modes_load state ~mailbox =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_keeper_tool_approval_modes ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_tool_modes_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_tool_modes_loaded (Error "Eio switch is unavailable"))

let launch_keeper_tool_mode_set state ~mailbox ~keeper_name ~mode =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try
        Masc_tui_http.post_keeper_tool_approval_mode ~host ~port ~keeper_name
          ~mode
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_tool_mode_set (keeper_name, mode, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_tool_mode_set
           (keeper_name, mode, Error "Eio switch is unavailable"))

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
let launch_tools_load state ~mailbox =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_tools ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Tools_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (Tools_loaded (Error "Eio switch is unavailable"))

let launch_schedules_load state ~mailbox =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_schedules ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Schedules_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox (Schedules_loaded (Error "Eio switch is unavailable"))

(* The durable call log of one keeper, over HTTP. The row the answer is
   applied to is named in the message so a load that returns after the
   operator moved to another keeper is discarded, not drawn under it. *)
let launch_keeper_calls_load state ~mailbox keeper_name =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_http.fetch_keeper_calls ~host ~port ~keeper_name ~limit:100
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_calls_loaded (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_calls_loaded (keeper_name, Error "Eio switch is unavailable"))

let launch_connectors_load state ~mailbox =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_connectors ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Connectors_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox (Connectors_loaded (Error "Eio switch is unavailable"))

let launch_repositories_load state ~mailbox =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_repositories ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Repositories_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Repositories_loaded (Error "Eio switch is unavailable"))

let launch_harness_load state ~mailbox =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_harness ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Harness_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (Harness_loaded (Error "Eio switch is unavailable"))

let launch_lanes_load state ~mailbox =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_keeper_lanes ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Lanes_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (Lanes_loaded (Error "Eio switch is unavailable"))

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
  let generation = state.msg_history_load_generation in
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
    enqueue_async mailbox
      (Keeper_chat_older_loaded (generation, keeper_name, before, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_older_loaded
           (generation, keeper_name, before, Error "Eio switch is unavailable"))

let launch_keeper_history_load state ~mailbox ~keeper_name =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  state.msg_history_load_generation <- state.msg_history_load_generation + 1;
  state.msg_older_loading <- false;
  let generation = state.msg_history_load_generation in
  let run () =
    let result =
      try Masc_tui_http.fetch_keeper_chat_history ~host ~port ~keeper_name with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (Keeper_chat_history_loaded (generation, keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_history_loaded
           (generation, keeper_name, Error "Eio switch is unavailable"))

let switch_to_next_keeper_message state ~mailbox =
  match next_keeper_message_target state with
  | Masc_tui_keeper_selection.No_alternative -> ()
  | Masc_tui_keeper_selection.Switch_to { keeper_name; cursor } ->
      open_message_for_keeper ~return_to:state.msg_return state keeper_name;
      state.keeper_cursor <- cursor;
      state.msg_scroll <- 0;
      state.msg_loaded <- [];
      state.msg_loaded_keeper <- None;
      state.msg_loaded_error <- None;
      state.msg_loaded_dropped <- 0;
      state.msg_older_cursor <- None;
      state.msg_older_exist <- false;
      state.msg_older_loading <- false;
      state.msg_older_error <- None;
      launch_keeper_history_load state ~mailbox ~keeper_name

(* Rows this session wrote that the transcript now carries. Dropped so the same
   turn is not drawn twice, once from each source.

   Four roles go on sight: the server holds every user line, keeper line, tool
   block and reasoning block.

   Errors used to be kept on sight for the opposite reason. Most are notices
   the server has no row for -- a blocked dispatch, a recovery fence waiting on
   Ctrl-R -- and dropping those loses the only record of them. A failed turn is
   the overlap the server does record, so it showed twice, which was the price
   of not being able to tell the two apart.

   The transcript can say which it is. The server persists a failed turn under
   the operation it ran, and that operation is the id this session dispatched
   under, so a session error row goes exactly when the transcript arrives
   carrying one for its request. Until then it stays -- a persist the server
   could not finish never produces that row, and the session keeps the only
   record, which is what keeping every error row was protecting. *)
let forget_session_rows_the_transcript_holds state keeper_name rows =
  let failures_the_transcript_holds =
    List.filter_map
      (fun (row : Keeper_chat_history.row) ->
        match row.Keeper_chat_history.kind with
        | Keeper_chat_history.Delivery_failed { origin_request_id } ->
            origin_request_id
        | Keeper_chat_history.Addressed_to_keeper _
        | Keeper_chat_history.Said_by_keeper | Keeper_chat_history.Tool_calls _
        | Keeper_chat_history.Reasoning _ -> None)
      rows
  in
  state.msg_history <-
    List.filter
      (fun entry ->
        (not (String.equal entry.me_keeper_name keeper_name))
        ||
        match entry.me_role with
        | Message_status -> true
        | Message_error ->
            String.equal entry.me_request_id ""
            || not
                 (List.exists
                    (String.equal entry.me_request_id)
                    failures_the_transcript_holds)
        | Message_user _ | Message_keeper | Message_tool | Message_thinking ->
            false)
      state.msg_history

let msg_entry_of_history_row keeper_name (row : Keeper_chat_history.row) =
  let role, text =
    match row.Keeper_chat_history.kind with
    | Keeper_chat_history.Addressed_to_keeper { speaker; surface } ->
        ( Message_user (Keeper_chat_history.addressed_label speaker surface)
        , row.text )
    | Keeper_chat_history.Said_by_keeper -> (Message_keeper, row.text)
    | Keeper_chat_history.Delivery_failed _ -> (Message_error, row.text)
    | Keeper_chat_history.Tool_calls rows ->
        (Message_tool, String.concat "\n" rows)
    | Keeper_chat_history.Reasoning lines ->
        (Message_thinking, String.concat "\n" lines)
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

let inflight_for state keeper_name =
  Option.map
    (fun entry -> entry.sent_request)
    (List.find_opt
       (fun entry -> String.equal entry.sent_request.keeper_name keeper_name)
       state.msg_inflight)
;;

let inflight_by_request_id state request_id =
  Option.map
    (fun entry -> entry.sent_request)
    (List.find_opt
       (fun entry -> String.equal entry.sent_request.request_id request_id)
       state.msg_inflight)
;;

let drop_inflight state request =
  state.msg_inflight <-
    List.filter
      (fun entry ->
        not (Keeper_chat.same_request_identity entry.sent_request request))
      state.msg_inflight
;;

(* POST the request. There is no durable claim to take first: the server keys
   every chat operation by this request's id and refuses a second submission of
   it ([Keeper_chat_operation_store.submit] answers [Existing] for a repeat and
   [Idempotency_conflict] for the same id with different content), so a resend
   cannot produce a second turn. The client used to hold its own five-phase
   fence to prevent exactly that, and the price was one un-acknowledged POST
   per workspace — talking to one keeper stopped every other. *)
let launch_keeper_request state ~mailbox request =
  state.msg_inflight <-
    { sent_request = request; sent_at = Unix.gettimeofday () }
    :: state.msg_inflight;
  let run () =
    if enqueue_dispatch_start mailbox request false
    then begin
      let result =
        try post_keeper_chat_watching ~mailbox ~port:state.port request with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Keeper_chat.Transport_error (Printexc.to_string exn))
      in
      enqueue_dispatch_ack mailbox (fun acknowledge ->
        Keeper_chat_done (request, false, result, acknowledge))
    end
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

let queue_keeper_message state ~keeper_name text =
  match Chat_queue.push state.msg_queued ~keeper_name text with
  | Error _ as error -> error
  | Ok (queue, waiting) ->
      state.msg_queued <- queue;
      Ok waiting
;;

(* Send one line to one keeper.

   The refusals here are about whether the message can be delivered at all: no
   keeper selected, a roster this build could not read, a keeper that is no
   longer registered. What used to sit above them — a prepared fence, an
   unverified outcome, a blocked recovery, each with its own Ctrl-R — is gone
   with the fence that produced them. *)
let start_keeper_message ?keeper_name state ~mailbox text =
  match
    match keeper_name with
    | Some _ -> keeper_name
    | None -> state.msg_target_keeper_name
  with
  | None -> add_event state "error" "Cannot send: no Keeper is selected"
  | Some _ when Option.is_some state.keepers_error ->
      add_event state "error"
        "Cannot send while the Keeper roster is unavailable"
  | Some target when not (keeper_available_for_new_message state target) ->
      add_event state "error"
        (Printf.sprintf "Cannot send: Keeper %s is no longer registered"
           (Keeper_chat.terminal_safe_text target))
  | Some target -> (
      (* Read through [send_disposition] rather than the state directly: the
         footer answers the same question the same way, and the two drifting
         apart is what put "Enter:blocked" on a screen that also said
         "queued 1". *)
      match send_disposition state ~keeper_name:target with
      | Sends ->
          let request =
            Keeper_chat.create_request ~keeper_name:target ~message:text
          in
          launch_keeper_request state ~mailbox request
      | Queues_behind request -> (
          (* A turn to this keeper is already running. Hold the line rather than
             refusing it: the operator pressed Enter meaning "send this next",
             and the turn settling is what "next" is. *)
          match queue_keeper_message state ~keeper_name:target text with
          | Error detail -> add_event state "error" detail
          | Ok waiting ->
              clear_current_message_draft state;
              add_event state "message"
                (Printf.sprintf "Queued for %s behind %s (%d waiting)"
                   (Keeper_chat.terminal_safe_text target)
                   request.Keeper_chat.request_id waiting)))
;;

let drain_queued_message state ~mailbox =
  (* Send everything that can go now, oldest first, skipping lines whose own
     keeper still has a turn running. Sending sets that keeper's in-flight, so
     the next pass will not pick it again and the walk terminates.

     Taking strictly from the front would stall the queue behind a busy
     keeper — and permanently, because the lines behind it are addressed to
     keepers that are idle and so have no settle coming to drain them.

     Recursion stays inside so the exported name has no self-call: a wiring
     test that counts calls to it would otherwise be satisfied by this
     function calling itself, and pass with nothing else calling it at all. *)
  let rec next () =
    match
      Chat_queue.take_first_sendable state.msg_queued ~sendable:(fun keeper_name ->
        Option.is_none (inflight_for state keeper_name))
    with
    | None -> ()
    | Some ((keeper_name, text), rest) ->
        if keeper_available_for_new_message state keeper_name
        then (
          state.msg_queued <- rest;
          start_keeper_message ~keeper_name state ~mailbox text;
          next ())
        else (
          (* The keeper this was written to is no longer registered. Sending it
             would fail; holding it would leave a count reporting work that
             never moves. Say what is being let go, and let it go. *)
          let before = Chat_queue.length state.msg_queued in
          state.msg_queued <-
            Chat_queue.drop_for_keeper state.msg_queued ~keeper_name;
          add_event state "error"
            (Printf.sprintf
               "Keeper %s is no longer registered; %d queued message(s) for it \
                were not sent"
               (Keeper_chat.terminal_safe_text keeper_name)
               (before - Chat_queue.length state.msg_queued));
          next ())
  in
  next ()
;;

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

(* /task in the composer or the chat pane: create the task first, then hand
   the keeper the operator's words with the task id in front. Creation runs
   on a daemon fiber; only the mailbox result mutates state. The MCP session
   is the one the observer feed keeps; without one, this call opens one and
   the observer reuses it. *)
let launch_task_dispatch state ~mailbox ~keeper_name ~title ~body ~original =
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let session = state.mcp_session in
  (* A JSON-RPC id for this one call: the answer must name it back. Wall
     clock is identity enough for correlation on a single request. *)
  let request_id = Printf.sprintf "tui-task-%.6f" (Unix.gettimeofday ()) in
  let run () =
    let result =
      try
        let session_result =
          match session with
          | Some session_id -> Ok session_id
          | None ->
              Masc_tui_http.open_mcp_session ~host ~port
                ~client_version:Runtime_build_version.current
        in
        match session_result with
        | Error detail -> Error detail
        | Ok session_id -> (
            let arguments =
              ("title", `String title)
              ::
              (if String.trim body = "" then []
               else [ ("description", `String body) ])
            in
            match
              Masc_tui_http.call_mcp_tool ~host ~port ~session_id ~request_id
                ~tool:"masc_add_task" ~arguments
            with
            | Error detail -> Error detail
            | Ok outcome ->
                if outcome.Masc_tui_mcp.is_error then
                  Error outcome.Masc_tui_mcp.text
                else Masc_tui_mcp.task_id_of_add_task outcome.Masc_tui_mcp.text)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (match result with
       | Ok task_id ->
           Task_dispatched { keeper = keeper_name; task_id; title; body }
       | Error detail ->
           Task_dispatch_failed { keeper = keeper_name; detail; original })
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Task_dispatch_failed
           { keeper = keeper_name
           ; detail = "Eio switch is unavailable"
           ; original
           })

(* One reading of what the operator typed, wherever they typed it: the
   composer row or the chat pane's input. Text goes to the keeper as it
   always did; a slash word is the TUI's to act on, and a mistyped one is
   reported rather than sent to the keeper as an instruction. *)
(* A command's answer, drawn into the pane the operator typed it in. Recent
   Events lives on another surface, and a /help answered there is a /help
   that looks ignored. Falls back to the event log when the pane has no
   keeper to file the row under. *)
let chat_notice state ~keeper_name ~role text =
  match keeper_name with
  | Some keeper ->
      state.msg_history <-
        state.msg_history
        @ [ {
              me_role = role;
              me_text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text;
              me_timestamp = current_clock_text ();
              me_keeper_name = keeper;
              me_request_id = "";
              me_at = Unix.gettimeofday ();
            } ]
  | None ->
      add_event state
        (match role with Message_error -> "error" | _ -> "system")
        text

let send_operator_text ?keeper_name state ~mailbox text =
  let target =
    match keeper_name with
    | Some _ as named -> named
    | None -> state.msg_target_keeper_name
  in
  let notice = chat_notice state ~keeper_name:target in
  match Masc_tui_command.parse text with
  | Masc_tui_command.Say _ ->
      start_keeper_message ?keeper_name state ~mailbox text
  | Masc_tui_command.Task_missing_title ->
      add_event state "error" "/task needs a title on the same line"
  | Masc_tui_command.Help ->
      Buffer.clear state.msg_input;
      notice ~role:Message_status
        (String.concat "\n" Masc_tui_command.help_lines)
  | Masc_tui_command.Switch_keeper_missing_name ->
      notice ~role:Message_error "/keeper needs a name on the same line"
  | Masc_tui_command.Switch_keeper name -> (
      let names =
        List.map (fun (keeper : keeper) -> keeper.k_name) state.keepers
      in
      match Masc_tui_command.resolve_keeper_name ~names name with
      | Masc_tui_command.Keeper_found keeper_name ->
          Buffer.clear state.msg_input;
          open_message_for_keeper ~return_to:state.msg_return state keeper_name;
          launch_keeper_history_load state ~mailbox ~keeper_name;
          state.view <- Keepers Keeper_message
      | Masc_tui_command.Keeper_ambiguous candidates ->
          notice ~role:Message_error
            (Printf.sprintf "%S names more than one keeper: %s" name
               (String.concat ", " candidates))
      | Masc_tui_command.Keeper_unknown ->
          notice ~role:Message_error
            (Printf.sprintf "no keeper named %S on the roster" name))
  | Masc_tui_command.Interrupt_turn -> (
      Buffer.clear state.msg_input;
      match state.msg_live with
      | Some live
        when Keeper_chat_transcript.interrupt live
             = Keeper_chat_transcript.Not_requested -> (
          match
            inflight_by_request_id state
              (Keeper_chat_transcript.request_id live)
          with
          | Some request -> launch_keeper_interrupt state ~mailbox request
          | None -> notice ~role:Message_status "no turn of this pane's to interrupt")
      | Some _ ->
          notice ~role:Message_status
            "an interrupt is already outstanding for this turn"
      | None -> notice ~role:Message_status "no turn is streaming in this pane")
  | Masc_tui_command.Toggle_thinking ->
      Buffer.clear state.msg_input;
      state.msg_thinking_collapsed <- not state.msg_thinking_collapsed;
      notice ~role:Message_status
        (if state.msg_thinking_collapsed
         then "reasoning folded (/thinking to unfold)"
         else "reasoning unfolded (/thinking to fold)")
  | Masc_tui_command.Unknown word ->
      add_event state "error"
        (Printf.sprintf
           "unknown command /%s (text is sent as typed; /help lists commands)"
           word)
  | Masc_tui_command.Task_for_keeper { title; body } -> (
      let target =
        match keeper_name with
        | Some _ as named -> named
        | None -> state.msg_target_keeper_name
      in
      match target with
      | None -> add_event state "error" "/task needs a keeper to hand the work to"
      | Some keeper ->
          Buffer.clear state.msg_input;
          add_event state "task"
            (Printf.sprintf "creating a task for %s: %s" keeper title);
          launch_task_dispatch state ~mailbox ~keeper_name:keeper ~title ~body
            ~original:text)

let apply_keeper_chat_result state request result =
  match inflight_by_request_id state request.Keeper_chat.request_id with
  | Some current when Keeper_chat.same_request_identity current request ->
      drop_inflight state request;
      (match result with
       | Ok (Keeper_chat.Turn_completed completed) ->
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
           (* The server answered [Existing] for this id: the turn already ran
              and this POST produced no second one. *)
           append_chat_history state request Message_status
             "Request was already completed; canonical reply is not present in this replay stream";
           add_event state "message"
             (Printf.sprintf "Keeper request already completed: %s"
                request.request_id)
       | Error error ->
           (* A 401 here is a credential problem, and which one depends on
              whether this process presented a bearer at all. Every other
              failure keeps the server's own words. *)
           let detail =
             Keeper_chat.reconciliation_failure_detail
               ~credential_sent:(Masc_tui_http.operator_token_present ())
               error
             |> Keeper_chat.terminal_safe_text
           in
           let detail =
             match
               Keeper_chat.error_certainty ~was_unverified:false error
             with
             | Keeper_chat.Verified_rejected | Keeper_chat.Verified_failed ->
                 detail
             | Keeper_chat.Outcome_unverified ->
                 (* The POST did not come back with an answer, so the turn may
                    have run anyway. Nothing here has to reconcile it: the
                    transcript reloads from the server after every settle, and
                    a turn that ran appears there. Sending the line again is
                    safe too — that request carries a new id, so the server
                    treats it as the new message it is. *)
                 Printf.sprintf
                   "Outcome unverified for %s; the turn may still be running. The transcript reload will show it. %s"
                   request.request_id detail
           in
           append_chat_history state request Message_error detail;
           add_event state "error"
             (Printf.sprintf "Keeper message %s: %s" request.request_id detail));
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
      (* The cursor indexes the merged list; the operator rows sit after the
         keeper tool rows, so reconciliation by token happens in operator
         coordinates and the keeper prefix length converts both ways. A
         cursor on a keeper row is not touched by an operator refresh. *)
      let keeper_prefix = List.length state.keeper_tool_approvals in
      let operator_cursor = state.approval_cursor - keeper_prefix in
      let approval_cursor =
        if operator_cursor < 0 then state.approval_cursor
        else
          keeper_prefix
          + Approval.reconcile_cursor
              ~current_items:(operator_approval_items state)
              ~cursor:operator_cursor ~next_items:snapshot.aps_items
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
        (Keeper_control.roster_failure_message
           ~credential_sent:(Masc_tui_http.operator_token_present ())
           failure)

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

let load_http_surfaces ~host ~port ~approval_generation
    ~(needs : Masc_tui_types.surface_needs) =
  let when_needed wanted load = if wanted then Some (load ()) else None in
  let http_overview = load_overview ~host ~port in
  (* Only the Overview row shows this, so a refresh on another surface does not
     spend a request on it. [None] leaves whatever the last read observed. *)
  let http_transport =
    when_needed needs.needs_transport (fun () ->
        load_transport_health ~host ~port)
  in
  let http_approvals =
    Option.map
      (fun ao_generation ->
         { ao_generation; ao_result = load_approvals ~host ~port })
      approval_generation
  in
  let http_board =
    when_needed needs.needs_board (fun () -> load_board_list ~host ~port)
  in
  let http_planning =
    when_needed needs.needs_planning (fun () -> load_planning ~host ~port)
  in
  let http_system_logs =
    when_needed needs.needs_system_logs (fun () ->
        load_system_logs ~host ~port ~limit:system_log_page)
  in
  let http_fleet_safety =
    when_needed needs.needs_fleet_safety (fun () -> load_fleet_safety ~host ~port)
  in
  let http_keeper_roster =
    when_needed needs.needs_keeper_roster (fun () ->
        load_keeper_roster ~host ~port)
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
  Option.iter (apply_board_list_load state) results.http_board;
  Option.iter (apply_planning_load state) results.http_planning;
  Option.iter (apply_system_logs_load state) results.http_system_logs;
  Option.iter (apply_fleet_safety_load state) results.http_fleet_safety;
  Option.iter (apply_keeper_roster_load state) results.http_keeper_roster;
  let reached result =
    Result.map (fun _ -> ()) result |> Result.map_error (fun _ -> ())
  in
  let reached_if_asked result = Option.map reached result |> Option.to_list in
  (* Only the requests this refresh actually made say anything about the
     connection. Overview runs on every surface, so the reading never rests on
     an empty list. *)
  state.connection_status <-
    refresh_status
      ([ reached results.http_overview ]
       @ reached_if_asked results.http_board
       @ reached_if_asked results.http_planning
       @ (Option.map
            (fun observation -> reached observation.ao_result)
            results.http_approvals
          |> Option.to_list))

(* Open the runtime event feed on a daemon fiber: one MCP initialize for the
   session id, then the stream, read until it ends. Every step reports back
   through the mailbox; the render fiber owns all state. The fiber ends with
   the stream, and whether to open another is the main loop's decision. *)
let launch_observer state ~host ~port ~mailbox =
  state.observer <- Observer_opening;
  let session = state.mcp_session in
  let run () =
    let result =
      try
        match
          match session with
          | Some session_id -> Ok session_id
          | None ->
              Masc_tui_http.open_mcp_session ~host ~port
                ~client_version:Runtime_build_version.current
        with
        | Error detail -> Error detail
        | Ok session_id -> (
            enqueue_async mailbox (Observer_opened session_id);
            match Eio_context.get_clock_opt () with
            | None -> Error "Eio clock is unavailable"
            | Some clock ->
                let reader = Masc_tui_observer.create () in
                let on_chunk chunk =
                  match Masc_tui_observer.feed reader chunk with
                  | [] -> ()
                  | decoded -> enqueue_async mailbox (Observer_received decoded)
                in
                Masc_tui_http.observe_runtime_events ~clock ~host ~port
                  ~session_id ~on_chunk)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (Observer_closed
         (match result with
          | Ok () -> "the server closed the stream"
          | Error detail -> detail))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (Observer_closed "Eio switch is unavailable")

(* The feed is opened only after a refresh has reached the server: opening
   it blind would report a closed feed every cycle while the TUI runs without
   one, and that row is meant to say the stream dropped, not that there was
   never a server. Once closed it is reopened on the next refresh that
   reaches the server, which is the cadence the operator already chose. *)
(* [retry_closed] separates the first open from a retry. A feed that has never
   run is opened as soon as the server answers, because the row is meant to say
   the stream dropped and there is nothing to say yet. A feed that ran and
   closed waits for the operator's cadence: retrying it once per finished
   refresh made the retry rate whatever the refresh rate was, and a refresh
   also goes out when the open surface needs something the last one did not
   fetch -- so walking the surfaces retried a refused feed once per surface and
   filled the eleven-entry event panel with its own refusals. *)
let open_observer_if_due state ~retry_closed ~host ~port ~mailbox =
  match (state.connection_status, state.observer) with
  | (Connected | Degraded), Observer_off ->
      launch_observer state ~host ~port ~mailbox
  | (Connected | Degraded), Observer_closed _ when retry_closed ->
      launch_observer state ~host ~port ~mailbox
  | (Connected | Degraded), (Observer_closed _ | Observer_opening | Observer_live _)
  | (Disconnected | Connecting | Reconnecting), _ ->
      ()

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
    (* The chat pane's history comes down its own generation-guarded path, not
       in the surface bundle, so the tick asks for it here. Without this the
       pane read once on open and a message that arrived after that waited for
       the operator to leave and come back. *)
    (if needs.Masc_tui_types.needs_keeper_chat then
       match state.msg_target_keeper_name with
       | Some keeper_name -> launch_keeper_history_load state ~mailbox ~keeper_name
       | None -> ());

    let run_refresh () =
      try
        enqueue_async mailbox
          (Http_refresh_done
             (load_http_surfaces ~host ~port ~approval_generation ~needs))
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
               (load_http_surfaces ~host ~port ~approval_generation ~needs))
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

(* Request a goal lifecycle change through the tools route. Runs in a fiber
   like the other writes; the outcome lands in the shared mailbox and the
   server's phase rules decide, so the TUI never pre-guesses a transition. *)
let start_goal_transition state ~mailbox ~(goal_id : string)
    ~(action : Goal_phase.Public_action.t) =
  state.goal_action_error <- None;
  add_event state "system"
    (Printf.sprintf "goal %s: %s" goal_id
       (Goal_phase.Public_action.to_string action));
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run_transition () =
    let result =
      match
        Masc_tui_http.post_goal_transition ~host ~port ~goal_id ~action
          ~note:None
      with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    enqueue_async mailbox (Goal_transition_done result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_transition
  | None -> run_transition ()

(* The lifecycle keys on a goal detail. Arming is the pattern the keeper
   lifecycle already uses: the first press names the action, the same press
   again submits it, and any other key disarms. [Goal_phase.Public_action.t]
   rides along so no string name of an action exists in this file. *)
let goal_public_action_key (action : Goal_phase.Public_action.t) =
  match action with
  | Goal_phase.Public_action.Request_complete -> "c"
  | Goal_phase.Public_action.Drop -> "x"
  | Goal_phase.Public_action.Reopen -> "o"

let handle_goal_action_key state ~mailbox ~(action : Goal_phase.Public_action.t)
    =
  match state.planning_mode with
  | Planning_detail goal_id -> (
      match state.goal_action_armed with
      | Some (armed_goal, armed_action)
        when String.equal armed_goal goal_id
             && armed_action = action ->
          state.goal_action_armed <- None;
          start_goal_transition state ~mailbox ~goal_id ~action
      | Some _ | None ->
          state.goal_action_armed <- Some (goal_id, action);
          state.goal_action_error <- None;
          add_event state "system"
            (Printf.sprintf "press %s again to %s goal %s"
               (goal_public_action_key action)
               (match action with
                | Goal_phase.Public_action.Request_complete ->
                    "request completion of"
                | Goal_phase.Public_action.Drop -> "drop"
                | Goal_phase.Public_action.Reopen -> "reopen")
               goal_id))
  | Planning_list -> ()

(* Compose-mode keys. Sending is armed rather than pressed: esc offers
   send-or-discard, so a stray key during writing cannot publish. Returns
   false for keys this pane does not own, so Tab and quit keep their global
   meaning. *)
(* Send a comment through the tools route. Same fiber-and-mailbox shape as
   the other board writes; the route stamps the author. *)
let start_board_comment state ~mailbox ~(post_id : string)
    ~(content : string) =
  state.board_post_error <- None;
  add_event state "system" "commenting on Board";
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run_comment () =
    let result =
      match Masc_tui_http.post_board_comment ~host ~port ~post_id ~content with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    enqueue_async mailbox (Board_new_post_done result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_comment
  | None -> run_comment ()

(* Send a vote through the tools route. The voter is stamped by the route,
   so the payload says only which post and which way. *)
let start_board_vote state ~mailbox ~(post_id : string) ~(up : bool) =
  add_event state "system"
    (Printf.sprintf "voting %s on %s" (if up then "up" else "down") post_id);
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run_vote () =
    let result =
      match Masc_tui_http.post_board_vote ~host ~port ~post_id ~up with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    enqueue_async mailbox (Board_vote_done result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_vote
  | None -> run_vote ()

(* The vote keys on the list row under the cursor. Two presses: the first
   names the post and direction, the same press again sends it. The post id
   is captured at arm time, so moving the cursor between presses re-arms
   for the new row rather than voting on the one the operator left. *)
let handle_board_vote_key state ~mailbox ~(up : bool) =
  match state.board_mode with
  | Board_list -> (
      match List.nth_opt state.board_posts state.board_cursor with
      | None -> ()
      | Some post -> (
          match state.board_vote_armed with
          | Some (armed_post, armed_up)
            when String.equal armed_post post.bp_id && armed_up = up ->
              state.board_vote_armed <- None;
              start_board_vote state ~mailbox ~post_id:post.bp_id ~up
          | Some _ | None ->
              state.board_vote_armed <- Some (post.bp_id, up);
              add_event state "system"
                (Printf.sprintf "press %s again to vote %s on %s"
                   (if up then "v" else "V")
                   (if up then "up" else "down")
                   post.bp_id)))
  | Board_read _ | Board_compose -> ()

(* Cancel a schedule through the tools route. Same fiber-and-mailbox shape as
   the other writes; the server's store rules decide whether the row is still
   cancellable, so the TUI does not pre-guess from the status column. *)
let start_schedule_cancel state ~mailbox ~(schedule_id : string) =
  state.schedule_cancel_error <- None;
  add_event state "system"
    (Printf.sprintf "cancelling schedule %s" schedule_id);
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let run_cancel () =
    let result =
      match Masc_tui_http.post_schedule_cancel ~host ~port ~schedule_id with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    enqueue_async mailbox (Schedule_cancel_done result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_cancel
  | None -> run_cancel ()

(* The cancel key on the row under the cursor. Two presses, like the vote
   keys: the first names the schedule, the same press again sends it. The
   schedule id is captured at arm time, so moving the cursor between presses
   re-arms for the new row rather than cancelling the one the operator left. *)
let handle_schedule_cancel_key state ~mailbox =
  let rows =
    match state.schedules with
    | None -> []
    | Some snapshot -> snapshot.scs_rows
  in
  match List.nth_opt rows state.schedule_cursor with
  | None -> ()
  | Some row -> (
      match state.schedule_cancel_armed with
      | Some armed when String.equal armed row.sch_schedule_id ->
          state.schedule_cancel_armed <- None;
          start_schedule_cancel state ~mailbox
            ~schedule_id:row.sch_schedule_id
      | Some _ | None ->
          state.schedule_cancel_armed <- Some row.sch_schedule_id;
          state.schedule_cancel_error <- None;
          add_event state "system"
            (Printf.sprintf "press x again to cancel %s" row.sch_schedule_id))

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
      (* A reply sends the whole draft as one comment; a new post still
         splits title from body at the first line. *)
      match state.board_compose_reply_to with
      | Some post_id ->
          let content = Buffer.contents state.board_draft in
          if String.equal (String.trim content) "" then begin
            state.board_compose_armed <- false;
            state.board_post_error <- Some "the comment is empty";
            true
          end else begin
            state.board_compose_armed <- false;
            start_board_comment state ~mailbox ~post_id ~content;
            true
          end
      | None ->
          let title, body =
            split_board_draft (Buffer.contents state.board_draft)
          in
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
      (match state.board_compose_reply_to with
       | Some post_id -> state.board_mode <- Board_read post_id
       | None -> state.board_mode <- Board_list);
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
           state.msg_return <- Keeper_chat_return_detail;
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
      (match Masc_tui_command.parse text with
       | Masc_tui_command.Say _ ->
           state.msg_scroll <- 0;
           state.view <- Keepers Keeper_message
       | Masc_tui_command.Switch_keeper _ ->
           (* The switch handler owns the view change. *)
           state.msg_scroll <- 0
       | Masc_tui_command.Task_for_keeper _ | Masc_tui_command.Task_missing_title
       | Masc_tui_command.Help | Masc_tui_command.Switch_keeper_missing_name
       | Masc_tui_command.Interrupt_turn | Masc_tui_command.Toggle_thinking
       | Masc_tui_command.Unknown _ ->
           (* A command keeps the surface: the operator asked the TUI, not
              the keeper, and the answer lands in Recent Events. *)
           ());
      send_operator_text state ~mailbox text;
      true
  | Composer.Edit ->
      let _handled =
        handle_message_key state
          ~submit_message:(fun _ -> ())
          ~answer_approval:(fun ~tool_call_id:_ ~allow:_ -> ())
          ~load_older:(fun ~before:_ -> ())
          key
      in
      true

let apply_async_message state ~base_path ~http_refresh_inflight ~mailbox =
  function
  | Http_refresh_done results ->
      http_refresh_inflight := false;
      apply_http_surfaces state results;
      (* The held-call listing rides the same cadence as the surface that
         draws it. Fetched only while the surface is up: the waits are
         short-lived and every other surface would fetch rows it never
         shows. *)
      (match state.view with
       | Approvals -> launch_keeper_tool_approvals_load state ~mailbox
       | Keepers _ -> launch_keeper_tool_modes_load state ~mailbox
       | _ -> ());
      open_observer_if_due state ~retry_closed:false
        ~host:(Env_config_core.masc_host ()) ~port:state.port ~mailbox
  | Observer_opened session_id ->
      state.mcp_session <- Some session_id;
      state.observer <-
        Observer_live { session_id; since = Unix.gettimeofday (); events = 0 };
      add_event state "observer" "runtime event feed open"
  | Observer_received decoded ->
      let received = Unix.gettimeofday () in
      List.iter
        (fun item ->
          match item with
          | Masc_tui_observer.Event event ->
              (match state.observer with
               | Observer_live live ->
                   state.observer <-
                     Observer_live { live with events = live.events + 1 }
               | Observer_off | Observer_opening | Observer_closed _ -> ());
              state.acting <-
                { ae_at = received; ae_event = event } :: state.acting;
              (* A row arriving at the top pushes every row down one. An
                 operator scrolled into the past keeps the rows they were
                 reading and a count of what arrived above them. *)
              if state.acting_scroll > 0 then begin
                state.acting_scroll <- state.acting_scroll + 1;
                state.acting_unseen <- state.acting_unseen + 1
              end
          | Masc_tui_observer.Undecodable reason ->
              state.acting_undecodable <- state.acting_undecodable + 1;
              state.acting_undecodable_last <- Some reason)
        decoded;
      let kept = List.length state.acting in
      if kept > Masc_tui_types.acting_retained_entries then begin
        state.acting <-
          List.filteri
            (fun index _ -> index < Masc_tui_types.acting_retained_entries)
            state.acting;
        state.acting_dropped <-
          state.acting_dropped + (kept - Masc_tui_types.acting_retained_entries)
      end
  | Task_dispatched { keeper; task_id; title; body } ->
      add_event state "task" (Printf.sprintf "%s created for %s" task_id keeper);
      state.msg_scroll <- 0;
      state.view <- Keepers Keeper_message;
      start_keeper_message ~keeper_name:keeper state ~mailbox
        (Masc_tui_command.task_message ~task_id ~title ~body)
  | Task_dispatch_failed { keeper; detail; original } ->
      (* The operator's words come back to the input so nothing typed is
         lost with the failure. *)
      Buffer.clear state.msg_input;
      Buffer.add_string state.msg_input original;
      add_event state "error"
        (Printf.sprintf "task for %s not created: %s" keeper detail)
  | Observer_closed reason ->
      let events =
        match state.observer with
        | Observer_live live -> live.events
        | Observer_off | Observer_opening | Observer_closed _ -> 0
      in
      state.observer <-
        Observer_closed { reason; at = Unix.gettimeofday (); events };
      (* A stream the server refused outright delivered nothing. The session
         it was asked under is dropped so the next attempt opens a fresh one;
         a stream that ran and ended keeps the session for the next. *)
      if events = 0 then state.mcp_session <- None;
      add_event state "observer" ("runtime event feed closed: " ^ reason)
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
      (* The same envelope carries a new post and a comment; where the
         operator lands afterwards is the only difference. A comment returns
         to the post it answered (and refreshes that detail), a post to the
         list. *)
      let reply_to = state.board_compose_reply_to in
      match result with
      | Ok message ->
          Buffer.clear state.board_draft;
          state.board_compose_armed <- false;
          state.board_compose_reply_to <- None;
          state.board_post_error <- None;
          (match reply_to with
           | Some post_id -> state.board_mode <- Board_read post_id
           | None -> state.board_mode <- Board_list);
          add_event state "system" ("Board: " ^ message);
          (* The posted row is the half the periodic refresh has not fetched
             yet; without this the operator returns to a list that does not
             contain what they just published. A comment refreshes the
             detail too, so the reply is visible the moment it lands. *)
          start_http_refresh state ~host:(Env_config_core.masc_host ())
            ~port:state.port ~refresh_inflight:http_refresh_inflight ~mailbox;
          (match reply_to with
           | Some post_id ->
               start_board_post_refresh state
                 ~host:(Env_config_core.masc_host ())
                 ~port:state.port ~post_id ~mailbox
           | None -> ())
      | Error err ->
          state.board_compose_armed <- false;
          (* The draft stays: a rejected post is usually one field short, and
             losing the text over it would make the error a dead end. *)
          state.board_post_error <- Some err)
  | Board_vote_done result -> (
      match result with
      | Ok message ->
          state.board_vote_armed <- None;
          add_event state "system" ("Board vote: " ^ message);
          (* The score is drawn from the list; refresh it rather than
             waiting out the interval to see the arrow land. *)
          start_http_refresh state ~host:(Env_config_core.masc_host ())
            ~port:state.port ~refresh_inflight:http_refresh_inflight ~mailbox
      | Error err ->
          state.board_vote_armed <- None;
          add_event state "error" ("Board vote failed: " ^ err))
  | Goal_transition_done result -> (
      match result with
      | Ok message ->
          state.goal_action_armed <- None;
          state.goal_action_error <- None;
          add_event state "system" ("Goal: " ^ message);
          (* The phase shown is the half the periodic refresh has not fetched
             yet; without this the detail keeps the old phase after the
             operator already changed it. *)
          start_http_refresh state ~host:(Env_config_core.masc_host ())
            ~port:state.port ~refresh_inflight:http_refresh_inflight ~mailbox
      | Error err ->
          state.goal_action_armed <- None;
          state.goal_action_error <- Some err)
  | Keeper_calls_loaded (keeper_name, result) -> (
      let still_selected =
        match List.nth_opt state.keepers state.keeper_cursor with
        | Some keeper -> String.equal keeper.k_name keeper_name
        | None -> false
      in
      if still_selected then
        match result with
        | Ok snapshot ->
            state.keeper_calls <- Some snapshot;
            state.keeper_calls_error <- None
        | Error detail -> state.keeper_calls_error <- Some detail)
  | Schedules_loaded result -> (
      match result with
      | Ok snapshot ->
          state.schedules <- Some snapshot;
          state.schedules_error <- None;
          (* The cursor can outlive a list whose rows changed underneath it;
             clamping to the new tail keeps the cancel key pointing at a row
             that exists. *)
          let count = List.length snapshot.scs_rows in
          if state.schedule_cursor >= count then
            state.schedule_cursor <- max 0 (count - 1)
      | Error err -> state.schedules_error <- Some err)
  | Schedule_cancel_done result -> (
      match result with
      | Ok message ->
          state.schedule_cancel_armed <- None;
          state.schedule_cancel_error <- None;
          add_event state "system" ("Schedule: " ^ message);
          (* The row shown still carries the old status until this lands; a
             cancelled row that reads "scheduled" invites a second cancel. *)
          launch_schedules_load state ~mailbox
      | Error err ->
          state.schedule_cancel_armed <- None;
          state.schedule_cancel_error <- Some err)
  | Approval_decision_done (approval, decision, result, approvals) ->
      apply_approval_decision_completion state approvals.ao_generation approval
        decision result approvals.ao_result
  | Keeper_chat_dispatch_started (request, was_replay, acknowledge) ->
      let proceed = ref false in
      Fun.protect
        ~finally:(fun () -> Eio.Promise.resolve acknowledge !proceed)
        (fun () ->
          match inflight_by_request_id state request.Keeper_chat.request_id with
          | Some current
            when Keeper_chat.same_request_identity current request ->
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
                     ~request_id:request.request_id
                     ~started_at:(Unix.gettimeofday ()));
              proceed := true
          | Some _ | None -> ())
  | Keeper_chat_done (request, was_replay, result, acknowledge) ->
      settle_live_turn state request;
      (* The server persists the user row, the reply and the tool calls before
         it ends the stream, so by now the transcript holds this turn. While
         the pane still points here, reloading makes that record the thing on
         screen; the rows settle_live_turn just committed are what stands if
         the load fails. A background Keeper does not supersede the visible
         Keeper's history generation. *)
      if
        Option.exists
          (String.equal request.Keeper_chat.keeper_name)
          state.msg_target_keeper_name
      then
        launch_keeper_history_load state ~mailbox
          ~keeper_name:request.Keeper_chat.keeper_name;
      let applied =
        Fun.protect
          ~finally:(fun () -> Eio.Promise.resolve acknowledge ())
          (fun () ->
            apply_keeper_chat_result state request result)
      in
      if applied then load_from_masc_dir state base_path;
      (* The turn settled, so "next" has arrived for whatever was waiting. *)
      drain_queued_message state ~mailbox
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
  | Keeper_tool_approvals_loaded result ->
      (match result with
       | Ok held ->
           state.keeper_tool_approvals <- held;
           state.keeper_tool_approvals_error <- None;
           let count = List.length (approval_items state) in
           if state.approval_cursor >= count then
             state.approval_cursor <- max 0 (count - 1)
       | Error detail -> state.keeper_tool_approvals_error <- Some detail)
  | Keeper_tool_modes_loaded result ->
      (match result with
       | Ok overrides ->
           state.keeper_yolo_names <-
             List.filter_map
               (fun (keeper, mode) ->
                 if String.equal mode "yolo" then Some keeper else None)
               overrides
       | Error _ ->
           (* The stance listing is advisory colouring; a failed fetch keeps
              the last known set rather than flashing every name back. *)
           ())
  | Keeper_tool_mode_set (keeper_name, mode, result) ->
      (match result with
       | Ok () ->
           state.keeper_yolo_names <-
             (let without =
                List.filter
                  (fun name -> not (String.equal name keeper_name))
                  state.keeper_yolo_names
              in
              if String.equal mode "yolo" then keeper_name :: without
              else without);
           add_event state "system"
             (if String.equal mode "yolo" then
                Printf.sprintf
                  "%s runs every tool call unasked (YOLO) until restart or g"
                  keeper_name
              else
                Printf.sprintf "%s is back on the approval policy (auto)"
                  keeper_name)
       | Error detail ->
           add_event state "error"
             (Printf.sprintf "could not set %s's gate: %s" keeper_name detail))
  | Surface_tool_approval_answered (keeper_name, tool_call_id, allow, result) ->
      (* The listing is stale the moment an answer lands, so the settled call
         leaves the local list at once rather than waiting for a refresh. *)
      state.keeper_tool_approvals <-
        List.filter
          (fun (held : Tui_decode.keeper_tool_approval) ->
            not (String.equal held.kta_tool_call_id tool_call_id))
          state.keeper_tool_approvals;
      let count = List.length (approval_items state) in
      if state.approval_cursor >= count then
        state.approval_cursor <- max 0 (count - 1);
      add_event state
        (match result with Ok true -> "system" | _ -> "error")
        (match result with
         | Ok true ->
             Printf.sprintf "%s %s's held call %s"
               (if allow then "allowed" else "denied")
               keeper_name
               (Keeper_chat.compact_request_id tool_call_id)
         | Ok false ->
             Printf.sprintf
               "too late for %s's call %s; it was no longer waiting"
               keeper_name
               (Keeper_chat.compact_request_id tool_call_id)
         | Error detail -> "could not answer the held call: " ^ detail)
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
  | Keeper_chat_dispatch_blocked (request, detail) ->
      (* The POST never left. Nothing durable was written for it, so there is
         nothing to reconcile: say what happened and let the operator send
         again if they want to. *)
      settle_live_turn state request;
      (match inflight_by_request_id state request.Keeper_chat.request_id with
       | Some current when Keeper_chat.same_request_identity current request ->
           drop_inflight state request;
           add_event state "error"
             (Printf.sprintf "Keeper request %s was not dispatched: %s"
                request.request_id detail)
       | Some _ | None -> ())
  | Keeper_chat_history_loaded (generation, keeper_name, result) ->
      (* The operator can switch while a previous GET is still in flight. The
         pane owns one loaded-history cache, so a late response for the old
         target or an older request for a target revisited since must not
         replace the transcript now being read. *)
      if
        generation = state.msg_history_load_generation
        && Option.exists (String.equal keeper_name)
             state.msg_target_keeper_name
      then
        (match result with
         | Ok { Keeper_chat_history.rows; dropped } ->
             state.msg_loaded <-
               List.map (msg_entry_of_history_row keeper_name) rows;
             state.msg_loaded_keeper <- Some keeper_name;
             state.msg_loaded_error <- None;
             state.msg_loaded_dropped <- dropped;
             (* Where reading further back starts. The oldest row this load
                carried is the cursor; if it carried none there is nothing to
                page back from. Whether older rows exist is only learned by
                asking, so the pane assumes they might and finds out on the
                first page. *)
             state.msg_older_cursor <-
               List.fold_left
                 (fun oldest (row : Keeper_chat_history.row) ->
                   match oldest with
                   | None -> Some row.Keeper_chat_history.at
                   | Some at ->
                       Some (Float.min at row.Keeper_chat_history.at))
                 None rows;
             state.msg_older_exist <- Option.is_some state.msg_older_cursor;
             state.msg_older_error <- None;
             forget_session_rows_the_transcript_holds state keeper_name rows
         | Error detail ->
             (* The transcript is left as it was and the session rows stay: a
                failed load must not be the reason the pane goes blank. *)
             state.msg_loaded_error <- Some detail)
  | Tools_loaded result -> (
      match result with
      | Ok snapshot ->
          state.tools_inventory <- Some snapshot;
          state.tools_error <- None
      | Error detail -> state.tools_error <- Some detail)
  | Connectors_loaded result -> (
      match result with
      | Ok snapshot ->
          state.connectors <- Some snapshot;
          state.connectors_error <- None
      | Error detail -> state.connectors_error <- Some detail)
  | Repositories_loaded result -> (
      match result with
      | Ok snapshot ->
          state.repositories <- Some snapshot;
          state.repositories_error <- None
      | Error detail -> state.repositories_error <- Some detail)
  | Lanes_loaded result -> (
      match result with
      | Ok snapshot ->
          state.lanes <- Some snapshot;
          state.lanes_error <- None
      | Error detail ->
          (* Keep the previous rows visible. The error says that they are
             stale; clearing them would turn a failed refresh into an empty
             reading. *)
          state.lanes_error <- Some detail)
  | Harness_loaded result -> (
      match result with
      | Ok snapshot ->
          state.harness <- Some snapshot;
          state.harness_error <- None
      | Error detail -> state.harness_error <- Some detail)
  | Verification_loaded result -> (
      match result with
      | Ok snapshot ->
          state.verification <- Some snapshot;
          state.verification_error <- None
      | Error detail ->
          (* The previous list stays: a failed reload must not make the queue
             look empty, which reads as "nothing is waiting". *)
          state.verification_error <- Some detail)
  | Keeper_chat_older_loaded (generation, keeper_name, before, result) ->
      (* A page that arrived for a keeper the pane has since left, or after a
         reload moved the cursor, is dropped: prepending it would put rows
         above a transcript they do not belong to. *)
      let still_current =
        generation = state.msg_history_load_generation
        && (match state.msg_loaded_keeper with
            | Some loaded -> String.equal loaded keeper_name
            | None -> false)
        && state.msg_older_cursor = Some before
      in
      if still_current then (
        state.msg_older_loading <- false;
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

(* One enable/disable pair for SGR mouse reports. Without tracking the
   terminal keeps the wheel for its own scrollback -- which scrolls past the
   TUI's frame on a non-alternate screen -- or turns it into arrow keys only
   if configured to. With it, wheel reports arrive here and read_key maps
   them to the same keys the arrows make. *)
let mouse_tracking_enable = "\x1b[?1006;1000h"
let mouse_tracking_disable = "\x1b[?1006;1000l"

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
  (* The provider layer reports through [Llm_provider.Diag], whose default sink
     writes to stderr -- which here is the terminal this draws on. One INFO line
     about the embedded model catalog lands between two frames and the screen is
     no longer what the frame presenter believes it wrote. The server routes
     these into the structured log at boot; this surface has the same terminal
     to protect, so it routes them the same way and before anything can ask the
     catalog a question. *)
  Provider_diag_log_sink.install ();
  let (base_path, workspace, port, refresh) = parse_args () in
  require_interactive_terminal ();
  (* The console mirror writes every record to stderr, and stderr is this
     terminal. A library Info line printed between two frames lands inside the
     drawn screen, and the repaint that follows does not unprint it -- it is
     already in the scrollback the frame occupies. Warn is the floor because a
     warning is worth that cost and a routine "loaded N entries" is not.

     MASC_LOG_LEVEL still wins: init_from_env runs after, so an operator who
     asks for Info gets it, terminal or not. *)
  Log.set_level Log.Warn;
  Log.init_from_env ();
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
    (* No tracking-off here: suspend runs this too, and a terminal that
       re-enters raw mode after Ctrl-Z would silently lose the wheel. The
       off byte is written once, in [cleanup], at real process exit. *)
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
      print_endline "Goodbye!";
      (* Tracking off after Goodbye: a terminal left in report mode keeps
         swallowing the wheel after this process is gone, and the farewell
         line is the last thing a reader matches on -- a byte after it cannot
         disturb that read. *)
      output_string stdout mouse_tracking_disable;
      flush stdout
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
        (* restore_terminal above gave the alternate screen back so the shell
           was usable while stopped. Take it again before the repaint, or the
           frame lands on top of whatever the user did meanwhile. *)
        Frame_presenter.setup frame_presenter ~write:(output_string stdout)
          ~flush:(fun () -> flush stdout);
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

  (* Written here rather than at session entry, inside enter_terminal_session:
     a byte written the moment raw mode is taken races the handshake reads a
     harness (or terminal) performs on the very first output, and the PTY
     regression's quit scenario reliably loses that race. Between session
     entry and the first frame the stream is quiet, and the enable is not
     urgent anyway -- the first wheel event always arrives after the first
     frame. *)
  (* Before the first frame and after session entry, so the at_exit cleanup
     that gives this back is already installed. *)
  Frame_presenter.setup frame_presenter ~write:(output_string stdout)
    ~flush:(fun () -> flush stdout);
  output_string stdout mouse_tracking_enable;
  flush stdout;

  (* Initial load *)
  load_from_masc_dir state base_path;
  let host = Env_config_core.masc_host () in
  let port = state.port in
  let http_refresh_inflight = ref false in
  let async_messages = Eio.Stream.create 32 in
  (* Bind the bearer to the workspace actually opened, before any request is
     built. Reported before the recovery load as well, so when neither source
     holds one the operator sees the cause ahead of the symptom: a tokenless
     process cannot dispatch, and cannot reconcile a dispatch an authenticated
     predecessor left behind. *)
  (match
     Masc_tui_credential.outcome_notice
       (Masc_tui_http.install_operator_token ~base_path ~host ~port)
   with
   | Some notice -> add_event state "error" notice
   | None -> ());
  start_http_refresh state ~host ~port ~refresh_inflight:http_refresh_inflight
    ~mailbox:async_messages;
  add_event state "system" "TUI started";

  (* Main loop *)
  let refresh_interval_ns =
    Int64.of_float (max 0.0 refresh *. nanoseconds_per_second)
  in
  let last_check_ns = ref (Mtime_clock.elapsed_ns ()) in
  (* A datum that is fetched only while its surface is open has nothing to draw
     the moment that surface opens, and waiting out the refresh interval would
     read as "there is nothing here". What is watched is the set of data the
     open surface needs rather than the surface itself, so moving between two
     surfaces that read the same things -- a keeper list and a keeper's detail --
     costs no request. Watching from the loop catches every way the surface can
     change, rather than asking each of the places that change it to remember. *)
  let drawn_needs = ref (Masc_tui_types.surface_needs state.view) in
  let input_reader = create_input_reader () in

  (* ── Keeper settings over $EDITOR (#29684) ─────────────────────
     The editor itself is the confirmation step: an exit other than 0
     leaves the settings untouched, so these flows skip Keeper_control's
     arming gate. The terminal handshake around the child is the pair
     [suspend] already runs around Ctrl-Z. *)
  let reenter_terminal () =
    Unix.tcsetattr Unix.stdin Unix.TCSANOW new_term;
    request_full_repaint 0
  in
  (* An empty object is the honest starting point for a partial patch: the
     config route applies only the fields present in the body, and the TUI
     has no view of the current settings to prefill from -- showing a
     guessed stem would invite an operator to "keep" a value that is not
     the one on disk. *)
  let handle_keeper_settings_edit () =
    match selected_keeper state with
    | None -> ()
    | Some keeper -> (
      match Masc_tui_editor.editor_command () with
      | None ->
        add_event state "error"
          "no $EDITOR set; export EDITOR to edit keeper settings here"
      | Some _ -> (
        match
          Masc_tui_editor.roundtrip ~restore:restore_terminal
            ~reenter:reenter_terminal "{\n}\n"
        with
        | None -> add_event state "system" (keeper.k_name ^ ": settings unchanged")
        | Some patch -> (
          match
            Masc_tui_http.post_keeper_config ~host ~port
              ~keeper_name:keeper.k_name ~patch_json:patch
          with
          | Ok _ -> add_event state "system" (keeper.k_name ^ ": settings applied")
          | Error detail -> add_event state "error" detail)))
  in
  let handle_keeper_create () =
    match Masc_tui_editor.editor_command () with
    | None ->
      add_event state "error" "no $EDITOR set; export EDITOR to create a keeper here"
    | Some _ -> (
      (* The stem names the only two fields a keeper cannot come up without;
         the name is edited in place and the route name comes from it. *)
      let stem =
        "{\n  \"name\": \"new-keeper\",\n  \"instructions\": \"\"\n}\n"
      in
      match
        Masc_tui_editor.roundtrip ~restore:restore_terminal
          ~reenter:reenter_terminal stem
      with
      | None -> add_event state "system" "create cancelled"
      | Some declaration -> (
        let declared_name =
          match Yojson.Safe.from_string declaration with
          | `Assoc fields -> (
            match List.assoc_opt "name" fields with
            | Some (`String value) -> String.trim value
            | _ -> "")
          | _ -> ""
        in
        if String.length declared_name = 0 then
          add_event state "error"
            "declaration needs a non-empty \"name\" string; nothing was created"
        else
          match
            Masc_tui_http.post_keeper_up ~host ~port ~keeper_name:declared_name
              ~declaration_json:declaration
          with
          | Ok _ -> add_event state "system" (declared_name ^ ": keeper created")
          | Error detail -> add_event state "error" detail))
  in
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
          minutes ago for something else. Same rule for an armed goal action. *)
       | Keepers _, Some ("s" | "S") -> ()
       | Keepers _, Some _ -> state.keeper_action_pending <- None
       | Board, Some ("v" | "V") -> ()
       | Board, Some _ -> state.board_vote_armed <- None
       | Planning, Some ("c" | "C" | "x" | "X" | "o" | "O") -> ()
       | Planning, Some _ -> state.goal_action_armed <- None
       | Schedules, Some ("x" | "X") -> ()
       | Schedules, Some _ -> state.schedule_cancel_armed <- None
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
           let switch_key = String.length k = 1 && Char.code k.[0] = 7 in
           if
             keeper_message_input_supported state
             || String.equal k "esc"
             || recovery_key
             || switch_key
           then
             if switch_key then
               switch_to_next_keeper_message state ~mailbox:async_messages
             else
               let _handled =
                 handle_message_key state
                   ~submit_message:
                     (send_operator_text state ~mailbox:async_messages)
                   ~answer_approval:(fun ~tool_call_id ~allow ->
                     match
                       Option.bind state.msg_live (fun live ->
                         inflight_by_request_id state
                           (Keeper_chat_transcript.request_id live))
                     with
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
                         launch_keeper_older_page state
                           ~mailbox:async_messages ~keeper_name ~before
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
                 | Some (Operator_row a) ->
                     handle_approval_decision state a Confirm
                       ~mailbox:async_messages
                 | Some (Keeper_tool_row held) ->
                     (* One press, matching the chat pane's [y]: the wait runs
                        out on a short clock, so the two-press arming the
                        operator actions use would spend it. *)
                     launch_surface_tool_approval state
                       ~mailbox:async_messages
                       ~keeper_name:held.kta_keeper
                       ~tool_call_id:held.kta_tool_call_id ~allow:true
                 | None -> ())
            | _ -> ())
       | Some "n" | Some "N" ->
           (match state.view with
            | Approvals ->
                (match List.nth_opt (approval_items state) state.approval_cursor with
                 | Some (Operator_row a) ->
                     handle_approval_decision state a Deny
                       ~mailbox:async_messages
                 | Some (Keeper_tool_row held) ->
                     launch_surface_tool_approval state
                       ~mailbox:async_messages
                       ~keeper_name:held.kta_keeper
                       ~tool_call_id:held.kta_tool_call_id ~allow:false
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
            | Keepers Keeper_calls ->
                (match selected_keeper state with
                 | Some keeper ->
                     launch_keeper_calls_load state ~mailbox:async_messages
                       keeper.k_name
                 | None -> ())
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
            | Lanes -> launch_lanes_load state ~mailbox:async_messages
            | Harness -> launch_harness_load state ~mailbox:async_messages
            | Repositories ->
                launch_repositories_load state ~mailbox:async_messages
            | Connectors -> launch_connectors_load state ~mailbox:async_messages
            | Tools -> launch_tools_load state ~mailbox:async_messages
            | Schedules -> launch_schedules_load state ~mailbox:async_messages
            | Overview | Acting | Keepers Keeper_list | Keepers Keeper_detail
            | Approvals | Planning | System_logs -> ());
           add_event state "system" "Manual refresh"
       | Some "\t" ->
           (* Tab cycles through primary surfaces *)
           (match state.view with
            | Overview -> state.view <- Acting
            | Acting -> state.view <- Keepers Keeper_list
            | Keepers _ ->
                launch_lanes_load state ~mailbox:async_messages;
                state.view <- Lanes
            | Lanes ->
                (* Loaded on arrival: a held call is on a short clock, and
                   showing none until the next periodic refresh reads as
                   "nothing is waiting". *)
                launch_keeper_tool_approvals_load state
                  ~mailbox:async_messages;
                state.view <- Approvals
            | Approvals ->
                state.pending_approval_action <- None;
                state.view <- Board
            | Board -> state.view <- Planning
            | Planning ->
                (* Loaded on arrival: the schedule page is a snapshot of the
                   store, and a stale one would answer "why is this keeper
                   awake" with yesterday's rows. *)
                launch_schedules_load state ~mailbox:async_messages;
                state.view <- Schedules
            | Schedules ->
                (* Loaded on arrival: the queue is what the surface is, so
                   showing it empty until a refresh would read as "nothing is
                   waiting". *)
                launch_verification_load state ~mailbox:async_messages;
                state.view <- Verification
            | Verification ->
                launch_harness_load state ~mailbox:async_messages;
                state.view <- Harness
            | Harness ->
                launch_repositories_load state ~mailbox:async_messages;
                state.view <- Repositories
            | Repositories ->
                launch_connectors_load state ~mailbox:async_messages;
                state.view <- Connectors
            | Connectors ->
                launch_tools_load state ~mailbox:async_messages;
                state.view <- Tools
            | Tools -> state.view <- System_logs
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
            | Keepers Keeper_calls ->
                state.view <- Keepers Keeper_detail;
                state.keeper_calls_scroll <- 0;
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
                     (match
                        inflight_by_request_id state
                          (Keeper_chat_transcript.request_id live)
                      with
                      | Some request ->
                          launch_keeper_interrupt state
                            ~mailbox:async_messages request
                      | None -> leave_keeper_message state)
                 | Some _ ->
                     (* An interrupt is already outstanding for this turn. *)
                     ()
                 | None -> leave_keeper_message state)
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
            | Acting | Keepers Keeper_list | Lanes | Approvals | Schedules
            | Verification | Harness | Repositories | Connectors | Tools
            | System_logs -> ())
       | Some "j" | Some "down" | Some "wheel-down" ->
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
            | Keepers Keeper_calls ->
                state.keeper_calls_scroll <- state.keeper_calls_scroll + 1
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
            | Schedules ->
                let count =
                  match state.schedules with
                  | None -> 0
                  | Some snapshot -> List.length snapshot.scs_rows
                in
                if state.schedule_cursor < count - 1 then
                  state.schedule_cursor <- state.schedule_cursor + 1
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
                state.verification_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:1
                    ~current:state.verification_scroll
            | Lanes ->
                state.lanes_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:1
                    ~current:state.lanes_scroll
            | Harness -> state.harness_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:1
                    ~current:state.harness_scroll
            | Repositories ->
                state.repositories_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:1
                    ~current:state.repositories_scroll
            | Connectors ->
                state.connectors_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:1
                    ~current:state.connectors_scroll
            | Tools -> state.tools_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:1
                    ~current:state.tools_scroll
            | Acting -> state.acting_scroll <- state.acting_scroll + 1
            | System_logs -> state.system_logs_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:1
                    ~current:state.system_logs_scroll
            | Keepers Keeper_message -> ())
       | Some "k" | Some "up" | Some "wheel-up" ->
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
            | Keepers Keeper_calls ->
                if state.keeper_calls_scroll > 0 then
                  state.keeper_calls_scroll <- state.keeper_calls_scroll - 1
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
            | Schedules ->
                if state.schedule_cursor > 0 then
                  state.schedule_cursor <- state.schedule_cursor - 1
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
                  state.verification_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:(-1)
                    ~current:state.verification_scroll
            | Lanes ->
                if state.lanes_scroll > 0 then
                  state.lanes_scroll <-
                    move_surface_scroll state ~rows:(surface_rows ()) ~delta:(-1)
                      ~current:state.lanes_scroll
            | Harness ->
                if state.harness_scroll > 0 then
                  state.harness_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:(-1)
                    ~current:state.harness_scroll
            | Repositories ->
                if state.repositories_scroll > 0 then
                  state.repositories_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:(-1)
                    ~current:state.repositories_scroll
            | Connectors ->
                if state.connectors_scroll > 0 then
                  state.connectors_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:(-1)
                    ~current:state.connectors_scroll
            | Tools ->
                if state.tools_scroll > 0 then
                  state.tools_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:(-1)
                    ~current:state.tools_scroll
            | Acting ->
                if state.acting_scroll > 0 then begin
                  state.acting_scroll <- state.acting_scroll - 1;
                  if state.acting_scroll = 0 then state.acting_unseen <- 0
                end
            | System_logs ->
                if state.system_logs_scroll > 0 then
                  state.system_logs_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:(-1)
                    ~current:state.system_logs_scroll
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
            | Keepers Keeper_detail | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message
            | Acting | Lanes | Approvals | Schedules | Verification | Harness
            | Repositories | Connectors | Tools | System_logs -> ())
       | Some "f" | Some "F" when state.view = Acting ->
           state.acting_filter <- Masc_tui_acting.next_filter state.acting_filter
       | Some "g" when state.view = Acting ->
           state.acting_scroll <- 0;
           state.acting_unseen <- 0
       | Some "g"
         when (match state.view with
               | Keepers Keeper_list | Keepers Keeper_detail -> true
               | _ -> false)
              && state.keeper_cursor < List.length state.keepers ->
           (* Toggle the approval gate for the keeper under the cursor. One
              press: the stance is in-memory and a restart returns it to
              auto, and the event line plus the red roster name say loudly
              what was armed. *)
           let keeper = List.nth state.keepers state.keeper_cursor in
           let mode =
             if List.mem keeper.k_name state.keeper_yolo_names then "auto"
             else "yolo"
           in
           launch_keeper_tool_mode_set state ~mailbox:async_messages
             ~keeper_name:keeper.k_name ~mode
       | Some "G" when state.view = Acting ->
           (* Past the end on purpose; the frame clamps it to the last page.
              The held count rather than max_int, because an event arriving
              before that frame adds one to it. *)
           state.acting_scroll <- List.length state.acting
       | Some "t" | Some "T" ->
           (* Focus the Overview task panel. The list is always on screen, but
              j/k belong to the event log until the operator asks for tasks. *)
           (match state.view with
            | Overview when Option.is_none state.task_detail_id ->
                state.task_focus <- not state.task_focus;
                if not state.task_focus then state.task_cursor <- 0
            | Keepers (Keeper_list | Keeper_detail) ->
                (* Tool calls, from the roster and from detail, the way logs
                   are: the keeper under the cursor is the one asked about. *)
                (match selected_keeper state with
                 | Some keeper ->
                     state.keeper_calls <- None;
                     state.keeper_calls_error <- None;
                     state.keeper_calls_scroll <- 0;
                     launch_keeper_calls_load state ~mailbox:async_messages
                       keeper.k_name;
                     state.view <- Keepers Keeper_calls
                 | None -> ())
            | Overview | Acting | Keepers (Keeper_logs | Keeper_calls | Keeper_message)
            | Lanes | Board | Approvals | Planning | Schedules
            | Verification | Harness | Repositories | Connectors | Tools | System_logs -> ())
       | Some "c" | Some "C" | Some "x" | Some "X" | Some "o" | Some "O" when state.view = Planning ->
           (* Goal lifecycle, detail only: the list keeps j/k/Enter and the
              letters stay navigation-free there. The first press arms, the
              same press submits; the server owns the phase rules. *)
           let action =
             match key with
             | Some ("c" | "C") -> Goal_phase.Public_action.Request_complete
             | Some ("x" | "X") -> Goal_phase.Public_action.Drop
             | _ -> Goal_phase.Public_action.Reopen
           in
           handle_goal_action_key state ~mailbox:async_messages ~action
       | Some "c" | Some "C" | Some "x" | Some "X" | Some "o" | Some "O" when state.view = Planning ->
           (* Goal lifecycle, detail only: the list keeps j/k/Enter and the
              letters stay navigation-free there. The first press arms, the
              same press submits; the server owns the phase rules. *)
           let action =
             match key with
             | Some ("c" | "C") -> Goal_phase.Public_action.Request_complete
             | Some ("x" | "X") -> Goal_phase.Public_action.Drop
             | _ -> Goal_phase.Public_action.Reopen
           in
           handle_goal_action_key state ~mailbox:async_messages ~action
       | Some "c" | Some "C" when state.view = Board ->
           (* Reply to the post being read. Same pane as a new post; the
              reply target decides the payload and where the operator
              lands after it sends. *)
           (match state.board_mode with
            | Board_read post_id ->
                state.board_mode <- Board_compose;
                state.board_compose_armed <- false;
                state.board_compose_reply_to <- Some post_id;
                state.board_post_error <- None
            | Board_list | Board_compose -> ())
       | Some "v" | Some "V" when state.view = Board ->
           (* Lowercase votes up, uppercase votes down -- the shift is the
              direction, so neither reading needs a second keypress to
              choose one. *)
           handle_board_vote_key state ~mailbox:async_messages
             ~up:(match key with Some "v" -> true | _ -> false)
       | Some "x" | Some "X" when state.view = Schedules ->
           (* Two presses, like every irreversible action here: the first
              names the schedule, the second cancels it. Whether the row is
              still cancellable is the server's store rules to say. *)
           handle_schedule_cancel_key state ~mailbox:async_messages
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
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Repositories | Connectors | Tools | System_logs -> ())
       | Some "m" | Some "M" | Some "c" | Some "C" ->
           (* Chat, from the roster as well as from detail, for the same reason
              logs are reachable from both: the keeper an operator wants to
              talk to is the one under the cursor. [c] is an alias for [m]
              because the footer names the action rather than the mnemonic. *)
           (match state.view with
            | Keepers Keeper_list
              when Option.is_none state.keepers_error
                   && state.keeper_cursor < List.length state.keepers ->
                let keeper = List.nth state.keepers state.keeper_cursor in
                open_message_for_keeper ~return_to:Keeper_chat_return_list state
                  keeper.k_name;
                launch_keeper_history_load state ~mailbox:async_messages
                  ~keeper_name:keeper.k_name;
                state.view <- Keepers Keeper_message
            | Keepers Keeper_detail
              when Option.is_none state.keepers_error
                   && state.keeper_cursor < List.length state.keepers ->
                let keeper = List.nth state.keepers state.keeper_cursor in
                open_message_for_keeper ~return_to:Keeper_chat_return_detail
                  state keeper.k_name;
                launch_keeper_history_load state ~mailbox:async_messages
                  ~keeper_name:keeper.k_name;
                state.view <- Keepers Keeper_message
            | Keepers Keeper_detail | Keepers Keeper_list
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Repositories | Connectors | Tools | System_logs -> ())
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
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Repositories | Connectors | Tools | System_logs -> ())
       | Some "s" | Some "S" ->
           (match state.view with
            | Keepers (Keeper_list | Keeper_detail) ->
                handle_keeper_action state ~base_path ~mailbox:async_messages
                  Keeper_control.Shutdown
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Repositories | Connectors | Tools | System_logs -> ())
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
                     state.board_compose_reply_to <- None;
                     state.board_post_error <- None
                 | Board_read _ | Board_compose -> ())
            | Keepers (Keeper_list | Keeper_detail) ->
                handle_keeper_action state ~base_path ~mailbox:async_messages
                  Keeper_control.Wakeup
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Approvals | Planning | Schedules | Verification | Harness
            | Repositories | Connectors | Tools | System_logs
            -> ())
       | Some "e" | Some "E" ->
           (* Settings edit hands the terminal to $EDITOR, so it cannot live
              inside the keeper-action pipeline: the loop is inside the
              editor, and the POST happens only after the editor returns. *)
           (match state.view with
            | Keepers (Keeper_list | Keeper_detail) -> handle_keeper_settings_edit ()
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Repositories | Connectors | Tools | System_logs -> ())
       | Some "a" | Some "A" ->
           (match state.view with
            | Keepers (Keeper_list | Keeper_detail) -> handle_keeper_create ()
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Repositories | Connectors | Tools | System_logs -> ())
      | _ -> ());

      (* A refresh already running was asked for what the surface open when it
         started needed, so it brings nothing for this one. The need is recorded
         as fetched only once a request has actually gone out; until then the
         next pass through the loop tries again. *)
      let needed = Masc_tui_types.surface_needs state.view in
      if needed <> !drawn_needs && not !http_refresh_inflight then begin
        drawn_needs := needed;
        start_http_refresh state ~host:(Env_config_core.masc_host ())
          ~port:state.port ~refresh_inflight:http_refresh_inflight
          ~mailbox:async_messages
      end;

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
        (* The retry a closed feed waits for. *)
        open_observer_if_due state ~retry_closed:true ~host ~port
          ~mailbox:async_messages;
        start_http_refresh state ~host ~port
          ~refresh_inflight:http_refresh_inflight
          ~mailbox:async_messages;
        (* Also refresh logs / Board detail if viewing them. *)
        (match state.view with
         | Keepers (Keeper_logs | Keeper_detail) ->
             load_selected_keeper_logs state base_path 200
               (List.nth_opt state.keepers state.keeper_cursor)
         | Keepers Keeper_calls ->
             (match selected_keeper state with
              | Some keeper ->
                  launch_keeper_calls_load state ~mailbox:async_messages
                    keeper.k_name
              | None -> ())
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
         | Lanes -> launch_lanes_load state ~mailbox:async_messages
         | Harness -> launch_harness_load state ~mailbox:async_messages
         | Repositories ->
             (* Registration and keeper assignment change from elsewhere, so
                the list is refreshed on the tick like the surfaces above. *)
             launch_repositories_load state ~mailbox:async_messages
         | Connectors ->
             (* Reachability is the column that moves on its own. *)
             launch_connectors_load state ~mailbox:async_messages
         | Tools ->
             (* The inventory is near-static, but a tool whose projection
                changes is exactly what this surface is read for. *)
             launch_tools_load state ~mailbox:async_messages
         | Schedules ->
             (* Rows cross their due time and turn terminal while an operator
                watches; the page that answers "why is this keeper awake"
                holds a reading from when the operator arrived otherwise. *)
             launch_schedules_load state ~mailbox:async_messages
         | Overview | Acting | Keepers Keeper_list | Keepers Keeper_message
         | Approvals | Planning | System_logs -> ());
        last_check_ns := now_ns;
        Render_schedule.request render_schedule Render_schedule.Background
      end;

      (match
         Render_schedule.take render_schedule
           ~now_ns:(Mtime_clock.elapsed_ns ())
       with
       | Render_schedule.Render ->
           let frame, clamped = render state in
           (* The frame is what the operator will act on next, so the scroll it
              had to clamp is the scroll the next keypress moves from. Applied
              here rather than inside the drawing: a surface whose row count
              only exists once the frame is built cannot be bounded before it,
              but the drawing does not have to be the thing that stores it. *)
           Option.iter (apply_clamped_scroll state) clamped;
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
