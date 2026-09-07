open Alcotest
module Driver = Masc.Browser_webdriver

let test_upgrade_eof_isolated_from_server () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let socket = Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:1
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
      let port = match Eio.Net.listening_addr socket with
        | `Tcp (_, port) -> port | _ -> fail "expected TCP listener" in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Switch.run (fun peer_sw ->
          let flow, _ = Eio.Net.accept ~sw:peer_sw socket in
          let reader = Eio.Buf_read.of_flow ~max_size:16384 flow in
          let rec headers () =
            if Eio.Buf_read.line reader <> "" then headers () in
          headers ();
          (* Close after reading the complete request, before any upgrade
             response. This reaches the native ws-direct read_head EOF. *)
          Eio.Flow.close flow));
      let deleted = ref false in
      let request ~method_ ~path ~body:_ = match method_, path with
        | `POST, "/session" -> Ok (`Assoc ["sessionId",`String "owned";
            "capabilities",`Assoc ["webSocketUrl",`String
              (Printf.sprintf "ws://127.0.0.1:%d/session/owned" port)]])
        | `DELETE, "/session/owned" -> deleted := true; Ok `Null
        | _ -> fail "failed setup exposed a browser action" in
      let driver = Driver.create ~request
          ~start_downloads:(Masc.Browser_bidi_downloads.start ~sw ~env
            ~root:(Filename.get_temp_dir_name ())
            ~publish:(fun _ -> fail "EOF setup must not publish an artifact")) in
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2. (fun () ->
        (match Driver.execute driver (Browser_lane.Session_open {headless=None}) with
         | Browser_lane.Refused detail ->
           check string "expected transport EOF becomes a setup error"
             "Firefox download setup failed: EOF during Firefox BiDi setup" detail
         | _ -> fail "EOF upgrade unexpectedly opened a browser");
        check bool "known Classic session rolled back" true !deleted;
        let alive, alive_u = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve alive_u true);
        check bool "server root switch still runs siblings" true (Eio.Promise.await alive))))

let () = run "browser BiDi lifecycle" ["transport",[
  test_case "upgrade EOF cannot fail the server switch" `Quick test_upgrade_eof_isolated_from_server]]
