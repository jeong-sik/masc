(* The dashboard's session and navigation routes: the request names a lane
   the server owns, and the verb reaches that lane's executor only. *)
open Alcotest
module Lane = Browser_lane
module Routes = Server_routes_http_browser_surface

let answered = Lane.Answered (`Assoc [ "ok", `Bool true; "data", `Assoc [] ])

let with_executors f =
  Eio_main.run
  @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  let automation = ref [] and stagehand = ref [] in
  Lane.install_automation_executor (Some (fun verb -> automation := verb :: !automation; answered));
  Lane.install_stagehand_executor (Some (fun verb -> stagehand := verb :: !stagehand; answered));
  Fun.protect
    ~finally:(fun () ->
      Lane.install_automation_executor None;
      Lane.install_stagehand_executor None)
    (fun () -> f ~automation ~stagehand)
;;

let body fields = `Assoc fields

let test_the_named_lane_takes_the_verb () =
  with_executors
  @@ fun ~automation ~stagehand ->
  check bool "stagehand open" true
    (Result.is_ok (Routes.session (body [ "action", `String "open"; "lane", `String "stagehand" ])));
  check bool "automation goto" true
    (Result.is_ok (Routes.goto (body [ "url", `String "https://example.org/"; "lane", `String "automation" ])));
  check (list string) "stagehand got the open" [ "session.open" ] (List.map Lane.verb_to_string !stagehand);
  check (list string) "automation got the goto" [ "page.goto" ] (List.map Lane.verb_to_string !automation)
;;

let test_a_request_without_a_server_lane_is_refused () =
  with_executors
  @@ fun ~automation ~stagehand ->
  List.iter
    (fun (name, result) -> check bool name true (Result.is_error result))
    [ "no lane", Routes.session (body [ "action", `String "open" ]);
      "live", Routes.session (body [ "action", `String "close"; "lane", `String "live" ]);
      "not a lane", Routes.goto (body [ "url", `String "https://example.org/"; "lane", `String "chromium" ]) ];
  check int "no executor was reached" 0 (List.length !automation + List.length !stagehand)
;;

let () =
  run "browser_surface_session_routes" [
    "lanes", [
      test_case "the named server lane takes the verb" `Quick test_the_named_lane_takes_the_verb;
      test_case "a request without a server lane is refused" `Quick test_a_request_without_a_server_lane_is_refused;
    ];
  ]
;;
