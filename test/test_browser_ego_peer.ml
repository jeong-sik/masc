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
  let step=find "// masc-ego: " in
  let args=match Yojson.Safe.from_string (trailing (find "const args = JSON.parse(") ");") with
      | `String encoded -> Yojson.Safe.from_string encoded
      | _ -> failwith "the production args envelope must contain a JSON string" in
  { step;args;
    space = (if step="space.status" then Yojson.Safe.Util.member "spaceId" args
      else Yojson.Safe.from_string (trailing (find "const task = await taskSpace(") ");")); window_s }

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
    if sent.step = "space.open" then answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"]) else run sent in
  match Peer.open_space ~downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory with
  | Ok peer -> peer
  | Error detail -> failf "the space did not open: %s" detail

(* A row as the listing script writes it: [dialog] is what page.info()
   named on a managed page, [dialogUnread] why it could not be read. *)
let tab_row ?(dialog=`Null) ?(unread=`Null) ?origin ~label ~target ~title ~url ~active () =
  let origin=match origin,label with Some value,_ -> value | None,`Null -> "unknown" | None,_ -> "agent" in
  obj ["label",label;"targetId",str target;"openedBy",str origin;"title",str title;"url",str url;"active",`Bool active;
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
  | Error (Live.Before_effect detail | Live.Observed_failure {disposition=Live.Not_started;message=detail;_}) -> detail
  | Ok _ -> failf "%s was served" name
  | Error (Live.Partial_failure _ | Live.Outcome_unknown _ | Live.Observed_failure {disposition=Live.Uncertain;_}) -> failf "%s failed after an effect" name

let test_space_name_inspection_is_read_only_and_requires_evidence () =
  let row id created ownership = obj ["id",`Int id;"createdBy",str created;"ownership",str ownership] in
  let observe result = Peer.observe_space_name ~space:"masc" ~run:(fun ~window_s:_ script ->
    check bool "lists without opening, claiming or finishing" true
      (contains script "await listTaskSpaces()" && not (contains script "taskSpace(") &&
       not (contains script ".claim(") && not (contains script ".finish("));
    result) in
  check bool "an agent space is not a user-owned conflict" true
    (observe (answered (`List [row 51 "agent" "agent"])) = Peer.No_user_owned_match);
  check bool "all matching user-owned ids survive duplicate names" true
    (observe (answered (`List [row 51 "agent" "agent";row 36 "user" "user";row 37 "agent" "user"]))
     = Peer.User_owned_matches [36;37]);
  check bool "another malformed or inactive namesake cannot erase a confirmed user space" true
    (observe (answered (`List [row 36 "user" "user";obj ["id",`Int 37];row 38 "agent" "inactive"]))
     = Peer.User_owned_matches [36]);
  check bool "a malformed matching row alone makes the listing inconclusive" true
    (match observe (answered (`List [obj ["id",`Int 37]])) with
     | Peer.Space_names_unavailable _ -> true | Peer.No_user_owned_match | Peer.User_owned_matches _ -> false);
  check bool "an SDK failure is inconclusive" true
    (match observe (failed "listing unavailable") with
     | Peer.Space_names_unavailable _ -> true | Peer.No_user_owned_match | Peer.User_owned_matches _ -> false);
  check bool "a timeout is inconclusive" true
    (match observe (Error Peer.Timed_out) with
     | Peer.Space_names_unavailable _ -> true | Peer.No_user_owned_match | Peer.User_owned_matches _ -> false)

let test_the_space_opens_by_name_and_is_held_by_number () =
  let spaces = ref [] in
  let run ~window_s script = let sent = sent_of ~window_s script in
    spaces := (sent.step, sent.space) :: !spaces;
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered (`List [])
    | "space.finish" -> answered (obj ["spaceId",`Int 51;"closedSpace",`Bool true;
        "keptManagedLabels",`List [];"closedManagedLabels",`List [];"preservedUnmanagedCount",`Int 0])
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  check int "space number" 51 (Peer.space_id peer);
  check string "SDK name is observed rather than guessed from configuration" "SDK Space" (Peer.space peer).name;
  ignore (dispatch peer Live.Tabs_list (obj []));
  check (result unit string) "finish" (Ok ()) (Peer.finish peer);
  check (list string) "opened by name, then held by number"
    [ "space.open \"masc\""; "tabs.list 51"; "space.finish 51" ]
    (List.rev_map (fun (step, space) -> step ^ " " ^ Yojson.Safe.to_string space) !spaces);
  let user = Peer.open_space ~run_native:(fun _ -> Error (Peer.Unstarted "no native command in this fixture")) ~downloads:no_downloads ~now ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) ~space:(Browser_configuration.Named_space "masc")
      ~run:(fun ~window_s:_ _ -> answered (obj ["spaceId",`Int 7;"name",str "SDK Space";"ownership",str "user"])) in
  check bool "a space the operator owns is refused" true (Result.is_error user);
  let in_use = Peer.open_space ~run_native:(fun _ -> Error (Peer.Unstarted "no native command in this fixture")) ~downloads:no_downloads ~now ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) ~space:(Browser_configuration.Named_space "masc")
      ~run:(fun ~window_s:_ _ -> failed "EGO_TASK_SPACE_NAME_IN_USE: masc") in
  check (result reject string) "ego's own refusal is kept" (Error "EGO_TASK_SPACE_NAME_IN_USE: masc") (Result.map ignore in_use);
  List.iter (fun fields ->
    let result=Peer.open_space ~run_native:(fun _ -> Error (Peer.Unstarted "unused"))
      ~downloads:no_downloads ~now ~version:"fixture" ~capture_directory:(capture_directory ()) ~space:(Browser_configuration.Named_space "masc")
      ~run:(fun ~window_s:_ script ->
        check string "malformed attachment never dispatches a page operation" "space.open" (sent_of ~window_s:0. script).step;
        answered (obj fields)) in
    check bool "malformed SDK attachment context is refused" true (Result.is_error result))
    [["spaceId",`Int 51;"ownership",str "agent"];
     ["spaceId",`Int 51;"name",str "SDK Space";"name",str "duplicate";"ownership",str "agent"];
     ["spaceId",`Int (-1);"name",str "SDK Space";"ownership",str "agent"];
     ["spaceId",`Int 51;"name",str " ";"ownership",str "agent"]]

let space_owner = testable (fun out owner -> Format.pp_print_string out (match owner with
  | Peer.Agent_owner -> "agent" | Handed_to_operator -> "handed to the operator" | Operator_owner -> "operator")) ( = )
let spaces_failure = testable (fun out -> function
  | Peer.Spaces_failed detail -> Format.fprintf out "failed: %s" detail
  | Spaces_malformed detail -> Format.fprintf out "malformed: %s" detail) ( = )

(* Opening a space by name makes it when it is not there, so the spaces are
   read from ego's list, and the name is compared in masc: setup checks a
   name this way before it leaves it in the table. *)
let test_the_spaces_of_a_name_are_listed_without_opening_one () =
  let script = Peer.task_spaces_script in
  let lines = List.map String.trim (String.split_on_char '\n' script) in
  check string "the step" "// masc-ego: spaces.list" (List.hd lines);
  check bool "it lists the spaces" true (contains script "await listTaskSpaces()");
  check bool "it opens no space" false (contains script "await taskSpace(");
  let read value = match value with
    | Ok output -> Peer.matching_spaces ~space:(Browser_configuration.Named_space "masc") output
    | Error failure -> Error (Peer.Spaces_failed (Peer.run_failure_message failure)) in
  let listed ?(name="masc") id ownership = obj ["spaceId",`Int id;"name",str name;"ownership",str ownership] in
  check (result (list (pair int space_owner)) spaces_failure) "each space of that name, with its number and owner"
    (Ok [36, Peer.Operator_owner; 42, Peer.Agent_owner; 32, Peer.Handed_to_operator])
    (read (answered (`List [listed 36 "user"; listed ~name:"masc-keepers" 43 "user"; listed 42 "agent";
      listed ~name:"Masc" 7 "user"; listed ~name:"other" 8 "team"; listed 32 "agentDelegatedToUser"])));
  check (result (list (pair int space_owner)) spaces_failure) "no space of that name" (Ok []) (read (answered (`List [])));
  List.iter (fun (label, output) -> check bool (label ^ " is an answer masc does not read") true
      (match read output with Error (Peer.Spaces_malformed _) -> true | Ok _ | Error (Peer.Spaces_failed _) -> false))
    [ "an owner masc does not know", answered (`List [listed 9 "team"]);
      "a space without its number", answered (`List [obj ["name",str "masc";"ownership",str "user"]]);
      "a space without its name", answered (`List [obj ["spaceId",`Int 9;"ownership",str "user"]]);
      "a row that is not an object", answered (`List [`Null]);
      "an answer that is not a list", answered `Null ];
  check bool "a failure the frame caught is a listing that failed" true
    (match read (failed "ego lite is not running") with Error (Peer.Spaces_failed _) -> true | Ok _ | Error (Peer.Spaces_malformed _) -> false);
  let unknown = Peer.open_space ~run_native:(fun _ -> Error (Peer.Unstarted "no native command in this fixture"))
      ~downloads:no_downloads ~now ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) ~space:(Browser_configuration.Named_space "masc")
      ~run:(fun ~window_s:_ _ -> answered (obj ["spaceId",`Int 9;"ownership",str "team"])) in
  check bool "a connection still does not open on an owner masc does not know" true (Result.is_error unknown)

(* The listing script itself, run by node with ego's listTaskSpaces stood in
   by the shape the ego guide documents: ego's id becomes spaceId, every row
   is passed on, and an ego without the list, or with no array, answers no
   list instead of throwing. *)
let test_the_listing_script_runs_under_node () =
  let run ego =
    let path = Filename.concat (capture_directory ()) "task-spaces.js" in
    Out_channel.with_open_bin path (fun out ->
      output_string out (ego ^ "\n(async () => {\n" ^ Peer.task_spaces_script ^ "\n})();\n"));
    let channel = Unix.open_process_args_in "node" [| "node"; path |] in
    let output = In_channel.input_all channel in
    (match Unix.close_process_in channel with
     | Unix.WEXITED 0 -> ()
     | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> fail ("node did not run the listing script: " ^ output));
    Peer.matching_spaces ~space:(Browser_configuration.Named_space "masc") output in
  check (result (list (pair int space_owner)) spaces_failure) "the operator's space of exactly that name"
    (Ok [36, Peer.Operator_owner])
    (run (String.concat "\n" [
      "globalThis.listTaskSpaces = async () => [";
      "  {id: 36, name: 'masc', ownership: 'user', createdBy: 'user', state: 'active'},";
      "  {id: 42, name: 'masc-keepers', ownership: 'agent', createdBy: 'agent'},";
      "  {id: 7, name: 'Masc', ownership: 'user', createdBy: 'user'}];" ]));
  List.iter (fun (label, ego) -> check bool (label ^ " is an answer masc does not read") true
      (match run ego with Error (Peer.Spaces_malformed _) -> true | Ok _ | Error (Peer.Spaces_failed _) -> false))
    [ "an ego without listTaskSpaces", "";
      "a list that is not an array", "globalThis.listTaskSpaces = async () => ({});";
      "a row that is not an object", "globalThis.listTaskSpaces = async () => [null];" ]

let test_exact_numeric_space_resume () =
  let calls=ref [] in
  let open_reference reference reply =
    calls:=[];
    Peer.open_space ~run_native:(fun _ -> Error (Peer.Unstarted "no native action in attachment test"))
      ~downloads:no_downloads ~now ~version:"fixture" ~capture_directory:(capture_directory ()) ~space:reference
      ~run:(fun ~window_s script ->
        let sent=sent_of ~window_s script in calls:=sent::!calls;
        check string "attachment sends no Page operation" "space.open" sent.step;
        reply ()) in
  let attachment id ownership ()=answered (obj ["spaceId",`Int id;"name",str "SDK Space";"ownership",str ownership]) in
  (match open_reference (Browser_configuration.Existing_space 51) (attachment 51 "agentDelegatedToUser") with
   | Ok peer -> check int "resumes the exact ID while preserving handoff" 51 (Peer.space_id peer)
   | Error detail -> fail detail);
  check bool "numeric ID stays numeric at the SDK boundary" true ((List.hd !calls).space=`Int 51);
  check bool "a mismatched SDK ID cannot replace the requested Space" true
    (Result.is_error (open_reference (Existing_space 51) (attachment 52 "agent")));
  check int "no name fallback after identity mismatch" 1 (List.length !calls);
  check bool "a missing ID is not replaced" true
    (Result.is_error (open_reference (Existing_space 51) (fun () -> failed "Space not found")));
  check int "no retry after native refusal" 1 (List.length !calls);
  check bool "a user-owned ID is not implicitly claimed" true
    (Result.is_error (open_reference (Existing_space 51) (attachment 51 "user")));
  check int "no takeover or claim follows" 1 (List.length !calls);
  check bool "invalid ID is refused before SDK entry" true
    (Result.is_error (open_reference (Existing_space (-1)) (attachment 51 "agent")));
  check int "invalid ID runs no script" 0 (List.length !calls);
  (match open_reference (Named_space "51") (attachment 74 "agent") with Ok _ -> () | Error detail -> fail detail);
  check bool "numeric-looking names remain names" true ((List.hd !calls).space=str "51")

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
  let rows=Yojson.Safe.Util.to_list first in
  check (list int) "rows retain numbered ownership" [1;2;3]
    (List.map (fun row -> Yojson.Safe.Util.(row |> member "id" |> to_int)) rows);
  check bool "native Page labels and origins reach the tab inventory" true
    (List.map (fun row -> field "egoPage" row) rows = List.map (fun (label,target,origin) ->
      obj ["label",label;"targetId",str target;"openedBy",str origin])
      [str "p1","T1","agent";`Null,"T9","unknown";str "p2","T2","agent"]);
  check string "the same pages keep their numbers" (Yojson.Safe.to_string first) (Yojson.Safe.to_string (listed ()));
  let unreadable = opened (fun _ -> answered (`List [obj ["label",`Null;"title",str "x";"url",str "y";"active",`Bool true]])) in
  ignore (before_effect "a tab without a label or target" (dispatch unreadable Live.Tabs_list (obj [])))

let test_page_provenance_survives_document_projection () =
  let module Surface=Masc.Browser_surface in
  let peer=opened (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs | other -> failf "unexpected step %s" other) in
  let rows=match dispatch peer Live.Tabs_list (obj []) with Ok rows -> rows | Error _ -> fail "no tabs" in
  let space=Peer.space peer in
  let client_id=Result.get_ok (Lane.client_id_of_string "10000000-0000-4000-8000-000000000021") in
  let selected : Masc.Browser_selection.selected = {route=Lane.Live_route (Some client_id);reason=Explicit_browser} in
  let info : Lane.client_info = {client_id;browser=Ego_lite;version="fixture";engine_version="fixture";
    transport=Ego_task_space;space=Some space} in
  let binding=Masc.Browser_binding.of_browser selected (Masc.Browser_selection.Connected info) in
  let plan=Result.get_ok (Surface.prepare_read ~tab_id:(Some 1) rows) in
  let page=obj ["url",str "https://app.slack.com/";"title",str "Slack";"text",str "observed";
    "chars",`Int 8;"truncated",`Bool false] in
  let result=match Surface.project_read plan ~binding ~started:0L ~page:(Some page) with
    | Ok value -> value | Error detail -> fail detail in
  check bool "read projection retains every observed Page context" true
    (List.map (field "egoPage") (Yojson.Safe.Util.to_list (field "tabs" result))
      =List.map (field "egoPage") (Yojson.Safe.Util.to_list rows));
  check bool "document read retains its Space binding" true
    (field "browserSpace" result=Lane.ego_space_to_json space);
  let info={info with transport=Lane.Webdriver_bidi;space=None} in
  let other=Masc.Browser_binding.of_browser selected (Masc.Browser_selection.Connected info) in
  check bool "Page provenance cannot masquerade as another transport" true
    (Result.is_error (Surface.project_read plan ~binding:other ~started:0L ~page:(Some page)));
  List.iter (fun context ->
    check bool "malformed Page context is refused" true (Result.is_error (Surface.ego_page_of_json context)))
    [obj ["label",str "p1";"targetId",str "T1";"openedBy",str "user"];
     obj ["label",str "p1";"targetId",str "T1";"openedBy",str "agent";"openedBy",str "unknown"];
     obj ["label",str "p1";"targetId",str "T1"]];
  ignore (before_effect "unmanaged tab stays protected" (dispatch peer Live.Page_read (obj ["tabId",`Int 2])))

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
  check bool "reports unmanaged status without attributing origin" true (String_util.contains_substring operator "is unmanaged");
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
  | Error (Live.Before_effect _ | Live.Observed_failure {disposition=Live.Not_started;_}) -> "before effect"
  | Error (Live.Partial_failure _) -> "partial"
  | Error (Live.Outcome_unknown _ | Live.Observed_failure {disposition=Live.Uncertain;_}) -> "unknown"

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
   | Ok receipt -> check string "the new tab" {|{"inputReadiness":"command_settled","tabId":4,"action":"open_tab","created":true,"url":"https://slack.com/","title":"Slack","active":true}|}
       (Yojson.Safe.to_string receipt)
   | Error _ -> fail "open_tab failed");
  check string "the url reaches the script" "https://slack.com/" (text (field "url" (last ()).args));
  check (float 0.) "open_tab uses the SDK-owned runner" 0. (last ()).window_s;
  reply := (fun _ -> refused "the page budget is reached");
  check string "a page ego would not create" "before effect"
    (failure_kind (dispatch peer Live.Page_act (act_args (Lane.Action.Open_tab "https://slack.com/"))));
  reply := (fun _ -> answered (obj ["label",str "p5";"error",str "page.goto failed: net::ERR_NAME_NOT_RESOLVED";
    "tab",obj ["url",str "https://nowhere.test/";"title",str "";"active",`Bool true]]));
  (match dispatch peer Live.Page_act (act_args (Lane.Action.Open_tab "https://nowhere.test/")) with
   | Error (Live.Partial_failure {tab_id; receipt; message}) ->
     check int "the created tab" 5 tab_id;
     check string "its receipt" {|{"inputReadiness":"command_settled","tabId":5,"action":"open_tab","created":true}|} (Yojson.Safe.to_string receipt);
     check bool "says not to open another" true (String_util.contains_substring message "Do not open another tab")
   | other -> failf "a failed load after creation was %s" (failure_kind other));
  reply := (fun _ -> Error Peer.Timed_out);
  (match dispatch peer Live.Page_act (act_args (Lane.Action.Open_tab "https://slack.com/")) with
   | Error (Live.Outcome_unknown detail | Live.Observed_failure {disposition=Live.Uncertain;message=detail;_}) ->
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
  reply := (fun _ -> refused "the SDK refused native navigation before acting");
  check string "a native navigation refusal remains before-effect" "before effect"
    (failure_kind (dispatch peer Live.Page_goto (obj ["tabId",`Int 3;"url",str "https://slack.com/"])));
  reply := (fun _ -> answered (obj ["error",`Null;"tab",obj ["url",str "https://slack.com/c";"title",str "Channel"]]));
  (match dispatch peer Live.Page_goto (obj ["tabId",`Int 1;"url",str "https://slack.com/c"]) with
   | Ok receipt -> check string "the move" {|{"inputReadiness":"command_settled","tabId":1,"action":"goto","url":"https://slack.com/c","title":"Channel"}|}
       (Yojson.Safe.to_string receipt)
   | Error _ -> fail "goto failed");
  check (float 0.) "goto uses the SDK-owned runner" 0. (last ()).window_s;
  (match dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Reload})) with
   | Ok _ -> () | Error _ -> fail "reload failed");
  check (float 0.) "reload uses the SDK-owned runner" 0. (last ()).window_s;
  reply := (fun _ -> answered (obj ["error",str "page.goto failed: net::ERR_UNSAFE_PORT";
    "tab",obj ["url",str "http://127.0.0.1:9/";"title",str "127.0.0.1"]]));
  (match dispatch peer Live.Page_goto (obj ["tabId",`Int 1;"url",str "http://127.0.0.1:9/"]) with
   | Error (Live.Partial_failure {tab_id; receipt; _}) ->
     check int "the moved tab" 1 tab_id;
     check string "where it is now" {|{"inputReadiness":"command_settled","tabId":1,"action":"goto","url":"http://127.0.0.1:9/","title":"127.0.0.1"}|}
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
   | Ok receipt -> check string "the close" {|{"inputReadiness":"command_settled","tabId":3,"action":"close_tab","closed":true}|} (Yojson.Safe.to_string receipt)
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
  (match interact (Lane.Click_node {document_id="d1";node_id="send"}) with
   | Ok receipt -> check string "the click"
       {|{"inputReadiness":"command_settled","tabId":1,"action":"click","urlBefore":"https://app.slack.com/","url":"https://app.slack.com/","title":"Slack","scrollX":0,"scrollY":0}|}
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
   | Error (Live.Outcome_unknown detail | Live.Observed_failure {disposition=Live.Uncertain;message=detail;_}) -> check bool "says to read the tab" true (String_util.contains_substring detail "read tab 1")
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
  (match dispatch peer ~actor:"keeper/fixture-peer" Live.Page_interact (interact_args (Lane.Click_at {point;viewport;button=Lane.Pointer.Primary})) with
   | Ok _ -> check string "an input names its actor" "MASC · keeper/fixture-peer · click_at" (text (field "cursor" (last ()).args))
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
   | Ok receipt -> check string "the fill" {|{"inputReadiness":"command_settled","tabId":1,"action":"fill","url":"https://app.slack.com/","title":"Slack"}|}
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
     Lane.Set_zoom {factor=1.5}; Lane.Set_viewport Lane.Browser_default];
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
  let drag = Lane.Drag_to {source=Lane.Selector "@12";destination=Lane.Selector "loc=css:#destination";via=[];duration_ms=0} in
  (match dispatch peer Live.Page_interact (interact_args drag) with
   | Ok receipt ->
     let sent=List.hd !asked in
     check string "native drag uses the SDK" "drag_to" (text (field "action" sent.args));
     check string "native drag source unchanged" "@12" (text (field "target" sent.args));
     check string "native drag destination unchanged" "loc=css:#destination" (text (field "destination" sent.args));
     check string "native drag receipt action" "drag_to" (text (field "action" receipt))
   | other -> failf "native drag was %s" (failure_kind other));
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
       | "unstarted" -> Error (Peer.Unstarted "no node here")
       | _ -> input_answer ())
    | "page.pointer" -> input_answer ()
    | "page.read" -> page_answer ~label:"p1" (obj ["text",str "still readable"])
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let drag duration_ms = Lane.Drag_to {source=Lane.Selector "#source";destination=Lane.Selector "#destination";
    via=[{Lane.Pointer.x=0.5;y=0.25}];duration_ms} in
  let invoke action = dispatch peer Live.Page_interact (interact_args action) in
  let count = List.length !sent in
  check string "timed movement is not emulated" "before effect" (failure_kind (invoke (drag 100)));
  check int "no script for unsupported timing" count (List.length !sent);
  mode := "refused";
  check string "guard rejects before input" "before effect" (failure_kind (invoke (drag 0)));
  mode := "unstarted";
  check string "a script that never started rejects before input" "before effect" (failure_kind (invoke (drag 0)));
  mode := "success";
  (* mouse.down, move and up answer void, so a clean run proves nothing about the button. *)
  check string "a drag after a guard refusal runs and cannot confirm the release" "unknown"
    (failure_kind (invoke (drag 0)));
  let last = List.hd !sent in
  check string "native API step" "page.drag" last.step;
  check bool "observed path is converted once to CSS pixels" true
    (field "path" last.args = `List [obj ["x",`Int 200;"y",`Int 300];
      obj ["x",`Int 400;"y",`Int 150];obj ["x",`Int 600;"y",`Int 300];
      obj ["x",`Int 600;"y",`Int 300]]);
  let count = List.length !sent in
  check string "no further input until the operator resets" "before effect"
    (failure_kind (invoke (Lane.Click "#next")));
  check int "blocked input is not run" count (List.length !sent);
  check string "reads remain available" "served"
    (failure_kind (dispatch peer Live.Page_read (obj ["tabId",`Int 1])))

(* The raw drag cannot be confirmed, but what its script saw is not dropped. *)
let test_a_raw_drag_reports_what_the_script_saw () =
  let drag = Lane.Drag {from={x=0.25;y=0.5};to_={x=0.75;y=0.5};viewport;via=[];duration_ms=0} in
  let detail_of reply =
    let peer = opened (fun sent -> match sent.step with
      | "tabs.list" -> answered tabs
      | "page.drag" -> reply
      | other -> failf "unexpected step %s" other) in
    ignore (dispatch peer Live.Tabs_list (obj []));
    match dispatch peer Live.Page_interact (interact_args drag) with
    | Error (Live.Outcome_unknown detail) -> detail
    | other -> failf "a raw drag was %s, not unknown" (failure_kind other) in
  check bool "the failure text the SDK gave is kept" true
    (String_util.contains_substring (detail_of (input_answer ~error:(str "up failed") ())) "up failed");
  let row = obj ["url",str observed_url;"title",str "Slack"] in
  let seen_with fields = detail_of (answered (obj (["guard",page_summary;"tab",row;"error",`Null] @ fields))) in
  check bool "an open dialog changes what is reported" true
    (seen_with ["dialog",ego_dialog "confirm" "sure?"] <> seen_with [])

(* dragAndDrop is the one drag whose answer the SDK declares: a receipt object,
   with a [dialog] member when a dialog interrupted it. Only a receipt object
   without [dialog] lets the next input run. *)
let test_a_target_drag_settles_only_from_the_receipt_it_returns () =
  let drag = Lane.Drag_to {source=Lane.Selector "#source";destination=Lane.Selector "#destination";via=[];duration_ms=0} in
  let tab = obj ["url",str observed_url;"title",str "Slack"] in
  let drag_reply fields = answered (obj (["urlBefore",str observed_url;"tab",tab] @ fields)) in
  let failed_after_start = Ok (Peer.result_marker ^ Yojson.Safe.to_string (obj ["ok",`Bool false;"error",str "native failed"]) ^ "\n") in
  List.iter (fun (name, reply, first, settles) ->
    let asked = ref [] in
    let peer = opened (fun sent ->
      asked := sent.step :: !asked;
      match sent.step with
      | "tabs.list" -> answered tabs
      | "page.target_input" -> reply
      | other -> failf "%s unexpectedly dispatched %s" name other) in
    ignore (dispatch peer Live.Tabs_list (obj []));
    check string (name ^ " answers the drag") first
      (failure_kind (dispatch peer Live.Page_interact (interact_args drag)));
    let before = List.length !asked in
    let next = failure_kind (dispatch peer Live.Page_interact (interact_args drag)) in
    if settles then check int (name ^ " lets the next input run") (before + 1) (List.length !asked)
    else begin
      check string (name ^ " keeps input blocked") "before effect" next;
      check int (name ^ " runs no script for the blocked input") before (List.length !asked)
    end)
    [ "a receipt object", drag_reply ["receipt",obj [];"error",`Null], "served", true;
      "a receipt that names a dialog", drag_reply ["receipt",obj ["dialog",ego_dialog "confirm" "sure?"];"error",`Null], "served", false;
      "a void receipt", drag_reply ["receipt",`Null;"error",`Null], "unknown", false;
      "a missing receipt", drag_reply ["error",`Null], "unknown", false;
      "a receipt that is not an object", drag_reply ["receipt",str "done";"error",`Null], "unknown", false;
      "a caught failure", drag_reply ["receipt",obj [];"error",str "native drag interrupted"], "unknown", false;
      "a lost answer", Error (Peer.Unobserved "lost"), "unknown", false;
      "a timed out answer", Error Peer.Timed_out, "unknown", false;
      "a script failure after the start", failed_after_start, "unknown", false;
      "an unreadable answer", Ok "no answer line", "unknown", false;
      (* One reply read by one rule: whatever the call cannot read whole settles nothing. *)
      "a receipt with a member the SDK does not declare", drag_reply ["receipt",obj ["error",str "boom";"ok",`Bool false];"error",`Null], "unknown", false;
      "a null dialog", drag_reply ["receipt",obj ["dialog",`Null];"error",`Null], "unknown", false;
      "a popup without its targetId", drag_reply ["receipt",obj ["popups",`List [obj ["label",str "p2"]]];"error",`Null], "unknown", false;
      "a popup without its label", drag_reply ["receipt",obj ["popups",`List [obj ["label",str "";"targetId",str "T2"]]];"error",`Null], "unknown", false;
      "a popup with an empty targetId", drag_reply ["receipt",obj ["popups",`List [obj ["label",str "p2";"targetId",str ""]]];"error",`Null], "unknown", false;
      "a popup with a member the SDK does not declare", drag_reply ["receipt",obj ["popups",`List [obj ["label",str "p2";"targetId",str "T2";"url",str observed_url]]];"error",`Null], "unknown", false;
      "a receipt with one declared popup", drag_reply ["receipt",obj ["popups",`List [obj ["label",str "p2";"targetId",str "T2"]]];"error",`Null], "served", true;
      "a reply without its starting URL", answered (obj ["receipt",obj [];"error",`Null;"tab",tab]), "unknown", false;
      "a reply without its tab", answered (obj ["urlBefore",str observed_url;"receipt",obj [];"error",`Null]), "unknown", false;
      "a refusal before the drag", refused "observed_url_changed", "before effect", true;
      "a script that never started", Error (Peer.Unstarted "no node here"), "before effect", true ]

let test_chooser_upload_respects_uncertain_pointer_release () =
  let directory = Unix.realpath (capture_directory ()) in
  let path = Filename.concat directory "owned-upload.txt" in
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel "fixture");
  let raw_drag = Lane.Drag {from={x=0.25;y=0.5};to_={x=0.75;y=0.5};viewport;via=[];duration_ms=0} in
  let native_drag = Lane.Drag_to {source=Lane.Selector "#source";destination=Lane.Selector "#destination";via=[];duration_ms=0} in
  List.iter (fun (name, drag) ->
    let asked = ref [] in
    let peer = opened (fun sent ->
      asked := sent.step :: !asked;
      match sent.step with
      | "tabs.list" -> answered tabs
      | "page.drag" -> input_answer ()
      | "page.target_input" -> answered (obj ["error",str "input release unconfirmed"])
      | "page.upload" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null])
      | other -> failf "%s unexpectedly dispatched %s" name other) in
    ignore (dispatch peer Live.Tabs_list (obj []));
    check string (name ^ " leaves release uncertain") "unknown"
      (failure_kind (dispatch peer Live.Page_interact (interact_args drag)));
    let upload target = dispatch peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target;paths=[path]}})) in
    let before = List.length !asked in
    check bool (name ^ " blocks chooser upload before its click") true
      (String_util.contains_substring
        (before_effect "chooser upload after uncertain release" (upload (Lane.Action.Chooser_opener "#attach")))
        "input release is unconfirmed");
    check int (name ^ " dispatches no chooser SDK script") before (List.length !asked);
    check string (name ^ " permits upload without pointer input") "served"
      (failure_kind (upload (Lane.Action.File_input "#file")));
    check string (name ^ " delegates file-input upload to SDK") "page.upload" (List.hd !asked)
  ) ["raw drag", raw_drag; "native drag", native_drag]

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
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered tabs
    | "page.capture" ->
      let path = text (field "path" sent.args) in
      Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel png);
      answered (obj ["label",str "p1";"path",str path;"before",state ~url:"u" ~width:1;"after",state ~url:"u" ~width:1])
    | "space.finish" -> answered (obj ["spaceId",`Int 51;"closedSpace",`Bool true;
        "keptManagedLabels",`List [];"closedManagedLabels",`List [];"preservedUnmanagedCount",`Int 0])
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
    | "page.upload" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null])
    | "page.choose_files" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null])
    | _ -> page_answer ~label:"p1" (obj ["url",str "u"]) in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory:directory with
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
      Live.Page_interact, interact_args (Lane.Fill_node {target={document_id="d1";node_id="message"};text="hi"});
      Live.Page_interact, interact_args (Lane.Fill_target {target=Lane.Target_ref 5;text="hi"});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=3;frame_path=[];interaction=Lane.Action.Close_tab});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Reload});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Back});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Accept_dialog (Some "hi")});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Dismiss_dialog});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.File_input "#file";paths=[upload_file]}});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.Chooser_opener "#attach";paths=[upload_file]}});
      (* Last: a raw drag cannot confirm the release, so it blocks the input that follows it. *)
      Live.Page_interact, interact_args (Lane.Drag {from={x=0.25;y=0.5};to_={x=0.75;y=0.5};viewport;via=[];duration_ms=0}) ];
  check (result unit string) "finish" (Ok ()) (Peer.finish peer);
  check (list string) "every step"
    ["space.open";"tabs.list";"page.read";"page.elements";"page.scene";"page.snapshot";"page.downloads";"page.capture";
     "page.open";"page.goto";"page.target";"page.pointer";"page.pointer";"page.pointer";"page.keyboard";"page.input";"page.target_input";
     "page.close";"page.reload";"page.history";"page.dialog";"page.dialog";"page.upload";"page.choose_files";"page.drag";"space.finish"]
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
  let drag_ran = ref false in
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
    | "page.native_workflow" -> answered (obj ["completed",`List [];"effectStarted",`Bool false;
        "completedEffect",`Bool false;"inputReleased",`Bool true;"failure",`Null;"urlBefore",str "https://app.slack.com/";"url",str "https://app.slack.com/";"title",str "Slack";
        "snapshot",str "root";"truncated",`Bool false;"chars",`Int 4])
    | "page.snapshot" -> answered (obj ["label",str "p1";"url",str "https://app.slack.com/";"title",str "Slack";
        "snapshot",str "root";"truncated",`Bool false;"chars",`Int 4])
    | "page.target_input" -> answered (obj ["urlBefore",str "https://app.slack.com/";"receipt",obj [];"error",`Null;
        "tab",obj ["url",str "https://app.slack.com/";"title",str "Slack"]])
    | "page.activate" -> answered (obj ["spaceId",`Int 51;"label",str "p1";"targetId",str "T1";
        "urlBefore",str "https://app.slack.com/";"url",str "https://app.slack.com/";"title",str "Slack";
        "active",`Bool true;"window",obj ["windowId",`Int 7;"stateBefore",str "normal";"stateAfter",str "normal";"restored",`Bool false]])
    | "page.open" -> answered (obj ["label",str "p4";"error",`Null;"tab",obj ["url",str "https://example.test/new";"title",str "New";"active",`Bool true]])
    | "page.goto" | "page.history" -> answered (obj ["error",`Null;"tab",obj ["url",str "https://example.test/next";"title",str "Next"]])
    | "page.close" -> answered (obj ["closed",`Bool true])
    | "page.dialog" -> answered (obj ["dialog",ego_dialog "alert" "hello"])
    | "space.hand_off" -> answered (obj ["spaceId",`Int 51;"spaceName",str "masc"])
    | "space.adopt_tab" -> answered (obj ["label",str "adopted";"targetId",str "T9";"openedBy",str "unknown"])
    | "page.downloads" -> answered (obj ["since",`Null;"rows",`List []])
    | "page.upload" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null])
    | "page.target" -> answered resolved
    | "page.drag" -> drag_ran := true; input_answer ()
    | "page.pointer" | "page.keyboard" -> input_answer ()
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
    | Viewport_capture -> Page_capture {tab_id=1;options=None}
    | Scene_read -> Page_scene {tab_id=1; max_chars=1000; view=Content; scope=None}
    | Accessibility_snapshot -> Page_snapshot {tab_id=1; max_chars=1000; scope=Snapshot_viewport}
    | Native_workflow ->
      (match Native_workflow.of_json (`Assoc ["tabId",`Int 1;"expectedUrl",`String "https://app.slack.com/";
        "steps",`List [];"maxChars",`Int 1000]) with
       | Ok request -> Page_native_workflow request | Error detail -> fail detail)
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
    | Page_management -> Page_act (Action.Control (Action.Adopt_tab {tab_id=2;label=None}))
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
    (* ego's mouse calls answer void, so a served raw drag always ends unknown. *)
    | Error (Live.Outcome_unknown _), true when capability = Lane.Trusted_drag && !drag_ran -> ()
    | Ok _, false -> failf "the peer served %s, which the lane table says ego does not" name
    | Error (Live.Before_effect detail), true | Error (Live.Outcome_unknown detail | Live.Observed_failure {message=detail;_} | Live.Partial_failure {message=detail;_}), _ ->
      failf "the peer did not serve %s (%s), which the lane table says ego does" name detail)
    (* The raw drag goes last: it cannot confirm the release, so it blocks the input after it. *)
    (List.filter (fun capability -> capability <> Lane.Trusted_drag) Lane.all_of_live_capability @ [Lane.Trusted_drag])

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
  tabs: async () => [{label: "p1", targetId: "T1", openedBy: "agent", url: entries[current].url, title: entries[current].title}],
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

let test_native_activation_keeps_space_authority () =
  let owner=ref "agent" and runner_failure=ref false and native_calls=ref 0 and output=ref "" in
  let run ~window_s script = match (sent_of ~window_s script).step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered tabs
    | other -> failf "activation must use native execution, got %s" other in
  let run_native script =
    incr native_calls;
    check string "one native activation" "page.activate" (sent_of ~window_s:0. script).step;
    if !runner_failure then Error (Peer.Unobserved "activation receipt lost") else
    let shim=Printf.sprintf {js|
const calls=[];let active=false;
process.on('exit',()=>console.log('native-calls '+JSON.stringify(calls)));
const taskSpace=async()=>({spaceId:51,ownership:%s,
 tabs:async()=>[{label:'p1',targetId:'T1',openedBy:'agent',url:'https://app.slack.com/',title:'Slack',active}],
 cdp:async(method,params)=>{
  calls.push(method);
  if(params.targetId!=='T1')throw Error('foreign target');
  if(method==='Browser.getWindowForTarget')return {windowId:7,bounds:{windowState:'normal'}};
  if(method==='Target.activateTarget'){active=true;return {};}
  throw Error('unexpected native command');
 }});
|js} (Yojson.Safe.to_string (str !owner)) in
    output:=in_node (shim^script);Ok !output in
  let peer=match Peer.open_space ~downloads:no_downloads ~run ~run_native ~now
      ~space:(Browser_configuration.Named_space "masc") ~version:"fixture" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore(dispatch peer Live.Tabs_list (obj []));
  let activate ()=dispatch peer Live.Page_interact (interact_args Lane.Activate_tab) in
  (match activate () with
   | Ok value -> check bool "native activation names the original tab" true
       (field "tabId" value=`Int 1 && field "active" value=`Bool true && field "spaceId" value=`Int 51)
   | Error _ -> fail "native activation failed");
  owner:="agentDelegatedToUser";
  check string "a delegated Space refuses before activation" "before effect" (failure_kind (activate ()));
  check bool "delegated owner performs no native target/window calls" true
    (List.mem "native-calls []" (String.split_on_char '\n' !output));
  owner:="agent";runner_failure:=true;
  check string "lost activation stays uncertain" "unknown" (failure_kind (activate ()));
  check int "one native execution per caller command" 3 !native_calls

(* Execute the generated capture script against a Page stand-in, including its
   actual screenshot call and file write. This proves the adapter boundary,
   not the installed SDK's rendering or a real browser's pixels. *)
let test_native_capture_options_and_owned_file () =
  let directory = capture_directory () in
  let expected = ref (obj []) and image = ref png and echo = ref None in
  let written = ref [] in
  let observed_state = state ~url:"https://app.slack.com/" ~width:800 in
  let run ~window_s script =
    match (sent_of ~window_s script).step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered tabs
    | other -> failf "capture must use the native runner, got bounded step %s" other in
  let run_native script =
    let sent = sent_of ~window_s:0. script in
    check string "native capture step" "page.capture" sent.step;
    check bool "exact native arguments" true (field "options" sent.args = !expected);
    let path = text (field "path" sent.args) in
    check string "broker owns the output directory" directory (Filename.dirname path);
    written := path :: !written;
    let stand_in = Printf.sprintf {js|
import {writeFileSync} from 'node:fs';
const page = {
  info: async () => ({url: 'https://app.slack.com/'}),
  evaluate: async () => (%s),
  screenshot: async options => {
    console.log('capture-options ' + JSON.stringify(options));
    writeFileSync(options.path, Buffer.from(%s, 'base64'));
    return options.path;
  },
};
const taskSpace = async () => ({ownership: 'agent',
  tabs: async () => [{label:'p1', targetId:'T1', openedBy:'agent'}], page: () => page});
|js} (Yojson.Safe.to_string observed_state)
      (Yojson.Safe.to_string (str (Base64.encode_string !image))) in
    let output = in_node (stand_in ^ script) in
    let screenshot_options = match List.find_opt (String.starts_with ~prefix:"capture-options ")
        (String.split_on_char '\n' output) with
      | Some line -> Yojson.Safe.from_string (after ~prefix:"capture-options " line)
      | None -> fail "the native Page.screenshot method was not called" in
    let screenshot_fields = match screenshot_options with `Assoc fields -> fields | _ -> fail "options must be an object" in
    check string "Page.screenshot receives the host path" path (text (field "path" screenshot_options));
    (* JSON.stringify prints integral coordinates without a decimal point. The
       strict native codec compares their values and still rejects extra fields. *)
    check bool "Page.screenshot receives exactly the native options" true
      (Lane.Capture.of_json (obj (List.remove_assoc "path" screenshot_fields)) = Lane.Capture.of_json !expected);
    match !echo with
    | None -> Ok output
    | Some options -> answered (obj ["label",str "p1";"path",str path;
        "before",observed_state;"after",observed_state;"captureOptions",options]) in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native ~now
      ~space:(Browser_configuration.Named_space "masc") ~version:"fixture" ~capture_directory:directory with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let capture () = dispatch peer Live.Page_capture (obj ["tabId",`Int 1;"options",!expected]) in
  let removed () = check bool "only owned capture files are consumed" true
      (List.for_all (fun path -> not (Sys.file_exists path)) !written) in
  List.iter (fun options ->
    expected := options;
    (match capture () with
     | Ok reply ->
       check bool "native receipt retains the exact requested options" true (field "captureOptions" reply = options);
       check string "native PNG bytes" (Base64.encode_string png) (text (field "data" reply));
       (match reply with
        | `Assoc fields -> check bool "native capture has no pointer viewport" false (List.mem_assoc "viewport" fields)
        | _ -> fail "capture did not return an object")
     | Error _ -> fail "native capture failed");
    removed ()) [obj []; obj ["fullPage",`Bool true;"scale",str "css";"raw",`Bool false];
      obj ["fullPage",`Bool false;"clip",obj ["x",`Float 4.5;"y",`Float 8.;
        "width",`Float 100.;"height",`Float 90.;"scale",`Float 2.];"raw",`Bool true]];
  echo := Some (obj []);
  check string "a different native option receipt is rejected" "ego answered different native screenshot options"
    (before_effect "mismatched capture options" (capture ()));
  removed ();
  echo := None;
  image := png ^ String.make (Masc.Keeper_vision_tool.max_image_bytes ()) '\000';
  check string "Vision's configured image boundary applies before publication" "screenshot exceeds Vision image size limit"
    (before_effect "oversized native PNG" (capture ()));
  removed ()

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
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered tabs
    | "page.snapshot" ->
      asked := sent :: !asked;
      output := in_node (snapshot_stand_in !text ^ script);
      Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let snapshot ?(tab_id=1) ?(max_chars=1000) scope =
    dispatch peer Live.Page_snapshot
      (Yojson.Safe.Util.member "args" (Lane.verb_json (Lane.Page_snapshot {tab_id;max_chars;scope}))) in
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.to_string (Yojson.Safe.from_string (after ~prefix:"seen " line))
    | None -> fail "the stand-in did not say what it saw" in
  let expected ~scope ~snapshot ~truncated ~chars = Yojson.Safe.to_string (obj (
    ["inputReadiness",str "command_settled";"tabId",`Int 1;"url",str "https://app.slack.com/";"title",str "Slack"] @ scope
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
    (contains (refused "operator tab" (snapshot ~tab_id:2 Lane.Snapshot_viewport)) "is unmanaged");
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
  tabs: async () => [{label: "p1", targetId: "T1", openedBy: "agent", url: currentUrl, title: "Slack"}],
  page: () => page,
});
|js} (Yojson.Safe.to_string (`String url)) blocked act act act act

let test_a_snapshot_target_is_found_by_ego_and_checked_first () =
  let url = ref observed_url and blocked = ref false and act = ref "return {};" in
  let asked = ref [] and output = ref "" in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered tabs
    | "page.target_input" ->
      asked := sent :: !asked;
      output := in_node (target_stand_in ~url:!url ~blocked:!blocked ~act:!act ^ script);
      Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
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
    (Yojson.Safe.to_string (obj ["inputReadiness",str "command_settled";"tabId",`Int 1;"action",str "click";"target",obj ["ref",`Int 12];
      "urlBefore",str observed_url;"url",str observed_url;"title",str "Slack"]))
    (answer "ref click" (click (Lane.Target_ref 12)));
  check string "the dialog and URL checks come before native input" {|["info","url","click @12"]|} (seen ());
  check string "ego's click carries the cursor label" {|["MASC · agent · click"]|} (printed "labels ");
  ignore (answer "named click" (on ~actor:"keeper/fixture-peer" (Lane.Click_target (Lane.Target_ref 12))));
  check string "and names the actor" {|["MASC · keeper/fixture-peer · click"]|} (printed "labels ");
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
   | Error (Live.Outcome_unknown detail | Live.Observed_failure {disposition=Live.Uncertain;message=detail;_}) -> check bool "native ambiguity is uncertain" true (contains detail "matched 2 elements")
   | other -> failf "native ambiguity was %s" (failure_kind other));
  act := {|throw new Error("Target closed");|};
  (match click (Lane.Target_ref 12) with
   | Error (Live.Outcome_unknown detail | Live.Observed_failure {disposition=Live.Uncertain;message=detail;_}) -> check bool "a failed click is unknown and asks for a read" true (contains detail "read tab 1")
   | other -> failf "a failed click was %s" (failure_kind other));
  check int "each of them was one run" (runs + 4) (List.length !asked);
  let before = List.length !asked in
  check bool "an operator tab is refused without a run" true
    (match dispatch peer Live.Page_interact (interact_args ~tab_id:2 (Lane.Click_target (Lane.Target_ref 1))) with
     | Error (Live.Before_effect _) -> true | Ok _ | Error (Live.Partial_failure _ | Live.Outcome_unknown _ | Live.Observed_failure _) -> false);
  check int "no script ran for it" before (List.length !asked)

(* A stand-in for ego's hand-off: a space whose owner the case sets, and
   handOff, takeOverTaskSpace and the space's tab list that record each call. *)
let control_stand_in ~ownership ~user_page = Printf.sprintf {js|
const seen = [];
process.on("exit", () => console.log("seen " + JSON.stringify(seen)));
const taskSpace = async space => ({
  spaceId: space,
  name: "MASC login",
  ownership: %s,
  tabs: async () => { seen.push("tabs"); return [{label: "p1", targetId: "T1", openedBy: "agent", url: "https://app.slack.com/", title: "Slack", active: true}]; },
  page: () => ({info: async () => ({url: "https://app.slack.com/"})}),
  handOff: async () => { seen.push("handOff"); },
});
const takeOverTaskSpace = async id => { seen.push("takeOver " + id); return {
 spaceId:id,name:"MASC login",ownership:"agent",userPage:()=>%s,
 tabs:async()=>{seen.push("tabs");return [
  {label:"p2",targetId:"T2",openedBy:"agent",active:false},
  {label:null,targetId:"TU",openedBy:"unknown",active:false},
  {label:"p1",targetId:"T1",openedBy:"agent",active:true}];}}; };
|js} (Yojson.Safe.to_string (str ownership)) user_page

let test_native_space_control_wait () =
  let ownership=ref "agent" and native_failure=ref false and calls=ref 0 and output=ref "" in
  let run ~window_s script =
    let sent=sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered tabs
    | "space.wait_for_control" ->
      check (float 0.) "wait uses the native runner rather than a host clock" 0. sent.window_s;
      incr calls;
      let shim=Printf.sprintf {js|
const seen=[];
process.on('exit',()=>console.log('seen '+JSON.stringify(seen)));
const forbidden=name=>{seen.push(name);throw new Error('unexpected '+name);};
const takeOverTaskSpace=async()=>forbidden('takeOver');
const claimTaskSpace=async()=>forbidden('claim');
const taskSpace=async id=>({spaceId:id,name:'SDK Space',ownership:%s,
  page:()=>forbidden('page'),tabs:async()=>forbidden('tabs'),
  waitForControl:async options=>{seen.push(options);%s}});
|js} (Yojson.Safe.to_string (str !ownership))
        (if !native_failure then "throw new Error('SDK control wait timed out');" else "") in
      output:=in_node (shim ^ script);Ok !output
    | "page.target_input" -> answered (obj ["urlBefore",str observed_url;
        "receipt",obj [];"error",str "native drag interrupted";"tab",obj ["url",str observed_url;"title",str "Slack"]])
    | other -> failf "unexpected control wait step %s" other in
  let peer=match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now
      ~space:(Browser_configuration.Named_space "masc") ~version:"fixture" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  let wait options=dispatch peer Live.Page_act (obj ["action",str "wait_for_control";"controlOptions",options]) in
  let seen ()=match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.from_string (after ~prefix:"seen " line)
    | None -> fail "native stand-in emitted no calls" in
  let reply_ms=Lane.reply_timeout_sec (Lane.Page_act (Lane.Action.Control
    (Lane.Action.Wait_for_control {Lane.Action.interval_ms=None;timeout_ms=None}))) *. 1000. in
  ignore (before_effect "a timeout as long as the Keeper's whole wait is refused"
    (wait (obj ["timeout",`Float reply_ms])));
  check int "a refused timeout starts no native wait" 0 !calls;
  let options=obj ["interval",`Float 0.5;"timeout",`Float 30000.] in
  (match wait options with
   | Ok value -> check bool "wait observation names the same Space" true
       (value=obj ["inputReadiness",str "command_settled";"action",str "wait_for_control";"spaceId",`Int 51;"spaceName",str "SDK Space";"controlAvailable",`Bool true])
   | Error _ -> fail "native control wait failed");
  check bool "options inside the window reach the SDK unchanged" true
    (seen ()=`List [obj ["interval",`Float 0.5;"timeout",`Int 30000]]);
  native_failure:=true;
  ignore (before_effect "SDK wait timeout sends no input" (wait (obj [])));
  let window_ms=match seen () with
    | `List [`Assoc ["timeout",`Int ms]] -> ms
    | other -> failf "an omitted timeout reaches the SDK as one timeout, got %s" (Yojson.Safe.to_string other) in
  check bool "the omitted timeout fits inside the Keeper's wait" true
    (window_ms > 0 && float_of_int window_ms < reply_ms);
  native_failure:=false;
  (match wait (obj ["timeout",`Int window_ms]) with
   | Ok _ -> ()
   | Error _ -> fail "a timeout equal to the reply window is accepted");
  native_failure:=false;ownership:="agentDelegatedToUser";
  ignore (before_effect "a user-held Space cannot be reclaimed by waiting" (wait (obj [])));
  check bool "user-held Space runs no native wait or page call" true (seen ()=`List []);
  ownership:="agent";
  ignore (dispatch peer Live.Tabs_list (obj []));
  let drag=Lane.Drag_to {source=Lane.Selector "@12";destination=Lane.Selector "#target";via=[];duration_ms=0} in
  check string "drag first leaves input unconfirmed" "unknown"
    (failure_kind (dispatch peer Live.Page_interact (interact_args drag)));
  (match wait (obj []) with Ok _ -> () | Error _ -> fail "control observation was refused after uncertain input");
  let before= !calls in
  ignore (before_effect "availability cannot clear uncertain input" (dispatch peer Live.Page_interact (interact_args (Lane.Click "#send"))));
  check int "no later native input was dispatched" before !calls

let test_native_page_management () =
  let ownership=ref "agent" and label=ref `Null and sdk_failure=ref false and native_calls=ref 0 and output=ref "" in
  let run ~window_s script =
    let sent=sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered (`List [tab_row ~origin:"unknown" ~label:!label ~target:"T9" ~title:"Mail" ~url:"https://mail.example/" ~active:true ()])
    | "space.adopt_tab"|"space.release_tab" ->
      check (float 0.) "SDK management uses the native runner" 0. sent.window_s;
      incr native_calls;
      let shim=Printf.sprintf {js|
const seen=[];
process.on('exit',()=>console.log('seen '+JSON.stringify(seen)));
const handle={targetId:'T9',openedBy:'unknown'};
const taskSpace=async id=>({spaceId:id,name:'SDK Space',ownership:%s,
  tabs:async()=>{seen.push('tabs');return [{label:%s,targetId:'T9',openedBy:'unknown',page:handle}];},
  adopt:async(page,options)=>{if(page!==handle)throw Error('not the SDK handle');seen.push('adopt');%s return {label:options.as??'generated',targetId:'T9',openedBy:'unknown'};},
  release:async label=>{seen.push('release');%s return handle;}});
|js} (Yojson.Safe.to_string (str !ownership)) (Yojson.Safe.to_string !label)
        (if !sdk_failure then "throw Error('SDK result lost');" else "")
        (if !sdk_failure then "throw Error('SDK result lost');" else "") in
      output:=in_node (shim ^ script);Ok !output
    | "page.read" -> page_answer ~label:"borrowed" (obj ["url",str "https://mail.example/";"title",str "Mail"])
    | "page.target_input" -> answered (obj ["urlBefore",str "https://mail.example/";
        "receipt",obj [];"error",str "native drag interrupted";"tab",obj ["url",str "https://mail.example/";"title",str "Mail"]])
    | other -> failf "unexpected Page management step %s" other in
  let peer=match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now
      ~space:(Browser_configuration.Named_space "masc") ~version:"fixture" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  let act control=dispatch peer Live.Page_act (act_args (Lane.Action.Control control)) in
  let adopt=Lane.Action.Adopt_tab {tab_id=1;label=Some "borrowed"} and release=Lane.Action.Release_tab 1 in
  let seen ()=match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.from_string (after ~prefix:"seen " line)
    | None -> fail "native stand-in emitted no calls" in
  ignore (dispatch peer Live.Tabs_list (obj []));
  ownership:="agentDelegatedToUser";
  ignore (before_effect "a user-held Space is not adopted" (act adopt));
  check bool "no tabs or SDK lifecycle call under user control" true (seen ()=`List []);
  ownership:="agent";
  (match act adopt with
   | Ok receipt -> check bool "adoption retains tab identity and origin" true
       (field "tabId" receipt=`Int 1 && field "spaceId" receipt=`Int 51
        && field "egoPage" receipt=obj ["label",str "borrowed";"targetId",str "T9";"openedBy",str "unknown"])
   | Error _ -> fail "adoption failed");
  check bool "one SDK adoption after observing tabs" true (seen ()=`List [str "tabs";str "adopt"]);
  label:=str "borrowed";
  (match dispatch peer Live.Page_read (obj ["tabId",`Int 1]) with Ok _ -> () | Error _ -> fail "adopted Page was not readable");
  let before= !native_calls in
  ignore (before_effect "an adopted tab cannot be re-adopted" (act adopt));
  check int "repeat did not reach SDK" before !native_calls;
  ownership:="agentDelegatedToUser";
  ignore (before_effect "a user-held Space is not released" (act release));
  check bool "user-held release has no SDK calls" true (seen ()=`List []);
  ownership:="agent";sdk_failure:=true;
  check string "a lost release reply is uncertain" "unknown" (failure_kind (act release));
  sdk_failure:=false;
  ignore (dispatch peer Live.Tabs_list (obj []));
  (match act release with
   | Ok receipt -> check bool "release retains unknown origin and the same target" true
       (field "tabId" receipt=`Int 1 && field "egoPage" receipt=obj ["label",`Null;"targetId",str "T9";"openedBy",str "unknown"])
   | Error _ -> fail "release failed");
  ignore (before_effect "a released tab is no longer readable" (dispatch peer Live.Page_read (obj ["tabId",`Int 1])));
  ignore (before_effect "a released tab cannot be released again" (act release));
  label:=`Null;
  ignore (dispatch peer Live.Tabs_list (obj []));
  sdk_failure:=true;
  check string "a lost adoption reply is uncertain" "unknown" (failure_kind (act adopt));
  sdk_failure:=false;
  (* Retain the original uncertainty; management cannot act as input recovery. *)
  label:=str "borrowed";
  ignore (dispatch peer Live.Tabs_list (obj []));
  let drag=Lane.Drag_to {source=Lane.Selector "@12";destination=Lane.Selector "#target";via=[];duration_ms=0} in
  check string "an interrupted input remains uncertain" "unknown"
    (failure_kind (dispatch peer Live.Page_interact (interact_args ~tab_id:2 drag)));
  let before= !native_calls in
  ignore (before_effect "management cannot clear uncertain input" (act (Lane.Action.Release_tab 2)));
  check int "uncertain input never dispatches a lifecycle call" before !native_calls

let test_adopted_managed_page_uses_native_actions_without_changing_origin () =
  let owner=ref "agent" and label=ref `Null and url=ref "https://fixture.test/mail"
  and closed=ref false and lost=ref false and calls=ref [] and scripts=ref 0 and used_labels=ref [] in
  let run ~window_s:_ script =
    incr scripts;
    let shim=Printf.sprintf {js|
let label=%s,url=%s,closed=%s,ownership=%s,lost=%s,active=false;
const usedLabels=new Set(%s);
const seen=[];
process.on('exit',()=>console.log('adopted-state '+JSON.stringify({label,url,closed,seen,usedLabels:[...usedLabels]})));
const handle={targetId:'T9',openedBy:'unknown'};
const page={
 url:async()=>url,title:async()=> 'Mail',info:async()=>({url,title:'Mail',dialog:null}),
 waitForEvent:()=>new Promise(()=>{}),snapshot:async()=> 'root',
 goto:async next=>{seen.push('goto');url=next;return {};},
 fill:async(selector,text)=>{if(selector!=='#editor'||text!=='changed')throw Error('native fill arguments changed');seen.push('fill');return {};},
 click:async selector=>{if(selector!=='#submit')throw Error('native click selector changed');seen.push('click');if(lost)throw Error('native click result lost');return {};},
 close:async()=>{seen.push('close');closed=true;}
};
const taskSpace=async reference=>{
 if(reference!==51&&reference!=='masc')throw Error('wrong original Space');
 return {spaceId:51,name:'SDK Space',ownership,
  tabs:async()=>{seen.push('tabs');return closed?[]:[{label,targetId:'T9',openedBy:'unknown',url,title:'Mail',active,page:handle}];},
  page:requested=>{if(label===null||requested!==label||closed)throw Error('not a managed Page');seen.push('page');return page;},
  adopt:async(original,options)=>{if(original!==handle||label!==null)throw Error('wrong adopt handle');seen.push('adopt');
   if(usedLabels.has(options.as))throw Error('Page label already used in this Space');
   usedLabels.add(options.as);label=options.as;return {...handle,label};},
  release:async requested=>{if(requested!==label)throw Error('wrong release label');seen.push('release');label=null;return {...handle,label};},
  cdp:async(method,args)=>{
   if(args.targetId!=='T9')throw Error('foreign activation target');
   if(method==='Browser.getWindowForTarget')return {windowId:7,bounds:{windowState:'normal'}};
   if(method==='Target.activateTarget'){seen.push('activate');active=true;return {};}
   throw Error('unexpected CDP command');
  }};
};
|js} (Yojson.Safe.to_string !label) (Yojson.Safe.to_string (str !url))
      (string_of_bool !closed) (Yojson.Safe.to_string (str !owner)) (string_of_bool !lost)
      (Yojson.Safe.to_string (`List (List.map str !used_labels))) in
    let output=in_node (shim^script) in
    let state=match List.find_opt (String.starts_with ~prefix:"adopted-state ") (String.split_on_char '\n' output) with
      | Some line->Yojson.Safe.from_string (after ~prefix:"adopted-state " line)
      | None->fail "native Page fixture emitted no state" in
    label:=field "label" state;url:=text (field "url" state);
    closed:=Yojson.Safe.Util.to_bool (field "closed" state);
    used_labels:=List.map text (Yojson.Safe.Util.to_list (field "usedLabels" state));
    calls:=List.map text (Yojson.Safe.Util.to_list (field "seen" state));
    Ok output in
  let open_peer ()=match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now
      ~space:(Browser_configuration.Named_space "masc") ~version:"fixture" ~capture_directory:(capture_directory ()) with
    | Ok peer->peer | Error detail->fail detail in
  let served label=function Ok value->value|other->failf "%s was %s" label (failure_kind other) in
  let peer=open_peer () in
  ignore (served "list original unmanaged Page" (dispatch peer Live.Tabs_list (obj [])));
  let control peer action=dispatch peer Live.Page_act (act_args (Lane.Action.Control action)) in
  let interact peer action=dispatch peer Live.Page_interact
    (field "args" (Lane.verb_json (Lane.Page_interact {tab_id=1;frame_path=[];expected_url=Some !url;action}))) in
  let workflow peer=dispatch peer Live.Page_native_workflow (obj ["tabId",`Int 1;"expectedUrl",str !url;"maxChars",`Int 100;
    "steps",`List [obj ["method",str "click";"selector",str "#submit"]]]) in
  let close peer=dispatch peer Live.Page_act
    (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Close_tab})) in
  let effects peer=[(fun ()->dispatch peer Live.Page_goto (obj ["tabId",`Int 1;"url",str "https://fixture.test/moved"]));
    (fun ()->interact peer (Lane.Fill {selector="#editor";text="changed"}));
    (fun ()->workflow peer);(fun ()->interact peer Lane.Activate_tab);(fun ()->close peer)] in
  let before= !scripts in
  List.iter (fun action->ignore (before_effect "unmanaged Page effect" (action ()))) (effects peer);
  check int "unmanaged Page effects run no SDK wrapper" before !scripts;
  let adopted=served "explicit native adoption" (control peer (Lane.Action.Adopt_tab {tab_id=1;label=Some "borrowed"})) in
  check bool "adoption retains original target and unknown origin" true
    (field "egoPage" adopted=obj ["label",str "borrowed";"targetId",str "T9";"openedBy",str "unknown"]);
  check bool "explicit adoption used the SDK handle" true (List.mem "adopt" !calls);
  List.iter (fun (name,action)->
    ignore (served name (action ()));
    check bool ("managed unknown origin reaches native "^name) true (List.mem name !calls))
    ["goto",(fun ()->dispatch peer Live.Page_goto (obj ["tabId",`Int 1;"url",str "https://fixture.test/moved"]));
     "fill",(fun ()->interact peer (Lane.Fill {selector="#editor";text="changed"}));
     "click",(fun ()->workflow peer);"activate",(fun ()->interact peer Lane.Activate_tab)];
  owner:="agentDelegatedToUser";
  List.iter (fun action->ignore (before_effect "delegated Space blocks managed Page effects" (action ()));
    check (list string) "delegated control runs no SDK Page or CDP effects" [] !calls) (effects peer);
  owner:="agent";
  let released=served "native release after Page actions" (control peer (Lane.Action.Release_tab 1)) in
  check bool "release never changes origin" true
    (field "egoPage" released=obj ["label",`Null;"targetId",str "T9";"openedBy",str "unknown"]);
  let before= !scripts in
  List.iter (fun action->ignore (before_effect "released Page effect" (action ()))) (effects peer);
  check int "released Page effects run no SDK wrapper" before !scripts;
  check string "the SDK rejects reuse of a released Page label" "unknown"
    (failure_kind (control peer (Lane.Action.Adopt_tab {tab_id=1;label=Some "borrowed"})));
  check bool "failed label reuse retains the unmanaged Page and used-label history" true
    (!label=`Null && !used_labels=["borrowed"] && not !closed);
  let still_unmanaged=served "observe original target after rejected label reuse" (dispatch peer Live.Tabs_list (obj [])) in
  check bool "rejected label reuse keeps the original unmanaged tab and origin" true
    (List.exists (fun row->field "id" row=`Int 1 && field "egoPage" row=
      obj ["label",`Null;"targetId",str "T9";"openedBy",str "unknown"])
      (Yojson.Safe.Util.to_list still_unmanaged));
  ignore (served "re-adopt same original target with a fresh label"
    (control peer (Lane.Action.Adopt_tab {tab_id=1;label=Some "borrowed-again"})));
  ignore (before_effect "unknown-origin managed Page is protected from close" (close peer));
  check bool "protected close never calls the native Page method" false (List.mem "close" !calls);
  check bool "protected close leaves the Page managed and open" true (!label=str "borrowed-again" && not !closed);
  let remaining=served "observe protected original Page" (dispatch peer Live.Tabs_list (obj [])) in
  check bool "protected close retains the original tab and unknown origin" true
    (List.exists (fun row->field "id" row=`Int 1 && field "egoPage" row=
      obj ["label",str "borrowed-again";"targetId",str "T9";"openedBy",str "unknown"])
      (Yojson.Safe.Util.to_list remaining));
  let uncertain=peer in
  lost:=true;
  check string "lost adopted-Page input stays uncertain" "unknown" (failure_kind (workflow uncertain));
  let pending=Peer.input_status uncertain in
  check bool "lost input records an unsettled generation" true
    (match pending with Masc.Browser_ego_input.Uncertain _->true|Ready _->false);
  let before= !scripts in
  List.iter (fun action->ignore (before_effect "adoption cannot settle uncertain input" (action ())))
    [(fun ()->interact uncertain (Lane.Fill {selector="#editor";text="changed"}));
     (fun ()->workflow uncertain);(fun ()->control uncertain (Lane.Action.Release_tab 1))];
  check int "uncertain input prevents later native commands" before !scripts;
  check bool "adopted origin never resets pending input" true (Peer.input_status uncertain=pending)

let test_the_space_goes_to_the_operator_and_back () =
  let ownership = ref "agent" and user_page = ref {|({spaceId:51,label:"p2",targetId:"T2",openedBy:"agent"})|} and output = ref "" in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str !ownership])
    | _ -> output := in_node (control_stand_in ~ownership:!ownership ~user_page:!user_page ^ script); Ok !output in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> after ~prefix:"seen " line
    | None -> fail "the stand-in did not say what it saw" in
  let act control = dispatch peer Live.Page_act (Lane.Action.to_json (Lane.Action.Control control)) in
  let answer label = function
    | Ok answer -> Yojson.Safe.to_string answer
    | other -> failf "%s was %s" label (failure_kind other) in
  check string "the hand-off identifies the same space for the operator"
    {|{"inputReadiness":"command_settled","action":"hand_off","spaceId":51,"spaceName":"MASC login"}|}
    (answer "hand-off" (act Lane.Action.Hand_off));
  check string "by ego's own handOff" {|["handOff"]|} (seen ());
  ownership := "agentDelegatedToUser";
  check bool "while the operator holds it, a step is refused before any effect" true
    (contains (before_effect "a listing" (dispatch peer Live.Tabs_list (obj []))) "the operator holds this ego task space");
  check string "and nothing in the space is called" "[]" (seen ());
  check bool "a second hand-off is refused the same way, with ego's owner" true
    (contains (before_effect "a second hand-off" (act Lane.Action.Hand_off)) "ego ownership: agentDelegatedToUser");
  let taken=Yojson.Safe.from_string (answer "take-over" (act Lane.Action.Take_over)) in
  check int "taking it back names the native boundary Page" 1 (Yojson.Safe.Util.to_int (field "activeTabId" taken));
  check int "takeover retains original Space" 51 (Yojson.Safe.Util.to_int (field "spaceId" taken));
  check string "takeover preserves Space name" "MASC login" (text (field "spaceName" taken));
  check bool "managed boundary provenance survives the Peer" true
    (field "egoPage" taken=obj ["label",str "p2";"targetId",str "T2";"openedBy",str "agent"]);
  check string "by ego's takeOverTaskSpace on this space and exact inventory" {|["takeOver 51","tabs"]|} (seen ());
  user_page := "({spaceId:51,label:null,targetId:'TU',openedBy:'unknown'})";
  let unmanaged=Yojson.Safe.from_string (answer "take-over onto an operator tab" (act Lane.Action.Take_over)) in
  check int "an unmanaged boundary is remembered without adoption" 2 (Yojson.Safe.Util.to_int (field "activeTabId" unmanaged));
  check bool "unmanaged target and origin survive the Peer" true
    (field "egoPage" unmanaged=obj ["label",`Null;"targetId",str "TU";"openedBy",str "unknown"]);
  user_page := "undefined";
  let absent=Yojson.Safe.from_string (answer "take-over without a native boundary Page" (act Lane.Action.Take_over)) in
  check bool "an absent boundary never selects current active tab" true
    (field "activeTabId" absent=`Null && field "egoPage" absent=`Null);
  check string "absent boundary does not enumerate tabs" {|["takeOver 51"]|} (seen ());
  List.iter (fun invalid->user_page:=invalid;
    check string "an invalid native Page is uncertain after takeover" "unknown" (failure_kind (act Lane.Action.Take_over))) ["null";"({})"];
  ownership := "agent";
  check bool "with the agent holding the space, a take-over is refused before any effect" true
    (contains (before_effect "a needless take-over" (act Lane.Action.Take_over)) "already holds");
  check string "and ego is not asked to take it" "[]" (seen ());
  let open_owned_by owner = Peer.open_space ~run_native:(fun _ -> Error (Peer.Unstarted "no native command in this fixture")) ~downloads:no_downloads ~run:(fun ~window_s:_ _ -> answered (obj ["spaceId",`Int 52;"name",str "SDK Space";"ownership",str owner]))
      ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) in
  check bool "a space handed to the operator still opens, so take_over can bring it back" true
    (Result.is_ok (open_owned_by "agentDelegatedToUser"));
  check bool "a space the operator made does not" true (Result.is_error (open_owned_by "user"))

let test_history_moves_one_entry () =
  let current = ref 1 and navigation = ref "" and detaches = ref false and same_url = ref false and load = ref "" in
  let output = ref "" and steps = ref [] in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered (`List [
        tab_row ~label:(str "p1") ~target:"T1" ~title:"B" ~url:"https://b.test/" ~active:true ();
        tab_row ~label:`Null ~target:"T9" ~title:"Mail" ~url:"https://mail.example/" ~active:false ()])
    | "page.history" | "page.reload" ->
      steps := sent :: !steps;
      output := in_node (stand_in ~current:!current ~navigation:!navigation ~detaches:!detaches
        ~same_url:!same_url ~load:!load ^ script);
      Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let on_tab ?(tab_id=1) interaction = dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id;frame_path=[];interaction})) in
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  (match on_tab Lane.Action.Back with
   | Ok receipt -> check string "back" {|{"inputReadiness":"command_settled","tabId":1,"action":"back","url":"https://a.test/","title":"A"}|} (Yojson.Safe.to_string receipt)
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
   | Ok receipt -> check string "forward" {|{"inputReadiness":"command_settled","tabId":1,"action":"forward","url":"https://b.test/","title":"B"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "forward was %s" (failure_kind other));
  current := 1;
  check string "no later page" "tab 1 has no later page in its history"
    (before_effect "forward from the last entry" (on_tab Lane.Action.Forward));
  (match on_tab Lane.Action.Reload with
   | Ok receipt -> check string "reload" {|{"inputReadiness":"command_settled","tabId":1,"action":"reload","url":"https://b.test/","title":"B"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "reload was %s" (failure_kind other));
  check (list string) "a reload is ego's own" ["reload"] (seen ());
  detaches := true;
  (match on_tab Lane.Action.Back with
   | Ok receipt -> check string "back past a failed read" {|{"inputReadiness":"command_settled","tabId":1,"action":"back","url":"https://a.test/","title":"A"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "a move with a failed read while waiting was %s" (failure_kind other));
  check bool "a read failed while it waited" true (List.mem "detached" (seen ()));
  detaches := false;
  same_url := true;
  (match on_tab Lane.Action.Back with
   | Ok receipt -> check string "back to an entry with the same URL" {|{"inputReadiness":"command_settled","tabId":1,"action":"back","url":"https://a.test/","title":"A"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "a move to the same URL was %s" (failure_kind other));
  check string "it waited for the entry, not the URL" "load at 0" (List.hd (List.rev (seen ())));
  same_url := false;
  load := {|throw new Error("Timeout 30000ms exceeded");|};
  (match on_tab Lane.Action.Back with
   | Error (Live.Partial_failure {receipt; message; _}) ->
     check string "a load wait that failed answers where the tab is" {|{"inputReadiness":"command_settled","tabId":1,"action":"back","url":"https://a.test/","title":"A"}|} (Yojson.Safe.to_string receipt);
     check string "and what failed" "Timeout 30000ms exceeded" message
   | other -> failf "a failed load wait was %s" (failure_kind other));
  load := "";
  navigation := {|throw new Error("net::ERR_ABORTED");|};
  (match on_tab Lane.Action.Back with
   | Error (Live.Partial_failure {tab_id; receipt; message}) ->
     check int "the tab" 1 tab_id;
     check string "where it is now" {|{"inputReadiness":"command_settled","tabId":1,"action":"back","url":"https://b.test/","title":"B"}|} (Yojson.Safe.to_string receipt);
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
       {|{"inputReadiness":"command_settled","tabId":1,"action":"accept_dialog","dialog":{"type":"prompt","message":"name?","defaultValue":"def"}}|}
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
       {|{"inputReadiness":"command_settled","tabId":1,"action":"dismiss_dialog","dialog":{"type":"alert","message":"saved"}}|} (Yojson.Safe.to_string receipt)
   | other -> failf "the dismissal was %s" (failure_kind other));
  check bool "dismisses" true (field "accept" (last ()).args = `Bool false);
  reply := (fun _ -> answered (obj ["dialog",ego_dialog "modal" "?"]));
  (match act Lane.Action.Dismiss_dialog with
   | Ok receipt -> check string "a dialog it cannot read is left out" {|{"inputReadiness":"command_settled","tabId":1,"action":"dismiss_dialog"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "an answer to an unreadable dialog was %s" (failure_kind other));
  reply := (fun _ -> refused "no dialog is open in this tab");
  check string "none open" "no dialog is open in this tab" (before_effect "an answer with none open" (act Lane.Action.Dismiss_dialog));
  reply := (fun _ -> failed "Target closed");
  (match act Lane.Action.Dismiss_dialog with
   | Error (Live.Outcome_unknown detail | Live.Observed_failure {disposition=Live.Uncertain;message=detail;_}) ->
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
   | Ok rows -> check bool "each managed page names the dialog blocking it" true
       (List.map (field "dialog") (Yojson.Safe.Util.to_list rows)
        = [obj ["type",str "prompt";"message",str "name?";"defaultValue",str "def"];`Null;
           obj ["type",str "alert";"message",str "saved"]])
   | Error _ -> fail "the listing failed");
  (* A page whose dialog state ego could not read, or named in a shape this
     connection cannot read, is listed as BiDi lists a tab it could not read. *)
  listing := `List [
    tab_row ~label:(str "p1") ~target:"T1" ~title:"Slack" ~url:"https://app.slack.com/" ~active:true ();
    tab_row ~unread:(str "Not attached to an active page") ~label:(str "p2") ~target:"T2" ~title:"" ~url:"about:blank" ~active:false ();
    tab_row ~dialog:(ego_dialog "modal" "?") ~label:(str "p3") ~target:"T3" ~title:"X" ~url:"https://x.test/" ~active:false ()];
  (match dispatch peer Live.Tabs_list (obj []) with
   | Ok rows ->
     check bool "an unread dialog state makes the inventory partial" false
       (Yojson.Safe.Util.to_bool (field "complete" rows));
     let unavailable=Yojson.Safe.Util.to_list (field "unavailableTabs" rows) in
     check (list int) "unread tabs retain their numbers" [3;4]
       (List.map (fun row -> Yojson.Safe.Util.to_int (field "id" row)) unavailable);
     check (list string) "unread tabs retain their reason"
       ["ego did not read whether a dialog blocks this page: Not attached to an active page";
        "ego reported a JavaScript dialog of unknown type \"modal\""]
       (List.map (fun row -> text (field "error" row)) unavailable);
     check bool "unread tabs retain their native Page context" true
       (List.map (field "egoPage") unavailable = List.map (fun (label,target) ->
          obj ["label",str label;"targetId",str target;"openedBy",str "agent"])
          ["p2","T2";"p3","T3"]);
     let module Surface=Masc.Browser_surface in
     let plan=Result.get_ok (Surface.prepare_read ~tab_id:None rows) in
     let client_id=Result.get_ok (Lane.client_id_of_string "10000000-0000-4000-8000-000000000021") in
     let selected : Masc.Browser_selection.selected = {route=Lane.Live_route (Some client_id);reason=Explicit_browser} in
     let info : Lane.client_info = {client_id;browser=Ego_lite;version="fixture";engine_version="fixture";
       transport=Ego_task_space;space=Some (Peer.space peer)} in
     let binding=Masc.Browser_binding.of_browser selected (Masc.Browser_selection.Connected info) in
     let page=obj ["url",str "https://app.slack.com/";"title",str "Slack";"text",str "observed";
       "chars",`Int 8;"truncated",`Bool false] in
     let projected=Result.get_ok (Surface.project_read plan ~binding ~started:0L ~page:(Some page)) in
     check bool "document projection keeps unavailable Page contexts" true
       (field "unavailableTabs" projected=field "unavailableTabs" rows)
   | Error _ -> fail "the partial listing failed");
  listing := `List [obj ["label",str "p1";"targetId",str "T1";"openedBy",str "agent";"title",str "Slack";"url",str "https://app.slack.com/";"active",`Bool true]];
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
    | "page.pointer" -> answered (obj ["guard",page_summary;"dialog",ego_dialog "confirm" "sure?";"tab",row;"error",`Null])
    | other -> failf "unexpected step %s" other);
  (match interact (Lane.Click_node {document_id="d1";node_id="send"}) with
   | Ok receipt -> check string "the click and the dialog it opened"
       {|{"inputReadiness":"command_settled","tabId":1,"action":"click","urlBefore":"https://app.slack.com/","url":"https://app.slack.com/","title":"Slack","dialog":{"type":"confirm","message":"sure?"}}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "a click that opened a dialog was %s" (failure_kind other));
  reply := (fun _ -> answered (obj ["dialog",ego_dialog "alert" "saved";"tab",row]));
  (match interact (Lane.Fill_node {target={document_id="d1";node_id="message"};text="hi"}) with
   | Error (Live.Partial_failure {tab_id; receipt; message}) ->
     check int "the tab" 1 tab_id;
     check string "where it is and the dialog"
       {|{"inputReadiness":"command_settled","tabId":1,"action":"fill","url":"https://app.slack.com/","title":"Slack","dialog":{"type":"alert","message":"saved"}}|}
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
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | step ->
      let open_, opening, opens_on = !scenario in
      output := in_node (dialog_stand_in ~open_ ~opening ~opens_on ~canned:(canned step) ^ script);
      Ok !output in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
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
   | Ok rows ->
     let row=match Yojson.Safe.Util.to_list rows with [row] -> row | _ -> fail "expected one listed page" in
     check bool "listed with its dialog" true
       (field "dialog" row=obj ["type",str "prompt";"message",str "name?";"defaultValue",str "def"]);
     check bool "dialog inventory retains its native Page provenance" true
       (field "egoPage" row=obj ["label",str "p1";"targetId",str "T1";"openedBy",str "agent"])
   | Error _ -> fail "the listing failed");
  (match act (Lane.Action.Accept_dialog (Some "Vincent")) with
   | Ok receipt -> check string "the answer"
       {|{"inputReadiness":"command_settled","tabId":1,"action":"accept_dialog","dialog":{"type":"prompt","message":"name?","defaultValue":"def"}}|} (Yojson.Safe.to_string receipt)
   | other -> failf "the accept was %s" (failure_kind other));
  check (list string) "read, then answered with the text" ["info";"accept Vincent"] (seen ());
  scenario := (`Null, `Null, "");
  check string "none open" "no dialog is open in this tab" (before_effect "a dismissal with none open" (act Lane.Action.Dismiss_dialog));
  check (list string) "and nothing was answered" ["info"] (seen ());
  scenario := (`Null, ego_dialog "confirm" "sure?", "click");
  (match interact (Lane.Click_node {document_id="d1";node_id="send"}) with
   | Ok receipt -> check string "the click and its dialog"
       {|{"inputReadiness":"command_settled","tabId":1,"action":"click","urlBefore":"https://app.slack.com/","url":"https://app.slack.com/","title":"Slack","dialog":{"type":"confirm","message":"sure?"}}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "a click that opened a dialog was %s" (failure_kind other));
  check (list string) "no page script after the dialog opened, and ego's click carried its label" ["info";"evaluate";"click MASC · agent · click";"info"] (seen ());
  scenario := (`Null, alert, "evaluate");
  (match interact (Lane.Fill_node {target={document_id="d1";node_id="message"};text="hi"}) with
   | Error (Live.Partial_failure {receipt; _}) -> check string "a fill the dialog stopped"
       {|{"inputReadiness":"command_settled","tabId":1,"action":"fill","url":"https://app.slack.com/","title":"Slack","dialog":{"type":"alert","message":"saved"}}|}
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
  let row ?(path=`Null) ?(reason=`Null) ~id ~state name = obj ["id",str id;"label",str "p1";"source",str "native_download";
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
    | Error (Live.Before_effect detail | Live.Outcome_unknown detail | Live.Observed_failure {message=detail;_} | Live.Partial_failure {message=detail;_}) ->
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
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered (`List [tab_row ~label:(str "p1") ~target:"T1" ~title:"Files" ~url:"https://example.test/" ~active:true ()])
    | "page.goto" -> program := silent script :: !program;
      answered (obj ["error",`Null;"tab",obj ["url",str "https://example.test/";"title",str "Files"]])
    | "page.downloads" ->
      output := in_node (String.concat "\n" (List.rev (("{\n" ^ script ^ "\n}") :: !program)));
      Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
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
    | Error (Live.Before_effect detail | Live.Outcome_unknown detail | Live.Observed_failure {message=detail;_} | Live.Partial_failure {message=detail;_}) ->
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

(* An upload hands the worker's copies to the native SDK and records the
   chosen metadata. The page reads the files later, so the copies outlive the
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
    | "space.finish" -> answered (obj ["spaceId",`Int 51;"closedSpace",`Bool true;
        "keptManagedLabels",`List [];"closedManagedLabels",`List [];"preservedUnmanagedCount",`Int 0])
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let upload ?(selector="#file") paths = dispatch peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.File_input selector;paths}})) in
  let row = obj ["url",str "https://app.slack.com/";"title",str "Slack"] in
  reply := (fun _ -> answered (obj ["error",`Null;"dialog",`Null;"tab",row]));
  (match upload paths with
   | Ok receipt -> check string "the staged files handed to the SDK"
       {|{"inputReadiness":"command_settled","tabId":1,"action":"upload","chosen":[{"name":"note.txt","size":5}],"url":"https://app.slack.com/","title":"Slack"}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "the upload was %s" (failure_kind other));
  check (list string) "ego was given the copies" paths
    (List.map text (Yojson.Safe.Util.to_list (field "paths" (List.hd !asked))));
  check string "and the selector as given" "#file" (text (field "selector" (List.hd !asked)));
  Lane.Upload_lease.release snapshot;
  check bool "the copies outlive the upload's own scope" true (List.for_all Sys.file_exists paths);
  reply := (fun _ -> answered (obj ["error",`Null;"dialog",ego_dialog "alert" "uploaded";"tab",row]));
  (match upload paths with
   | Ok receipt -> check string "an upload that opened a dialog answers with it"
       {|{"inputReadiness":"command_settled","tabId":1,"action":"upload","chosen":[{"name":"note.txt","size":5}],"url":"https://app.slack.com/","title":"Slack","dialog":{"type":"alert","message":"uploaded"}}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "an upload that opened a dialog was %s" (failure_kind other));
  reply := (fun _ -> answered (obj ["error",str "Target closed";"dialog",`Null;"tab",row]));
  check string "a failed setInputFiles leaves the input unknown" "unknown" (failure_kind (upload paths));
  reply := (fun _ -> answered (obj ["error",str "SDK could not resolve the file input";"dialog",`Null;"tab",row]));
  check string "a native input failure is uncertain" "unknown" (failure_kind (upload ~selector:"#none" paths));
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
    | "space.finish" -> answered (obj ["spaceId",`Int 51;"closedSpace",`Bool true;
        "keptManagedLabels",`List [];"closedManagedLabels",`List [];"preservedUnmanagedCount",`Int 0])
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let choose ?actor ?(opener="#attach") paths = dispatch ?actor peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.Chooser_opener opener;paths}})) in
  let row = obj ["url",str "https://app.slack.com/";"title",str "Slack"] in
  let last () = List.hd !asked in
  reply := (fun _ -> answered (obj ["error",`Null;"dialog",`Null;"tab",row]));
  (match choose paths with
   | Ok receipt -> check string "the files handed to the chooser"
       {|{"inputReadiness":"command_settled","tabId":1,"action":"upload","chosen":[{"name":"note.txt","size":5}],"url":"https://app.slack.com/","title":"Slack"}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "the upload was %s" (failure_kind other));
  check (list string) "ego was given the copies" paths
    (List.map text (Yojson.Safe.Util.to_list (field "paths" (last ()))));
  check string "and the opener as given" "#attach" (text (field "opener" (last ())));
  check string "whose click is labelled" "MASC · agent · upload" (text (field "cursor" (last ())));
  ignore (choose ~actor:"keeper/fixture-peer" paths);
  check string "with the actor when there is one" "MASC · keeper/fixture-peer · upload" (text (field "cursor" (last ())));
  Lane.Upload_lease.release snapshot;
  check bool "the copies outlive the upload's own scope" true (List.for_all Sys.file_exists paths);
  reply := (fun _ -> answered (obj ["error",`Null;"dialog",ego_dialog "alert" "uploaded";"tab",row]));
  (match choose paths with
   | Ok receipt -> check bool "a dialog the files opened is in the receipt" true
       (String_util.contains_substring (Yojson.Safe.to_string receipt) {|"dialog":{"type":"alert","message":"uploaded"}|})
   | other -> failf "an upload that opened a dialog was %s" (failure_kind other));
  reply := (fun _ -> answered (obj ["error",str "the opener opened no file chooser: page.waitForFileChooser timed out after 5000ms";"dialog",`Null;"tab",row]));
  (match choose paths with
   | Error (Live.Outcome_unknown detail | Live.Observed_failure {disposition=Live.Uncertain;message=detail;_}) ->
     check bool "a chooser that did not open is reported after the click" true (String_util.contains_substring detail "opened no file chooser")
   | other -> failf "a click that opened no chooser was %s" (failure_kind other));
  reply := (fun _ -> answered (obj ["error",str "ego did not click the opener: native selector not found";"dialog",`Null;"tab",row]));
  check string "a native opener failure is uncertain" "unknown" (failure_kind (choose ~opener:"#none" paths));
  let runs = List.length !asked in
  check bool "a missing file is refused" true
    (String_util.contains_substring (before_effect "a missing file" (choose [Filename.concat directory "absent.txt"])) "absent.txt");
  check int "without running ego" runs (List.length !asked);
  check (result unit string) "finish" (Ok ()) (Peer.finish peer);
  check bool "the space's end lets the copies go" false (List.exists Sys.file_exists paths)

(* The stand-in exposes only the SDK upload boundary. No DOM evaluator is
   available: selector resolution and file-input validation belong to Ego. *)
let upload_stand_in ~opens ~fails = Printf.sprintf {js|
const opens = %s;
let open = null;
const seen = [];
process.on("exit", () => console.log("seen " + JSON.stringify(seen)));
const page = {
  info: async () => open === null ? {url: "https://example.test/", title: "Form", w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600} : {dialog: open},
  setInputFiles: async (selector, paths) => {
    seen.push("set " + selector + " " + paths.length);
    if (%b) throw new Error("native selector not found");
    open = opens;
    return {};
  },
};
const taskSpace = async () => ({
  ownership: "agent",
  tabs: async () => [{label: "p1", openedBy: "agent", url: "https://example.test/", title: "Form", targetId: "T1", active: true}],
  page: () => page,
});
|js} (Yojson.Safe.to_string opens) fails

let test_the_upload_script_runs_in_node () =
  let directory = Unix.realpath (capture_directory ()) in
  let path = Filename.concat directory "note.txt" and other = Filename.concat directory "two.txt" in
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel "hello");
  Out_channel.with_open_bin other (fun channel -> Out_channel.output_string channel "second");
  let opens = ref `Null and fails = ref false and output = ref "" in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered (`List [tab_row ~label:(str "p1") ~target:"T1" ~title:"Form" ~url:"https://example.test/" ~active:true ()])
    | "page.upload" -> output := in_node (upload_stand_in ~opens:!opens ~fails:!fails ^ script); Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  let upload ?(selector="#file") paths = dispatch peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.File_input selector;paths}})) in
  (match upload [path] with
   | Ok receipt -> check string "the staged files handed to the SDK" {|[{"name":"note.txt","size":5}]|} (Yojson.Safe.to_string (field "chosen" receipt))
   | other -> failf "the upload was %s" (failure_kind other));
  check (list string) "one native call preserves the CSS selector" ["set #file 1"] (seen ());
  ignore (upload ~selector:"@file-ref" [path]);
  check (list string) "a snapshot ref reaches the SDK unchanged" ["set @file-ref 1"] (seen ());
  ignore (upload ~selector:"loc=label:Attachment" [path; other]);
  check (list string) "semantic locator and both paths reach the SDK unchanged"
    ["set loc=label:Attachment 2"] (seen ());
  fails := true;
  check string "a native selector failure is uncertain" "unknown" (failure_kind (upload ~selector:"#none" [path]));
  check (list string) "the failed native call is not retried" ["set #none 1"] (seen ());
  fails := false;
  opens := ego_dialog "alert" "too big";
  (match upload [path] with
   | Ok receipt -> check string "the dialog it opened" {|{"type":"alert","message":"too big"}|} (Yojson.Safe.to_string (field "dialog" receipt))
   | other -> failf "an upload that opened a dialog was %s" (failure_kind other));
  check (list string) "the dialog requires no DOM readback" ["set #file 1"] (seen ())

(* Input and upload frame paths reach the peer and are refused before any
   effect. Frame_read is refused by the live transport gate, so a direct
   peer call would not prove which message the public tool receives. *)
let test_input_frame_paths_are_refused_with_the_way_that_works () =
  let runs = ref 0 in
  let peer = opened (fun sent ->
    incr runs;
    match sent.step with
    | "tabs.list" -> answered tabs
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let before = !runs in
  let says label needle result =
    check bool label true (String_util.contains_substring (before_effect label result) needle) in
  let frame_click = interact_args ~frame_path:["#frame"] (Lane.Click "#send") in
  (match Masc.Browser_interaction.parse frame_click with
   | Ok _ -> ()
   | Error detail -> failf "the frame fixture must reach the peer: %s" detail);
  says "frame input names target" "acts inside frames through target"
    (dispatch peer Live.Page_interact frame_click);
  says "an upload frame path names the native route" "without framePath"
    (dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=1;frame_path=["#frame"];
      interaction=Lane.Action.Upload {target=Lane.Action.File_input "#file";paths=["/tmp/note.txt"]}})));
  check int "neither refused frame request dispatches an SDK script" before !runs

(* The chooser SDK stand-in has no DOM evaluator. Its native click
   opens a file chooser when [opens] holds, one that takes several files when
   [multiple] does; its setFiles answers [set], or throws when [fails] holds.
   Every entered setFiles disposes the chooser, including backend failure;
   setFiles([]) handles a captured chooser that was never filled. *)
let chooser_stand_in ~opens ~multiple ~set ~fails ~click_fails = Printf.sprintf {js|
const fs = await import("node:fs");
const nodePath = await import("node:path");
const seen = [];
process.on("exit", () => console.log("seen " + JSON.stringify(seen)));
let waiting = null;
let activeChooser = false;
let clickFails = %b;
let setFails = %b;
let chooserHandled = false;
const chooser = {
  isMultiple: async () => %b,
  setFiles: async paths => {
    if (chooserHandled) { seen.push("duplicate set"); throw new Error("this file chooser was already handled"); }
    chooserHandled = true;
    activeChooser = false;
    if (paths.length === 0) { seen.push("closed"); return {}; }
    if (setFails) throw new Error("Node is not a file input element");
    seen.push("chosen " + paths.map(path => nodePath.basename(path) + "/" + fs.statSync(path).size).join(",")); return %s;
  },
};
const page = {
  info: async () => ({url: "https://example.test/", title: "Form", w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600}),
  waitForFileChooser: options => {
    if (activeChooser) throw new Error("this Page is already waiting for a file chooser");
    seen.push(options === undefined ? "wait native" : "wait custom"); return new Promise((resolve, reject) => { waiting = {resolve, reject}; });
  },
  click: async (selector, options) => {
    seen.push("click " + selector + " " + options.label);
    if (waiting !== null) { if (%b) { activeChooser = true; chooserHandled = false; waiting.resolve(chooser); } else waiting.reject(new Error("page.waitForFileChooser timed out after 5000ms")); }
    if (selector === "#none") throw new Error("native selector not found");
    if (clickFails) throw new Error("click response lost");
    return {};
  },
};
const taskSpace = async () => ({
  ownership: "agent",
  tabs: async () => [{label: "p1", openedBy: "agent", url: "https://example.test/", title: "Form", targetId: "T1", active: true}],
  page: () => page,
});
|js} click_fails fails multiple (Yojson.Safe.to_string set) opens

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
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered (`List [tab_row ~label:(str "p1") ~target:"T1" ~title:"Form" ~url:"https://example.test/" ~active:true ()])
    | "page.choose_files" ->
      let recovery = if !click_fails || !fails then
          "\nclickFails = false; setFails = false; const savedLog = console.log; console.log = () => {};\n{\n"
          ^ script ^ "\n}\nconsole.log = savedLog;\n"
        else "" in
      output := in_node (chooser_stand_in ~opens:!opens ~multiple:!multiple ~set:!set ~fails:!fails ~click_fails:!click_fails
        ^ "\n{\n" ^ script ^ "\n}\n" ^ recovery); Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "masc") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  let choose ?(opener="#attach") paths = dispatch peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Upload {target=Lane.Action.Chooser_opener opener;paths}})) in
  let unknown label result = match result with
    | Error (Live.Outcome_unknown detail | Live.Observed_failure {disposition=Live.Uncertain;message=detail;_}) -> detail
    | other -> failf "%s was %s" label (failure_kind other) in
  (match choose [path] with
   | Ok receipt -> check string "what the chooser was handed" {|[{"name":"note.txt","size":5}]|} (Yojson.Safe.to_string (field "chosen" receipt))
   | other -> failf "the upload was %s" (failure_kind other));
  check (list string) "armed with native wait, clicked with its label, then chosen"
    ["wait native";"click #attach MASC · agent · upload";"chosen note.txt/5"] (seen ());
  check bool "a chooser that takes one file gets none of two" true
    (String_util.contains_substring (unknown "two files" (choose [path; other])) "takes one file");
  check bool "and nothing was chosen" false (List.exists (String.starts_with ~prefix:"chosen") (seen ()));
  check bool "the chooser is closed so the next one can open" true (List.mem "closed" (seen ()));
  fails := true;
  check bool "a setFiles that fails is reported after the click" true
    (String_util.contains_substring (unknown "a failed setFiles" (choose [path])) "ego did not set the files");
  check bool "the SDK owns cleanup after setFiles was entered" false (List.mem "closed" (seen ()));
  check bool "no second setFiles is attempted on a handled chooser" false (List.mem "duplicate set" (seen ()));
  check bool "the next chooser succeeds after SDK-owned failure cleanup in the same process" true
    (List.mem "chosen note.txt/5" (seen ()));
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
  ignore (choose ~opener:"@attach-ref" [path]);
  check bool "a snapshot opener ref reaches the SDK unchanged" true
    (List.mem "click @attach-ref MASC · agent · upload" (seen ()));
  ignore (choose ~opener:"loc=label:Attach" [path]);
  check bool "a semantic opener reaches the SDK unchanged" true
    (List.mem "click loc=label:Attach MASC · agent · upload" (seen ()));
  check bool "a native opener failure remains uncertain" true
    (String_util.contains_substring (unknown "native selector failure" (choose ~opener:"#none" [path])) "native selector not found");
  check (list string) "the SDK failure is dispatched once and any opened chooser is closed"
    ["wait native";"click #none MASC · agent · upload";"closed"] (seen ());
  set := obj ["dialog",ego_dialog "alert" "too big"];
  (match choose [path] with
   | Ok receipt -> check string "the dialog the files opened" {|{"type":"alert","message":"too big"}|} (Yojson.Safe.to_string (field "dialog" receipt))
   | other -> failf "an upload that opened a dialog was %s" (failure_kind other));
  opens := false;
  check bool "a click that opens no chooser is reported after the click" true
    (String_util.contains_substring (unknown "no chooser" (choose [path])) "opened no file chooser")

let test_native_workflow_json_headers () =
  let shim = {js|
const page = {
  url: async () => 'https://app.slack.com/', title: async () => 'Fixture',
  info: async () => ({dialog:null}), snapshot: async () => 'root',
  waitForEvent: () => new Promise(() => {}),
  fetch: async (url, options) => ({own:Object.hasOwn(options.headers,'__proto__'),
    value:options.headers.__proto__,plain:Object.getPrototypeOf(options.headers)===Object.prototype})
};
const taskSpace = async () => ({ownership:'agent',
  tabs:async () => [{label:'p1',openedBy:'agent'}],page:() => page});
|js} in
  let run ~window_s script = match (sent_of ~window_s script).step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered tabs
    | "page.native_workflow" -> Ok (in_node (shim ^ script))
    | other -> failf "unexpected envelope fixture step %s" other in
  let peer=match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.)
      ~now ~space:(Browser_configuration.Named_space "masc") ~version:"fixture" ~capture_directory:(capture_directory ()) with
    | Ok value -> value | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let args=obj ["tabId",`Int 1;"expectedUrl",str "https://app.slack.com/";"maxChars",`Int 100;
    "steps",`List [obj ["method",str "fetch";"url",str "/api";
      "options",obj ["headers",obj ["__proto__",str "keep-me"]]]]] in
  match dispatch peer Live.Page_native_workflow args with
  | Error _ -> fail "the actual production envelope lost valid fetch data"
  | Ok reply ->
    let receipt=field "receipt" (List.hd (Yojson.Safe.Util.to_list (field "completed" reply))) in
    check bool "special header remains an own data property" true (field "own" receipt = `Bool true);
    check string "header bytes are preserved" "keep-me" (text (field "value" receipt));
    check bool "data never changes the headers prototype" true (field "plain" receipt = `Bool true)

let test_first_evaluation_timeout_preserves_unknown_native_receipt () =
  let module Wire=Masc.Browser_addon_wire in
  List.iter (fun (initial_url_fails,execution_stopped) ->
    let output=ref "" and native_calls=ref 0 and bounded_steps=ref [] in
    let shim=Printf.sprintf {js|
const seen = [];
const page = {
  url: async () => { seen.push('url');
    if (%s) throw Object.assign(new Error('native URL evaluation safety limit'), {
      code:'EGO_PAGE_EVALUATION_TIMED_OUT', timeoutMs:2500,
      executionStopped:%s, mayHaveLateEffects:true, pageResponsive:true
    });
    return 'https://app.slack.com/'; },
  info: async () => ({dialog:null}),
  waitForEvent: () => new Promise(() => {}),
  evaluate: async source => {
    seen.push('evaluate ' + source);
    throw Object.assign(new Error('native evaluation safety limit'), {
      code:'EGO_PAGE_EVALUATION_TIMED_OUT', timeoutMs:2500,
      executionStopped:%s, mayHaveLateEffects:true, pageResponsive:true
    });
  },
  waitForFunction: async () => { seen.push('unexpected following step'); throw new Error('must not continue'); },
  snapshot: async () => { seen.push('unexpected snapshot'); throw new Error('must not snapshot'); }
};
const taskSpace = async () => ({ownership:'agent',
  tabs:async () => [{label:'p1',targetId:'T1',openedBy:'agent'}],page:() => page});
|js} (string_of_bool initial_url_fails) (string_of_bool execution_stopped) (string_of_bool execution_stopped) in
    let run ~window_s script =
      let step=(sent_of ~window_s script).step in
      bounded_steps:=step :: !bounded_steps;
      match step with
      | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
      | "tabs.list" -> answered tabs
      | other -> failf "evaluation must use native runner, got %s" other in
    let run_native script =
      incr native_calls;
      check string "one native workflow" "page.native_workflow" (sent_of ~window_s:0. script).step;
      output:=in_node (shim ^ script ^ "\nconsole.log('evaluation-calls '+JSON.stringify(seen));");
      Ok !output in
    let peer=match Peer.open_space ~downloads:no_downloads ~run ~run_native ~now
        ~space:(Browser_configuration.Named_space "masc") ~version:"fixture" ~capture_directory:(capture_directory ()) with
      | Ok peer -> peer | Error detail -> fail detail in
    ignore (dispatch peer Live.Tabs_list (obj []));
    let args=obj ["tabId",`Int 1;"expectedUrl",str "https://app.slack.com/";"maxChars",`Int 100;
      "steps",`List [obj ["method",str "evaluate";"source",str "document.title"];
        obj ["method",str "waitForFunction";"source",str "window.ready"]]] in
    let result=Peer.dispatch ~command_id:"first-evaluation-timeout" peer ~verb:Live.Page_native_workflow args in
    let receipt=match result with
      | Error (Live.Observed_failure {disposition;receipt;_}) ->
        check bool "disposition follows workflow progress, not native diagnostics" true
          (disposition=(if initial_url_fails then Live.Not_started else Live.Uncertain)); receipt
      | Ok _|Error (Live.Before_effect _|Partial_failure _|Outcome_unknown _) ->
        fail "first evaluation failure lost its validated native receipt or changed disposition" in
    let diagnostic=field "nativeError" (field "failure" receipt) in
    check string "native error code is available to the caller" "EGO_PAGE_EVALUATION_TIMED_OUT" (text (field "code" diagnostic));
    check int "SDK timeout is retained" 2500 (Yojson.Safe.Util.to_int (field "timeoutMs" diagnostic));
    check bool "executionStopped remains an observation" execution_stopped (Yojson.Safe.Util.to_bool (field "executionStopped" diagnostic));
    check bool "even stopped execution may have late effects" true (Yojson.Safe.Util.to_bool (field "mayHaveLateEffects" diagnostic));
    check bool "native Page responsiveness is retained" true (Yojson.Safe.Util.to_bool (field "pageResponsive" diagnostic));
    check bool "first effect progress is retained" (not initial_url_fails) (Yojson.Safe.Util.to_bool (field "effectStarted" receipt));
    check bool "no effect completed" true (field "completedEffect" receipt=`Bool false && field "completed" receipt=`List []);
    let payload=Live.payload result in
    check bool "diagnostic failure is not successful" true (field "ok" payload=`Bool false);
    check bool "only initial URL failure is marked not-started" true
      (field "effectPhase" payload=(if initial_url_fails then str "not_started" else `Null));
    check bool "model-facing data preserves the entire validated receipt" true (field "data" payload=receipt);
    let wire=Wire.reply_to_json (Wire.Issue_result (Ok (Lane.Answered payload))) in
    (match Wire.reply_of_json wire with
     | Ok (Wire.Issue_result (Ok (Lane.Answered restored))) ->
       check bool "worker wire preserves diagnostic data and effect disposition" true (restored=payload)
     | Ok _|Error _ -> fail "worker wire lost the native evaluation diagnostic");
    let prefix="evaluation-calls " in
    let calls=match List.filter (String.starts_with ~prefix) (String.split_on_char '\n' !output) with
      | [line] -> Yojson.Safe.from_string (after ~prefix line)
      | _ -> fail "missing native SDK stand-in calls" in
    check bool "failed evaluation executes once, with no following SDK step or snapshot" true
      (calls=`List (if initial_url_fails then [str "url"] else [str "url";str "evaluate document.title"]));
    check int "native workflow is never replayed" 1 !native_calls;
    check (list string) "bounded runner does not wrap native evaluation"
      ["space.open";"tabs.list"] (List.rev !bounded_steps)) [false,false;false,true;true,false;true,true]

let test_saved_fetch_survives_snapshot_failure_and_reaches_download_broker () =
  let module Broker=Masc.Browser_addon_downloads in
  let ok=function Ok value->value|Error detail->fail detail in
  let root=Unix.realpath (Filename.temp_dir ~perms:0o700 "masc-fetch-peer-" "") in
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name->remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
    | Unix.S_REG|S_LNK|S_CHR|S_BLK|S_FIFO|S_SOCK -> Unix.unlink path in
  Fun.protect ~finally:(fun ()->remove root) (fun ()->
    let broker=ok (Broker.create ~directory:root) in
    let preserved=ref [] and original=ref None in
    let has_original_pin path =
      let expected=Unix.stat path in
      Array.exists (fun name->
        (* Darwin's devfd path stat reports the devfd mount's device, not
           the underlying file's device. Inspect an opened descriptor and
           close this temporary probe before looking at another entry. *)
        match Unix.openfile (Filename.concat "/dev/fd" name)
            [Unix.O_RDONLY;O_NONBLOCK;O_CLOEXEC] 0 with
        | fd->Fun.protect ~finally:(fun ()->Unix.close fd) (fun ()->
            let actual=Unix.fstat fd in
            actual.Unix.st_dev=expected.st_dev && actual.st_ino=expected.st_ino)
        | exception Unix.Unix_error ((Unix.ENOENT|EBADF|EACCES|EINVAL|ENODEV|ENXIO),_,_)->false)
        (Sys.readdir "/dev/fd") in
    Fun.protect ~finally:(fun ()->
      check (result unit string) "abandon preserves files without confirmed backend teardown"
        (Error "download cleanup requires confirmed backend teardown") (Broker.abandon broker);
      Option.iter (fun path->check bool "abandon closes the broker's original source pin" false (has_original_pin path)) !original;
      List.iter (fun (path,bytes)->check string "abandon preserves fixture-owned binary files" bytes
        (In_channel.with_open_bin path In_channel.input_all)) !preserved) (fun ()->
      let downloads_directory=Broker.downloads_directory ~directory:root in
      Unix.mkdir downloads_directory 0o700;
      let download_root=Filename.concat downloads_directory "ego" in Unix.mkdir download_root 0o700;
      let capture=Filename.concat root "capture" in Unix.mkdir capture 0o700;
      let program=Filename.concat root "sdk-stand-in.cjs" in
      Out_channel.with_open_bin program (fun channel->output_string channel {js|
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
globalThis.crypto=crypto;
const ownedRoot=process.argv[2],bytes=Buffer.from([0,255,128,13,10,0,65]);
let fetchCalls=0,snapshots=0;
const page={
 url:async()=> 'https://fixture.test/start',title:async()=> 'Binary fixture',info:async()=>({dialog:null}),
 waitForEvent:()=>new Promise(()=>{}),
 snapshot:async()=>{snapshots++;if(snapshots===1)throw Error('final snapshot response lost');return 'later snapshot';},
 fetch:async(url,options)=>{
  fetchCalls++;
  if(url!=='/binary'||options.credentials!=='include'||options.timeout!==37)throw Error('native fetch options lost');
  if(path.dirname(options.saveAs)!==ownedRoot||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(path.basename(options.saveAs)))
   throw Error('SDK write escaped fixture-owned UUID path');
  fs.writeFileSync(options.saveAs,bytes,{mode:0o600});
  return {ok:false,status:404,statusText:'Not Found',url:'https://fixture.test/binary',headers:{'content-type':'application/octet-stream'},savedPath:options.saveAs};
 }
};
globalThis.taskSpace=async reference=>{
 if(reference!==51&&reference!=='masc')throw Error('unexpected Space');
 return {spaceId:51,name:'SDK Space',ownership:'agent',
  tabs:async()=>[{label:'p1',targetId:'T1',openedBy:'agent',title:'Binary fixture',url:'https://fixture.test/start',active:true}],
  page:label=>{if(label!=='p1')throw Error('wrong Page');return page;}};
};
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
(async()=>{
 for await(const line of require('node:readline').createInterface({input:process.stdin})){
  const request=JSON.parse(line);
  if(request.stats){process.stdout.write(JSON.stringify({fetchCalls,snapshots,sha256:crypto.createHash('sha256').update(bytes).digest('hex')})+'\n');continue;}
  const lines=[];
  try {await new AsyncFunction('console',request.script)({log:(...args)=>lines.push(args.join(' '))});
   process.stdout.write(JSON.stringify({output:lines.join('\n')+'\n'})+'\n');}
  catch(error){process.stdout.write(JSON.stringify({error:String(error)})+'\n');}
 }
})().catch(error=>{process.stderr.write(String(error));process.exitCode=1;});
|js});
      let channels=Unix.open_process_full
        ("node " ^ Filename.quote program ^ " " ^ Filename.quote download_root) (Unix.environment ()) in
      let incoming,outgoing,_errors=channels in
      Fun.protect ~finally:(fun ()->
        match Unix.close_process_full channels with
        | Unix.WEXITED 0 -> ()
        | WEXITED _|WSIGNALED _|WSTOPPED _ -> fail "persistent Node SDK stand-in did not close cleanly") (fun ()->
        let exchange value = output_string outgoing (Yojson.Safe.to_string value ^ "\n");flush outgoing;
          Yojson.Safe.from_string (input_line incoming) in
        let scripts=ref [] in
        let run ~window_s script =
          scripts:=(sent_of ~window_s script).step::!scripts;
          let reply=exchange (obj ["script",str script]) in
          match field "output" reply with
          | `String output -> Ok output
          | `Null|`Bool _|`Int _|`Intlit _|`Float _|`Assoc _|`List _ -> Error (Peer.Unobserved (Yojson.Safe.to_string reply)) in
        let published=ref [] in
        let downloads={Peer.root=download_root;publish=(fun path->published:=path::!published;Broker.publish broker path)} in
        let peer=ok (Peer.open_space ~downloads ~run ~run_native:(run ~window_s:0.) ~now
          ~space:(Browser_configuration.Named_space "masc") ~version:"fixture" ~capture_directory:capture) in
        let served name=function Ok value->value
          | Error (Live.Before_effect detail|Outcome_unknown detail | Observed_failure {message=detail;_}|Partial_failure {message=detail;_})->failf "%s: %s" name detail in
        ignore (served "actual tabs listing" (dispatch peer Live.Tabs_list (obj [])));
        let arguments=obj ["tabId",`Int 1;"expectedUrl",str "https://fixture.test/start";"maxChars",`Int 100;
          "steps",`List [obj ["method",str "fetch";"url",str "/binary";
            "options",obj ["saveAs",str "binary report.bin";"credentials",str "include";"timeout",`Int 37]]]] in
        let partial=match Peer.dispatch ~command_id:"save-once-before-snapshot-failure" ~actor:"keeper/fetch-reader"
            peer ~verb:Live.Page_native_workflow arguments with
          | Error (Live.Partial_failure {tab_id=1;receipt;_})->receipt
          | other->failf "saved fetch with failed final snapshot was %s" (failure_kind other) in
        let completed=match field "completed" partial with
          | `List [row]->field "receipt" row | _->fail "completed save metadata was lost" in
        let download_id=text (field "downloadId" completed) in
        check string "completed workflow keeps fetch provenance" "fetch" (text (field "source" completed));
        check bool "workflow save receipt does not expose a source path" true (field "savedPath" completed=`Null);
        check int "HTTP error remains saved response data" 404 (Yojson.Safe.Util.to_int (field "status" completed));
        let listing=served "recover saved fetch" (dispatch peer Live.Page_downloads (obj ["tabId",`Int 1])) in
        let second=served "repeat download read" (dispatch peer Live.Page_downloads (obj ["tabId",`Int 1])) in
        check bool "repeated listing reuses the same private snapshot marker" true (listing=second);
        let row=match field "downloads" listing with `List [row]->row|_->fail "one saved fetch expected" in
        check string "the same completed fetch is recovered" download_id (text (field "downloadId" row));
        check string "download source is preserved" "fetch" (text (field "source" row));
        check string "requested filename remains artifact metadata" "binary report.bin" (text (field "suggestedFilename" row));
        check string "download is complete" "completed" (text (field "status" row));
        let saved=Filename.concat download_root download_id in
        check (list string) "the original file was published exactly once" [saved] !published;
        let bytes="\000\255\128\r\n\000A" in
        check string "SDK save kept binary bytes" bytes (In_channel.with_open_bin saved In_channel.input_all);
        original:=Some saved;preserved:=[saved,bytes];
        check bool "broker holds the original source until retirement" true (has_original_pin saved);
        let client=ok (Lane.client_id_of_string "00000000-0000-4000-8000-000000000001") in
        let other=ok (Lane.client_id_of_string "00000000-0000-4000-8000-000000000002") in
        let route=Lane.Live_route (Some client) and actor="keeper/fetch-reader" and verb=Lane.Page_downloads {tab_id=1} in
        let bound=ok (Broker.bind broker ~actor ~route ~verb listing) in
        let grant=match field "downloads" bound with
          | `List [row]->text (field "downloadGrant" (field "artifact" row))
          | _->fail "the actual broker did not bind the listing marker" in
        check bool "a different actor cannot claim the saved bytes" true
          (Result.is_error (Broker.claim broker ~id:grant ~actor:"keeper/foreign" ~route ~verb));
        check bool "another client cannot claim the saved bytes" true
          (Result.is_error (Broker.claim broker ~id:grant ~actor ~route:(Lane.Live_route (Some other)) ~verb));
        check bool "another tab read cannot claim the saved bytes" true
          (Result.is_error (Broker.claim broker ~id:grant ~actor ~route ~verb:(Lane.Page_downloads {tab_id=2})));
        let descriptor=match ok (Broker.claim broker ~id:grant ~actor ~route ~verb) with
          | Broker.Snapshot descriptor->descriptor | Published _->fail "first claim must hold a snapshot" in
        Fun.protect ~finally:(fun ()->ok (Broker.release broker ~id:grant ~actor ~route ~verb)) (fun ()->
          let snapshot_path=ok (Broker.snapshot_path ~directory:root ~snapshot_id:descriptor.snapshot_id) in
          preserved:=(snapshot_path,bytes)::!preserved;
          ok (Broker.snapshot_matches ~label:"saved fetch snapshot" ~path:snapshot_path descriptor (Unix.lstat snapshot_path));
          check int "descriptor counts binary bytes" (String.length bytes) descriptor.bytes;
          check string "broker snapshot preserves binary content" bytes (In_channel.with_open_bin snapshot_path In_channel.input_all);
          let stats=exchange (obj ["stats",`Bool true]) in
          check string "snapshot digest matches the saved binary" (text (field "sha256" stats)) descriptor.sha256;
          check int "listing never retries native fetch" 1 (Yojson.Safe.Util.to_int (field "fetchCalls" stats));
          check int "download recovery needs no new snapshot" 1 (Yojson.Safe.Util.to_int (field "snapshots" stats)));
        check (list string) "one persistent SDK session executes production wrappers without replay"
          ["space.open";"tabs.list";"page.native_workflow";"page.downloads";"page.downloads"] (List.rev !scripts))))

let test_takeover_receipt_and_native_runner_preserve_pending_input () =
  let module Takeover=Masc.Browser_ego_takeover in
  let raw page=obj ["spaceId",`Int 51;"spaceName",str "Renamed Space";"page",page] in
  let managed=obj ["label",str "p1";"targetId",str "T1";"openedBy",str "agent"] in
  let unmanaged=obj ["label",`Null;"targetId",str "TU";"openedBy",str "unknown"] in
  List.iter (fun page->match Takeover.decode ~expected_id:51 (raw page) with
    | Ok receipt->check string "takeover decoder preserves observed Space name" "Renamed Space" receipt.space.name;
      check bool "takeover decoder preserves exact boundary identity" true
        (Option.map Masc.Browser_surface.ego_page_to_json receipt.page=(if page=`Null then None else Some page))
    | Error detail->fail detail) [`Null;managed;unmanaged];
  let malformed=[`Null;obj [];obj ["spaceId",`Int 52;"spaceName",str "Space";"page",managed];
    obj ["spaceId",`Int 51;"spaceName",str " ";"page",managed];
    obj ["spaceId",`Int 51;"spaceName",str "Space";"page",managed;"page",unmanaged];
    obj ["spaceId",`Int 51;"spaceName",str "Space";"page",managed;"active",str "p1"];
    raw (`Bool false);raw (obj []);
    raw (obj ["label",`Null;"targetId",str " ";"openedBy",str "unknown"]);
    raw (obj ["label",str "p1";"targetId",str "T1";"openedBy",str "user"]);
    raw (obj ["label",str "p1";"targetId",str "T1";"openedBy",str "agent";"openedBy",str "unknown"])] in
  List.iter (fun value->check bool "malformed takeover receipts cannot manufacture a boundary Page" true
    (Result.is_error (Takeover.decode ~expected_id:51 value))) malformed;
  let native_calls=ref 0 and bounded_calls=ref 0 and mode=ref `Node in
  let run ~window_s script =
    incr bounded_calls;
    match (sent_of ~window_s script).step with
    | "space.open"->answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list"->answered tabs
    | step->failf "takeover escaped the native runner into bounded %s" step in
  let run_native script = match (sent_of ~window_s:0. script).step with
    | "page.native_workflow"->Error (Peer.Unobserved "lost original holding input")
    | "space.take_over"->
      incr native_calls;
      (match !mode with
       | `Node->Ok (in_node (control_stand_in ~ownership:"agentDelegatedToUser"
           ~user_page:"({spaceId:51,targetId:'TU',label:null,openedBy:'unknown'})" ^ script))
       | `Receipt value->answered value
       | `Lost->Error (Peer.Unobserved "takeover effect ran but response was lost"))
    | step->failf "unexpected native step %s" step in
  let peer=match Peer.open_space ~downloads:no_downloads ~run ~run_native ~now
      ~space:(Browser_configuration.Named_space "masc") ~version:"fixture" ~capture_directory:(capture_directory ()) with
    | Ok peer->peer | Error detail->fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let input=obj ["tabId",`Int 1;"expectedUrl",str "https://app.slack.com/";"maxChars",`Int 100;
    "steps",`List [obj ["method",str "click";"selector",str "#held"]]] in
  check string "original holding input becomes uncertain" "unknown"
    (failure_kind (Peer.dispatch ~command_id:"original-before-takeover" peer ~verb:Live.Page_native_workflow input));
  let pending=Peer.input_status peer in
  check bool "original pending input was recorded" true
    (match pending with Masc.Browser_ego_input.Uncertain value->value.command_id="original-before-takeover"
      | Ready _->false);
  let take ()=dispatch peer Live.Page_act (act_args (Lane.Action.Control Lane.Action.Take_over)) in
  let before= !bounded_calls in
  let taken=match take () with Ok value->value|Error _->fail "actual Node takeover wrapper failed" in
  check bool "native wrapper preserves unmanaged provenance" true (field "egoPage" taken=unmanaged);
  check bool "native takeover does not clear original pending input" true (Peer.input_status peer=pending);
  List.iter (fun value->mode:=`Receipt value;
    check string "invalid native DTO is an uncertain effect" "unknown" (failure_kind (take ()));
    check bool "invalid takeover does not reset input" true (Peer.input_status peer=pending)) malformed;
  mode:=`Lost;
  check string "lost native takeover is never replay permission" "unknown" (failure_kind (take ()));
  check bool "lost takeover retains the original pending generation" true (Peer.input_status peer=pending);
  check int "each explicit takeover uses the native runner exactly once" (List.length malformed+2) !native_calls;
  check int "takeover never installs a host deadline runner" before !bounded_calls

let test_native_workflow_pointer_ownership () =
  List.iter (fun (method_,fields) -> List.iter (fun mode ->
    let issued=ref 0 in
    let peer=opened (fun sent -> match sent.step with
      | "tabs.list" -> answered tabs
      | "page.native_workflow" ->
        incr issued;
        if !issued=1 then match mode with
          | `Lost -> Error (Peer.Unobserved "lost native workflow result")
          | `Before -> answered (obj ["completed",`List [];"effectStarted",`Bool false;
              "completedEffect",`Bool false;"inputReleased",`Bool true;
              "failure",obj ["index",`Int 0;"method",str "inputPreflight";"message",str "selector absent"]])
          | `Unreleased|`Contradicted -> answered (obj ["completed",`List [];"effectStarted",`Bool true;
              "completedEffect",`Bool false;"inputReleased",`Bool (mode=`Contradicted);
              "failure",obj ["index",`Int 0;"method",str method_;"message",str "SDK failed"]])
          | `Snapshot_failed -> answered (obj ["completed",`List [obj ["index",`Int 0;"method",str method_;"receipt",obj []]];
              "effectStarted",`Bool true;"completedEffect",`Bool true;"inputReleased",`Bool true;
              "failure",obj ["index",`Int 1;"method",str "snapshot";"message",str "snapshot failed"]])
          | `Unproven|`Proven -> answered (obj ["completed",`List [obj ["index",`Int 0;"method",str method_;
                "receipt",(if mode=`Proven then obj [] else `Null)]];
              "effectStarted",`Bool true;"completedEffect",`Bool true;"inputReleased",`Bool true;"failure",`Null;
              "urlBefore",str "https://app.slack.com/";"url",str "https://app.slack.com/";"title",str "Slack";
              "snapshot",str "root";"chars",`Int 4;"truncated",`Bool false])
        else answered (obj ["completed",`List [];"effectStarted",`Bool false;"completedEffect",`Bool false;
          "inputReleased",`Bool true;"failure",`Null;"urlBefore",str "https://app.slack.com/";
          "url",str "https://app.slack.com/";"title",str "Slack";"snapshot",str "root";"chars",`Int 4;"truncated",`Bool false])
      | other -> failf "unexpected workflow fixture step %s" other) in
    ignore (dispatch peer Live.Tabs_list (obj []));
    let call steps=dispatch peer Live.Page_native_workflow (obj ["tabId",`Int 1;
      "expectedUrl",str "https://app.slack.com/";"maxChars",`Int 1000;"steps",`List steps]) in
    let first=call [obj (("method",str method_)::fields)] in
    (match mode,first with
     | `Before,Error (Live.Before_effect _)
     | (`Lost|`Unreleased|`Contradicted|`Unproven),Error (Live.Outcome_unknown _ | Live.Observed_failure {disposition=Live.Uncertain;_})
     | `Snapshot_failed,Error (Live.Partial_failure _)
     | `Proven,Ok _ -> ()
     | (`Before|`Lost|`Unreleased|`Contradicted|`Unproven|`Proven|`Snapshot_failed),
       (Ok _|Error (Live.Before_effect _|Live.Partial_failure _|Live.Outcome_unknown _|Live.Observed_failure {disposition=(Live.Not_started|Live.Uncertain);_})) ->
       fail "workflow input result changed its effect classification");
    (match mode,call [] with
     | (`Proven|`Before|`Snapshot_failed),Ok _ -> check int "a settled or never-started input permits the next original request" 2 !issued
     | (`Lost|`Unreleased|`Contradicted|`Unproven),Error (Live.Before_effect _) ->
       check int "unknown release never dispatches another workflow" 1 !issued
     | (`Lost|`Unreleased|`Contradicted|`Unproven),Ok _|(`Proven|`Before|`Snapshot_failed),Error _
     | (`Lost|`Unreleased|`Contradicted|`Unproven),Error (Live.Partial_failure _|Live.Outcome_unknown _ | Live.Observed_failure {disposition=(Live.Not_started|Live.Uncertain);_}) ->
       fail "native input ownership did not survive the workflow boundary");
    ignore (dispatch peer Live.Tabs_list (obj [])))
      (* keyboard.type returns void in the SDK, so no real success carries a receipt for it. *)
      ([`Lost;`Unreleased;`Contradicted;`Unproven] @ (if method_="press" then [`Before] else [])
        @ (if method_="keyboard.type" then [] else [`Proven;`Snapshot_failed])))
    ["dragAndDrop",["selector",str "#source";"destination",str "#target"];
     "click",["selector",str "#source"];
     "dblclick",["selector",str "#source"];
     "mouse.click",["x",`Int 10;"y",`Int 20];
     "press",["selector",str "#editor";"key",str "ControlOrMeta+Enter"];
     "keyboard.press",["key",str "ControlOrMeta+Enter"];
     "keyboard.type",["text",str "x"];
     "keyboard.paste",["text",str "x"]]

(* A workflow whose holding step is never reached held nothing. It must not turn an operator's reset
   into a settled command. *)
let test_a_workflow_that_never_held_input_keeps_the_previous_readiness () =
  let module Input=Masc.Browser_ego_input in
  let issued=ref 0 in
  let peer=opened (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | "page.native_workflow" ->
      incr issued;
      let failed method_ ~released = answered (obj ["completed",`List [];"effectStarted",`Bool true;
        "completedEffect",`Bool false;"inputReleased",`Bool released;
        "failure",obj ["index",`Int 0;"method",str method_;"message",str "SDK failed"]]) in
      if !issued=1 then failed "keyboard.type" ~released:false
      else if !issued=2 then failed "fill" ~released:true
      else Error (Peer.Unstarted "no node here")
    | other -> failf "unexpected workflow fixture step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let call steps=dispatch peer Live.Page_native_workflow (obj ["tabId",`Int 1;
    "expectedUrl",str "https://app.slack.com/";"maxChars",`Int 1000;"steps",`List steps]) in
  check string "typing that never returned is unknown" "unknown"
    (failure_kind (call [obj ["method",str "keyboard.type";"text",str "x"]]));
  let pending=match Peer.input_status peer with Input.Uncertain pending -> pending
    | Ready _ -> fail "typing did not hold the input" in
  check bool "the operator resets the held input" true
    (Result.is_ok (Peer.assert_input_reset peer ~generation:pending.generation));
  let reset=Peer.input_status peer in
  check bool "the reset is the operator's" true
    (match reset with Input.Ready (Input.Operator_reset_asserted _) -> true | Ready Input.Command_settled | Uncertain _ -> false);
  check string "a fill that fails before the click is unknown" "unknown"
    (failure_kind (call [obj ["method",str "fill";"selector",str "#editor";"text",str "x"];
      obj ["method",str "click";"selector",str "#send"]]));
  check int "the second workflow ran" 2 !issued;
  check bool "a workflow that never held input leaves the operator's reset in place" true (Peer.input_status peer=reset);
  check string "a script that never started is refused before any effect" "before effect"
    (failure_kind (call [obj ["method",str "click";"selector",str "#send"]]));
  check int "the third workflow was asked for" 3 !issued;
  check bool "a script that never started leaves the operator's reset in place" true (Peer.input_status peer=reset)

let test_operator_input_recovery () =
  let module Input=Masc.Browser_ego_input in
  let module Operator=Masc.Browser_ego_operator in
  let answer label = function
    | Ok value -> value
    | Error _ as result -> failf "%s: %s" label (failure_kind result) in
  let issued=ref 0 and scripts=ref 0 and input_commands=ref [] and recovery_peer=ref None in
  let dialog=ego_dialog "alert" "check" in
  let completed steps ~has_effect ~snapshot = answered (obj [
    "completed",`List steps;"effectStarted",`Bool has_effect;"completedEffect",`Bool has_effect;
    "inputReleased",`Bool true;"failure",`Null;"urlBefore",str "https://app.slack.com/";
    "url",str "https://app.slack.com/";"title",str "Slack";"snapshot",str snapshot;
    "chars",`Int (String.length snapshot);"truncated",`Bool false]) in
  let peer=opened (fun sent -> incr scripts;match sent.step with
    | "tabs.list" -> answered tabs
    | "page.dialog" -> answered (obj ["dialog",dialog])
    | "page.native_workflow" ->
      incr issued;
      check bool "recovery workflows stay in the original Space/Page" true
        (sent.space=`Int 51 && field "tabId" sent.args=`Int 1 && field "label" sent.args=str "p1");
      let steps=Yojson.Safe.Util.to_list (field "steps" sent.args) in
      (match steps with
       | [] -> completed [] ~has_effect:false ~snapshot:"root"
       | [step] when field "method" step=str "click" ->
         let selector=text (field "selector" step) in
         let peer=match !recovery_peer with Some peer -> peer | None -> fail "recovery Peer is not bound" in
         let pending=match Peer.input_status peer with Input.Uncertain pending -> pending
           | Ready _ -> fail "nonempty workflow did not acquire input ownership" in
         check bool "the running click holds the original tab's input" true
           (Peer.input_busy peer && pending.tab_id=1 && pending.page_label="p1"
             && pending.operation="native_workflow");
         input_commands := (pending.command_id,selector) :: !input_commands;
         (match selector with
          | "#dialog" -> answered (obj [
              "completed",`List [obj ["index",`Int 0;"method",str "click";"receipt",obj ["dialog",dialog]]];
              "effectStarted",`Bool true;"completedEffect",`Bool true;"inputReleased",`Bool false;
              "failure",obj ["index",`Int 0;"method",str "click";"message",str "answer dialog";"dialog",dialog]])
          | "#continue" -> completed [obj ["index",`Int 0;"method",str "click";"receipt",obj []]]
              ~has_effect:true ~snapshot:"root\n  button Continue"
          | _ -> failf "unexpected recovery click %s" selector)
       | _ -> fail "unexpected recovery workflow steps")
    | other -> failf "unexpected recovery fixture step %s" other) in
  recovery_peer := Some peer;
  ignore (dispatch peer Live.Tabs_list (obj []));
  let args steps=obj ["tabId",`Int 1;"expectedUrl",str "https://app.slack.com/";"maxChars",`Int 1000;"steps",`List steps] in
  let first=Peer.dispatch ~command_id:"original-input-command" peer ~verb:Live.Page_native_workflow
    (args [obj ["method",str "click";"selector",str "#dialog"]]) in
  check string "dialog retains partial effect" "partial" (failure_kind first);
  (match first with
   | Error (Live.Partial_failure {receipt; _}) ->
     check string "a partial receipt written while input is pending says so" "release_uncertain"
       Yojson.Safe.Util.(receipt |> member "inputReadiness" |> to_string)
   | Ok _ | Error (Live.Before_effect _ | Live.Outcome_unknown _ | Live.Observed_failure _) -> fail "the dialog lost its partial receipt");
  let pending=match Peer.input_status peer with Input.Uncertain pending -> pending
    | Ready _ -> fail "dialog lost its pending input" in
  check string "pending input names original command" "original-input-command" pending.command_id;
  let accepted=answer "answer dialog" (dispatch peer Live.Page_act (Lane.Action.to_json
    (Lane.Action.On_tab {tab_id=1;frame_path=[];interaction=Lane.Action.Accept_dialog None}))) in
  check string "a result read while input is pending says so" "release_uncertain"
    Yojson.Safe.Util.(accepted |> member "inputReadiness" |> to_string);
  ignore (before_effect "dialog answer is not input-reset authority" (dispatch peer Live.Page_native_workflow (args [])));
  let connection:Operator.connection={client_id="original-client";space=Peer.space peer;recovery={
    status=(fun () -> Peer.input_status peer);busy=(fun () -> Peer.input_busy peer);
    assert_reset=(fun ~generation -> Peer.assert_input_reset peer ~generation);
    space_observation=(fun () -> Peer.space_observation peer)}} in
  let view=Operator.invoke (Some connection) (obj ["action",str "view";"arguments",obj []]) in
  let action=Yojson.Safe.Util.(view |> member "actions" |> to_list |> List.hd) in
  let fields=Yojson.Safe.Util.(action |> member "arguments") in
  let invoke fields=Operator.invoke (Some connection) (obj ["action",str "assert_input_reset";"arguments",fields]) in
  let before= !scripts in
  let replace key value=match fields with `Assoc fields -> obj ((key,str value)::List.remove_assoc key fields)
    | _ -> fail "form arguments missing" in
  List.iter (fun fields -> check string "foreign/stale assertion rejected" "not_applied"
    Yojson.Safe.Util.(invoke fields |> member "outcome" |> to_string))
    [replace "clientId" "replacement-client";replace "spaceId" "52";replace "generation" "old";replace "confirmation" "go"];
  check string "human assertion applied" "operator_asserted"
    Yojson.Safe.Util.(invoke fields |> member "outcome" |> to_string);
  check string "same assertion is idempotent" "operator_asserted"
    Yojson.Safe.Util.(invoke fields |> member "outcome" |> to_string);
  check int "private view/assertions issue no browser scripts" before !scripts;
  let resumed=answer "continue after explicit operator assertion" (dispatch peer Live.Page_native_workflow (args [])) in
  check string "resume retains operator provenance, not native release proof" "operator_asserted"
    Yojson.Safe.Util.(resumed |> member "inputReadiness" |> to_string);
  let continued=answer "new click after explicit operator assertion"
    (Peer.dispatch ~command_id:"continued-input-command" peer ~verb:Live.Page_native_workflow
      (args [obj ["method",str "click";"selector",str "#continue"]])) in
  check bool "the new click returns complete native input settlement" true
    (field "completed" continued=`List [obj ["index",`Int 0;"method",str "click";"receipt",obj []]]
      && field "effectStarted" continued=`Bool true && field "completedEffect" continued=`Bool true
      && field "inputReleased" continued=`Bool true && field "failure" continued=`Null
      && field "snapshot" continued=str "root\n  button Continue");
  check bool "new input settles instead of retaining the operator assertion as native proof" true
    (Peer.input_status peer=Input.Ready Input.Command_settled && not (Peer.input_busy peer)
      && field "inputReadiness" continued=str "command_settled");
  check (list (pair string string)) "original click is never replayed; the new command clicks once"
    ["original-input-command","#dialog";"continued-input-command","#continue"] (List.rev !input_commands);
  check int "only original, empty observation and new input workflows were issued" 3 !issued

let test_native_space_status () =
  let ownership=ref "agentDelegatedToUser" and invalid=ref false and unavailable=ref false in
  let calls=ref 0 and output=ref "" in
  let run ~window_s script =
    let sent=sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered tabs
    | "space.status" ->
      incr calls;
      check bool "metadata keeps the original numeric Space" true (sent.space=`Int 51);
      check (float 0.) "metadata uses the SDK clock" 0. sent.window_s;
      if !unavailable then Error (Peer.Unobserved "metadata connection lost") else
      let shim=Printf.sprintf {js|
const seen=[];
process.on('exit',()=>console.log('seen '+JSON.stringify(seen)));
const forbidden=name=>{seen.push(name);throw new Error('unexpected '+name);};
const takeOverTaskSpace=async()=>forbidden('takeOver');
const claimTaskSpace=async()=>forbidden('claim');
const taskSpace=async()=>forbidden('taskSpace');
const listTaskSpaces=async()=>{seen.push('listTaskSpaces');return [{id:%d,name:'Renamed native Space',ownership:%s}];};
|js} (if !invalid then 52 else 51) (Yojson.Safe.to_string (str !ownership)) in
      output:=in_node (shim ^ script);Ok !output
    | "space.hand_off" -> answered (obj ["spaceId",`Int 51;"spaceName",str "SDK Space"])
    | other -> failf "unexpected Space status fixture step %s" other in
  let peer=match Peer.open_space ~run ~run_native:(run ~window_s:0.) ~now
    ~space:(Browser_configuration.Existing_space 51) ~version:"fixture"
    ~capture_directory:(capture_directory ()) ~downloads:no_downloads with
    | Ok peer -> peer | Error detail -> fail detail in
  check bool "attachment metadata is retained" true (Option.is_some (Peer.space_observation peer));
  let status ()=dispatch peer Live.Page_act (obj ["action",str "space_status"]) in
  let value=match status () with Ok value -> value | Error _ -> fail "delegated metadata query failed" in
  check string "native owner is returned verbatim" !ownership (text (field "ownership" value));
  check string "native name can refresh without rebinding" "Renamed native Space" (text (field "spaceName" value));
  check int "original numeric binding is returned" 51 (Yojson.Safe.Util.to_int (field "spaceId" value));
  check (float 0.) "metadata receipt is dated" (now ()) (Yojson.Safe.Util.to_float (field "observedAt" value));
  check string "connection attachment identity remains separate" "SDK Space" (Peer.space peer).name;
  check bool "query uses only task metadata" true
    (contains !output "seen [\"listTaskSpaces\"]");
  let module Operator=Masc.Browser_ego_operator in
  let connection:Operator.connection={client_id="original-client";space=Peer.space peer;recovery={
    status=(fun () -> Peer.input_status peer);busy=(fun () -> Peer.input_busy peer);
    assert_reset=(fun ~generation -> Peer.assert_input_reset peer ~generation);
    space_observation=(fun () -> Peer.space_observation peer)}} in
  let before= !calls in
  let view=Operator.invoke (Some connection) (obj ["action",str "view";"arguments",obj []]) in
  check bool "operator form shows the actual native observation" true
    (contains (text (field "message" view)) "agentDelegatedToUser");
  check int "form reading never dispatches SDK work" before !calls;
  ownership:="future-native-owner";
  let value=match status () with Ok value -> value | Error _ -> fail "opaque metadata value refused" in
  check string "unfamiliar native ownership is data, not a default decision" !ownership (text (field "ownership" value));
  invalid:=true;
  ignore (before_effect "foreign Space metadata is refused" (status ()));
  check bool "failed refresh invalidates the earlier cached observation" true (Option.is_none (Peer.space_observation peer));
  invalid:=false;unavailable:=true;
  ignore (before_effect "metadata transport failure sends no Page effect" (status ()));
  unavailable:=false;
  ignore (status ());
  ignore (dispatch peer Live.Page_act (obj ["action",str "hand_off"]));
  check bool "control changes invalidate cached owner metadata" true (Option.is_none (Peer.space_observation peer))

let test_explicit_completion_is_terminal_and_never_replayed () =
  let scenario reply keep =
    let calls=ref 0 in
    let run ~window_s script = let sent=sent_of ~window_s script in
      match sent.step with
      | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
      | "space.finish" -> incr calls; reply sent
      | other -> failf "unexpected post-completion SDK call %s" other in
    let peer=match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now
        ~space:(Browser_configuration.Existing_space 51) ~version:"fixture" ~capture_directory:(capture_directory ()) with
      | Ok peer -> peer | Error detail -> fail detail in
    check bool "active Space cannot justify retirement deletion" true (Result.is_error (Peer.retirement_settlement peer));
    let args=Browser_lane.Action.to_json (Control (Finish_space keep)) in
    let first=dispatch peer Live.Page_act args in
    let second=dispatch peer Live.Page_act args in
    check int "finish dispatched exactly once" 1 !calls;
    ignore (before_effect "former Page work" (dispatch peer Live.Tabs_list (obj [])));
    ignore (before_effect "takeover after completion" (dispatch peer Live.Page_act (obj ["action",str "take_over"])));
    peer,first,second in
  let receipt ?(closed=true) ?(kept=[]) ?(removed=[]) ()=obj ["spaceId",`Int 51;"closedSpace",`Bool closed;
    "keptManagedLabels",`List (List.map str kept);"closedManagedLabels",`List (List.map str removed);"preservedUnmanagedCount",`Int 0] in
  let peer,first,second=scenario (fun sent ->
    check bool "empty retention forwarded to native SDK" true (field "keep" sent.args=`List []);
    answered (receipt ())) (Keep_labels []) in
  check bool "confirmed receipt is returned without replay" true (Result.is_ok first && first=second);
  check bool "confirmed closure settles files" true (Peer.retirement_settlement peer=Ok ());
  let peer,first,second=scenario (fun _ -> answered (receipt ~closed:false ~kept:["p2"] ())) (Keep_labels ["p2"]) in
  check bool "retained result has a stable native receipt" true (Result.is_ok first && first=second);
  check bool "retained native tabs preserve file ownership" true (Result.is_error (Peer.retirement_settlement peer));
  List.iter (fun kept ->
    let peer,first,second=scenario (fun sent ->
      check bool "all is forwarded as native literal" true (field "keep" sent.args=str "all");
      answered (receipt ~closed:false ~kept ())) Keep_all in
    check bool "all has a stable terminal receipt, even without managed Pages" true
      (Result.is_ok first && first=second);
    check bool "all retains Space-backed file ownership" true (Result.is_error (Peer.retirement_settlement peer));
    ignore (before_effect "cannot change all policy after completion"
      (dispatch peer Live.Page_act (Browser_lane.Action.to_json (Control (Finish_space (Keep_labels [])))))))
    [[];["p2";"p3"]];
  List.iter (fun value ->
    let peer,first,second=scenario (fun _ -> answered value) Keep_all in
    check bool "all cannot confirm closure or closed managed Pages" true
      (match first with Error (Live.Outcome_unknown _) -> true | _ -> false);
    ignore (before_effect "invalid all receipt is never replayed" second);
    check bool "invalid all receipt preserves files" true (Result.is_error (Peer.retirement_settlement peer)))
    [receipt ();receipt ~closed:false ~removed:["p1"] ()];
  let peer,first,second=scenario (fun _ -> Error (Peer.Unobserved "lost all completion")) Keep_all in
  check bool "lost all completion is unknown" true
    (match first with Error (Live.Outcome_unknown _) -> true | _ -> false);
  ignore (before_effect "lost all completion is never replayed" second);
  check bool "lost all completion preserves files" true (Result.is_error (Peer.retirement_settlement peer));
  List.iter (fun reply ->
    let peer,first,second=scenario reply (Keep_labels []) in
    check bool "lost or invalid completion is unknown" true (match first with Error (Live.Outcome_unknown _ | Live.Observed_failure {disposition=Live.Uncertain;_}) -> true | _ -> false);
    ignore (before_effect "uncertain completion replay" second);
    check bool "unknown completion preserves files" true (Result.is_error (Peer.retirement_settlement peer)))
    [(fun _ -> Error (Peer.Unobserved "lost completion"));(fun _ -> answered `Null);
     (fun _ -> answered (obj ["spaceId",`Int 999;"closedSpace",`Bool true;"keptManagedLabels",`List [];
       "closedManagedLabels",`List [];"preservedUnmanagedCount",`Int 0]))]

let () =
  run "browser_ego_peer" [
    "ego", [
      test_case "Space status reads native metadata without Page or control effects" `Quick test_native_space_status;
      test_case "production workflow envelope preserves special JSON header keys" `Quick test_native_workflow_json_headers;
      test_case "first evaluation timeout preserves unknown native receipt" `Quick test_first_evaluation_timeout_preserves_unknown_native_receipt;
      test_case "adopted managed Pages retain origin while using native actions" `Quick test_adopted_managed_page_uses_native_actions_without_changing_origin;
      test_case "takeover receipts and native runner preserve pending input" `Quick test_takeover_receipt_and_native_runner_preserve_pending_input;
      test_case "saved fetch survives snapshot failure and reaches the download broker" `Quick test_saved_fetch_survives_snapshot_failure_and_reaches_download_broker;
      test_case "a raw drag never confirms input release" `Quick test_native_drag_and_release;
      test_case "a raw drag reports what its script saw" `Quick test_a_raw_drag_reports_what_the_script_saw;
      test_case "a target drag settles only from the receipt it returns" `Quick test_a_target_drag_settles_only_from_the_receipt_it_returns;
      test_case "operator input assertion resumes the same peer without replay" `Quick test_operator_input_recovery;
      test_case "native workflows retain input ownership after a lost result" `Quick test_native_workflow_pointer_ownership;
      test_case "a workflow that never held input keeps the previous readiness" `Quick test_a_workflow_that_never_held_input_keeps_the_previous_readiness;
      test_case "chooser upload respects uncertain input release" `Quick test_chooser_upload_respects_uncertain_pointer_release;
      test_case "explicit completion is terminal and never replayed" `Quick test_explicit_completion_is_terminal_and_never_replayed;
      test_case "the space opens by name and is held by number" `Quick test_the_space_opens_by_name_and_is_held_by_number;
      test_case "the spaces of a name are listed without opening one" `Quick test_the_spaces_of_a_name_are_listed_without_opening_one;
      test_case "the listing script runs under node" `Quick test_the_listing_script_runs_under_node;
      test_case "numeric Space references never create replacements" `Quick test_exact_numeric_space_resume;
      test_case "Page provenance survives document projection" `Quick test_page_provenance_survives_document_projection;
      test_case "space inspection preserves user ownership and uncertain listings" `Quick test_space_name_inspection_is_read_only_and_requires_evidence;
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
      test_case "native captures preserve options and consume owned files" `Quick test_native_capture_options_and_owned_file;
      test_case "native activation retains original Space authority" `Quick test_native_activation_keeps_space_authority;
      test_case "effects answer what happened" `Quick test_effects_answer_what_happened;
      test_case "history moves one entry and waits for it" `Quick test_history_moves_one_entry;
      test_case "a snapshot reads ego's own tree" `Quick test_a_snapshot_reads_egos_own_tree;
      test_case "dialogs are listed and answered" `Quick test_dialogs_are_listed_and_answered;
      test_case "an input that opens a dialog answers with it" `Quick test_an_input_that_opens_a_dialog_answers_with_it;
      test_case "the dialog scripts run against a stand-in in node" `Quick test_dialog_scripts_in_node;
      test_case "a snapshot target is found by ego and checked first" `Quick test_a_snapshot_target_is_found_by_ego_and_checked_first;
      test_case "native control wait preserves ownership and uncertain input" `Quick test_native_space_control_wait;
      test_case "native Page management preserves identity and operator control" `Quick test_native_page_management;
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
