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
  ; mutable script_throws : string option  (* what the page script throws, as the expression answers it *)
  ; mutable failing : Wire.call -> Session.call_failure option
  ; mutable evaluated : Yojson.Safe.t option  (* what a page script answers, when set *)
  ; mutable created_count : int
  ; mutable sent : Wire.call list
  }

let fake pages ~active =
  { pages; active; scroll_y = 0; scrolls_while_capturing = false; script_throws = None; failing = (fun _ -> None); evaluated = None; created_count = 0; sent = [] }
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
     | Wire.Context_new_page ->
       fake.created_count <- fake.created_count + 1;
       let page = {page_id="NEW" ^ string_of_int fake.created_count;url="about:blank";title="New tab"} in
       fake.pages <- fake.pages @ [page]; Ok (page_ref page)
     | Wire.Page_close {page_id} ->
       fake.pages <- List.filter (fun page -> page.page_id <> page_id) fake.pages;
       Ok (`Assoc ["closed",`Bool true])
     | Wire.Page_reload {page_id} | Wire.Page_go_back {page_id} | Wire.Page_go_forward {page_id} ->
       Ok (`Assoc ["page",page_ref (find fake page_id);"response",`Null])
     | Wire.Context_active_page ->
       Ok (match fake.active with Some page_id -> page_ref (find fake page_id) | None -> `Null)
     | Wire.Page_evaluate { page_id; _ } ->
       (match fake.evaluated with
        | Some value -> Ok (`Assoc [ "value", `String (to_s value) ])
        | None ->
       let page = find fake page_id in
        (match fake.script_throws with
         | Some reason -> Ok (`Assoc [ "value", `Assoc [ "thrown", `String reason ] ])
         | None ->
           Ok
             (`Assoc
               [ "value", `String (to_s (`Assoc [ "url", `String page.url; "title", `String page.title; "viewport", viewport fake ])) ])))
     | Wire.Page_screenshot _ ->
       if fake.scrolls_while_capturing then fake.scroll_y <- fake.scroll_y + 1;
       Ok (`Assoc [ "data", `String png ])
     | Wire.Page_goto { page_id; url } ->
       (find fake page_id).url <- url;
       Ok (`Assoc [ "page", `Assoc [ "page_id", `String page_id; "url", `String url ]; "response", `Null ])
     | Wire.Act _ | Wire.Observe _ | Wire.Extract _ ->
       Ok (`Assoc [ "data", `Assoc [ "success", `Bool true ]; "metadata", `Assoc [ "cache", `Assoc [] ] ])
     | Wire.Page_hover _ | Wire.Page_click _ | Wire.Page_scroll _ | Wire.Page_drag_and_drop _
     | Wire.Page_double_click _ | Wire.Page_type _ | Wire.Page_key_press _ -> Ok (`Assoc [ "ok", `Bool true ])
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

(* A later session's pages are new pages: an id from before reaches none of
   them, even when the new session reuses a page id. *)
let test_tabs_across_sessions () =
  let tabs = Executor.Tabs.create () and fake = fake [ blank; shop () ] ~active:(Some "P2") in
  ignore (listed tabs fake);
  Executor.Tabs.forget_pages tabs;
  check (option string) "an earlier session's id reaches no page" None (Executor.Tabs.page_of_id tabs 0);
  ignore (listed tabs fake);
  check (option string) "a page of the new session gets a new id" (Some "P1") (Executor.Tabs.page_of_id tabs 2);
  check (option string) "the old id stays unused" None (Executor.Tabs.page_of_id tabs 0)
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
  Lane.install_activity_observer (Some (fun _ -> Lane.Enabled));
  Lane.install_stagehand_executor (Some (fun ~actor verb -> Executor.execute ~tabs ~call:(call fake) ?actor verb));
  let captured = Fun.protect ~finally:(fun () ->
    Lane.install_activity_observer None; Lane.install_stagehand_executor None) (fun () ->
    Masc.Browser_surface.capture { Masc.Browser_surface.route = Masc.Browser_selection.Exact Lane.Stagehand_route; tab_id = Some 1 }) in
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

(* Reads run the automation lane's page scripts: the expression sent is
   that script with its arguments, and the answer keeps the tab. *)
let test_reads_run_the_page_scripts () =
  let tabs = Executor.Tabs.create () and fake = fake [ blank; shop () ] ~active:(Some "P2") in
  ignore (listed tabs fake);
  let sent_expression () =
    match fake.sent with
    | Wire.Page_evaluate { expression; _ } :: _ -> expression
    | _ -> fail "no page.evaluate was sent"
  in
  fake.sent <- [];
  let text = served (Executor.execute ~tabs ~call:(call fake) (Lane.Page_read { tab_id = None; max_chars = None })) in
  check int "text of the active tab names it" 1 Yojson.Safe.Util.(member "tabId" text |> to_int);
  check string "text read with the default cap"
    (Executor.evaluate_expression ~runtime:Executor.No_runtime ~body:Masc.Browser_page_script.text ~args:(`Int Masc.Browser_page_script.default_text_chars))
    (sent_expression ());
  let elements = served (Executor.execute ~tabs ~call:(call fake) (Lane.Page_elements { tab_id = None })) in
  check string "elements script" (Executor.evaluate_expression ~runtime:Executor.No_runtime ~body:Masc.Browser_page_script.elements ~args:`Null) (sent_expression ());
  check int "elements of the active tab name it" 1 Yojson.Safe.Util.(member "tabId" elements |> to_int);
  let scene =
    served (Executor.execute ~tabs ~call:(call fake)
      (Lane.Page_scene { tab_id = 0; max_chars = 2000; view = Lane.Content; scope = None }))
  in
  check string "scene call with the read arguments"
    (Executor.evaluate_expression ~runtime:Executor.Scene_runtime ~body:Masc.Browser_scene_script.read_call
       ~args:(match Lane.scene_args ~tab_id:0 ~max_chars:2000 ~view:Lane.Content ~scope:None with
              | `Assoc fields -> `Assoc (("mode", `String "read") :: fields)
              | _ -> fail "scene arguments must be an object"))
    (sent_expression ());
  check int "scene names its tab" 0 Yojson.Safe.Util.(member "tabId" scene |> to_int);
  fake.sent <- [];
  check bool "a cap past the most is refused" true
    (rejected_before_effect
       (Executor.execute ~tabs ~call:(call fake) (Lane.Page_read { tab_id = Some 1; max_chars = Some (Masc.Browser_page_script.max_text_chars + 1) })));
  check int "and sends nothing" 0 (List.length fake.sent)
;;

let point = { Lane.Pointer.x = 0.5; y = 0.25 }
let observed_viewport = { Lane.Pointer.document_id = "d1"; width = 800.; height = 600.; scroll_x = 0.; scroll_y = 0. }

let feedback_arguments body = function
  | Wire.Page_evaluate {expression;_} ->
    let sample = Executor.evaluate_expression ~runtime:Executor.No_runtime ~body ~args:`Null in
    let prefix = String.sub sample 0 (String.length sample - String.length "null)") in
    if String.starts_with ~prefix expression then
      Some (Yojson.Safe.from_string (String.sub expression (String.length prefix)
        (String.length expression - String.length prefix - 1)))
    else None
  | _ -> None
;;

let test_actor_feedback_outcomes () = Eio_main.run (fun _ ->
  let tabs = Executor.Tabs.create () and fake = fake [shop ()] ~active:(Some "P2") in
  ignore (listed tabs fake);
  let begins = ref [] and finishes = ref [] and overlay_fails = ref false in
  let call request = match feedback_arguments Masc.Browser_pointer_feedback.begin_script request with
    | Some args -> begins:=args::!begins;
      if !overlay_fails then Error (Session.Lost "overlay unavailable") else Ok (`Assoc ["value",`String "null"])
    | None -> match feedback_arguments Masc.Browser_pointer_feedback.finish_script request with
      | Some args -> finishes:=args::!finishes;
        if !overlay_fails then raise (Failure "overlay unavailable") else Ok (`Assoc ["value",`String "null"])
      | None -> call fake request in
  let invoke () = Executor.execute ~tabs ~call ~actor:"keeper-observed"
    (Lane.Page_interact {tab_id=0;expected_url=Some "http://127.0.0.1:1/shop";
      action=Lane.Hover_at {point;viewport=observed_viewport}}) in
  let check_feedback phase =
    let start=List.hd !begins and finish=List.hd !finishes in
    check string "explicit keeper owns the overlay" "keeper-observed" Yojson.Safe.Util.(member "actor" start |> to_string);
    check string "original action is displayed" "hover_at" Yojson.Safe.Util.(member "action" start |> to_string);
    let id=Yojson.Safe.Util.(member "requestId" start |> to_string) in
    check bool "interaction request identity is a UUID" true (Option.is_some (Uuidm.of_string id));
    check string "finish belongs to this exact request" id Yojson.Safe.Util.(member "requestId" finish |> to_string);
    check string "observational terminal phase" phase Yojson.Safe.Util.(member "phase" finish |> to_string) in
  ignore (served (invoke ()));check_feedback "finished";
  fake.failing <- (function Wire.Page_evaluate _ -> Some (Session.Rejected {code= -32603;message="page_url_changed"})|_->None);
  check bool "guard refusal stays before effect" true (rejected_before_effect (invoke ()));
  check_feedback "refused";
  fake.sent <- [];
  fake.failing <- (function Wire.Page_hover _ -> Some (Session.Lost "native input unanswered")|_->None);
  check bool "unknown input stays unknown" true (refused (invoke ()));
  check_feedback "unknown";
  check int "unknown input is never replayed" 1
    (List.length (List.filter (function Wire.Page_hover _->true|_->false) fake.sent));
  fake.failing <- (fun _ -> None);fake.sent<-[];overlay_fails:=true;
  ignore (served (invoke ()));
  check int "overlay failures neither block nor repeat authoritative input" 1
    (List.length (List.filter (function Wire.Page_hover _->true|_->false) fake.sent));
  let count=List.length !begins in
  ignore (served (Executor.execute ~tabs ~call (Lane.Page_interact {tab_id=0;
    expected_url=Some "http://127.0.0.1:1/shop";action=Lane.Hover_at {point;viewport=observed_viewport}})));
  check int "anonymous calls invent no owner" count (List.length !begins);
  overlay_fails:=false;
  let entered,enter=Eio.Promise.create () and never,_=Eio.Promise.create () in
  let cancelled=ref false in
  let cancel_call = function
    | Wire.Page_hover _ -> Eio.Promise.resolve enter ();Eio.Promise.await never
    | request -> call request in
  (match Eio.Switch.run (fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       match Executor.execute ~tabs ~call:cancel_call ~actor:"keeper-observed"
           (Lane.Page_interact {tab_id=0;expected_url=Some "http://127.0.0.1:1/shop";
             action=Lane.Hover_at {point;viewport=observed_viewport}}) with
       | _ -> fail "cancelled native input returned normally"
       | exception (Eio.Cancel.Cancelled _ as exn) -> cancelled:=true;raise exn);
     Eio.Promise.await entered;Eio.Switch.fail sw Exit)
   with () -> fail "expected scope cancellation" | exception Exit -> ());
  check bool "caller cancellation propagates" true !cancelled;
  check_feedback "unknown")
;;

let test_hover_wire () =
  let request = Wire.Page_hover {page_id="P2";x=400.;y=150.} in
  let encoded = Wire.encode_call ~id:7 request |> Yojson.Safe.from_string in
  check string "official runtime method" "page.hover" Yojson.Safe.Util.(member "method" encoded |> to_string);
  check string "coordinates and page use protocol wire keys"
    {|{"page_id":"P2","x":400.0,"y":150.0}|}
    Yojson.Safe.Util.(member "params" encoded |> to_s);
  check bool "native hover never asks a model" false (Wire.uses_model request);
  check bool "native hover has no sentence timeout" true (Option.is_none (Wire.sentence_timeout_of_call request));
  let drag = Wire.Page_drag_and_drop {page_id="P2";from_x=400.;from_y=150.;to_x=600.;to_y=300.;
    route=[{x=500.;y=225.}]} in
  check string "native drag forwards its CSS-pixel route in runtime options"
    {|{"page_id":"P2","from_x":400.0,"from_y":150.0,"to_x":600.0,"to_y":300.0,"options":{"route":[{"x":500.0,"y":225.0}]}}|}
    (Wire.call_params drag |> to_s)
;;

let test_semantic_pointer_input () =
  let tabs = Executor.Tabs.create () and fake = fake [shop ()] ~active:(Some "P2") in
  ignore (listed tabs fake);
  let expected_url = Some "http://127.0.0.1:1/shop" in
  let execute ?(expected_url=expected_url) action resolution =
    fake.sent <- [];
    let responses = ref [resolution;
      `Assoc ["url",`String "http://127.0.0.1:1/shop"];
      `Assoc ["url",`String "http://127.0.0.1:1/shop";"title",`String "Shop"]] in
    let call request = match request with
      | Wire.Page_evaluate _ ->
        fake.sent <- request :: fake.sent;
        (match !responses with
         | value::rest -> responses:=rest;Ok (`Assoc ["value",`String (to_s value)])
         | [] -> fail "unexpected evaluation")
      | _ -> call fake request in
    Executor.execute ~tabs ~call (Lane.Page_interact {tab_id=0;expected_url;action}) in
  let viewport = Lane.Pointer.viewport_to_json observed_viewport in
  let resolved_point = Lane.Pointer.point_to_json point in
  let hovered = served (execute (Lane.Hover (Lane.Selector "#menu"))
    (`Assoc ["url",`String "http://127.0.0.1:1/shop";"point",resolved_point;"viewport",viewport])) in
  check string "semantic hover retains the requested action" "hover" Yojson.Safe.Util.(member "action" hovered |> to_string);
  (match List.rev fake.sent with
   | [Wire.Page_evaluate _;Wire.Page_evaluate _;Wire.Page_hover {page_id="P2";x=400.;y=150.};Wire.Page_evaluate _] -> ()
   | _ -> fail "resolve, guard, native hover, receipt required");
  let drag = Lane.Drag_to {source=Lane.Selector "#source";destination=Lane.Selector "#destination";
    via=[];duration_ms=0} in
  let dragged = served (execute drag (`Assoc ["url",`String "http://127.0.0.1:1/shop";"from",resolved_point;
    "to",Lane.Pointer.point_to_json {x=0.75;y=0.5};"viewport",viewport])) in
  check string "semantic drag retains the requested action" "drag_to" Yojson.Safe.Util.(member "action" dragged |> to_string);
  (match List.rev fake.sent with
   | [Wire.Page_evaluate _;Wire.Page_evaluate _;
      Wire.Page_drag_and_drop {page_id="P2";from_x=400.;from_y=150.;to_x=600.;to_y=300.;
        route=[{x=500.;y=225.}]};Wire.Page_evaluate _] -> ()
   | _ -> fail "resolved semantic drag must use one native runtime drag");
  ignore (served (execute drag (`Assoc ["url",`String "http://127.0.0.1:1/shop";"from",resolved_point;
    "to",Lane.Pointer.point_to_json {x=0.75;y=0.5};"arrival",Lane.Pointer.point_to_json {x=0.7;y=0.5};"viewport",viewport])));
  check bool "semantic drag enters the hit-tested destination before its center" true
    (List.exists (function Wire.Page_drag_and_drop {route=[{x=500.;y=225.};{x=560.;y=300.}];_}->true|_->false) fake.sent);
  List.iter (fun arrival ->
    check bool "malformed arrival is refused before native input" true
      (rejected_before_effect (execute drag (`Assoc ["url",`String "http://127.0.0.1:1/shop";"from",resolved_point;
        "to",Lane.Pointer.point_to_json {x=0.75;y=0.5};"arrival",arrival;"viewport",viewport])));
    check int "bad arrival only performs target resolution" 1 (List.length fake.sent))
    [`Null;`Assoc ["x",`Float 1.;"y",`Float 0.5]];
  List.iter (fun action ->
    let clicked = served (execute ~expected_url:None action
      (`Assoc ["url",`String "http://127.0.0.1:1/shop";"point",resolved_point;"viewport",viewport])) in
    check string "native semantic click retains the requested action" "click" Yojson.Safe.Util.(member "action" clicked |> to_string);
    match List.rev fake.sent with
    | [Wire.Page_evaluate _;Wire.Page_evaluate {expression;_};
       Wire.Page_click {page_id="P2";x=400.;y=150.};Wire.Page_evaluate _] ->
      check string "click binds the resolver's URL and viewport before native input"
        (Executor.evaluate_expression ~runtime:Executor.Scene_runtime
          ~body:Masc.Browser_interaction.pointer_guard_script
          ~args:(Lane.interaction_args ~tab_id:0 ~expected_url
            (Lane.Click_at {point;viewport=observed_viewport;button=Lane.Pointer.Primary}))) expression
    | _ -> fail "observed click must resolve, guard, and dispatch one native click")
    [Lane.Click "#menu-item";Lane.Click_node {document_id="d1";node_id="n1"}];
  check bool "resolver refusal is before any input" true
    (rejected_before_effect (execute (Lane.Hover (Lane.Selector "#covered"))
      (`Assoc ["interactionFailure",`Assoc ["message",`String "element_pointer_obstructed";"effectStarted",`Bool false]])));
  check int "refusal sends only resolution" 1 (List.length fake.sent);
  check bool "malformed resolver geometry is before input" true
    (rejected_before_effect (execute (Lane.Hover (Lane.Selector "#menu")) (`Assoc [])));
  check int "malformed target sends no native input" 1 (List.length fake.sent);
  fake.sent <- [];
  let path = [{Lane.Pointer.x=0.6;y=0.1};{Lane.Pointer.x=0.7;y=0.4}] in
  let custom = Lane.Drag_to {source=Lane.Selector "#source";destination=Lane.Selector "#destination";
    via=path;duration_ms=0} in
  ignore (served (execute custom (`Assoc ["url",`String "http://127.0.0.1:1/shop";"from",resolved_point;
    "to",Lane.Pointer.point_to_json {x=0.75;y=0.5};"viewport",viewport])));
  (match List.rev fake.sent with
   | [Wire.Page_evaluate _;Wire.Page_evaluate _;
      Wire.Page_drag_and_drop {route=[{x=480.;y=60.};{x=560.;y=240.}];_};Wire.Page_evaluate _] -> ()
   | _ -> fail "semantic custom path must reach the runtime in CSS pixels, in order");
  ignore (served (execute custom (`Assoc ["url",`String "http://127.0.0.1:1/shop";"from",resolved_point;
    "to",Lane.Pointer.point_to_json {x=0.75;y=0.5};"arrival",Lane.Pointer.point_to_json {x=0.7;y=0.5};"viewport",viewport])));
  check bool "destination arrival follows the full explicit path" true
    (List.exists (function Wire.Page_drag_and_drop {route=[{x=480.;y=60.};{x=560.;y=240.};{x=560.;y=300.}];_}->true|_->false) fake.sent);
  fake.sent <- [];
  let raw = Lane.Drag {from=point;to_={x=0.75;y=0.5};viewport=observed_viewport;via=path;duration_ms=0} in
  ignore (served (Executor.execute ~tabs ~call:(call fake)
    (Lane.Page_interact {tab_id=0;expected_url;action=raw})));
  check bool "coordinate drags forward the same observed path" true
    (List.exists (function Wire.Page_drag_and_drop {route=[{x=480.;y=60.};{x=560.;y=240.}];_}->true|_->false) fake.sent);
  List.iter (fun action ->
    fake.sent <- [];
    check bool "movement duration is refused before input" true
      (rejected_before_effect (Executor.execute ~tabs ~call:(call fake)
        (Lane.Page_interact {tab_id=0;expected_url;action})));
    check int "timing is refused before resolution too" 0 (List.length fake.sent))
    [Lane.Drag_to {source=Lane.Selector "#source";destination=Lane.Selector "#destination";via=path;duration_ms=10};
     Lane.Drag {from=point;to_={x=0.75;y=0.5};viewport=observed_viewport;via=path;duration_ms=10}]
;;

let test_hover_effect_boundary () =
  let tabs = Executor.Tabs.create () and fake = fake [shop ()] ~active:(Some "P2") in
  ignore (listed tabs fake);
  let invoke () = Executor.execute ~tabs ~call:(call fake)
    (Lane.Page_interact {tab_id=0;expected_url=Some "http://127.0.0.1:1/shop";
      action=Lane.Hover_at {point;viewport=observed_viewport}}) in
  fake.sent <- [];
  fake.failing <- (function Wire.Page_evaluate _ -> Some (Session.Rejected {code= -32603;message="observed_viewport_changed"}) | _ -> None);
  check bool "changed viewport blocks native hover" true (rejected_before_effect (invoke ()));
  check bool "guard failure sends no hover" true (List.for_all (function Wire.Page_hover _ -> false | _ -> true) fake.sent);
  fake.sent <- [];
  fake.failing <- (function Wire.Page_hover _ -> Some (Session.Lost "input reply missing") | _ -> None);
  check bool "lost input is uncertain" true (refused (invoke ()));
  check int "unknown native input is never replayed" 1
    (List.length (List.filter (function Wire.Page_hover _ -> true | _ -> false) fake.sent));
  fake.sent <- [];
  let reads = ref 0 in
  fake.failing <- (function Wire.Page_evaluate _ -> incr reads;
    if !reads=2 then Some (Session.Detached) else None | _ -> None);
  check bool "lost receipt after input is uncertain" true (refused (invoke ()));
  check int "receipt failure does not repeat hover" 1
    (List.length (List.filter (function Wire.Page_hover _ -> true | _ -> false) fake.sent))
;;

let test_interactions () =
  let tabs = Executor.Tabs.create () and fake = fake [ shop () ] ~active:(Some "P2") in
  ignore (listed tabs fake);
  let expected_url = Some "http://127.0.0.1:1/shop" in
  let click = Lane.Fill {selector="#name";text="replacement"} in
  fake.sent <- [];
  fake.evaluated <- Some
    (`Assoc
       [ "action", `String "fill"
       ; "urlBefore", `String "http://127.0.0.1:1/shop"
       ; "url", `String "http://127.0.0.1:1/shop"
       ; "title", `String "Shop"
       ; "scrollX", `Int 0
       ; "scrollY", `Int 0
       ]);
  let receipt = served (Executor.execute ~tabs ~call:(call fake) (Lane.Page_interact { tab_id = 0; expected_url; action = click })) in
  (match fake.sent with
   | [ Wire.Page_evaluate { expression; _ } ] ->
     check string "the automation lane's interaction script"
       (Executor.evaluate_expression ~runtime:Executor.Scene_runtime ~body:Masc.Browser_interaction.script
          ~args:(Lane.interaction_args ~tab_id:0 ~expected_url click))
       expression
   | _ -> fail "one page.evaluate");
  check int "the receipt names its tab" 0 Yojson.Safe.Util.(member "tabId" receipt |> to_int);
  fake.evaluated <- Some (`Assoc []);
  check bool "an empty scripted receipt is not success" true
    (refused (Executor.execute ~tabs ~call:(call fake)
       (Lane.Page_interact { tab_id = 0; expected_url; action = click })));
  fake.evaluated <- Some (`Assoc [ "interactionFailure", `Bool true ]);
  check bool "a malformed failure is not success" true
    (refused (Executor.execute ~tabs ~call:(call fake)
       (Lane.Page_interact { tab_id = 0; expected_url; action = click })));
  fake.evaluated <- Some (`Assoc [ "interactionFailure", `Assoc [ "message", `String "no element"; "effectStarted", `Bool false ] ]);
  check bool "a refusal before the click started is before effect" true
    (rejected_before_effect (Executor.execute ~tabs ~call:(call fake) (Lane.Page_interact { tab_id = 0; expected_url; action = click })));
  fake.evaluated <- None;
  fake.sent <- [];
  let clicked =
    served (Executor.execute ~tabs ~call:(call fake)
      (Lane.Page_interact { tab_id = 0; expected_url; action = Lane.Click_at { point; viewport = observed_viewport; button = Lane.Pointer.Primary } }))
  in
  (match List.rev fake.sent with
   | [ Wire.Page_evaluate _; Wire.Page_click { page_id = "P2"; x = 400.; y = 150. }; Wire.Page_evaluate _ ] -> ()
   | sent -> failf "guard, native click at the viewport point, receipt; sent %s"
               (String.concat ", " (List.map Wire.method_name sent)));
  check string "the receipt names the action" "click_at" Yojson.Safe.Util.(member "action" clicked |> to_string);
  fake.evaluated <- Some (`Assoc [ "url", `String "http://127.0.0.1:1/shop"; "title", `Int 1 ]);
  fake.sent <- [];
  check bool "a malformed receipt after native input is refused" true
    (refused (Executor.execute ~tabs ~call:(call fake)
       (Lane.Page_interact { tab_id = 0; expected_url; action = Lane.Click_at { point; viewport = observed_viewport; button = Lane.Pointer.Primary } })));
  check bool "native input was sent before the malformed receipt" true
    (List.exists (function Wire.Page_click _ -> true | _ -> false) fake.sent);
  fake.evaluated <- Some (`Assoc []);
  fake.sent <- [];
  check bool "a malformed guard result is before effect" true
    (rejected_before_effect (Executor.execute ~tabs ~call:(call fake)
       (Lane.Page_interact { tab_id = 0; expected_url; action = Lane.Click_at { point; viewport = observed_viewport; button = Lane.Pointer.Primary } })));
  check bool "a malformed guard never sends native input" true
    (List.for_all (function Wire.Page_click _ -> false | _ -> true) fake.sent);
  fake.evaluated <- None;
  fake.sent <- [];
  fake.failing <- (function Wire.Page_evaluate _ -> Some (Session.Rejected { code = -32603; message = "page_url_changed" }) | _ -> None);
  check bool "a guard that refused is before effect" true
    (rejected_before_effect (Executor.execute ~tabs ~call:(call fake)
       (Lane.Page_interact { tab_id = 0; expected_url; action = Lane.Click_at { point; viewport = observed_viewport; button = Lane.Pointer.Primary } })));
  check bool "and nothing was clicked" true
    (List.for_all (function Wire.Page_click _ -> false | _ -> true) fake.sent)
;;

(* Stagehand 4.1.0 answers an act it could not do as a normal result with
   [data.success = false]; the lane answers it as a failure that may have
   acted, carrying Stagehand's message. *)
let test_act_that_did_not_succeed () =
  let tabs = Executor.Tabs.create () and fake = fake [ blank; shop () ] ~active:(Some "P2") in
  ignore (listed tabs fake);
  let act_answers data request =
    match request with
    | Wire.Act _ -> Ok (`Assoc [ "data", data; "metadata", `Assoc [] ])
    | _ -> call fake request
  in
  let instruct call = Executor.execute ~tabs ~call (Lane.Page_instruct { tab_id = 1; instruction = "click Buy" }) in
  (match instruct (act_answers (`Assoc [ "success", `Bool false; "message", `String "no element matched" ])) with
   | Lane.Refused reason -> check string "Stagehand's message" "Stagehand act did not succeed: no element matched" reason
   | Lane.Answered _ | Lane.Lane_absent | Lane.Timed_out | Lane.Rejected_before_effect _ ->
     fail "an unsuccessful act is refused after its effect");
  check bool "an unsuccessful act without a message" true
    (refused (instruct (act_answers (`Assoc [ "success", `Bool false ]))));
  check bool "an act answer without success" true (refused (instruct (act_answers (`Assoc [ "actions", `List [] ]))));
  check bool "observe has no success flag to read" true
    (match
       Executor.execute ~tabs
         ~call:(fun request ->
           match request with
           | Wire.Observe _ -> Ok (`Assoc [ "data", `List []; "metadata", `Assoc [] ])
           | _ -> call fake request)
         (Lane.Page_locate { tab_id = 1; instruction = None })
     with
     | Lane.Answered _ -> true
     | Lane.Lane_absent | Lane.Timed_out | Lane.Refused _ | Lane.Rejected_before_effect _ -> false)
;;

let test_zoom_requires_extension () =
  let tabs=Executor.Tabs.create () and fake=fake [shop ()] ~active:(Some "P2") in
  ignore (listed tabs fake);fake.sent<-[];
  check bool "owned Chrome refuses browser zoom before native input" true
    (rejected_before_effect (Executor.execute ~tabs ~call:(call fake)
      (Lane.Page_interact {tab_id=0;expected_url=Some "http://127.0.0.1:1/shop";
        action=Lane.Set_zoom {factor=1.5}})));
  check int "unsupported zoom sends no runtime request" 0 (List.length fake.sent)
;;

let test_unserved_verbs () =
  let tabs = Executor.Tabs.create () and fake = fake [ blank ] ~active:None in
  List.iter
    (fun verb ->
      check bool (Lane.verb_to_string verb) true (rejected_before_effect (Executor.execute ~tabs ~call:(call fake) verb)))
    [ Lane.Session_status; Lane.Page_downloads { tab_id = 0 }; Lane.Page_document { tab_id = 0 } ];
  check int "nothing was sent" 0 (List.length fake.sent)
;;

(* A page script's throw reaches the caller by its own reason, not by the
   "Uncaught" Stagehand would word it with. *)
let test_script_throw_keeps_its_reason () =
  let tabs = Executor.Tabs.create () and fake = fake [ shop () ] ~active:(Some "P2") in
  ignore (listed tabs fake);
  fake.script_throws <- Some "scene_document_changed";
  match Executor.execute ~tabs ~call:(call fake) (Lane.Page_capture { tab_id = 0 }) with
  | Lane.Refused reason -> check string "the thrown reason" "scene_document_changed" reason
  | _ -> fail "a throw in the page script is refused with its reason"
;;

let test_native_keyboard_and_double_click () =
  let tabs = Executor.Tabs.create () and fake = fake [shop ()] ~active:(Some "P2") in
  ignore (listed tabs fake);
  let key = match Lane.Keyboard.of_wire ~key:"a" ~modifiers:["Meta"] with
    | Ok key -> key | Error detail -> fail detail in
  let actions = [Lane.Type_text {document_id="d1";text="한글🙂"};
    Lane.Press_key {document_id="d1";key};
    Lane.Double_click_at {point;viewport=observed_viewport}] in
  List.iter (fun action ->
    fake.sent <- [];
    let verb = Lane.Page_interact {tab_id=0;expected_url=Some "https://example.org";action} in
    let result = served (Executor.execute ~tabs ~call:(call fake) verb) in
    check string "receipt retains semantic input action" (Lane.interaction_verb action)
      Yojson.Safe.Util.(result |> member "action" |> to_string);
    (match List.rev fake.sent,action with
     | [Wire.Page_evaluate _;Wire.Page_type {page_id="P2";text="한글🙂"};Wire.Page_evaluate _],Lane.Type_text _
     | [Wire.Page_evaluate _;Wire.Page_key_press {page_id="P2";_};Wire.Page_evaluate _],Lane.Press_key _
     | [Wire.Page_evaluate _;Wire.Page_double_click {page_id="P2";x=400.;y=150.};Wire.Page_evaluate _],Lane.Double_click_at _ -> ()
     | _ -> fail "native input must be guarded, sent once, and followed by a read-only receipt");
    fake.sent <- [];fake.script_throws <- Some "scene_document_changed";
    check bool "guard refusal is before effect" true
      (rejected_before_effect (Executor.execute ~tabs ~call:(call fake) verb));
    check int "guard failure sends no input" 1 (List.length fake.sent);
    fake.sent <- [];fake.script_throws <- None;
    fake.failing <- (function Wire.Page_type _ | Wire.Page_key_press _ | Wire.Page_double_click _ ->
      Some (Session.Lost "input reply missing") | _ -> None);
    check bool "lost input reply preserves uncertainty" true
      (refused (Executor.execute ~tabs ~call:(call fake) verb));
    check int "input is never replayed" 2 (List.length fake.sent);
    fake.failing <- (fun _ -> None)) actions;
  List.iter (fun text ->
    fake.sent <- [];
    check bool "text controls are rejected before native input" true
      (rejected_before_effect (Executor.execute ~tabs ~call:(call fake)
        (Lane.Page_interact {tab_id=0;expected_url=Some "https://example.org";
          action=Lane.Type_text {document_id="d1";text}})));
    check int "rejected text sends no runtime request" 0 (List.length fake.sent)) ["a\tb";"a\nb";"a\rb"];
  let supplementary=match Lane.Keyboard.of_wire ~key:"🙂" ~modifiers:[] with Ok key->key|Error detail->fail detail in
  fake.sent <- [];
  check bool "runtime cannot silently accept an unsupported supplementary key" true
    (rejected_before_effect (Executor.execute ~tabs ~call:(call fake)
      (Lane.Page_interact {tab_id=0;expected_url=Some "https://example.org";
        action=Lane.Press_key {document_id="d1";key=supplementary}})));
  check int "unsupported key never reaches runtime" 0 (List.length fake.sent);
  ignore (served (Executor.execute ~tabs ~call:(call fake)
    (Lane.Page_interact {tab_id=0;expected_url=Some "https://example.org";
      action=Lane.Type_text {document_id="d1";text="\xee\x80\x89"}})));
  check bool "Stagehand PUA remains literal text rather than a modifier chord" true
    (List.exists (function Wire.Page_type {text="\xee\x80\x89";_}->true|_->false) fake.sent)
;;

let test_native_tab_actions () =
  let tabs = Executor.Tabs.create () and fake = fake [blank;shop ()] ~active:(Some "P2") in
  ignore (listed tabs fake);
  let exec action = Executor.execute ~tabs ~call:(call fake) (Lane.Page_act action) in
  let opened = served (exec (Lane.Action.Open_tab "https://example.org/new")) in
  check int "returned new tab is owned by this map" 2 Yojson.Safe.Util.(member "tabId" opened |> to_int);
  check (option string) "new page identity retained" (Some "NEW1") (Executor.Tabs.page_of_id tabs 2);
  check int "native creation sends exactly once" 1 fake.created_count;
  List.iter (fun (interaction,method_) ->
    fake.sent <- [];
    let action = Lane.Action.On_tab {tab_id=2;frame_path=[];interaction} in
    check bool "served subset admitted by Lane" true (Lane.verb_allowed_on_stagehand (Lane.Page_act action));
    ignore (served (exec action));
    check (list string) "one native navigation then summary" [method_;"page.evaluate"]
      (List.rev_map Wire.method_name fake.sent);
    List.iter (fun call -> check bool "native calls never use model" false (Wire.uses_model call)) fake.sent)
    [Lane.Action.Back,"page.go_back";Forward,"page.go_forward";Reload,"page.reload"];
  fake.sent <- [];
  ignore (served (exec (Lane.Action.On_tab {tab_id=2;frame_path=[];interaction=Close_tab})));
  check (option string) "closed identity is retired" None (Executor.Tabs.page_of_id tabs 2);
  check (list string) "close has no synthetic evaluation" ["page.close"] (List.rev_map Wire.method_name fake.sent);
  fake.sent <- [];
  check bool "retired identity cannot navigate another page" true
    (rejected_before_effect (exec (Lane.Action.On_tab {tab_id=2;frame_path=[];interaction=Reload})));
  check int "retired action dispatches nothing" 0 (List.length fake.sent);
  let unknown_close = ref 0 in
  let malformed_close request = match request with
    | Wire.Page_close _ -> incr unknown_close; Ok (`Assoc ["closed",`Bool false])
    | request -> call fake request in
  check bool "unconfirmed close stays unknown" true (refused (Executor.execute ~tabs ~call:malformed_close
    (Lane.Page_act (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Close_tab}))));
  check int "unconfirmed close is never replayed" 1 !unknown_close;
  check (option string) "unconfirmed close retains exact mapping" (Some "P2") (Executor.Tabs.page_of_id tabs 1);
  let second = served (exec (Lane.Action.Open_tab "https://example.org/second")) in
  check int "new page never receives retired tab id" 3 Yojson.Safe.Util.(member "tabId" second |> to_int);
  List.iter (fun action ->
    fake.sent <- [];
    check bool "unsupported/frame action not admitted" false (Lane.verb_allowed_on_stagehand (Lane.Page_act action));
    check bool "direct executor also fails before effect" true (rejected_before_effect (exec action));
    check int "unsupported action makes no runtime call" 0 (List.length fake.sent))
    (Lane.Action.On_tab {tab_id=1;frame_path=["iframe"];interaction=Reload} ::
     List.map (fun interaction -> Lane.Action.On_tab {tab_id=1;frame_path=[];interaction})
       [Click "#x";Fill {selector="#x";text="x"};Press {selector="#x";key=Enter};
        Select {selector="#x";value="x"};Scroll {x=0;y=1};Upload {selector="#x";paths=["x"]};
        Accept_dialog None;Dismiss_dialog]);
  List.iter (fun call ->
    let params = Wire.call_params call in
    let expected = match call with Wire.Context_new_page -> `Assoc [] | _ -> `Assoc ["page_id",`String "P2"] in
    check string "official native parameters" (to_s expected) (to_s params);
    check bool "tab methods never request model" false (Wire.uses_model call);
    check bool "tab methods have no sentence timeout" true (Wire.sentence_timeout_of_call call=None))
    [Wire.Context_new_page;Page_close {page_id="P2"};Page_reload {page_id="P2"};
     Page_go_back {page_id="P2"};Page_go_forward {page_id="P2"}]
;;

let test_created_tab_partial_failure () =
  List.iter (fun failure ->
    let tabs = Executor.Tabs.create () and fake = fake [blank] ~active:(Some "P1") in
    ignore (listed tabs fake);
    fake.sent <- [];
    fake.failing <- (function Wire.Page_goto _ -> Some failure | _ -> None);
    let answer = Executor.execute ~tabs ~call:(call fake)
      (Lane.Page_act (Lane.Action.Open_tab "https://example.org/new")) in
    (match answer with
     | Lane.Answered (`Assoc fields) ->
       check bool "creation then navigation failure is failed" true (List.assoc_opt "ok" fields=Some (`Bool false));
       check bool "confirmed creation is post effect" true (List.assoc_opt "effectPhase" fields=Some (`String "partial"));
       let receipt = List.assoc "data" fields in
       check int "created id retained in failed receipt" 1 Yojson.Safe.Util.(member "tabId" receipt |> to_int);
       check string "created owner lane retained" "stagehand" Yojson.Safe.Util.(member "lane" receipt |> to_string);
       check bool "creation receipt is confirmed" true Yojson.Safe.Util.(member "created" receipt |> to_bool)
     | _ -> fail "expected failed partial receipt");
    check int "navigation failure never re-creates the tab" 1 fake.created_count;
    check (list string) "create then navigate only" ["context.new_page";"page.goto"] (List.rev_map Wire.method_name fake.sent);
    fake.failing <- (fun _ -> None);
    ignore (listed tabs fake);
    ignore (served (Executor.execute ~tabs ~call:(call fake) (Lane.Page_read {tab_id=Some 1;max_chars=None})));
    check int "subsequent observation never recreates" 1 fake.created_count)
    [Session.Rejected {code = -32000;message="navigation rejected"};Session.Lost "unanswered";
     Session.Not_delivered "navigation not written"];
  let tabs = Executor.Tabs.create () and fake = fake [blank] ~active:(Some "P1") in
  ignore (listed tabs fake);
  fake.script_throws <- Some "summary unavailable";
  (match Executor.execute ~tabs ~call:(call fake) (Lane.Page_act (Lane.Action.Open_tab "https://example.org/new")) with
   | Lane.Answered (`Assoc fields) -> check bool "metadata failure retains partial receipt" true
       (List.assoc_opt "effectPhase" fields=Some (`String "partial"))
   | _ -> fail "metadata failure lost created receipt");
  check int "metadata failure also creates once" 1 fake.created_count;
  fake.script_throws <- None;
  fake.evaluated <- Some (`Assoc ["url",`String "chrome-error://chromewebdata/";"title",`String "navigation failed"]);
  (match Executor.execute ~tabs ~call:(call fake) (Lane.Page_act (Lane.Action.Open_tab "https://example.org/failed")) with
   | Lane.Answered (`Assoc fields) -> check bool "native success on browser error page is partial" true
       (List.assoc_opt "ok" fields=Some (`Bool false) && List.assoc_opt "effectPhase" fields=Some (`String "partial"))
   | _ -> fail "browser error page became navigation success");
  fake.evaluated <- None;
  fake.sent <- [];
  fake.failing <- (function Wire.Context_new_page -> Some (Session.Not_delivered "create not written") | _ -> None);
  check bool "unsent create is proven before effect" true (rejected_before_effect
    (Executor.execute ~tabs ~call:(call fake) (Lane.Page_act (Lane.Action.Open_tab "https://example.org/unsent"))));
  check (list string) "unsent create never navigates" ["context.new_page"] (List.rev_map Wire.method_name fake.sent);
  fake.sent <- [];
  fake.failing <- (function Wire.Context_new_page -> Some (Session.Lost "create unanswered") | _ -> None);
  check bool "unanswered create stays unknown without inventing tab identity" true (refused
    (Executor.execute ~tabs ~call:(call fake) (Lane.Page_act (Lane.Action.Open_tab "https://example.org/unknown"))));
  check (list string) "unanswered create never automatically recreates or navigates" ["context.new_page"] (List.rev_map Wire.method_name fake.sent)
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
    "tabs", [
      test_case "pages become tabs with ids that stay" `Quick test_tabs;
      test_case "ids are not given again in a later session" `Quick test_tabs_across_sessions;
    ];
    "tab actions", [test_case "native subset, ownership and closed IDs" `Quick test_native_tab_actions;
      test_case "created tab survives partial failure without replay" `Quick test_created_tab_partial_failure];
    "goto", [
      test_case "navigates a listed or the active tab" `Quick test_goto;
      test_case "a failure after the navigation is not before effect" `Quick test_goto_effect_boundary;
    ];
    "capture", [
      test_case "a capture passes the surface's checks" `Quick test_capture_passes_the_surface;
      test_case "a page that moved during capture is refused" `Quick test_capture_refuses_a_moving_page;
    ];
    ( "sentences",
      [ test_case "each sentence verb sends one Stagehand call" `Quick test_sentence_verbs;
        test_case "an act Stagehand did not carry out is a failure" `Quick test_act_that_did_not_succeed
      ] );
    "reads", [ test_case "reads run the page scripts" `Quick test_reads_run_the_page_scripts ];
    "interactions", [ test_case "native keys/text/double click preserve guard and failure boundaries" `Quick test_native_keyboard_and_double_click;
      test_case "scripts and native pointer input" `Quick test_interactions;
      test_case "hover uses official runtime wire without a model" `Quick test_hover_wire;
      test_case "observed targets resolve into native hover and drag" `Quick test_semantic_pointer_input;
      test_case "hover failure boundaries never replay input" `Quick test_hover_effect_boundary;
      test_case "attributed feedback cannot alter authoritative input" `Quick test_actor_feedback_outcomes ];
    "refusals", [ test_case "browser zoom requires extension" `Quick test_zoom_requires_extension;
      test_case "an unserved verb sends nothing" `Quick test_unserved_verbs ];
    "evaluate", [
      test_case "the expression calls its body" `Quick test_evaluate_expression;
      test_case "a page script's throw keeps its reason" `Quick test_script_throw_keeps_its_reason;
    ];
  ]
;;
