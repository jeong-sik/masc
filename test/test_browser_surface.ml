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
let request tab_id : Surface.request = { source = Automation; tab_id }
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

let () = run "browser surface" ["behavior",[
  test_case "read any website by active or explicit tab" `Quick test_any_website_selection;
  test_case "empty browser has no page" `Quick test_empty_browser;
  test_case "invalid input is refused" `Quick test_strict_input;
  test_case "backend failure is visible" `Quick test_remote_failure]]
