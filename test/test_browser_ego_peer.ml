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
let contains text part =
  let n = String.length part in
  let rec at i = i + n <= String.length text && (String.sub text i n = part || at (i + 1)) in
  at 0

(* Every directory a case made, removed with what is left in it once the run ends. *)
let created = ref []
let capture_directory () =
  let directory = Filename.temp_dir "masc-ego-peer-" "" in
  created := directory :: !created; directory
let () = at_exit (fun () -> List.iter (fun directory ->
  Array.iter (fun name -> Sys.remove (Filename.concat directory name)) (Sys.readdir directory);
  Sys.rmdir directory) !created)

(* Where the peer saves downloads when a case does not look at them; a
   publication there fails, as without a broker. *)
let no_downloads = {Peer.root = "/nonexistent/masc-ego-downloads"; publish = (fun _ -> Error "no download broker in this case")}

(* The peer's clock: a runner moves it to stand for the time a run took. *)
let clock = ref 0.
let now () = !clock

let opened ?(capture_directory=capture_directory ()) ?(downloads=no_downloads) run =
  let run ~window_s script = let sent = sent_of ~window_s script in
    if sent.step = "space.open" then answered (obj ["spaceId",`Int 51;"ownership",str "agent"]) else run sent in
  match Peer.open_space ~downloads ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory with
  | Ok peer -> peer
  | Error detail -> failf "the space did not open: %s" detail

(* A row as the listing script writes it: [dialog] is what page.info()
   named on a managed page, [dialogUnread] why it could not be read. *)
let tab_row ?(dialog=`Null) ?(unread=`Null) ~label ~target ~title ~url ~active () =
  obj ["label",label;"targetId",str target;"title",str title;"url",str url;"active",`Bool active;
    "dialog",dialog;"dialogUnread",unread]
let tabs = `List [
  tab_row ~label:(str "p1") ~target:"T1" ~title:"Slack" ~url:"https://app.slack.com/" ~active:true ();
  tab_row ~label:`Null ~target:"T9" ~title:"Mail" ~url:"https://mail.example/" ~active:false ();
  tab_row ~label:(str "p2") ~target:"T2" ~title:"" ~url:"about:blank" ~active:false ()]

(* A JavaScript dialog as ego 0.6.0.16's page.info() names it. *)
let ego_dialog ?(default="") kind message = obj ["url",str "https://app.slack.com/";"frameId",str "F1";
  "message",str message;"type",str kind;"hasBrowserHandler",`Bool true;"defaultPrompt",str default]

(* What a page script answers from inside the page: its JSON text, or what it threw. *)
let in_page value = obj ["answer",str (Yojson.Safe.to_string value)]
let page_answer ~label value = answered (obj ["label",str label;"answer",in_page value])

let dispatch ?actor peer verb args = Peer.dispatch ?actor peer ~verb args
let before_effect name = function
  | Error (Live.Before_effect detail) -> detail
  | Ok _ -> failf "%s was served" name
  | Error (Live.Partial_failure _ | Live.Outcome_unknown _) -> failf "%s failed after an effect" name

let test_the_space_opens_by_name_and_is_held_by_number () =
  let spaces = ref [] in
  let run ~window_s script = let sent = sent_of ~window_s script in
    spaces := (sent.step, sent.space) :: !spaces;
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"ownership",str "agent"])
    | "tabs.list" -> answered (`List [])
    | "space.finish" -> answered `Null
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  check int "space number" 51 (Peer.space_id peer);
  ignore (dispatch peer Live.Tabs_list (obj []));
  check (result unit string) "finish" (Ok ()) (Peer.finish peer);
  check (list string) "opened by name, then held by number"
    [ "space.open \"masc\""; "tabs.list 51"; "space.finish 51" ]
    (List.rev_map (fun (step, space) -> step ^ " " ^ Yojson.Safe.to_string space) !spaces);
  let user = Peer.open_space ~downloads:no_downloads ~now ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) ~space:"masc"
      ~run:(fun ~window_s:_ _ -> answered (obj ["spaceId",`Int 7;"ownership",str "user"])) in
  check bool "a space the operator owns is refused" true (Result.is_error user);
  let in_use = Peer.open_space ~downloads:no_downloads ~now ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) ~space:"masc"
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
  ignore (before_effect "an unsupported browser window" (dispatch peer Live.Page_act
    (Lane.Action.to_json (Lane.Action.Open_window "https://example.test/window"))));
  let cookie : Lane.Action.cookie = {name="session";value="fixture";path="/";
    secure=true;http_only=true;same_site=Some Lane.Action.Strict;max_age_sec=None} in
  List.iter (fun interaction -> ignore (before_effect "an unsupported cookie write"
    (dispatch peer Live.Page_act (Lane.Action.to_json
      (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction})))))
    [Lane.Action.Set_cookie cookie;Lane.Action.Delete_cookie "session"];
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
  let emulation : Lane.Action.emulation = {geolocation=None;locale=Some "ko-KR";timezone=None} in
  List.iter (fun interaction -> ignore (before_effect "an unsupported emulation"
    (dispatch peer Live.Page_act (Lane.Action.to_json
      (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction})))))
    [Lane.Action.Set_emulation emulation;Lane.Action.Clear_emulation];
  List.iter (fun interaction -> ignore (before_effect "an unsupported request block"
    (dispatch peer Live.Page_act (Lane.Action.to_json
      (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction})))))
    [Lane.Action.Block_requests ["ads.example.com"];Lane.Action.Unblock_requests];
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
  check string "a request block is not served" "before effect"
    (failure_kind (dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Block_requests ["ads.example"]}))));
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
(* What the DOM input script answers: the shared script's own answer. *)
let dom_answer value = answered (obj ["result",in_page value])
let input_answer ?(error=`Null) ?(released=true) () = answered (obj ["guard",page_summary;"receipt",page_summary;"error",error;"pointerReleased",`Bool released])
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
  (match interact (Lane.Click_node {document_id="d1";node_id="send"}) with
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
  check string "a target the page does not have" "element_not_found" (before_effect "a missing target" (interact (Lane.Click_node {document_id="d1";node_id="gone"})));
  check (list string) "sends no input" ["page.target"] (steps_since before);
  by_step ["page.target",(fun _ -> answered resolved);"page.pointer",(fun _ -> refused "observed_viewport_changed")];
  check string "a page that moved since it was observed" "observed_viewport_changed"
    (before_effect "a moved page" (interact (Lane.Click_node {document_id="d1";node_id="send"})));
  (* After the input was sent. *)
  by_step ["page.target",(fun _ -> answered resolved);"page.pointer",(fun _ -> input_answer ~error:(str "Target closed") ())];
  (match interact (Lane.Click_node {document_id="d1";node_id="send"}) with
   | Error (Live.Outcome_unknown detail) -> check bool "says to read the tab" true (String_util.contains_substring detail "read tab 1")
   | other -> failf "a failed click was %s" (failure_kind other));
  by_step ["page.target",(fun _ -> answered resolved);"page.pointer",(fun _ -> Error Peer.Timed_out)];
  check string "a stopped click" "unknown" (failure_kind (interact (Lane.Click_node {document_id="d1";node_id="send"})));
  (* The other pointer gestures. *)
  by_step ["page.target",(fun _ -> answered resolved);"page.pointer",(fun _ -> input_answer ())];
  let gesture name action =
    (match interact action with Ok _ -> () | other -> failf "%s was %s" name (failure_kind other));
    (last ()).args in
  check bool "a hover presses nothing" true (field "button" (gesture "a hover" (Lane.Hover (Lane.Scene_node {document_id="d1";node_id="menu"}))) = `Null);
  check int "a double click clicks twice" 2 (to_int (field "count" (gesture "a double click" (Lane.Double_click (Lane.Scene_node {document_id="d1";node_id="row"})))));
  let point = {Lane.Pointer.x=0.5;y=0.25} in
  let before = runs () in
  let right = gesture "a right click" (Lane.Click_at {point;viewport;button=Lane.Pointer.Secondary}) in
  check (list string) "a point needs no target" ["page.pointer"] (steps_since before);
  check string "with the secondary button" "right" (text (field "button" right));
  check (pair int int) "at that point" (400, 150) (to_int (field "x" right), to_int (field "y" right));
  let wheel = gesture "a wheel" (Lane.Scroll_at {point;viewport;x=0;y=120}) in
  check (pair int int) "the wheel's delta" (0, 120) (to_int (field "dx" wheel), to_int (field "dy" wheel));
  (* ego shows who acts and what beside its cursor. *)
  check string "an input with no actor is the agent's" "MASC · agent · scroll_at" (text (field "cursor" wheel));
  (match dispatch peer ~actor:"keeper/sangsu" Live.Page_interact (interact_args (Lane.Click_at {point;viewport;button=Lane.Pointer.Primary})) with
   | Ok _ -> check string "an input names its actor" "MASC · keeper/sangsu · click_at" (text (field "cursor" (last ()).args))
   | other -> failf "a click with an actor was %s" (failure_kind other));
  (* Keys. *)
  by_step ["page.keyboard",(fun _ -> input_answer ())];
  let keys action = text (field "keys" (gesture "keys" action)) in
  let chord ~key ~modifiers = match Lane.Keyboard.of_wire ~key ~modifiers with Ok chord -> chord | Error detail -> fail detail in
  check string "text is typed as it is" "héllo" (keys (Lane.Type_text {document_id="d1";text="héllo"}));
  check string "a chord in ego's spelling" "Control+Shift+a"
    (keys (Lane.Press_key {document_id="d1";key=chord ~key:"a" ~modifiers:["Control";"Shift"]}));
  check string "a named key" "Enter" (keys (Lane.Press_key {document_id="d1";key=chord ~key:"Enter" ~modifiers:[]}));
  (* The DOM edits. *)
  by_step ["page.input",(fun _ -> dom_answer (obj ["action",str "fill";"url",str observed_url;"title",str "Slack"]))];
  let fill = Lane.Fill_node {target={document_id="d1";node_id="message"};text="hi"} in
  (match interact fill with
   | Ok receipt -> check string "the fill" {|{"tabId":1,"action":"fill","url":"https://app.slack.com/","title":"Slack"}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "the fill was %s" (failure_kind other));
  let refusal ~started = dom_answer (obj ["interactionFailure",obj ["message",str "element_not_found";"effectStarted",`Bool started]]) in
  by_step ["page.input",(fun _ -> refusal ~started:false)];
  check string "a refusal the script made first" "element_not_found" (before_effect "a refused fill" (interact fill));
  by_step ["page.input",(fun _ -> refusal ~started:true)];
  check string "a failure after the edit started" "unknown" (failure_kind (interact fill));
  (* Refused before any run. *)
  let elsewhere = {Lane.Pointer.x=0.75;y=0.5} in
  let before = runs () in
  check string "inside a frame" "before effect"
    (failure_kind (dispatch peer Live.Page_interact (interact_args ~frame_path:["iframe"] (Lane.Click_node {document_id="d1";node_id="send"}))));
  check string "the operator's tab" "before effect"
    (failure_kind (dispatch peer Live.Page_interact (interact_args ~tab_id:2 (Lane.Click_node {document_id="d1";node_id="send"}))));
  check string "control characters" "before effect" (failure_kind (interact (Lane.Type_text {document_id="d1";text="a\nb"})));
  check string "a key ego cannot press" "before effect"
    (failure_kind (interact (Lane.Press_key {document_id="d1";key=chord ~key:"é" ~modifiers:["Control"]})));
  List.iter (fun action ->
    check bool (Lane.interaction_verb action ^ " is not served") true
      (String_util.contains_substring (before_effect "an input ego does not serve" (interact action)) "not served by an ego connection"))
    [Lane.Tap_at {point;viewport}; Lane.Swipe {from=point;to_=elsewhere;viewport;via=[];duration_ms=0};
     Lane.Set_zoom {factor=1.5}; Lane.Set_viewport Lane.Browser_default; Lane.Activate_tab];
  check int "none of those ran a script" before (runs ())

(* Selector requests must reach ego unchanged, without a MASC target/DOM run.
   The SDK owns matching, scrolling and selection; native errors are uncertain. *)
let test_selector_input_uses_ego_sdk () =
  let asked = ref [] and native_error = ref `Null in
  let peer = opened (fun sent ->
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.target_input" ->
      asked := sent :: !asked;
      let receipt = if field "action" sent.args = str "select_option" then
          obj ["selectedValues",`List [str "b"]] else obj [] in
      answered (obj ["urlBefore",str observed_url;"receipt",receipt;"error",!native_error;
        "tab",obj ["url",str observed_url;"title",str "Slack"]])
    | other -> failf "selector input invoked its own adapter: %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let selector = "loc=role:button[name=\"Send\"]" in
  let actions = [Lane.Click selector; Lane.Fill {selector;text="hello"};
    Lane.Hover (Lane.Selector selector); Lane.Double_click (Lane.Selector selector);
    Lane.Select_option {selector;selection=Lane.Single_option "b"};
    Lane.Select_option {selector;selection=Lane.Multiple_options ["a";"b"]}] in
  List.iter (fun action ->
    match dispatch peer Live.Page_interact (interact_args action) with
    | Ok receipt ->
      let sent = List.hd !asked in
      check string "SDK locator is unchanged" selector (text (field "target" sent.args));
      check string "explicit result identifies the locator" selector (text (field "selector" receipt));
      (match action with
       | Lane.Select_option _ -> check bool "selection is returned" true (field "selectedValues" receipt = `List [str "b"])
       | Lane.Activate_tab | Lane.Click _ | Lane.Fill _ | Lane.Set_zoom _ | Lane.Set_viewport _
       | Lane.Double_click _ | Lane.Double_click_at _ | Lane.Type_text _ | Lane.Press_key _
       | Lane.Scroll _ | Lane.Hover _ | Lane.Drag_to _ | Lane.Hover_at _ | Lane.Tap_at _
       | Lane.Swipe _ | Lane.Click_at _ | Lane.Scroll_at _ | Lane.Drag _ | Lane.Follow_link _
       | Lane.Click_node _ | Lane.Fill_node _ | Lane.Click_target _ | Lane.Fill_target _
       | Lane.Hover_target _ | Lane.Double_click_target _ -> ())
    | other -> failf "native selector was %s" (failure_kind other)) actions;
  check int "one native run per input" (List.length actions) (List.length !asked);
  native_error := str "native input reply lost";
  let before = List.length !asked in
  check string "a native failure is uncertain" "unknown"
    (failure_kind (dispatch peer Live.Page_interact (interact_args (Lane.Click selector))));
  check int "no automatic replay" (before + 1) (List.length !asked)

let test_native_drag_and_release () =
  let sent = ref [] and mode = ref "success" in
  let target = obj ["url",str observed_url;"from",Lane.Pointer.point_to_json {x=0.25;y=0.5};
    "to",Lane.Pointer.point_to_json {x=0.75;y=0.5};"viewport",Lane.Pointer.viewport_to_json viewport] in
  let peer = opened (fun request ->
    sent := request :: !sent;
    match request.step with
    | "tabs.list" -> answered tabs
    | "page.target" -> answered (in_page target)
    | "page.drag" ->
      (match !mode with
       | "refused" -> refused "observed_viewport_changed"
       | "unknown" -> Error Peer.Timed_out
       | "release_failed" -> input_answer ~released:false ~error:(str "up failed") ()
       | _ -> input_answer ())
    | "page.pointer" -> input_answer ()
    | "page.read" -> page_answer ~label:"p1" (obj ["text",str "still readable"])
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let drag duration_ms = Lane.Drag_to {source=Lane.Selector "#source";destination=Lane.Selector "#destination";
    via=[{Lane.Pointer.x=0.5;y=0.25}];duration_ms} in
  let invoke action = dispatch peer Live.Page_interact (interact_args action) in
  check string "native drag succeeds" "served" (failure_kind (invoke (drag 0)));
  let last = List.hd !sent in
  check string "native API step" "page.drag" last.step;
  check bool "observed path is converted once to CSS pixels" true
    (field "path" last.args = `List [obj ["x",`Int 200;"y",`Int 300];
      obj ["x",`Int 400;"y",`Int 150];obj ["x",`Int 600;"y",`Int 300];
      obj ["x",`Int 600;"y",`Int 300]]);
  let count = List.length !sent in
  check string "timed movement is not emulated" "before effect" (failure_kind (invoke (drag 100)));
  check int "no script for unsupported timing" count (List.length !sent);
  mode := "refused";
  check string "guard rejects before input" "before effect" (failure_kind (invoke (drag 0)));
  mode := "success";
  check string "guard refusal leaves input usable" "served" (failure_kind (invoke (drag 0)));
  mode := "release_failed";
  check string "failed release is unknown" "unknown" (failure_kind (invoke (drag 0)));
  let count = List.length !sent in
  check string "no further input after unconfirmed release" "before effect"
    (failure_kind (invoke (Lane.Click "#next")));
  check int "blocked input is not run" count (List.length !sent);
  check string "reads remain available" "served"
    (failure_kind (dispatch peer Live.Page_read (obj ["tabId",`Int 1])))

let png = "\137PNG\r\n\026\nfixture"
let state ~url ~width = in_page (obj ["url",str url;"title",str "Slack";
  "viewport",obj ["width",`Int width;"height",`Int 600]])

(* Every script the peer hands to ego parses as the ES module ego runs. *)
let test_the_scripts_parse_as_modules () =
  let scripts = ref [] in
  let directory = capture_directory () in
  let upload_file = Filename.concat directory "note.txt" in
  Out_channel.with_open_bin upload_file (fun channel -> Out_channel.output_string channel "hello");
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
    | "page.pointer" | "page.keyboard" | "page.drag" -> input_answer ()
    | "page.input" -> dom_answer (obj ["action",str "fill"])
    | "page.open" -> answered (obj ["label",str "p4";"error",`Null;"tab",obj ["url",str "https://example.test/";"title",str "New";"active",`Bool true]])
    | "page.goto" -> answered (obj ["error",`Null;"tab",obj ["url",str "https://example.test/";"title",str "Next"]])
    | "page.close" -> answered (obj ["closed",`Bool true])
    | "page.reload" | "page.history" -> answered (obj ["error",`Null;"tab",obj ["url",str "https://example.test/";"title",str "Back"]])
    | "page.snapshot" -> answered (obj ["label",str "p1";"url",str "u";"title",str "T";"snapshot",str "root";"truncated",`Bool false;"chars",`Int 4])
    | "page.dialog" -> answered (obj ["dialog",ego_dialog ~default:"def" "prompt" "name?"])
    | "page.target_input" -> answered (obj ["urlBefore",str observed_url;"receipt",obj [];"error",`Null;
        "tab",obj ["url",str observed_url;"title",str "Slack"]])
    | "page.downloads" -> answered (obj ["since",`Null;"rows",`List []])
    | "page.upload" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null;"after",in_page (obj ["files",`List []])])
    | "page.choose_files" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null])
    | _ -> page_answer ~label:"p1" (obj ["url",str "u"]) in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:directory with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  List.iter (fun (verb, args) -> ignore (dispatch peer verb args))
    [ Live.Page_read, obj ["tabId",`Int 1];
      Live.Page_elements, obj ["tabId",`Int 1;"within",str "#main"];
      Live.Page_scene, obj ["tabId",`Int 1];
      Live.Page_snapshot, obj ["tabId",`Int 1;"maxChars",`Int 1000;"scope",str "subtree";"root",str "@12"];
      Live.Page_downloads, obj ["tabId",`Int 1];
      Live.Page_capture, obj ["tabId",`Int 1];
      Live.Page_act, act_args (Lane.Action.Open_tab "https://example.test/");
      Live.Page_goto, obj ["tabId",`Int 1;"url",str "https://example.test/"];
      Live.Page_interact, interact_args (Lane.Click_node {document_id="d1";node_id="send"});
      Live.Page_interact, interact_args (Lane.Hover_at {point={x=0.5;y=0.5};viewport});
      Live.Page_interact, interact_args (Lane.Scroll_at {point={x=0.5;y=0.5};viewport;x=0;y=120});
      Live.Page_interact, interact_args (Lane.Type_text {document_id="d1";text="hi"});
      Live.Page_interact, interact_args (Lane.Drag {from={x=0.25;y=0.5};to_={x=0.75;y=0.5};viewport;via=[];duration_ms=0});
      Live.Page_interact, interact_args (Lane.Fill_node {target={document_id="d1";node_id="message"};text="hi"});
      Live.Page_interact, interact_args (Lane.Fill_target {target=Lane.Target_ref 5;text="hi"});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=3;frame_path=[];interaction=Lane.Action.Close_tab});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Reload});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Back});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Accept_dialog (Some "hi")});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Dismiss_dialog});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.File_input "#file";paths=[upload_file]}});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.Chooser_opener "#attach";paths=[upload_file]}}) ];
  check (result unit string) "finish" (Ok ()) (Peer.finish peer);
  check (list string) "every step"
    ["space.open";"tabs.list";"page.read";"page.elements";"page.scene";"page.snapshot";"page.downloads";"page.capture";
     "page.open";"page.goto";"page.target";"page.pointer";"page.pointer";"page.pointer";"page.keyboard";"page.drag";"page.input";"page.target_input";
     "page.close";"page.reload";"page.history";"page.dialog";"page.dialog";"page.upload";"page.choose_files";"space.finish"]
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
  let upload_file = Filename.concat directory "note.txt" in
  Out_channel.with_open_bin upload_file (fun channel -> Out_channel.output_string channel "hello");
  let peer = opened ~capture_directory:directory (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | "page.capture" ->
      let path = text (field "path" sent.args) in
      Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel png);
      answered (obj ["label",str "p1";"path",str path;
        "before",(state ~url:"https://app.slack.com/" ~width:800);
        "after",(state ~url:"https://app.slack.com/" ~width:800)])
    | "page.read" | "page.elements" | "page.scene" -> page_answer ~label:"p1" (obj ["url",str "https://app.slack.com/"])
    | "page.snapshot" -> answered (obj ["label",str "p1";"url",str "https://app.slack.com/";"title",str "Slack";
        "snapshot",str "root";"truncated",`Bool false;"chars",`Int 4])
    | "page.target_input" -> answered (obj ["urlBefore",str "https://app.slack.com/";"receipt",obj [];"error",`Null;
        "tab",obj ["url",str "https://app.slack.com/";"title",str "Slack"]])
    | "page.open" -> answered (obj ["label",str "p4";"error",`Null;"tab",obj ["url",str "https://example.test/new";"title",str "New";"active",`Bool true]])
    | "page.goto" | "page.history" -> answered (obj ["error",`Null;"tab",obj ["url",str "https://example.test/next";"title",str "Next"]])
    | "page.close" -> answered (obj ["closed",`Bool true])
    | "page.dialog" -> answered (obj ["dialog",ego_dialog "alert" "hello"])
    | "space.hand_off" -> answered `Null
    | "page.downloads" -> answered (obj ["since",`Null;"rows",`List []])
    | "page.upload" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null;
        "after",in_page (obj ["url",str "https://app.slack.com/";"title",str "Slack";"files",`List []])])
    | "page.target" -> answered resolved
    | "page.pointer" | "page.keyboard" | "page.drag" -> input_answer ()
    | "page.input" -> dom_answer (obj ["action",str "fill"])
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let viewport : Lane.Pointer.viewport = {document_id="observed"; width=800.; height=600.; scroll_x=0.; scroll_y=0.} in
  let point : Lane.Pointer.point = {x=0.5;y=0.5} in
  let interact action = Lane.Page_interact {tab_id=1; expected_url=Some "https://app.slack.com/"; frame_path=[]; action} in
  let verb_asking_for : Lane.live_capability -> Lane.verb = Lane.(function
    | Tab_listing -> Tabs_list
    | Text_read -> Page_read {tab_id=Some 1; max_chars=None}
    | Document_source -> Page_document {tab_id=1}
    | Element_inventory -> Page_elements {tab_id=Some 1;filter={within=None;selector=None}}
    | Viewport_capture -> Page_capture {tab_id=1}
    | Scene_read -> Page_scene {tab_id=1; max_chars=1000; view=Content; scope=None}
    | Accessibility_snapshot -> Page_snapshot {tab_id=1; max_chars=1000; scope=Snapshot_viewport}
    | Snapshot_target_input -> interact (Click_target (Target_ref 12))
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
    | Dialog_answer -> Page_act (Action.On_tab {tab_id=1;frame_path=[];interaction=Action.Dismiss_dialog})
    | Frame_read -> Page_context {tab_id=1;frame_path=[];mode=`Frames}
    | Operator_handoff -> Page_act (Action.Control Action.Hand_off)
    | Download_listing -> Page_downloads {tab_id=1}
    | File_upload -> Page_act (Action.On_tab {tab_id=1;frame_path=[];interaction=Action.Upload {target=Action.File_input "#file";paths=[upload_file]}})) in
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

(* The history scripts run in node against a stand-in for ego: one agent page
   whose history holds a.test then b.test. A move to an entry lands a little
   after the CDP call returns, as a navigation commits later; with [detaches]
   the first history read after it fails, as ego's did while the page changed
   renderer. With [same_url] both entries have one URL, as a pushState to the
   same address makes; [load] is what the load wait does after it notes the
   call. The stand-in prints the CDP calls and waits the script made. *)
let stand_in ~current ~navigation ~detaches ~same_url ~load = Printf.sprintf {js|
const entries = [{id: 11, url: "https://a.test/", title: "A"}, {id: 12, url: "%s", title: "B"}];
let current = %d;
let detached = false;
const seen = [];
process.on("exit", () => console.log("seen " + JSON.stringify(seen)));
const page = {
  cdp: async (method, params) => {
    seen.push(method);
    if (method === "Page.getNavigationHistory" && detached) { detached = false; seen.push("detached"); throw new Error("Not attached to an active page"); }
    if (method === "Page.getNavigationHistory") return {currentIndex: current, entries};
    if (method !== "Page.navigateToHistoryEntry") throw new Error("unexpected " + method);
    %s
    const index = entries.findIndex(entry => entry.id === params.entryId);
    setTimeout(() => { current = index; }, 20);
    detached = %b;
    return {};
  },
  reload: async () => { seen.push("reload"); },
  info: async () => ({url: entries[current].url, title: entries[current].title, w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600}),
  waitForTimeout: ms => new Promise(resolve => setTimeout(resolve, ms)),
  waitForLoadState: async () => { seen.push("load at " + current); %s },
};
const taskSpace = async () => ({
  ownership: "agent",
  tabs: async () => [{label: "p1", openedBy: "agent", url: entries[current].url, title: entries[current].title}],
  page: () => page,
});
|js} (if same_url then "https://a.test/" else "https://b.test/") current navigation detaches load

let in_node script =
  let directory = capture_directory () in
  let file = Filename.concat directory "step.mjs" and out = Filename.concat directory "out.txt" in
  Out_channel.with_open_bin file (fun channel -> Out_channel.output_string channel script);
  let fd = Unix.openfile out [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let pid = Unix.create_process "node" [|"node";file|] Unix.stdin fd Unix.stderr in
  Unix.close fd;
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED 0 -> In_channel.with_open_bin out In_channel.input_all
  | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> fail "node did not run the step"

(* The snapshot script runs in node against a stand-in for ego whose one agent
   page answers [text]; it prints the options each snapshot call got. *)
let snapshot_stand_in text = Printf.sprintf {js|
const seen = [];
process.on("exit", () => console.log("seen " + JSON.stringify(seen)));
const page = {
  snapshot: async options => { seen.push(options === undefined ? "no options" : options); return %s; },
  url: async () => "https://app.slack.com/",
  title: async () => "Slack",
  info: async () => ({url: "https://app.slack.com/", title: "Slack", w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600}),
};
const taskSpace = async () => ({
  ownership: "agent",
  tabs: async () => [{label: "p1", url: "https://app.slack.com/", title: "Slack", active: true}],
  page: () => page,
});
|js} (Yojson.Safe.to_string (`String text))

let test_a_snapshot_reads_egos_own_tree () =
  let text = ref "" and asked = ref [] and output = ref "" in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"ownership",str "agent"])
    | "tabs.list" -> answered tabs
    | "page.snapshot" ->
      asked := sent :: !asked;
      output := in_node (snapshot_stand_in !text ^ script);
      Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let snapshot ?(tab_id=1) ?(max_chars=1000) scope =
    dispatch peer Live.Page_snapshot
      (Yojson.Safe.Util.member "args" (Lane.verb_json (Lane.Page_snapshot {tab_id;max_chars;scope}))) in
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.to_string (Yojson.Safe.from_string (after ~prefix:"seen " line))
    | None -> fail "the stand-in did not say what it saw" in
  let expected ~scope ~snapshot ~truncated ~chars = Yojson.Safe.to_string (obj (
    ["tabId",`Int 1;"url",str "https://app.slack.com/";"title",str "Slack"] @ scope
    @ ["snapshot",str snapshot;"truncated",`Bool truncated;"chars",`Int chars])) in
  let answer label = function
    | Ok answer -> Yojson.Safe.to_string answer
    | other -> failf "%s was %s" label (failure_kind other) in
  text := "root\n  button \"Send\" [ref=12]";
  check string "the viewport is ego's own tree, whole"
    (expected ~scope:["scope",str "viewport"] ~snapshot:!text ~truncated:false ~chars:(String.length !text))
    (answer "viewport" (snapshot Lane.Snapshot_viewport));
  check string "a viewport snapshot passes no options" {|["no options"]|} (seen ());
  check bool "it runs within the read window" true ((List.hd !asked).window_s
    < Lane.reply_timeout_sec (Lane.Page_snapshot {tab_id=1;max_chars=1000;scope=Lane.Snapshot_viewport}));
  check string "the subtree answer names its root"
    (expected ~scope:["scope",str "subtree";"root",str "@12"] ~snapshot:!text ~truncated:false ~chars:(String.length !text))
    (answer "subtree" (snapshot (Lane.Snapshot_subtree 12)));
  check string "and ego is asked for that subtree" {|[{"scope":"subtree","root":"@12"}]|} (seen ());
  ignore (answer "full page" (snapshot Lane.Snapshot_full_page));
  check string "a full page snapshot asks for the whole page" {|[{"scope":"full_page"}]|} (seen ());
  (* "ab", one emoji (two UTF-16 units), "cd": six units. *)
  text := "ab\xF0\x9F\x98\x80cd";
  check string "a cut never splits a surrogate pair"
    (expected ~scope:["scope",str "viewport"] ~snapshot:"ab" ~truncated:true ~chars:6)
    (answer "cut" (snapshot ~max_chars:3 Lane.Snapshot_viewport));
  check string "a cut after the pair keeps it"
    (expected ~scope:["scope",str "viewport"] ~snapshot:"ab\xF0\x9F\x98\x80" ~truncated:true ~chars:6)
    (answer "cut" (snapshot ~max_chars:4 Lane.Snapshot_viewport));
  let runs = List.length !asked in
  let refused label result = match result with
    | Error (Live.Before_effect detail) -> detail
    | other -> failf "%s was %s" label (failure_kind other) in
  check bool "an operator tab is refused" true
    (contains (refused "operator tab" (snapshot ~tab_id:2 Lane.Snapshot_viewport)) "opened by the operator");
  ignore (refused "no tab" (dispatch peer Live.Page_snapshot (obj ["maxChars",`Int 10;"scope",str "viewport"])));
  check bool "a root that is not a ref is refused" true
    (contains (refused "root" (dispatch peer Live.Page_snapshot
       (obj ["tabId",`Int 1;"maxChars",`Int 10;"scope",str "subtree";"root",str "12"]))) "ref");
  check int "and none of them ran a script" runs (List.length !asked)

(* The target script runs in node against a stand-in for ego's agent page at
   [url]. [act] is what its native Page method answers; with an open dialog the page answers no URL read, as ego's
   does. The stand-in prints the calls the script made and the cursor label
   each click carried; ego's fill takes no options. *)
let target_stand_in ~url ~blocked ~act = Printf.sprintf {js|
const seen = [];
const labels = [];
let currentUrl = %s;
let dialogOpen = %b;
process.on("exit", () => { console.log("seen " + JSON.stringify(seen)); console.log("labels " + JSON.stringify(labels)); });
const page = {
  info: async () => { seen.push("info"); return dialogOpen ? {url: currentUrl, dialog: {type: "alert", message: "Hold on", defaultPrompt: ""}} : {url: currentUrl}; },
  url: async () => { seen.push("url"); if (dialogOpen) throw new Error("PageDialogOpenedError: Runtime.evaluate cannot run while a JavaScript alert dialog is open"); return currentUrl; },
  click: async (target, options) => { seen.push("click " + target); labels.push(options === undefined ? null : options.label); %s },
  fill: async (target, text, options) => { seen.push("fill " + target + " " + text + (options === undefined ? "" : " with options")); %s },
  hover: async target => { seen.push("hover " + target); %s },
  dblclick: async target => { seen.push("double_click " + target); %s },
};
const taskSpace = async () => ({
  ownership: "agent",
  tabs: async () => [{label: "p1", openedBy: "agent", url: currentUrl, title: "Slack"}],
  page: () => page,
});
|js} (Yojson.Safe.to_string (`String url)) blocked act act act act

let test_a_snapshot_target_is_found_by_ego_and_checked_first () =
  let url = ref observed_url and blocked = ref false and act = ref "return {};" in
  let asked = ref [] and output = ref "" in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"ownership",str "agent"])
    | "tabs.list" -> answered tabs
    | "page.target_input" ->
      asked := sent :: !asked;
      output := in_node (target_stand_in ~url:!url ~blocked:!blocked ~act:!act ^ script);
      Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let printed prefix = match List.find_opt (String.starts_with ~prefix) (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.to_string (Yojson.Safe.from_string (after ~prefix line))
    | None -> fail "the stand-in did not say what it saw" in
  let seen () = printed "seen " in
  let on ?actor action = dispatch ?actor peer Live.Page_interact (interact_args action) in
  let answer label = function
    | Ok answer -> Yojson.Safe.to_string answer
    | other -> failf "%s was %s" label (failure_kind other) in
  let click target = on (Lane.Click_target target) in
  check string "a ref is clicked by ego once it names one element"
    (Yojson.Safe.to_string (obj ["tabId",`Int 1;"action",str "click";"target",obj ["ref",`Int 12];
      "urlBefore",str observed_url;"url",str observed_url;"title",str "Slack"]))
    (answer "ref click" (click (Lane.Target_ref 12)));
  check string "the dialog and URL checks come before native input" {|["info","url","click @12"]|} (seen ());
  check string "ego's click carries the cursor label" {|["MASC · agent · click"]|} (printed "labels ");
  ignore (answer "named click" (on ~actor:"keeper/sangsu" (Lane.Click_target (Lane.Target_ref 12))));
  check string "and names the actor" {|["MASC · keeper/sangsu · click"]|} (printed "labels ");
  ignore (answer "role" (click (Lane.Target_role {role="button";name="Say \"hi\"";exact=true})));
  check string "a role target is ego's role locator with a JSON name"
    {|["info","url","click loc=role:button[name=\"Say \\\"hi\\\"\"]"]|} (seen ());
  ignore (answer "part of a name" (click (Lane.Target_role {role="link";name="Docs";exact=false})));
  check bool "a part of a name is name*=" true (contains (seen ()) {|loc=role:link[name*=\"Docs\"]|});
  ignore (answer "text" (click (Lane.Target_text {text="Send";exact=false})));
  check bool "part of a text is unquoted" true (contains (seen ()) "click text=Send");
  ignore (answer "exact text" (click (Lane.Target_text {text="Send now";exact=true})));
  check bool "an exact text is ego's quoted text" true (contains (seen ()) {|click text=\"Send now\"|});
  ignore (answer "fill" (on (Lane.Fill_target {target=Lane.Target_ref 5;text="Ada"})));
  check string "a fill gives ego its text and no label, which ego's fill refuses" {|["info","url","fill @5 Ada"]|} (seen ());
  ignore (answer "hover" (on (Lane.Hover_target (Lane.Target_ref 12))));
  check string "hover uses ego's element resolver and native input"
    {|["info","url","hover @12"]|} (seen ());
  ignore (answer "double-click" (on (Lane.Double_click_target (Lane.Target_ref 12))));
  check string "double-click uses ego's element resolver and native input"
    {|["info","url","double_click @12"]|} (seen ());
  act := {|return {popups: [{label: "p7", targetId: "T7"}]};|};
  check bool "an opened page is answered with its tab number" true
    (contains (answer "popup" (click (Lane.Target_ref 4))) {|"popups":[{"tabId":4,"label":"p7"}]|});
  act := {|dialogOpen = true; return {dialog: {url: "u", frameId: "F", type: "prompt", message: "Name?", hasBrowserHandler: true, defaultPrompt: "Ada"}};|};
  let with_dialog = answer "dialog" (click (Lane.Target_ref 3)) in
  check bool "a raised dialog is answered in the surface's shape" true
    (contains with_dialog {|"dialog":{"type":"prompt","message":"Name?","defaultValue":"Ada"}|});
  check bool "and the tab's row still says where the page is" true
    (contains with_dialog (Printf.sprintf {|"url":%S|} observed_url));
  check string "the page itself is not read after the dialog" {|["info","url","click @3"]|} (seen ());
  act := "return {};";
  let runs = List.length !asked in
  let refused label result = match result with
    | Error (Live.Before_effect detail) -> detail
    | other -> failf "%s was %s" label (failure_kind other) in
  blocked := true;
  check bool "a page blocked on a dialog is refused before any effect" true
    (contains (refused "blocked page" (click (Lane.Target_ref 12))) "blocked on a JavaScript dialog");
  check string "and ego is asked only whether a dialog is open" {|["info"]|} (seen ());
  blocked := false;
  url := "https://app.slack.com/other";
  check bool "a page at another URL is refused before any effect" true
    (contains (refused "moved page" (click (Lane.Target_ref 12))) "not at expectedUrl");
  check bool "and ego is not asked to find the target" false (contains (seen ()) "wait");
  url := observed_url;
  act := {|throw new Error('Locator text="A" matched 2 elements');|};
  (match click (Lane.Target_text {text="A";exact=true}) with
   | Error (Live.Outcome_unknown detail) -> check bool "native ambiguity is uncertain" true (contains detail "matched 2 elements")
   | other -> failf "native ambiguity was %s" (failure_kind other));
  act := {|throw new Error("Target closed");|};
  (match click (Lane.Target_ref 12) with
   | Error (Live.Outcome_unknown detail) -> check bool "a failed click is unknown and asks for a read" true (contains detail "read tab 1")
   | other -> failf "a failed click was %s" (failure_kind other));
  check int "each of them was one run" (runs + 4) (List.length !asked);
  let before = List.length !asked in
  check bool "an operator tab is refused without a run" true
    (match dispatch peer Live.Page_interact (interact_args ~tab_id:2 (Lane.Click_target (Lane.Target_ref 1))) with
     | Error (Live.Before_effect _) -> true | Ok _ | Error (Live.Partial_failure _ | Live.Outcome_unknown _) -> false);
  check int "no script ran for it" before (List.length !asked)

(* A stand-in for ego's hand-off: a space whose owner the case sets, and
   handOff, takeOverTaskSpace and the space's tab list that record each call. *)
let control_stand_in ~ownership ~user_page = Printf.sprintf {js|
const seen = [];
process.on("exit", () => console.log("seen " + JSON.stringify(seen)));
const taskSpace = async space => ({
  spaceId: space,
  ownership: %s,
  tabs: async () => { seen.push("tabs"); return [{label: "p1", openedBy: "agent", url: "https://app.slack.com/", title: "Slack", active: true}]; },
  page: () => ({info: async () => ({url: "https://app.slack.com/"})}),
  handOff: async () => { seen.push("handOff"); },
});
const takeOverTaskSpace = async id => { seen.push("takeOver " + id); return {ownership: "agent", userPage: () => %s}; };
|js} (Yojson.Safe.to_string (str ownership)) user_page

let test_the_space_goes_to_the_operator_and_back () =
  let ownership = ref "agent" and user_page = ref {|({label: "p2"})|} and output = ref "" in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"ownership",str !ownership])
    | _ -> output := in_node (control_stand_in ~ownership:!ownership ~user_page:!user_page ^ script); Ok !output in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> after ~prefix:"seen " line
    | None -> fail "the stand-in did not say what it saw" in
  let act control = dispatch peer Live.Page_act (Lane.Action.to_json (Lane.Action.Control control)) in
  let answer label = function
    | Ok answer -> Yojson.Safe.to_string answer
    | other -> failf "%s was %s" label (failure_kind other) in
  check string "the space is handed to the operator" {|{"action":"hand_off"}|} (answer "hand-off" (act Lane.Action.Hand_off));
  check string "by ego's own handOff" {|["handOff"]|} (seen ());
  ownership := "agentDelegatedToUser";
  check bool "while the operator holds it, a step is refused before any effect" true
    (contains (before_effect "a listing" (dispatch peer Live.Tabs_list (obj []))) "the operator holds this ego task space");
  check string "and nothing in the space is called" "[]" (seen ());
  check bool "a second hand-off is refused the same way, with ego's owner" true
    (contains (before_effect "a second hand-off" (act Lane.Action.Hand_off)) "ego ownership: agentDelegatedToUser");
  check string "taking it back names the tab that was active" {|{"action":"take_over","activeTabId":1}|}
    (answer "take-over" (act Lane.Action.Take_over));
  check string "by ego's takeOverTaskSpace on this space" {|["takeOver 51"]|} (seen ());
  user_page := "({})";
  check string "a tab the operator opened is not numbered" {|{"action":"take_over"}|}
    (answer "take-over onto an operator tab" (act Lane.Action.Take_over));
  ownership := "agent";
  check bool "with the agent holding the space, a take-over is refused before any effect" true
    (contains (before_effect "a needless take-over" (act Lane.Action.Take_over)) "already holds");
  check string "and ego is not asked to take it" "[]" (seen ());
  let open_owned_by owner = Peer.open_space ~downloads:no_downloads ~run:(fun ~window_s:_ _ -> answered (obj ["spaceId",`Int 52;"ownership",str owner]))
      ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) in
  check bool "a space handed to the operator still opens, so take_over can bring it back" true
    (Result.is_ok (open_owned_by "agentDelegatedToUser"));
  check bool "a space the operator made does not" true (Result.is_error (open_owned_by "user"))

let test_history_moves_one_entry () =
  let current = ref 1 and navigation = ref "" and detaches = ref false and same_url = ref false and load = ref "" in
  let output = ref "" and steps = ref [] in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"ownership",str "agent"])
    | "tabs.list" -> answered (`List [
        tab_row ~label:(str "p1") ~target:"T1" ~title:"B" ~url:"https://b.test/" ~active:true ();
        tab_row ~label:`Null ~target:"T9" ~title:"Mail" ~url:"https://mail.example/" ~active:false ()])
    | "page.history" | "page.reload" ->
      steps := sent :: !steps;
      output := in_node (stand_in ~current:!current ~navigation:!navigation ~detaches:!detaches
        ~same_url:!same_url ~load:!load ^ script);
      Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let on_tab ?(tab_id=1) interaction = dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id;frame_path=[];interaction})) in
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  (match on_tab Lane.Action.Back with
   | Ok receipt -> check string "back" {|{"tabId":1,"action":"back","url":"https://a.test/","title":"A"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "back was %s" (failure_kind other));
  check bool "it moved to the entry" true (List.mem "Page.navigateToHistoryEntry" (seen ()));
  check string "and waited for the load once the tab was on it" "load at 0" (List.hd (List.rev (seen ())));
  check bool "back runs within the action window" true ((List.hd !steps).window_s
    < Lane.reply_timeout_sec (Lane.Page_act (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Back})));
  current := 0;
  check string "no earlier page" "tab 1 has no earlier page in its history"
    (before_effect "back from the first entry" (on_tab Lane.Action.Back));
  check (list string) "and nothing moved" ["Page.getNavigationHistory"] (seen ());
  (match on_tab Lane.Action.Forward with
   | Ok receipt -> check string "forward" {|{"tabId":1,"action":"forward","url":"https://b.test/","title":"B"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "forward was %s" (failure_kind other));
  current := 1;
  check string "no later page" "tab 1 has no later page in its history"
    (before_effect "forward from the last entry" (on_tab Lane.Action.Forward));
  (match on_tab Lane.Action.Reload with
   | Ok receipt -> check string "reload" {|{"tabId":1,"action":"reload","url":"https://b.test/","title":"B"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "reload was %s" (failure_kind other));
  check (list string) "a reload is ego's own" ["reload"] (seen ());
  detaches := true;
  (match on_tab Lane.Action.Back with
   | Ok receipt -> check string "back past a failed read" {|{"tabId":1,"action":"back","url":"https://a.test/","title":"A"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "a move with a failed read while waiting was %s" (failure_kind other));
  check bool "a read failed while it waited" true (List.mem "detached" (seen ()));
  detaches := false;
  same_url := true;
  (match on_tab Lane.Action.Back with
   | Ok receipt -> check string "back to an entry with the same URL" {|{"tabId":1,"action":"back","url":"https://a.test/","title":"A"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "a move to the same URL was %s" (failure_kind other));
  check string "it waited for the entry, not the URL" "load at 0" (List.hd (List.rev (seen ())));
  same_url := false;
  load := {|throw new Error("Timeout 30000ms exceeded");|};
  (match on_tab Lane.Action.Back with
   | Error (Live.Partial_failure {receipt; message; _}) ->
     check string "a load wait that failed answers where the tab is" {|{"tabId":1,"action":"back","url":"https://a.test/","title":"A"}|} (Yojson.Safe.to_string receipt);
     check string "and what failed" "Timeout 30000ms exceeded" message
   | other -> failf "a failed load wait was %s" (failure_kind other));
  load := "";
  navigation := {|throw new Error("net::ERR_ABORTED");|};
  (match on_tab Lane.Action.Back with
   | Error (Live.Partial_failure {tab_id; receipt; message}) ->
     check int "the tab" 1 tab_id;
     check string "where it is now" {|{"tabId":1,"action":"back","url":"https://b.test/","title":"B"}|} (Yojson.Safe.to_string receipt);
     check string "what failed" "net::ERR_ABORTED" message
   | other -> failf "a failed move was %s" (failure_kind other));
  let before = List.length !steps in
  check string "the operator's tab" "before effect" (failure_kind (on_tab ~tab_id:2 Lane.Action.Back));
  check int "ran no script" before (List.length !steps)

(* A managed page's row names the dialog blocking it, and an agent page's
   dialog is answered with a receipt that names it. *)
let test_dialogs_are_listed_and_answered () =
  let asked = ref [] and listing = ref tabs and reply = ref (fun (_ : sent) -> fail "no reply set") in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with "tabs.list" -> answered !listing | _ -> !reply sent) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let runs () = List.length !asked and last () = List.hd !asked in
  let act ?(tab_id=1) interaction = dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id;frame_path=[];interaction})) in
  let prompt = ego_dialog ~default:"def" "prompt" "name?" and alert = ego_dialog "alert" "saved" in
  reply := (fun _ -> answered (obj ["dialog",prompt]));
  (match act (Lane.Action.Accept_dialog (Some "Vincent")) with
   | Ok receipt -> check string "the answer names the dialog"
       {|{"tabId":1,"action":"accept_dialog","dialog":{"type":"prompt","message":"name?","defaultValue":"def"}}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "the accept was %s" (failure_kind other));
  check string "on the page's label" "p1" (text (field "label" (last ()).args));
  check bool "accepts" true (field "accept" (last ()).args = `Bool true);
  check string "with the text" "Vincent" (text (field "text" (last ()).args));
  check bool "within the action window" true ((last ()).window_s
    < Lane.reply_timeout_sec (Lane.Page_act (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Accept_dialog None})));
  ignore (act (Lane.Action.Accept_dialog None));
  check bool "no text is no text" true (field "text" (last ()).args = `Null);
  reply := (fun _ -> answered (obj ["dialog",alert]));
  (match act Lane.Action.Dismiss_dialog with
   | Ok receipt -> check string "the dismissal names the dialog"
       {|{"tabId":1,"action":"dismiss_dialog","dialog":{"type":"alert","message":"saved"}}|} (Yojson.Safe.to_string receipt)
   | other -> failf "the dismissal was %s" (failure_kind other));
  check bool "dismisses" true (field "accept" (last ()).args = `Bool false);
  reply := (fun _ -> answered (obj ["dialog",ego_dialog "modal" "?"]));
  (match act Lane.Action.Dismiss_dialog with
   | Ok receipt -> check string "a dialog it cannot read is left out" {|{"tabId":1,"action":"dismiss_dialog"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "an answer to an unreadable dialog was %s" (failure_kind other));
  reply := (fun _ -> refused "no dialog is open in this tab");
  check string "none open" "no dialog is open in this tab" (before_effect "an answer with none open" (act Lane.Action.Dismiss_dialog));
  reply := (fun _ -> failed "Target closed");
  (match act Lane.Action.Dismiss_dialog with
   | Error (Live.Outcome_unknown detail) ->
     check bool "may have been answered" true (String_util.contains_substring detail "may have been answered")
   | other -> failf "a failed answer was %s" (failure_kind other));
  let before = runs () in
  check string "the operator's tab" "before effect" (failure_kind (act ~tab_id:2 Lane.Action.Dismiss_dialog));
  check int "ran no script" before (runs ());
  (* The rows: a managed page's dialog, read now; an operator tab has none. *)
  listing := `List [
    tab_row ~dialog:prompt ~label:(str "p1") ~target:"T1" ~title:"Slack" ~url:"https://app.slack.com/" ~active:true ();
    tab_row ~label:`Null ~target:"T9" ~title:"Mail" ~url:"https://mail.example/" ~active:false ();
    tab_row ~dialog:alert ~label:(str "p2") ~target:"T2" ~title:"" ~url:"about:blank" ~active:false ()];
  (match dispatch peer Live.Tabs_list (obj []) with
   | Ok rows -> check string "each managed page names the dialog blocking it"
       ({|[{"id":1,"index":0,"url":"https://app.slack.com/","title":"Slack","active":true,"dialog":{"type":"prompt","message":"name?","defaultValue":"def"}},|}
        ^ {|{"id":2,"index":1,"url":"https://mail.example/","title":"Mail","active":false},|}
        ^ {|{"id":3,"index":2,"url":"about:blank","title":"","active":false,"dialog":{"type":"alert","message":"saved"}}]|})
       (Yojson.Safe.to_string rows)
   | Error _ -> fail "the listing failed");
  (* A page whose dialog state ego could not read, or named in a shape this
     connection cannot read, is listed as BiDi lists a tab it could not read. *)
  listing := `List [
    tab_row ~label:(str "p1") ~target:"T1" ~title:"Slack" ~url:"https://app.slack.com/" ~active:true ();
    tab_row ~unread:(str "Not attached to an active page") ~label:(str "p2") ~target:"T2" ~title:"" ~url:"about:blank" ~active:false ();
    tab_row ~dialog:(ego_dialog "modal" "?") ~label:(str "p3") ~target:"T3" ~title:"X" ~url:"https://x.test/" ~active:false ()];
  (match dispatch peer Live.Tabs_list (obj []) with
   | Ok rows -> check string "an unread dialog state is not a page without a dialog"
       ({|{"tabs":[{"id":1,"index":0,"url":"https://app.slack.com/","title":"Slack","active":true}],"complete":false,"unavailableTabs":[|}
        ^ {|{"id":3,"index":1,"error":"ego did not read whether a dialog blocks this page: Not attached to an active page","url":"about:blank"},|}
        ^ {|{"id":4,"index":2,"error":"ego reported a JavaScript dialog of unknown type \"modal\"","url":"https://x.test/"}]}|})
       (Yojson.Safe.to_string rows)
   | Error _ -> fail "the partial listing failed");
  listing := `List [obj ["label",str "p1";"targetId",str "T1";"title",str "Slack";"url",str "https://app.slack.com/";"active",`Bool true]];
  check bool "a row without its dialog state is refused" true (Result.is_error (dispatch peer Live.Tabs_list (obj [])))

(* An input whose page opened a dialog answers with it; a page already
   blocked is refused before any input. *)
let test_an_input_that_opens_a_dialog_answers_with_it () =
  let reply = ref (fun (_ : sent) -> fail "no reply set") in
  let peer = opened (fun sent -> match sent.step with "tabs.list" -> answered tabs | _ -> !reply sent) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let interact action = dispatch peer Live.Page_interact (interact_args action) in
  let row = obj ["url",str observed_url;"title",str "Slack"] in
  reply := (fun sent -> match sent.step with
    | "page.target" -> answered resolved
    | "page.pointer" -> answered (obj ["guard",page_summary;"dialog",ego_dialog "confirm" "sure?";"tab",row;"error",`Null;"pointerReleased",`Bool true])
    | other -> failf "unexpected step %s" other);
  (match interact (Lane.Click_node {document_id="d1";node_id="send"}) with
   | Ok receipt -> check string "the click and the dialog it opened"
       {|{"tabId":1,"action":"click","urlBefore":"https://app.slack.com/","url":"https://app.slack.com/","title":"Slack","dialog":{"type":"confirm","message":"sure?"}}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "a click that opened a dialog was %s" (failure_kind other));
  reply := (fun _ -> answered (obj ["dialog",ego_dialog "alert" "saved";"tab",row]));
  (match interact (Lane.Fill_node {target={document_id="d1";node_id="message"};text="hi"}) with
   | Error (Live.Partial_failure {tab_id; receipt; message}) ->
     check int "the tab" 1 tab_id;
     check string "where it is and the dialog"
       {|{"tabId":1,"action":"fill","url":"https://app.slack.com/","title":"Slack","dialog":{"type":"alert","message":"saved"}}|}
       (Yojson.Safe.to_string receipt);
     check bool "says to answer it" true (String_util.contains_substring message "accept_dialog or dismiss_dialog")
   | other -> failf "a fill the dialog stopped was %s" (failure_kind other));
  reply := (fun _ -> refused "tab 1 is blocked on a JavaScript dialog; list the tabs to read it, and answer it with accept_dialog or dismiss_dialog before another step");
  check string "a blocked page" "before effect" (failure_kind (interact (Lane.Fill_node {target={document_id="d1";node_id="message"};text="hi"})))

(* The dialog scripts in node, against a stand-in for ego: one agent page,
   [open] the dialog it is blocked on, and [opening] the one the next click
   or page script opens. ego refuses page.evaluate while a dialog is open
   and stops waiting for one that opens a dialog, as 0.6.0.16 did. *)
let dialog_stand_in ~open_ ~opening ~opens_on ~canned = Printf.sprintf {js|
let open = %s;
const opening = %s;
const opensOn = %S;
const canned = %s;
const seen = [];
process.on("exit", () => console.log("seen " + JSON.stringify(seen)));
const page = {
  info: async () => { seen.push("info"); return open === null ? {url: "https://app.slack.com/", title: "Slack", w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600} : {dialog: open}; },
  evaluate: async () => {
    seen.push("evaluate");
    if (open !== null) throw new Error("Runtime.evaluate cannot run while a JavaScript " + open.type + " dialog is open");
    if (opensOn === "evaluate") { open = opening; throw new Error("a JavaScript " + open.type + " dialog opened while Runtime.evaluate was running"); }
    return canned;
  },
  mouse: {
    move: async () => { seen.push("move"); },
    click: async (x, y, options) => { seen.push("click " + options.label); if (opensOn === "click") open = opening; return open === null ? {} : {dialog: open}; },
  },
  acceptDialog: async text => { seen.push(text === undefined ? "accept" : "accept " + text); if (open === null) return false; open = null; return true; },
  dismissDialog: async () => { seen.push("dismiss"); if (open === null) return false; open = null; return true; },
  goto: async () => { seen.push("goto"); },
  close: async () => { seen.push("close"); },
};
const taskSpace = async () => ({
  ownership: "agent",
  tabs: async () => [{label: "p1", openedBy: "agent", url: "https://app.slack.com/", title: "Slack", targetId: "T1", active: true}],
  page: () => page,
});
|js} (Yojson.Safe.to_string open_) (Yojson.Safe.to_string opening) opens_on (Yojson.Safe.to_string canned)

let test_dialog_scripts_in_node () =
  let scenario = ref (`Null, `Null, "") and output = ref "" in
  let canned = function
    | "page.target" -> resolved
    | "page.pointer" -> page_summary
    | "page.input" -> in_page (obj ["action",str "fill"])
    | _ -> in_page (obj ["url",str observed_url]) in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"ownership",str "agent"])
    | step ->
      let open_, opening, opens_on = !scenario in
      output := in_node (dialog_stand_in ~open_ ~opening ~opens_on ~canned:(canned step) ^ script);
      Ok !output in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  let act interaction = dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction})) in
  let interact action = dispatch peer Live.Page_interact (interact_args action) in
  let blocked detail = check bool ("refused as blocked: " ^ detail) true (String_util.contains_substring detail "is blocked on a JavaScript dialog") in
  let prompt = ego_dialog ~default:"def" "prompt" "name?" and alert = ego_dialog "alert" "saved" in
  scenario := (prompt, `Null, "");
  (match dispatch peer Live.Tabs_list (obj []) with
   | Ok rows -> check string "listed with its dialog"
       {|[{"id":1,"index":0,"url":"https://app.slack.com/","title":"Slack","active":true,"dialog":{"type":"prompt","message":"name?","defaultValue":"def"}}]|}
       (Yojson.Safe.to_string rows)
   | Error _ -> fail "the listing failed");
  (match act (Lane.Action.Accept_dialog (Some "Vincent")) with
   | Ok receipt -> check string "the answer"
       {|{"tabId":1,"action":"accept_dialog","dialog":{"type":"prompt","message":"name?","defaultValue":"def"}}|} (Yojson.Safe.to_string receipt)
   | other -> failf "the accept was %s" (failure_kind other));
  check (list string) "read, then answered with the text" ["info";"accept Vincent"] (seen ());
  scenario := (`Null, `Null, "");
  check string "none open" "no dialog is open in this tab" (before_effect "a dismissal with none open" (act Lane.Action.Dismiss_dialog));
  check (list string) "and nothing was answered" ["info"] (seen ());
  scenario := (`Null, ego_dialog "confirm" "sure?", "click");
  (match interact (Lane.Click_node {document_id="d1";node_id="send"}) with
   | Ok receipt -> check string "the click and its dialog"
       {|{"tabId":1,"action":"click","urlBefore":"https://app.slack.com/","url":"https://app.slack.com/","title":"Slack","dialog":{"type":"confirm","message":"sure?"}}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "a click that opened a dialog was %s" (failure_kind other));
  check (list string) "no page script after the dialog opened, and ego's click carried its label" ["info";"evaluate";"click MASC · agent · click";"info"] (seen ());
  scenario := (`Null, alert, "evaluate");
  (match interact (Lane.Fill_node {target={document_id="d1";node_id="message"};text="hi"}) with
   | Error (Live.Partial_failure {receipt; _}) -> check string "a fill the dialog stopped"
       {|{"tabId":1,"action":"fill","url":"https://app.slack.com/","title":"Slack","dialog":{"type":"alert","message":"saved"}}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "a fill the dialog stopped was %s" (failure_kind other));
  check (list string) "read the dialog after the script stopped" ["info";"evaluate";"info"] (seen ());
  scenario := (alert, `Null, "");
  blocked (before_effect "a read of a blocked page" (dispatch peer Live.Page_read (obj ["tabId",`Int 1])));
  check (list string) "read nothing" ["info"] (seen ());
  blocked (before_effect "a move of a blocked page" (dispatch peer Live.Page_goto (obj ["tabId",`Int 1;"url",str "https://example.test/"])));
  check (list string) "moved nothing" ["info"] (seen ());
  blocked (before_effect "a click on a blocked page" (interact (Lane.Click_at {point={x=0.5;y=0.5};viewport;button=Lane.Pointer.Primary})));
  check (list string) "clicked nothing" ["info"] (seen ());
  (match act Lane.Action.Close_tab with
   | Ok _ -> check (list string) "a blocked page still closes" ["close"] (seen ())
   | other -> failf "a close of a blocked page was %s" (failure_kind other))

(* A listing answers ego's rows as Browser_downloads rows. A completed file in
   the connection's folder is published once and carried as its artifact; a
   failed publication is said on the row and tried again; a row the wait
   could not have written is refused. *)
let test_downloads_are_listed_and_published_once () =
  let root = Unix.realpath (capture_directory ()) in
  let saved = "1b000000-0000-4000-8000-0000000000a1" and pending = "1b000000-0000-4000-8000-0000000000a2"
  and broken = "1b000000-0000-4000-8000-0000000000a3" in
  let saved_path = Filename.concat root saved in
  Out_channel.with_open_bin saved_path (fun channel -> Out_channel.output_string channel "report");
  let published = ref [] and busy = ref true in
  let downloads = {Peer.root; publish = (fun path ->
    published := path :: !published;
    if !busy then Error "the broker is busy" else Ok (obj ["downloadSnapshot",str "snapshot-1"]))} in
  let row ?(path=`Null) ?(reason=`Null) ~id ~state name = obj ["id",str id;"label",str "p1";
    "url",str ("https://example.test/" ^ name);"suggestedFilename",str name;"state",str state;"path",path;"reason",reason] in
  let rows = ref [] and asked = ref [] in
  let peer = opened ~downloads (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | "page.downloads" -> asked := sent.args :: !asked;
      answered (obj ["since",str "2026-10-23T09:00:00.000Z";"rows",`List !rows])
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let read () = dispatch peer Live.Page_downloads (obj ["tabId",`Int 1]) in
  let listed () = match read () with
    | Ok listing -> listing
    | Error (Live.Before_effect detail | Live.Outcome_unknown detail | Live.Partial_failure {message=detail;_}) ->
      failf "the listing failed: %s" detail in
  rows := [row ~id:saved ~state:"completed" ~path:(str saved_path) "report.txt";
           row ~id:pending ~state:"pending" "big.zip";
           row ~id:broken ~state:"interrupted" ~reason:(str "network failed") "broken.txt"];
  let downloads_of listing = Yojson.Safe.Util.to_list (field "downloads" listing) in
  (match downloads_of (listed ()) with
   | first :: _ -> check string "a failed publication is said on its row" "the broker is busy" (text (field "artifactError" first))
   | [] -> fail "the listing has no rows");
  busy := false;
  let listing = listed () in
  ignore (listed ());
  check (list string) "the saved file was published on the next read, then kept" [saved_path; saved_path] !published;
  check int "for its tab" 1 (Yojson.Safe.Util.to_int (field "tabId" listing));
  check string "since when the page was watched" "2026-10-23T09:00:00.000Z" (text (field "watchingSince" listing));
  (match downloads_of listing with
   | [completed; waiting; failed] ->
     check string "completed" "completed" (text (field "status" completed));
     check string "its artifact" {|{"downloadSnapshot":"snapshot-1"}|} (Yojson.Safe.to_string (field "artifact" completed));
     check int "its size" 6 (Yojson.Safe.Util.to_int (field "bytes" completed));
     check string "its name" "report.txt" (text (field "suggestedFilename" completed));
     check string "its tab as the context" "1" (text (field "context" completed));
     check string "pending" "pending" (text (field "status" waiting));
     check bool "a pending row has no artifact" true (field "artifact" waiting = `Null);
     check string "interrupted" "interrupted" (text (field "status" failed));
     check string "and why" "network failed" (text (field "reason" failed))
   | other -> failf "the listing has %d rows" (List.length other));
  check string "the script names the connection's folder" root (text (field "downloads" (List.hd !asked)));
  let refused rows_now = rows := rows_now; before_effect "an unreadable listing" (read ()) in
  check bool "a file outside the folder is refused" true
    (String_util.contains_substring
       (refused [row ~id:saved ~state:"completed" ~path:(str "/tmp/report.txt") "report.txt"]) "outside the connection's download folder");
  check bool "an id that is not a UUID is refused" true
    (String_util.contains_substring
       (refused [row ~id:"../escape" ~state:"pending" "report.txt"]) "not a UUID");
  let runs = List.length !asked in
  check bool "a listing names its tab" true
    (String_util.contains_substring (before_effect "a listing without a tab" (dispatch peer Live.Page_downloads (obj []))) "tabId");
  check int "and runs nothing without one" runs (List.length !asked)

(* The download wait and the listing in node, against a stand-in for ego with
   one agent page. [fire] starts a download there, [fail] fails the armed
   wait while the page stays open, [close] closes the page.
   Steps run one after another in one node process, as in one ego process;
   a step whose answer the case does not read prints nothing. *)
let download_stand_in = {js|
const fs = await import("node:fs");
const nodePath = await import("node:path");
const seen = [];
process.on("exit", () => console.log("seen " + JSON.stringify(seen)));
let waiting = [];
let open = true;
const page = {
  info: async () => ({url: "https://example.test/", title: "Files", w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600}),
  goto: async () => { seen.push("goto"); },
  waitForEvent: (name, options) => {
    seen.push("wait " + name + " " + options.timeout);
    return new Promise((resolve, reject) => waiting.push({resolve, reject}));
  },
};
const download = (name, failure) => ({
  url: () => "https://example.test/" + name,
  suggestedFilename: () => name,
  saveAs: async path => {
    seen.push("save");
    if (failure === null) { fs.mkdirSync(nodePath.dirname(path), {recursive: true}); fs.writeFileSync(path, "contents of " + name); }
  },
  failure: async () => failure,
  delete: async () => { seen.push("delete"); },
});
const fire = (name, failure) => { const armed = waiting; waiting = []; armed.forEach(wait => wait.resolve(download(name, failure))); };
const fail = () => { const armed = waiting; waiting = []; armed.forEach(wait => wait.reject(new Error("Target crashed"))); };
const close = () => { open = false; const armed = waiting; waiting = []; armed.forEach(wait => wait.reject(new Error("No target with given id found"))); };
const taskSpace = async () => ({
  ownership: "agent",
  tabs: async () => open ? [{label: "p1", openedBy: "agent", url: "https://example.test/", title: "Files", targetId: "T1", active: true}] : [],
  page: () => page,
});
const settle = () => new Promise(resolve => setTimeout(resolve, 20));
const quiet = console.log;
|js}

let test_the_download_wait_runs_in_node () =
  let root = Unix.realpath (capture_directory ()) in
  let published = ref [] in
  let downloads = {Peer.root; publish = (fun path -> published := path :: !published; Ok (obj ["downloadSnapshot",str "snapshot-1"]))} in
  let program = ref [download_stand_in] and output = ref "" in
  let silent script = "console.log = () => {};\n{\n" ^ script ^ "\n}\nconsole.log = quiet;" in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"ownership",str "agent"])
    | "tabs.list" -> answered (`List [tab_row ~label:(str "p1") ~target:"T1" ~title:"Files" ~url:"https://example.test/" ~active:true ()])
    | "page.goto" -> program := silent script :: !program;
      answered (obj ["error",`Null;"tab",obj ["url",str "https://example.test/";"title",str "Files"]])
    | "page.downloads" ->
      output := in_node (String.concat "\n" (List.rev (("{\n" ^ script ^ "\n}") :: !program)));
      Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let goto () = match dispatch peer Live.Page_goto (obj ["tabId",`Int 1;"url",str "https://example.test/"]) with
    | Ok _ -> () | Error _ -> fail "the move failed" in
  let between line = program := line :: !program in
  goto ();
  between "fire(\"report.txt\", null); await settle();";
  goto ();
  between "fire(\"broken.txt\", \"network failed\"); await settle(); fail(); await settle();";
  goto ();
  between "close(); await settle();";
  let listing = match dispatch peer Live.Page_downloads (obj ["tabId",`Int 1]) with
    | Ok listing -> listing
    | Error (Live.Before_effect detail | Live.Outcome_unknown detail | Live.Partial_failure {message=detail;_}) ->
      failf "the listing failed: %s" detail in
  let seen = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  let count name = List.length (List.filter (String.equal name) seen) in
  let waits = List.filter (String.starts_with ~prefix:"wait download ") seen in
  check int "one wait on the page, armed again after each download and by the step after a failed wait, not after the page closed"
    4 (List.length waits);
  check bool "each with a timeout ego accepts" true
    (List.for_all (fun wait -> int_of_string (after ~prefix:"wait download " wait) > 0) waits);
  check int "the moves ran" 3 (count "goto");
  check int "both downloads were saved" 2 (count "save");
  check int "and ego's own copies deleted" 2 (count "delete");
  check bool "watched since a time" true (match field "watchingSince" listing with `String _ -> true | _ -> false);
  match Yojson.Safe.Util.to_list (field "downloads" listing) with
  | [completed; failed] ->
    let path = text (field "path" completed) in
    check bool "the file is in the connection's folder" true (String.starts_with ~prefix:(root ^ "/") path);
    check string "with what the browser saved" "contents of report.txt" (In_channel.with_open_bin path In_channel.input_all);
    check (list string) "and was published" [path] !published;
    check string "its artifact" {|{"downloadSnapshot":"snapshot-1"}|} (Yojson.Safe.to_string (field "artifact" completed));
    check string "its name" "report.txt" (text (field "suggestedFilename" completed));
    check string "the failed one" "interrupted" (text (field "status" failed));
    check string "says why" "network failed" (text (field "reason" failed))
  | other -> failf "the listing has %d rows" (List.length other)

(* An upload sets the worker's copies on one file input and answers what the
   input holds. The page reads the files later, so the copies outlive the
   upload's own scope and go only once the space has ended. *)
let test_an_upload_keeps_its_files_until_the_space_ends () =
  let directory = Unix.realpath (capture_directory ()) in
  let snapshot = match Lane.Upload_lease.prepare_files ~temp_dir:directory ~files:["note.txt",(fun () -> Ok "hello")] () with
    | Ok snapshot -> snapshot
    | Error (Lane.Upload_lease.Read_failed _ | Lane.Upload_lease.Snapshot_failed _) -> fail "the batch was not prepared" in
  let paths = Lane.Upload_lease.paths snapshot in
  let reply = ref (fun _ -> fail "no reply was set") and asked = ref [] in
  let peer = opened (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | "page.upload" -> asked := sent.args :: !asked; !reply sent
    | "space.finish" -> answered `Null
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let upload ?(selector="#file") paths = dispatch peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.File_input selector;paths}})) in
  let row = obj ["url",str "https://app.slack.com/";"title",str "Slack"] in
  let held = in_page (obj ["url",str "https://app.slack.com/";"title",str "Slack";"files",`List [obj ["name",str "note.txt";"size",`Int 5]]]) in
  reply := (fun _ -> answered (obj ["error",`Null;"dialog",`Null;"after",held;"tab",row]));
  (match upload paths with
   | Ok receipt -> check string "the files the input holds"
       {|{"tabId":1,"action":"upload","url":"https://app.slack.com/","title":"Slack","files":[{"name":"note.txt","size":5}]}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "the upload was %s" (failure_kind other));
  check (list string) "ego was given the copies" paths
    (List.map text (Yojson.Safe.Util.to_list (field "paths" (List.hd !asked))));
  check string "and the selector as given" "#file" (text (field "selector" (List.hd !asked)));
  Lane.Upload_lease.release snapshot;
  check bool "the copies outlive the upload's own scope" true (List.for_all Sys.file_exists paths);
  reply := (fun _ -> answered (obj ["error",`Null;"dialog",ego_dialog "alert" "uploaded";"after",`Null;"tab",row]));
  (match upload paths with
   | Ok receipt -> check string "an upload that opened a dialog answers with it"
       {|{"tabId":1,"action":"upload","url":"https://app.slack.com/","title":"Slack","dialog":{"type":"alert","message":"uploaded"}}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "an upload that opened a dialog was %s" (failure_kind other));
  reply := (fun _ -> answered (obj ["error",str "Target closed";"dialog",`Null;"after",`Null;"tab",row]));
  check string "a failed setInputFiles leaves the input unknown" "unknown" (failure_kind (upload paths));
  reply := (fun _ -> refused "upload requires a file input");
  check string "a refused input" "before effect" (failure_kind (upload ~selector:"#text" paths));
  let runs = List.length !asked in
  check bool "a missing file is refused" true
    (String_util.contains_substring (before_effect "a missing file" (upload [Filename.concat directory "absent.txt"])) "absent.txt");
  check bool "and so is no file" true
    (String_util.contains_substring (before_effect "no file" (upload [])) "at least one file");
  check int "neither runs ego" runs (List.length !asked);
  check (result unit string) "finish" (Ok ()) (Peer.finish peer);
  check bool "the space's end lets the copies go" false (List.exists Sys.file_exists paths)

(* A page that makes its file input on a click gets the copies through ego's
   file chooser. The click is the effect, so a chooser that did not open is
   reported after it; the receipt lists what was handed to the chooser, and
   the copies stay until the space ends, as for a file input. *)
let test_an_upload_through_a_file_chooser_answers_what_it_handed () =
  let directory = Unix.realpath (capture_directory ()) in
  let snapshot = match Lane.Upload_lease.prepare_files ~temp_dir:directory ~files:["note.txt",(fun () -> Ok "hello")] () with
    | Ok snapshot -> snapshot
    | Error (Lane.Upload_lease.Read_failed _ | Lane.Upload_lease.Snapshot_failed _) -> fail "the batch was not prepared" in
  let paths = Lane.Upload_lease.paths snapshot in
  let reply = ref (fun _ -> fail "no reply was set") and asked = ref [] in
  let peer = opened (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | "page.choose_files" -> asked := sent.args :: !asked; !reply sent
    | "space.finish" -> answered `Null
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let choose ?actor ?(opener="#attach") paths = dispatch ?actor peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.Chooser_opener opener;paths}})) in
  let row = obj ["url",str "https://app.slack.com/";"title",str "Slack"] in
  let last () = List.hd !asked in
  reply := (fun _ -> answered (obj ["error",`Null;"dialog",`Null;"tab",row]));
  (match choose paths with
   | Ok receipt -> check string "the files handed to the chooser"
       {|{"tabId":1,"action":"upload","chosen":[{"name":"note.txt","size":5}],"url":"https://app.slack.com/","title":"Slack"}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "the upload was %s" (failure_kind other));
  check (list string) "ego was given the copies" paths
    (List.map text (Yojson.Safe.Util.to_list (field "paths" (last ()))));
  check string "and the opener as given" "#attach" (text (field "opener" (last ())));
  check string "whose click is labelled" "MASC · agent · upload" (text (field "cursor" (last ())));
  ignore (choose ~actor:"keeper/sangsu" paths);
  check string "with the actor when there is one" "MASC · keeper/sangsu · upload" (text (field "cursor" (last ())));
  Lane.Upload_lease.release snapshot;
  check bool "the copies outlive the upload's own scope" true (List.for_all Sys.file_exists paths);
  reply := (fun _ -> answered (obj ["error",`Null;"dialog",ego_dialog "alert" "uploaded";"tab",row]));
  (match choose paths with
   | Ok receipt -> check bool "a dialog the files opened is in the receipt" true
       (String_util.contains_substring (Yojson.Safe.to_string receipt) {|"dialog":{"type":"alert","message":"uploaded"}|})
   | other -> failf "an upload that opened a dialog was %s" (failure_kind other));
  reply := (fun _ -> answered (obj ["error",str "the opener opened no file chooser: page.waitForFileChooser timed out after 5000ms";"dialog",`Null;"tab",row]));
  (match choose paths with
   | Error (Live.Outcome_unknown detail) ->
     check bool "a chooser that did not open is reported after the click" true (String_util.contains_substring detail "opened no file chooser")
   | other -> failf "a click that opened no chooser was %s" (failure_kind other));
  reply := (fun _ -> refused "no element matches the upload opener");
  check string "an opener that names nothing" "before effect" (failure_kind (choose ~opener:"#none" paths));
  let runs = List.length !asked in
  check bool "a missing file is refused" true
    (String_util.contains_substring (before_effect "a missing file" (choose [Filename.concat directory "absent.txt"])) "absent.txt");
  check int "without running ego" runs (List.length !asked);
  check (result unit string) "finish" (Ok ()) (Peer.finish peer);
  check bool "the space's end lets the copies go" false (List.exists Sys.file_exists paths)

(* The upload script in node, against a stand-in for ego with one agent page
   whose document has a file input #file, a text input #text, and two
   elements matching "input". The page scripts run as they would in a page,
   against that document. [opens] is the dialog the upload opens. *)
let upload_stand_in ~opens = Printf.sprintf {js|
const fs = await import("node:fs");
const nodePath = await import("node:path");
const opens = %s;
let open = null;
const seen = [];
process.on("exit", () => console.log("seen " + JSON.stringify(seen)));
const file = {localName: "input", type: "file", multiple: false, files: []};
const elements = {"#file": [file], "#text": [{localName: "input", type: "text", multiple: false, files: null}], "input": [file, file]};
globalThis.document = {title: "Form", querySelectorAll: selector => elements[selector] ?? []};
globalThis.location = {href: "https://example.test/"};
const page = {
  info: async () => open === null ? {url: "https://example.test/", title: "Form", w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600} : {dialog: open},
  evaluate: async expression => { seen.push("evaluate"); return (0, eval)(expression); },
  setInputFiles: async (selector, paths) => {
    seen.push("set " + selector + " " + paths.length);
    file.files = paths.map(path => ({name: nodePath.basename(path), size: fs.statSync(path).size}));
    open = opens;
  },
};
const taskSpace = async () => ({
  ownership: "agent",
  tabs: async () => [{label: "p1", openedBy: "agent", url: "https://example.test/", title: "Form", targetId: "T1", active: true}],
  page: () => page,
});
|js} (Yojson.Safe.to_string opens)

let test_the_upload_script_runs_in_node () =
  let directory = Unix.realpath (capture_directory ()) in
  let path = Filename.concat directory "note.txt" and other = Filename.concat directory "two.txt" in
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel "hello");
  Out_channel.with_open_bin other (fun channel -> Out_channel.output_string channel "second");
  let opens = ref `Null and output = ref "" in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"ownership",str "agent"])
    | "tabs.list" -> answered (`List [tab_row ~label:(str "p1") ~target:"T1" ~title:"Form" ~url:"https://example.test/" ~active:true ()])
    | "page.upload" -> output := in_node (upload_stand_in ~opens:!opens ^ script); Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  let upload ?(selector="#file") paths = dispatch peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.File_input selector;paths}})) in
  (match upload [path] with
   | Ok receipt -> check string "what the input now holds" {|[{"name":"note.txt","size":5}]|} (Yojson.Safe.to_string (field "files" receipt))
   | other -> failf "the upload was %s" (failure_kind other));
  check (list string) "checked in the page, set as CSS, then read back" ["evaluate";"set loc=css:#file 1";"evaluate"] (seen ());
  check string "a text input is refused" "upload requires a file input" (before_effect "an upload to a text input" (upload ~selector:"#text" [path]));
  check (list string) "and nothing is set" ["evaluate"] (seen ());
  check string "two files need a multiple input" "this file input takes one file" (before_effect "two files" (upload [path; other]));
  check string "a selector must match one element" "the upload selector matches 2 elements" (before_effect "two matches" (upload ~selector:"input" [path]));
  check string "or any" "no element matches the upload selector" (before_effect "no match" (upload ~selector:"#none" [path]));
  opens := ego_dialog "alert" "too big";
  (match upload [path] with
   | Ok receipt -> check string "the dialog it opened" {|{"type":"alert","message":"too big"}|} (Yojson.Safe.to_string (field "dialog" receipt))
   | other -> failf "an upload that opened a dialog was %s" (failure_kind other));
  check (list string) "no page script after the dialog opened" ["evaluate";"set loc=css:#file 1"] (seen ())

(* Input and upload frame paths reach the peer and are refused before any
   effect. Frame_read is refused by the live transport gate, so a direct
   peer call would not prove which message the public tool receives. *)
let test_input_frame_paths_are_refused_with_the_way_that_works () =
  let peer = opened (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let says label needle result =
    check bool label true (String_util.contains_substring (before_effect label result) needle) in
  says "frame input names target" "acts inside frames through target"
    (dispatch peer Live.Page_interact (interact_args ~frame_path:["#frame"] (Lane.Click_node {document_id="d1";node_id="send"})));
  says "an upload into a frame names the top document" "top document"
    (dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=1;frame_path=["#frame"];
      interaction=Lane.Action.Upload {target=Lane.Action.File_input "#file";paths=["/tmp/note.txt"]}})))

(* The chooser script in node, against a stand-in for ego whose page has one
   #attach button and two elements matching "button". The stand-in's click
   opens a file chooser when [opens] holds, one that takes several files when
   [multiple] does; its setFiles answers [set], or throws when [fails] holds.
   setFiles([]) closes the chooser. *)
let chooser_stand_in ~opens ~multiple ~set ~fails ~click_fails = Printf.sprintf {js|
const fs = await import("node:fs");
const nodePath = await import("node:path");
const seen = [];
process.on("exit", () => console.log("seen " + JSON.stringify(seen)));
const elements = {"#attach": [{localName: "button"}], "button": [{localName: "button"}, {localName: "button"}]};
globalThis.document = {title: "Form", querySelectorAll: selector => elements[selector] ?? []};
globalThis.location = {href: "https://example.test/"};
let waiting = null;
let activeChooser = false;
let clickFails = %b;
const chooser = {
  isMultiple: async () => %b,
  setFiles: async paths => {
    if (paths.length === 0) { activeChooser = false; seen.push("closed"); return {}; }
    if (%b) throw new Error("Target closed");
    activeChooser = false;
    seen.push("chosen " + paths.map(path => nodePath.basename(path) + "/" + fs.statSync(path).size).join(",")); return %s;
  },
};
const page = {
  info: async () => ({url: "https://example.test/", title: "Form", w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600}),
  evaluate: async expression => { seen.push("evaluate"); return (0, eval)(expression); },
  waitForFileChooser: options => {
    if (activeChooser) throw new Error("this Page is already waiting for a file chooser");
    seen.push("wait " + options.timeout); return new Promise((resolve, reject) => { waiting = {resolve, reject}; });
  },
  click: async (selector, options) => {
    seen.push("click " + selector + " " + options.label);
    if (waiting !== null) { if (%b) { activeChooser = true; waiting.resolve(chooser); } else waiting.reject(new Error("page.waitForFileChooser timed out after 5000ms")); }
    if (clickFails) throw new Error("click response lost");
    return {};
  },
};
const taskSpace = async () => ({
  ownership: "agent",
  tabs: async () => [{label: "p1", openedBy: "agent", url: "https://example.test/", title: "Form", targetId: "T1", active: true}],
  page: () => page,
});
|js} click_fails multiple fails (Yojson.Safe.to_string set) opens

let test_the_chooser_script_runs_in_node () =
  let directory = Unix.realpath (capture_directory ()) in
  let path = Filename.concat directory "note.txt" and other = Filename.concat directory "two.txt" in
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel "hello");
  Out_channel.with_open_bin other (fun channel -> Out_channel.output_string channel "second");
  let opens = ref true and multiple = ref false and set = ref (obj []) and fails = ref false
  and click_fails = ref false and output = ref "" in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"ownership",str "agent"])
    | "tabs.list" -> answered (`List [tab_row ~label:(str "p1") ~target:"T1" ~title:"Form" ~url:"https://example.test/" ~active:true ()])
    | "page.choose_files" ->
      let recovery = if !click_fails then
          "\nclickFails = false; const savedLog = console.log; console.log = () => {};\n{\n"
          ^ script ^ "\n}\nconsole.log = savedLog;\n"
        else "" in
      output := in_node (chooser_stand_in ~opens:!opens ~multiple:!multiple ~set:!set ~fails:!fails ~click_fails:!click_fails
        ^ "\n{\n" ^ script ^ "\n}\n" ^ recovery); Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~now ~space:"masc" ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  let choose ?(opener="#attach") paths = dispatch peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.Chooser_opener opener;paths}})) in
  let unknown label result = match result with
    | Error (Live.Outcome_unknown detail) -> detail
    | other -> failf "%s was %s" label (failure_kind other) in
  (match choose [path] with
   | Ok receipt -> check string "what the chooser was handed" {|[{"name":"note.txt","size":5}]|} (Yojson.Safe.to_string (field "chosen" receipt))
   | other -> failf "the upload was %s" (failure_kind other));
  check (list string) "checked in the page, armed, clicked with its label, then chosen"
    ["evaluate";"wait 5000";"click loc=css:#attach MASC · agent · upload";"chosen note.txt/5"] (seen ());
  check bool "a chooser that takes one file gets none of two" true
    (String_util.contains_substring (unknown "two files" (choose [path; other])) "takes one file");
  check bool "and nothing was chosen" false (List.exists (String.starts_with ~prefix:"chosen") (seen ()));
  check bool "the chooser is closed so the next one can open" true (List.mem "closed" (seen ()));
  fails := true;
  check bool "a setFiles that fails is reported after the click" true
    (String_util.contains_substring (unknown "a failed setFiles" (choose [path])) "ego did not set the files");
  check bool "and that chooser is closed too" true (List.mem "closed" (seen ()));
  fails := false;
  click_fails := true;
  check bool "a click whose response fails retains its original outcome uncertainty" true
    (String_util.contains_substring (unknown "a failed click response" (choose [path])) "ego did not click the opener: click response lost");
  check bool "the chooser opened by that click is closed" true (List.mem "closed" (seen ()));
  check bool "the next chooser upload succeeds in the same process" true (List.mem "chosen note.txt/5" (seen ()));
  click_fails := false;
  multiple := true;
  ignore (choose [path; other]);
  check bool "a multiple chooser gets both" true (List.mem "chosen note.txt/5,two.txt/6" (seen ()));
  check string "an opener must match one element" "the upload opener matches 2 elements" (before_effect "two matches" (choose ~opener:"button" [path]));
  check (list string) "and nothing is clicked" ["evaluate"] (seen ());
  check string "or any" "no element matches the upload opener" (before_effect "no match" (choose ~opener:"#none" [path]));
  set := obj ["dialog",ego_dialog "alert" "too big"];
  (match choose [path] with
   | Ok receipt -> check string "the dialog the files opened" {|{"type":"alert","message":"too big"}|} (Yojson.Safe.to_string (field "dialog" receipt))
   | other -> failf "an upload that opened a dialog was %s" (failure_kind other));
  opens := false;
  check bool "a click that opens no chooser is reported after the click" true
    (String_util.contains_substring (unknown "no chooser" (choose [path])) "opened no file chooser")

let () =
  run "browser_ego_peer" [
    "ego", [
      test_case "native drag preserves release and failure boundaries" `Quick test_native_drag_and_release;
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
      test_case "history moves one entry and waits for it" `Quick test_history_moves_one_entry;
      test_case "a snapshot reads ego's own tree" `Quick test_a_snapshot_reads_egos_own_tree;
      test_case "dialogs are listed and answered" `Quick test_dialogs_are_listed_and_answered;
      test_case "an input that opens a dialog answers with it" `Quick test_an_input_that_opens_a_dialog_answers_with_it;
      test_case "the dialog scripts run against a stand-in in node" `Quick test_dialog_scripts_in_node;
      test_case "a snapshot target is found by ego and checked first" `Quick test_a_snapshot_target_is_found_by_ego_and_checked_first;
      test_case "the space goes to the operator and back" `Quick test_the_space_goes_to_the_operator_and_back;
      test_case "scene input preserves shared identity checks" `Quick test_input_acts_through_the_shared_page_scripts;
      test_case "selectors use ego SDK" `Quick test_selector_input_uses_ego_sdk;
      test_case "downloads are listed and published once" `Quick test_downloads_are_listed_and_published_once;
      test_case "the download wait runs against a stand-in in node" `Quick test_the_download_wait_runs_in_node;
      test_case "an upload keeps its files until the space ends" `Quick test_an_upload_keeps_its_files_until_the_space_ends;
      test_case "the upload script runs against a stand-in in node" `Quick test_the_upload_script_runs_in_node;
      test_case "an upload through a file chooser answers what it handed" `Quick test_an_upload_through_a_file_chooser_answers_what_it_handed;
      test_case "the chooser script runs against a stand-in in node" `Quick test_the_chooser_script_runs_in_node;
      test_case "input frame paths name the supported route" `Quick test_input_frame_paths_are_refused_with_the_way_that_works;
      test_case "the peer serves what the lane table says" `Quick test_the_peer_serves_what_the_lane_table_says ] ]
