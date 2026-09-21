module Pool = Masc_http_client.Pool

(* Exercise the production body through Piaf after an HTTP/1.1 upgrade,
   without certificates or external services. Only this fixture enables h2c;
   the production pool negotiates HTTP/2 over TLS instead. *)
let line flow =
  let byte = Cstruct.create 1 in
  let out = Buffer.create 80 in
  let rec read () =
    Eio.Flow.read_exact flow byte;
    match Cstruct.get_char byte 0 with
    | '\n' -> String.trim (Buffer.contents out)
    | c -> Buffer.add_char out c; read ()
  in
  read ()

let start_server ~sw env payload =
  let listener = Eio.Net.listen ~sw ~backlog:4 env#net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let uploads = ref 0 in
  let handler reqd =
    let request = H2.Reqd.request reqd in
    if request.H2.Request.meth = `GET then
      H2.Reqd.respond_with_string reqd (H2.Response.create `OK) "ready"
    else (
      let received = Buffer.create (String.length payload) in
      let body = H2.Reqd.request_body reqd in
      let rec read () =
        H2.Body.Reader.schedule_read body
          ~on_read:(fun bytes ~off ~len ->
            Buffer.add_string received (Bigstringaf.substring bytes ~off ~len);
            read ())
          ~on_eof:(fun () ->
            Alcotest.(check string) "the peer receives every request byte"
              payload (Buffer.contents received);
            Alcotest.(check (option string)) "fixed Content-Length is preserved"
              (Some (string_of_int (String.length payload)))
              (H2.Headers.get request.headers "content-length");
            incr uploads;
            (* Only END_STREAM permits a response: a server replying after
               Content-Length alone would hide a body that never closes. *)
            H2.Reqd.respond_with_string reqd (H2.Response.create `OK) "complete")
      in
      read ())
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec accept () =
      Eio.Switch.run (fun connection_sw ->
        let flow, address = Eio.Net.accept ~sw:connection_sw listener in
        match line flow with
        | exception End_of_file -> () (* Pool's connection probe. *)
        | request_line ->
          let headers = ref [] in
          let rec read_headers () =
            match line flow with
            | "" -> ()
            | value ->
              let colon = String.index value ':' in
              headers :=
                (String.sub value 0 colon,
                 String.trim (String.sub value (colon + 1)
                   (String.length value - colon - 1))) :: !headers;
              read_headers ()
          in
          read_headers ();
          Alcotest.(check string) "upgrade begins with a GET"
            "GET /upload HTTP/1.1" request_line;
          let connection =
            H2.Server_connection.create_h2c
              ~config:{ H2.Config.default with
                initial_window_size = H2.Settings.default.initial_window_size }
              ~headers:(Httpun_types.Headers.of_list (List.rev !headers))
              ~target:"/upload" ~meth:`GET handler
            |> Result.get_ok
          in
          Eio.Flow.copy_string
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n" flow;
          Gluten_eio.Server.create_connection_handler
            ~read_buffer_size:H2.Config.default.read_buffer_size
            ~protocol:(module H2.Server_connection)
            ~sw:connection_sw connection address flow);
      accept ()
    in
    accept ());
  let port = match Eio.Net.listening_addr listener with
    | `Tcp (_, port) -> port
    | `Unix _ -> assert false in
  Printf.sprintf "http://127.0.0.1:%d/upload" port, uploads

let require = function Ok value -> value | Error detail -> Alcotest.fail detail

let test_upload length () =
  Eio_main.run (fun env ->
    Eio.Time.with_timeout_exn env#clock 5. (fun () ->
      Eio.Switch.run (fun sw ->
        let payload = String.make length 'x' in
        let url, uploads = start_server ~sw env payload in
        let config = { Piaf.Config.default with h2c_upgrade = true } in
        let client =
          match Piaf.Client.create ~config ~sw env (Uri.of_string url) with
          | Ok client -> client
          | Error error -> Alcotest.fail (Piaf.Error.to_string error)
        in
        let response = function
          | Ok response -> response
          | Error error -> Alcotest.fail (Piaf.Error.to_string error)
        in
        let ready = Piaf.Client.get client "/upload" |> response in
        Alcotest.(check string) "h2c upgrade completed" "ready"
          (Piaf.Body.to_string ready.body |> Result.map_error Piaf.Error.to_string
           |> require);
        Alcotest.(check bool) "the peer is speaking HTTP2" true
          (ready.version = Piaf.Versions.HTTP.HTTP_2);
        let result = Piaf.Client.post client "/upload"
            ~body:(Pool.For_testing.request_body payload) |> response in
        Alcotest.(check int) "successful response" 200
          (Piaf.Status.to_code result.status);
        Alcotest.(check string) "response follows END_STREAM" "complete"
          (Piaf.Body.to_string result.body |> Result.map_error Piaf.Error.to_string
           |> require);
        Alcotest.(check int) "exactly one completed upload, no retry" 1 !uploads;
        Piaf.Client.shutdown client)))

let () =
  Alcotest.run "production HTTP2 request body via Piaf"
    [ "complete upload",
      [ Alcotest.test_case "empty body terminates" `Quick (test_upload 0)
      ; Alcotest.test_case "window exhaustion delays END_STREAM" `Quick
          (test_upload
             (Int32.to_int H2.Settings.default.initial_window_size + 1)) ] ]
