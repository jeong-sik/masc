(** Keeper Chat AG-UI Bridge — SDK-aligned token streaming

    Translates keeper chat interactions to AG-UI protocol events.
    Enables SDK consumers (CopilotKit, custom UIs) to receive
    keeper responses as standard TEXT_MESSAGE_CONTENT delta events.

    Event sequence for a keeper chat turn:
    1. RUN_STARTED (thread=keeper_name)
    2. TEXT_MESSAGE_START (role=assistant, message_id=unique)
    3. TEXT_MESSAGE_CONTENT* (delta=chunk) — one per streaming chunk
    4. TEXT_MESSAGE_END
    5. RUN_FINISHED

    @since 2.102.0 *)

(** {1 Session State} *)

type chat_session = {
  keeper_name : string;
  thread_id : string;
  run_id : string;
  mutable message_seq : int;
}

let session_counter = ref 0

let make_session ~keeper_name =
  incr session_counter;
  let run_id = Printf.sprintf "keeper-%s-%d-%d"
    keeper_name (int_of_float (Time_compat.now () *. 1000.0)) !session_counter in
  let thread_id = Printf.sprintf "keeper-chat-%s" keeper_name in
  { keeper_name; thread_id; run_id; message_seq = 0 }

let next_message_id session =
  session.message_seq <- session.message_seq + 1;
  Printf.sprintf "%s-msg-%d" session.run_id session.message_seq

(** {1 AG-UI Event Generators} *)

let event_run_started session : Ag_ui.event =
  Ag_ui.make_event
    ~thread_id:session.thread_id
    ~run_id:(Some session.run_id)
    Ag_ui.Run_started

let event_text_start session : string * Ag_ui.event =
  let msg_id = next_message_id session in
  msg_id,
  Ag_ui.make_event
    ~thread_id:session.thread_id
    ~run_id:(Some session.run_id)
    ~message_id:(Some msg_id)
    ~role:(Some Ag_ui.Assistant)
    Ag_ui.Text_message_start

let event_text_delta session ~message_id ~delta : Ag_ui.event =
  Ag_ui.make_event
    ~thread_id:session.thread_id
    ~run_id:(Some session.run_id)
    ~message_id:(Some message_id)
    ~delta:(Some delta)
    Ag_ui.Text_message_content

let event_text_end session ~message_id : Ag_ui.event =
  Ag_ui.make_event
    ~thread_id:session.thread_id
    ~run_id:(Some session.run_id)
    ~message_id:(Some message_id)
    Ag_ui.Text_message_end

let event_run_finished session : Ag_ui.event =
  Ag_ui.make_event
    ~thread_id:session.thread_id
    ~run_id:(Some session.run_id)
    Ag_ui.Run_finished

let event_run_error session ~error : Ag_ui.event =
  Ag_ui.make_event
    ~thread_id:session.thread_id
    ~run_id:(Some session.run_id)
    ~custom_name:(Some "error")
    ~custom_value:(Some (`Assoc [("message", `String error)]))
    Ag_ui.Run_error

(** {1 Streaming Adapter}

    Converts a keeper response (full text) into a sequence of AG-UI events.
    For post-assembly chunking (current backend), splits the response into
    fixed-size chunks and emits TEXT_MESSAGE_CONTENT events.

    When native provider streaming is available, this adapter should be
    replaced with direct delta forwarding from the model client. *)

let chunk_size = 64  (* target bytes per chunk *)

(** Advance [pos] to the next UTF-8 character boundary at or after [pos].
    UTF-8 continuation bytes have the form 10xxxxxx (0x80..0xBF). *)
let utf8_safe_boundary s pos =
  let len = String.length s in
  if pos >= len then len
  else
    let p = ref pos in
    while !p < len && Char.code (String.get s !p) land 0xC0 = 0x80 do
      incr p
    done;
    !p

let events_for_response session ~response : Ag_ui.event list =
  let msg_id, start_event = event_text_start session in
  let chunks =
    let len = String.length response in
    let rec split pos acc =
      if pos >= len then List.rev acc
      else
        let end_pos = utf8_safe_boundary response (min (pos + chunk_size) len) in
        let chunk = String.sub response pos (end_pos - pos) in
        split end_pos (chunk :: acc)
    in
    split 0 []
  in
  let delta_events = List.map (fun delta ->
    event_text_delta session ~message_id:msg_id ~delta
  ) chunks in
  [event_run_started session; start_event]
  @ delta_events
  @ [event_text_end session ~message_id:msg_id;
     event_run_finished session]

(** Emit events as SSE data lines. *)
let sse_for_response session ~response : string =
  let events = events_for_response session ~response in
  String.concat "" (List.map Ag_ui.event_to_sse events)

(** Emit error as SSE. *)
let sse_for_error session ~error : string =
  let events = [
    event_run_started session;
    event_run_error session ~error;
  ] in
  String.concat "" (List.map Ag_ui.event_to_sse events)
