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
      else Yojson.Safe.from_string (trailing (find "task = await taskSpace(") ");")); window_s }

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
  match Peer.open_space ~downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory with
  | Ok peer -> peer
  | Error detail -> failf "the space did not open: %s" detail

(* Native inventory carries Page metadata without a Page.info read. *)
let tab_row ?origin ~label ~target ~title ~url ~active () =
  let origin=match origin,label with Some value,_ -> value | None,`Null -> "unknown" | None,_ -> "agent" in
  obj ["label",label;"targetId",str target;"openedBy",str origin;"title",str title;"url",str url;"active",`Bool active]

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

let test_a_claim_reclaims_only_the_space_that_was_asked_for () =
  let claim result = Peer.claim_space ~space_id:7 ~run:(fun ~window_s:_ script ->
    check bool "claims through the SDK claim, never a takeover" true
      (contains script "await claimTaskSpace(args.spaceId)" && not (contains script "takeOverTaskSpace"));
    result) in
  check bool "a claimed Space id and name come back" true
    (claim (answered (obj ["spaceId",`Int 7;"name",str "masc-keepers";"ownership",str "agent"]))
     = Ok (7,"masc-keepers"));
  check bool "a foreign Space id is refused" true
    (Result.is_error (claim (answered (obj ["spaceId",`Int 8;"name",str "other";"ownership",str "agent"]))));
  check bool "a Space still held by the operator is refused" true
    (Result.is_error (claim (answered (obj ["spaceId",`Int 7;"name",str "masc-keepers";"ownership",str "user"]))));
  check bool "a frame error is a refusal" true (Result.is_error (claim (failed "claim refused")));
  check bool "a timeout is a refusal" true (Result.is_error (claim (Error Peer.Timed_out)))

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
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  check int "space number" 51 (Peer.space_id peer);
  check string "attachment matches the configured literal name" "SDK Space" (Peer.space peer).name;
  ignore (dispatch peer Live.Tabs_list (obj []));
  check (result unit string) "finish" (Ok ()) (Peer.finish peer);
  check (list string) "opened by name, then held by number"
    [ "space.open \"SDK Space\""; "tabs.list 51"; "space.finish 51" ]
    (List.rev_map (fun (step, space) -> step ^ " " ^ Yojson.Safe.to_string space) !spaces);
  let user = Peer.open_space ~run_native:(fun _ -> Error (Peer.Unstarted "no native command in this fixture")) ~downloads:no_downloads ~now ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) ~space:(Browser_configuration.Named_space "SDK Space")
      ~run:(fun ~window_s:_ _ -> answered (obj ["spaceId",`Int 7;"name",str "SDK Space";"ownership",str "user"])) in
  check bool "a space the operator owns is refused" true (Result.is_error user);
  let in_use = Peer.open_space ~run_native:(fun _ -> Error (Peer.Unstarted "no native command in this fixture")) ~downloads:no_downloads ~now ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) ~space:(Browser_configuration.Named_space "masc")
      ~run:(fun ~window_s:_ _ -> failed "EGO_TASK_SPACE_NAME_IN_USE: masc") in
  check (result reject string) "ego's own refusal is kept" (Error "EGO_TASK_SPACE_NAME_IN_USE: masc") (Result.map ignore in_use);
  List.iter (fun fields ->
    let result=Peer.open_space ~run_native:(fun _ -> Error (Peer.Unstarted "unused"))
      ~downloads:no_downloads ~now ~version:"fixture" ~capture_directory:(capture_directory ()) ~space:(Browser_configuration.Named_space "SDK Space")
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
      ~downloads:no_downloads ~now ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) ~space:(Browser_configuration.Named_space "SDK Space")
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
  let attachment ?(name="SDK Space") id ownership ()=answered (obj ["spaceId",`Int id;"name",str name;"ownership",str ownership]) in
  (match open_reference (Browser_configuration.Existing_space 51) (attachment 51 "agentDelegatedToUser") with
   | Ok peer ->
       check int "resumes the exact ID while preserving handoff" 51 (Peer.space_id peer);
       check string "an exact ID keeps the SDK's observed name" "SDK Space" (Peer.space peer).name
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
  (match open_reference (Named_space "51") (attachment ~name:"51" 74 "agent") with Ok _ -> () | Error detail -> fail detail);
  check bool "numeric-looking names remain names" true ((List.hd !calls).space=str "51");
  List.iter (fun (requested,actual,id) ->
    check bool "a differently named native Space never becomes this Peer" true
      (Result.is_error (open_reference (Named_space requested) (attachment ~name:actual id "agent")));
    check int "name mismatch permits no replacement or retry" 1 (List.length !calls))
    ["51","SDK Space",51;"work","renamed work",74;"work","Work",74;" work ","work",74]

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
  ignore (before_effect "an unknown browser action" (dispatch peer Live.Page_act
    (obj ["action",str "open_window";"url",str "https://example.test/window"])));
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

(* The inventory script asks ego for each tab's window; a tab ego does not
   place in a window comes back without windowId. The tab surface that reads
   project their tab list through keeps the window. *)
let test_tabs_carry_the_window_ego_names () =
  let module Surface=Masc.Browser_surface in
  let with_window window = function
    | `Assoc fields -> `Assoc (fields @ ["windowId",window])
    | _ -> fail "a tab row is an object" in
  let slack = tab_row ~label:(str "p1") ~target:"T1" ~title:"Slack" ~url:"https://app.slack.com/" ~active:true () in
  let blank = tab_row ~label:(str "p2") ~target:"T2" ~title:"" ~url:"about:blank" ~active:false () in
  let listing = ref (`List [with_window (`Int 7) slack; blank]) in
  let peer = opened (fun sent -> match sent.step with
    | "tabs.list" -> answered !listing
    | other -> failf "unexpected step %s" other) in
  (match dispatch peer Live.Tabs_list (obj []) with
   | Ok rows ->
     check (list (option int)) "the window ego named, and none for the tab it did not place" [Some 7; None]
       (List.map (fun row -> Yojson.Safe.Util.(row |> member "windowId" |> to_int_option)) (Yojson.Safe.Util.to_list rows));
     let surface tab_id = match Surface.inventory_tab ~tab_id rows with
       | Ok tab -> tab.Surface.window_id
       | Error detail -> failf "the tab surface refused tab %d: %s" tab_id detail in
     check (list (option int)) "the tab surface keeps it" [Some 7; None]
       (List.map (fun row -> surface Yojson.Safe.Util.(row |> member "id" |> to_int)) (Yojson.Safe.Util.to_list rows))
   | Error _ -> fail "tabs were not listed");
  List.iter (fun (label, window) ->
    listing := `List [with_window window slack];
    ignore (before_effect label (dispatch peer Live.Tabs_list (obj []))))
    ["a negative window",`Int (-1); "a window named by text",str "7"; "a null window",`Null]

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
    | "page.document" -> page_answer ~label:"p1" (obj ["documentId",str "d1";"url",str "https://app.slack.com/";
        "title",str "Slack";"html",str "<html></html>";"htmlComplete",`Bool true;"htmlUnavailableReason",`Null])
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  (match dispatch peer Live.Page_read (obj ["tabId",`Int 1;"includeHtml",`Bool true]) with
   | Ok page -> check int "the document's tabId" 1 (Yojson.Safe.Util.to_int (field "tabId" page));
     check string "the document source" "<html></html>" (text (field "html" page))
   | Error _ -> fail "the document read failed");
  check bool "the document script is the shared one" true
    (String_util.contains_substring (text (field "fn" (List.hd !asked).args)) Lane.Document.runtime);
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
  (match dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Reload})) with
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
    (failure_kind (dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=3;interaction=Lane.Action.Close_tab}))));
  reply := (fun _ -> answered (obj ["closed",`Bool true]));
  (match dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=3;interaction=Lane.Action.Close_tab})) with
   | Ok receipt -> check string "the close" {|{"inputReadiness":"command_settled","tabId":3,"action":"close_tab","closed":true}|} (Yojson.Safe.to_string receipt)
   | Error _ -> fail "close failed");
  let before = runs () in
  check string "a closed tab is gone" "browser tab is no longer present"
    (before_effect "a closed tab" (dispatch peer Live.Page_read (obj ["tabId",`Int 3])));
  check int "and its read ran no script" before (runs ())

let viewport : Lane.Pointer.viewport = {document_id="d1"; width=800.; height=600.; scroll_x=0.; scroll_y=0.}
let observed_url = "https://app.slack.com/"
let interact_args ?(tab_id=1) action =
  Yojson.Safe.Util.member "args"
    (Lane.verb_json (Lane.Page_interact {tab_id;expected_url=Some observed_url;action}))
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
  let before = runs () in
  check string "the operator's tab" "before effect"
    (failure_kind (dispatch peer Live.Page_interact (interact_args ~tab_id:2 (Lane.Click_node {document_id="d1";node_id="send"}))));
  check string "control characters" "before effect" (failure_kind (interact (Lane.Type_text {document_id="d1";text="a\nb"})));
  check string "a key ego cannot press" "before effect"
    (failure_kind (interact (Lane.Press_key {document_id="d1";key=chord ~key:"é" ~modifiers:["Control"]})));
  List.iter (fun action ->
    check bool (Lane.interaction_verb action ^ " is not served") true
      (String_util.contains_substring (before_effect "an input ego does not serve" (interact action)) "not served by an ego connection"))
    [];
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
       | Lane.Activate_tab | Lane.Click _ | Lane.Fill _ | Lane.Set_viewport _
       | Lane.Double_click _ | Lane.Double_click_at _ | Lane.Type_text _ | Lane.Press_key _
       | Lane.Scroll _ | Lane.Hover _ | Lane.Drag_to _ | Lane.Hover_at _ | Lane.Tap_at _
       | Lane.Swipe _ | Lane.Click_at _ | Lane.Scroll_at _ | Lane.Follow_link _
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

let test_unattestable_raw_input_is_refused_before_effect () =
  let module Input=Masc.Browser_ego_input in
  let calls=ref [] and lose_receipt=ref false in
  let peer=opened (fun sent ->
    calls:=sent.step::!calls;
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.target_input" ->
      if !lose_receipt then Error (Peer.Unobserved "original receipt lost")
      else answered (obj ["urlBefore",str observed_url;"receipt",obj [];"error",`Null;
        "tab",obj ["url",str observed_url;"title",str "Slack"]])
    | other -> failf "raw-input preflight must not run %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let selector=Lane.Selector "#source" and scene=Lane.Scene_node {document_id="d1";node_id="source"} in
  let raw=[Lane.Drag_to {source=selector;destination=selector;via=[{x=0.5;y=0.5}];duration_ms=0};
    Lane.Drag_to {source=scene;destination=selector;via=[];duration_ms=0};
    Lane.Drag_to {source=selector;destination=scene;via=[];duration_ms=0}] in
  let refuse readiness=List.iter (fun action ->
    let before=List.length !calls in
    ignore (before_effect "unattestable raw input" (dispatch peer Live.Page_interact (interact_args action)));
    check int "no native resolution or input call" before (List.length !calls);
    check bool "preflight preserves exact readiness" true (Peer.input_status peer=readiness)) raw in
  refuse (Peer.input_status peer);
  let supported=Lane.Drag_to {source=selector;destination=Lane.Selector "#destination";via=[];duration_ms=0} in
  check string "selector drag still uses native observed dragAndDrop" "served"
    (failure_kind (dispatch peer Live.Page_interact (interact_args supported)));
  lose_receipt:=true;
  check string "a supported input with a lost receipt remains unknown" "unknown"
    (failure_kind (Peer.dispatch ~command_id:"original-supported-drag" peer ~verb:Live.Page_interact (interact_args supported)));
  let pending=Peer.input_status peer in
  (match pending with Input.Uncertain value -> check string "original command retained" "original-supported-drag" value.command_id
   | Ready _ -> fail "lost native receipt did not retain pending input");
  refuse pending

let test_invalid_workflow_is_refused_before_any_step () =
  let calls=ref 0 in
  let peer=opened (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | "page.native_workflow" -> incr calls;Error (Peer.Unobserved "original supported input result lost")
    | other -> failf "workflow preflight must not run %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let args steps=obj ["tabId",`Int 1;"expectedUrl",str observed_url;"maxChars",`Int 1000;"steps",`List steps] in
  let fill=obj ["method",str "fill";"selector",str "#editor";"text",str "earlier effect"] in
  let click=obj ["method",str "click";"selector",str "#send"] in
  let unavailable=args [fill;obj ["method",str "keyboard.type";"text",str "raw";"unexpected",`Bool true];click] in
  let refuse readiness=
    let before= !calls in
    let message=before_effect "whole workflow admission" (dispatch peer Live.Page_native_workflow unavailable) in
    check bool "refusal identifies the malformed later raw step" true
      (contains message "step[1]" && contains message "keyboard.type" && contains message "unexpected");
    check int "even the first fill is never dispatched" before !calls;
    check bool "preflight never changes existing input readiness" true (Peer.input_status peer=readiness) in
  refuse (Peer.input_status peer);
  check string "supported original click can still become uncertain" "unknown"
    (failure_kind (dispatch peer Live.Page_native_workflow (args [click])));
  check int "one supported command entered native execution" 1 !calls;
  refuse (Peer.input_status peer)

(* Generate private captures with the actual fixed producer and the shared
   documented-native transport stand-in. The Peer must bind the captures to
   its own freshly recorded intent; no test fabricates a release receipt. *)
let raw_capture sent mode =
  let directory=capture_directory () in
  let arguments=Filename.concat directory "arguments.json"
  and producer=Filename.concat directory "producer.js"
  and results=Filename.concat directory "captures.json" in
  Yojson.Safe.to_file arguments (obj ["source",field "expectedSourcePage" sent.args;
    "binding",field "nativeInputWindows" sent.args]);
  Out_channel.with_open_bin producer (fun channel->output_string channel Masc.Browser_ego_raw_type.script);
  let pid=Unix.create_process "node" [|"node";"test_browser_ego_raw_type.cjs";arguments;producer;results|]
    Unix.stdin Unix.stdout Unix.stderr in
  let _,status=Unix.waitpid [] pid in
  (match status with Unix.WEXITED 0->()
   | WEXITED _|WSIGNALED _|WSTOPPED _->fail "fixed native producer stand-in failed");
  let cases=Yojson.Safe.from_file results |> Yojson.Safe.Util.to_list in
  match List.find_opt (fun row->field "mode" row=str mode) cases with
  | Some row->field "capture" row
  | None->fail "native producer case is absent"

let public_input_result = function
  | Ok receipt -> "",receipt
  | Error (Live.Observed_failure {message;receipt;_}|Live.Partial_failure {message;receipt;_}) -> message,receipt
  | Error (Live.Before_effect message|Live.Outcome_unknown message) -> message,`Null

(* The readiness [with_session_state] stamps on what leaves the peer. *)
let reported_readiness peer result = match Peer.with_session_state peer ~sdk_process_started_at:None result with
  | Ok receipt | Error (Live.Observed_failure {receipt;_}|Live.Partial_failure {receipt;_}) -> text (field "inputReadiness" receipt)
  | Error (Live.Before_effect _|Live.Outcome_unknown _) -> fail "with_session_state left a failure without its receipt"

let private_native_data_stays_private result =
  let message,receipt=public_input_result result in
  let public=message ^ Yojson.Safe.to_string receipt in
  List.iter (fun private_value->check bool (private_value ^ " is not public") false (contains public private_value))
    ["PRIVATE_NATIVE_HEADER_SENTINEL";"nativeInputWindow";"bindingName";"worldName";"nonce";"intervalEvents"]

let test_raw_type_settles_only_its_exact_native_window () =
  let module Input=Masc.Browser_ego_input in
  List.iter (fun (mode,served,settled)->
    let raw_calls=ref 0 and next_calls=ref 0 and bound=ref None in
    let peer=opened (fun sent->match sent.step with
      | "tabs.list"->answered tabs
      | "page.native_type"->
        incr raw_calls;
        check (float 0.) "raw execution uses the native runner" 0. sent.window_s;
        let source=field "expectedSourcePage" sent.args in
        check bool "source binds full observed native identity" true
          (source=obj ["spaceId",`Int 51;"label",str "p1";"targetId",str "T1";"openedBy",str "agent"]);
        let guarded=field "input" sent.args |> text |> Yojson.Safe.from_string in
        check string "ordinary input retains expected URL" observed_url (text (field "expectedUrl" guarded));
        check string "ordinary input retains observed document" "d1" (text (field "documentId" guarded));
        check bool "ordinary guard remains the fixed deep active-element guard" true
          (contains (text (field "guard" sent.args)) "shadowRoot"
           && contains (text (field "guard" sent.args)) "documentId");
        (match !bound with
         | Some peer->(match Peer.input_status peer with
           | Input.Uncertain pending->
             check string "native producer uses the recorded command" pending.command_id
               (text (field "commandId" (field "nativeInputWindows" sent.args)));
             check string "native producer uses the recorded generation" pending.generation
               (text (field "generation" (field "nativeInputWindows" sent.args)))
           | Ready _->fail "native raw call preceded the recorded intent")
         | None->fail "the peer is not bound");
        let capture=raw_capture sent (if mode="cleanup-malformed" then "cleanup" else mode) in
        answered (obj (["capture",capture] @ if mode="cleanup-malformed" then ["nativeError",
          obj ["code",str "EGO_PAGE_DIALOG_OPENED";"private",str "PRIVATE_NATIVE_HEADER_SENTINEL"]] else []))
      | "page.target_input"->incr next_calls;answered (obj ["urlBefore",str observed_url;"receipt",obj [];
          "error",`Null;"tab",obj ["url",str observed_url;"title",str "Slack"]])
      | step->failf "raw typing unexpectedly ran %s" step) in
    bound:=Some peer;
    ignore (dispatch peer Live.Tabs_list (obj []));
    let prior=Peer.input_status peer in
    let result=Peer.dispatch ~command_id:("ordinary-raw-" ^ mode) peer ~verb:Live.Page_interact
      (interact_args (Lane.Type_text {document_id="d1";text="a"})) in
    check string "completion distinguishes cleanup and unconfirmed windows" served (failure_kind result);
    private_native_data_stays_private result;
    let _,receipt=public_input_result result in
    if List.mem mode ["normal";"cleanup";"cleanup-malformed"] then begin
      check bool "raw success never forges an SDK action receipt" true (field "receipt" receipt=`Null);
      check bool "completion is a separate public native summary" true (field "nativeCompletion" receipt<>`Null)
    end;
    if mode="guard" then begin
      check bool "proven-unentered restores exact prior readiness" true (Peer.input_status peer=prior);
      check bool "instrumentation effects are not mislabeled before-effect" true (field "effectStarted" receipt=`Bool true)
    end;
    check bool "only completed or proven-unentered input settles" settled
      (match Peer.input_status peer with Input.Ready _->true|Uncertain _->false);
    (match Peer.input_status peer with
     | Input.Uncertain pending->check string "original command remains pending" ("ordinary-raw-" ^ mode) pending.command_id
     | Ready _->());
    check string "the answer reports where input stands" (if settled then "command_settled" else "release_uncertain")
      (reported_readiness peer result);
    let next=dispatch peer Live.Page_interact (interact_args (Lane.Click_target (Lane.Target_ref 12))) in
    check int "the next input runs once, without replaying the raw input" 1 !next_calls;
    check string "the next input is served whatever the earlier readiness" "served" (failure_kind next);
    check int "one Peer raw invocation" 1 !raw_calls)
    ["normal","served",true;"cleanup","partial",true;"cleanup-malformed","partial",true;"guard","unknown",true;
     "dialog","unknown",false;"context","unknown",false;"value","unknown",false]

let test_raw_type_lost_and_private_failures_remain_pending () =
  let module Input=Masc.Browser_ego_input in
  List.iter (fun mode->
    let calls=ref 0 in
    let peer=opened (fun sent->match sent.step with
      | "tabs.list"->answered tabs
      | "page.native_type"->
        incr calls;
        if mode="lost" then Error (Peer.Unobserved "PRIVATE_NATIVE_HEADER_SENTINEL")
        else answered (obj ["capture",`Null;"private",str "PRIVATE_NATIVE_HEADER_SENTINEL"])
      | step->failf "unconfirmed raw input unexpectedly ran %s" step) in
    ignore (dispatch peer Live.Tabs_list (obj []));
    let result=Peer.dispatch ~command_id:("uncertain-" ^ mode) peer ~verb:Live.Page_interact
      (interact_args (Lane.Type_text {document_id="d1";text="a"})) in
    check string "a missing reply or capture never settles" "unknown" (failure_kind result);
    private_native_data_stays_private result;
    check bool "original input remains Pending" true
      (match Peer.input_status peer with Input.Uncertain _->true|Ready _->false);
    check int "no raw replay" 1 !calls) ["lost";"malformed"]

let test_raw_type_retains_only_strict_native_diagnostics () =
  let module Input=Masc.Browser_ego_input in
  let diagnostic_fields=["code",str "EGO_PAGE_DIALOG_OPENED";"method",str "Runtime.evaluate";
    "sessionId",str "actual-native-session";"dialog",obj ["type",str "alert";"message",str "owned dialog"]] in
  let diagnostic=obj diagnostic_fields in
  List.iter (fun (valid,native_error)->
    let calls=ref 0 in
    let peer=opened (fun sent->match sent.step with
      | "tabs.list"->answered tabs
      | "page.native_type"->incr calls;answered (obj ["capture",raw_capture sent "guard";"nativeError",native_error])
      | step->failf "native diagnostic unexpectedly dispatched %s" step) in
    ignore (dispatch peer Live.Tabs_list (obj []));
    let prior=Peer.input_status peer in
    let result=Peer.dispatch ~command_id:"raw-native-diagnostic" peer ~verb:Live.Page_interact
      (interact_args (Lane.Type_text {document_id="d1";text="a"})) in
    check string "SDK error never becomes a successful input" "unknown" (failure_kind result);
    private_native_data_stays_private result;
    let _,receipt=public_input_result result in
    if valid then begin
      check bool "recognized SDK observation is retained without arbitrary prose" true (field "nativeError" receipt=diagnostic);
      check bool "verified no holding entry restores prior readiness" true (Peer.input_status peer=prior)
    end else begin
      check bool "malformed native diagnostic is not published" true (receipt=`Null);
      check bool "malformed returned evidence keeps intent unresolved" true
        (match Peer.input_status peer with Input.Uncertain _->true|Ready _->false)
    end;
    check int "diagnostic handling does not repeat input" 1 !calls)
    [true,diagnostic;false,obj ["code",str "EGO_PAGE_DIALOG_OPENED";"sessionId",str "actual-native-session"];
     false,obj (("private",str "PRIVATE_NATIVE_HEADER_SENTINEL")::diagnostic_fields)]

let test_workflow_raw_context_is_bound_to_its_actual_pending () =
  let module Input=Masc.Browser_ego_input in
  List.iter (fun mode->
    let calls=ref 0 in
    let peer=opened (fun sent->match sent.step with
      | "tabs.list"->answered tabs
      | "page.native_workflow"->
        incr calls;
        let source=field "expectedSourcePage" sent.args in
        check bool "raw workflow binds source even without popup" true (source<>`Null);
        check string "workflow producer uses the actual command" ("workflow-raw-" ^ mode)
          (text (field "commandId" (field "nativeInputWindows" sent.args)));
        let capture=raw_capture sent (if mode="dialog" then "dialog" else "normal") in
        let pages=obj ["source",source;"current",source;"transitions",`List []] in
        if mode="lost" then Error (Peer.Unobserved "PRIVATE_NATIVE_HEADER_SENTINEL")
        else if mode="malformed" then answered (obj ["private",str "PRIVATE_NATIVE_HEADER_SENTINEL"])
        else if mode="normal" then answered (obj ["completed",`List [obj ["index",`Int 0;
          "method",str "keyboard.type";"receipt",`Null;"nativeInputWindow",capture];
          obj ["index",`Int 1;"method",str "fill";"receipt",obj []]];
          "effectStarted",`Bool true;"completedEffect",`Bool true;"inputReleased",`Bool true;
          "failure",`Null;"urlBefore",str observed_url;"url",str observed_url;"title",str "Slack";
          "snapshot",str "same Page snapshot";"chars",`Int (String.length "same Page snapshot");
          "truncated",`Bool false;"pages",pages])
        else answered (obj ["completed",`List [];"effectStarted",`Bool true;"completedEffect",`Bool false;
          "inputReleased",`Bool false;"pages",pages;"failure",obj ["index",`Int 0;
            "method",str "nativeTyping";"message",str "fixed unconfirmed input";"nativeInputWindow",capture]])
      | step->failf "raw workflow unexpectedly dispatched %s" step) in
    ignore (dispatch peer Live.Tabs_list (obj []));
    let result=Peer.dispatch ~command_id:("workflow-raw-" ^ mode) peer ~verb:Live.Page_native_workflow
      (obj ["tabId",`Int 1;"expectedUrl",str observed_url;"maxChars",`Int 100;
        "steps",`List [obj ["method",str "keyboard.type";"text",str "a"];
          obj ["method",str "fill";"selector",str "#entry";"text",str "follow-up"]]]) in
    check string "raw workflow completion is independently judged" (if mode="normal" then "served" else "unknown")
      (failure_kind result);
    private_native_data_stays_private result;
    if mode="normal" then begin
      let _,receipt=public_input_result result in
      match field "completed" receipt with
      | `List (raw::_)->
        check bool "raw workflow receipt remains null" true (field "receipt" raw=`Null);
        check bool "workflow public summary survives Peer projection" true (field "nativeCompletion" raw<>`Null)
      | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`Assoc _|`List [] -> fail "completed raw workflow progress absent"
    end;
    check bool "only exact completed workflow window settles intent" (mode="normal")
      (match Peer.input_status peer with Input.Ready _->true|Uncertain _->false);
    check int "one workflow invocation, never replayed" 1 !calls) ["normal";"dialog";"lost";"malformed"]

(* Native clicks, double-clicks and drags can open a dialog before release.
   Only their declared receipt without [dialog] settles the input; the next
   input runs either way. *)
let test_a_target_gesture_settles_only_from_the_receipt_it_returns () =
  let drag = Lane.Drag_to {source=Lane.Selector "#source";destination=Lane.Selector "#destination";via=[];duration_ms=0} in
  List.iter (fun gesture ->
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
    check string (name ^ " answers the gesture") first
      (failure_kind (dispatch peer Live.Page_interact (interact_args gesture)));
    check bool (name ^ " settles only from a declared receipt") settles
      (match Peer.input_status peer with
       | Masc.Browser_ego_input.Ready Masc.Browser_ego_input.Command_settled -> true
       | Masc.Browser_ego_input.Ready (Masc.Browser_ego_input.Release_uncertain _)
       | Masc.Browser_ego_input.Uncertain _ -> false);
    let before = List.length !asked in
    ignore (dispatch peer Live.Page_interact (interact_args gesture));
    check int (name ^ " lets the next input run") (before + 1) (List.length !asked))
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
      "a script that never started", Error (Peer.Unstarted "no node here"), "before effect", true ])
    [drag; Lane.Click "#source"; Lane.Double_click (Lane.Selector "#source");
     Lane.Click_target (Lane.Target_ref 12); Lane.Double_click_target (Lane.Target_ref 12)]

let test_target_dialog_keeps_release_uncertain_until_a_clean_receipt () =
  let module Input=Masc.Browser_ego_input in
  let dialog=ego_dialog "alert" "mousedown interrupted" in
  let input_reply receipt = answered (obj ["urlBefore",str observed_url;
    "tab",obj ["url",str observed_url;"title",str "Slack"];"receipt",receipt;"error",`Null]) in
  List.iter (fun gesture ->
    let asked=ref [] and reply=ref (input_reply (obj ["dialog",dialog])) in
    let peer=opened (fun sent ->
      asked:=sent.step :: !asked;
      match sent.step with
      | "tabs.list" -> answered tabs
      | "page.target_input" -> !reply
      | "page.dialog" -> answered (obj ["answered",`Bool true;"dialog",dialog])
      | other -> failf "unexpected target recovery step %s" other) in
    ignore (dispatch peer Live.Tabs_list (obj []));
    let first=Peer.dispatch ~command_id:"original-target-gesture" peer ~verb:Live.Page_interact (interact_args gesture) in
    check string "the original dialog remains a served observation" "served" (failure_kind first);
    check string "the dialog answer reports release as uncertain" "release_uncertain" (reported_readiness peer first);
    let pending=match Peer.input_status peer with
      | Input.Uncertain pending -> pending
      | Ready _ -> fail "dialog-interrupted gesture lost its original input" in
    check bool "pending input belongs to the original command and Page" true
      (pending.command_id="original-target-gesture" && pending.page_label="p1");
    check string "answering the dialog succeeds" "served" (failure_kind (dispatch peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Accept_dialog None}))));
    check bool "answering the dialog preserves the exact pending generation" true
      (Peer.input_status peer=Input.Uncertain pending);
    List.iter (fun refused_reply ->
      reply:=refused_reply;
      let before=List.length !asked in
      check string "input that never starts is refused before an effect" "before effect"
        (failure_kind (dispatch peer Live.Page_interact (interact_args gesture)));
      check int "the input runs while release is uncertain" (before + 1) (List.length !asked);
      check bool "pre-effect refusal restores the earlier uncertain release" true
        (Peer.input_status peer=Input.Ready (Input.Release_uncertain pending)))
      [refused "observed URL changed"; Error (Peer.Unstarted "no node here")];
    reply:=input_reply (obj []);
    let settled=dispatch peer Live.Page_interact (interact_args gesture) in
    check string "a new original gesture completes" "served" (failure_kind settled);
    check string "its answer reports command settlement" "command_settled" (reported_readiness peer settled);
    check bool "the SDK clean receipt establishes command settlement" true
      (Peer.input_status peer=Input.Ready Input.Command_settled))
    [Lane.Click "#source"; Lane.Double_click_target (Lane.Target_ref 12)]

(* 2026-11-03: a click on text="dev-frontend" matched 8 elements; the SDK threw
   ElementResolutionError before any press. *)
let test_a_gesture_refused_before_its_press_keeps_input () =
  let module Input=Masc.Browser_ego_input in
  let refusal name kind = answered (obj ["urlBefore",str observed_url;"receipt",`Null;
    "error",str "Locator text=\"dev-frontend\" matched 8 elements";"thrown",obj ["name",name;"kind",kind]]) in
  let reply=ref (refusal (str "ElementResolutionError") (str "permanent")) and asked=ref [] in
  let peer=opened (fun sent ->
    asked:=sent.step :: !asked;
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.target_input" -> !reply
    | other -> failf "unexpected refused-gesture step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let drag = Lane.Drag_to {source=Lane.Selector "#source";destination=Lane.Selector "#destination";via=[];duration_ms=0} in
  List.iter (fun (name, kind, action) ->
    reply := refusal (str "ElementResolutionError") (str kind);
    (match dispatch peer Live.Page_interact (interact_args action) with
     | Error (Live.Observed_failure {disposition=Live.Uncertain;receipt;_}) ->
       check string (name ^ ": the SDK kind is reported") kind (text (field "kind" (field "refusedBeforePress" receipt)));
       check string (name ^ ": the answer says the input is free") "command_settled" (text (field "inputReadiness" receipt))
     | Ok _ | Error _ -> fail (name ^ ": a refused gesture must be an observed failure with an uncertain effect"));
    check bool (name ^ ": nothing is pending") true (Peer.input_status peer=Input.Ready Input.Command_settled))
    ["click","permanent",Lane.Click "#channel";
     "double click","transient",Lane.Double_click (Lane.Selector "#channel");
     "drag","permanent",drag];
  reply := refusal (str "TimeoutError") (str "transient");
  check string "another SDK error stays unknown" "unknown"
    (failure_kind (dispatch peer Live.Page_interact (interact_args (Lane.Click "#channel"))));
  let pending_after label =
    match Peer.input_status peer with
    | Input.Ready _ -> fail (label ^ ": no input was pending")
    | Input.Uncertain pending -> pending in
  let earlier=pending_after "after the unknown error" in
  reply := refusal (str "ElementResolutionError") (str "permanent");
  (match dispatch peer Live.Page_interact (interact_args (Lane.Click "#channel")) with
   | Error (Live.Observed_failure {disposition=Live.Uncertain;receipt;_}) ->
     check string "a refusal while release is uncertain still reports it" "release_uncertain"
       (text (field "inputReadiness" receipt))
   | Ok _ | Error _ -> fail "a refused gesture after an unknown error must be an observed failure with an uncertain effect");
  check bool "a refusal keeps the earlier uncertain release and its generation" true
    (match Peer.input_status peer with
     | Input.Ready (Input.Release_uncertain kept) -> kept.generation=earlier.generation
     | Input.Ready Input.Command_settled | Input.Uncertain _ -> false);
  List.iter (fun (label, frame) ->
    reply := answered (obj frame);
    check string (label ^ " stays unknown") "unknown"
      (failure_kind (dispatch peer Live.Page_interact (interact_args (Lane.Click "#channel"))));
    ignore (pending_after label))
    ["a frame without the thrown error",
       ["urlBefore",str observed_url;"receipt",`Null;"error",str "native click failed"];
     "a refusal beside a receipt",
       ["urlBefore",str observed_url;"receipt",obj [];"error",str "native click failed";
        "thrown",obj ["name",str "ElementResolutionError";"kind",str "permanent"]]]

(* An ego viewport is a CDP override on its Page: the URL guard runs first,
   the receipt reads the size the page took, and the answer says the size
   lives with the SDK process and that snapshot refs are stale. *)
let test_viewport_is_a_cdp_override_on_the_page () =
  let asked = ref [] in
  let reply = ref (input_answer ()) in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.viewport" -> !reply
    | other -> failf "unexpected viewport step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let size width height = in_page (obj ["url",str observed_url;"title",str "Slack";
    "innerWidth",`Int width;"innerHeight",`Int height;"devicePixelRatio",`Int 2]) in
  let resize viewport = dispatch peer Live.Page_interact (interact_args (Lane.Set_viewport viewport)) in
  reply := answered (obj ["guard",page_summary;"receipt",size 800 600;"error",`Null]);
  (match resize (Lane.Fit {width=800;height=600}) with
   | Ok receipt ->
     check string "the action" "set_viewport" (text (field "action" receipt));
     check string "the page it was set on" observed_url (text (field "urlBefore" receipt));
     check (pair int int) "the size the page took" (800, 600)
       (to_int (field "innerWidth" receipt), to_int (field "innerHeight" receipt));
     check bool "snapshot refs are stale" true (field "refsInvalidated" receipt = `Bool true);
     check string "the size lives with the SDK process" "ego_sdk_process" (text (field "lifetime" receipt))
   | other -> failf "the viewport was %s" (failure_kind other));
  let sent = List.hd !asked in
  check string "the override names the size" {|{"width":800,"height":600}|} (Yojson.Safe.to_string (field "metrics" sent.args));
  check bool "the guard is the URL guard the BiDi connection runs" true
    (String_util.contains_substring (text (field "guard" sent.args)) Masc.Browser_interaction.url_guard_script);
  check bool "the receipt is its viewport receipt" true
    (String_util.contains_substring (text (field "receipt" sent.args)) Masc.Browser_interaction.viewport_receipt_script);
  reply := answered (obj ["guard",page_summary;"receipt",size 1548 990;"error",`Null]);
  (match resize Lane.Browser_default with
   | Ok receipt ->
     check bool "restoring sends no size" true (field "metrics" (List.hd !asked).args = `Null);
     check bool "and the restored size holds nothing of the process" true
       (not (List.mem_assoc "lifetime" (Yojson.Safe.Util.to_assoc receipt)))
   | other -> failf "the restore was %s" (failure_kind other));
  reply := refused "page_url_changed";
  check string "a page that moved is refused before the override" "page_url_changed"
    (before_effect "a moved page" (resize (Lane.Fit {width=800;height=600})));
  reply := answered (obj ["guard",page_summary;"receipt",size 1548 990;"error",str "Emulation.setDeviceMetricsOverride failed"]);
  check string "a CDP failure leaves the size unknown" "unknown" (failure_kind (resize (Lane.Fit {width=800;height=600})))

(* Taps and swipes are CDP touch events on an ego Page. A tap sends one
   point; a swipe fills each BiDi segment with a point every 16 ms, each with
   the wait before it. Both run the BiDi pointer guard, mark snapshot refs
   stale, and a swipe longer than the command's window never runs. *)
let test_touch_is_cdp_touch_on_the_page () =
  let asked = ref [] in
  let reply = ref (input_answer ()) in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.touch" -> !reply
    | other -> failf "unexpected touch step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let runs () = List.length !asked in
  let gesture action = dispatch peer Live.Page_interact (interact_args action) in
  let points json = List.map (fun point -> List.map to_int (Yojson.Safe.Util.to_list point)) (Yojson.Safe.Util.to_list json) in
  (match gesture (Lane.Tap_at {point={x=0.5;y=0.25};viewport}) with
   | Ok receipt ->
     check string "the action" "tap_at" (text (field "action" receipt));
     check string "the page it was sent to" observed_url (text (field "urlBefore" receipt));
     check bool "snapshot refs are stale" true (field "refsInvalidated" receipt = `Bool true)
   | other -> failf "the tap was %s" (failure_kind other));
  let sent = List.hd !asked in
  check (list int) "a tap presses at its pixel" [400; 150] (List.map to_int (Yojson.Safe.Util.to_list (field "start" sent.args)));
  check (list (list int)) "and moves nowhere" [] (points (field "moves" sent.args));
  check bool "the guard is the pointer guard the BiDi connection runs" true
    (String_util.contains_substring (text (field "guard" sent.args)) Masc.Browser_interaction.pointer_guard_script);
  let swipe ~duration_ms ~via = Lane.Swipe {from={x=0.25;y=0.5};to_={x=0.75;y=0.5};viewport;via;duration_ms} in
  (match gesture (swipe ~duration_ms:32 ~via:[]) with
   | Ok _ -> ()
   | other -> failf "the swipe was %s" (failure_kind other));
  check (list (list int)) "a straight swipe passes its midpoint, a point every 16 ms"
    [[300;300;16]; [400;300;16]; [500;300;16]; [600;300;16]] (points (field "moves" (List.hd !asked).args));
  (match gesture (swipe ~duration_ms:0 ~via:[{Lane.Pointer.x=0.5;y=0.25}]) with
   | Ok _ -> ()
   | other -> failf "the quick swipe was %s" (failure_kind other));
  check (list (list int)) "a 0 ms segment is one point at once" [[400;150;0]; [600;300;0]]
    (points (field "moves" (List.hd !asked).args));
  let before = runs () in
  check bool "a swipe longer than the window is refused before it starts" true
    (contains (before_effect "a long swipe" (gesture (swipe ~duration_ms:100_000_000 ~via:[]))) "shorter durationMs");
  check int "and runs nothing" before (runs ());
  reply := refused "observed_viewport_changed";
  check string "a page whose viewport moved is refused before the touch" "observed_viewport_changed"
    (before_effect "a moved page" (gesture (Lane.Tap_at {point={x=0.5;y=0.25};viewport})));
  reply := input_answer ~error:(str "the touch was cancelled after Target closed") ();
  check string "a touch that failed after its press is unknown" "unknown"
    (failure_kind (gesture (Lane.Tap_at {point={x=0.5;y=0.25};viewport})))

(* Location, locale and time zone are CDP overrides on an ego Page. The
   peer sends what was asked with the label it names, passes the page's own
   before and after through, and says the overrides end with the SDK process
   and that the locale reaches Intl only. A step that stopped after another
   took effect is partial; a refusal the script made before any change is
   before effect. *)
let test_emulation_is_a_cdp_override_on_the_page () =
  let asked = ref [] in
  let reply = ref (refused "no reply set") in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.emulation" -> !reply
    | other -> failf "unexpected emulation step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let environment ~locale ~zone ~permission = obj ["origin",str "https://app.slack.com";"locale",str locale;
    "timeZone",str zone;"geolocationPermission",str permission] in
  let emulate interaction = dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=1;interaction})) in
  let seoul = Lane.Action.Set_emulation {geolocation=Some {latitude=37.5665;longitude=126.978;accuracy_m=25.};
    locale=Some "fr-FR";timezone=Some "America/New_York"} in
  reply := answered (obj ["applied",`List [str "locale";str "timezone";str "geolocation_grant";str "geolocation"];
    "before",environment ~locale:"ko" ~zone:"Asia/Seoul" ~permission:"prompt";
    "observed",environment ~locale:"fr-FR" ~zone:"America/New_York" ~permission:"granted";
    "geolocationGrant",str "https://app.slack.com";"emulated",`Null]);
  (match emulate seoul with
   | Ok receipt ->
     check string "the action" "set_emulation" (text (field "action" receipt));
     check int "the tab" 1 (Yojson.Safe.Util.to_int (field "tabId" receipt));
     check string "what the page reports afterwards" "America/New_York" (text (field "timeZone" (field "observed" receipt)));
     check string "the origin the grant covers" "https://app.slack.com" (text (field "geolocationGrant" receipt));
     check string "the overrides live with the SDK process" "ego_sdk_process" (text (field "lifetime" receipt));
     check string "the locale reaches Intl only" "intl_only" (text (field "localeScope" receipt))
   | other -> failf "set_emulation was %s" (failure_kind other));
  let sent = List.hd !asked in
  check string "the Page it names" "p1" (text (field "label" sent.args));
  check string "what it asks for" {|{"latitude":37.5665,"longitude":126.978,"accuracy":25.0}|}
    (Yojson.Safe.to_string (field "geolocation" sent.args));
  check (pair string string) "the locale and time zone as asked" ("fr-FR", "America/New_York")
    (text (field "locale" sent.args), text (field "timezone" sent.args));
  check bool "a set is not a clear" true (field "clear" sent.args = `Bool false);
  reply := answered (obj ["applied",`List [str "geolocation";str "locale";str "timezone"];
    "before",environment ~locale:"fr-FR" ~zone:"America/New_York" ~permission:"granted";
    "observed",environment ~locale:"ko" ~zone:"Asia/Seoul" ~permission:"granted";
    "geolocationGrant",`Null;"emulated",`Null]);
  (match emulate Lane.Action.Clear_emulation with
   | Ok receipt ->
     check string "the action" "clear_emulation" (text (field "action" receipt));
     check bool "cleared, with the grant left" true
       (field "cleared" receipt = `Bool true && field "permissionsUnchanged" receipt = `Bool true)
   | other -> failf "clear_emulation was %s" (failure_kind other));
  check bool "a clear asks for nothing else" true
    (let args = (List.hd !asked).args in field "clear" args = `Bool true && field "locale" args = `Null);
  reply := answered (obj ["applied",`List [str "timezone"];
    "failed",obj ["step",str "timezone";"error",str "the page reports Asia/Seoul after the override to America/New_York"];
    "before",environment ~locale:"ko" ~zone:"Asia/Seoul" ~permission:"prompt";
    "observed",environment ~locale:"ko" ~zone:"Asia/Seoul" ~permission:"prompt"]);
  (match emulate (Lane.Action.Set_emulation {geolocation=None;locale=None;timezone=Some "America/New_York"}) with
   | Error (Live.Partial_failure {tab_id; message; _}) ->
     check int "the tab it stopped on" 1 tab_id;
     check bool "it names the step and what the page said" true
       (contains message "timezone: the page reports Asia/Seoul")
   | other -> failf "a time zone the page did not take was %s" (failure_kind other));
  reply := refused "the page knows no time zone \"Mars/Olympus\": Invalid time zone specified: Mars/Olympus";
  check bool "a name the page does not know is refused before any change" true
    (contains (before_effect "an unknown zone" (emulate (Lane.Action.Set_emulation {geolocation=None;locale=None;timezone=Some "Mars/Olympus"})))
       "Mars/Olympus");
  reply := answered (obj ["before",`Null]);
  check string "a receipt without its steps leaves the change unknown" "unknown" (failure_kind (emulate Lane.Action.Clear_emulation));
  let unmanaged = dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=2;interaction=seoul})) in
  check string "an operator tab is refused before any change" "before effect" (failure_kind unmanaged)

(* Request blocking is one CDP setting on the Page. The script keeps the
   hosts it blocked, so the receipt lists every host blocked on the tab and an
   unblock counts the hosts it lifted. *)
let test_request_blocking_is_a_cdp_setting_on_the_page () =
  let asked = ref [] in
  let reply = ref (refused "no reply set") in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.block_requests" -> !reply
    | other -> failf "unexpected request blocking step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let act ?(tab_id=1) interaction = dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id;interaction})) in
  reply := answered (obj ["blocked",`List [str "ads.example.com";str "cdn.example.com"]]);
  (match act (Lane.Action.Block_requests ["cdn.example.com"]) with
   | Ok receipt ->
     check string "the action" "block_requests" (text (field "action" receipt));
     check int "the tab" 1 (Yojson.Safe.Util.to_int (field "tabId" receipt));
     check (list string) "every host blocked on the tab" ["ads.example.com";"cdn.example.com"]
       (List.map text (Yojson.Safe.Util.to_list (field "blocked" receipt)));
     check string "the blocks live with the SDK process" "ego_sdk_process" (text (field "lifetime" receipt));
     check bool "snapshot refs are stale" true (field "refsInvalidated" receipt = `Bool true);
     check bool "the note says navigations still load" true (contains (text (field "note" receipt)) "Navigations")
   | other -> failf "block_requests was %s" (failure_kind other));
  let sent = List.hd !asked in
  check string "the Page it names" "p1" (text (field "label" sent.args));
  check (list string) "the hosts of this call" ["cdn.example.com"] (List.map text (Yojson.Safe.Util.to_list (field "hosts" sent.args)));
  reply := answered (obj ["unblocked",`Int 2]);
  (match act Lane.Action.Unblock_requests with
   | Ok receipt ->
     check string "the action" "unblock_requests" (text (field "action" receipt));
     check int "the hosts it lifted" 2 (Yojson.Safe.Util.to_int (field "unblocked" receipt));
     check bool "nothing lives on after an unblock" true (field "lifetime" receipt = `Null)
   | other -> failf "unblock_requests was %s" (failure_kind other));
  check bool "an unblock names no hosts" true (field "hosts" (List.hd !asked).args = `Null);
  List.iter (fun (label, value) ->
    reply := answered value;
    check string label "unknown" (failure_kind (act (Lane.Action.Block_requests ["ads.example.com"]))))
    ["a receipt with no hosts leaves the change unknown", obj ["blocked",`List []];
     "an unblock count for a block leaves the change unknown", obj ["unblocked",`Int 0];
     "a receipt with more fields leaves the change unknown", obj ["blocked",`List [str "ads.example.com"];"extra",`Null]];
  reply := failed "Network.setBlockedURLs failed: CDP request timed out";
  check string "a CDP call that threw leaves the change unknown" "unknown"
    (failure_kind (act (Lane.Action.Block_requests ["ads.example.com"])));
  let runs = List.length !asked in
  check string "an operator tab is refused before any change" "before effect"
    (failure_kind (act ~tab_id:2 (Lane.Action.Block_requests ["ads.example.com"])));
  check int "and runs no script" runs (List.length !asked)

(* A cookie write goes into the operator's ego profile. The receipt is
   rebuilt from what the browser holds for the asked name and path on the
   page's host, never carries a value, and says the change outlives the SDK
   process. *)
let cookie_answer ?(name="session") ?(path="/") ?(domain="app.example.com") ?(extra=[]) () =
  obj (["name",str name;"domain",str domain;"path",str path;"secure",`Bool true;"httpOnly",`Bool true;
        "sameSite",str "Lax";"session",`Bool false;"expiry",`Int 1794043123;"replaced",`Bool false] @ extra)

let test_cookie_writes_go_into_the_ego_profile () =
  let asked = ref [] in
  let reply = ref (refused "no reply set") in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.set_cookie" | "page.delete_cookie" -> !reply
    | other -> failf "unexpected cookie step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let cookie = {Lane.Action.name="session";value="SECRET_VALUE";path="/";secure=true;http_only=true;
                same_site=Some Lane.Action.Lax;max_age_sec=Some 3600} in
  let act ?(tab_id=1) interaction = dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id;interaction})) in
  reply := answered (cookie_answer ());
  (match act (Lane.Action.Set_cookie cookie) with
   | Ok receipt ->
     check string "the action" "set_cookie" (text (field "action" receipt));
     check string "the host it went to" "app.example.com" (text (field "domain" receipt));
     check bool "with its expiry" true (field "expiry" receipt = `Int 1794043123 && field "sessionCookie" receipt = `Bool false);
     check bool "the value is withheld" true (field "valueWithheld" receipt = `Bool true);
     check bool "and never in the receipt" false (contains (Yojson.Safe.to_string receipt) "SECRET_VALUE");
     check string "the cookie lives in the ego profile" "ego_profile" (text (field "lifetime" receipt));
     check bool "the note names the operator's profile" true (contains (text (field "note" receipt)) "operator's ego profile")
   | other -> failf "set_cookie was %s" (failure_kind other));
  let sent = List.hd !asked in
  check string "the Page it names" "p1" (text (field "label" sent.args));
  check string "a set" "set" (text (field "kind" sent.args));
  check string "the value goes to the browser" "SECRET_VALUE" (text (field "value" sent.args));
  check bool "with its lifetime and SameSite" true (field "maxAgeSec" sent.args = `Int 3600 && field "sameSite" sent.args = str "Lax");
  check bool "and no domain" true (field "domain" sent.args = `Null);
  reply := answered (obj ["deleted",`List [obj ["domain",str "app.example.com";"path",str "/"];obj ["domain",str ".example.com";"path",str "/"]]]);
  (match act (Lane.Action.Delete_cookie "session") with
   | Ok receipt ->
     check string "the action" "delete_cookie" (text (field "action" receipt));
     check (list string) "every cookie of that name it deleted" ["app.example.com/";".example.com/"]
       (List.map (fun row -> text (field "domain" row) ^ text (field "path" row)) (Yojson.Safe.Util.to_list (field "deleted" receipt)))
   | other -> failf "delete_cookie was %s" (failure_kind other));
  check string "a delete" "delete" (text (field "kind" (List.hd !asked).args));
  List.iter (fun (label, value) ->
    reply := answered value;
    check string label "unknown" (failure_kind (act (Lane.Action.Set_cookie cookie))))
    ["another name leaves the write unknown", cookie_answer ~name:"other" ();
     "another path leaves the write unknown", cookie_answer ~path:"/app" ();
     "a domain cookie leaves the write unknown", cookie_answer ~domain:".example.com" ();
     "a value in the answer leaves the write unknown", cookie_answer ~extra:["value",str "SECRET_VALUE"] ();
     "an expiry on a session cookie leaves the write unknown", obj ["name",str "session";"domain",str "app.example.com";"path",str "/";"secure",`Bool true;"httpOnly",`Bool true;"session",`Bool true;"expiry",`Int 1;"replaced",`Bool false]];
  List.iter (fun (label, value) ->
    reply := answered value;
    check string label "unknown" (failure_kind (act (Lane.Action.Delete_cookie "session"))))
    ["a deleted row with a value leaves the delete unknown", obj ["deleted",`List [obj ["domain",str "a";"path",str "/";"value",str "x"]]];
     "a delete without its list leaves it unknown", obj []];
  reply := refused "the browser refused the cookie (Network.setCookie answered success false)";
  check string "a refused cookie changed nothing" "before effect" (failure_kind (act (Lane.Action.Set_cookie cookie)));
  reply := failed "Network.setCookie failed: CDP request timed out";
  (match act (Lane.Action.Set_cookie cookie) with
   | Error (Live.Outcome_unknown detail) ->
     check bool "a CDP call that threw says how to find out" true (contains detail "read_storage")
   | other -> failf "a thrown setCookie was %s" (failure_kind other));
  let runs = List.length !asked in
  check string "an operator tab is refused before any change" "before effect"
    (failure_kind (act ~tab_id:2 (Lane.Action.Delete_cookie "session")));
  check int "and runs no script" runs (List.length !asked)

(* A page.cookies answer: the cookies, their total and the page's storage
   names, as storage_names_script emits them. *)
let storage_answer ?(cookies=[]) ?total ?(local=obj ["count",`Int 1;"keys",`List [str "theme"];"truncated",`Bool false]) () =
  obj ["cookies",`List cookies;"total",`Int (Option.value total ~default:(List.length cookies));
       "storage",obj ["origin",str "https://app.slack.com";"localStorage",local;
                      "sessionStorage",obj ["error",str "SecurityError"];"indexedDb",obj ["unsupported",`Bool true]]]

(* The answer is rebuilt from what was parsed: a cookie value, or any field
   the script does not name, is refused instead of passed on. *)
let test_storage_names_withhold_every_value () =
  let asked = ref [] in
  let reply = ref (refused "no reply set") in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.cookies" -> !reply
    | other -> failf "unexpected storage step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let read ?(tab_id=1) () = dispatch peer Live.Page_cookies (obj ["tabId",`Int tab_id]) in
  let plain_fields = ["name",str "theme";"domain",str "app.slack.com";"path",str "/";"secure",`Bool false;"httpOnly",`Bool false] in
  let plain = obj plain_fields in
  let session = obj ["name",str "d";"domain",str ".slack.com";"path",str "/";"secure",`Bool true;"httpOnly",`Bool true;
    "sameSite",str "Lax";"expiry",`Int 1794018557] in
  reply := answered (storage_answer ~cookies:[session;plain] ());
  (match read () with
   | Ok answer ->
     check int "the tab" 1 (Yojson.Safe.Util.to_int (field "tabId" answer));
     check (list string) "each cookie's name and the attributes that scope it"
       (List.map Yojson.Safe.to_string [session;plain])
       (List.map Yojson.Safe.to_string (Yojson.Safe.Util.to_list (field "cookies" answer)));
     check int "how many the page sees" 2 (Yojson.Safe.Util.to_int (field "total" answer));
     check bool "cookie values are withheld" true (field "valuesWithheld" answer = `Bool true);
     check bool "storage values are withheld" true (field "storageValuesWithheld" answer = `Bool true);
     check string "the storage names as the page answered them"
       (Yojson.Safe.to_string (field "storage" (storage_answer ()))) (Yojson.Safe.to_string (field "storage" answer))
   | other -> failf "the storage read was %s" (failure_kind other));
  let sent = List.hd !asked in
  check string "the Page it names" "p1" (text (field "label" sent.args));
  check string "the limits it sends" {|{"cookies":200,"names":100,"nameChars":200,"indexedDbWaitMs":2000}|}
    (Yojson.Safe.to_string (field "limits" sent.args));
  reply := answered (storage_answer ~cookies:(List.init 200 (fun _ -> plain)) ~total:250 ());
  (match read () with
   | Ok answer ->
     check int "the first 200 cookies" 200 (List.length (Yojson.Safe.Util.to_list (field "cookies" answer)));
     check int "with the total past them" 250 (Yojson.Safe.Util.to_int (field "total" answer))
   | other -> failf "a long cookie list was %s" (failure_kind other));
  List.iter (fun (label, value) ->
    reply := answered value;
    check string label "before effect" (failure_kind (read ())))
    ["a cookie with its value is refused", storage_answer ~cookies:[obj (plain_fields @ ["value",str "secret"])] ();
     "a sameSite the browser does not name is refused", storage_answer ~cookies:[obj (plain_fields @ ["sameSite",str "lax"])] ();
     "fewer cookies than the total explains is refused", storage_answer ~cookies:[plain] ~total:2 ();
     "more keys than the count is refused",
       storage_answer ~local:(obj ["count",`Int 1;"keys",`List [str "a";str "b"];"truncated",`Bool false]) ();
     "a cut the count does not explain is refused",
       storage_answer ~local:(obj ["count",`Int 1;"keys",`List [str "a"];"truncated",`Bool true]) ();
     "an answer with more fields is refused",
       (match storage_answer () with `Assoc fields -> obj (fields @ ["extra",`Null]) | other -> other)];
  reply := failed "Network.getCookies failed: CDP request timed out";
  check string "a CDP call that threw is a failed read" "before effect" (failure_kind (read ()));
  let runs = List.length !asked in
  check string "an operator tab is refused" "before effect" (failure_kind (read ~tab_id:2 ()));
  check string "a read without a tab is refused" "before effect" (failure_kind (dispatch peer Live.Page_cookies (obj [])));
  check int "and neither runs a script" runs (List.length !asked)

(* A page.network answer as mascNetworkLog emits it, with one row of each
   state (L8 evidence c). *)
let network_row ?(url="http://127.0.0.1:18775/x?tag=REDACTED&token=REDACTED") ?(cut=false) ?(state=["state",str "pending"]) () =
  obj (["method",str "GET";"url",str url;"urlCut",`Bool cut;"timestamp",`Int 1794029599447;
        "requestHeaders",obj ["names",`List [str "X-Masc-L8";str "Referer"];"total",`Int 2]] @ state)
let network_answer ?(rows=[network_row ()]) ?(malformed=obj ["count",`Int 0;"last",`Null]) () =
  obj ["requests",`List rows;"dropped",`Int 0;"malformedEvents",malformed;"fullBufferReads",`Int 0]
let response_headers = "responseHeaders",obj ["names",`List [str "Content-Type"];"total",`Int 1]

(* The answer is rebuilt from what was parsed: a row whose address keeps a
   user, a fragment or a query value, or a field the script does not name, is
   refused instead of passed on. *)
let test_network_log_rebuilds_every_row () =
  let asked = ref [] in
  let reply = ref (refused "no reply set") in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.network" -> !reply
    | other -> failf "unexpected network step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let read ?(tab_id=1) () = dispatch peer Live.Page_network (obj ["tabId",`Int tab_id]) in
  let rows = [
    network_row ();
    network_row ~state:["state",str "responded";"status",`Int 200;"mimeType",str "text/plain";response_headers] ();
    network_row ~state:["state",str "completed";"status",`Int 302;"mimeType",str "";"bytesReceived",`Int 171;response_headers] ();
    network_row ~state:["state",str "failed";"error",str "blocked: inspector"] ();
    network_row ~url:"data:" ~cut:true () ] in
  reply := answered (network_answer ~rows ());
  (match read () with
   | Ok answer ->
     check int "the tab" 1 (Yojson.Safe.Util.to_int (field "tabId" answer));
     check (list string) "every row as the script answered it"
       (List.map Yojson.Safe.to_string rows)
       (List.map Yojson.Safe.to_string (Yojson.Safe.Util.to_list (field "requests" answer)));
     check string "the counts" {|{"count":0,"last":null}|} (Yojson.Safe.to_string (field "malformedEvents" answer))
   | other -> failf "the network read was %s" (failure_kind other));
  check string "the Page it names" "p1" (text (field "label" (List.hd !asked).args));
  reply := answered (network_answer ~rows:[]
    ~malformed:(obj ["count",`Int 2;"last",str "Network.loadingFinished: finished without a response or encodedDataLength"]) ());
  (match read () with
   | Ok answer -> check int "malformed events are counted" 2 (Yojson.Safe.Util.to_int (field "count" (field "malformedEvents" answer)))
   | other -> failf "a log with malformed events was %s" (failure_kind other));
  List.iter (fun (label, value) ->
    reply := answered value;
    check string label "before effect" (failure_kind (read ())))
    ["a query value is refused", network_answer ~rows:[network_row ~url:"http://a.test/x?token=secret" ()] ();
     "a user in the address is refused", network_answer ~rows:[network_row ~url:"http://user:pw@a.test/x" ()] ();
     "a fragment is refused", network_answer ~rows:[network_row ~url:"http://a.test/x#t" ()] ();
     "a scheme-only address not marked cut is refused", network_answer ~rows:[network_row ~url:"data:" ()] ();
     "header values instead of names are refused",
       network_answer ~rows:[obj ["method",str "GET";"url",str "http://a.test/";"urlCut",`Bool false;"timestamp",`Int 1;
         "requestHeaders",obj ["Cookie",str "secret"];"state",str "pending"]] ();
     "more header names than the total is refused",
       network_answer ~rows:[obj ["method",str "GET";"url",str "http://a.test/";"urlCut",`Bool false;"timestamp",`Int 1;
         "requestHeaders",obj ["names",`List [str "a";str "b"];"total",`Int 1];"state",str "pending"]] ();
     "a state the script does not name is refused", network_answer ~rows:[network_row ~state:["state",str "done"] ()] ();
     "a completed row without its byte count is refused",
       network_answer ~rows:[network_row ~state:["state",str "completed";"status",`Int 200;"mimeType",str "";response_headers] ()] ();
     "a malformed count without its reason is refused", network_answer ~malformed:(obj ["count",`Int 1;"last",`Null]) ();
     "more rows than the log keeps is refused",
       network_answer ~rows:(List.init (Masc.Browser_ego_page_events.requests_limit + 1) (fun _ -> network_row ())) ();
     "an answer with more fields is refused",
       (match network_answer () with `Assoc fields -> obj (fields @ ["extra",`Null]) | other -> other)];
  reply := failed "the tab's network log was not read: ego returned a non-array event buffer";
  check string "a drain that threw is a failed read" "before effect" (failure_kind (read ()));
  let runs = List.length !asked in
  check string "an operator tab is refused" "before effect" (failure_kind (read ~tab_id:2 ()));
  check string "a read without a tab is refused" "before effect" (failure_kind (dispatch peer Live.Page_network (obj [])));
  check int "and neither runs a script" runs (List.length !asked)

(* ego's buffer empties on every drain, so one shared drain reads it and the
   step scripts that need events call it (RFC-browser-ego-cdp-capabilities
   §3.4). *)
let test_one_drain_reads_the_event_buffer () =
  let count text part =
    let width = String.length part in
    let rec from index found =
      if index + width > String.length text then found
      else from (index + 1) (if String.sub text index width = part then found + 1 else found) in
    from 0 0 in
  check int "the shared drain reads ego's buffer once" 1 (count Masc.Browser_ego_page_events.script ".events()");
  List.iter (fun (name, script) ->
    check int (name ^ " never reads ego's buffer itself") 0 (count script ".events()");
    check bool (name ^ " drains through mascPageEvents") true (contains script "mascPageEvents(page)"))
    ["the workflow", Masc.Browser_ego_workflow.script; "native typing", Masc.Browser_ego_raw_type.script];
  check int "the console read never reads ego's buffer itself" 0
    (count (Masc.Browser_ego_console.script ~answer_units:1000) ".events()")

(* A page.console answer as mascConsoleRead emits it (L9 evidence c). *)
let console_entry ?(kind="console") ?(level="log") ?(text="load-line 7 Object") ?(cut=false) () =
  obj ["type",str kind;"level",str level;"text",str text;"textCut",`Bool cut;"timestamp",`Int 1794035766700]
let console_answer ?(entries=[console_entry ()]) ?(hiding=obj ["offMs",`Int 8;"restored",`Bool true]) () =
  obj ["entries",`List entries;"dropped",`Int 0;"malformedEvents",obj ["count",`Int 0;"last",`Null];"hiding",hiding]

(* The answer is rebuilt from what was parsed. An answer masc cannot read
   does not say whether the hiding came back on, so it is an unknown outcome;
   a failure after the hiding came back on changed nothing. *)
let test_console_read_rebuilds_every_entry () =
  let asked = ref [] in
  let reply = ref (refused "no reply set") in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with
    | "tabs.list" -> answered tabs
    | "page.console" -> !reply
    | other -> failf "unexpected console step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let read ?(tab_id=1) () = dispatch peer Live.Page_console (obj ["tabId",`Int tab_id]) in
  let entries = [
    console_entry ();
    console_entry ~level:"warning" ~text:"load-warn" ();
    console_entry ~kind:"javascript" ~level:"error" ~text:"Uncaught Error: load-uncaught\n    at http://127.0.0.1:18776/page:5:31" ();
    console_entry ~text:(String.concat "" (List.init 1333 (fun _ -> "\xea\xb0\x80"))) ~cut:true () ] in
  reply := answered (console_answer ~entries ());
  (match read () with
   | Ok answer ->
     check int "the tab" 1 (Yojson.Safe.Util.to_int (field "tabId" answer));
     check (list string) "every entry as the script answered it"
       (List.map Yojson.Safe.to_string entries)
       (List.map Yojson.Safe.to_string (Yojson.Safe.Util.to_list (field "entries" answer)));
     check string "the hiding window" {|{"offMs":8,"restored":true}|} (Yojson.Safe.to_string (field "hiding" answer))
   | other -> failf "the console read was %s" (failure_kind other));
  check string "the Page it names" "p1" (text (field "label" (List.hd !asked).args));
  reply := answered (console_answer ~hiding:(obj ["offMs",`Int 12;"restored",`Bool false;"error",str "egoAutomated.enable failed"]) ());
  (match read () with
   | Ok answer -> check bool "hiding left off says so" true (contains (Yojson.Safe.to_string (field "hiding" answer)) "is still off")
   | other -> failf "a read that left the hiding off was %s" (failure_kind other));
  List.iter (fun (label, value) ->
    reply := answered value;
    check string label "unknown" (failure_kind (read ())))
    ["a kind the script does not name is refused", console_answer ~entries:[console_entry ~kind:"network" ()] ();
     "an uncaught error at another level is refused", console_answer ~entries:[console_entry ~kind:"javascript" ~level:"log" ()] ();
     "a text past the byte limit is refused",
       console_answer ~entries:[console_entry ~text:(String.make (Masc.Browser_ego_console.text_bytes_limit + 1) 'x') ~cut:true ()] ();
     "a text that is not UTF-8 is refused", console_answer ~entries:[console_entry ~text:"\xff" ()] ();
     "hiding restored with an error is refused",
       console_answer ~hiding:(obj ["offMs",`Int 1;"restored",`Bool true;"error",str "x"]) ();
     "more entries than the read answers is refused",
       console_answer ~entries:(List.init (Masc.Browser_ego_console.entries_limit + 1) (fun _ -> console_entry ())) ();
     "an answer with more fields is refused",
       (match console_answer () with `Assoc fields -> obj (fields @ ["extra",`Null]) | other -> other)];
  reply := refused "the tab's console was not read: Runtime.enable failed; ego's console hiding was off for 4 ms and is on again";
  check string "a failure after the hiding came back on changed nothing" "before effect" (failure_kind (read ()));
  reply := failed "the tab's console was not read: Runtime.enable failed; ego's console hiding was not turned back on: gone";
  (match read () with
   | Error (Live.Outcome_unknown message) ->
     check bool "hiding that may be off is an unknown outcome that says so" true (contains message "may still be off")
   | other -> failf "a read that may have left the hiding off was %s" (failure_kind other));
  let runs = List.length !asked in
  check string "an operator tab is refused" "before effect" (failure_kind (read ~tab_id:2 ()));
  check string "a read without a tab is refused" "before effect" (failure_kind (dispatch peer Live.Page_console (obj [])));
  check int "and neither runs a script" runs (List.length !asked)

(* What leaves the peer says where input stands and which SDK process ran
   it, failures included. *)
let test_every_answer_carries_the_input_state () =
  let module Input=Masc.Browser_ego_input in
  let dialog=ego_dialog "alert" "mousedown interrupted" in
  let input_reply receipt = answered (obj ["urlBefore",str observed_url;
    "tab",obj ["url",str observed_url;"title",str "Slack"];"receipt",receipt;"error",`Null]) in
  let reply=ref (input_reply (obj ["dialog",dialog])) in
  let peer=opened (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | "page.target_input" -> !reply
    | other -> failf "unexpected input-state step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let gesture=interact_args (Lane.Click "#source") in
  ignore (dispatch peer Live.Page_interact gesture);
  check bool "the interrupted gesture left pending input" true
    (match Peer.input_status peer with Input.Uncertain _ -> true | Input.Ready _ -> false);
  let receipt_of label = function
    | Error (Live.Observed_failure {receipt;_} | Live.Partial_failure {receipt;_}) -> receipt
    | Ok _ | Error (Live.Before_effect _ | Live.Outcome_unknown _) -> fail (label ^ ": no failure receipt") in
  let stamped result = Peer.with_session_state peer ~sdk_process_started_at:(Some 12.5) result in
  let held label receipt =
    check string (label ^ ": readiness") "release_uncertain" (text (field "inputReadiness" receipt));
    check bool (label ^ ": SDK process") true (field "sdkProcessStartedAt" receipt = `Float 12.5) in
  (match stamped (dispatch peer Live.Page_interact gesture) with
   | Ok value -> held "the next input" value
   | Error _ as other -> failf "the next input while release is uncertain was %s" (failure_kind other));
  let refusal=stamped (Error (Live.Before_effect "refused")) in
  check string "a refusal stays before any effect" "before effect" (failure_kind refusal);
  held "a refusal" (receipt_of "a refusal" refusal);
  let unknown=stamped (Error (Live.Outcome_unknown "lost answer")) in
  check string "an unknown outcome stays unknown" "unknown" (failure_kind unknown);
  held "an unknown outcome" (receipt_of "an unknown outcome" unknown);
  (match stamped (dispatch peer Live.Browser_info (obj [])) with
   | Ok value -> held "a read while held" value
   | Error _ -> fail "a read while input is held was not served");
  let partial=receipt_of "a partial failure"
    (stamped (Error (Live.Partial_failure {tab_id=1;message="partial";receipt=obj ["step",`Int 1]}))) in
  held "a partial failure" partial;
  check int "a partial receipt keeps its own fields" 1 (Yojson.Safe.Util.to_int (field "step" partial));
  reply:=input_reply (obj []);
  ignore (dispatch peer Live.Page_interact gesture);
  let after=receipt_of "a failure after a clean receipt"
    (Peer.with_session_state peer ~sdk_process_started_at:None (Error (Live.Before_effect "refused"))) in
  check string "after a clean receipt the readiness is settled" "command_settled" (text (field "inputReadiness" after));
  check bool "no running SDK process answers null" true
    (List.assoc_opt "sdkProcessStartedAt" (Yojson.Safe.Util.to_assoc after) = Some `Null)

let test_chooser_upload_runs_after_uncertain_pointer_release () =
  let directory = Unix.realpath (capture_directory ()) in
  let path = Filename.concat directory "owned-upload.txt" in
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel "fixture");
  let native_drag = Lane.Drag_to {source=Lane.Selector "#source";destination=Lane.Selector "#destination";via=[];duration_ms=0} in
  List.iter (fun (name, drag) ->
    let asked = ref [] in
    let peer = opened (fun sent ->
      asked := sent.step :: !asked;
      match sent.step with
      | "tabs.list" -> answered tabs
      | "page.target_input" -> answered (obj ["error",str "input release unconfirmed"])
      | "page.upload" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null])
      | "page.choose_files" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null])
      | other -> failf "%s unexpectedly dispatched %s" name other) in
    ignore (dispatch peer Live.Tabs_list (obj []));
    check string (name ^ " leaves release uncertain") "unknown"
      (failure_kind (dispatch peer Live.Page_interact (interact_args drag)));
    let upload target = dispatch peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Upload {target;paths=[path]}})) in
    (match upload (Lane.Action.Chooser_opener "#attach") with
     | Ok receipt -> check string (name ^ " chooser upload reports release as uncertain") "release_uncertain"
         (text (field "inputReadiness" receipt))
     | Error _ as other -> failf "%s chooser upload after uncertain release was %s" name (failure_kind other));
    check string (name ^ " delegates chooser upload to the SDK") "page.choose_files" (List.hd !asked);
    check string (name ^ " permits upload without pointer input") "served"
      (failure_kind (upload (Lane.Action.File_input "#file")));
    check string (name ^ " delegates file-input upload to SDK") "page.upload" (List.hd !asked)
  ) ["native drag", native_drag]

let png = "\137PNG\r\n\026\nfixture"
let state ~url ~width = in_page (obj ["url",str url;"title",str "Slack";
  "viewport",obj ["width",`Int width;"height",`Int 600]])

(* Every script the peer hands to ego parses as the ES module ego runs. *)
let test_the_scripts_parse_as_modules () =
  let scripts = ref [] in
  let directory = capture_directory () in
  let enter=match Lane.Keyboard.of_wire ~key:"Enter" ~modifiers:[] with
    | Ok key -> key | Error message -> fail message in
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
    | "page.pointer" | "page.keyboard" | "page.touch" -> input_answer ()
    | "page.input" -> dom_answer (obj ["action",str "fill"])
    | "page.open" -> answered (obj ["label",str "p4";"error",`Null;"tab",obj ["url",str "https://example.test/";"title",str "New";"active",`Bool true]])
    | "page.goto" -> answered (obj ["error",`Null;"tab",obj ["url",str "https://example.test/";"title",str "Next"]])
    | "page.stop_loading" -> answered (obj ["spaceId",`Int 51;"label",str "p1";"targetId",str "T1";
        "openedBy",str "agent";"method",str "Page.stopLoading";"returned",`Bool true])
    | "page.close" -> answered (obj ["closed",`Bool true])
    | "page.reload" | "page.history" -> answered (obj ["error",`Null;"tab",obj ["url",str "https://example.test/";"title",str "Back"]])
    | "page.snapshot" -> answered (obj ["label",str "p1";"url",str "u";"title",str "T";"snapshot",str "root";"truncated",`Bool false;"chars",`Int 4])
    | "page.dialog" -> answered (obj ["answered",`Bool true;"dialog",ego_dialog ~default:"def" "prompt" "name?"])
    | "page.target_input" -> answered (obj ["urlBefore",str observed_url;"receipt",obj [];"error",`Null;
        "tab",obj ["url",str observed_url;"title",str "Slack"]])
    | "page.downloads" -> answered (obj ["since",`Null;"rows",`List []])
    | "page.cookies" -> answered (storage_answer ())
    | "page.network" -> answered (network_answer ())
    | "page.console" -> answered (console_answer ())
    | "page.set_cookie" -> answered (obj ["name",str "n";"domain",str "app.example.com";"path",str "/";"secure",`Bool false;
        "httpOnly",`Bool false;"session",`Bool true;"replaced",`Bool false])
    | "page.delete_cookie" -> answered (obj ["deleted",`List []])
    | "page.upload" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null])
    | "page.choose_files" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null])
    | "page.emulation" -> answered (obj ["applied",`List [];"before",`Null;"observed",`Null])
    | _ -> page_answer ~label:"p1" (obj ["url",str "u"]) in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:directory with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  List.iter (fun (verb, args) -> ignore (dispatch peer verb args))
    [ Live.Page_read, obj ["tabId",`Int 1];
      Live.Page_read, obj ["tabId",`Int 1;"includeHtml",`Bool true];
      Live.Page_elements, obj ["tabId",`Int 1;"within",str "#main"];
      Live.Page_scene, obj ["tabId",`Int 1];
      Live.Page_snapshot, obj ["tabId",`Int 1;"maxChars",`Int 1000;"scope",str "subtree";"root",str "@12"];
      Live.Page_downloads, obj ["tabId",`Int 1];
      Live.Page_cookies, obj ["tabId",`Int 1];
      Live.Page_network, obj ["tabId",`Int 1];
      Live.Page_console, obj ["tabId",`Int 1];
      Live.Page_capture, obj ["tabId",`Int 1];
      Live.Page_act, act_args (Lane.Action.Open_tab "https://example.test/");
      Live.Page_goto, obj ["tabId",`Int 1;"url",str "https://example.test/"];
      Live.Page_interact, interact_args (Lane.Click_node {document_id="d1";node_id="send"});
      Live.Page_interact, interact_args (Lane.Hover_at {point={x=0.5;y=0.5};viewport});
      Live.Page_interact, interact_args (Lane.Scroll_at {point={x=0.5;y=0.5};viewport;x=0;y=120});
      Live.Page_interact, interact_args (Lane.Press_key {document_id="d1";key=enter});
      Live.Page_interact, interact_args (Lane.Fill_node {target={document_id="d1";node_id="message"};text="hi"});
      Live.Page_interact, interact_args (Lane.Fill_target {target=Lane.Target_ref 5;text="hi"});
      Live.Page_interact, interact_args (Lane.Set_viewport (Lane.Fit {width=800;height=600}));
      Live.Page_interact, interact_args (Lane.Tap_at {point={x=0.5;y=0.5};viewport});
      Live.Page_interact, interact_args (Lane.Swipe {from={x=0.25;y=0.5};to_={x=0.75;y=0.5};viewport;via=[{x=0.5;y=0.25}];duration_ms=32});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=3;interaction=Lane.Action.Close_tab});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Reload});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Stop_loading});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Back});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Accept_dialog (Some "hi")});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Dismiss_dialog});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Upload {target=Lane.Action.File_input "#file";paths=[upload_file]}});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Upload {target=Lane.Action.Chooser_opener "#attach";paths=[upload_file]}});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Set_emulation {geolocation=Some {latitude=1.;longitude=2.;accuracy_m=10.};locale=Some "fr-FR";timezone=Some "UTC"}});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Clear_emulation});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Block_requests ["ads.example.com"]});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Unblock_requests});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Set_cookie {name="n";value="v";path="/";secure=false;http_only=false;same_site=None;max_age_sec=None}});
      Live.Page_act, act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Delete_cookie "n"}) ];
  check (result unit string) "finish" (Ok ()) (Peer.finish peer);
  check (list string) "every step"
    ["space.open";"tabs.list";"page.read";"page.document";"page.elements";"page.scene";"page.snapshot";"page.downloads";"page.cookies";"page.network";"page.console";"page.capture";
     "page.open";"page.goto";"page.target";"page.pointer";"page.pointer";"page.pointer";"page.keyboard";"page.input";"page.target_input";"page.viewport";"page.touch";"page.touch";
     "page.close";"page.reload";"page.stop_loading";"page.history";"page.dialog";"page.dialog";"page.upload";"page.choose_files";"page.emulation";"page.emulation";"page.block_requests";"page.block_requests";
     "page.set_cookie";"page.delete_cookie";"space.finish"]
    (List.rev_map fst !scripts);
  List.iter (fun (step, script) ->
    let file = Filename.concat directory (step ^ ".mjs") in
    Out_channel.with_open_bin file (fun channel -> Out_channel.output_string channel script);
    let pid = Unix.create_process "node" [|"node";"--check";file|] Unix.stdin Unix.stdout Unix.stderr in
    match Unix.waitpid [] pid with
    | _, Unix.WEXITED 0 -> ()
    | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> failf "the %s script does not parse as a module" step)
    !scripts;
  List.iter (fun (step, script) -> match step with
    | "page.touch" ->
      check bool "touch is CDP touch events" true (contains script "Input.dispatchTouchEvent");
      check bool "a failed touch is cancelled" true (contains script "touchCancel");
      check bool "with no touch emulation" false (contains script "setTouchEmulationEnabled")
    | "tabs.list" ->
      check bool "the tab list asks the browser for each tab's window" true (contains script "Browser.getWindowForTarget")
    | "page.block_requests" ->
      check bool "a block is a URLPattern on the Page's CDP session" true
        (contains script "Network.setBlockedURLs" && contains script "urlPatterns" && contains script ":*/*");
      check bool "with no glob that also matches a URL carrying the host in its query" false (contains script "urls:")
    | "page.cookies" ->
      check bool "the cookies are listed for the URL the page answered" true
        (contains script "Network.getCookies" && contains script "{urls: [seen.url]}");
      check bool "and the value is dropped in the SDK process" false (contains script "cookie.value")
    | "page.network" ->
      check bool "the log is read through the shared drain" true
        (contains script "mascNetworkLog(page)" && contains script Masc.Browser_ego_page_events.script)
    | "page.set_cookie" | "page.delete_cookie" ->
      check bool "a cookie is written and read back through the Page's CDP session" true
        (contains script "Network.setCookie" && contains script "Network.deleteCookies" && contains script "Network.getCookies");
      check bool "a delete names each cookie by its domain and path" true
        (contains script "{name: cookie.name, domain: cookie.domain, path: cookie.path}");
      check bool "and no value leaves the SDK process" false (contains script "held.value" || contains script "cookie.value")
    | "page.console" ->
      check bool "the console is read through the shared drain" true
        (contains script "mascConsoleRead(page, reason)" && contains script Masc.Browser_ego_page_events.script
         && contains script "egoAutomated.enable")
    | _ -> ())
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
    | "page.read" | "page.document" | "page.elements" | "page.scene" -> page_answer ~label:"p1" (obj ["url",str "https://app.slack.com/"])
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
    | "page.context" -> answered (obj ["dialog",`Null])
    | "page.open" -> answered (obj ["label",str "p4";"error",`Null;"tab",obj ["url",str "https://example.test/new";"title",str "New";"active",`Bool true]])
    | "page.goto" | "page.history" -> answered (obj ["error",`Null;"tab",obj ["url",str "https://example.test/next";"title",str "Next"]])
    | "page.stop_loading" -> answered (obj ["spaceId",`Int 51;"label",str "p1";"targetId",str "T1";
        "openedBy",str "agent";"method",str "Page.stopLoading";"returned",`Bool true])
    | "page.close" -> answered (obj ["closed",`Bool true])
    | "page.dialog" -> answered (obj ["answered",`Bool true;"dialog",ego_dialog "alert" "hello"])
    | "space.hand_off" -> answered (obj ["spaceId",`Int 51;"spaceName",str "masc"])
    | "space.adopt_tab" -> answered (obj ["label",str "adopted";"targetId",str "T9";"openedBy",str "unknown"])
    | "page.downloads" -> answered (obj ["since",`Null;"rows",`List []])
    | "page.cookies" -> answered (storage_answer ())
    | "page.network" -> answered (network_answer ())
    | "page.console" -> answered (console_answer ())
    | "page.upload" -> answered (obj ["error",`Null;"dialog",`Null;"tab",`Null])
    | "page.emulation" -> answered (obj ["applied",`List [str "locale"];"before",`Null;"observed",`Null])
    | "page.block_requests" -> answered (obj ["blocked",`List [str "ads.example.com"]])
    | "page.set_cookie" -> answered (cookie_answer ~name:"n" ())
    | "page.target" -> answered resolved
    | "page.pointer" | "page.keyboard" | "page.viewport" | "page.touch" -> input_answer ()
    | "page.input" -> dom_answer (obj ["action",str "fill"])
    | other -> failf "unexpected step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let viewport : Lane.Pointer.viewport = {document_id="observed"; width=800.; height=600.; scroll_x=0.; scroll_y=0.} in
  let point : Lane.Pointer.point = {x=0.5;y=0.5} in
  let interact action = Lane.Page_interact {tab_id=1; expected_url=Some "https://app.slack.com/"; action} in
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
    | Trusted_drag -> interact (Drag_to {source=Selector "#source";destination=Selector "#destination";via=[];duration_ms=0})
    | Trusted_double_click -> interact (Double_click_at {point;viewport})
    | Trusted_button_click -> interact (Click_at {point;viewport;button=Pointer.Secondary})
    | Viewport_resize -> interact (Set_viewport (Fit {width=800;height=600}))
    | Touch_input -> interact (Swipe {from=point;to_={x=0.75;y=0.5};viewport;via=[];duration_ms=0})
    | Trusted_keyboard ->
      let key=match Keyboard.of_wire ~key:"Enter" ~modifiers:[] with Ok key->key|Error message->fail message in
      interact (Press_key {document_id=viewport.document_id;key})
    | Page_recovery -> Page_act (Action.On_tab {tab_id=1;interaction=Action.Stop_loading})
    | Tab_history -> Page_act (Action.On_tab {tab_id=1;interaction=Action.Back})
    | Tab_closing -> Page_act (Action.On_tab {tab_id=3;interaction=Action.Close_tab})
    | Tab_navigation -> Page_goto {url="https://example.test/next";tab_id=Some 1}
    | Tab_activation -> interact Activate_tab
    | Tab_creation -> Page_act (Action.Open_tab "https://example.test/new")
    | Dialog_read -> Page_context {tab_id=1}
    | Dialog_answer -> Page_act (Action.On_tab {tab_id=1;interaction=Action.Dismiss_dialog})
    | Operator_handoff -> Page_act (Action.Control Action.Hand_off)
    | Page_management -> Page_act (Action.Control (Action.Adopt_tab {tab_id=2;label=None}))
    | Download_listing -> Page_downloads {tab_id=1}
    | File_upload -> Page_act (Action.On_tab {tab_id=1;interaction=Action.Upload {target=Action.File_input "#file";paths=[upload_file]}})
    | Environment_emulation -> Page_act (Action.On_tab {tab_id=1;interaction=Action.Set_emulation {geolocation=None;locale=Some "fr-FR";timezone=None}})
    | Request_blocking -> Page_act (Action.On_tab {tab_id=1;interaction=Action.Block_requests ["ads.example.com"]})
    | Storage_listing -> Page_cookies {tab_id=1}
    | Request_listing -> Page_network {tab_id=1}
    | Console_reading -> Page_console {tab_id=1}
    | Cookie_writing -> Page_act (Action.On_tab {tab_id=1;interaction=Action.Delete_cookie "n"})) in
  List.iter (fun capability ->
    let name = Lane.live_capability_to_wire capability in
    let asked = verb_asking_for capability in
    check bool (name ^ " is what its verb asks for") true (Lane.live_capability asked = capability);
    let wire = Lane.verb_json asked in
    let verb = match Live.verb_of_wire Yojson.Safe.Util.(wire |> member "verb" |> to_string) with
      | Some verb -> verb
      | None -> failf "the lane put a verb on the wire that the peer does not decode: %s" name in
    let served = Lane.live_transport_serves Lane.Ego_task_space capability in
    match dispatch peer verb (Yojson.Safe.Util.member "args" wire), served with
    | Ok _, true | Error (Live.Before_effect _), false -> ()
    | Ok _, false -> failf "the peer served %s, which the lane table says ego does not" name
    | Error (Live.Before_effect detail), true | Error (Live.Outcome_unknown detail | Live.Observed_failure {message=detail;_} | Live.Partial_failure {message=detail;_}), _ ->
      failf "the peer did not serve %s (%s), which the lane table says ego does" name detail)
    Lane.all_of_live_capability

(* The history scripts run in node against a stand-in for ego: one agent page
   whose history holds a.test then b.test. A move to an entry lands a little
   after the CDP call returns, as a navigation commits later; with [detaches]
   the first history read after it fails, as ego's did while the page changed
   renderer. With [same_url] both entries have one URL, as a pushState to the
   same address makes; [load] is what the load wait does after it notes the
   call. The stand-in prints the CDP calls and waits the script made. *)
let stand_in ~current ~navigation ~detaches ~same_url ~load ~stops_in_ms = Printf.sprintf {js|
const runStopsAt = Date.now() + %d;
const entries = [{id: 11, url: "https://a.test/", title: "A"}, {id: 12, url: "%s", title: "B"}];
let current = %d;
let detached = false;
const seen = [];
const loads = [];
process.on("exit", () => console.log("seen " + JSON.stringify(seen) + "\nloads " + JSON.stringify(loads)));
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
  waitForLoadState: async (state, options) => { seen.push("load at " + current); loads.push({state: state ?? null, options: options ?? null}); %s },
};
const taskSpace = async () => ({
  ownership: "agent",
  tabs: async () => [{label: "p1", targetId: "T1", openedBy: "agent", url: entries[current].url, title: entries[current].title}],
  page: () => page,
});
|js} stops_in_ms (if same_url then "https://a.test/" else "https://b.test/") current navigation detaches load

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
      ~space:(Browser_configuration.Named_space "SDK Space") ~version:"fixture" ~capture_directory:(capture_directory ()) with
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
      ~space:(Browser_configuration.Named_space "SDK Space") ~version:"fixture" ~capture_directory:directory with
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
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
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
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
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
  let release_stays_uncertain () =
    check bool "an interrupted target gesture leaves release uncertain" true
      (match Peer.input_status peer with Masc.Browser_ego_input.Uncertain _ -> true | Ready _ -> false) in
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
  release_stays_uncertain ();
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
  release_stays_uncertain ();
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
  let ownership=ref "agent" and native_failure=ref false and calls=ref 0 and inputs=ref 0 and output=ref "" in
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
    | "page.target_input" -> incr inputs;answered (obj ["urlBefore",str observed_url;
        "receipt",obj [];"error",str "native drag interrupted";"tab",obj ["url",str observed_url;"title",str "Slack"]])
    | other -> failf "unexpected control wait step %s" other in
  let peer=match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now
      ~space:(Browser_configuration.Named_space "SDK Space") ~version:"fixture" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  let wait options=dispatch peer Live.Page_act (obj ["action",str "wait_for_control";"controlOptions",options]) in
  let seen ()=match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.from_string (after ~prefix:"seen " line)
    | None -> fail "native stand-in emitted no calls" in
  let options=obj ["interval",`Float 0.5;"timeout",`Int 120000] in
  (match wait options with
   | Ok value -> check bool "wait observation names the same Space" true
       (value=obj ["inputReadiness",str "command_settled";"action",str "wait_for_control";"spaceId",`Int 51;"spaceName",str "SDK Space";"controlAvailable",`Bool true])
   | Error _ -> fail "native control wait failed");
  check bool "the caller's timeout beyond a generic reply window reaches the SDK unchanged" true
    (seen ()=`List [obj ["interval",`Float 0.5;"timeout",`Int 120000]]);
  check int "one original SDK wait was dispatched" 1 !calls;
  native_failure:=true;
  ignore (before_effect "SDK wait timeout sends no input" (wait (obj [])));
  check bool "omitted options remain omitted even when the SDK times out" true
    (seen ()=`List [obj []]);
  native_failure:=false;
  (match wait (obj ["interval",`Float 0.5]) with
   | Ok _ -> ()
   | Error _ -> fail "an interval without a timeout keeps the SDK deadline default");
  check bool "an omitted timeout is not replaced with a host deadline" true
    (seen ()=`List [obj ["interval",`Float 0.5]]);
  native_failure:=false;ownership:="agentDelegatedToUser";
  ignore (before_effect "a user-held Space cannot be reclaimed by waiting" (wait (obj [])));
  check bool "user-held Space runs no native wait or page call" true (seen ()=`List []);
  ownership:="agent";
  ignore (dispatch peer Live.Tabs_list (obj []));
  let drag=Lane.Drag_to {source=Lane.Selector "@12";destination=Lane.Selector "#target";via=[];duration_ms=0} in
  check string "drag first leaves input unconfirmed" "unknown"
    (failure_kind (dispatch peer Live.Page_interact (interact_args drag)));
  let pending=Peer.input_status peer in
  (match wait (obj []) with
   | Ok value -> check string "control observation reports release as uncertain" "release_uncertain"
       (text (field "inputReadiness" value))
   | Error _ -> fail "control observation was refused after uncertain input");
  check bool "control availability preserves the exact pending input" true (Peer.input_status peer=pending);
  let before= !inputs in
  check string "a later input runs while release is uncertain" "unknown"
    (failure_kind (dispatch peer Live.Page_interact (interact_args (Lane.Click "#send"))));
  check int "the later input was dispatched once" (before + 1) !inputs

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
  tabs:async()=>{seen.push('tabs');const label=%s;return [{...(label===null?{}:{label}),targetId:'T9',openedBy:'unknown',page:handle}];},
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
      ~space:(Browser_configuration.Named_space "SDK Space") ~version:"fixture" ~capture_directory:(capture_directory ()) with
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
  let pending=Peer.input_status peer in
  check bool "the interrupted input leaves release uncertain" true
    (match pending with Masc.Browser_ego_input.Uncertain _ -> true | Ready _ -> false);
  let before= !native_calls in
  (match act (Lane.Action.Release_tab 2) with
   | Ok receipt -> check string "management reports release as still uncertain" "release_uncertain"
       (text (field "inputReadiness" receipt))
   | Error _ as other -> failf "management after uncertain input was %s" (failure_kind other));
  check int "management runs while release is uncertain" (before + 1) !native_calls;
  check bool "management does not clear uncertain input" true (Peer.input_status peer=pending)

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
 if(reference!==51&&reference!=='SDK Space')throw Error('wrong original Space');
 return {spaceId:51,name:'SDK Space',ownership,
  tabs:async()=>{seen.push('tabs');return closed?[]:[{...(label===null?{}:{label}),targetId:'T9',openedBy:'unknown',url,title:'Mail',active,page:handle}];},
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
      ~space:(Browser_configuration.Named_space "SDK Space") ~version:"fixture" ~capture_directory:(capture_directory ()) with
    | Ok peer->peer | Error detail->fail detail in
  let served label=function Ok value->value|other->failf "%s was %s" label (failure_kind other) in
  let peer=open_peer () in
  ignore (served "list original unmanaged Page" (dispatch peer Live.Tabs_list (obj [])));
  let control peer action=dispatch peer Live.Page_act (act_args (Lane.Action.Control action)) in
  let interact peer action=dispatch peer Live.Page_interact
    (field "args" (Lane.verb_json (Lane.Page_interact {tab_id=1;expected_url=Some !url;action}))) in
  let workflow peer=dispatch peer Live.Page_native_workflow (obj ["tabId",`Int 1;"expectedUrl",str !url;"maxChars",`Int 100;
    "steps",`List [obj ["method",str "click";"selector",str "#submit"]]]) in
  let close peer=dispatch peer Live.Page_act
    (act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Close_tab})) in
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
  List.iter (fun (name,action)->
    let value=served name (action ()) in
    check string (name ^ " reports release as still uncertain") "release_uncertain" (text (field "inputReadiness" value)))
    ["a fill while release is uncertain",(fun ()->interact uncertain (Lane.Fill {selector="#editor";text="changed"}));
     "a release while release is uncertain",(fun ()->control uncertain (Lane.Action.Release_tab 1))];
  check int "later native commands run while release is uncertain" (before + 2) !scripts;
  check bool "adopted origin never changes pending input" true (Peer.input_status uncertain=pending)

let test_the_space_goes_to_the_operator_and_back () =
  let ownership = ref "agent" and user_page = ref {|({spaceId:51,label:"p2",targetId:"T2",openedBy:"agent"})|} and output = ref "" in
  let run ~window_s script =
    let sent = sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str !ownership])
    | _ -> output := in_node (control_stand_in ~ownership:!ownership ~user_page:!user_page ^ script); Ok !output in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
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
      ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) in
  check bool "a space handed to the operator still opens, so take_over can bring it back" true
    (Result.is_ok (open_owned_by "agentDelegatedToUser"));
  check bool "a space the operator made does not" true (Result.is_error (open_owned_by "user"))

let test_history_moves_one_entry () =
  let current = ref 1 and navigation = ref "" and detaches = ref false and same_url = ref false and load = ref ""
  and stops_in_ms = ref 10_000 in
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
        ~same_url:!same_url ~load:!load ~stops_in_ms:!stops_in_ms ^ script);
      Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let on_tab ?(tab_id=1) interaction = dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id;interaction})) in
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  (match on_tab Lane.Action.Back with
   | Ok receipt -> check string "back" {|{"inputReadiness":"command_settled","tabId":1,"action":"back","url":"https://a.test/","title":"A"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "back was %s" (failure_kind other));
  check bool "it moved to the entry" true (List.mem "Page.navigateToHistoryEntry" (seen ()));
  check string "and waited for the load once the tab was on it" "load at 0" (List.hd (List.rev (seen ())));
  check bool "back runs within the action window" true ((List.hd !steps).window_s
    < Lane.reply_timeout_sec (Lane.Page_act (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Back})));
  let load_timeout () = match List.find_opt (String.starts_with ~prefix:"loads ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(Yojson.Safe.from_string (after ~prefix:"loads " line)
        |> to_list |> List.hd |> member "options" |> member "timeout" |> to_int)
    | None -> fail "the stand-in did not say how it waited for the load" in
  let margin = Yojson.Safe.Util.(member "answerMarginMs" (List.hd !steps).args |> to_int) in
  let timeout = load_timeout () in
  check bool "the load wait ends an answer margin before the run is stopped" true
    (timeout >= 1 && timeout <= !stops_in_ms - margin);
  stops_in_ms := margin + 200;
  navigation := "return {};";
  (match on_tab Lane.Action.Back with
   | Error (Live.Partial_failure {tab_id; receipt; _}) ->
     check int "a move that never lands answers for its tab" 1 tab_id;
     check string "before its run is stopped, with where the tab still is"
       {|{"inputReadiness":"command_settled","tabId":1,"action":"back","url":"https://b.test/","title":"B"}|}
       (Yojson.Safe.to_string receipt)
   | other -> failf "a move that never landed was %s" (failure_kind other));
  navigation := "";
  stops_in_ms := 10_000;
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

(* ego times its own page.goto and page.reload, and the server sets no
   deadline on these steps. The stand-in prints the options each call got. *)
let navigation_stand_in = {js|
const seen = [];
let opened = false;
process.on("exit", () => console.log("seen " + JSON.stringify(seen)));
const methods = {
  goto: async (url, options) => { seen.push({call: "goto", options: options ?? null}); },
  reload: async options => { seen.push({call: "reload", options: options ?? null}); },
  info: async () => ({url: "https://a.test/", title: "A", w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600}),
};
const page = {label: "p1", ...methods};
const fresh = {label: "p2", ...methods};
const taskSpace = async () => ({
  ownership: "agent",
  tabs: async () => [{label: "p1", targetId: "T1", openedBy: "agent", url: "https://a.test/", title: "A", active: !opened},
    ...(opened ? [{label: "p2", targetId: "T2", openedBy: "agent", url: "https://a.test/", title: "A", active: true}] : [])],
  page: label => label === "p2" ? fresh : page,
  newPage: async () => { opened = true; return fresh; },
});
|js}

let test_sdk_timed_navigation_waits_the_reply_window () =
  let output = ref "" in
  let run ~window_s script = match (sent_of ~window_s script).step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | "tabs.list" -> answered (`List [tab_row ~label:(str "p1") ~target:"T1" ~title:"A" ~url:"https://a.test/" ~active:true ()])
    | "page.open" | "page.goto" | "page.reload" -> output := in_node (navigation_stand_in ^ script); Ok !output
    | other -> failf "unexpected step %s" other in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now
      ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let seen verb args =
    (match dispatch peer verb args with
     | Ok _ -> ()
     | other -> failf "the step was %s" (failure_kind other));
    match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.to_string (Yojson.Safe.from_string (after ~prefix:"seen " line))
    | None -> fail "the stand-in did not say what it saw" in
  let waits call verb =
    Printf.sprintf {|[{"call":"%s","options":{"timeout":%d}}]|} call
      (Float.to_int (Lane.reply_timeout_sec verb *. 1000.)) in
  let reload = Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Reload} in
  check string "a reload waits the command's reply window"
    (waits "reload" (Lane.Page_act reload)) (seen Live.Page_act (act_args reload));
  check string "a move waits the command's reply window"
    (waits "goto" (Lane.Page_goto {url="https://b.test/";tab_id=Some 1}))
    (seen Live.Page_goto (obj ["tabId",`Int 1;"url",str "https://b.test/"]));
  let open_tab = Lane.Action.Open_tab "https://c.test/" in
  check string "a new tab's first move waits the command's reply window"
    (waits "goto" (Lane.Page_act open_tab)) (seen Live.Page_act (act_args open_tab))

(* Inventory stays usable when an explicit dialog read fails. Answers use
   native boolean evidence, never a prerequisite metadata read. *)
let test_dialog_inventory_and_answers_do_not_require_info () =
  let asked = ref [] and reply = ref (fun (_ : sent) -> fail "no reply set") in
  let peer = opened (fun sent ->
    asked := sent :: !asked;
    match sent.step with "tabs.list" -> answered tabs | _ -> !reply sent) in
  let listed ()=match dispatch peer Live.Tabs_list (obj []) with
    | Ok (`List rows) -> rows | Ok _|Error _ -> fail "bare inventory failed" in
  let rows=listed () in
  check int "all native tabs remain usable" 3 (List.length rows);
  check bool "inventory makes no clean-dialog claim" true
    (List.for_all (fun row -> field "dialogObservation" row=str "unobserved" && field "dialog" row=`Null) rows);
  let selected=Result.get_ok (Masc.Browser_surface.inventory_tab ~tab_id:1 (`List rows)) in
  check string "unknown dialog coverage does not invalidate selection" "https://app.slack.com/" selected.url;
  let runs ()=List.length !asked and last ()=List.hd !asked in
  let context= obj ["tabId",`Int 1;"mode",str "dialog"] in
  let read ()=dispatch peer Live.Page_context context in
  let prompt=ego_dialog ~default:"def" "prompt" "name?" in
  reply := (fun _ -> answered (obj ["dialog",prompt]));
  (match read () with
   | Ok value -> check bool "explicit read observes the native dialog" true
       (field "dialogObservation" value=str "observed" && field "dialog" value=
        obj ["type",str "prompt";"message",str "name?";"defaultValue",str "def"])
   | Error _ -> fail "explicit dialog read failed");
  check string "existing context verb carries the read" "page.context" (last ()).step;
  reply := (fun _ -> answered (obj ["dialog",`Null]));
  (match read () with
   | Ok value -> check bool "native successful read alone can observe none" true
       (field "dialogObservation" value=str "observed" && field "dialog" value=`Null)
   | Error _ -> fail "native no-dialog read failed");
  reply := (fun _ -> failed "CDP request timed out: Runtime.evaluate");
  check string "native metadata failure stays a read failure" "CDP request timed out: Runtime.evaluate"
    (before_effect "explicit dialog read" (read ()));
  check bool "failed metadata cannot erase inventory" true (listed ()=rows);
  let act ?(tab_id=1) interaction = dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id;interaction})) in
  reply := (fun _ -> answered (obj ["answered",`Bool true]));
  (match act (Lane.Action.Accept_dialog (Some "Vincent")) with
   | Ok receipt -> check bool "native true answers without invented metadata" true
       (field "answered" receipt=`Bool true && field "dialogObservation" receipt=str "unobserved" && field "dialog" receipt=`Null)
   | Error _ -> fail "native true answer failed");
  check string "on the observed Page label" "p1" (text (field "label" (last ()).args));
  check bool "same numeric Space bound before answer" true (field "spaceId" (last ()).args=`Int 51);
  check bool "accepts exact prompt text" true
    (field "accept" (last ()).args=`Bool true && field "text" (last ()).args=str "Vincent");
  ignore (act Lane.Action.Dismiss_dialog);
  check bool "dismissal stays a distinct native method" true (field "accept" (last ()).args=`Bool false);
  List.iter (fun malformed ->
    reply := (fun _ -> answered malformed);
    match act Lane.Action.Dismiss_dialog with
    | Error (Live.Outcome_unknown _) -> ()
    | other -> failf "missing native true receipt was %s" (failure_kind other))
    [obj [];obj ["answered",`Null];obj ["answered",`Bool false];obj ["answered",str "true"];obj ["answered",`Int 1]];
  reply := (fun _ -> refused "no dialog is open in this tab");
  check string "native false refuses before effect" "no dialog is open in this tab"
    (before_effect "no dialog" (act Lane.Action.Dismiss_dialog));
  reply := (fun _ -> failed "Target closed");
  (match act Lane.Action.Dismiss_dialog with
   | Error (Live.Outcome_unknown _ | Live.Observed_failure {disposition=Live.Uncertain;_}) -> ()
   | other -> failf "lost native answer was %s" (failure_kind other));
  let before=runs () in
  ignore (before_effect "unmanaged Page" (act ~tab_id:2 Lane.Action.Dismiss_dialog));
  check int "unmanaged Page is never answered" before (runs ())

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
  spaceId: 51, label: "p1", targetId: "T1", openedBy: "agent",
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
  spaceId: 51, ownership: "agent",
  tabs: async () => [{label: "p1", page, openedBy: "agent", url: "https://app.slack.com/", title: "Slack", targetId: "T1", active: true}],
  page: () => page,
});
|js} (Yojson.Safe.to_string open_) (Yojson.Safe.to_string opening) opens_on (Yojson.Safe.to_string canned)

let test_dialog_scripts_in_node () =
  let scenario = ref (`Null, `Null, "") and output = ref "" and native_answer = ref None in
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
      let answer = match !native_answer with
        | None -> ""
        | Some value -> "page.acceptDialog = page.dismissDialog = async () => " ^ value ^ ";\n" in
      output := in_node (dialog_stand_in ~open_ ~opening ~opens_on ~canned:(canned step) ^ answer ^ script);
      Ok !output in
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  let act interaction = dispatch peer Live.Page_act (act_args (Lane.Action.On_tab {tab_id=1;interaction})) in
  let interact action = dispatch peer Live.Page_interact (interact_args action) in
  let blocked detail = check bool ("refused as blocked: " ^ detail) true (String_util.contains_substring detail "is blocked on a JavaScript dialog") in
  let prompt = ego_dialog ~default:"def" "prompt" "name?" and alert = ego_dialog "alert" "saved" in
  scenario := (prompt, `Null, "");
  (match dispatch peer Live.Tabs_list (obj []) with
   | Ok rows ->
     let row=match Yojson.Safe.Util.to_list rows with [row] -> row | _ -> fail "expected one listed page" in
     check bool "bare inventory does not read an open dialog" true
       (field "dialogObservation" row=str "unobserved" && field "dialog" row=`Null);
     check bool "dialog inventory retains its native Page provenance" true
       (field "egoPage" row=obj ["label",str "p1";"targetId",str "T1";"openedBy",str "agent"])
   | Error _ -> fail "the listing failed");
  (match act (Lane.Action.Accept_dialog (Some "Vincent")) with
   | Ok receipt -> check string "the answer"
       {|{"inputReadiness":"command_settled","tabId":1,"action":"accept_dialog","answered":true,"dialogObservation":"unobserved"}|} (Yojson.Safe.to_string receipt)
   | other -> failf "the accept was %s" (failure_kind other));
  check (list string) "answered without a metadata prerequisite" ["accept Vincent"] (seen ());
  List.iter (fun value ->
    native_answer := Some value;
    match act Lane.Action.Dismiss_dialog with
    | Error (Live.Outcome_unknown _) -> ()
    | other -> failf "native non-boolean %s was %s" value (failure_kind other))
    ["undefined";"null";"1";"\"true\""];
  native_answer := Some "false";
  check string "native false refuses without success" "no dialog is open in this tab"
    (before_effect "a native false dialog answer" (act Lane.Action.Dismiss_dialog));
  native_answer := None;
  scenario := (`Null, `Null, "");
  check string "none open" "no dialog is open in this tab" (before_effect "a dismissal with none open" (act Lane.Action.Dismiss_dialog));
  check (list string) "native false is checked by the method" ["dismiss"] (seen ());
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
  let peer = match Peer.open_space ~downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
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
      (act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Upload {target=Lane.Action.File_input selector;paths}})) in
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
      (act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Upload {target=Lane.Action.Chooser_opener opener;paths}})) in
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
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  let upload ?(selector="#file") paths = dispatch peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Upload {target=Lane.Action.File_input selector;paths}})) in
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
  let peer = match Peer.open_space ~downloads:no_downloads ~run ~run_native:(run ~window_s:0.) ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"0.6.0.16" ~capture_directory:(capture_directory ()) with
    | Ok peer -> peer | Error detail -> fail detail in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let seen () = match List.find_opt (String.starts_with ~prefix:"seen ") (String.split_on_char '\n' !output) with
    | Some line -> Yojson.Safe.Util.(to_list (Yojson.Safe.from_string (after ~prefix:"seen " line)) |> List.map to_string)
    | None -> fail "the stand-in did not say what it saw" in
  let choose ?(opener="#attach") paths = dispatch peer Live.Page_act
      (act_args (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Upload {target=Lane.Action.Chooser_opener opener;paths}})) in
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
      ~now ~space:(Browser_configuration.Named_space "SDK Space") ~version:"fixture" ~capture_directory:(capture_directory ()) with
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
        ~space:(Browser_configuration.Named_space "SDK Space") ~version:"fixture" ~capture_directory:(capture_directory ()) with
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

let test_native_dialog_error_keeps_progress_and_wire_observation () =
  let module Wire=Masc.Browser_addon_wire in
  let module Input=Masc.Browser_ego_input in
  List.iter (fun (stage,prior) ->
    let output=ref "" and native_calls=ref 0 in
    let shim=Printf.sprintf {js|
const seen = [], stage = %S;
const dialog = {type:'prompt',message:'page text',defaultPrompt:'',
  url:'https://app.slack.com/',frameId:'F1',hasBrowserHandler:false};
const interrupt = () => { throw Object.assign(new Error('native dialog interruption'), {
  code:'EGO_PAGE_DIALOG_OPENED',method:'Runtime.evaluate',sessionId:'S1',dialog}); };
const page = {
  url: async () => {seen.push('url');if(stage==='initialUrl')interrupt();return 'https://app.slack.com/';},
  evaluate: async () => {seen.push('evaluate');interrupt();},
  click: async () => {seen.push('click');interrupt();},
  fill: async () => {seen.push('fill');return {};},
  info: async () => {seen.push('info');return {
    url:'https://app.slack.com/',title:'Slack',w:800,h:600,sx:0,sy:0,pw:800,ph:600};},
  waitForEvent: () => new Promise(() => {}),
  snapshot: async () => {seen.push('snapshot');return 'must not reach';}
};
const taskSpace = async () => ({ownership:'agent',
  tabs:async () => [{label:'p1',targetId:'T1',openedBy:'agent'}],page:()=>page});
|js} stage in
    let run ~window_s script = match (sent_of ~window_s script).step with
      | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
      | "tabs.list" -> answered tabs
      | step -> failf "unexpected bounded runner step %s" step in
    let run_native script =
      incr native_calls;
      output:=in_node (shim ^ script ^ "\nconsole.log('dialog-calls '+JSON.stringify(seen));");
      Ok !output in
    let peer=match Peer.open_space ~downloads:no_downloads ~run ~run_native ~now
        ~space:(Browser_configuration.Named_space "SDK Space") ~version:"fixture" ~capture_directory:(capture_directory ()) with
      | Ok peer -> peer | Error detail -> fail detail in
    ignore (dispatch peer Live.Tabs_list (obj []));
    let action=if stage="click" then obj ["method",str "click";"selector",str "#interrupt"]
      else obj ["method",str "evaluate";"source",str "window.operation()"] in
    let prefix=if prior then [obj ["method",str "fill";"selector",str "#editor";"text",str "changed"]] else [] in
    let args=obj ["tabId",`Int 1;"expectedUrl",str "https://app.slack.com/";"maxChars",`Int 100;
      "steps",`List (prefix @ [action;obj ["method",str "fill";"selector",str "#never";"text",str "must not run"]])] in
    let result=Peer.dispatch ~command_id:"native-dialog-error" peer ~verb:Live.Page_native_workflow args in
    let receipt=match result with
      | Error (Live.Partial_failure {receipt;_}) when prior -> receipt
      | Error (Live.Observed_failure {disposition;receipt;_}) when not prior ->
        check bool "native metadata does not change failed progress" true
          (disposition=(if stage="initialUrl" then Live.Not_started else Live.Uncertain)); receipt
      | Ok _|Error (Live.Before_effect _|Partial_failure _|Outcome_unknown _|Observed_failure _) ->
        fail "native dialog failure lost its observation or changed disposition" in
    let native=field "nativeError" (field "failure" receipt) in
    check string "native code retained" "EGO_PAGE_DIALOG_OPENED" (text (field "code" native));
    check string "native method retained" "Runtime.evaluate" (text (field "method" native));
    check string "native session retained" "S1" (text (field "sessionId" native));
    check bool "raw prompt fields and false handler flag retained" true (field "dialog" native=
      obj ["type",str "prompt";"message",str "page text";"defaultPrompt",str "";
        "url",str "https://app.slack.com/";"frameId",str "F1";"hasBrowserHandler",`Bool false]);
    check bool "completed prefix remains exact" true
      (List.length (Yojson.Safe.Util.to_list (field "completed" receipt))=(if prior then 1 else 0));
    check bool "completed effect follows prefix only" true (field "completedEffect" receipt=`Bool prior);
    (match Peer.input_status peer with
     | Input.Ready Input.Command_settled when stage<>"click" -> ()
     | Input.Uncertain pending when stage="click" ->
       check string "interrupted holding command stays pending" "native-dialog-error" pending.command_id
     | Input.Ready _|Input.Uncertain _ -> fail "dialog diagnostics changed input readiness");
    let payload=Live.payload result in
    check bool "model-facing failure retains the complete receipt" true (field "data" payload=receipt && field "ok" payload=`Bool false);
    let wire=Wire.reply_to_json (Wire.Issue_result (Ok (Lane.Answered payload))) in
    (match Wire.reply_of_json wire with
     | Ok (Wire.Issue_result (Ok (Lane.Answered restored))) -> check bool "worker wire retains full observation" true (restored=payload)
     | Ok _|Error _ -> fail "worker wire lost native dialog observation");
    let prefix="dialog-calls " in
    let calls=match List.filter (String.starts_with ~prefix) (String.split_on_char '\n' !output) with
      | [line] -> Yojson.Safe.from_string (after ~prefix line)
      | _ -> fail "missing SDK stand-in call receipt" in
    check bool "no follow-up read, step or replay after interruption" true
      (calls=`List (List.map str (["info"] @ (if stage="initialUrl" then ["url"]
        else ["url"] @ (if prior then ["fill"] else []) @ [stage]))));
    check int "one workflow dispatch" 1 !native_calls)
    ["initialUrl",false;"evaluate",false;"evaluate",true;"click",false]

let test_malformed_native_dialog_error_stays_unknown () =
  let dialog_fields=["type",str "alert";"message",str "page text"] in
  let dialog=obj dialog_fields in
  let diagnostic dialog=obj ["code",str "EGO_PAGE_DIALOG_OPENED";"method",str "Runtime.evaluate";
    "sessionId",str "S1";"dialog",dialog] in
  let malformed=[`Null;obj [];obj ["type",str "future";"message",str "page text"];
    obj ["type",str "alert";"message",`Null];
    obj ["type",str "alert";"message",str "page text";"message",str "duplicate"]]
    @ List.map (fun (key,value) -> obj ((key,value)::dialog_fields))
      ["defaultPrompt",`Null;"url",`Bool true;"frameId",`Int 1;"hasBrowserHandler",str "false";"unknown",str "value"] in
  List.iter (fun native ->
    let calls=ref 0 in
    let peer=opened (fun sent -> match sent.step with
      | "tabs.list" -> answered tabs
      | "page.native_workflow" -> incr calls; answered (obj ["completed",`List [];"effectStarted",`Bool true;
          "completedEffect",`Bool false;"inputReleased",`Bool true;
          "failure",obj ["index",`Int 0;"method",str "evaluate";"message",str "native dialog error";"nativeError",native]])
      | step -> failf "unexpected step %s" step) in
    ignore (dispatch peer Live.Tabs_list (obj []));
    let result=dispatch peer Live.Page_native_workflow (obj ["tabId",`Int 1;
      "expectedUrl",str "https://app.slack.com/";"maxChars",`Int 100;
      "steps",`List [obj ["method",str "evaluate";"source",str "window.operation()"]]]) in
    (match result with
     | Error (Live.Outcome_unknown _) -> ()
     | Ok _|Error (Live.Before_effect _|Live.Partial_failure _|Live.Observed_failure _) ->
       fail "malformed native dialog evidence was accepted");
    check int "malformed reply never replays the workflow" 1 !calls)
    (List.map diagnostic malformed @ [obj ["code",str "EGO_PAGE_DIALOG_OPENED";"dialog",dialog];
      obj ["code",str "EGO_PAGE_DIALOG_OPENED";"method",`Null;"sessionId",str "S1";"dialog",dialog]])

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
 if(reference!==51&&reference!=='SDK Space')throw Error('unexpected Space');
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
          ~space:(Browser_configuration.Named_space "SDK Space") ~version:"fixture" ~capture_directory:capture) in
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
      ~space:(Browser_configuration.Named_space "SDK Space") ~version:"fixture" ~capture_directory:(capture_directory ()) with
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
    check bool "invalid takeover does not change input readiness" true (Peer.input_status peer=pending)) malformed;
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
     | (`Proven|`Before|`Snapshot_failed),Ok value ->
       check int "a settled or never-started input is followed by the next original request" 2 !issued;
       check string "the next request reports command settlement" "command_settled" (text (field "inputReadiness" value))
     | (`Lost|`Unreleased|`Contradicted|`Unproven),Ok value ->
       check int "an unknown release is followed by the next original request" 2 !issued;
       check string "the next request reports release as uncertain" "release_uncertain" (text (field "inputReadiness" value))
     | (`Lost|`Unreleased|`Contradicted|`Unproven|`Proven|`Before|`Snapshot_failed),Error _ ->
       fail "the next workflow after a holding workflow was not served");
    ignore (dispatch peer Live.Tabs_list (obj [])))
      ([`Lost;`Unreleased;`Contradicted;`Unproven] @ (if method_="press" then [`Before] else [])
        @ [`Proven;`Snapshot_failed]))
    ["dragAndDrop",["selector",str "#source";"destination",str "#target"];
     "click",["selector",str "#source"];
     "dblclick",["selector",str "#source"];
     "mouse.click",["x",`Int 10;"y",`Int 20];
     "press",["selector",str "#editor";"key",str "ControlOrMeta+Enter"];
     "keyboard.press",["key",str "ControlOrMeta+Enter"];
     "keyboard.paste",["text",str "x"]]

(* A workflow whose holding step is never reached held nothing. It must not turn an earlier
   uncertain release into a settled command. *)
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
      if !issued=1 then failed "keyboard.press" ~released:false
      else if !issued=2 then failed "fill" ~released:true
      else if !issued=3 then answered (obj [
        "completed",`List [obj ["index",`Int 0;"method",str "keyboard.insertText";"receipt",`Null]];
        "effectStarted",`Bool true;"completedEffect",`Bool true;"inputReleased",`Bool true;"failure",`Null;
        "urlBefore",str observed_url;"url",str observed_url;"title",str "Slack";
        "snapshot",str "root";"chars",`Int 4;"truncated",`Bool false])
      else Error (Peer.Unstarted "no node here")
    | other -> failf "unexpected workflow fixture step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let call steps=dispatch peer Live.Page_native_workflow (obj ["tabId",`Int 1;
    "expectedUrl",str "https://app.slack.com/";"maxChars",`Int 1000;"steps",`List steps]) in
  check string "a supported key press that never returned is unknown" "unknown"
    (failure_kind (call [obj ["method",str "keyboard.press";"key",str "Enter"]]));
  let pending=match Peer.input_status peer with Input.Uncertain pending -> pending
    | Ready _ -> fail "the key press did not hold the input" in
  let earlier=Input.Ready (Input.Release_uncertain pending) in
  check string "a fill that fails before the click is unknown" "unknown"
    (failure_kind (call [obj ["method",str "fill";"selector",str "#editor";"text",str "x"];
      obj ["method",str "click";"selector",str "#send"]]));
  check int "the second workflow ran" 2 !issued;
  check bool "a workflow that never held input restores the earlier uncertain release" true (Peer.input_status peer=earlier);
  check string "insertText completes without acquiring holding-input ownership" "served"
    (failure_kind (call [obj ["method",str "keyboard.insertText";"text",str "literal"]]));
  check int "the nonholding insertion was dispatched once" 3 !issued;
  check bool "insertText keeps the earlier uncertain release without manufacturing release proof" true
    (Peer.input_status peer=earlier);
  check string "a script that never started is refused before any effect" "before effect"
    (failure_kind (call [obj ["method",str "click";"selector",str "#send"]]));
  check int "the fourth workflow was asked for" 4 !issued;
  check bool "a script that never started keeps the earlier uncertain release" true (Peer.input_status peer=earlier)

let test_dialog_interrupted_workflow_stays_uncertain_until_a_new_click_settles () =
  let module Input=Masc.Browser_ego_input in
  let answer label = function
    | Ok value -> value
    | Error _ as result -> failf "%s: %s" label (failure_kind result) in
  let issued=ref 0 and scripts=ref 0 and input_commands=ref [] and recovery_peer=ref None in
  let dialog=ego_dialog "alert" "check" in
  let dialog_reply=ref (answered (obj ["answered",`Bool true])) in
  let completed steps ~has_effect ~snapshot = answered (obj [
    "completed",`List steps;"effectStarted",`Bool has_effect;"completedEffect",`Bool has_effect;
    "inputReleased",`Bool true;"failure",`Null;"urlBefore",str "https://app.slack.com/";
    "url",str "https://app.slack.com/";"title",str "Slack";"snapshot",str snapshot;
    "chars",`Int (String.length snapshot);"truncated",`Bool false]) in
  let peer=opened (fun sent -> incr scripts;match sent.step with
    | "tabs.list" -> answered tabs
    | "page.dialog" -> !dialog_reply
    | "page.context" -> failed "CDP request timed out: Runtime.evaluate"
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
           (pending.page_label="p1");
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
    (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Accept_dialog None}))) in
  check string "a result read while input is pending says so" "release_uncertain"
    Yojson.Safe.Util.(accepted |> member "inputReadiness" |> to_string);
  check bool "native true leaves the exact pending generation untouched" true (Peer.input_status peer=Input.Uncertain pending);
  List.iter (fun response ->
    dialog_reply := response;
    ignore (dispatch peer Live.Page_act (Lane.Action.to_json
      (Lane.Action.On_tab {tab_id=1;interaction=Lane.Action.Dismiss_dialog})));
    check bool "false, malformed and lost dialog answers preserve exact pending" true (Peer.input_status peer=Input.Uncertain pending))
    [refused "no dialog is open in this tab";answered (obj ["answered",`Null]);failed "Target closed"];
  ignore (before_effect "unavailable dialog metadata" (dispatch peer Live.Page_context
    (obj ["tabId",`Int 1;"mode",str "dialog"])));
  check bool "failed native read preserves exact pending" true (Peer.input_status peer=Input.Uncertain pending);
  let observed=answer "an observation workflow while release is uncertain" (dispatch peer Live.Page_native_workflow (args [])) in
  check string "the observation reports release as uncertain" "release_uncertain"
    Yojson.Safe.Util.(observed |> member "inputReadiness" |> to_string);
  check bool "an observation workflow leaves the exact pending generation" true (Peer.input_status peer=Input.Uncertain pending);
  let continued=answer "new click while release is uncertain"
    (Peer.dispatch ~command_id:"continued-input-command" peer ~verb:Live.Page_native_workflow
      (args [obj ["method",str "click";"selector",str "#continue"]])) in
  check bool "the new click returns complete native input settlement" true
    (field "completed" continued=`List [obj ["index",`Int 0;"method",str "click";"receipt",obj []]]
      && field "effectStarted" continued=`Bool true && field "completedEffect" continued=`Bool true
      && field "inputReleased" continued=`Bool true && field "failure" continued=`Null
      && field "snapshot" continued=str "root\n  button Continue");
  check bool "the new click's receipt settles input" true
    (Peer.input_status peer=Input.Ready Input.Command_settled
      && field "inputReadiness" continued=str "command_settled");
  check (list (pair string string)) "original click is never replayed; the new command clicks once"
    ["original-input-command","#dialog";"continued-input-command","#continue"] (List.rev !input_commands);
  check int "only original, empty observation and new input workflows were issued" 3 !issued

let test_popup_workflow_identity_and_scope () =
  let module Input=Masc.Browser_ego_input in
  let answer label = function Ok value -> value | other -> failf "%s: %s" label (failure_kind other) in
  let source_url="https://fixture.test/opener" and child_url="https://fixture.test/child" in
  let identity label target=obj ["spaceId",`Int 51;"label",str label;"targetId",str target;"openedBy",str "agent"] in
  let source=identity "p1" "T1" and child=identity "p2" "T2" in
  let pages=obj ["source",source;"current",child;"transitions",`List [obj [
    "index",`Int 0;"source",source;"popup",child;"selected",`Bool true]]] in
  let popup=obj ["method",str "clickAndWaitForPopup";"selector",str "a[target=_blank]"] in
  let args ~tab_id ~expected_url steps=obj ["tabId",`Int tab_id;"expectedUrl",str expected_url;
    "steps",`List steps;"maxChars",`Int 1000] in
  let progress={|{"index":0,"method":"clickAndWaitForPopup","receipt":{}}|} |> Yojson.Safe.from_string in
  let successful url completed extra=obj (extra @ ["completed",`List completed;"effectStarted",`Bool (completed<>[]);
    "completedEffect",`Bool (completed<>[]);"inputReleased",`Bool true;"failure",`Null;
    "urlBefore",str url;"url",str (if completed=[] then url else child_url);"title",str "Owned fixture";
    "snapshot",str "root";"chars",`Int 4;"truncated",`Bool false]) in
  let observed=ref [] in
  let peer=opened (fun sent -> match sent.step with
    | "tabs.list" -> answered (`List [tab_row ~label:(str "p1") ~target:"T1" ~title:"Owned source" ~url:source_url ~active:true ()])
    | "page.native_workflow" ->
      observed:=text (field "label" sent.args)::!observed;
      if field "steps" sent.args=`List [] then answered (successful (text (field "expectedUrl" sent.args)) [] [])
      else answered (successful source_url [progress] ["pages",pages])
    | other -> failf "unexpected popup fixture step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let first=answer "popup workflow" (dispatch peer Live.Page_native_workflow (args ~tab_id:1 ~expected_url:source_url [popup])) in
  let child_tab=Yojson.Safe.Util.to_int (field "tabId" first) in
  check int "source ID stays separately bound" 1 (Yojson.Safe.Util.to_int (field "sourceTabId" first));
  check bool "child receives a distinct stable MASC ID" true (child_tab<>1);
  ignore (answer "later exact child workflow" (dispatch peer Live.Page_native_workflow (args ~tab_id:child_tab ~expected_url:child_url [])));
  ignore (answer "later original source workflow" (dispatch peer Live.Page_native_workflow (args ~tab_id:1 ~expected_url:source_url [])));
  check (list string) "popup identity never overwrites source routing" ["p1";"p2";"p1"] (List.rev !observed);
  let issued=ref 0 in
  let peer=opened (fun sent -> match sent.step with
    | "tabs.list" -> answered (`List [tab_row ~label:(str "p1") ~target:"T1" ~title:"Owned source" ~url:source_url ~active:true ()])
    | "page.native_workflow" -> incr issued; answered (obj ["pages",pages;"completed",`List [progress];
      "effectStarted",`Bool true;"completedEffect",`Bool true;"inputReleased",`Bool false;
      "failure",obj ["index",`Int 1;"method",str "keyboard.press";"message",str "native receipt lost"]])
    | other -> failf "unexpected popup input fixture step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let typed=obj ["method",str "keyboard.press";"key",str "Enter"] in
  (match dispatch peer Live.Page_native_workflow (args ~tab_id:1 ~expected_url:source_url [popup;typed]) with
   | Error (Live.Partial_failure {tab_id;receipt;_}) ->
     check bool "uncertain child retains its exact partial Page identity" true
       (tab_id<>1 && field "tabId" receipt=`Int tab_id && field "sourceTabId" receipt=`Int 1)
   | other -> failf "expected typed popup partial failure, got %s" (failure_kind other));
  (match Peer.input_status peer with
   | Input.Uncertain pending -> check bool "lost multi-Page input is scoped to the original Space without guessing a Page" true
       (pending.scope=Input.Space_scope && pending.page_label="p1")
   | Ready _ -> fail "popup child input was incorrectly released");
  ignore (dispatch peer Live.Page_native_workflow (args ~tab_id:1 ~expected_url:source_url [popup]));
  check int "a new popup input runs once and the unknown child input is not replayed" 2 !issued

let test_popup_workflow_source_binding () =
  let source_url="https://fixture.test/opener" and child_url="https://fixture.test/child" in
  let identity ?(origin="agent") label target=obj ["spaceId",`Int 51;"label",str label;
    "targetId",str target;"openedBy",str origin] in
  let source=identity "p1" "T1" and child=identity "p2" "T2" in
  let popup=obj ["method",str "clickAndWaitForPopup";"selector",str "a[target=_blank]"] in
  let args=obj ["tabId",`Int 1;"expectedUrl",str source_url;"steps",`List [popup];"maxChars",`Int 1000] in
  List.iter (fun changed ->
    let issued=ref 0 and inventories=ref 0 in
    let peer=opened (fun sent -> match sent.step with
      | "tabs.list" -> incr inventories;
        answered (`List [tab_row ~label:(str "p1") ~target:"T1" ~title:"Owned source" ~url:source_url ~active:true ()])
      | "page.native_workflow" ->
        incr issued;
        check bool "host fixes complete source identity before dispatch" true (field "expectedSourcePage" sent.args=source);
        check bool "host supplies the receipt parser's own field contract" true
          (field "inputReceiptContract" sent.args=Masc.Browser_ego_release.receipt_contract);
        let pages=obj ["source",changed;"current",child;"transitions",`List [obj ["index",`Int 0;
          "source",changed;"popup",child;"selected",`Bool true]]] in
        answered (obj ["pages",pages;"completed",`List [obj ["index",`Int 0;"method",str "clickAndWaitForPopup";"receipt",obj []]];
          "effectStarted",`Bool true;"completedEffect",`Bool true;"inputReleased",`Bool true;"failure",`Null;
          "urlBefore",str source_url;"url",str child_url;"title",str "Child";"snapshot",str "root";"chars",`Int 4;"truncated",`Bool false])
      | other -> failf "unexpected source-binding step %s" other) in
    ignore (dispatch peer Live.Tabs_list (obj []));
    (match dispatch peer Live.Page_native_workflow args with
     | Error (Live.Outcome_unknown _) -> ()
     | other -> failf "changed source target/origin was accepted: %s" (failure_kind other));
    check int "popup source was freshly observed before execution" 2 !inventories;
    (match Peer.input_status peer with
     | Masc.Browser_ego_input.Uncertain _ -> ()
     | Ready _ -> fail "changed source identity incorrectly settled input");
    (match dispatch peer Live.Page_native_workflow args with
     | Error (Live.Outcome_unknown _) -> ()
     | other -> failf "a new input on a changed source was %s" (failure_kind other));
    check int "a new input runs once and the changed-source operation is not replayed" 2 !issued)
    [identity "p1" "replacement";identity ~origin:"unknown" "p1" "T1"];
  let issued=ref 0 and inventories=ref 0 in
  let peer=opened (fun sent -> match sent.step with
    | "tabs.list" ->
      incr inventories;
      let row=tab_row ~label:(str "p1") ~target:"T1" ~title:"Owned source" ~url:source_url ~active:true () in
      answered (`List (if !inventories=1 then [row] else [row;row]))
    | "page.native_workflow" -> incr issued; fail "ambiguous native source must refuse before execution"
    | other -> failf "unexpected source-inventory step %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  ignore (before_effect "ambiguous source inventory refuses before input" (dispatch peer Live.Page_native_workflow args));
  check int "no workflow was dispatched on an ambiguous native source" 0 !issued;
  match Peer.input_status peer with
  | Masc.Browser_ego_input.Ready _ -> ()
  | Uncertain _ -> fail "source preflight failure manufactured an input hold"

let test_native_space_status () =
  let ownership=ref "agentDelegatedToUser" and invalid=ref false and unavailable=ref false and duplicate=ref false in
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
const listTaskSpaces=async()=>{seen.push('listTaskSpaces');const row={id:%d,name:'Renamed native Space',ownership:%s};return %s ? [row,row] : [row];};
|js} (if !invalid then 52 else 51) (Yojson.Safe.to_string (str !ownership)) (string_of_bool !duplicate) in
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
  ownership:="future-native-owner";
  let value=match status () with Ok value -> value | Error _ -> fail "opaque metadata value refused" in
  check string "unfamiliar native ownership is data, not a default decision" !ownership (text (field "ownership" value));
  invalid:=true;
  ignore (before_effect "foreign Space metadata is refused" (status ()));
  check bool "failed refresh invalidates the earlier cached observation" true (Option.is_none (Peer.space_observation peer));
  check bool "native absence is retained as missing for the original binding" true
    ((Peer.space_presence peer).state=Masc.Browser_ego_space_observation.Missing);
  invalid:=false;unavailable:=true;
  ignore (before_effect "metadata transport failure sends no Page effect" (status ()));
  check bool "transport failure is unknown, not missing" true
    (match (Peer.space_presence peer).state with
     | Unknown (Transport_unavailable _) -> true | Present|Missing|Unknown _ -> false);
  unavailable:=false;
  duplicate:=true;
  ignore (before_effect "ambiguous native inventory sends no Page effect" (status ()));
  check bool "ambiguous native inventory is unknown, not missing" true
    ((Peer.space_presence peer).state=Masc.Browser_ego_space_observation.Unknown Ambiguous_inventory);
  duplicate:=false;
  ignore (status ());
  check bool "explicit refresh recovers the same binding without allocating" true
    ((Peer.space_presence peer).state=Masc.Browser_ego_space_observation.Present);
  ignore (dispatch peer Live.Page_act (obj ["action",str "hand_off"]));
  check bool "control changes invalidate cached owner metadata" true (Option.is_none (Peer.space_observation peer))

(* ego lite 0.6.2.5 throws from taskSpace itself for a number it does not
   list (probed 2026-11-04), with no error code. The production script runs
   under node with that taskSpace; the body never runs, and one read of
   ego's list says whether the Space is gone. *)
let test_a_space_that_did_not_open_is_looked_up_once () =
  let opens=ref true and listing=ref (`Ids [51]) and lookups=ref [] and output=ref "" in
  let missing_task_space = "const taskSpace=async id=>{throw new Error('task space not found: '+id);};\n" in
  let run ~window_s script =
    let sent=sent_of ~window_s script in
    match sent.step with
    | "space.open" -> answered (obj ["spaceId",`Int 51;"name",str "SDK Space";"ownership",str "agent"])
    | ("tabs.list" | "page.open") when !opens -> if sent.step="tabs.list" then answered tabs
      else answered (obj ["label",str "p4";"error",`Null;"tab",obj ["url",str "https://slack.com/";"title",str "Slack";"active",`Bool true]])
    | "tabs.list" | "page.open" -> output:=in_node (missing_task_space ^ script); Ok !output
    | "space.status" ->
      lookups:=sent.window_s :: !lookups;
      check bool "the lookup reads the original numeric Space" true (sent.space=`Int 51);
      (match !listing with
       | `Unanswered -> Error (Peer.Unobserved "ego went away")
       | `Ids ids -> answered (`List (List.map (fun id ->
           obj ["spaceId",`Int id;"name",str "SDK Space";"ownership",str "agent"]) ids)))
    | other -> failf "unexpected step %s" other in
  let peer=match Peer.open_space ~run ~run_native:(run ~window_s:0.) ~now
    ~space:(Browser_configuration.Named_space "SDK Space") ~version:"fixture"
    ~capture_directory:(capture_directory ()) ~downloads:no_downloads with
    | Ok peer -> peer | Error detail -> fail detail in
  let presence ()=(Peer.space_presence peer).state in
  let answers ()=List.length (List.filter (String.starts_with ~prefix:Peer.result_marker)
    (String.split_on_char '\n' !output)) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  check int "a Space that opened is not looked up" 0 (List.length !lookups);
  opens:=false;
  let detail=before_effect "a Space ego still lists" (dispatch peer Live.Tabs_list (obj [])) in
  check string "a listed Space gives ego's own error back" "task space not found: 51" detail;
  check int "the script answers once" 1 (answers ());
  check bool "it says the Space did not open" true (contains !output {|"spaceOpen":"failed"|});
  check int "one lookup" 1 (List.length !lookups);
  check bool "the lookup has a read's window" true (List.hd !lookups > 0.);
  check bool "a listed Space stays present" true (presence ()=Masc.Browser_ego_space_observation.Present);
  listing:=`Unanswered;
  let detail=before_effect "an unanswered lookup" (dispatch peer Live.Tabs_list (obj [])) in
  check bool "an unanswered lookup keeps ego's error" true (String.starts_with ~prefix:"task space not found: 51" detail);
  check bool "and says presence is unknown, and why" true
    (contains detail "; Space presence is unknown: " && contains detail "ego went away");
  check bool "an unanswered lookup leaves the earlier presence" true (presence ()=Masc.Browser_ego_space_observation.Present);
  listing:=`Ids [52];
  let detail=before_effect "a Space ego no longer lists" (dispatch peer Live.Tabs_list (obj [])) in
  check string "a missing Space is named as missing, and nothing replaces it"
    "the original bound Space is missing from the native inventory; no replacement was opened; this connection ends, and take_over with lane=live and no clientId asks its worker to open the configured Space again, which works only when the worker names the Space rather than its number" detail;
  check bool "the connection's presence is missing" true (presence ()=Masc.Browser_ego_space_observation.Missing);
  let detail=before_effect "an effect step on a missing Space"
    (dispatch peer Live.Page_act (act_args (Lane.Action.Open_tab "https://slack.com/"))) in
  check string "an effect step on it did nothing" "the original bound Space is missing from the native inventory; no replacement was opened; this connection ends, and take_over with lane=live and no clientId asks its worker to open the configured Space again, which works only when the worker names the Space rather than its number" detail;
  check int "each failed open is looked up once" 4 (List.length !lookups)

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

let test_loading_recovery_receipt_requires_original_page () =
  let fields = ["spaceId",`Int 51;"label",str "p1";"targetId",str "T1";
    "openedBy",str "agent";"method",str "Page.stopLoading";"returned",`Bool true] in
  let decode value = Masc.Browser_ego_recovery.receipt ~space_id:51 ~tab_id:1 ~label:"p1" value in
  check bool "native command-return acknowledgement is accepted" true (Result.is_ok (decode (obj fields)));
  List.iter (fun (key,value) ->
    check bool ("invalid " ^ key ^ " is never a recovery acknowledgement") true
      (Result.is_error (decode (obj ((key,value)::List.remove_assoc key fields)))))
    ["spaceId",`Int 99;"label",str "p2";"targetId",str "";"openedBy",str "user";
     "method",str "DOM.setFileInputFiles";"returned",`Bool false];
  List.iter (fun invalid ->
    check bool "missing, duplicate, or invented state is not a native acknowledgement" true
      (Result.is_error (decode invalid)))
    [obj (List.remove_assoc "targetId" fields);obj (("spaceId",`Int 51)::fields);
     obj (("ready",`Bool true)::fields)]

let test_loading_recovery_preserves_original_input_hold () =
  let calls = ref 0 and original_calls = ref 0 in
  let peer = opened (fun sent -> match sent.step with
    | "tabs.list" -> answered tabs
    | "page.target_input" ->
      incr original_calls;
      check string "the original native input holds a drag" "drag_to" (text (field "action" sent.args));
      Error (Peer.Unobserved "original drag result lost")
    | "page.stop_loading" ->
      incr calls;
      check string "recovery stays on the original managed Page" "p1" (text (field "label" sent.args));
      answered (obj ["spaceId",`Int 51;"label",str "p1";"targetId",str "T1";
        "openedBy",str "agent";"method",str "Page.stopLoading";"returned",`Bool true])
    | other -> failf "recovery must not require an observation: %s" other) in
  ignore (dispatch peer Live.Tabs_list (obj []));
  let original = Peer.dispatch ~command_id:"original-lost-drag" peer ~verb:Live.Page_interact
    (interact_args (Lane.Drag_to {source=Lane.Selector "#source";destination=Lane.Selector "#destination";
      via=[];duration_ms=0})) in
  check string "the original holding input has an unknown outcome" "unknown" (failure_kind original);
  check int "the original holding input reached native exactly once" 1 !original_calls;
  let pending = Peer.input_status peer in
  check bool "fixture retains the original lost input generation" true
    (match pending with Masc.Browser_ego_input.Uncertain value -> value.command_id="original-lost-drag"
     | Ready _ -> false);
  let action tab_id = obj ["action",str "stop_loading";"tabId",`Int tab_id] in
  (match dispatch peer Live.Page_act (action 1) with
   | Ok receipt ->
     check string "native return is acknowledged" "Page.stopLoading" (text (field "method" receipt));
     check string "recovery does not release input" "release_uncertain" (text (field "inputReadiness" receipt));
     check bool "no URL or document readiness is invented" true
       (field "url" receipt=`Null && field "ready" receipt=`Null)
   | other -> failf "loading recovery did not run: %s" (failure_kind other));
  check bool "recovery leaves the pending generation unchanged" true (Peer.input_status peer=pending);
  List.iter (fun tab_id -> ignore (before_effect "foreign or unmanaged recovery"
      (dispatch peer Live.Page_act (action tab_id)))) [2;99];
  check int "only one native recovery call was sent" 1 !calls;
  check bool "URL and caller CDP arguments cannot enter recovery" true
    (List.for_all (fun (key,value) -> Result.is_error (Lane.Action.parse
      (obj ["action",str "stop_loading";"tabId",`Int 1;key,value])))
      ["expectedUrl",str "https://example.test/";"method",str "DOM.setFileInputFiles";
       "params",obj ["files",`List [str "/host/private"]]])

let () =
  run "browser_ego_peer" [
    "ego", [
      test_case "loading recovery requires the original native Page acknowledgement" `Quick test_loading_recovery_receipt_requires_original_page;
      test_case "loading recovery keeps exact Page authority and unknown input" `Quick test_loading_recovery_preserves_original_input_hold;
      test_case "popup workflow preserves Page routing and Space input uncertainty" `Quick test_popup_workflow_identity_and_scope;
      test_case "popup workflow binds the full pre-effect source and fails closed on changed identity" `Quick test_popup_workflow_source_binding;
      test_case "Space status reads native metadata without Page or control effects" `Quick test_native_space_status;
      test_case "a bound Space that did not open is looked up once, and nothing ran" `Quick test_a_space_that_did_not_open_is_looked_up_once;
      test_case "production workflow envelope preserves special JSON header keys" `Quick test_native_workflow_json_headers;
      test_case "first evaluation timeout preserves unknown native receipt" `Quick test_first_evaluation_timeout_preserves_unknown_native_receipt;
      test_case "native dialog errors retain progress and wire observation" `Quick test_native_dialog_error_keeps_progress_and_wire_observation;
      test_case "malformed native dialog errors stay unknown" `Quick test_malformed_native_dialog_error_stays_unknown;
      test_case "adopted managed Pages retain origin while using native actions" `Quick test_adopted_managed_page_uses_native_actions_without_changing_origin;
      test_case "takeover receipts and native runner preserve pending input" `Quick test_takeover_receipt_and_native_runner_preserve_pending_input;
      test_case "saved fetch survives snapshot failure and reaches the download broker" `Quick test_saved_fetch_survives_snapshot_failure_and_reaches_download_broker;
      test_case "unattestable raw inputs refuse before native resolution and preserve pending input" `Quick test_unattestable_raw_input_is_refused_before_effect;
      test_case "a malformed later raw workflow step prevents every earlier effect" `Quick test_invalid_workflow_is_refused_before_any_step;
      test_case "raw typing settles only its exact native window" `Quick test_raw_type_settles_only_its_exact_native_window;
      test_case "raw typing preserves pending for a lost reply or private failure" `Quick test_raw_type_lost_and_private_failures_remain_pending;
      test_case "raw typing retains only strict native diagnostics" `Quick test_raw_type_retains_only_strict_native_diagnostics;
      test_case "workflow raw context uses actual pending and safe public progress" `Quick test_workflow_raw_context_is_bound_to_its_actual_pending;
      test_case "target gestures settle only from their declared receipt" `Quick test_a_target_gesture_settles_only_from_the_receipt_it_returns;
      test_case "target dialog keeps release uncertain until a clean receipt" `Quick test_target_dialog_keeps_release_uncertain_until_a_clean_receipt;
      test_case "a gesture refused before its press keeps input" `Quick test_a_gesture_refused_before_its_press_keeps_input;
      test_case "every answer carries the input state" `Quick test_every_answer_carries_the_input_state;
      test_case "an ego viewport is a CDP override on its Page" `Quick test_viewport_is_a_cdp_override_on_the_page;
      test_case "ego location, locale and time zone are CDP overrides on its Page" `Quick test_emulation_is_a_cdp_override_on_the_page;
      test_case "ego request blocking is a CDP setting on its Page" `Quick test_request_blocking_is_a_cdp_setting_on_the_page;
      test_case "ego cookie writes go into the operator's ego profile" `Quick test_cookie_writes_go_into_the_ego_profile;
      test_case "ego storage names withhold every value" `Quick test_storage_names_withhold_every_value;
      test_case "ego network log rebuilds every row" `Quick test_network_log_rebuilds_every_row;
      test_case "one drain reads the ego event buffer" `Quick test_one_drain_reads_the_event_buffer;
      test_case "ego console read rebuilds every entry" `Quick test_console_read_rebuilds_every_entry;
      test_case "a dialog-interrupted workflow stays uncertain until a new click settles, without replay" `Quick test_dialog_interrupted_workflow_stays_uncertain_until_a_new_click_settles;
      test_case "native workflows retain input ownership after a lost result" `Quick test_native_workflow_pointer_ownership;
      test_case "a workflow that never held input keeps the previous readiness" `Quick test_a_workflow_that_never_held_input_keeps_the_previous_readiness;
      test_case "chooser upload runs after uncertain input release" `Quick test_chooser_upload_runs_after_uncertain_pointer_release;
      test_case "explicit completion is terminal and never replayed" `Quick test_explicit_completion_is_terminal_and_never_replayed;
      test_case "the space opens by name and is held by number" `Quick test_the_space_opens_by_name_and_is_held_by_number;
      test_case "the spaces of a name are listed without opening one" `Quick test_the_spaces_of_a_name_are_listed_without_opening_one;
      test_case "the listing script runs under node" `Quick test_the_listing_script_runs_under_node;
      test_case "numeric Space references never create replacements" `Quick test_exact_numeric_space_resume;
      test_case "Page provenance survives document projection" `Quick test_page_provenance_survives_document_projection;
      test_case "space inspection preserves user ownership and uncertain listings" `Quick test_space_name_inspection_is_read_only_and_requires_evidence;
      test_case "a claim reclaims only the Space that was asked for" `Quick test_a_claim_reclaims_only_the_space_that_was_asked_for;
      test_case "tabs are numbered by page label" `Quick test_tabs_are_numbered_by_label;
      test_case "tabs carry the window ego names" `Quick test_tabs_carry_the_window_ego_names;
      test_case "a tab that left the listing loses its number" `Quick test_a_tab_that_left_the_listing_loses_its_number;
      test_case "an ego error is cut" `Quick test_an_ego_error_is_cut;
      test_case "taps and swipes are CDP touch events on the page" `Quick test_touch_is_cdp_touch_on_the_page;
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
      test_case "SDK-timed navigation waits the command's reply window" `Quick test_sdk_timed_navigation_waits_the_reply_window;
      test_case "a snapshot reads ego's own tree" `Quick test_a_snapshot_reads_egos_own_tree;
      test_case "dialog inventory and answers do not require info" `Quick test_dialog_inventory_and_answers_do_not_require_info;
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
      test_case "the peer serves what the lane table says" `Quick test_the_peer_serves_what_the_lane_table_says ] ]
