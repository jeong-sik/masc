open Alcotest
module Driver = Masc.Browser_webdriver
module Lane = Browser_lane
let test_session_lifecycle () =
  Eio_main.run (fun _ ->
    let calls = ref [] in
    let request ~method_ ~path ~body:_ =
      calls := (method_, path) :: !calls;
      match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId", `String "owned"])
      | `DELETE, "/session/owned" -> Ok `Null
      | `POST, "/session/owned/url" -> Error (Driver.Remote {code="invalid session id";message="Firefox exited"})
      | _ -> fail ("unexpected request: " ^ path)
    in
    let driver = Driver.create ~request () in
    (match Driver.execute driver Lane.Tabs_list with
     | Lane.Refused _ -> () | _ -> fail "closed session must refuse reads");
    check int "closed read never contacted driver" 0 (List.length !calls);
    let open_session () = Driver.execute driver (Lane.Session_open {headless=Some true}) in
    ignore (open_session ()); ignore (open_session ());
    check int "reopening keeps owned session" 1 (List.length !calls);
    (match Driver.execute driver (Lane.Page_goto {url="https://example.org";tab_id=None}) with
     | Lane.Refused _ -> () | _ -> fail "browser exit must be visible");
    ignore (open_session ());
    check int "session can recover after Firefox exits" 3 (List.length !calls);
    List.iter (fun verb ->
      check bool "session lifecycle cannot be classified as a read" false
        (Lane.verb_is_read verb))
      [ Lane.Session_open {headless=Some true}; Lane.Session_close ];
    (match Driver.execute driver Lane.Session_close with
     | Lane.Answered _ -> () | _ -> fail "session close failed");
    check bool "close issues WebDriver DELETE" true
      (List.hd !calls = (`DELETE, "/session/owned"));
    (match Driver.execute driver Lane.Tabs_list with
     | Lane.Refused _ -> () | _ -> fail "closed session must refuse subsequent reads");
    check int "closed read adds no backend request" 4 (List.length !calls))
let test_backend_failure () =
  match Driver.decode_response ~status:404
    {|{"value":{"error":"no such window","message":"tab closed"}}|} with
  | Error (Driver.Remote {code="no such window";message="tab closed"}) -> ()
  | _ -> fail "WebDriver errors must retain their code and message"
let test_malformed_success () =
  match Driver.decode_response ~status:200 {|{"ok":true}|} with
  | Error (Driver.Protocol _) -> ()
  | _ -> fail "HTTP 200 without a WebDriver value is not success"
let test_closed_current_window () =
  Eio_main.run (fun _ ->
    let selected = ref [] in
    let request ~method_ ~path ~body = match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId", `String "owned"])
      | `GET, "/session/owned/window/handles" -> Ok (`List [`String "remaining"])
      | `GET, "/session/owned/window" ->
        Error (Driver.Remote {code="no such window";message="current tab closed"})
      | `POST, "/session/owned/window" ->
        selected := body :: !selected; Ok `Null
      | `POST, "/session/owned/execute/sync" ->
        Ok (`Assoc ["url", `String "https://example.org"; "title", `String "Remaining"])
      | _ -> fail ("unexpected request: " ^ path) in
    let driver = Driver.create ~request () in
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    (match Driver.execute driver Lane.Tabs_list with
     | Lane.Answered (`Assoc fields) ->
       (match List.assoc "data" fields with
        | `List [`Assoc tab] ->
          check bool "remaining tab selected" true (List.assoc "active" tab = `Bool true);
          check bool "stable tab ID assigned" true (List.assoc "id" tab = `Int 1)
        | _ -> fail "remaining tab missing")
     | _ -> fail "closed current window must not prevent discovery");
    check int "read and restore remaining window" 2 (List.length !selected))

let test_timeout_releases_session () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    let cancelled = ref false in
    let blocked = ref true in
    let request ~method_ ~path ~body:_ = match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId", `String "owned"])
      | `POST, "/session/owned/execute/sync" when !blocked ->
        Eio.Switch.run (fun sw ->
          Eio.Switch.on_release sw (fun () -> cancelled := true);
          Eio.Fiber.await_cancel ())
      | `POST, "/session/owned/execute/sync" -> Ok (`Assoc ["text", `String "recovered"])
      | _ -> fail ("unexpected request: " ^ path) in
    let driver = Driver.create ~request () in
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    Eio.Switch.run (fun sw ->
      Lane.install_automation_executor (Some (Driver.execute driver));
      Eio.Switch.on_release sw (fun () -> Lane.install_automation_executor None);
      let read () = Lane.issue ~lane_name:"automation"
          ~verb:(Lane.Page_read {tab_id=None;max_chars=None}) ~timeout_sec:0.01 in
      (match read () with Lane.Timed_out -> () | _ -> fail "native deadline not enforced");
      check bool "I/O cancelled before timeout returns" true !cancelled;
      blocked := false;
      (match read () with
       | Lane.Answered _ -> ()
       | _ -> fail "cancelled operation left the session mutex unusable")))

let test_shutdown_transport_lifetime () =
  Eio_main.run (fun _ ->
    let transport_live = ref true in
    let deleted = ref false in
    let cleanup_released = ref false in
    let request ~method_ ~path ~body:_ =
      if not !transport_live then fail "released normal transport used during shutdown";
      match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId", `String "owned"])
      | _ -> fail ("unexpected normal request: " ^ path) in
    let driver = Driver.create ~request () in
    Eio.Switch.run (fun root ->
      Eio.Switch.on_release root (fun () ->
        Eio.Switch.run_protected (fun cleanup ->
          let request ~method_ ~path ~body:_ =
            Eio.Switch.on_release cleanup (fun () -> cleanup_released := true);
            match method_, path with
            | `DELETE, "/session/owned" -> deleted := true; Ok `Null
            | _ -> fail ("unexpected cleanup request: " ^ path) in
          match Driver.close ~request driver with
          | Ok () -> () | Error error -> fail (Driver.error_message error)));
      ignore (Driver.execute driver (Lane.Session_open {headless=None}));
      (* Connections created after the browser hook are released first. *)
      Eio.Switch.on_release root (fun () -> transport_live := false));
    check bool "owned session deleted after normal transport release" true !deleted;
    check bool "cleanup transport released" true !cleanup_released;
    (match Driver.execute driver Lane.Tabs_list with
     | Lane.Refused _ -> () | _ -> fail "deleted session still appears open"))

let test_selected_binary () =
  Eio_main.run (fun _ ->
    let requests = ref [] in
    let request ~method_ ~path ~body =
      match method_, path with
      | `POST, "/session" ->
        requests := body :: !requests;
        Error (Driver.Remote {code="session not created";message="invalid configured browser"})
      | _ -> fail "unexpected browser request" in
    let driver = Driver.create ~binary:"/test/Zen.app/Contents/MacOS/zen" ~request () in
    (match Driver.execute driver (Lane.Session_open {headless=Some true}) with
     | Lane.Refused _ -> () | _ -> fail "explicit browser failure must remain visible");
    check int "no implicit fallback session" 1 (List.length !requests);
    let open Yojson.Safe.Util in
    let sent = Option.get (List.hd !requests) in
    let options = sent |> member "capabilities" |> member "alwaysMatch" |> member "moz:firefoxOptions" in
    check string "configured Zen binary forwarded exactly" "/test/Zen.app/Contents/MacOS/zen"
      (options |> member "binary" |> to_string);
    let default = Driver.create ~request () in
    ignore (Driver.execute default (Lane.Session_open {headless=None}));
    let sent = Option.get (List.hd !requests) in
    check bool "default discovery leaves binary capability absent" true
      ((sent |> member "capabilities" |> member "alwaysMatch" |> member "moz:firefoxOptions" |> member "binary") = `Null))

let test_browser_configuration () =
  let parse text = match Otoml.Parser.from_string_result text with
    | Error detail -> fail detail | Ok toml -> Masc.Browser_configuration.parse toml in
  (match parse "" with Ok Masc.Browser_configuration.Disabled -> () | _ -> fail "missing browser config");
  (match parse {|[browser]
webdriver_url = "http://127.0.0.1:4444/"
binary = "/test/Zen.app"
|} with
   | Ok (Masc.Browser_configuration.Webdriver {endpoint="http://127.0.0.1:4444";binary=Some "/test/Zen.app"}) -> ()
   | _ -> fail "explicit browser configuration lost");
  List.iter (fun text -> check bool "invalid browser config is refused" true (Result.is_error (parse text)))
    [{|[browser]
binary = "/test/Zen.app"|}; {|[browser]
webdriver_url = "http://example.org:4444"|}; {|[browser]
webdriver_url = "http://127.0.0.1:4444"
binary = "Zen.app"|}; {|[browser]
webdriver_url = "http://127.0.0.1:4444"
binary = false|}]

let () = run "native Firefox lane" ["behavior", [
  test_case "session ownership and crash recovery" `Quick test_session_lifecycle;
  test_case "closed tab error" `Quick test_backend_failure;
  test_case "malformed response" `Quick test_malformed_success;
  test_case "closed current window keeps remaining tabs discoverable" `Quick test_closed_current_window;
  test_case "deadline cancels I/O and releases the session" `Quick test_timeout_releases_session;
  test_case "shutdown uses a live cleanup transport" `Quick test_shutdown_transport_lifetime;
  test_case "explicit Zen binary never falls back" `Quick test_selected_binary;
  test_case "browser configuration" `Quick test_browser_configuration]]
