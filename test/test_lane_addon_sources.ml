(** Source acquisition reuses owners and preserves measured bytes. *)
open Alcotest
module Sources = Masc.Lane_addon_sources
module Store = Masc.Lane_addon_store
module Types = Masc.Lane_addon_types
external unsetenv : string -> unit = "masc_test_unsetenv"
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
  model_access=Types.Model_disabled;
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
  let result = require (Sources.acquire ~access:Sources.Operator_configuration ~resolve_lane_output:(fun ~installation_id:_ -> Error "no configured upstream") ~store ~package:(package dir 16384)
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

let test_duplicate_snapshot_keys_cannot_replace_host_evidence () = with_store (fun dir store ->
  let path = Filename.concat dir "duplicate.json" in
  let forged = `List [`Assoc ["uri", `String "forged";
    "sha256", `String (String.make 64 'a')]] in
  let observation = `Assoc ["kind", `String "fusion_run";
    "evidence", `List []; "evidence", forged] in
  let duplicate_observation = envelope "deployment" [observation] in
  let duplicate_root = match envelope "deployment" [] with
    | `Assoc fields -> `Assoc (("observations", `List [observation]) :: fields)
    | _ -> assert false in
  List.iter (fun input ->
    write path (Yojson.Safe.to_string input);
    let source = require (Sources.acquire
      ~access:Sources.Operator_configuration
      ~resolve_lane_output:(fun ~installation_id:_ -> Error "no configured upstream")
      ~store ~package:(package dir 16384)
      ~binding:(binding [file_source "deployment" path])) |> list |> List.hd in
    check bool "ambiguous source remains incomplete" false
      (Yojson.Safe.Util.to_bool (member "complete" source));
    check int "ambiguous source cannot publish forged evidence" 0
      (List.length (list (member "observations" source)));
    check string "ambiguity is explicit" "snapshot contains duplicate object keys"
      (text (member "detail" source))) [duplicate_observation; duplicate_root])

let test_combined_ingress_marks_omitted_sources () = with_store (fun dir store ->
  let sources = List.init 2 (fun index ->
    let id = string_of_int index in
    let path = Filename.concat dir (id ^ ".json") in
    let value = envelope id [`Assoc ["id", `String id; "payload", `String (String.make 700 'x')]] in
    write path (Yojson.Safe.to_string value);
    file_source id path) in
  let cap = 2048 in
  let result = require (Sources.acquire ~access:Sources.Operator_configuration ~resolve_lane_output:(fun ~installation_id:_ -> Error "no configured upstream") ~store ~package:(package dir cap) ~binding:(binding sources)) in
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
    let read () = require (Sources.acquire ~access:Sources.Operator_configuration ~resolve_lane_output:(fun ~installation_id:_ -> Error "no configured upstream") ~store ~package:(package dir 16384)
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

let test_completed_port_refresh_identity_preserves_status_and_output () = with_store (fun dir store ->
  let binding = binding [`Assoc ["source_id",`String "upstream";"kind",`String "lane_output";
    "installation_id",`String "producer";"selection",`String "latest_completed"]] in
  let row : Types.row = {id="row";lane_id="owner/result";kind=Types.Value;title="Answer";
    observed_at=1.;subject_id="subject";clock=None;actor=None;fields=[];evidence=[];related_ids=[]} in
  let status : Types.coverage = {source_id="owner";incarnation="owner";cursor=Some "1";
    complete=true;detail=None} in
  let producer = ref ({installation_id="producer";instance_id="owner";run_id="run";
    configuration_revision="config-1";package_revision="package-1";outputs=[];
    observation_seq=1;output={rows=[row];coverage=[status]};status} : Sources.lane_output) in
  let interest = require (Sources.refresh_interest binding) in
  let acquire () = require (Sources.acquire ~access:Sources.Operator_configuration ~store ~package:(package dir 16384)
    ~resolve_lane_output:(fun ~installation_id:_ -> Ok !producer) ~binding) in
  let fingerprint value = require (Sources.refresh_fingerprint interest value) in
  let first = acquire () in
  let first_key = fingerprint first in
  check bool "completed ports have a stable automatic identity" true (Option.is_some first_key);
  let later = match first with
    | `List [`Assoc fields] -> `List [`Assoc (List.map (fun (key,value) ->
        if key="observations" then key,`List (List.map (function
          | `Assoc observation -> `Assoc (("observed_at",`Float 999.) :: List.remove_assoc "observed_at" observation)
          | _ -> fail "invalid acquired observation") (list value)) else key,value) fields)]
    | _ -> fail "invalid acquired source array" in
  check bool "a later host acquisition is the same input" true (fingerprint later=first_key);
  let changed label update =
    let original = !producer in producer := update original;
    check bool label false (fingerprint (acquire ())=first_key);
    producer := original in
  changed "new producer generation is different" (fun source -> {source with observation_seq=2});
  changed "replacement owner is different" (fun source -> {source with instance_id="replacement"});
  changed "mapping revision is different" (fun source -> {source with configuration_revision="config-2"});
  changed "worker failure is different even with retained rows" (fun source ->
    {source with status={status with complete=false;detail=Some "worker failed"}});
  changed "original output timestamps remain part of input" (fun source ->
    {source with output={source.output with rows=[{row with observed_at=2.}]}});
  let file_interest = require (Sources.refresh_interest (`Assoc ["sources",`List [file_source "file" "/fixture/input.json"]])) in
  check bool "file input timestamps are preserved" false
    (require (Sources.refresh_fingerprint file_interest first)=require (Sources.refresh_fingerprint file_interest later));
  let live_interest = require (Sources.refresh_interest (`Assoc ["sources",`List [`Assoc [
    "source_id",`String "screen";"kind",`String "msx_capture"]]])) in
  check bool "live capture cannot suppress notification by port identity" true
    (require (Sources.refresh_fingerprint live_interest first)=None))

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
  let read ?(complete=false) selector = require (Sources.acquire ~access:Sources.Operator_configuration ~store ~package:(package dir 16384)
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
      require (Sources.acquire ~access:Sources.Operator_configuration ~resolve_lane_output:(fun ~installation_id:_ -> Error "no upstream")
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
    ~saves_dir:(Filename.concat dir "saves") ~checkpoint_dir:(Filename.concat dir "checkpoints")
    ~program_name:"HELLO.COM" ~program_bytes:hello
    ~files:[] ~announce:ignore)) in
  load ();
  Fun.protect ~finally:(fun () -> ignore (Dos_lane.eject ~who:"keeper-A" ~announce:ignore ())) (fun () ->
    let capture () =
      require (Sources.acquire ~access:Sources.Operator_configuration ~resolve_lane_output:(fun ~installation_id:_ -> Error "no upstream")
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
    (Sources.interested msx (Sources.Machine_changed Masc.Machine_lane.Msx));
  let dos = interest [`Assoc ["source_id",`String "machine";"kind",`String "dos_capture"]] in
  check bool "DOS changes refresh the declared DOS source" true
    (Sources.interested dos (Sources.Machine_changed Masc.Machine_lane.Dos));
  check bool "and MSX changes do not" false (Sources.interested dos (Sources.Machine_changed Masc.Machine_lane.Msx));
  check bool "browser changes refresh only the declared browser source" true
    (Sources.interested browser Sources.Browser_changed);
  List.iter (fun activity ->
    check bool "producer output dependencies do not subscribe to tool completions" false
      (Sources.interested dependent activity);
    check bool "owned environment has no invented external source" false
      (Sources.interested (interest []) activity))
    [Sources.Tool_completed;Sources.Machine_changed Masc.Machine_lane.Msx;
     Sources.Machine_changed Masc.Machine_lane.Dos;Sources.Browser_changed];
  check bool "unrelated completion does not refresh browser capture" false
    (Sources.interested browser Sources.Tool_completed);
  check bool "browser completion does not refresh MSX capture" false
    (Sources.interested msx Sources.Browser_changed)

(* Each misc tool says which source it moves, beside the activity type rather
   than in the event bridge. A tool that moves nothing is a plain completion,
   and reads are not source changes. *)
let test_misc_tools_name_the_source_they_move () =
  let label = function
    | Sources.Machine_changed Masc.Machine_lane.Msx -> "msx"
    | Sources.Machine_changed Masc.Machine_lane.Dos -> "dos"
    | Sources.Browser_changed -> "browser"
    | Sources.Fusion_changed _ -> "fusion"
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
  check string "restoring a DOS checkpoint replaces the machine a watcher shows" "dos"
    (activity Tool_schemas_misc.Misc_dos_restore);
  check string "saving one moves nothing" "tool"
    (activity Tool_schemas_misc.Misc_dos_save);
  check string "interacting with a page moves its document" "browser"
    (activity Tool_schemas_misc.Misc_browser_interact);
  check string "listing tabs moves nothing" "tool"
    (activity Tool_schemas_misc.Misc_browser_tabs);
  check string "a stagehand sentence moves no source a lane addon observes" "tool"
    (activity Tool_schemas_misc.Misc_browser_instruct);
  check string "subscription reading and acknowledgement do not move an MSX or browser source" "tool"
    (activity Tool_schemas_misc.Misc_lane_updates);
  check string "a web search is a plain completion" "tool"
    (activity Tool_schemas_misc.Misc_web_search)

(* What a built-in lane offers a binding and what [parse] accepts come from one
   match, so a backend without an idle document observer is refused as a
   source and lists no source kind. *)
let test_built_in_lanes_offer_what_parse_accepts () =
  let offers builtin = List.map Sources.kind_to_string (Sources.offers builtin) in
  check (Alcotest.list string) "Stagehand offers no source" []
    (offers (Masc.Lane_id.Browser Browser_lane.Lane_name.Stagehand));
  check (Alcotest.list string) "automation offers its document" [ "browser_document" ]
    (offers (Masc.Lane_id.Browser Browser_lane.Lane_name.Automation));
  check (Alcotest.list string) "the live browser offers its document" [ "browser_document" ]
    (offers (Masc.Lane_id.Browser Browser_lane.Lane_name.Live));
  check (Alcotest.list string) "MSX offers its capture" [ "msx_capture" ]
    (offers (Masc.Lane_id.Machine Masc.Machine_lane.Msx));
  check (Alcotest.list string) "DOS offers its capture" [ "dos_capture" ]
    (offers (Masc.Lane_id.Machine Masc.Machine_lane.Dos));
  List.iter
    (fun lane ->
       check (Alcotest.list string) (Standalone_lane.to_id lane ^ " offers no source") []
         (offers (Masc.Lane_id.Exact lane)))
    Standalone_lane.all;
  let document lane =
    binding [`Assoc ["source_id",`String "page";"kind",`String "browser_document";
      "lane",`String (Browser_lane.Lane_name.to_wire lane);"tab_id",`Int 1;
      "target_id",`String "project";"environment",`String "preview";"request_id",`String "capture"]] in
  (match Sources.parse (document Browser_lane.Lane_name.Stagehand) with
   | Ok _ -> fail "a stagehand document source must be refused"
   | Error error ->
     check bool "the refusal names the stagehand lane" true
       (String.equal error "a lane addon cannot observe the stagehand lane: it has no idle document observer"));
  check bool "an automation document source is accepted" true
    (Result.is_ok (Sources.parse (document Browser_lane.Lane_name.Automation)))

let test_fusion_capture_retains_exact_state_across_terminal_change () =
  with_store (fun dir store ->
    let old_base = Sys.getenv_opt "MASC_BASE_PATH" in
    let reset () =
      Masc.Board_dispatch.reset_for_test ();
      Masc.Board.reset_global_for_test () in
    Fun.protect ~finally:(fun () ->
      reset ();
      match old_base with Some value -> Unix.putenv "MASC_BASE_PATH" value
      | None -> unsetenv "MASC_BASE_PATH")
      (fun () ->
        Unix.putenv "MASC_BASE_PATH" dir;
        reset ();
        let registry = Fusion_run_registry.create ~path:(Filename.concat dir "fusion-runs.jsonl") () in
        (match Fusion_run_registry.install_global registry with
         | Ok () -> () | Error _ -> fail "source fixture registry already installed");
        let run_id = "fusion-capture-" ^ Store.digest dir in
        Fusion_run_registry.register_running registry ~run_id
          ~keeper:"fixture" ~preset:"default" ~roster:Fusion_types.preset_roster
          ~topology:Fusion_types.Simple ~started_at:1.;
        let read () = require (Sources.acquire ~access:(Sources.Keeper "fixture") ~store ~package:(package dir 16384)
          ~resolve_lane_output:(fun ~installation_id:_ -> Error "unused")
          ~binding:(binding [`Assoc ["source_id",`String "fusion";
            "kind",`String "fusion_run";"run_id",`String run_id]]))
          |> list |> List.hd |> member "observations" |> list |> List.hd in
        List.iter (fun access ->
        let denied = require (Sources.acquire ~access
          ~store ~package:(package dir 16384)
          ~resolve_lane_output:(fun ~installation_id:_ -> Error "unused")
          ~binding:(binding [`Assoc ["source_id",`String "fusion";
            "kind",`String "fusion_run";"run_id",`String run_id]]))
          |> list |> List.hd in
        check bool "another Keeper cannot capture a Fusion run" false
          (member "complete" denied |> Yojson.Safe.Util.to_bool);
        check int "denied source exposes no run or Board evidence" 0
          (member "observations" denied |> list |> List.length))
          [Sources.Keeper "another-keeper"; Sources.Unauthenticated];
        let authorize run_id = Sources.authorize ~access:(Sources.Keeper "another-keeper")
          (binding [`Assoc ["source_id",`String "fusion";"kind",`String "fusion_run";
            "run_id",`String run_id]]) in
        check (result unit string) "foreign and unknown Fusion IDs have one denial"
          (authorize run_id) (authorize (run_id ^ "-missing"));
        let first = read () in
        let rejected_store = Store.create ~root:(Filename.concat dir "rejected-envelope") in
        let detail_bytes = String.length (Yojson.Safe.to_string (member "detail" first)) in
        check int "array serialization reserves exactly the detail plus brackets"
          (detail_bytes + String.length "[]")
          (String.length (Yojson.Safe.to_string (`List [member "detail" first])));
        let rejected = require (Sources.acquire ~access:(Sources.Keeper "fixture")
          ~store:rejected_store ~package:(package dir
            (String.length (Yojson.Safe.to_string (`List [member "detail" first]))))
          ~resolve_lane_output:(fun ~installation_id:_ -> Error "unused")
          ~binding:(binding [`Assoc ["source_id",`String "fusion";
            "kind",`String "fusion_run";"run_id",`String run_id]]))
          |> list |> List.hd in
        check bool "whole envelope that cannot fit remains incomplete" false
          (member "complete" rejected |> Yojson.Safe.Util.to_bool);
        check string "detail fits but its enclosing observation is refused"
          "Fusion observation exceeds the available source ingress envelope"
          (member "detail" rejected |> text);
        check bool "rejected envelope writes no orphan capture blob" false
          (Sys.file_exists (Filename.concat (Store.root rejected_store) "evidence"));
        let reference = member "evidence" first |> list |> List.hd |> own_reference in
        let frozen = require (Store.read_blob store reference) in
        check string "captures exact registered run" run_id
          (first |> member "detail" |> member "run" |> member "run_id" |> text);
        Fusion_run_registry.mark_completed registry ~run_id
          ~outcome:(Fusion_run_registry.Failed {reason="fixture failure";code="fixture"});
        let terminal = read () in
        check string "captures terminal failure" "failed"
          (terminal |> member "detail" |> member "run" |> member "status" |> text);
        for index = 1 to Fusion_run_registry.max_completed_retained do
          let newer = run_id ^ "/newer/" ^ string_of_int index in
          Fusion_run_registry.register_running registry ~run_id:newer ~keeper:"foreign"
            ~preset:"default" ~roster:Fusion_types.preset_roster ~topology:Fusion_types.Simple
            ~started_at:(float_of_int index +. 10.);
          Fusion_run_registry.mark_completed registry ~run_id:newer ~outcome:Fusion_run_registry.Succeeded
        done;
        check bool "delayed source target has left the recent cache" true
          (Option.is_none (Fusion_run_registry.get registry ~run_id));
        let delayed_terminal = read () in
        check string "delayed observer reads durable exact terminal failure" "failed"
          (delayed_terminal |> member "detail" |> member "run" |> member "status" |> text);
        check string "durable fallback retains original owner" "fixture"
          (delayed_terminal |> member "detail" |> member "run" |> member "keeper" |> text);
        check bool "eviction does not transfer access to a foreign Keeper" true
          (Result.is_error (authorize run_id));
        Fusion_run_registry.register_running registry ~run_id ~keeper:"replacement-owner"
          ~preset:"default" ~roster:Fusion_types.preset_roster ~topology:Fusion_types.Simple
          ~started_at:1000.;
        check bool "reused id denies former owner's retained source access" true
          (Result.is_error (Sources.authorize ~access:(Sources.Keeper "fixture")
            (binding [`Assoc ["source_id",`String "fusion";"kind",`String "fusion_run";
              "run_id",`String run_id]])));
        check string "old running capture is still frozen" frozen
          (require (Store.read_blob store reference));
        check bool "observed actor is not the requested Keeper" true
          (member "actor" terminal=`Null);
        List.iteri (fun index (producer,author) ->
          let reused_run = run_id ^ "/reused/" ^ string_of_int index in
          let origin : Masc.Board.post_origin = {turn_ref=None;source=Some "fusion";
            fusion_run_id=Some reused_run;fusion_producer=producer} in
          (match Masc.Board_dispatch.create_post_once_by_fusion_run_id
            ~fusion_run_id:reused_run ~author ~content:"private foreign transcript"
            ~meta_json:(`Assoc ["prompt",`String "private foreign prompt"])
            ~post_kind:Masc.Board.System_post ~visibility:Masc.Board.Unlisted ~ttl_hours:0 ~origin () with
           | Ok _ -> () | Error _ -> fail "fixture Board post creation failed");
          Fusion_run_registry.register_running registry ~run_id:reused_run
            ~keeper:"fixture" ~preset:"default" ~roster:Fusion_types.preset_roster
            ~topology:Fusion_types.Simple ~started_at:2.;
          let captured = require (Sources.acquire ~access:(Sources.Keeper "fixture")
            ~store ~package:(package dir 16384)
            ~resolve_lane_output:(fun ~installation_id:_ -> Error "unused")
            ~binding:(binding [`Assoc ["source_id",`String "fusion";
              "kind",`String "fusion_run";"run_id",`String reused_run]])) |> list |> List.hd in
          check bool "foreign Board provenance refuses host capture" false
            (member "complete" captured |> Yojson.Safe.Util.to_bool);
          check int "no foreign prompt or transcript crosses package boundary" 0
            (member "observations" captured |> list |> List.length))
          [Some "foreign", "fixture"; Some "fixture", "foreign"; None, "fixture"] ))

let test_fusion_binding_targets_only_exact_run () =
  let source run_id = `Assoc ["source_id",`String "fusion";
    "kind",`String "fusion_run";"run_id",`String run_id] in
  let interest = require (Sources.refresh_interest (binding [source "run-one"])) in
  check bool "exact update wakes this source" true
    (Sources.interested interest (Sources.Fusion_changed "run-one"));
  check bool "another run does not wake this source" false
    (Sources.interested interest (Sources.Fusion_changed "run-two"));
  check bool "tool completions do not wake Fusion" false
    (Sources.interested interest Sources.Tool_completed);
  let file_interest = require (Sources.refresh_interest (binding [`Assoc [
    "source_id",`String "file";"kind",`String "snapshot_file";
    "path",`String "/retained/snapshot.json"]])) in
  check bool "Fusion updates do not wake unrelated file watchers" false
    (Sources.interested file_interest (Sources.Fusion_changed "run-one"));
  check bool "generic tool activity still refreshes files" true
    (Sources.interested file_interest Sources.Tool_completed);
  let bad = `Assoc ["source_id",`String "fusion";"kind",`String "fusion_run";
    "run_id",`String "run-one";"path",`String "/guessed"] in
  check bool "unknown fields rejected" true
    (Result.is_error (Sources.parse (binding [bad])));
  check bool "unknown run is unavailable, not fabricated" true
    (with_store (fun dir store ->
       let sources = require (Sources.acquire ~access:Sources.Operator_configuration ~store ~package:(package dir 16384)
         ~resolve_lane_output:(fun ~installation_id:_ -> Error "unused")
         ~binding:(binding [source "definitely-unregistered-fusion-run"])) in
       match list sources with
       | [captured] -> member "complete" captured = `Bool false
           && member "observations" captured = `List []
       | _ -> false))

let test_fusion_envelope_overflow_does_not_retain_or_remove_blobs () =
  with_store (fun dir store ->
    let old_base = Sys.getenv_opt "MASC_BASE_PATH" in
    let reset () =
      Masc.Board_dispatch.reset_for_test ();
      Masc.Board.reset_global_for_test () in
    Fun.protect ~finally:(fun () ->
      reset ();
      match old_base with Some value -> Unix.putenv "MASC_BASE_PATH" value
      | None -> unsetenv "MASC_BASE_PATH")
      (fun () ->
        Unix.putenv "MASC_BASE_PATH" dir;
        reset ();
        let registry = Fusion_run_registry.global () in
        let run_id = "fusion-envelope-" ^ Store.digest dir in
        Fusion_run_registry.register_running registry ~run_id
          ~keeper:"fixture" ~preset:"default" ~roster:Fusion_types.preset_roster
          ~topology:Fusion_types.Simple ~started_at:1.;
        let change_reason marker = Fusion_run_registry.mark_completed registry ~run_id
          ~outcome:(Fusion_run_registry.Failed {reason=String.make 4096 marker;code="fixture"}) in
        change_reason 'a';
        let read cap = require (Sources.acquire ~access:(Sources.Keeper "fixture")
          ~store ~package:(package dir cap)

          ~resolve_lane_output:(fun ~installation_id:_ -> Error "unused")
          ~binding:(binding [`Assoc ["source_id",`String "fusion";
            "kind",`String "fusion_run";"run_id",`String run_id]])) in
        let admitted = read 16384 |> list |> List.hd in
        let observation = member "observations" admitted |> list |> List.hd in
        let reference = member "evidence" observation |> list |> List.hd |> own_reference in
        let frozen = require (Store.read_blob store reference) in
        check bool "preflight and persisted content addresses agree" true
          (Store.blob_reference frozen = reference);
        let inner_size = String.length frozen in
        let cap = inner_size + 2 in
        check bool "only full envelope exceeds the single source array capacity" true
          (String.length (Yojson.Safe.to_string admitted) + 2 > cap);
        let blob_names () = Sys.readdir (Filename.concat (Store.root store) "evidence")
          |> Array.to_list |> List.sort String.compare in
        let before = blob_names () in
        List.iter (fun marker ->
          (* Equal-sized changes guarantee distinct detail blobs without a clock
             sleep, even when all acquisitions occur in the same second. *)
          change_reason marker;
          let result = read cap in
          check bool "unavailable fallback still fits the complete ingress envelope" true
            (String.length (Yojson.Safe.to_string result) <= cap);
          let rejected = list result |> List.hd in
          check bool "an oversized source is explicitly unavailable" true
            (member "complete" rejected = `Bool false && member "observations" rejected = `List []);
          check string "inner detail fits but complete capture is refused before retention"
            "Fusion observation exceeds the available source ingress envelope"
            (member "detail" rejected |> text);
          check (Alcotest.list string) "rejected captures create no orphan blobs" before (blob_names ());
          check string "previous retained evidence remains readable" frozen
            (require (Store.read_blob store reference))) ['a';'b';'c']))

let () = run "Lane source provenance" ["acquisition", [
  test_case "completed input identity preserves output, mapping and failure" `Quick
    test_completed_port_refresh_identity_preserves_status_and_output;
  test_case "Fusion envelope overflow creates no orphan and preserves existing evidence" `Quick
    test_fusion_envelope_overflow_does_not_retain_or_remove_blobs;
  test_case "Fusion captures retain earlier state across terminal updates" `Quick
    test_fusion_capture_retains_exact_state_across_terminal_change;
  test_case "Fusion bindings target exact run updates and preserve unavailable coverage" `Quick
    test_fusion_binding_targets_only_exact_run;
  test_case "activity follows declared typed sources" `Quick test_source_activity_does_not_infer_ownership;
  test_case "native input ledger is captured and retained with frame identity" `Quick test_native_input_history_is_frozen_with_capture;
  test_case "DOS capture retains the machine's history" `Quick test_dos_capture_retains_the_machines_history;
  test_case "named ports select exact instance lanes and retain whole coverage" `Quick test_named_port_uses_exact_instance_and_keeps_coverage;
  test_case "file rotation keeps original bytes" `Quick test_file_rotation_keeps_exact_original_bytes;
  test_case "duplicate snapshot keys cannot replace retained evidence" `Quick test_duplicate_snapshot_keys_cannot_replace_host_evidence;
  test_case "combined ingress preserves incomplete coverage" `Quick test_combined_ingress_marks_omitted_sources;
  test_case "browser actual identity and unknown coverage" `Quick test_browser_identity_and_unknown_coverage;
  test_case "misc tools name the source they move" `Quick test_misc_tools_name_the_source_they_move;
  test_case "built-in lanes offer what parse accepts" `Quick test_built_in_lanes_offer_what_parse_accepts]]
