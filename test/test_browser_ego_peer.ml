open Alcotest
module Peer = Masc.Browser_ego_peer
module Live = Masc.Browser_live_peer
module Lane = Browser_lane
let obj xs = `Assoc xs
let str s = `String s

(* What a script handed to the runner says about itself: the step on its
   first line, the arguments and the task space it opens. *)
type sent = { step : string; args : Yojson.Safe.t; space : Yojson.Safe.t; window_s : float }
let after ~prefix line = String.sub line (String.length prefix) (String.length line - String.length prefix)
let sent_of ~window_s script =
  let lines = String.split_on_char '\n' script in
  let find prefix = match List.find_opt (String.starts_with ~prefix) (List.map String.trim lines) with
    | Some line -> after ~prefix line
    | None -> failf "the script has no line starting %S" prefix in
  let trailing text suffix =
    if String.ends_with ~suffix text then String.sub text 0 (String.length text - String.length suffix)
    else failf "%S does not end with %S" text suffix in
  { step = find "// masc-ego: ";
    args = Yojson.Safe.from_string (trailing (find "const args = ") ";");
    space = Yojson.Safe.from_string (trailing (find "const task = await taskSpace(") ");"); window_s }

(* ego writes other lines too, such as its update notice; only the marked line is the answer. *)
let answered value = Ok ("[ego-browser:notice] an update is available\n" ^ Peer.result_marker
  ^ Yojson.Safe.to_string (obj ["ok",`Bool true;"value",value]) ^ "\n")
(* A refusal the script made before acting, and an error the frame caught. *)
let refused error = Ok (Peer.result_marker ^ Yojson.Safe.to_string (obj ["ok",`Bool false;"before",`Bool true;"error",str error]) ^ "\n")
let failed error = Ok (Peer.result_marker ^ Yojson.Safe.to_string (obj ["ok",`Bool false;"error",str error]) ^ "\n")

let field name json = Yojson.Safe.Util.member name json
let text json = Yojson.Safe.Util.to_string json

(* Every directory a case made, removed with what is left in it once the run ends. *)
let created = ref []
let capture_directory () =
  let directory = Filename.temp_dir "masc-ego-peer-" "" in
  created := directory :: !created; directory
let () = at_exit (fun () -> List.iter (fun directory ->
  Array.iter (fun name -> Sys.remove (Filename.concat directory name)) (Sys.readdir directory);
  Sys.rmdir directory) !created)

(* The peer's clock: a runner moves it to stand for the time a run took. *)
let clock = ref 0.
let now () = !clock

let opened ?(capture_directory=capture_directory ()) run =
  let run ~window_s script = let sent = sent_of ~window_s script in
    if sent.step = "space.open" then answered (obj ["spaceId",`Int 51;"ownership",str "agent"]) else run sent in
  match Peer.open_space ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory with
  | Ok peer -> peer
  | Error detail -> failf "the space did not open: %s" detail

let tabs = `List [
  obj ["label",str "p1";"targetId",str "T1";"title",str "Slack";"url",str "https://app.slack.com/";"active",`Bool true];
  obj ["label",`Null;"targetId",str "T9";"title",str "Mail";"url",str "https://mail.example/";"active",`Bool false];
  obj ["label",str "p2";"targetId",str "T2";"title",str "";"url",str "about:blank";"active",`Bool false]]

(* What a page script answers from inside the page: its JSON text, or what it threw. *)
let in_page value = obj ["answer",str (Yojson.Safe.to_string value)]
let page_answer ~label value = answered (obj ["label",str label;"answer",in_page value])

let dispatch peer verb args = Peer.dispatch peer ~verb args
let before_effect name = function
  | Error (Live.Before_effect detail) -> detail
  | Ok _ -> failf "%s was served" name
  | Error (Live.Partial_failure _ | Live.Outcome_unknown _) -> failf "%s failed after an effect" name

let test_version () =
  (match Peer.version_of_output "ego-browser 0.6.0.16\n  chromium 154.0.8037.44\n  node v24.21.0\n" with
   | Ok (version, engine) ->
     check string "ego lite" "0.6.0.16" version; check string "Chromium" "154.0.8037.44" engine
   | Error detail -> fail detail);
  check bool "an answer naming no Chromium is refused" true
    (Result.is_error (Peer.version_of_output "ego-browser 0.6.0.16\n"))

let test_the_space_opens_by_name_and_is_held_by_number () =
  let spaces = ref [] in
  let run ~window_s script = let sent = sent_of ~window_s script in
    spaces := (sent.step, sent.space) :: !spaces;
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"ownership",str "agent"])
    | "tabs.list" -> answered (`List [])
    | "space.finish" -> answered `Null
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  check int "space number" 51 (Peer.space_id peer);
  ignore (dispatch peer Live.Tabs_list (obj []));
  check (result unit string) "finish" (Ok ()) (Peer.finish peer);
  check (list string) "opened by name, then held by number"
    [ "space.open \"masc\""; "tabs.list 51"; "space.finish 51" ]
    (List.rev_map (fun (step, space) -> step ^ " " ^ Yojson.Safe.to_string space) !spaces);
  let user = Peer.open_space ~now ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) ~space:"masc"
      ~run:(fun ~window_s:_ _ -> answered (obj ["spaceId",`Int 7;"ownership",str "user"])) in
  check bool "a space the operator owns is refused" true (Result.is_error user);
  let in_use = Peer.open_space ~now ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) ~space:"masc"
      ~run:(fun ~window_s:_ _ -> failed "EGO_TASK_SPACE_NAME_IN_USE: masc") in
  check (result reject string) "ego's own refusal is kept" (Error "EGO_TASK_SPACE_NAME_IN_USE: masc") (Result.map ignore in_use)

(* A tab that left the listing loses its number: reading it is refused
   before any run, and the bookkeeping does not grow with every listing. *)
let test_a_tab_that_left_the_listing_loses_its_number () =
  let listing = ref tabs and ran = ref [] in
  let peer = opened (fun sent ->
    ran := sent.step :: !ran;
    match sent.step with "tabs.list" -> answered !listing | other -> failf "%s ran a script" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  listing := `List [List.hd (Yojson.Safe.Util.to_list tabs)];
  (match dispatch peer Live.Tabs_list (obj []) with
   | Ok rows -> check int "one tab" 1 (List.length (Yojson.Safe.Util.to_list rows))
   | Error _ -> fail "the second listing failed");
  ran := [];
  List.iter (fun id ->
    check string (Printf.sprintf "tab %d" id) "browser tab is no longer present"
      (before_effect "a tab that left" (dispatch peer Live.Page_read (obj ["tabId",`Int id]))))
    [2; 3];
  check (list string) "no script ran" [] !ran

(* What ego threw reaches the Keeper cut, where a character starts. *)
let test_an_ego_error_is_cut () =
  let long = "JavaScript evaluation failed: Error: Target closed; expression: " ^ String.concat "" (List.init 2000 (fun _ -> "é")) in
  let peer = opened (fun _ -> refused long) in
  let message = before_effect "a long error" (dispatch peer Live.Tabs_list (obj [])) in
  check bool "starts with what failed" true (String.starts_with ~prefix:"JavaScript evaluation failed" message);
  check bool "cut" true (String.length message < 500);
  check bool "on a character boundary" true (String.is_valid_utf_8 message)

let test_tabs_are_numbered_by_label () =
  let peer = opened (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | other -> failf "unexpected step %s" other) in
  let listed () = match dispatch peer Live.Tabs_list (obj []) with
    | Ok rows -> rows | Error _ -> fail "tabs were not listed" in
  let first = listed () in
  check string "rows" ({|[{"id":1,"index":0,"url":"https://app.slack.com/","title":"Slack","active":true},|}
    ^ {|{"id":2,"index":1,"url":"https://mail.example/","title":"Mail","active":false},|}
    ^ {|{"id":3,"index":2,"url":"about:blank","title":"","active":false}]|}) (Yojson.Safe.to_string first);
  check string "the same pages keep their numbers" (Yojson.Safe.to_string first) (Yojson.Safe.to_string (listed ()));
  let unreadable = opened (fun _ -> answered (`List [obj ["label",`Null;"title",str "x";"url",str "y";"active",`Bool true]])) in
  ignore (before_effect "a tab without a label or target" (dispatch unreadable Live.Tabs_list (obj [])))

let test_reads_run_the_shared_page_scripts () =
  let asked = ref [] in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.read" -> page_answer ~label:"p1" (obj ["url",str "https://app.slack.com/";"title",str "Slack";
        "text",str "hello";"chars",`Int 5;"truncated",`Bool false])
    | "page.elements" -> page_answer ~label:"p1" (obj ["url",str "https://app.slack.com/";"title",str "Slack";
        "within",str "#main";"withinMatches",`Int 1;"total",`Int 0;"truncated",`Bool false;"elements",`List []])
    | "page.scene" -> page_answer ~label:"p2" (obj ["url",str "about:blank";"items",`List []])
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  (match dispatch peer Live.Page_read (obj ["tabId",`Int 1;"maxChars",`Int 10]) with
   | Ok page -> check int "tabId" 1 (Yojson.Safe.Util.to_int (field "tabId" page));
     check string "text" "hello" (text (field "text" page))
   | Error _ -> fail "the read failed");
  let read = List.hd !asked in
  check string "by label" "\"p1\"" (Yojson.Safe.to_string (field "label" read.args));
  check string "the cap reaches the page" "10" (text (field "input" read.args));
  check bool "the text script is the shared one" true
    (String_util.contains_substring (text (field "fn" read.args)) Masc.Browser_page_script.text);
  (match dispatch peer Live.Page_elements (obj ["tabId",`Int 1;"within",str "#main"]) with
   | Ok page -> check int "withinMatches" 1 (Yojson.Safe.Util.to_int (field "withinMatches" page))
   | Error _ -> fail "the element read failed");
  check string "within reaches the page" {|{"within":"#main"}|} (text (field "input" (List.hd !asked).args));
  ignore (before_effect "an empty within" (dispatch peer Live.Page_elements (obj ["tabId",`Int 1;"within",str ""])));
  (match dispatch peer Live.Page_scene (obj ["tabId",`Int 3;"maxChars",`Int 100]) with
   | Ok page -> check int "the page of label p2" 3 (Yojson.Safe.Util.to_int (field "tabId" page))
   | Error _ -> fail "the scene read failed");
  check string "the scene reads" {|{"mode":"read","tabId":3,"maxChars":100}|} (text (field "input" (List.hd !asked).args));
  (* No tabId reads the active tab, which the script finds. *)
  ignore (dispatch peer Live.Page_read (obj []));
  check string "the active tab" "null" (Yojson.Safe.to_string (field "label" (List.hd !asked).args))

let test_refusals_run_no_script () =
  let ran = ref [] in
  let peer = opened (fun sent ->
    ran := sent.step :: !ran;
    match sent.step with
    | "tabs.list" -> answered tabs
    | other -> failf "%s ran a script" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  ran := [];
  let operator = before_effect "the operator's tab" (dispatch peer Live.Page_read (obj ["tabId",`Int 2])) in
  check bool "says whose tab it is" true (String_util.contains_substring operator "opened by the operator");
  check string "an unknown tab" "browser tab is no longer present"
    (before_effect "an unknown tab" (dispatch peer Live.Page_capture (obj ["tabId",`Int 40])));
  ignore (before_effect "the document source" (dispatch peer Live.Page_read (obj ["tabId",`Int 1;"includeHtml",`Bool true])));
  ignore (before_effect "a cap past the limit" (dispatch peer Live.Page_read (obj ["tabId",`Int 1;"maxChars",`Int 100_001])));
  List.iter (fun verb -> ignore (before_effect (Live.verb_to_wire verb) (dispatch peer verb (obj ["tabId",`Int 1]))))
    [Live.Page_interact; Live.Page_act; Live.Page_goto];
  check (list string) "no script ran" [] !ran

let test_answers_outside_the_frame () =
  let reply = ref (Ok "") in
  let peer = opened (fun _ -> !reply) in
  let failure output =
    reply := output; before_effect "a broken answer" (dispatch peer Live.Tabs_list (obj [])) in
  check bool "no answer line" true
    (String_util.contains_substring (failure (Ok "Error: top_level_marker\n")) "ended without an answer");
  check bool "two answer lines" true
    (String_util.contains_substring
       (failure (Ok (Peer.result_marker ^ {|{"ok":true,"value":[]}|} ^ "\n" ^ Peer.result_marker ^ {|{"ok":true,"value":[]}|})))
       "more than once");
  check string "exit code" "ego-browser nodejs exited with code 1: ego's nodejs process exited with code 1."
    (failure (Error (Peer.Exited {code=1;output="ego's nodejs process exited with code 1.\n"})));
  check bool "timed out" true
    (String_util.contains_substring (failure (Error Peer.Timed_out)) "did not finish in time");
  check string "ego's refusal" "page p2 was closed" (failure (refused "page p2 was closed"));
  let long = String.concat "" (List.init 300 (fun _ -> "é")) in
  let message = failure (Error (Peer.Exited {code=1;output=long})) in
  check bool "only the end of the output" true (String.length message < 500);
  check bool "cut where a character starts" true (String.is_valid_utf_8 message)

let test_a_page_script_error_is_answered_from_the_page () =
  let peer = opened (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | _ -> answered (obj ["label",str "p1";"answer",obj ["pageError",str "invalid_css_selector"]])) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  check string "what the page threw" "the fixed page script failed in the page: invalid_css_selector"
    (before_effect "a bad selector" (dispatch peer Live.Page_elements (obj ["tabId",`Int 1;"within",str "[["])))

let test_an_answer_past_the_limit_is_refused () =
  let peer = opened (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | _ -> answered (obj ["label",str "p1";"answer",obj ["answer",`Int 3_000_003]])) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  check bool "names the limit" true
    (String_util.contains_substring (before_effect "a large answer" (dispatch peer Live.Page_read (obj ["tabId",`Int 1])))
       "page_answer_exceeds_ego_answer_limit")

let act_args action = Yojson.Safe.Util.member "args" (Lane.verb_json (Lane.Page_act action))
let failure_kind = function
  | Ok _ -> "served"
  | Error (Live.Before_effect _) -> "before effect"
  | Error (Live.Partial_failure _) -> "partial"
  | Error (Live.Outcome_unknown _) -> "unknown"

(* Opening, moving and closing act only on pages an agent opened in the
   space; a refusal the script makes before acting is before any effect, and
   anything after the run started that is not answered is unknown. *)
let test_effects_answer_what_happened () =
  let asked = ref [] in
  let reply = ref (fun (_ : sent) -> fail "no reply set") in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with "tabs.list" -> answered tabs | _ -> !reply sent) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let last () = List.hd !asked in
  let runs () = List.length !asked in
  let opened_page label = answered (obj ["label",str label;"error",`Null;
    "tab",obj ["url",str "https://slack.com/";"title",str "Slack";"active",`Bool true]]) in
  reply := (fun _ -> opened_page "p4");
  (match dispatch peer Live.Page_act (act_args (Lane.Action.Open_tab "https://slack.com/")) with
   | Ok receipt -> check string "the new tab" {|{"tabId":4,"action":"open_tab","created":true,"url":"https://slack.com/","title":"Slack","active":true}|}
       (Yojson.Safe.to_string receipt)
   | Error _ -> fail "open_tab failed");
  check string "the url reaches the script" "https://slack.com/" (text (field "url" (last ()).args));
  let action_window = Lane.reply_timeout_sec (Lane.Page_act (Lane.Action.Open_tab "https://slack.com/")) in
  check bool "open_tab runs within the server's action window" true
    ((last ()).window_s < action_window && (last ()).window_s > Lane.default_timeout_sec);
  reply := (fun _ -> refused "the page budget is reached");
  check string "a page ego would not create" "before effect"
    (failure_kind (dispatch peer Live.Page_act (act_args (Lane.Action.Open_tab "https://slack.com/"))));
  reply := (fun _ -> answered (obj ["label",str "p5";"error",str "page.goto failed: net::ERR_NAME_NOT_RESOLVED";
    "tab",obj ["url",str "https://nowhere.test/";"title",str "";"active",`Bool true]]));
  (match dispatch peer Live.Page_act (act_args (Lane.Action.Open_tab "https://nowhere.test/")) with
   | Error (Live.Partial_failure {tab_id; receipt; message}) ->
     check int "the created tab" 5 tab_id;
     check string "its receipt" {|{"tabId":5,"action":"open_tab","created":true}|} (Yojson.Safe.to_string receipt);
     check bool "says not to open another" true (String_util.contains_substring message "Do not open another tab")
   | other -> failf "a failed load after creation was %s" (failure_kind other));
  reply := (fun _ -> Error Peer.Timed_out);
  (match dispatch peer Live.Page_act (act_args (Lane.Action.Open_tab "https://slack.com/")) with
   | Error (Live.Outcome_unknown detail) ->
     check bool "says to list tabs first" true (String_util.contains_substring detail "list this connection's tabs")
   | other -> failf "a stopped open was %s" (failure_kind other));
  let before = runs () in
  check string "a javascript: URL" "before effect"
    (failure_kind (dispatch peer Live.Page_act (act_args (Lane.Action.Open_tab "javascript:alert(1)"))));
  check string "the operator's tab" "before effect"
    (failure_kind (dispatch peer Live.Page_goto (obj ["tabId",`Int 2;"url",str "https://slack.com/"])));
  check string "a move without a tab" "before effect"
    (failure_kind (dispatch peer Live.Page_goto (obj ["url",str "https://slack.com/"])));
  check string "back is not served" "before effect"
    (failure_kind (dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Back}))));
  check int "none of those ran a script" before (runs ());
  reply := (fun _ -> refused "tab 3 was not opened by an agent in the ego task space");
  check string "a page the space adopted" "before effect"
    (failure_kind (dispatch peer Live.Page_goto (obj ["tabId",`Int 3;"url",str "https://slack.com/"])));
  reply := (fun _ -> answered (obj ["error",`Null;"tab",obj ["url",str "https://slack.com/c";"title",str "Channel"]]));
  (match dispatch peer Live.Page_goto (obj ["tabId",`Int 1;"url",str "https://slack.com/c"]) with
   | Ok receipt -> check string "the move" {|{"tabId":1,"action":"goto","url":"https://slack.com/c","title":"Channel"}|}
       (Yojson.Safe.to_string receipt)
   | Error _ -> fail "goto failed");
  check bool "goto runs within the server's goto window" true
    ((last ()).window_s < Lane.reply_timeout_sec (Lane.Page_goto {url="https://slack.com/c";tab_id=Some 1}));
  reply := (fun _ -> answered (obj ["error",str "page.goto failed: net::ERR_UNSAFE_PORT";
    "tab",obj ["url",str "http://127.0.0.1:9/";"title",str "127.0.0.1"]]));
  (match dispatch peer Live.Page_goto (obj ["tabId",`Int 1;"url",str "http://127.0.0.1:9/"]) with
   | Error (Live.Partial_failure {tab_id; receipt; _}) ->
     check int "the moved tab" 1 tab_id;
     check string "where it is now" {|{"tabId":1,"action":"goto","url":"http://127.0.0.1:9/","title":"127.0.0.1"}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "a failed load was %s" (failure_kind other));
  reply := (fun _ -> failed "Target closed");
  check string "an error the frame caught" "unknown"
    (failure_kind (dispatch peer Live.Page_goto (obj ["tabId",`Int 1;"url",str "https://slack.com/"])));
  reply := (fun _ -> failed "Target closed");
  check string "a close that may have happened" "unknown"
    (failure_kind (dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=3;frame_path=[];interaction=Lane.Action.Close_tab}))));
  reply := (fun _ -> answered (obj ["closed",`Bool true]));
  (match dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=3;frame_path=[];interaction=Lane.Action.Close_tab})) with
   | Ok receipt -> check string "the close" {|{"tabId":3,"action":"close_tab","closed":true}|} (Yojson.Safe.to_string receipt)
   | Error _ -> fail "close failed");
  let before = runs () in
  check string "a closed tab is gone" "browser tab is no longer present"
    (before_effect "a closed tab" (dispatch peer Live.Page_read (obj ["tabId",`Int 3])));
  check int "and its read ran no script" before (runs ())

let viewport : Lane.Pointer.viewport = {document_id="d1"; width=800.; height=600.; scroll_x=0.; scroll_y=0.}
let observed_url = "https://app.slack.com/"
let interact_args ?(tab_id=1) ?(frame_path=[]) action =
  Yojson.Safe.Util.member "args"
    (Lane.verb_json (Lane.Page_interact {tab_id;frame_path;expected_url=Some observed_url;action}))
(* What the guard and the receipt scripts read: the page, its title and scroll. *)
let page_summary = in_page (obj ["url",str observed_url;"title",str "Slack";"scrollX",`Int 0;"scrollY",`Int 0])
let input_answer ?(error=`Null) () = answered (obj ["guard",page_summary;"receipt",page_summary;"error",error])
(* The pointer target script's answer: the URL, a point and the viewport it is in. *)
let resolved = in_page (obj ["url",str observed_url;"point",Lane.Pointer.point_to_json {x=0.25;y=0.5};
  "viewport",Lane.Pointer.viewport_to_json viewport])
let to_int = Yojson.Safe.Util.to_int

(* Input finds its target and checks the page with the page scripts the BiDi
   connection runs; then ego moves the mouse or presses the keys. *)
let test_input_acts_through_the_shared_page_scripts () =
  let asked = ref [] in
  let reply = ref (fun (_ : sent) -> fail "no reply set") in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with "tabs.list" -> answered tabs | _ -> !reply sent) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let runs () = List.length !asked in
  let steps_since before =
    List.rev_map (fun (sent : sent) -> sent.step) (List.filteri (fun index _ -> index < runs () - before) !asked) in
  let last () = List.hd !asked in
  let interact action = dispatch peer Live.Page_interact (interact_args action) in
  let by_step answers = reply := (fun sent -> match List.assoc_opt sent.step answers with
    | Some answer -> answer sent
    | None -> failf "unexpected step %s" sent.step) in
  (* A click: its target is found, and the run that finds it takes five seconds. *)
  by_step ["page.target",(fun _ -> clock := !clock +. 5.; answered resolved); "page.pointer",(fun _ -> input_answer ())];
  let before = runs () in
  (match interact (Lane.Click "#send") with
   | Ok receipt -> check string "the click"
       {|{"tabId":1,"action":"click","urlBefore":"https://app.slack.com/","url":"https://app.slack.com/","title":"Slack","scrollX":0,"scrollY":0}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "the click was %s" (failure_kind other));
  check (list string) "found, then clicked" ["page.target";"page.pointer"] (steps_since before);
  let pointer = last () and target = List.nth !asked 1 in
  check (pair int int) "at the target's point, in CSS pixels" (200, 300) (to_int (field "x" pointer.args), to_int (field "y" pointer.args));
  check string "with the primary button" "left" (text (field "button" pointer.args));
  check int "once" 1 (to_int (field "count" pointer.args));
  check string "on the page by its label" "p1" (text (field "label" pointer.args));
  check string "the guard checks the point that was found" "click_at"
    (text (field "action" (Yojson.Safe.from_string (text (field "input" pointer.args)))));
  check bool "within input's window" true (target.window_s < Lane.default_timeout_sec);
  check (float 1e-9) "the click's two runs share that window" (target.window_s -. 5.) pointer.window_s;
  (* Refused before any input. *)
  by_step ["page.target",(fun _ -> answered (in_page (obj ["interactionFailure",obj ["message",str "element_not_found"]])))];
  let before = runs () in
  check string "a target the page does not have" "element_not_found" (before_effect "a missing target" (interact (Lane.Click "#gone")));
  check (list string) "sends no input" ["page.target"] (steps_since before);
  by_step ["page.target",(fun _ -> answered resolved);"page.pointer",(fun _ -> refused "observed_viewport_changed")];
  check string "a page that moved since it was observed" "observed_viewport_changed"
    (before_effect "a moved page" (interact (Lane.Click "#send")));
  (* After the input was sent. *)
  by_step ["page.target",(fun _ -> answered resolved);"page.pointer",(fun _ -> input_answer ~error:(str "Target closed") ())];
  (match interact (Lane.Click "#send") with
   | Error (Live.Outcome_unknown detail) -> check bool "says to read the tab" true (String_util.contains_substring detail "read tab 1")
   | other -> failf "a failed click was %s" (failure_kind other));
  by_step ["page.target",(fun _ -> answered resolved);"page.pointer",(fun _ -> Error Peer.Timed_out)];
  check string "a stopped click" "unknown" (failure_kind (interact (Lane.Click "#send")));
  (* The other pointer gestures. *)
  by_step ["page.target",(fun _ -> answered resolved);"page.pointer",(fun _ -> input_answer ())];
  let gesture name action =
    (match interact action with Ok _ -> () | other -> failf "%s was %s" name (failure_kind other));
    (last ()).args in
  check bool "a hover presses nothing" true (field "button" (gesture "a hover" (Lane.Hover (Lane.Selector "#menu"))) = `Null);
  check int "a double click clicks twice" 2 (to_int (field "count" (gesture "a double click" (Lane.Double_click (Lane.Selector "#row")))));
  let point = {Lane.Pointer.x=0.5;y=0.25} in
  let before = runs () in
  let right = gesture "a right click" (Lane.Click_at {point;viewport;button=Lane.Pointer.Secondary}) in
  check (list string) "a point needs no target" ["page.pointer"] (steps_since before);
  check string "with the secondary button" "right" (text (field "button" right));
  check (pair int int) "at that point" (400, 150) (to_int (field "x" right), to_int (field "y" right));
  let wheel = gesture "a wheel" (Lane.Scroll_at {point;viewport;x=0;y=120}) in
  check (pair int int) "the wheel's delta" (0, 120) (to_int (field "dx" wheel), to_int (field "dy" wheel));
  (* Keys. *)
  by_step ["page.keyboard",(fun _ -> input_answer ())];
  let keys action = text (field "keys" (gesture "keys" action)) in
  let chord ~key ~modifiers = match Lane.Keyboard.of_wire ~key ~modifiers with Ok chord -> chord | Error detail -> fail detail in
  check string "text is typed as it is" "héllo" (keys (Lane.Type_text {document_id="d1";text="héllo"}));
  check string "a chord in ego's spelling" "Control+Shift+a"
    (keys (Lane.Press_key {document_id="d1";key=chord ~key:"a" ~modifiers:["Control";"Shift"]}));
  check string "a named key" "Enter" (keys (Lane.Press_key {document_id="d1";key=chord ~key:"Enter" ~modifiers:[]}));
  (* The DOM edits. *)
  by_step ["page.input",(fun _ -> answered (in_page (obj ["action",str "fill";"url",str observed_url;"title",str "Slack"])))];
  let fill = Lane.Fill {selector="#message";text="hi"} in
  (match interact fill with
   | Ok receipt -> check string "the fill" {|{"tabId":1,"action":"fill","url":"https://app.slack.com/","title":"Slack"}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "the fill was %s" (failure_kind other));
  let refusal ~started = answered (in_page (obj ["interactionFailure",obj ["message",str "element_not_found";"effectStarted",`Bool started]])) in
  by_step ["page.input",(fun _ -> refusal ~started:false)];
  check string "a refusal the script made first" "element_not_found" (before_effect "a refused fill" (interact fill));
  by_step ["page.input",(fun _ -> refusal ~started:true)];
  check string "a failure after the edit started" "unknown" (failure_kind (interact fill));
  (* Refused before any run. *)
  let before = runs () in
  check string "inside a frame" "before effect"
    (failure_kind (dispatch peer Live.Page_interact (interact_args ~frame_path:["iframe"] (Lane.Click "#send"))));
  check string "the operator's tab" "before effect"
    (failure_kind (dispatch peer Live.Page_interact (interact_args ~tab_id:2 (Lane.Click "#send"))));
  check string "control characters" "before effect" (failure_kind (interact (Lane.Type_text {document_id="d1";text="a\nb"})));
  check string "a key ego cannot press" "before effect"
    (failure_kind (interact (Lane.Press_key {document_id="d1";key=chord ~key:"é" ~modifiers:["Control"]})));
  let elsewhere = {Lane.Pointer.x=0.75;y=0.25} in
  List.iter (fun action ->
    check bool (Lane.interaction_verb action ^ " is not served") true
      (String_util.contains_substring (before_effect "an input ego does not serve" (interact action)) "not served by an ego connection"))
    [Lane.Drag {from=point;to_=elsewhere;viewport;via=[];duration_ms=0};
     Lane.Drag_to {source=Lane.Selector "#a";destination=Lane.Selector "#b";via=[];duration_ms=0};
     Lane.Tap_at {point;viewport}; Lane.Swipe {from=point;to_=elsewhere;viewport;via=[];duration_ms=0};
     Lane.Set_zoom {factor=1.5}; Lane.Set_viewport Lane.Browser_default; Lane.Activate_tab];
  check int "none of those ran a script" before (runs ())

let png = "\137PNG\r\n\026\nfixture"
let state ~url ~width = in_page (obj ["url",str url;"title",str "Slack";
  "viewport",obj ["width",`Int width;"height",`Int 600]])

(* Every script the peer hands to ego parses as the ES module ego runs. *)
let test_the_scripts_parse_as_modules () =
  let scripts = ref [] in
  let directory = capture_directory () in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    scripts := (sent.step, script) :: !scripts;
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"ownership",str "agent"])
    | "tabs.list" -> answered tabs
    | "page.capture" ->
      let path = text (field "path" sent.args) in
      Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel png);
      answered (obj ["label",str "p1";"path",str path;"before",state ~url:"u" ~width:1;"after",state ~url:"u" ~width:1])
    | "space.finish" -> answered `Null
    | "page.target" -> answered resolved
    | "page.pointer" | "page.keyboard" -> input_answer ()
    | "page.input" -> answered (in_page (obj ["action",str "fill"]))
    | "page.open" -> answered (obj ["label",str "p4";"error",`Null;"tab",obj ["url",str "https://example.test/";"title",str "New";"active",`Bool true]])
    | "page.goto" -> answered (obj ["error",`Null;"tab",obj ["url",str "https://example.test/";"title",str "Next"]])
    | "page.close" -> answered (obj ["closed",`Bool true])
    | _ -> page_answer ~label:"p1" (obj ["url",str "u"]) in
  let peer = match Peer.open_space ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:directory with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  List.iter (fun (verb, args) -> ignore (dispatch peer verb args))
    [ Live.Page_read, obj ["tabId",`Int 1];
      Live.Page_elements, obj ["tabId",`Int 1;"within",str "#main"];
      Live.Page_scene, obj ["tabId",`Int 1];
      Live.Page_capture, obj ["tabId",`Int 1];
      Live.Page_act, act_args (Lane.Action.Open_tab "https://example.test/");
      Live.Page_goto, obj ["tabId",`Int 1;"url",str "https://example.test/"];
      Live.Page_interact, interact_args (Lane.Click "#send");
      Live.Page_interact, interact_args (Lane.Hover_at {point={x=0.5;y=0.5};viewport});
      Live.Page_interact, interact_args (Lane.Scroll_at {point={x=0.5;y=0.5};viewport;x=0;y=120});
      Live.Page_interact, interact_args (Lane.Type_text {document_id="d1";text="hi"});
      Live.Page_interact, interact_args (Lane.Fill {selector="#message";text="hi"});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=3;frame_path=[];interaction=Lane.Action.Close_tab}) ];
  check (result unit string) "finish" (Ok ()) (Peer.finish peer);
  check (list string) "every step"
    ["space.open";"tabs.list";"page.read";"page.elements";"page.scene";"page.capture";
     "page.open";"page.goto";"page.target";"page.pointer";"page.pointer";"page.pointer";"page.keyboard";"page.input";
     "page.close";"space.finish"]
    (List.rev_map fst !scripts);
  List.iter (fun (step, script) ->
    let file = Filename.concat directory (step ^ ".mjs") in
    Out_channel.with_open_bin file (fun channel -> Out_channel.output_string channel script);
    let pid = Unix.create_process "node" [|"node";"--check";file|] Unix.stdin Unix.stdout Unix.stderr in
    match Unix.waitpid [] pid with
    | _, Unix.WEXITED 0 -> ()
    | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> failf "the %s script does not parse as a module" step)
    !scripts

let test_capture_reads_and_removes_the_file () =
  let directory = capture_directory () in
  let written = ref [] in
  let shot ?(image=png) ?(after_width=800) () = opened ~capture_directory:directory (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | "page.capture" ->
      let path = text (field "path" sent.args) in
      check string "into the capture directory" directory (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel image);
      written := path :: !written;
      answered (obj ["label",str "p1";"path",str path;
        "before",(state ~url:"https://app.slack.com/" ~width:800);
        "after",(state ~url:"https://app.slack.com/" ~width:after_width)])
    | other -> failf "unexpected step %s" other) in
  let capture peer = ignore (dispatch peer Live.Tabs_list (obj [])); dispatch peer Live.Page_capture (obj ["tabId",`Int 1]) in
  let removed () = List.for_all (fun path -> not (Sys.file_exists path)) !written in
  (match capture (shot ()) with
   | Ok reply ->
     check string "the image" (Base64.encode_string png) (text (field "data" reply));
     check string "mime" "image/png" (text (field "mimeType" reply));
     check int "tabId" 1 (Yojson.Safe.Util.to_int (field "tabId" reply))
   | Error _ -> fail "the capture failed");
  check bool "the file is removed" true (removed ());
  check string "a viewport that moved" "viewport_changed_during_capture"
    (before_effect "a moved viewport" (capture (shot ~after_width:900 ())));
  check bool "removed after a refusal" true (removed ());
  check string "not a PNG" "ego wrote a screenshot that is not a PNG"
    (before_effect "a JPEG" (capture (shot ~image:"\255\216\255" ())));
  check bool "removed after a bad image" true (removed ())

(* Every live capability is either served, or refused before any page
   script, as Browser_lane.live_transport_serves says of ego. *)
let test_the_peer_serves_what_the_lane_table_says () =
  let directory = capture_directory () in
  let peer = opened ~capture_directory:directory (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | "page.capture" ->
      let path = text (field "path" sent.args) in
      Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel png);
      answered (obj ["label",str "p1";"path",str path;
        "before",(state ~url:"https://app.slack.com/" ~width:800);
        "after",(state ~url:"https://app.slack.com/" ~width:800)])
    | "page.read" | "page.elements" | "page.scene" -> page_answer ~label:"p1" (obj ["url",str "https://app.slack.com/"])
    | "page.open" -> answered (obj ["label",str "p4";"error",`Null;"tab",obj ["url",str "https://example.test/new";"title",str "New";"active",`Bool true]])
    | "page.goto" -> answered (obj ["error",`Null;"tab",obj ["url",str "https://example.test/next";"title",str "Next"]])
    | "page.close" -> answered (obj ["closed",`Bool true])
    | "page.target" -> answered resolved
    | "page.pointer" | "page.keyboard" -> input_answer ()
    | "page.input" -> answered (in_page (obj ["action",str "fill"]))
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let viewport : Lane.Pointer.viewport = {document_id="observed"; width=800.; height=600.; scroll_x=0.; scroll_y=0.} in
  let point : Lane.Pointer.point = {x=0.5;y=0.5} in
  let interact action = Lane.Page_interact {tab_id=1; expected_url=Some "https://app.slack.com/"; frame_path=[]; action} in
  let verb_asking_for : Lane.live_capability -> Lane.verb = Lane.(function
    | Tab_listing -> Tabs_list
    | Text_read -> Page_read {tab_id=Some 1; max_chars=None}
    | Document_source -> Page_document {tab_id=1}
    | Element_inventory -> Page_elements {tab_id=Some 1;within=None}
    | Viewport_capture -> Page_capture {tab_id=1}
    | Scene_read -> Page_scene {tab_id=1; max_chars=1000; view=Content; scope=None}
    | Dom_interaction -> interact (Click "#button")
    | Point_click -> interact (Click_at {point;viewport;button=Pointer.Primary})
    | Point_scroll -> interact (Scroll_at {point;viewport;x=0;y=120})
    | Trusted_hover -> interact (Hover_at {point;viewport})
    | Trusted_drag -> interact (Drag {from=point;to_={x=0.75;y=0.5};viewport;via=[];duration_ms=0})
    | Trusted_double_click -> interact (Double_click_at {point;viewport})
    | Trusted_button_click -> interact (Click_at {point;viewport;button=Pointer.Secondary})
    | Viewport_resize -> interact (Set_viewport (Fit {width=800;height=600}))
    | Touch_input -> interact (Swipe {from=point;to_={x=0.75;y=0.5};viewport;via=[];duration_ms=0})
    | Trusted_keyboard -> interact (Type_text {document_id=viewport.document_id;text="hello"})
    | Browser_zoom -> interact (Set_zoom {factor=1.5})
    | Tab_history -> Page_act (Action.On_tab {tab_id=1;frame_path=[];interaction=Action.Back})
    | Tab_closing -> Page_act (Action.On_tab {tab_id=3;frame_path=[];interaction=Action.Close_tab})
    | Tab_navigation -> Page_goto {url="https://example.test/next";tab_id=Some 1}
    | Tab_activation -> interact Activate_tab
    | Tab_creation -> Page_act (Action.Open_tab "https://example.test/new")
    | Dialog_answer -> Page_act (Action.On_tab {tab_id=1;frame_path=[];interaction=Action.Dismiss_dialog})) in
  List.iter (fun capability ->
    let name = Lane.live_capability_to_wire capability in
    let asked = verb_asking_for capability in
    check bool (name ^ " is what its verb asks for") true (Lane.live_capability asked = Some capability);
    let wire = Lane.verb_json asked in
    let verb = match Live.verb_of_wire Yojson.Safe.Util.(wire |> member "verb" |> to_string) with
      | Some verb -> verb
      | None -> failf "the lane put a verb on the wire that the peer does not decode: %s" name in
    let served = Lane.live_transport_serves Lane.Ego_task_space capability in
    match dispatch peer verb (Yojson.Safe.Util.member "args" wire), served with
    | Ok _, true | Error (Live.Before_effect _), false -> ()
    | Ok _, false -> failf "the peer served %s, which the lane table says ego does not" name
    | Error (Live.Before_effect detail), true | Error (Live.Outcome_unknown detail | Live.Partial_failure {message=detail;_}), _ ->
      failf "the peer did not serve %s (%s), which the lane table says ego does" name detail)
    Lane.all_of_live_capability

let () =
  run "browser_ego_peer" [
    "ego", [
      test_case "the version line names ego lite and Chromium" `Quick test_version;
      test_case "the space opens by name and is held by number" `Quick test_the_space_opens_by_name_and_is_held_by_number;
      test_case "tabs are numbered by page label" `Quick test_tabs_are_numbered_by_label;
      test_case "a tab that left the listing loses its number" `Quick test_a_tab_that_left_the_listing_loses_its_number;
      test_case "an ego error is cut" `Quick test_an_ego_error_is_cut;
      test_case "the scripts parse as modules" `Quick test_the_scripts_parse_as_modules;
      test_case "reads run the shared page scripts" `Quick test_reads_run_the_shared_page_scripts;
      test_case "refusals run no script" `Quick test_refusals_run_no_script;
      test_case "answers outside the frame are refused" `Quick test_answers_outside_the_frame;
      test_case "a page script error is answered from the page" `Quick test_a_page_script_error_is_answered_from_the_page;
      test_case "an answer past the limit is refused" `Quick test_an_answer_past_the_limit_is_refused;
      test_case "a capture reads and removes its file" `Quick test_capture_reads_and_removes_the_file;
      test_case "effects answer what happened" `Quick test_effects_answer_what_happened;
      test_case "input acts through the shared page scripts" `Quick test_input_acts_through_the_shared_page_scripts;
      test_case "the peer serves what the lane table says" `Quick test_the_peer_serves_what_the_lane_table_says ] ]
