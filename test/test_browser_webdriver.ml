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
      | `POST, "/session/owned/url" -> Error (Driver.Remote {code="invalid session id";message="Firefox exited"})
      | _ -> fail ("unexpected request: " ^ path)
    in
    let driver = Driver.create ~request in
    (match Driver.execute driver Lane.Tabs_list with
     | Lane.Refused _ -> () | _ -> fail "closed session must refuse reads");
    check int "closed read never contacted driver" 0 (List.length !calls);
    let open_session () = Driver.execute driver (Lane.Session_open {headless=Some true}) in
    ignore (open_session ()); ignore (open_session ());
    check int "reopening keeps owned session" 1 (List.length !calls);
    (match Driver.execute driver (Lane.Page_goto {url="https://example.org"}) with
     | Lane.Refused _ -> () | _ -> fail "browser exit must be visible");
    ignore (open_session ());
    check int "session can recover after Firefox exits" 3 (List.length !calls))
let test_backend_failure () =
  match Driver.decode_response ~status:404
    {|{"value":{"error":"no such window","message":"tab closed"}}|} with
  | Error (Driver.Remote {code="no such window";message="tab closed"}) -> ()
  | _ -> fail "WebDriver errors must retain their code and message"
let test_malformed_success () =
  match Driver.decode_response ~status:200 {|{"ok":true}|} with
  | Error (Driver.Protocol _) -> ()
  | _ -> fail "HTTP 200 without a WebDriver value is not success"
let () = run "native Firefox lane" ["behavior", [
  test_case "session ownership and crash recovery" `Quick test_session_lifecycle;
  test_case "closed tab error" `Quick test_backend_failure;
  test_case "malformed response" `Quick test_malformed_success]]
