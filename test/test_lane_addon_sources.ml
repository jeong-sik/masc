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
  directory=dir;skills_directory=None;action_tool=None;outputs=[];
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
  ignore (msx (Msx_lane.load ~ledger_dir ~roms_dir:"" ~cart_path:None ~disk_path:None));
  Fun.protect ~finally:(fun () -> ignore (Msx_lane.eject ())) (fun () ->
    let capture () =
      require (Sources.acquire ~resolve_lane_output:(fun ~installation_id:_ -> Error "no upstream")
        ~store ~package:(package dir 16384)
        ~binding:(binding [`Assoc ["kind",`String "msx_capture";"source_id",`String "native"]]))
      |> list |> List.hd |> member "observations" |> list |> List.hd in
    let reference observation = member "input_ledger" observation |> member "evidence" |> own_reference in
    let empty = capture () in
    check string "empty native ledger is observed, not missing" ""
      (require (Store.read_blob store (reference empty)));
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
    let expected = before.input_ledger
      |> List.map (fun entry -> Yojson.Safe.to_string (Msx_lane.entry_json entry) ^ "\n") |> String.concat "" in
    let ref = reference observed in
    check string "native frame/who/key/edge records survive" expected (require (Store.read_blob store ref));
    check string "snapshot equals native ledger file while controller is paused" expected
      (In_channel.with_open_bin (Filename.concat ledger_dir "ledger.jsonl") In_channel.input_all);
    check (Alcotest.list string) "actual callers preserved, not capture actor" ["keeper-A";"keeper-A";"keeper-B";"keeper-B"]
      (List.map (fun (entry : Msx_lane.entry) -> entry.who) before.input_ledger);
    let checkpoint = Filename.concat dir "saved.json" in
    ignore (msx (Msx_lane.save ~path:checkpoint));
    press "keeper-C" "return";
    let future = capture () in
    check string "future input has a separate cursor" "6" (member "input_cursor" future |> text);
    check string "later input never rewrites retained evidence" expected (require (Store.read_blob store ref));
    ignore (msx (Msx_lane.restore ~path:checkpoint ~ledger_dir));
    let restored = capture () in
    check bool "restore has a new epoch" false (member "incarnation" restored = member "incarnation" observed);
    check string "restored snapshot includes saved history, not future input" expected
      (require (Store.read_blob store (reference restored)));
    ignore (msx (Msx_lane.eject ()));
    check string "machine removal preserves input evidence" expected (require (Store.read_blob store ref))))

let () = run "Lane source provenance" ["acquisition", [
  test_case "native input ledger is captured and retained with frame identity" `Quick test_native_input_history_is_frozen_with_capture;
  test_case "named ports select exact instance lanes and retain whole coverage" `Quick test_named_port_uses_exact_instance_and_keeps_coverage;
  test_case "file rotation keeps original bytes" `Quick test_file_rotation_keeps_exact_original_bytes;
  test_case "combined ingress preserves incomplete coverage" `Quick test_combined_ingress_marks_omitted_sources;
  test_case "browser actual identity and unknown coverage" `Quick test_browser_identity_and_unknown_coverage]]
