module Reader = Masc_tui_execute_stream

(* Raised from [on_chunk] when the reader refuses a frame, to end the
   connection that sent it. *)
exception Close_connection

type observe_error =
  | Transport_failure of string
  | Http_refusal of { status : int; detail : string }
  | Unattested of { status : int; detail : string }

type stop_reason =
  | Http_status of int
  | Unattested_response of int
  | Unexpected_error

type ending =
  | Retry_after of { detail : string; delay_s : float }
  | Reopen_required of { reason : stop_reason; detail : string }

type connection_end =
  | Reader_refusal of Reader.failure
  | Server_closed
  | Observe_error of observe_error

let connection_ended ~refused outcome =
  match refused, outcome with
  | Some failure, (Ok () | Error _) -> Reader_refusal failure
  | None, Ok () -> Server_closed
  | None, Error error -> Observe_error error
;;

let detail = function
  | Reader_refusal failure -> Reader.failure_to_string failure
  | Server_closed -> "the server closed the Execute output stream"
  | Observe_error (Transport_failure detail | Http_refusal { detail; _ }
                   | Unattested { detail; _ }) -> detail
;;

let stop_reason = function
  | Reader_refusal _ | Server_closed | Observe_error (Transport_failure _) -> None
  | Observe_error (Unattested { status; _ }) -> Some (Unattested_response status)
  | Observe_error (Http_refusal { status; _ }) ->
    if status = 408 || status = 425 || status = 429 || (status >= 500 && status <= 599)
    then None else Some (Http_status status)
;;

let run ~clock ~reconnect_s ~max_reconnect_s ~stable_s ~monotonic_now
    ~post_interval_s ~reader ~observe ~on_view ~on_ended =
  let posted = ref (Reader.version reader) in
  let next_delay_s = ref reconnect_s in
  let post () =
    let version = Reader.version reader in
    if version <> !posted
    then (
      posted := version;
      on_view (Reader.view reader))
  in
  let read_one_connection () =
    Reader.started reader;
    let refused = ref None in
    let valid_since = ref None in
    let outcome =
      try
        observe ~on_chunk:(fun chunk ->
          match Reader.feed reader ~now:(Eio.Time.now clock) chunk with
          | Reader.Keep_reading ->
            if Option.is_none !valid_since && Reader.synchronized reader
            then valid_since := Some (monotonic_now ())
          | Reader.Reconnect failure ->
            refused := Some failure;
            raise Close_connection)
      with
      | Close_connection -> Ok ()
    in
    (* [post] can wait for mailbox capacity. That wait is not time the
       connection stayed open, so take the end time before posting. *)
    let ended_at = monotonic_now () in
    let ending = connection_ended ~refused:!refused outcome in
    post ();
    match stop_reason ending with
    | None ->
      (* An initial frame on a short-lived connection is not recovery. A
         synchronized connection must stay open for a heartbeat interval; the
         monotonic clock also covers quiet streams whose heartbeat is a comment. *)
      let stable = match !valid_since with
        | Some since -> ended_at -. since >= stable_s
        | None -> false in
      let delay_s = if stable then reconnect_s else !next_delay_s in
      next_delay_s := min max_reconnect_s (2.0 *. delay_s);
      on_ended (Retry_after { detail = detail ending; delay_s });
      Some delay_s
    | Some reason ->
      on_ended (Reopen_required { reason; detail = detail ending });
      None
  in
  let rec keep_connected () =
    match read_one_connection () with
    | None -> ()
    | Some delay_s ->
      Eio.Time.sleep clock delay_s;
      keep_connected ()
  in
  let keep_posting () =
    while true do
      Eio.Time.sleep clock post_interval_s;
      post ()
    done
  in
  (* A permanent refusal ends this job and its posting fiber. The tab owner
     remains registered until the operator leaves the tab. *)
  Eio.Fiber.first keep_connected keep_posting
;;
