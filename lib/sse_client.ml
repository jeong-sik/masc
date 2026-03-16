(** SSE Client - Server-Sent Events consumer using Eio

    Connects to MASC server's SSE endpoint and streams events
    in real-time for the TUI dashboard.

    Usage:
    {[
      let client = Sse_client.create ~sw ~env "http://127.0.0.1:8935/sse?room=me" in
      Sse_client.connect client ~on_event:(fun ev ->
        Eio.traceln "Event: %s\n" ev.data
      )
    ]}
*)

(** SSE event type *)
type event = {
  id: string option;
  event_type: string;
  data: string;
  retry: int option;
}

(** Client state *)
type state =
  | Disconnected
  | Connecting
  | Connected
  | Reconnecting of int  (* retry count *)
  | Closed

(** SSE client *)
type t = {
  url: string;
  mutable state: state;
  mutable last_event_id: string option;
  mutable retry_ms: int;
  max_retries: int;
}

(** Default configuration *)
let default_retry_ms = 3000
let default_max_retries = 10

(** Create a new SSE client *)
let create ?(retry_ms = default_retry_ms) ?(max_retries = default_max_retries) url = {
  url;
  state = Disconnected;
  last_event_id = None;
  retry_ms;
  max_retries;
}

(** Parse a single SSE event from lines *)
let parse_event (lines : string list) : event option =
  if lines = [] then None
  else
    let id = ref None in
    let event_type = ref "message" in
    let data_parts = ref [] in
    let retry = ref None in
    List.iter (fun line ->
      if String.length line > 0 then
        (* Check for field: value format *)
        match String.index_opt line ':' with
        | Some 0 ->
            (* Comment line starting with : *)
            ()
        | Some idx ->
            let field = String.sub line 0 idx in
            let value_start = if idx + 1 < String.length line && line.[idx + 1] = ' '
                              then idx + 2 else idx + 1 in
            let value = if value_start < String.length line
                        then String.sub line value_start (String.length line - value_start)
                        else "" in
            (match field with
             | "id" -> id := Some value
             | "event" -> event_type := value
             | "data" -> data_parts := value :: !data_parts
             | "retry" -> retry := int_of_string_opt value
             | _ -> ())  (* Unknown field, ignore *)
        | None ->
            (* No colon, treat entire line as field with empty value *)
            ()
    ) lines;
    if !data_parts = [] then None
    else Some {
      id = !id;
      event_type = !event_type;
      data = String.concat "\n" (List.rev !data_parts);
      retry = !retry;
    }

(** Read lines from a stream until double newline (event boundary) *)
let read_event_lines (flow : _ Eio.Flow.source) : string list option =
  let buf = Buffer.create 256 in
  let lines = ref [] in
  let rec read_char () =
    let b = Cstruct.create 1 in
    try
      let n = Eio.Flow.single_read flow b in
      if n = 0 then None
      else begin
        let c = Cstruct.get_char b 0 in
        if c = '\n' then begin
          let line = Buffer.contents buf in
          Buffer.clear buf;
          if line = "" || line = "\r" then
            (* Empty line = end of event *)
            if !lines = [] then read_char ()  (* Skip leading empty lines *)
            else Some (List.rev !lines)
          else begin
            (* Remove trailing \r if present *)
            let line = if String.length line > 0 && line.[String.length line - 1] = '\r'
                       then String.sub line 0 (String.length line - 1)
                       else line in
            lines := line :: !lines;
            read_char ()
          end
        end else begin
          Buffer.add_char buf c;
          read_char ()
        end
      end
    with
    | End_of_file -> if !lines = [] then None else Some (List.rev !lines)
    | Eio.Io _ -> if !lines = [] then None else Some (List.rev !lines)
  in
  read_char ()

(** Format state as string *)
let state_to_string = function
  | Disconnected -> "disconnected"
  | Connecting -> "connecting"
  | Connected -> "connected"
  | Reconnecting n -> Printf.sprintf "reconnecting (%d)" n
  | Closed -> "closed"

(** Connect and stream events using Eio HTTP client

    Note: This is a simplified implementation. In production,
    you'd want to use a full HTTP client like cohttp-eio.
    For now, we use a raw TCP connection with manual HTTP parsing.
*)
let connect_raw ~sw (net : _ Eio.Net.t) (t : t) ~on_event ~on_state_change =
  t.state <- Connecting;
  on_state_change t.state;

  (* Parse URL *)
  let uri = Uri.of_string t.url in
  let host = Uri.host uri |> Option.value ~default:"127.0.0.1" in
  let port = Uri.port uri |> Option.value ~default:8935 in
  let path = Uri.path_and_query uri in

  (* Connect to server *)
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow = Eio.Net.connect ~sw net addr in

  (* Send HTTP request *)
  let request = Printf.sprintf
    "GET %s HTTP/1.1\r\n\
     Host: %s:%d\r\n\
     Accept: text/event-stream\r\n\
     Cache-Control: no-cache\r\n\
     Connection: keep-alive\r\n\
     %s\
     \r\n"
    path host port
    (match t.last_event_id with
     | Some id -> Printf.sprintf "Last-Event-ID: %s\r\n" id
     | None -> "")
  in
  Eio.Flow.copy_string request flow;

  (* Read HTTP response headers (simplified) *)
  let buf = Buffer.create 256 in
  let rec skip_headers () =
    let b = Cstruct.create 1 in
    let n = Eio.Flow.single_read flow b in
    if n > 0 then begin
      Buffer.add_char buf (Cstruct.get_char b 0);
      let s = Buffer.contents buf in
      if String.length s >= 4 &&
         String.sub s (String.length s - 4) 4 = "\r\n\r\n" then
        ()  (* End of headers *)
      else
        skip_headers ()
    end
  in
  skip_headers ();

  t.state <- Connected;
  on_state_change t.state;

  (* Read events *)
  let rec read_events () =
    match read_event_lines flow with
    | None ->
        t.state <- Disconnected;
        on_state_change t.state
    | Some lines ->
        (match parse_event lines with
         | None -> ()
         | Some ev ->
             (match ev.id with
              | Some id -> t.last_event_id <- Some id
              | None -> ());
             (match ev.retry with
              | Some ms -> t.retry_ms <- ms
              | None -> ());
             on_event ev);
        read_events ()
  in
  read_events ()

(** Connect with automatic reconnection *)
let connect_with_retry ~sw (net : _ Eio.Net.t) (clock : _ Eio.Time.clock) (t : t)
    ~on_event ~on_state_change =
  let rec loop retry_count =
    if t.state = Closed then ()
    else begin
      try
        connect_raw ~sw net t ~on_event ~on_state_change
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          if retry_count < t.max_retries && t.state <> Closed then begin
            t.state <- Reconnecting retry_count;
            on_state_change t.state;
            Eio.Time.sleep clock (float_of_int t.retry_ms /. 1000.0);
            loop (retry_count + 1)
          end else begin
            t.state <- Closed;
            on_state_change t.state;
            raise exn
          end
    end
  in
  loop 0

(** Close the client *)
let close t =
  t.state <- Closed

(** Get current state *)
let get_state t = t.state

(** Get last event ID *)
let get_last_event_id t = t.last_event_id

(** Pretty-print an event *)
let pp_event (ev : event) : string =
  let id_str = match ev.id with Some id -> Printf.sprintf "id=%s " id | None -> "" in
  Printf.sprintf "[%s%s] %s" id_str ev.event_type ev.data
