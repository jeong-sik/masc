(* This standalone fixture explicitly enables new Browser work. *)
let () = Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled))

open Alcotest
module Driver = Masc.Browser_webdriver
module Lane = Browser_lane
let start_downloads ~session_id:_ ~websocket_url:_ =
  Ok Masc.Browser_downloads.{read=(fun ~context:_ -> Ok (`Assoc ["downloads",`List []]));
    console=(fun ~context:_ -> Ok (`Assoc ["entries",`List [];"dropped",`Int 0]));
    network=(fun ~context:_ -> Ok (`Assoc ["requests",`List [];"dropped",`Int 0]));
    check=(fun () -> Ok ());close=(fun () -> ())}

let test_session_lifecycle () =
  Eio_main.run (fun _ ->
    let calls = ref [] in
    let request ~method_ ~path ~body:_ =
      calls := (method_, path) :: !calls;
      match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId", `String "owned";"capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `DELETE, "/session/owned" -> Ok `Null
      | `POST, "/session/owned/frame" -> Ok `Null
      | `POST, "/session/owned/url" -> Error (Driver.Remote {code=Driver.Invalid_session_id;message="Firefox exited"})
      | _ -> fail ("unexpected request: " ^ path)
    in
    let driver = Driver.create ~start_downloads ~request () in
    check bool "driver registration alone is closed" true (Driver.session_observation driver=Lane.Browser_closed);
    (match Driver.execute driver (Lane.Page_interact {frame_path=[];tab_id=7;expected_url=Some "https://example.org";action=Lane.Activate_tab}) with
     | Lane.Rejected_before_effect _ -> () | _ -> fail "live-only activation must reject before selecting a WebDriver tab");
    check int "unsupported activation makes no backend request" 0 (List.length !calls);
    (match Driver.execute driver Lane.Tabs_list with
     | Lane.Refused _ -> () | _ -> fail "closed session must refuse reads");
    check int "closed read never contacted driver" 0 (List.length !calls);
    let open_session () = Driver.execute driver (Lane.Session_open {headless=Some true}) in
    ignore (open_session ()); ignore (open_session ());
    check bool "confirmed owned session is open" true (Driver.session_observation driver=Lane.Browser_open);
    check int "reopening keeps owned session" 1 (List.length !calls);
    (match Driver.execute driver (Lane.Page_goto {url="https://example.org";tab_id=None}) with
     | Lane.Refused _ -> () | _ -> fail "browser exit must be visible");
    check bool "confirmed invalid session clears observation" true (Driver.session_observation driver=Lane.Browser_closed);
    ignore (open_session ());
    check int "session can recover after Firefox exits" 4 (List.length !calls);
    List.iter (fun verb ->
      check bool "session lifecycle cannot be classified as a read" false
        (Lane.verb_is_read verb))
      [ Lane.Session_open {headless=Some true}; Lane.Session_close ];
    (match Driver.execute driver Lane.Session_close with
     | Lane.Answered _ -> () | _ -> fail "session close failed");
    check bool "confirmed deletion clears observation" true (Driver.session_observation driver=Lane.Browser_closed);
    check bool "close issues WebDriver DELETE" true
      (List.hd !calls = (`DELETE, "/session/owned"));
    (match Driver.execute driver Lane.Tabs_list with
     | Lane.Refused _ -> () | _ -> fail "closed session must refuse subsequent reads");
    check int "closed read adds no backend request" 5 (List.length !calls))
let test_session_observer_unknown_outcome () = Eio_main.run (fun _ ->
  let creating_fails=ref true and closing_fails=ref false and calls=ref 0 in
  let observe=ref (fun () -> Lane.Browser_unknown) in
  let request ~method_ ~path ~body:_ =
    incr calls;
    check bool "lifecycle is observable while transport is active" true (!observe ()=Lane.Browser_changing);
    match method_,path with
    | `POST,"/session" -> if !creating_fails then Error (Driver.Transport "create response lost")
      else Ok (`Assoc ["sessionId",`String "owned";"capabilities",`Assoc ["webSocketUrl",`String "ws://localhost/session/owned"]])
    | `DELETE,"/session/owned" -> if !closing_fails then Error (Driver.Transport "delete response lost") else Ok `Null
    | _ -> fail "unexpected lifecycle request" in
  let driver=Driver.create ~start_downloads ~request () in
  observe:=(fun ()->Driver.session_observation driver);
  ignore (Driver.execute driver (Lane.Session_open {headless=None}));
  check bool "lost creation does not invent a closed or open browser" true (!observe ()=Lane.Browser_unknown);
  check int "lifecycle reads send nothing" 1 !calls;
  creating_fails:=false;
  let driver=Driver.create ~start_downloads ~request () in
  observe:=(fun ()->Driver.session_observation driver);
  ignore (Driver.execute driver (Lane.Session_open {headless=None}));
  check bool "confirmed new session is open" true (!observe ()=Lane.Browser_open);
  closing_fails:=true;
  ignore (Driver.execute driver Lane.Session_close);
  check bool "lost deletion is unknown" true (!observe ()=Lane.Browser_unknown);
  closing_fails:=false;
  ignore (Driver.execute driver Lane.Session_close);
  check bool "confirmed deletion settles closed" true (!observe ()=Lane.Browser_closed))
let test_zoom_requires_extension () = Eio_main.run (fun _ ->
  let calls=ref 0 in
  let request ~method_:_ ~path:_ ~body:_ = incr calls;Error (Driver.Transport "must not dispatch") in
  let driver=Driver.create ~start_downloads ~request () in
  (match Driver.execute driver (Lane.Page_interact {frame_path=[];tab_id=7;expected_url=Some "https://example.org";
      action=Lane.Set_zoom {factor=1.5}}) with
   | Lane.Rejected_before_effect _ -> ()
   | Lane.Answered _ | Lane.Lane_absent | Lane.Timed_out | Lane.Refused _ -> fail "unsupported zoom must be pre-effect");
  check int "unsupported browser zoom performs no driver call" 0 !calls)
let test_backend_failure () =
  match Driver.decode_response ~status:404
    {|{"value":{"error":"no such window","message":"tab closed"}}|} with
  | Error (Driver.Remote {code=Driver.No_such_window;message="tab closed"}) -> ()
  | _ -> fail "WebDriver errors must retain their code and message"
let test_malformed_success () =
  match Driver.decode_response ~status:200 {|{"ok":true}|} with
  | Error (Driver.Protocol _) -> ()
  | _ -> fail "HTTP 200 without a WebDriver value is not success"
let test_closed_current_window () =
  Eio_main.run (fun _ ->
    let selected = ref [] in
    let request ~method_ ~path ~body = match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId", `String "owned";"capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `GET, "/session/owned/window/handles" -> Ok (`List [`String "remaining"])
      | `GET, "/session/owned/window" ->
        Error (Driver.Remote {code=Driver.No_such_window;message="current tab closed"})
      | `POST, "/session/owned/window" ->
        selected := body :: !selected; Ok `Null
      | `POST, "/session/owned/execute/sync" ->
        Ok (`Assoc ["url", `String "https://example.org"; "title", `String "Remaining"])
      | _ -> fail ("unexpected request: " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
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
      | `POST, "/session" -> Ok (`Assoc ["sessionId", `String "owned";"capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `POST, "/session/owned/frame" -> Ok `Null
      | `POST, "/session/owned/execute/sync" when !blocked ->
        Eio.Switch.run (fun sw ->
          Eio.Switch.on_release sw (fun () -> cancelled := true);
          Eio.Fiber.await_cancel ())
      | `POST, "/session/owned/execute/sync" -> Ok (`Assoc ["text", `String "recovered"])
      | _ -> fail ("unexpected request: " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    Eio.Switch.run (fun sw ->
      Lane.install_automation_executor (Some (Driver.execute driver));
      Eio.Switch.on_release sw (fun () -> Lane.install_automation_executor None);
      let read () = Lane.issue_automation
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
      | `POST, "/session" -> Ok (`Assoc ["sessionId", `String "owned";"capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | _ -> fail ("unexpected normal request: " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
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

let test_download_setup_rollback () =
  Eio_main.run (fun _ ->
    let deleted = ref 0 in
    let request ~method_ ~path ~body = match method_, path with
      | `POST, "/session" ->
        check bool "BiDi capability requested" true
          (match body with Some body ->
             Yojson.Safe.Util.(body |> member "capabilities" |> member "alwaysMatch" |> member "webSocketUrl") = `Bool true
           | None -> false);
        Ok (`Assoc ["sessionId",`String "owned";"capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `DELETE, "/session/owned" -> incr deleted; Ok `Null
      | _ -> fail "setup failure exposed browser actions" in
    let driver = Driver.create ~request
      ~start_downloads:(fun ~session_id:_ ~websocket_url:_ -> Error "unsupported download events") () in
    (match Driver.execute driver (Lane.Session_open {headless=None}) with
     | Lane.Refused _ -> () | _ -> fail "unsupported downloads silently degraded session");
    check int "failed setup deletes the known remote session" 1 !deleted;
    (match Driver.execute driver Lane.Tabs_list with Lane.Refused _ -> () | _ -> fail "rolled-back session still open"))

let test_download_setup_cancellation () =
  Eio_main.run (fun env ->
    let deleted = ref false in
    let request ~method_ ~path ~body:_ = match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId",`String "owned";
          "capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `DELETE, "/session/owned" -> deleted := true; Ok `Null
      | _ -> fail "unexpected setup request" in
    let driver = Driver.create ~request
      ~start_downloads:(fun ~session_id:_ ~websocket_url:_ -> Eio.Fiber.await_cancel ()) () in
    (try
       Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 0.01 (fun () ->
         ignore (Driver.execute driver (Lane.Session_open {headless=None})))
     with Eio.Time.Timeout -> ());
    check bool "canceled setup deletes the known remote session" true !deleted)

let test_selected_binary () =
  Eio_main.run (fun _ ->
    let requests = ref [] in
    let request ~method_ ~path ~body =
      match method_, path with
      | `POST, "/session" ->
        requests := body :: !requests;
        Error (Driver.Remote {code=Driver.Other "session not created";message="invalid configured browser"})
      | _ -> fail "unexpected browser request" in
    let driver = Driver.create ~start_downloads ~binary:"/test/Zen.app/Contents/MacOS/zen" ~request () in
    (match Driver.execute driver (Lane.Session_open {headless=Some true}) with
     | Lane.Refused _ -> () | _ -> fail "explicit browser failure must remain visible");
    check int "no implicit fallback session" 1 (List.length !requests);
    let open Yojson.Safe.Util in
    let sent = Option.get (List.hd !requests) in
    let options = sent |> member "capabilities" |> member "alwaysMatch" |> member "moz:firefoxOptions" in
    check string "configured Zen binary forwarded exactly" "/test/Zen.app/Contents/MacOS/zen"
      (options |> member "binary" |> to_string);
    let default = Driver.create ~start_downloads ~request () in
    ignore (Driver.execute default (Lane.Session_open {headless=None}));
    let sent = Option.get (List.hd !requests) in
    check bool "default discovery leaves binary capability absent" true
      ((sent |> member "capabilities" |> member "alwaysMatch" |> member "moz:firefoxOptions" |> member "binary") = `Null))

let test_browser_configuration () =
  let parse text = match Otoml.Parser.from_string_result text with
    | Error detail -> fail detail | Ok toml -> Browser_configuration.parse toml in
  (match parse "" with Ok { Browser_configuration.automation = None; stagehand = None; _ } -> () | _ -> fail "missing browser config");
  (match parse {|[browser]
geckodriver = "/test/geckodriver"
binary = "/test/Zen.app"
|} with
   | Ok { Browser_configuration.automation = Some {driver="/test/geckodriver";binary=Some "/test/Zen.app"}; stagehand = None; _ } -> ()
   | _ -> fail "explicit browser configuration lost");
  (match parse {|[browser]
geckodriver = "/test/geckodriver"
|} with
   | Ok { Browser_configuration.automation = Some {driver="/test/geckodriver";binary=None}; stagehand = None; _ } -> ()
   | _ -> fail "a driver without a binary lets geckodriver discover the browser");
  List.iter (fun (why, text) -> check bool why true (Result.is_error (parse text)))
    [ "a binary needs the driver that launches it", {|[browser]
binary = "/test/Zen.app"|};
      "the driver is an absolute path, never a PATH lookup", {|[browser]
geckodriver = "geckodriver"|};
      "a relative binary is refused", {|[browser]
geckodriver = "/test/geckodriver"
binary = "Zen.app"|};
      "a non-string binary is refused", {|[browser]
geckodriver = "/test/geckodriver"
binary = false|};
      "a Stagehand table needs its extension", {|[browser.stagehand]
chrome = "/test/chrome"|};
      "a Stagehand table needs its browser", {|[browser.stagehand]
extension = "/test/extension"|};
      "an empty Stagehand table needs its browser", {|[browser.stagehand]|};
      "a misspelled Stagehand field does not disable the backend", {|[browser.stagehand]
extention = "/test/extension"|};
      "a relative Stagehand profile is refused", {|[browser.stagehand]
chrome = "/test/chrome"
extension = "/test/extension"
profile = "profile"|} ];
  (match parse {|[browser]
geckodriver = "/test/geckodriver"

[browser.stagehand]
chrome = "/test/chrome"
extension = "/test/extension"
|} with
   | Ok { Browser_configuration.automation = Some _;
          stagehand = Some { chrome = "/test/chrome"; extension = "/test/extension"; profile = None }; _ } -> ()
   | _ -> fail "both backends can be configured together")

(* A keeper's first question is whether a session already exists. Every other
   verb answers that only by being refused, which costs a lane round trip and
   reads as a failure. Session_status answers it directly, from the backend's
   own record, and stays answerable while the session is closed. *)
let test_session_status_answers_while_closed () =
  Eio_main.run (fun _ ->
    let calls = ref [] in
    let driver_answer : (Yojson.Safe.t, Driver.error) result ref =
      ref (Ok (`Assoc ["ready", `Bool true; "message", `String ""])) in
    let request ~method_ ~path ~body:_ =
      calls := (method_, path) :: !calls;
      match method_, path with
      | `GET, "/status" -> !driver_answer
      | `POST, "/session" ->
        Ok (`Assoc ["sessionId", `String "owned";
                    "capabilities", `Assoc ["webSocketUrl", `String "ws://localhost:1234/session/owned"]])
      | _ -> fail ("unexpected request: " ^ path)
    in
    let driver = Driver.create ~start_downloads ~request () in
    let status () = match Driver.execute driver Lane.Session_status with
      | Lane.Answered (`Assoc fields) ->
        (match List.assoc_opt "data" fields with
         | Some (`Assoc data) -> data
         | _ -> fail "status answer carries no data")
      | _ -> fail "status must answer whether or not a session exists"
    in
    let closed = status () in
    check bool "closed session reports open=false" true
      (List.assoc_opt "open" closed = Some (`Bool false));
    (* {"open":false} alone read as a broken lane (2026-09-15). The driver's
       own readiness says whether open can start a session now. *)
    check bool "closed session carries the driver's readiness" true
      (List.assoc_opt "driver" closed
       = Some (`Assoc ["ready", `Bool true; "message", `String ""]));
    check bool "status on a closed session asks only the driver's /status" true
      (!calls = [ (`GET, "/status") ]);
    driver_answer := Ok (`Assoc ["ready", `Bool false; "message", `String "Session already started"]);
    check bool "a driver holding a session this record does not own says so" true
      (List.assoc_opt "driver" (status ())
       = Some (`Assoc ["ready", `Bool false; "message", `String "Session already started"]));
    driver_answer := Error (Driver.Transport "connection refused");
    check bool "a driver that does not answer is reported, and status still answers" true
      (List.assoc_opt "driver" (status ()) = Some (`Assoc ["error", `String "connection refused"]));
    driver_answer := Ok (`Assoc ["ready", `Bool true; "message", `String ""]);
    calls := [];
    ignore (Driver.execute driver (Lane.Session_open {headless = Some true}));
    let opened = status () in
    check bool "open session reports open=true" true
      (List.assoc_opt "open" opened = Some (`Bool true));
    check bool "open session reports its id" true
      (List.assoc_opt "sessionId" opened = Some (`String "owned"));
    check bool "open session reports its tab count" true
      (List.assoc_opt "tabs" opened = Some (`Int 0));
    check int "status on an open session adds no backend request" 1 (List.length !calls);
    check bool "open session status carries no driver probe" true
      (List.assoc_opt "driver" opened = None);
    check bool "status is a read" true (Lane.verb_is_read Lane.Session_status);
    check bool "status is not offered on the live lane" false
      (Lane.verb_allowed_on_live Lane.Session_status))

let test_semantic_click_uses_native_pointer_input () =
  Eio_main.run (fun _ ->
    let inputs = ref 0 and releases = ref 0 and fail_guard = ref false in
    let viewport = `Assoc ["documentId",`String "observed";"width",`Int 800;"height",`Int 600;
      "scrollX",`Int 0;"scrollY",`Int 0] in
    let request ~method_ ~path ~body = match method_,path with
      | `POST,"/session" -> Ok (`Assoc ["sessionId",`String "owned";"capabilities",`Assoc
          ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `GET,"/session/owned/window/handles" -> Ok (`List [`String "tab"])
      | `GET,"/session/owned/window" -> Ok (`String "tab")
      | `POST,"/session/owned/window" | `POST,"/session/owned/frame" -> Ok `Null
      | `POST,"/session/owned/execute/sync" ->
        let args = match body with
          | Some value -> Yojson.Safe.Util.(value |> member "args" |> to_list)
          | None -> fail "missing script arguments" in
        (match args with
         | [`Assoc fields] when List.assoc_opt "action" fields = Some (`String "click") ->
           Ok (`Assoc ["url",`String "https://example.test/";"viewport",viewport;
             "point",`Assoc ["x",`Float 0.25;"y",`Float 0.5]])
         | [`Assoc fields] when List.assoc_opt "action" fields = Some (`String "click_at") ->
           check bool "automation native guard uses captured URL" true
             (List.assoc_opt "expectedUrl" fields = Some (`String "https://example.test/"));
           if !fail_guard then Error (Driver.Protocol "observed_viewport_changed")
           else Ok (`Assoc ["url",`String "https://example.test/"])
         | [] -> Ok (`Assoc ["url",`String "https://example.test/";"title",`String "fixture"])
         | _ -> fail "unexpected script path; no synthetic click fallback")
      | `POST,"/session/owned/actions" ->
        incr inputs;
        let value = match body with Some value -> value | None -> fail "missing actions" in
        let steps = Yojson.Safe.Util.(value |> member "actions" |> index 0 |> member "actions" |> to_list) in
        check (list string) "automation dispatches native click" ["pointerMove";"pointerDown";"pointerUp"]
          (List.map Yojson.Safe.Util.(fun step -> step |> member "type" |> to_string) steps);
        Ok `Null
      | `DELETE,"/session/owned/actions" -> incr releases; Ok `Null
      | _ -> fail ("unexpected native semantic click request " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    ignore (Driver.execute driver Lane.Tabs_list);
    List.iter (fun action ->
      (match Driver.execute driver (Lane.Page_interact {frame_path=[];tab_id=1;expected_url=None;action}) with
       | Lane.Answered _ -> ()
       | Lane.Refused _ | Lane.Rejected_before_effect _ | Lane.Lane_absent | Lane.Timed_out -> fail "native semantic click failed"))
      [Lane.Click "#menu";Lane.Click_node {document_id="observed";node_id="menu"}];
    check int "one dispatch per semantic click" 2 !inputs;
    check int "each click releases native input" 2 !releases;
    fail_guard := true;
    (match Driver.execute driver (Lane.Page_interact {frame_path=[];tab_id=1;expected_url=None;action=Lane.Click "#menu"}) with
     | Lane.Rejected_before_effect _ -> ()
     | Lane.Answered _ | Lane.Refused _ | Lane.Lane_absent | Lane.Timed_out -> fail "stale native guard must reject before input");
    check int "failed guard sends no input or fallback" 2 !inputs)

let test_interact_enters_frames () =
  Eio_main.run (fun _ ->
    let order = ref [] and missing = ref false in
    let viewport = `Assoc ["documentId",`String "observed";"width",`Int 300;"height",`Int 200;
      "scrollX",`Int 0;"scrollY",`Int 0] in
    let request ~method_ ~path ~body = match method_,path with
      | `POST,"/session" -> Ok (`Assoc ["sessionId",`String "owned";"capabilities",`Assoc
          ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `GET,"/session/owned/window/handles" -> Ok (`List [`String "tab"])
      | `GET,"/session/owned/window" -> Ok (`String "tab")
      | `POST,"/session/owned/window" -> order := "window" :: !order; Ok `Null
      | `POST,"/session/owned/elements" ->
        order := "find-frame" :: !order;
        if !missing then Ok (`List [])
        else Ok (`List [`Assoc ["element-6066-11e4-a52e-4f735466cecf",`String "frame-el"]])
      | `POST,"/session/owned/frame" ->
        (match Option.bind body (fun json -> Yojson.Safe.Util.(member "id" json |> to_option Fun.id)) with
         | Some (`Assoc [_,`String "frame-el"]) -> order := "enter-frame" :: !order
         | _ -> ());
        Ok `Null
      | `POST,"/session/owned/execute/sync" ->
        order := "script" :: !order;
        let args = match body with
          | Some value -> Yojson.Safe.Util.(value |> member "args" |> to_list)
          | None -> fail "missing script arguments" in
        (match args with
         | [`Assoc fields] when List.assoc_opt "action" fields = Some (`String "click") ->
           check bool "the script receives the frame path" true
             (List.assoc_opt "framePath" fields = Some (`List [`String "#frame"]));
           Ok (`Assoc ["url",`String "https://example.test/frame";"viewport",viewport;
             "point",`Assoc ["x",`Float 0.25;"y",`Float 0.5]])
         | _ -> Ok (`Assoc ["url",`String "https://example.test/frame";"title",`String "frame";
             "scrollX",`Int 0;"scrollY",`Int 0]))
      | `POST,"/session/owned/actions" -> order := "pointer" :: !order; Ok `Null
      | `DELETE,"/session/owned/actions" -> Ok `Null
      | _ -> fail ("unexpected framed interaction request " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    ignore (Driver.execute driver Lane.Tabs_list);
    order := [];
    let framed action = Lane.Page_interact {frame_path=["#frame"];tab_id=1;expected_url=None;action} in
    let framed_receipt = match Driver.execute driver (framed (Lane.Click "#go")) with
      | Lane.Answered (`Assoc fields) -> (match List.assoc_opt "data" fields with Some data -> data | None -> fail "no data")
      | Lane.Answered _ | Lane.Refused _ | Lane.Rejected_before_effect _ | Lane.Lane_absent | Lane.Timed_out -> fail "framed click failed" in
    let seen = List.rev !order in
    let index name = let rec go i = function [] -> fail (name ^ " never ran") | x :: _ when x = name -> i | _ :: rest -> go (i+1) rest in go 0 seen in
    check bool "the frame is entered before the page script runs" true (index "enter-frame" < index "script");
    (match framed_receipt with
     | `Assoc fields -> check bool "the receipt names the frame chain" true
         (List.assoc_opt "framePath" fields = Some (`List [`String "#frame"]))
     | _ -> fail "receipt is not an object");
    check bool "the pointer moves only after the frame is entered" true (index "enter-frame" < index "pointer");
    order := []; missing := true;
    (match Driver.execute driver (framed (Lane.Click "#go")) with
     | Lane.Rejected_before_effect _ -> ()
     | Lane.Answered _ | Lane.Refused _ | Lane.Lane_absent | Lane.Timed_out -> fail "an unknown frame must reject before effect");
    check bool "no script or pointer runs after a missing frame" false
      (List.exists (fun step -> step = "script" || step = "pointer") !order))

let test_pointer_release_recovery () =
  Eio_main.run (fun _ ->
    let release_fails = ref true and gestures = ref 0 and releases = ref 0 and wheels = ref 0 in
    let request ~method_ ~path ~body = match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId",`String "owned";
          "capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `GET, "/session/owned/window/handles" -> Ok (`List [`String "tab"])
      | `GET, "/session/owned/window" -> Ok (`String "tab")
      | `POST, "/session/owned/window" | `POST, "/session/owned/frame" -> Ok `Null
      | `POST, "/session/owned/execute/sync" -> Ok (`Assoc ["url",`String "https://example.org";"title",`String "Fixture"])
      | `POST, "/session/owned/actions" ->
          let kind = match body with
            | Some json -> Yojson.Safe.Util.(json |> member "actions" |> to_list |> List.hd |> member "type" |> to_string)
            | None -> fail "actions require a body" in
          if kind = "wheel" then (incr wheels; Ok `Null)
          else (incr gestures; Error (Driver.Transport "response lost after pointerDown"))
      | `DELETE, "/session/owned/actions" -> incr releases;
          if !release_fails then Error (Driver.Transport "release unavailable") else Ok `Null
      | _ -> fail ("unexpected pointer request: " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    ignore (Driver.execute driver Lane.Tabs_list);
    let point : Lane.Pointer.point = {x=0.5;y=0.5} in
    let viewport : Lane.Pointer.viewport = {document_id="fixture";width=800.;height=600.;scroll_x=0.;scroll_y=0.} in
    let click = Lane.Page_interact {frame_path=[];tab_id=1;expected_url=Some "https://example.org";
      action=Lane.Click_at {point;viewport;button=Lane.Pointer.Primary}} in
    let wheel = Lane.Page_interact {frame_path=[];tab_id=1;expected_url=Some "https://example.org";
      action=Lane.Scroll_at {point;viewport;x=0;y=120}} in
    check bool "successful wheel is not overridden by failing release endpoint" true
      (match Driver.execute driver wheel with
       | Lane.Answered (`Assoc fields) -> List.assoc_opt "ok" fields = Some (`Bool true)
       | _ -> false);
    check int "wheel dispatch occurs once" 1 !wheels;
    check int "wheel requires no pointer cleanup" 0 !releases;
    ignore (Driver.execute driver click);
    check int "cleanup attempted after lost gesture response" 1 !releases;
    ignore (Driver.execute driver wheel);
    check int "unreleased pointer prevents a new wheel" 1 !wheels;
    check int "unreleased input prevents a subsequent gesture" 1 !gestures;
    check int "recovery retries release, not the gesture" 2 !releases;
    release_fails := false;
    check bool "wheel recovers older pointer release before dispatch" true
      (match Driver.execute driver wheel with
       | Lane.Answered (`Assoc fields) -> List.assoc_opt "ok" fields = Some (`Bool true)
       | _ -> false);
    check int "successful recovery permits one new wheel" 2 !wheels;
    check int "wheel recovers only older remote release" 3 !releases;
    check int "recovery never replays previous input" 1 !gestures)

(* A click that opens a JavaScript dialog makes geckodriver refuse the pointer
   release (probed on Firefox 158). Answering that dialog goes through the same
   session, so the refused release must not block it. *)
let test_dialog_opened_by_a_click_can_be_answered () =
  Eio_main.run (fun _ ->
    let dialog_open = ref false and releases = ref 0 and answered = ref 0 in
    let request ~method_ ~path ~body:_ = match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId",`String "owned";
          "capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `GET, "/session/owned/window/handles" -> Ok (`List [`String "tab"])
      | `GET, "/session/owned/window" -> Ok (`String "tab")
      | `POST, "/session/owned/window" | `POST, "/session/owned/frame" -> Ok `Null
      | `POST, "/session/owned/execute/sync" -> Ok (`Assoc ["url",`String "https://example.org";"title",`String "Fixture"])
      | `POST, "/session/owned/actions" -> dialog_open := true; Ok `Null
      | `DELETE, "/session/owned/actions" -> incr releases;
          if !dialog_open then Error (Driver.Remote {code=Driver.Unexpected_alert_open;message="dialog open"})
          else Ok `Null
      | `GET, "/session/owned/alert/text" -> Ok (`String "sure?")
      | `POST, "/session/owned/alert/accept" -> incr answered; dialog_open := false; Ok `Null
      | _ -> fail ("unexpected request: " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    ignore (Driver.execute driver Lane.Tabs_list);
    let point : Lane.Pointer.point = {x=0.5;y=0.5} in
    let viewport : Lane.Pointer.viewport = {document_id="fixture";width=800.;height=600.;scroll_x=0.;scroll_y=0.} in
    let click = Lane.Page_interact {frame_path=[];tab_id=1;expected_url=Some "https://example.org";
      action=Lane.Click_at {point;viewport;button=Lane.Pointer.Primary}} in
    (match Driver.execute driver click with
     | Lane.Refused _ | Lane.Answered _ -> ()
     | Lane.Rejected_before_effect _ | Lane.Lane_absent | Lane.Timed_out -> fail "the click must reach the page");
    check bool "the click opened a dialog" true !dialog_open;
    (match Driver.execute driver (Lane.Page_act (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Accept_dialog None})) with
     | Lane.Answered _ -> ()
     | Lane.Refused _ | Lane.Rejected_before_effect _ | Lane.Lane_absent | Lane.Timed_out ->
       fail "a pending release must not block answering the dialog");
    check int "the dialog was answered once" 1 !answered;
    let before = !releases in
    ignore (Driver.execute driver Lane.Tabs_list);
    check bool "the pending release runs once the dialog is gone" true (!releases > before))

let test_touch_sends_a_touch_pointer_and_releases_it () =
  Eio_main.run (fun _ ->
    let pointer_types = ref [] and releases = ref 0 in
    let request ~method_ ~path ~body = match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId",`String "owned";
          "capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `GET, "/session/owned/window/handles" -> Ok (`List [`String "tab"])
      | `GET, "/session/owned/window" -> Ok (`String "tab")
      | `POST, "/session/owned/window" | `POST, "/session/owned/frame" -> Ok `Null
      | `POST, "/session/owned/execute/sync" -> Ok (`Assoc ["url",`String "https://example.org";"title",`String "Fixture"])
      | `POST, "/session/owned/actions" ->
        (match body with
         | Some json ->
           pointer_types := Yojson.Safe.Util.(json |> member "actions" |> to_list |> List.hd
             |> member "parameters" |> member "pointerType" |> to_string) :: !pointer_types;
           Ok `Null
         | None -> fail "actions require a body")
      | `DELETE, "/session/owned/actions" -> incr releases; Ok `Null
      | _ -> fail ("unexpected touch request: " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    ignore (Driver.execute driver Lane.Tabs_list);
    let point : Lane.Pointer.point = {x=0.5;y=0.5} in
    let viewport : Lane.Pointer.viewport = {document_id="fixture";width=800.;height=600.;scroll_x=0.;scroll_y=0.} in
    let interact action = Driver.execute driver
      (Lane.Page_interact {frame_path=[];tab_id=1;expected_url=Some "https://example.org";action}) in
    List.iter (fun action -> match interact action with
      | Lane.Answered _ -> ()
      | Lane.Refused _ | Lane.Rejected_before_effect _ | Lane.Lane_absent | Lane.Timed_out -> fail "touch input was not served")
      [Lane.Tap_at {point;viewport};
       Lane.Swipe {from=point;to_={x=0.9;y=0.5};viewport;via=[];duration_ms=0}];
    check (list string) "each touch action sends a touch pointer" ["touch";"touch"] !pointer_types;
    check int "each pressed touch is released" 2 !releases)

let test_console_read_uses_the_tabs_context () =
  Eio_main.run (fun _ ->
    let request ~method_ ~path ~body:_ = match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId",`String "owned";
          "capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `GET, "/session/owned/window/handles" -> Ok (`List [`String "tab"])
      | `GET, "/session/owned/window" -> Ok (`String "tab")
      | `POST, "/session/owned/window" | `POST, "/session/owned/frame" -> Ok `Null
      | `POST, "/session/owned/execute/sync" -> Ok (`Assoc ["url",`String "https://example.org";"title",`String "Fixture"])
      | _ -> fail ("unexpected console request: " ^ path) in
    let asked = ref [] in
    let start_downloads ~session_id:_ ~websocket_url:_ =
      Ok Masc.Browser_downloads.{read=(fun ~context:_ -> Ok (`Assoc ["downloads",`List []]));
        console=(fun ~context -> asked := context :: !asked;
          Ok (`Assoc ["entries",`List [`Assoc ["text",`String "hello"]];"dropped",`Int 0]));
        network=(fun ~context:_ -> Ok (`Assoc ["requests",`List [];"dropped",`Int 0]));
        check=(fun () -> Ok ());close=(fun () -> ())} in
    let driver = Driver.create ~start_downloads ~request () in
    (match Driver.execute driver (Lane.Page_console {tab_id=1}) with
     | Lane.Refused _ -> () | _ -> fail "a closed session must refuse a console read");
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    ignore (Driver.execute driver Lane.Tabs_list);
    (match Driver.execute driver (Lane.Page_console {tab_id=1}) with
     | Lane.Answered (`Assoc fields) ->
       (match List.assoc_opt "data" fields with
        | Some (`Assoc data) ->
          check bool "the receipt names the tab" true (List.assoc_opt "tabId" data = Some (`Int 1));
          check bool "the entries come through" true (List.mem_assoc "entries" data)
        | _ -> fail "the console answer has no data")
     | _ -> fail "the console read was not answered");
    check (list string) "the read used the tab's context" ["tab"] !asked;
    (match Driver.execute driver (Lane.Page_console {tab_id=99}) with
     | Lane.Refused _ -> () | _ -> fail "an unknown tab must be refused");
    check (list string) "an unknown tab asks nothing" ["tab"] !asked)

let test_cookie_values_never_leave_the_driver_module () =
  Eio_main.run (fun _ ->
    let request ~method_ ~path ~body:_ = match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId",`String "owned";
          "capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `GET, "/session/owned/window/handles" -> Ok (`List [`String "tab"])
      | `GET, "/session/owned/window" -> Ok (`String "tab")
      | `POST, "/session/owned/window" | `POST, "/session/owned/frame" -> Ok `Null
      | `POST, "/session/owned/execute/sync" -> Ok (`Assoc ["url",`String "https://example.org";"title",`String "Fixture"])
      | `GET, "/session/owned/cookie" ->
        Ok (`List [`Assoc ["name",`String "sid";"value",`String "DRIVERSECRET";"domain",`String "example.test";
                           "path",`String "/";"secure",`Bool true;"httpOnly",`Bool true]])
      | _ -> fail ("unexpected cookie request: " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
    (match Driver.execute driver (Lane.Page_cookies {tab_id=1}) with
     | Lane.Refused _ -> () | _ -> fail "a closed session must refuse a cookie read");
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    ignore (Driver.execute driver Lane.Tabs_list);
    match Driver.execute driver (Lane.Page_cookies {tab_id=1}) with
    | Lane.Answered json ->
      let text = Yojson.Safe.to_string json in
      check bool "the value never reaches the answer" false
        (try ignore (Str.search_forward (Str.regexp_string "DRIVERSECRET") text 0); true with Not_found -> false);
      check bool "the cookie's name does" true
        (try ignore (Str.search_forward (Str.regexp_string "sid") text 0); true with Not_found -> false)
    | _ -> fail "the cookie read was not answered")

let test_pointer_guard_failure_rejects_before_effect () =
  Eio_main.run (fun _ ->
    let actions = ref 0 in
    let request ~method_ ~path ~body:_ = match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId",`String "owned";
          "capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
      | `GET, "/session/owned/window/handles" -> Ok (`List [`String "tab"])
      | `GET, "/session/owned/window" -> Ok (`String "tab")
      | `POST, "/session/owned/window" | `POST, "/session/owned/frame" -> Ok `Null
      | `POST, "/session/owned/execute/sync" -> Error (Driver.Transport "page_url_changed")
      | `POST, "/session/owned/actions" -> incr actions; Ok `Null
      | _ -> fail ("unexpected pointer request: " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    ignore (Driver.execute driver Lane.Tabs_list);
    let point : Lane.Pointer.point = {x=0.5;y=0.5} in
    let viewport : Lane.Pointer.viewport = {document_id="fixture";width=800.;height=600.;scroll_x=0.;scroll_y=0.} in
    let hover = Lane.Page_interact {frame_path=[];tab_id=1;expected_url=Some "https://example.org";
      action=Lane.Hover_at {point;viewport}} in
    check bool "failed hover guard is rejected before effect" true
      (match Driver.execute driver hover with Lane.Rejected_before_effect _ -> true | _ -> false);
    check int "failed hover guard sends no pointer input" 0 !actions)

let test_native_keyboard_and_double_click () = Eio_main.run (fun _ ->
  let submitted = ref [] and released = ref 0 and guard_failure = ref false and lost = ref false in
  let request ~method_ ~path ~body = match method_,path with
    | `POST,"/session" -> Ok (`Assoc ["sessionId",`String "owned";
        "capabilities",`Assoc ["webSocketUrl",`String "ws://localhost:1234/session/owned"]])
    | `GET,"/session/owned/window/handles" -> Ok (`List [`String "tab"])
    | `GET,"/session/owned/window" -> Ok (`String "tab")
    | `POST,"/session/owned/window" | `POST,"/session/owned/frame" -> Ok `Null
    | `POST,"/session/owned/execute/sync" -> if !guard_failure then Error (Driver.Protocol "scene_document_changed")
      else Ok (`Assoc ["url",`String "https://example.org";"title",`String "native"])
    | `POST,"/session/owned/actions" -> submitted := body :: !submitted;
      if !lost then Error (Driver.Transport "input reply missing") else Ok `Null
    | `DELETE,"/session/owned/actions" -> incr released;Ok `Null
    | _ -> fail ("unexpected native request: " ^ path) in
  let driver = Driver.create ~start_downloads ~request () in
  ignore (Driver.execute driver (Lane.Session_open {headless=None}));
  ignore (Driver.execute driver Lane.Tabs_list);
  let key=match Lane.Keyboard.of_wire ~key:"a" ~modifiers:["Meta"] with Ok key->key|Error detail->fail detail in
  let point : Lane.Pointer.point = {x=0.5;y=0.5} in
  let viewport : Lane.Pointer.viewport = {document_id="d1";width=800.;height=600.;scroll_x=0.;scroll_y=0.} in
  List.iter (fun action ->
    let verb=Lane.Page_interact {frame_path=[];tab_id=1;expected_url=Some "https://example.org";action} in
    submitted:=[];released:=0;
    (match Driver.execute driver verb with Lane.Answered _ -> () | _ -> fail "native input failed");
    check int "one native action sequence" 1 (List.length !submitted);
    check int "all pressed input is released" 1 !released;
    guard_failure:=true;submitted:=[];released:=0;
    (match Driver.execute driver verb with Lane.Rejected_before_effect _ -> () | _ -> fail "guard failure must reject before input");
    check int "failed guard sends no native action" 0 (List.length !submitted);
    check int "failed guard releases no input it did not own" 0 !released;
    guard_failure:=false;lost:=true;submitted:=[];released:=0;
    (match Driver.execute driver verb with Lane.Refused _ -> () | _ -> fail "missing reply must remain uncertain");
    check int "uncertain input is never replayed" 1 (List.length !submitted);
    check int "uncertain input still releases" 1 !released;
    lost:=false)
    [Lane.Type_text {document_id="d1";text="한🙂"};Lane.Press_key {document_id="d1";key};
     Lane.Double_click_at {point;viewport}];
  List.iter (fun text -> submitted:=[];released:=0;
    (match Driver.execute driver (Lane.Page_interact {frame_path=[];tab_id=1;expected_url=Some "https://example.org";
      action=Lane.Type_text {document_id="d1";text}}) with
     | Lane.Rejected_before_effect _ -> () | _ -> fail "text controls/reserved scalars must reject before input");
    check int "rejected text sends no action sequence" 0 (List.length !submitted);
    check int "rejected text sends no native release" 0 !released) ["a\tb";"a\nb";"a\rb";"\xee\x80\x89"])


let test_optional_document_never_selects_or_blocks_owner () =
  Eio_main.run (fun _ ->
    let calls = ref [] in
    let blocked = ref false in
    let entered, enter = Eio.Promise.create () in
    let release, finish = Eio.Promise.create () in
    let request ~method_ ~path ~body:_ =
      calls := (method_, path) :: !calls;
      match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId", `String "owned";
          "capabilities", `Assoc ["webSocketUrl", `String "ws://localhost:1234/session/owned"]])
      | `GET, "/session/owned/window/handles" -> Ok (`List [`String "current"])
      | `GET, "/session/owned/window" -> Ok (`String "current")
      | `POST, "/session/owned/window" | `POST, "/session/owned/frame" -> Ok `Null
      | `POST, "/session/owned/execute/sync" ->
        if !blocked then (Eio.Promise.resolve enter (); Eio.Promise.await release);
        Ok (`Assoc ["url", `String "https://example.org/app"; "title", `String "Document";
                   "documentId", `String "document"; "html", `String "<html></html>";
                   "htmlComplete", `Bool true; "observedAt", `Float 1000.])
      | _ -> fail ("unexpected optional document request: " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
    (match Driver.observe_document_if_idle driver ~tab_id:1 with
     | Lane.Refused _ -> () | _ -> fail "optional read must not create a session");
    check int "closed optional read has no remote calls" 0 (List.length !calls);
    ignore (Driver.execute driver (Lane.Session_open {headless=None}));
    ignore (Driver.execute driver Lane.Tabs_list);
    calls := [];
    (match Driver.observe_document_if_idle driver ~tab_id:1 with
     | Lane.Answered json ->
       check string "existing automation client identity" "automation:owned"
         Yojson.Safe.Util.(json |> member "data" |> member "clientId" |> to_string)
     | _ -> fail "current document should be readable");
    check bool "optional read neither selects a window nor resets a frame" true
      (List.rev !calls = [`GET, "/session/owned/window"; `POST, "/session/owned/execute/sync"]);
    calls := [];
    (match Driver.observe_document_if_idle driver ~tab_id:2 with
     | Lane.Refused _ -> () | _ -> fail "optional source must not select another tab");
    check bool "another tab is refused without selection" true
      (!calls = [`GET, "/session/owned/window"]);
    Eio.Switch.run (fun sw ->
      blocked := true;
      let primary = Eio.Fiber.fork_promise ~sw (fun () ->
        Driver.execute driver (Lane.Page_read {tab_id=None;max_chars=None})) in
      Eio.Promise.await entered;
      let before = List.length !calls in
      check bool "optional read returns before held primary barrier releases" true
        (Driver.observe_document_if_idle driver ~tab_id:1
          = Lane.Refused "optional_document_observation_busy");
      check int "busy optional source performs no requests" before (List.length !calls);
      blocked := false;
      Eio.Promise.resolve finish ();
      (match Eio.Promise.await primary with
       | Ok (Lane.Answered _) -> () | _ -> fail "original owner did not finish");
      (match Driver.observe_document_if_idle driver ~tab_id:1 with
       | Lane.Answered _ -> () | _ -> fail "primary completion should release optional admission")))

(* Proves F290/F400: the W3C error code reaches every recovery site as a
   closed sum, not a wire string. On origin/main [Remote.code] is a string,
   so the constructor patterns here do not compile there. On this branch a
   response decoded with "invalid session id" still clears the owned
   session, and an unlisted code surfaces as [Other] carrying the raw code.
   [spelled] is exhaustive: a constructor added without a spelling here
   fails to compile under -warn-error +a. *)
let test_remote_error_is_a_closed_sum () =
  let decode code = Driver.decode_response ~status:404
      (Printf.sprintf {|{"value":{"error":"%s","message":"m"}}|} code) in
  let spelled = function
    | Driver.Invalid_session_id -> "invalid session id"
    | Driver.No_such_window -> "no such window"
    | Driver.No_such_alert -> "no such alert"
    | Driver.Unexpected_alert_open -> "unexpected alert open"
    | Driver.Other code -> code in
  List.iter (fun (wire, expected) ->
      match decode wire with
      | Error (Driver.Remote {code; message = "m"}) ->
        check bool ("decoded " ^ wire) true (code = expected);
        check string "constructor spells its wire code" wire (spelled code)
      | _ -> fail ("no Remote error decoded for " ^ wire))
    [ "invalid session id", Driver.Invalid_session_id;
      "no such window", Driver.No_such_window;
      "no such alert", Driver.No_such_alert;
      "unexpected alert open", Driver.Unexpected_alert_open;
      "session not created", Driver.Other "session not created" ];
  (match decode "session not created" with
   | Error error ->
     check string "unlisted code stays visible in the message"
       "session not created: m" (Driver.error_message error)
   | Ok _ -> fail "HTTP 404 with a WebDriver error is not success");
  Eio_main.run (fun _ ->
    let request ~method_ ~path ~body:_ = match method_, path with
      | `POST, "/session" -> Ok (`Assoc ["sessionId", `String "owned";
          "capabilities", `Assoc ["webSocketUrl", `String "ws://localhost:1234/session/owned"]])
      | `POST, "/session/owned/frame" -> Ok `Null
      | `POST, "/session/owned/url" -> decode "invalid session id"
      | `GET, "/status" -> Ok (`Assoc ["ready", `Bool true; "message", `String ""])
      | _ -> fail ("unexpected request: " ^ path) in
    let driver = Driver.create ~start_downloads ~request () in
    ignore (Driver.execute driver (Lane.Session_open {headless = Some true}));
    (match Driver.execute driver (Lane.Page_goto {url = "https://example.org"; tab_id = None}) with
     | Lane.Refused _ -> () | _ -> fail "browser exit must be visible");
    match Driver.execute driver Lane.Session_status with
    | Lane.Answered (`Assoc fields) ->
      (match List.assoc_opt "data" fields with
       | Some (`Assoc data) ->
         check bool "a decoded invalid session id clears the owned session" true
           (List.assoc_opt "open" data = Some (`Bool false))
       | _ -> fail "status answer carries no data")
    | _ -> fail "status must answer after the session was lost")

let () = run "native Firefox lane" ["behavior", [
  test_case "browser zoom is refused without driver input" `Quick test_zoom_requires_extension;
  test_case "native keyboard and double click guarded release" `Quick test_native_keyboard_and_double_click;
  test_case "optional document never selects or blocks owner" `Quick test_optional_document_never_selects_or_blocks_owner;
  test_case "download setup failure rolls back session" `Quick test_download_setup_rollback;
  test_case "semantic clicks use native input" `Quick test_semantic_click_uses_native_pointer_input;
  test_case "framed interaction enters the frame first" `Quick test_interact_enters_frames;
  test_case "pointer release failure recovery" `Quick test_pointer_release_recovery;
  test_case "a dialog opened by a click can be answered" `Quick test_dialog_opened_by_a_click_can_be_answered;
  test_case "pointer guard failure rejects before effect" `Quick test_pointer_guard_failure_rejects_before_effect;
  test_case "download setup cancellation rolls back session" `Quick test_download_setup_cancellation;
  test_case "session ownership and crash recovery" `Quick test_session_lifecycle;
  test_case "lifecycle observations preserve unknown outcomes" `Quick test_session_observer_unknown_outcome;
  test_case "session status answers while closed" `Quick test_session_status_answers_while_closed;
  test_case "closed tab error" `Quick test_backend_failure;
  test_case "remote error code is a closed sum" `Quick test_remote_error_is_a_closed_sum;
  test_case "malformed response" `Quick test_malformed_success;
  test_case "closed current window keeps remaining tabs discoverable" `Quick test_closed_current_window;
  test_case "deadline cancels I/O and releases the session" `Quick test_timeout_releases_session;
  test_case "shutdown uses a live cleanup transport" `Quick test_shutdown_transport_lifetime;
  test_case "explicit Zen binary never falls back" `Quick test_selected_binary;
  test_case "touch sends a touch pointer and releases it" `Quick test_touch_sends_a_touch_pointer_and_releases_it;
  test_case "console read uses the tab's context" `Quick test_console_read_uses_the_tabs_context;
  test_case "cookie values never leave the driver module" `Quick test_cookie_values_never_leave_the_driver_module;
  test_case "browser configuration" `Quick test_browser_configuration ]]
