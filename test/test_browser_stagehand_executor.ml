(* The Stagehand page executor against a fake [call]: which Stagehand calls a
   verb sends, and whether its answer is what the lane's readers take. *)
open Alcotest
module Executor = Masc.Browser_stagehand_executor
module Wire = Masc.Browser_stagehand_wire
module Session = Masc.Browser_stagehand_session
module Lane = Browser_lane

let to_s = Yojson.Safe.to_string

(* A 1x1 PNG. *)
let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

type page = { page_id : string; mutable url : string; title : string }

type fake =
  { mutable pages : page list
  ; mutable active : string option
  ; mutable scroll_y : int
  ; mutable scrolls_while_capturing : bool
  ; mutable failing : Wire.call -> Session.call_failure option
  ; mutable sent : Wire.call list
  }

let fake pages ~active =
  { pages; active; scroll_y = 0; scrolls_while_capturing = false; failing = (fun _ -> None); sent = [] }
;;

let page_ref page = `Assoc [ "page_id", `String page.page_id; "url", `String page.url ]
let find fake page_id = List.find (fun page -> String.equal page.page_id page_id) fake.pages

let viewport fake =
  `Assoc [ "documentId", `String "d1"; "width", `Int 800; "height", `Int 600; "scrollX", `Int 0; "scrollY", `Int fake.scroll_y ]
;;

let call fake request =
  fake.sent <- request :: fake.sent;
  match fake.failing request with
  | Some failure -> Error failure
  | None ->
    (match request with
     | Wire.Context_pages -> Ok (`List (List.map page_ref fake.pages))
     | Wire.Context_active_page ->
       Ok (match fake.active with Some page_id -> page_ref (find fake page_id) | None -> `Null)
     | Wire.Page_evaluate { page_id; _ } ->
       let page = find fake page_id in
       Ok
         (`Assoc
           [ "value", `String (to_s (`Assoc [ "url", `String page.url; "title", `String page.title; "viewport", viewport fake ])) ])
     | Wire.Page_screenshot _ ->
       if fake.scrolls_while_capturing then fake.scroll_y <- fake.scroll_y + 1;
       Ok (`Assoc [ "data", `String png ])
     | Wire.Page_goto { page_id; url } ->
       (find fake page_id).url <- url;
       Ok (`Assoc [ "page", `Assoc [ "page_id", `String page_id; "url", `String url ]; "response", `Null ])
     | Wire.Act _ | Wire.Observe _ | Wire.Extract _ ->
       Ok (`Assoc [ "data", `Assoc [ "success", `Bool true ]; "metadata", `Assoc [ "cache", `Assoc [] ] ])
     | Wire.Close -> failf "the executor sent %s" (Wire.method_name request))
;;

let blank = { page_id = "P1"; url = "about:blank"; title = "" }
let shop () = { page_id = "P2"; url = "http://127.0.0.1:1/shop"; title = "Shop" }

let served = function
  | Lane.Answered (`Assoc fields) ->
    (match List.assoc_opt "ok" fields, List.assoc_opt "data" fields with
     | Some (`Bool true), Some data -> data
     | _ -> fail "an answer without ok data")
  | Lane.Answered _ | Lane.Lane_absent | Lane.Timed_out | Lane.Refused _ | Lane.Rejected_before_effect _ ->
    fail "the verb was not served"
;;

let rejected_before_effect = function
  | Lane.Rejected_before_effect _ -> true
  | Lane.Answered _ | Lane.Lane_absent | Lane.Timed_out | Lane.Refused _ -> false
;;

let refused = function
  | Lane.Refused _ -> true
  | Lane.Answered _ | Lane.Lane_absent | Lane.Timed_out | Lane.Rejected_before_effect _ -> false
;;

(* Lists tabs once, so the pages have ids. *)
let listed tabs fake = served (Executor.execute ~tabs ~call:(call fake) Lane.Tabs_list)

let test_tabs () =
  let tabs = Executor.Tabs.create () and fake = fake [ blank; shop () ] ~active:(Some "P2") in
  (match listed tabs fake with
   | `List [ first; second ] ->
     check (list string) "a tab has what the readers decode" [ "active"; "id"; "title"; "url" ]
       (match first with `Assoc fields -> List.sort compare (List.map fst fields) | _ -> []);
     check int "first id" 0 Yojson.Safe.Util.(member "id" first |> to_int);
     check bool "the active page is the active tab" true Yojson.Safe.Util.(member "active" second |> to_bool);
     check string "the title comes from the page" "Shop" Yojson.Safe.Util.(member "title" second |> to_string)
   | _ -> fail "two tabs");
  fake.pages <- [ shop (); { page_id = "P3"; url = "about:blank"; title = "" } ];
  ignore (listed tabs fake);
  check (option string) "a page keeps its id" (Some "P2") (Executor.Tabs.page_of_id tabs 1);
  check (option string) "a new page gets a new id" (Some "P3") (Executor.Tabs.page_of_id tabs 2);
  check (option string) "an id is not given to another page" (Some "P1") (Executor.Tabs.page_of_id tabs 0);
  check (option string) "an id never given" None (Executor.Tabs.page_of_id tabs 3)
;;

let test_goto () =
  let tabs = Executor.Tabs.create () and fake = fake [ blank; shop () ] ~active:(Some "P2") in
  ignore (listed tabs fake);
  let data = served (Executor.execute ~tabs ~call:(call fake) (Lane.Page_goto { url = "http://127.0.0.1:1/cart"; tab_id = Some 0 })) in
  check string "BrowserGoto's output: url and title only" {|{"url":"http://127.0.0.1:1/cart","title":""}|} (to_s data);
  ignore (served (Executor.execute ~tabs ~call:(call fake) (Lane.Page_goto { url = "http://127.0.0.1:1/"; tab_id = None })));
  check string "no tab id navigates the active page" "http://127.0.0.1:1/" (find fake "P2").url;
  fake.sent <- [];
  List.iter
    (fun (name, verb) -> check bool name true (rejected_before_effect (Executor.execute ~tabs ~call:(call fake) verb)))
    [ "an unknown tab", Lane.Page_goto { url = "http://127.0.0.1:1/"; tab_id = Some 9 };
      "not HTTP(S)", Lane.Page_goto { url = "file:///etc/hosts"; tab_id = Some 0 } ];
  check int "nothing was sent for them" 0 (List.length fake.sent);
  fake.active <- None;
  check bool "no active page to navigate" true
    (rejected_before_effect (Executor.execute ~tabs ~call:(call fake) (Lane.Page_goto { url = "http://127.0.0.1:1/"; tab_id = None })))
;;

(* A failure before the navigation was sent cannot have navigated; after it,
   the navigation may have happened. *)
let test_goto_effect_boundary () =
  let tabs = Executor.Tabs.create () and fake = fake [ blank ] ~active:(Some "P1") in
  ignore (listed tabs fake);
  let goto = Lane.Page_goto { url = "http://127.0.0.1:1/"; tab_id = Some 0 } in
  fake.failing <- (function Wire.Page_goto _ -> Some (Session.Not_delivered "receiver threw") | _ -> None);
  check bool "not delivered: before effect" true (rejected_before_effect (Executor.execute ~tabs ~call:(call fake) goto));
  fake.failing <- (function Wire.Page_goto _ -> Some (Session.Lost "no answer") | _ -> None);
  check bool "lost: may have navigated" true (refused (Executor.execute ~tabs ~call:(call fake) goto));
  fake.failing <- (function Wire.Page_evaluate _ -> Some (Session.Not_delivered "receiver threw") | _ -> None);
  check bool "a read after the navigation fails as after effect" true (refused (Executor.execute ~tabs ~call:(call fake) goto))
;;

let test_capture_passes_the_surface () =
  let tabs = Executor.Tabs.create () and fake = fake [ blank; shop () ] ~active:(Some "P2") in
  ignore (listed tabs fake);
  Eio_main.run
  @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Lane.install_stagehand_executor (Some (Executor.execute ~tabs ~call:(call fake)));
  let captured = Masc.Browser_surface.capture { Masc.Browser_surface.route = Lane.Stagehand_route; tab_id = Some 1 } in
  Lane.install_stagehand_executor None;
  match captured with
  | Ok data ->
    check string "source" "stagehand" Yojson.Safe.Util.(member "source" data |> to_string);
    check string "url" "http://127.0.0.1:1/shop" Yojson.Safe.Util.(member "url" data |> to_string);
    let scene_reads =
      List.filter
        (function
          | Wire.Page_evaluate { expression; _ } ->
            String.length expression > String.length Masc.Browser_scene_script.runtime
          | _ -> false)
        fake.sent
    in
    check int "only the two capture reads carry scene runtime" 2 (List.length scene_reads)
  | Error failure -> fail (Masc.Browser_surface.failure_message failure)
;;

let test_capture_refuses_a_moving_page () =
  let tabs = Executor.Tabs.create () and fake = fake [ shop () ] ~active:(Some "P2") in
  ignore (listed tabs fake);
  fake.scrolls_while_capturing <- true;
  check bool "the page scrolled between the reads" true
    (refused (Executor.execute ~tabs ~call:(call fake) (Lane.Page_capture { tab_id = 0 })))
;;

let test_sentence_verbs () =
  let tabs = Executor.Tabs.create () and fake = fake [ blank; shop () ] ~active:(Some "P2") in
  ignore (listed tabs fake);
  let schema = `Assoc [ "type", `String "object" ] in
  List.iter
    (fun (verb, expected) ->
      fake.sent <- [];
      let data = served (Executor.execute ~tabs ~call:(call fake) verb) in
      check (list string) "tab, Stagehand's data and metadata" [ "data"; "metadata"; "tabId" ]
        (match data with `Assoc fields -> List.sort compare (List.map fst fields) | _ -> []);
      match fake.sent with
      | [ sent ] ->
        check string (Wire.method_name expected) (to_s (Wire.call_params expected)) (to_s (Wire.call_params sent));
        check int "the protocol receives the per-call timeout in milliseconds"
          (Wire.timeout_ms Wire.sentence_timeout)
          Yojson.Safe.Util.(Wire.call_params sent |> member "options" |> member "timeout" |> to_int)
      | _ -> fail "one Stagehand call")
    [ Lane.Page_instruct { tab_id = 1; instruction = "click Buy" }, Wire.Act { page_id = "P2"; instruction = "click Buy"; timeout = Wire.sentence_timeout };
      Lane.Page_locate { tab_id = 1; instruction = None }, Wire.Observe { page_id = "P2"; instruction = None; timeout = Wire.sentence_timeout };
      Lane.Page_extract { tab_id = 0; instruction = "the price"; schema = Some schema },
      Wire.Extract { page_id = "P1"; instruction = "the price"; schema = Some schema; timeout = Wire.sentence_timeout } ];
  fake.failing <- (function Wire.Act _ -> Some (Session.Rejected { code = -32603; message = "no element" }) | _ -> None);
  check bool "an act the extension refused may have acted" true
    (refused (Executor.execute ~tabs ~call:(call fake) (Lane.Page_instruct { tab_id = 1; instruction = "click Buy" })));
  fake.failing <- (function Wire.Act _ -> Some Session.Abandoned_call_pending | _ -> None);
  check bool "an act the session did not take" true
    (rejected_before_effect (Executor.execute ~tabs ~call:(call fake) (Lane.Page_instruct { tab_id = 1; instruction = "click Buy" })))
;;

let test_unserved_verbs () =
  let tabs = Executor.Tabs.create () and fake = fake [ blank ] ~active:None in
  List.iter
    (fun verb ->
      check bool (Lane.verb_to_string verb) true (rejected_before_effect (Executor.execute ~tabs ~call:(call fake) verb)))
    [ Lane.Page_read { tab_id = None; max_chars = None }; Lane.Session_status; Lane.Page_elements { tab_id = None } ];
  check int "nothing was sent" 0 (List.length fake.sent)
;;

let test_evaluate_expression () =
  let args = `Assoc [ "mode", `String "viewport" ] in
  let expression = Executor.evaluate_expression ~runtime:Executor.No_runtime ~body:"return 1;" ~args in
  let with_scene = Executor.evaluate_expression ~runtime:Executor.Scene_runtime ~body:"return 1;" ~args in
  check bool "called at once with its arguments as a JSON literal" true
    (String.ends_with ~suffix:("(" ^ to_s args ^ ")") expression);
  check int "scene runtime is added only when requested"
    (String.length expression + String.length Masc.Browser_scene_script.runtime)
    (String.length with_scene)
;;

let () =
  run "browser_stagehand_executor" [
    "tabs", [ test_case "pages become tabs with ids that stay" `Quick test_tabs ];
    "goto", [
      test_case "navigates a listed or the active tab" `Quick test_goto;
      test_case "a failure after the navigation is not before effect" `Quick test_goto_effect_boundary;
    ];
    "capture", [
      test_case "a capture passes the surface's checks" `Quick test_capture_passes_the_surface;
      test_case "a page that moved during capture is refused" `Quick test_capture_refuses_a_moving_page;
    ];
    "sentences", [ test_case "each sentence verb sends one Stagehand call" `Quick test_sentence_verbs ];
    "refusals", [ test_case "an unserved verb sends nothing" `Quick test_unserved_verbs ];
    "evaluate", [ test_case "the expression calls its body" `Quick test_evaluate_expression ];
  ]
;;
