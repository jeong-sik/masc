(** Source acquisition reuses owners and preserves measured bytes. *)
open Alcotest
module Sources = Masc.Lane_addon_sources
module Store = Masc.Lane_addon_store
module Types = Masc.Lane_addon_types
let require = function Ok value -> value | Error error -> fail error
let member = Yojson.Safe.Util.member
let text json = Yojson.Safe.Util.to_string json
let list json = Yojson.Safe.Util.to_list json
let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path
let with_store f =
  let dir = Filename.temp_file "lane-sources-" ".fixture" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () ->
    Eio_main.run (fun env ->
      Time_compat.set_clock (Eio.Stdenv.clock env);
      f dir (Store.create ~root:(Filename.concat dir "retained"))))
let package dir max_bytes : Types.package = {
  id="source-test";revision="1";title="Source capture fixture";
  contributions=[Types.Observe];image="unused";command=["unused"];
  directory=dir;skills_directory=None;action_tool=None;outputs=[];refresh_policy=Types.Every_hint;
  binding_schema=None;presentation=Masc.Lane_addon_presentation.empty;
  resources={cpus=0.5;memory_bytes=134217728L;pids=16;max_reply_bytes=max_bytes}}
let file_source id path = `Assoc ["kind", `String "snapshot_file";
  "source_id", `String id; "path", `String path]
let binding sources = `Assoc ["sources", `List sources]
let envelope id observations = `Assoc ["source_id", `String id; "incarnation", `String "file-1";
  "cursor", `String "cursor-1"; "complete", `Bool true; "detail", `Null;
  "observations", `List observations]
let write path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)
let own_reference json : Types.evidence = {
  uri=text (member "uri" json);sha256=Some (text (member "sha256" json))}

let test_file_rotation_keeps_exact_original_bytes () = with_store (fun dir store ->
  let path = Filename.concat dir "source.json" in
  let external_uri = "file:///does-not-exist/never-open-this-from-a-source-reference" in
  let input = envelope "deployment" [`Assoc ["kind", `String "deployment";
    "evidence", `List [`Assoc ["uri", `String external_uri; "sha256", `Null]]]] in
  let bytes = "  \n" ^ Yojson.Safe.pretty_to_string input ^ "\n\n" in
  write path bytes;
  let result = require (Sources.acquire ~resolve_lane_output:(fun ~installation_id:_ -> Error "no configured upstream") ~store ~package:(package dir 16384)
    ~binding:(binding [file_source "deployment" path])) |> list |> List.hd in
  let reference = own_reference (member "snapshot_evidence" result) in
  check string "raw whitespace bytes retained" bytes (require (Store.read_blob store reference));
  let observation = member "observations" result |> list |> List.hd in
  let refs = member "evidence" observation |> list in
  check string "first evidence is the retained raw source" reference.uri (text (member "uri" (List.hd refs)));
  check string "declared URI remains a declaration" external_uri (text (member "uri" (List.nth refs 1)));
  write path "{\"source_id\":\"rotated\"}";
  Sys.remove path;
  check string "rotation and deletion do not remove evidence" bytes (require (Store.read_blob store reference));
  check string "retained SHA describes original bytes" (Store.digest bytes) (Option.get reference.sha256))

let test_combined_ingress_marks_omitted_sources () = with_store (fun dir store ->
  let sources = List.init 2 (fun index ->
    let id = string_of_int index in
    let path = Filename.concat dir (id ^ ".json") in
    let value = envelope id [`Assoc ["id", `String id; "payload", `String (String.make 700 'x')]] in
    write path (Yojson.Safe.to_string value);
    file_source id path) in
  let cap = 2048 in
  let result = require (Sources.acquire ~resolve_lane_output:(fun ~installation_id:_ -> Error "no configured upstream") ~store ~package:(package dir cap) ~binding:(binding sources)) in
  check bool "whole source array fits ingress envelope" true (String.length (Yojson.Safe.to_string result) <= cap);
  let rows = list result in
  check int "both source coverage entries survive" 2 (List.length rows);
  check bool "overflow is marked unavailable" true
    (List.exists (fun source -> member "complete" source = `Bool false) rows);
  check bool "capacity does not fabricate an empty complete source" true
    (List.for_all (fun source -> member "observations" source <> `List []
      || member "complete" source = `Bool false) rows))

let browser_source = `Assoc ["kind", `String "browser_document"; "source_id", `String "browser";
  "lane", `String "automation"; "tab_id", `Int 4; "target_id", `String "service";
  "environment", `String "production"; "request_id", `String "verify-1"]
let browser_payload ~tab ~complete ~html = `Assoc ["ok", `Bool true; "data", `Assoc [
  "clientId", `String "automation:actual-session"; "tabId", `Int tab;
  "documentId", `String "actual-document"; "url", `String "https://actual.example:8123/app?q=1";
  "observedAt", `Float 1000.; "html", html; "htmlComplete", `Bool complete;
  "htmlUnavailableReason", if complete then `Null else `String "document_html_exceeds_1_mib"]]

let test_browser_identity_and_unknown_coverage () = with_store (fun dir store ->
  let response = ref (browser_payload ~tab:4 ~complete:true ~html:(`String "<html>actual document</html>")) in
  Eio.Switch.run (fun sw ->
    let previous = Atomic.get Browser_lane.automation_document_observer in
    Browser_lane.install_automation_document_observer (Some (fun ~tab_id ->
      check int "explicit existing tab requested" 4 tab_id; Browser_lane.Answered !response));
    Eio.Switch.on_release sw (fun () -> Browser_lane.install_automation_document_observer previous);
    let read () = require (Sources.acquire ~resolve_lane_output:(fun ~installation_id:_ -> Error "no configured upstream") ~store ~package:(package dir 16384)
      ~binding:(binding [browser_source])) |> list |> List.hd in
    let source = read () in
    let observation = member "observations" source |> list |> List.hd in
    check string "returned client is preserved" "automation:actual-session" (text (member "client_id" observation));
    check string "tab uses package string representation" "4" (text (member "tab_id" observation));
    check string "actual URL preserved exactly" "https://actual.example:8123/app?q=1"
      (text (member "url" (member "target" observation)));
    check string "document identity preserved" "actual-document" (text (member "document_id" observation));
    let reference = member "evidence" observation |> list |> List.hd |> own_reference in
    check string "raw browser HTML preserved" "<html>actual document</html>"
      (require (Store.read_blob store reference) |> Yojson.Safe.from_string |> member "html" |> text);
    response := browser_payload ~tab:5 ~complete:true ~html:(`String "<html>other tab</html>");
    let wrong = read () in
    check bool "different actual tab produces incomplete source" true (member "complete" wrong = `Bool false);
    check int "different actual tab produces no fabricated observation" 0 (member "observations" wrong |> list |> List.length);
    response := browser_payload ~tab:4 ~complete:false ~html:`Null;
    let missing = read () in
    check bool "unknown document remains incomplete" true (member "complete" missing = `Bool false);
    check string "source's reason remains visible" "document_html_exceeds_1_mib" (text (member "detail" missing));
    let missing_observation = member "observations" missing |> list |> List.hd in
    check bool "missing document does not become content" true (member "html" missing_observation = `Null)))

let test_named_port_uses_exact_instance_and_keeps_coverage () = with_store (fun dir store ->
  let row id lane_id : Types.row = {id;lane_id;kind=Types.Value;title="Observed";
    observed_at=1.;subject_id="subject";clock=None;actor=None;fields=[];evidence=[];related_ids=[]} in
  let coverage : Types.coverage = {source_id="other-port";incarnation="history";
    cursor=Some "7";complete=false;detail=Some "another producer input is missing"} in
  let output : Types.output = {rows=[row "chosen" "owner/msx/frame";
    row "other-instance" "someone-else/msx/frame"; row "prefix" "owner/msx/frame/details";
    row "other-port" "owner/msx/state"];coverage=[coverage]} in
  let captured : Sources.lane_output = {installation_id="producer";instance_id="owner";
    run_id="run";configuration_revision="configuration";package_revision="package";
    outputs=["frames",Types.Selected_lanes ["msx/frame"];"empty",Types.Selected_lanes ["absent"];
      "all",Types.All_lanes];observation_seq=7;output;status={coverage with complete=true;detail=None}} in
  let read ?(complete=false) selector = require (Sources.acquire ~store ~package:(package dir 16384)
    ~resolve_lane_output:(fun ~installation_id ->
      check string "stable declaration requested" "producer" installation_id;
      Ok {captured with output={output with coverage=[{coverage with complete}]}})
    ~binding:(binding [`Assoc (["source_id",`String "upstream";"kind",`String "lane_output";
      "installation_id",`String "producer";"selection",`String "latest_completed"] @ selector)])) |> list |> List.hd in
  let selected = read ["output_id",`String "frames"] in
  let observed = member "observations" selected |> list |> List.hd in
  check (Alcotest.list string) "exact owner and local lane only" ["chosen"]
    (member "output" observed |> member "rows" |> list |> List.map (fun row -> text (member "id" row)));
  check bool "unselected port's incomplete coverage remains explicit" true
    (member "complete" selected = `Bool false);
  check string "port identity retained beside producer coordinates" "frames"
    (member "producer" observed |> member "output_id" |> text);
  check string "raw observation identity is unchanged" "owner/output/7" (member "id" observed |> text);
  check bool "whole producer coverage survives row selection" true
    ((member "output" observed |> member "coverage") = `List [Types.coverage_to_json coverage]);
  let reference = member "evidence" observed |> list |> List.hd |> own_reference in
  let frozen = require (Store.read_blob store reference) |> Yojson.Safe.from_string in
  check bool "frozen bytes describe the selection and exactly the delivered rows" true
    (member "producer" frozen = member "producer" observed && member "output" frozen = member "output" observed);
  let empty = read ~complete:true ["output_id",`String "empty"] in
  check bool "a complete known empty selection remains complete" true (member "complete" empty = `Bool true);
  check int "known port with no matching rows still has a completed observation" 1
    (member "observations" empty |> list |> List.length);
  check int "known empty selection returns no fabricated row" 0
    (member "observations" empty |> list |> List.hd |> member "output" |> member "rows" |> list |> List.length);
  let unknown = read ["output_id",`String "typo"] in
  check bool "missing named port never becomes whole output" true
    (member "complete" unknown = `Bool false && member "observations" unknown = `List []);
  List.iter (fun selector ->
    let observed = read selector |> member "observations" |> list |> List.hd in
    check int "explicit all-lanes and omitted selector retain whole output" 4
      (member "output" observed |> member "rows" |> list |> List.length))
    [[];["output_id",`String "all"]])

let test_native_input_history_is_frozen_with_capture () = with_store (fun dir store ->
  let msx = function Ok value -> value | Error error -> fail (Msx_lane.error_to_string error) in
  let ledger_dir = Filename.concat dir "machine" in
  ignore (msx (Msx_lane.load ~ledger_dir ~roms_dir:None ~cart_path:None ~disk_path:None));
  Fun.protect ~finally:(fun () -> ignore (Msx_lane.eject ())) (fun () ->
    let capture () =
      require (Sources.acquire ~resolve_lane_output:(fun ~installation_id:_ -> Error "no upstream")
        ~store ~package:(package dir 16384)
        ~binding:(binding [`Assoc ["kind",`String "msx_capture";"source_id",`String "native"]]))
      |> list |> List.hd |> member "observations" |> list |> List.hd in
    let reference observation = member "input_ledger" observation |> member "evidence" |> own_reference in
    let empty = capture () in
    check string "empty native ledger is observed, not missing" ""
      (require (Store.read_jsonl store (reference empty)));
    let press who name =
      let key = Msx_lane.key_of_string name |> require in
      ignore (msx (Msx_lane.press ~who ~keys:[key] ~hold_frames:1 ~step_frames:2 ~sequence:false)) in
    press "keeper-A" "space";
    press "keeper-B" "up";
    let before = msx (Msx_lane.capture_with_identity ()) in
    let observed = capture () in
    let after = msx (Msx_lane.capture_with_identity ()) in
    check int "source capture does not step" before.frame.number after.frame.number;
    check string "same captured machine history" before.incarnation (member "incarnation" observed |> text);
    check string "input cursor includes actual edges" "4" (member "input_cursor" observed |> text);
    check int "snapshot count matches native cursor" 4
      (member "entry_count" (member "input_ledger" observed) |> Yojson.Safe.Util.to_int);
    let expected = List.rev before.input_ledger
      |> List.map (fun entry -> Yojson.Safe.to_string (Msx_lane.entry_json entry) ^ "\n") |> String.concat "" in
    let ref = reference observed in
    check string "native frame/who/key/edge records survive" expected (require (Store.read_jsonl store ref));
    check string "snapshot equals native ledger file while controller is paused" expected
      (In_channel.with_open_bin (Filename.concat ledger_dir "ledger.jsonl") In_channel.input_all);
    check (Alcotest.list string) "actual callers preserved, not capture actor" ["keeper-A";"keeper-A";"keeper-B";"keeper-B"]
      (List.map (fun (entry : Msx_lane.entry) -> entry.who) (List.rev before.input_ledger));
    let checkpoint = Filename.concat dir "saved.json" in
    ignore (msx (Msx_lane.save ~path:checkpoint));
    press "keeper-C" "return";
    let future = capture () in
    check string "future input has a separate cursor" "6" (member "input_cursor" future |> text);
    check string "later input never rewrites retained evidence" expected (require (Store.read_jsonl store ref));
    ignore (msx (Msx_lane.restore ~path:checkpoint ~ledger_dir));
    let restored = capture () in
    check bool "restore has a new epoch" false (member "incarnation" restored = member "incarnation" observed);
    check string "restored snapshot includes saved history, not future input" expected
      (require (Store.read_jsonl store (reference restored)));
    ignore (msx (Msx_lane.eject ()));
    check string "machine removal preserves input evidence" expected (require (Store.read_jsonl store ref))))

(* The DOS machine as a source: frame, identity and input history read
   together, the ledger retained exactly as the machine wrote it, and a new
   load a new identity. The COM prints HI and loops on INT 16h. *)
let test_dos_capture_retains_the_machines_history () = with_store (fun dir store ->
  let dos = function Ok value -> value | Error error -> fail (Dos_lane.error_to_string error) in
  let hello = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$" in
  let ledger_dir = Filename.concat dir "dos" in
  let load () = ignore (dos (Dos_lane.load ~who:"keeper-A" ~ledger_dir
    ~saves_dir:(Filename.concat dir "saves") ~program_name:"HELLO.COM" ~program_bytes:hello
    ~files:[] ~mouse:false ~announce:ignore)) in
  load ();
  Fun.protect ~finally:(fun () -> ignore (Dos_lane.eject ~who:"keeper-A" ~announce:ignore ())) (fun () ->
    let capture () =
      require (Sources.acquire ~resolve_lane_output:(fun ~installation_id:_ -> Error "no upstream")
        ~store ~package:(package dir 2_000_000)
        ~binding:(binding [`Assoc ["kind",`String "dos_capture";"source_id",`String "dos"]]))
      |> list |> List.hd |> member "observations" |> list |> List.hd in
    let reference observation = member "input_ledger" observation |> member "evidence" |> own_reference in
    ignore (dos (Dos_lane.press ~who:"keeper-A" ~keys:["x"] ~steps:100_000));
    let before = dos (Dos_lane.capture_with_identity ()) in
    let observed = capture () in
    let after = dos (Dos_lane.capture_with_identity ()) in
    check int "capture does not step" before.observation.steps after.observation.steps;
    check string "same machine identity" before.incarnation (member "incarnation" observed |> text);
    check string "the input cursor counts the key" "1" (member "input_cursor" observed |> text);
    check string "the holder rides along" "keeper-A" (member "controller" observed |> text);
    let expected = Yojson.Safe.to_string (Dos_lane.entry_json (List.hd before.input_ledger)) ^ "\n" in
    check string "retained ledger equals the machine's file" expected
      (In_channel.with_open_bin (Filename.concat ledger_dir "ledger.jsonl") In_channel.input_all);
    check string "and the retained copy" expected (require (Store.read_jsonl store (reference observed)));
    ignore (dos (Dos_lane.eject ~who:"keeper-A" ~announce:ignore ()));
    load ();
    check bool "a new load is a new identity" false
      (member "incarnation" (capture ()) = member "incarnation" observed);
    check string "the old evidence stays" expected (require (Store.read_jsonl store (reference observed)))))

let test_source_activity_does_not_infer_ownership () =
  let interest sources = Sources.refresh_interest (binding sources) |> require in
  let msx = interest [`Assoc ["source_id",`String "screen";"kind",`String "msx_capture"]] in
  let browser = interest [`Assoc ["source_id",`String "page";"kind",`String "browser_document";
    "lane",`String "automation";"tab_id",`Int 1;"target_id",`String "project";
    "environment",`String "preview";"request_id",`String "capture"]] in
  let dependent = interest [`Assoc ["source_id",`String "metric";"kind",`String "lane_output";
    "installation_id",`String "producer";"selection",`String "latest_completed"]] in
  check bool "MSX changes refresh only the declared native MSX source" true
    (Sources.interested msx Sources.Msx_changed);
  let dos = interest [`Assoc ["source_id",`String "machine";"kind",`String "dos_capture"]] in
  check bool "DOS changes refresh the declared DOS source" true
    (Sources.interested dos Sources.Dos_changed);
  check bool "and MSX changes do not" false (Sources.interested dos Sources.Msx_changed);
  check bool "browser changes refresh only the declared browser source" true
    (Sources.interested browser Sources.Browser_changed);
  List.iter (fun activity ->
    check bool "producer output dependencies do not subscribe to tool completions" false
      (Sources.interested dependent activity);
    check bool "owned environment has no invented external source" false
      (Sources.interested (interest []) activity))
    [Sources.Tool_completed;Sources.Msx_changed;Sources.Dos_changed;Sources.Browser_changed];
  check bool "unrelated completion does not refresh browser capture" false
    (Sources.interested browser Sources.Tool_completed);
  check bool "browser completion does not refresh MSX capture" false
    (Sources.interested msx Sources.Browser_changed)

(* Each misc tool says which source it moves, beside the activity type rather
   than in the event bridge. A tool that moves nothing is a plain completion,
   and reads are not source changes. *)
let test_misc_tools_name_the_source_they_move () =
  let label = function
    | Sources.Msx_changed -> "msx"
    | Sources.Dos_changed -> "dos"
    | Sources.Browser_changed -> "browser"
    | Sources.Tool_completed -> "tool" in
  let activity operation = label (Sources.activity_of_misc_operation operation) in
  check string "stepping the MSX moves its capture" "msx"
    (activity Tool_schemas_misc.Misc_msx_step);
  check string "reading the MSX screen moves nothing" "tool"
    (activity Tool_schemas_misc.Misc_msx_screen);
  check string "pressing on the DOS machine moves its capture" "dos"
    (activity Tool_schemas_misc.Misc_dos_press);
  check string "reading the DOS screen moves nothing" "tool"
    (activity Tool_schemas_misc.Misc_dos_screen);
  check string "handing the DOS controller on refreshes the capture that shows the holder" "dos"
    (activity Tool_schemas_misc.Misc_dos_pass);
  check string "interacting with a page moves its document" "browser"
    (activity Tool_schemas_misc.Misc_browser_interact);
  check string "listing tabs moves nothing" "tool"
    (activity Tool_schemas_misc.Misc_browser_tabs);
  check string "subscription reading and acknowledgement do not move an MSX or browser source" "tool"
    (activity Tool_schemas_misc.Misc_lane_updates);
  check string "a web search is a plain completion" "tool"
    (activity Tool_schemas_misc.Misc_web_search)

module Live = Masc.Lane_addon_live

let kind_names = ["snapshot_file"; "msx_capture"; "dos_capture"; "lane_output"; "browser_document"]

let test_only_machine_kinds_have_a_live_screen () =
  let reader name = match Sources.kind_of_string name with
    | None -> fail ("kind name does not parse: " ^ name)
    | Some kind -> (match Sources.live_screen_of_kind kind with
        | Some Sources.Msx_screen -> "msx" | Some Sources.Dos_screen -> "dos" | None -> "none") in
  check (Alcotest.list (pair string string)) "only msx_capture and dos_capture show a screen"
    ["snapshot_file","none";"msx_capture","msx";"dos_capture","dos";"lane_output","none";
     "browser_document","none"]
    (List.map (fun name -> name, reader name) kind_names);
  check bool "an unknown kind is refused" true (Result.is_error (Live.reader_of_kind "vic20_capture"));
  List.iter (fun name -> check bool ("screenless " ^ name ^ " is refused") true
      (Result.is_error (Live.reader_of_kind name)))
    ["snapshot_file"; "lane_output"; "browser_document"]

let test_live_capture_runs_on_a_system_thread () = Eio_main.run (fun _env ->
  let fiber_thread = Thread.id (Thread.self ()) in
  let seen = ref fiber_thread in
  let capture (_ : Sources.live_reader) ~since:_ =
    seen := Thread.id (Thread.self ()); Ok Live.Not_loaded in
  let body = require (Result.map_error Live.error_to_string
    (Live.read ~reader:Sources.Dos_screen ~since:None ~capture:(Live.on_systhread capture))) in
  check bool "the machine reader ran off the request thread" true (!seen <> fiber_thread);
  check string "no machine is an explicit answer" {|{"loaded":false}|} (Yojson.Safe.to_string body))

(* Every file below [root] with its size: what a write of any kind, blob,
   observation or ledger, would change. *)
let rec tree_sizes root =
  if Sys.is_directory root then
    Sys.readdir root |> Array.to_list |> List.sort String.compare
    |> List.concat_map (fun name -> tree_sizes (Filename.concat root name))
  else [root, (Unix.stat root).Unix.st_size]

let dos = function Ok value -> value | Error error -> fail (Dos_lane.error_to_string error)
let dos_counter () = match Dos_lane.loaded_changes () with
  | Some counter -> counter | None -> fail "no DOS machine loaded"
let load_dos dir name bytes = Dos_lane.load ~who:"keeper-A" ~ledger_dir:(Filename.concat dir "dos")
  ~saves_dir:(Filename.concat dir "saves") ~program_name:name ~program_bytes:bytes
  ~files:[] ~mouse:false ~announce:ignore
(* The DOS machine is process-global: every live DOS test starts from none and
   ejects in [finally], whatever ran before. An eject's result only says
   whether one was loaded. *)
let with_no_dos f =
  ignore (Dos_lane.eject ~who:"keeper-A" ~announce:ignore ());
  Fun.protect ~finally:(fun () -> ignore (Dos_lane.eject ~who:"keeper-A" ~announce:ignore ())) f
let live_dos ?since () = Live.read ~reader:Sources.Dos_screen ~since ~capture:Live.default_capture
  |> Result.map_error Live.error_to_string |> require

(* The HI program from the DOS capture test, read through the route's own
   capture. A live read shows the frame, its step count and the counter, moves
   nothing, and writes nothing next to a store an observation filled. *)
let test_live_reads_a_real_dos_machine () = with_store (fun dir store -> with_no_dos (fun () ->
  let hello = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$" in
  check string "nothing loaded is not an empty picture" {|{"loaded":false}|}
    (Yojson.Safe.to_string (live_dos ~since:0 ()));
  (* A failed load fails the test through [dos]; the load report is not checked. *)
  ignore (dos (load_dos dir "HELLO.COM" hello));
  (* An observation fills the store, so an untouched store is not an empty one. *)
  ignore (require (Sources.acquire ~resolve_lane_output:(fun ~installation_id:_ -> Error "no upstream")
    ~store ~package:(package dir 2_000_000)
    ~binding:(binding [`Assoc ["kind",`String "dos_capture";"source_id",`String "dos"]])));
  let files_before = tree_sizes dir in
  let before = dos (Dos_lane.capture_with_identity ()) in
  let body = live_dos () in
  let after = dos (Dos_lane.capture_with_identity ()) in
  let field key = member key body |> Yojson.Safe.Util.to_int in
  let pixels = Base64.decode_exn (member "rgb_base64" body |> text) in
  check bool "loaded and changed" true (member "loaded" body = `Bool true && member "changed" body = `Bool true);
  check string "capture format" "rgb8" (member "format" body |> text);
  check int "width" before.frame.width (field "width");
  check int "height" before.frame.height (field "height");
  check bool "the picture is the machine's frame" true (String.equal before.frame.rgb pixels);
  check int "the step count of that picture" before.observation.steps (field "steps");
  check bool "DOS time is steps, not frames" true (member "frame" body = `Null);
  check int "the counter of that picture" before.changes (field "counter");
  check string "the machine incarnation" before.incarnation (member "incarnation" body |> text);
  check int "a live read does not tick" before.observation.steps after.observation.steps;
  check int "nor move the counter" before.changes after.changes;
  let same = live_dos ~since:before.changes () in
  check string "the same counter is only 'unchanged'"
    (Printf.sprintf {|{"changed":false,"counter":%d}|} before.changes) (Yojson.Safe.to_string same);
  check (Alcotest.list (pair string int)) "live reads wrote no byte to the store or the machine's files"
    files_before (tree_sizes dir);
  (* A failed press fails the test through [dos]; its report is not checked. *)
  ignore (dos (Dos_lane.press ~who:"keeper-A" ~keys:["x"] ~steps:100_000));
  check bool "a key moves the counter" true (dos_counter () > before.changes);
  check bool "and the old counter now gets a picture" true
    (member "changed" (live_dos ~since:before.changes ()) = `Bool true)))

(* From #38715's fault test: paint X at B800:0000, then [lea ax,ax], which the
   core does not implement. The load and every later run end in a fault, and
   each one still moves the counter. *)
let test_a_run_that_faults_moves_the_counter () = with_store (fun dir _store -> with_no_dos (fun () ->
  let paint_then_fault = "\xb8\x00\xb8\x8e\xc0\x26\xc6\x06\x00\x00\x58\x8d\xc0" in
  let faulted what = function
    | Error (Dos_lane.Guest_fault _) -> ()
    | Error other -> fail (what ^ " failed another way: " ^ Dos_lane.error_to_string other)
    | Ok _ -> fail (what ^ " did not fault") in
  (* The eject in [with_no_dos] left no machine; read the counter off a
     throwaway load so the faulting load has a known count to beat. *)
  ignore (dos (load_dos dir "HELLO.COM" "\xb4\x00\xcd\x16\xeb\xfa"));
  let before = dos_counter () in
  faulted "the load" (load_dos dir "FAULT.COM" paint_then_fault);
  let after_load = dos_counter () in
  check bool "a load that faults moves the counter" true (after_load > before);
  check bool "and a watcher holding the old counter gets the picture" true
    (member "changed" (live_dos ~since:before ()) = `Bool true);
  (* Whether the stopped guest faults again or runs on, the step ran. *)
  (match Dos_lane.step ~who:"keeper-A" ~steps:1000 ~until_ready:false with
   | Ok _ | Error (Dos_lane.Guest_fault _) -> ()
   | Error other -> fail ("the step was refused: " ^ Dos_lane.error_to_string other));
  check bool "a step after the fault moves it again" true (dos_counter () > after_load);
  (* A refusal ran nothing: another caller is held off before the guest runs. *)
  let held = dos_counter () in
  (match Dos_lane.step ~who:"keeper-B" ~steps:1000 ~until_ready:false with
   | Error (Dos_lane.Held_by _) -> ()
   | Error other -> fail ("expected Held_by, got " ^ Dos_lane.error_to_string other)
   | Ok _ -> fail "a second caller moved a held machine");
  check int "a refused call leaves the counter" held (dos_counter ())))

let msx = function Ok value -> value | Error error -> fail (Msx_lane.error_to_string error)
let msx_counter () = match Msx_lane.loaded_changes () with
  | Some counter -> counter | None -> fail "no MSX machine loaded"

(* Every MSX change passes [advance] or [install]: a step, a press, a restore
   and a load each move the counter; a capture and a save do not. *)
let test_msx_changes_move_the_counter () = with_store (fun dir _store ->
  let ledger_dir = Filename.concat dir "msx" in
  (* A failed load fails the test through [msx]; the load report is not checked. *)
  ignore (msx (Msx_lane.load ~ledger_dir ~roms_dir:None ~cart_path:None ~disk_path:None));
  (* Cleanup must run even when a check fails; its result is irrelevant then. *)
  Fun.protect ~finally:(fun () -> ignore (Msx_lane.eject ())) (fun () ->
    let rises what before = check bool (what ^ " moves the counter") true (msx_counter () > before) in
    let loaded = msx_counter () in
    let checkpoint = Filename.concat dir "saved.json" in
    (* The save is checked by the restore below; its report is not. *)
    ignore (msx (Msx_lane.save ~path:checkpoint));
    ignore (msx (Msx_lane.capture_with_identity ()));
    check int "a save and a capture leave it" loaded (msx_counter ());
    let body = Live.read ~reader:Sources.Msx_screen ~since:(Some loaded) ~capture:Live.default_capture
      |> Result.map_error Live.error_to_string |> require in
    check string "so a watcher at that counter hears 'unchanged'"
      (Printf.sprintf {|{"changed":false,"counter":%d}|} loaded) (Yojson.Safe.to_string body);
    ignore (msx (Msx_lane.step ~frames:1));
    rises "a step" loaded;
    let stepped = msx_counter () in
    let key = Msx_lane.key_of_string "space" |> require in
    ignore (msx (Msx_lane.press ~who:"keeper-A" ~keys:[key] ~hold_frames:1 ~step_frames:2 ~sequence:false));
    rises "a press" stepped;
    let pressed = msx_counter () in
    ignore (msx (Msx_lane.restore ~path:checkpoint ~ledger_dir));
    rises "a restore" pressed;
    let restored = msx_counter () in
    let body = Live.read ~reader:Sources.Msx_screen ~since:(Some loaded) ~capture:Live.default_capture
      |> Result.map_error Live.error_to_string |> require in
    check int "a restored machine answers a picture at the new counter" restored
      (member "counter" body |> Yojson.Safe.Util.to_int);
    check bool "with MSX time as a frame number" true (member "frame" body <> `Null);
    ignore (msx (Msx_lane.load ~ledger_dir ~roms_dir:None ~cart_path:None ~disk_path:None));
    rises "a new load" restored))

let () = run "Lane source provenance" ["acquisition", [
  test_case "activity follows declared typed sources" `Quick test_source_activity_does_not_infer_ownership;
  test_case "native input ledger is captured and retained with frame identity" `Quick test_native_input_history_is_frozen_with_capture;
  test_case "DOS capture retains the machine's history" `Quick test_dos_capture_retains_the_machines_history;
  test_case "named ports select exact instance lanes and retain whole coverage" `Quick test_named_port_uses_exact_instance_and_keeps_coverage;
  test_case "file rotation keeps original bytes" `Quick test_file_rotation_keeps_exact_original_bytes;
  test_case "combined ingress preserves incomplete coverage" `Quick test_combined_ingress_marks_omitted_sources;
  test_case "browser actual identity and unknown coverage" `Quick test_browser_identity_and_unknown_coverage;
  test_case "misc tools name the source they move" `Quick test_misc_tools_name_the_source_they_move];
  "live screen", [
  test_case "only machine kinds have a live screen" `Quick test_only_machine_kinds_have_a_live_screen;
  test_case "the capture runs on a system thread" `Quick test_live_capture_runs_on_a_system_thread;
  test_case "a real DOS machine answers its frame, steps and counter" `Quick test_live_reads_a_real_dos_machine;
  test_case "a run that faults moves the counter" `Quick test_a_run_that_faults_moves_the_counter;
  test_case "MSX changes move the counter" `Quick test_msx_changes_move_the_counter]]
