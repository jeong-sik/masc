module Reader = Masc_tui_execute_stream

(* Raised from [on_chunk] when the reader refuses a frame, to end the
   connection that sent it. *)
exception Close_connection

let connection_ended ~refused outcome =
  match refused, outcome with
  | Some failure, (Ok () | Error _) -> Reader.failure_to_string failure
  | None, Ok () -> "the server closed the Execute output stream"
  | None, Error detail -> detail
;;

let run ~clock ~reconnect_s ~post_interval_s ~reader ~observe ~on_view ~on_ended =
  let posted = ref (Reader.version reader) in
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
    let outcome =
      try
        observe ~on_chunk:(fun chunk ->
          match Reader.feed reader ~now:(Eio.Time.now clock) chunk with
          | Reader.Keep_reading -> ()
          | Reader.Reconnect failure ->
            refused := Some failure;
            raise Close_connection)
      with
      | Close_connection -> Ok ()
    in
    post ();
    on_ended (connection_ended ~refused:!refused outcome)
  in
  let keep_connected () =
    while true do
      read_one_connection ();
      Eio.Time.sleep clock reconnect_s
    done
  in
  let keep_posting () =
    while true do
      Eio.Time.sleep clock post_interval_s;
      post ()
    done
  in
  Eio.Fiber.both keep_connected keep_posting
;;
