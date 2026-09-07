open Alcotest
module Surface = Masc.Browser_surface
let test_strict_input () =
  List.iter (fun json -> match Surface.parse_request json with
      | Error _ -> () | Ok _ -> fail "invalid read request accepted")
    [`Assoc ["lane", `Bool true]; `Assoc ["app",`String "unknown"];
     `Assoc ["tabId",`Int (-1)]; `Assoc ["tabID",`Int 1]]
let test_remote_failure () =
  match Surface.decode_answer (Browser_lane.Answered
    (`Assoc ["ok",`Bool false;"error",`String "tab closed"])) with
  | Error "tab closed" -> () | _ -> fail "backend failure became success"
let answer data = Browser_lane.Answered (`Assoc ["ok", `Bool true; "data", data])
let tab id url active = `Assoc ["id", `Int id; "title", `String "Page";
  "url", `String url; "active", `Bool active]
let with_browser tabs f =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let reads = ref [] in
      Browser_lane.install_automation_executor (Some (function
        | Browser_lane.Tabs_list -> answer (`List tabs)
        | Browser_lane.Page_read { tab_id = Some id; max_chars = Some 50_000 } ->
          reads := id :: !reads;
          answer (`Assoc ["tabId", `Int id; "url", `String "https://example.org/page";
            "title", `String "Page"; "text", `String "Observed page";
            "chars", `Int 13; "truncated", `Bool false])
        | _ -> fail "unexpected browser command"));
      Eio.Switch.on_release sw (fun () -> Browser_lane.install_automation_executor None);
      f reads))
let request tab_id : Surface.request = { source = Automation; tab_id; client_id=None }
let read_ok request = match Surface.read request with
  | Ok data -> data | Error detail -> fail detail
let test_any_website_selection () =
  with_browser [tab 41 "https://docs.example.org/guide" false;
                tab 73 "https://app.example.org/dashboard" true] (fun reads ->
    ignore (read_ok (request None));
    ignore (read_ok (request (Some 41)));
    check (list int) "active tab then explicit tab, independent of website" [41; 73] !reads;
    check bool "closed selected tab fails" true
      (Result.is_error (Surface.read (request (Some 99))));
    check int "closed selection must not read another tab" 2 (List.length !reads))
let test_empty_browser () =
  with_browser [] (fun reads ->
    let data = read_ok (request None) in
    check bool "empty tabs are a successful empty observation" true
      (Yojson.Safe.Util.member "tabs" data = `List []
       && Yojson.Safe.Util.member "page" data = `Null);
    check (list int) "empty browser does not read an arbitrary page" [] !reads)

let test_capture_identity () =
  check bool "capture requires an explicit tab" true
    (Result.is_error (Surface.parse_capture_request (`Assoc [])));
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let actual_id = ref 7 in
      let payload = ref (Base64.encode_string "\137PNG\r\n\026\nfixture") in
      Browser_lane.install_automation_executor (Some (function
        | Browser_lane.Page_capture {tab_id=7} ->
          answer (`Assoc ["tabId", `Int !actual_id; "url", `String "https://example.org";
            "title", `String "Fixture"; "mimeType", `String "image/png";
            "data", `String !payload])
        | _ -> fail "capture used an implicit or different target"));
      Eio.Switch.on_release sw (fun () -> Browser_lane.install_automation_executor None);
      check bool "explicit capture succeeds" true
        (Result.is_ok (Surface.capture (request (Some 7))));
      actual_id := 8;
      check bool "wrong tab result refused" true
        (Result.is_error (Surface.capture (request (Some 7))));
      actual_id := 7; payload := Base64.encode_string "not PNG";
      check bool "non-image payload refused" true
        (Result.is_error (Surface.capture (request (Some 7))))))

let test_live_read_pins_client_between_hops () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let info raw browser : Browser_lane.client_info =
        let client_id = match Browser_lane.client_id_of_string raw with
          | Ok id -> id | Error error -> fail error in
        {client_id; browser; version="fixture"; engine_version="155.0.1"} in
      let first = info "10000000-0000-4000-8000-000000000001" Browser_lane.Firefox in
      let second = info "10000000-0000-4000-8000-000000000002" Browser_lane.Zen in
      List.iter (fun info -> Eio.Switch.on_release sw (fun () ->
        ignore (Browser_lane.disconnect_client ~client_id:info.Browser_lane.client_id))) [first;second];
      ignore (Browser_lane.take_command ~client_info:first ~window_sec:0.001);
      let pending = Eio.Fiber.fork_promise ~sw (fun () ->
        Surface.read {source=Live; tab_id=Some 1; client_id=None}) in
      let take info = match Browser_lane.take_command ~client_info:info ~window_sec:1. with
        | Ok (Some command) -> command | _ -> fail "selected client command missing" in
      let tabs_command = take first in
      ignore (Browser_lane.take_command ~client_info:second ~window_sec:0.001);
      ignore (Browser_lane.deliver_result ~client_id:first.client_id ~id:tabs_command.id
        ~payload:(`Assoc ["ok", `Bool true; "data", `List [tab 1 "https://example.org/first" true]]));
      check bool "new client cannot consume next hop" true
        (Browser_lane.take_command ~client_info:second ~window_sec:0.002 = Ok None);
      let read_command = take first in
      ignore (Browser_lane.deliver_result ~client_id:first.client_id ~id:read_command.id
        ~payload:(`Assoc ["ok", `Bool true; "data", `Assoc [
          "url", `String "https://example.org/first"; "title", `String "First browser";
          "text", `String "first-owned"; "chars", `Int 11; "truncated", `Bool false]]));
      match Eio.Promise.await pending with
      | Ok (Ok data) ->
        check bool "reply identifies the original single client" true
          (Yojson.Safe.Util.member "clientId" data = `String (Browser_lane.client_id_to_string first.client_id));
        check bool "page belongs to the pinned browser" true
          (Yojson.Safe.Util.(data |> member "page" |> member "text") = `String "first-owned")
      | _ -> fail "second connection disrupted the once-resolved read"))

let test_keeper_discovers_clients_without_dispatch () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let info raw browser : Browser_lane.client_info =
        let client_id = match Browser_lane.client_id_of_string raw with
          | Ok id -> id | Error error -> fail error in
        {client_id; browser; version="fixture"; engine_version="155.0.1"} in
      let clients = [
        info "20000000-0000-4000-8000-000000000001" Browser_lane.Firefox;
        info "20000000-0000-4000-8000-000000000002" Browser_lane.Zen] in
      List.iter (fun info ->
        Eio.Switch.on_release sw (fun () ->
          ignore (Browser_lane.disconnect_client ~client_id:info.Browser_lane.client_id));
        ignore (Browser_lane.take_command ~client_info:info ~window_sec:0.001)) clients;
      let result = Masc.Tool_misc_browser_lane.handle_tabs
        ~tool_name:"BrowserTabs" ~start_time:(Unix.gettimeofday ()) (`Assoc []) in
      let data = Masc.Tool_result.data result in
      check bool "ambiguous failure stays actionable" true
        (Yojson.Safe.Util.member "error" data = `String "ambiguous_browser_clients");
      check int "both browser identities discoverable" 2
        (Yojson.Safe.Util.(data |> member "clients" |> to_list |> List.length));
      check bool "model-facing error preserves the same discovery payload" true
        (Yojson.Safe.from_string (Masc.Tool_result.message result) = data);
      List.iter (fun info -> check bool "no dispatch before explicit selection" true
        (Browser_lane.take_command ~client_info:info ~window_sec:0.001 = Ok None)) clients))

let () = run "browser surface" ["behavior",[
  test_case "read any website by active or explicit tab" `Quick test_any_website_selection;
  test_case "empty browser has no page" `Quick test_empty_browser;
  test_case "invalid input is refused" `Quick test_strict_input;
  test_case "backend failure is visible" `Quick test_remote_failure;
  test_case "capture target and image identity" `Quick test_capture_identity;
  test_case "Keeper discovers ambiguous clients without dispatch" `Quick test_keeper_discovers_clients_without_dispatch;
  test_case "live read pins client across both hops" `Quick test_live_read_pins_client_between_hops]]
