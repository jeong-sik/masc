open Masc
module Decode = Tui_decode_lane_inventory
module Display = Masc_tui_lane_inventory
let str value = `String value
let strings values = `List (List.map str values)
let object_ fields = `Assoc fields
let set name value = function
  | `Assoc fields -> `Assoc ((name,value) :: List.remove_assoc name fields)
  | _ -> Alcotest.fail "fixture is not an object"
let get name = function `Assoc fields -> List.assoc name fields | _ -> Alcotest.fail "fixture is not an object"
let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let rejects name value = Alcotest.(check bool) name true (Result.is_error (Decode.decode value))
let configuration = object_ ["kind",str "configured";"admitted_slots",strings ["account.model"];
  "cli_slots",strings [];"declared_slots",strings ["account.model"];
  "declared_cli_slots",strings [];"dropped_slots",strings [];"admission_error",`Null]
let exact_lane lane =
  let id = Standalone_lane.to_id lane in
  object_ (["lane_id",str id;"label",str id;"purpose",str "fixture purpose";
    "required",`Bool (Standalone_lane.obligation lane=Required);"observation_only",`Bool true;
    "configured",`Bool true;"configuration_state",str "ready";"admitted_slots",strings ["account.model"];
    "cli_slots",strings [];"declared_slots",strings ["account.model"];"declared_cli_slots",strings [];
    "dropped_slots",strings [];"admission_error",`Null;"status",str "no_retained_observation";
    "retained_run_count",`Int 0;"running_count",`Int 0;"succeeded_count",`Int 0;"failed_count",`Int 0;
    "cancelled_count",`Int 0;"last_started_at",`Null;"last_terminal_at",`Null;"last_outcome",`Null;
    "p50_elapsed_s",`Null;"selected_slots",`List [];"runs_without_slot",object_ ["vendor_system_one",`Int 0;"server_restarted",`Int 0;"no_slot",`Int 0]]
    @ (match lane with Standalone_lane.Board_attention -> ["jev",object_ ["state",str "off"]] | _ -> []))
let exact_snapshot = object_ ["schema",str "masc.standalone_llm_lanes.v2";
  "generated_at",str "2026-10-04T00:00:00Z";"observed_at_unix",`Float 12.;"observation_only",`Bool true;
  "exact_run_projection_count",`Int 0;"exact_run_source_total",`Int 0;"exact_run_projection_truncated",`Bool false;
  "lanes",`List (List.map exact_lane Standalone_lane.all)]
let row id selection state = object_ ["id",str id;"label",str id;"purpose",str "fixture purpose";"selection",selection;"state",state]
let builtin_rows = Lane_id.all_of_builtin |> List.map (fun lane ->
  let selection,state = match lane with
    | Lane_id.Exact id -> object_ ["kind",str "exact";"lane_id",str (Standalone_lane.to_id id)],
        object_ ["kind",str "exact";"configuration",configuration]
    | Lane_id.Browser id -> object_ ["kind",str "browser";"lane",str (Browser_lane.Lane_name.to_wire id)],
        (match id with Browser_lane.Lane_name.Live -> object_ ["kind",str "browser_clients";"connected_clients",`Int 0]
        | Automation | Stagehand -> object_ ["kind",str "browser_executor";"registered",`Bool true])
    | Lane_id.Machine id -> object_ ["kind",str "machine";"machine",str (Machine_lane.to_wire id)],
        object_ ["kind",str "machine";"publication",str "stable"] in
  row (Lane_id.to_wire (Lane_id.Builtin lane)) selection state)
let package_state declaration instances = object_ ["kind",str "package";"declaration",declaration;"instances",`List instances]
let instance ?(revision=`String "applied") ?(presence="live") ?(phase="observing") id =
  object_ ["instance_id",str id;"incarnation",str (id ^ "-incarnation");"run_id",str "run";
    "package_id",str "custom-package";"title",str "Custom observer";"package_revision",str "package-v1";
    "presence",str presence;"phase",(if phase="failed" then object_ ["kind",str phase;"message",str "cleanup unconfirmed"] else object_ ["kind",str phase]);"applied_revision",revision]
let declared ?(instances=[]) state =
  row "declaration//config/broken.toml" (object_ ["kind",str "declaration";"source_path",str "/config/broken.toml"])
    (package_state state instances)
let manual = row "instance/manual" (object_ ["kind",str "manual_instance";"instance_id",str "manual";"incarnation",str "manual-incarnation"])
  (package_state `Null [instance ~revision:`Null ~presence:"retained" ~phase:"failed" "manual"])
let package_read = object_ ["directory",str "/config";"complete",`Bool true;"owner_present",`Bool true;"issues",`List []]
let snapshot extra = object_ ["schema",str "masc.lane-inventory/v1";"observed_at",`Float 12.;
  "rows",`List (builtin_rows @ extra);"exact_snapshot",exact_snapshot;"package_read",package_read]
let replace_first change payload =
  match get "rows" payload with
  | `List (first::rest) -> set "rows" (`List (change first::rest)) payload
  | _ -> Alcotest.fail "missing fixture rows"
let find id snapshot = List.find (fun (row : Decode.row) -> row.id=id) snapshot.Decode.rows

let complete_inventory () =
  let snapshot = ok (Decode.decode (snapshot [manual])) in
  Alcotest.(check int) "all builtins and manual row" (List.length Lane_id.all_of_builtin + 1) (List.length snapshot.rows);
  Alcotest.(check int) "existing exact decoder retains every lane" (List.length Standalone_lane.all) (List.length snapshot.exact_snapshot.sls_lanes);
  (match (find "instance/manual" snapshot).selection with
   | Decode.Manual_instance {instance_id="manual";incarnation="manual-incarnation"} -> ()
   | _ -> Alcotest.fail "manual selection identity lost");
  Alcotest.(check string) "registration is not session health" "executor registered"
    (Display.row_summary (find "browser/automation" snapshot))
let invalid_and_running () =
  let target = declared ~instances:[instance "running"] (object_ ["kind",str "invalid";"messages",strings ["bad TOML"]]) in
  let decoded = ok (Decode.decode (snapshot [target])) in
  let row = find "declaration//config/broken.toml" decoded in
  Alcotest.(check string) "invalid declaration does not erase running worker" "declaration invalid · live observing" (Display.row_summary row);
  Alcotest.(check bool) "original diagnostic retained" true (List.mem "Declaration error: bad TOML" (Display.detail_lines row));
  Alcotest.(check bool) "applied revision distinct from invalid desired config" true (List.mem "Applied declaration revision: applied" (Display.detail_lines row))
let partial_owner_unknown () =
  let target = declared ~instances:[instance ~presence:"retained" ~phase:"detaching" "old"] (object_ ["kind",str "unobserved"]) in
  let payload = snapshot [target] |> set "package_read" (package_read |> set "complete" (`Bool false) |> set "owner_present" (`Bool false)
    |> set "issues" (`List [object_ ["source_path",str "/config";"message",str "directory unreadable"]])) in
  let decoded = ok (Decode.decode payload) in
  Alcotest.(check string) "partial does not say off or deleted" "declaration not observed · retained cleanup pending"
    (Display.row_summary (find "declaration//config/broken.toml" decoded));
  Alcotest.(check int) "partial, owner absence and source failure remain distinct" 3 (List.length (Display.snapshot_notices decoded));
  Alcotest.(check bool) "overview exposes the diagnostic reader" true
    (List.mem "1 inventory issues · i: details" (Display.overview_notices decoded));
  Alcotest.(check bool) "long issue details stay out of the overview" false
    (List.mem "/config: directory unreadable" (Display.overview_notices decoded))
let explicit_absence () =
  let decoded = ok (Decode.decode (snapshot [declared ~instances:[instance ~phase:"failed" "old"] (object_ ["kind",str "absent"])])) in
  Alcotest.(check string) "absent file is not successful cleanup" "declaration absent · live failed: cleanup unconfirmed"
    (Display.row_summary (find "declaration//config/broken.toml" decoded))
let unknown_wire () =
  let payload = snapshot [] in
  rejects "schema" (set "schema" (str "masc.lane-inventory/v2") payload);
  rejects "selection" (replace_first (fun row -> set "selection" (object_ ["kind",str "future"]) row) payload);
  rejects "state" (replace_first (fun row -> set "state" (object_ ["kind",str "off"]) row) payload);
  rejects "extra field" (set "extra" (`Bool true) payload);
  rejects "unknown instance presence" (snapshot [declared ~instances:[instance ~presence:"unknown" "old"] (object_ ["kind",str "absent"])])
let missing_and_duplicate () =
  let payload = snapshot [] in
  let without name = function `Assoc fields -> `Assoc (List.remove_assoc name fields) | value -> value in
  rejects "missing reading" (without "package_read" payload);
  rejects "missing row state" (replace_first (without "state") payload);
  rejects "duplicate nested key" (replace_first (fun row -> set "selection" (object_ ["kind",str "exact";"kind",str "exact";"lane_id",str "librarian_exact"]) row) payload);
  rejects "duplicate row" (set "rows" (`List (List.hd builtin_rows :: builtin_rows)) payload);
  rejects "missing builtin" (set "rows" (`List (List.tl builtin_rows)) payload)
let invalid_targets () =
  rejects "mismatched id" (replace_first (set "id" (str "exact/verifier_exact")) (snapshot []));
  rejects "wrong family state" (replace_first (set "state" (object_ ["kind",str "browser_clients";"connected_clients",`Int 1])) (snapshot []));
  let wrong = set "selection" (object_ ["kind",str "manual_instance";"instance_id",str "manual";"incarnation",str "another-incarnation"]) manual in
  rejects "manual incarnation mismatch" (snapshot [wrong]);
  rejects "manual declaration owner is not invented" (snapshot [set "state" (package_state `Null [instance "manual"]) manual]);
  rejects "managed worker needs applied owner revision" (snapshot [declared ~instances:[instance ~revision:`Null "old"] (object_ ["kind",str "absent"])])
let malformed_embedded_exact () =
  rejects "existing embedded schema decoder runs" (set "exact_snapshot" (set "schema" (str "unknown") exact_snapshot) (snapshot []));
  rejects "embedded duplicate keys also rejected" (set "exact_snapshot" (object_ ["schema",str "x";"schema",str "y"]) (snapshot []));
  rejects "nonfinite observed_at" (set "observed_at" (`Float nan) (snapshot []))
let exact_overview_agrees () =
  let inconsistent = replace_first (fun row ->
    set "state" (object_ ["kind",str "exact";"configuration",set "admitted_slots" (strings []) configuration]) row) (snapshot []) in
  rejects "overview and slot-editor snapshot must share admission" inconsistent
let repeated_instance () =
  let one = declared ~instances:[instance "same"] (object_ ["kind",str "absent"]) in
  let two = one |> set "id" (str "declaration//config/other.toml")
    |> set "selection" (object_ ["kind",str "declaration";"source_path",str "/config/other.toml"]) in
  rejects "same worker cannot have two source owners" (snapshot [one;two])
let running_observation_survives_inventory () =
  let decoded = ok (Decode.decode (snapshot [])) in
  let exact = decoded.exact_snapshot in
  let exact = {exact with Tui_decode.sls_lanes=List.map (fun (lane : Tui_decode.standalone_lane) ->
    if Standalone_lane.equal lane.sl_lane Librarian then
      {lane with sl_status=Tui_decode.Standalone_running;sl_running_count=2}
    else lane) exact.sls_lanes} in
  let decoded = {decoded with exact_snapshot=exact} in
  Alcotest.(check string) "admission does not hide ongoing exact work"
    "2 running · 1 admitted slots"
    (Display.row_summary_in decoded (find "exact/librarian_exact" decoded))

let bounded_run_reading_is_visible () =
  let decoded = ok (Decode.decode (snapshot [])) in
  let exact = {decoded.exact_snapshot with Tui_decode.sls_exact_run_projection_count=4;
    sls_exact_run_source_total=9;sls_exact_run_projection_truncated=true} in
  let decoded = {decoded with exact_snapshot=exact} in
  let note = "Exact run observations are windowed: 4/9 retained runs. Counts and timings describe this window." in
  Alcotest.(check bool) "overview retains the bounded observation warning" true
    (List.mem note (Display.overview_notices decoded));
  Alcotest.(check bool) "full diagnostics retain the same observation scope" true
    (List.mem note (Display.snapshot_notices decoded))

let () = Alcotest.run "TUI Lane inventory" ["wire and display",[
  Alcotest.test_case "running observation survives inventory" `Quick running_observation_survives_inventory;
  Alcotest.test_case "bounded run reading remains visible" `Quick bounded_run_reading_is_visible;
  Alcotest.test_case "all builtins and manual identity" `Quick complete_inventory;
  Alcotest.test_case "invalid declaration and live worker" `Quick invalid_and_running;
  Alcotest.test_case "partial reading and unknown owner" `Quick partial_owner_unknown;
  Alcotest.test_case "absent declaration and failed cleanup" `Quick explicit_absence;
  Alcotest.test_case "unknown wire rejected" `Quick unknown_wire;
  Alcotest.test_case "missing and duplicate rejected" `Quick missing_and_duplicate;
  Alcotest.test_case "targets remain coherent" `Quick invalid_targets;
  Alcotest.test_case "embedded exact decoder retained" `Quick malformed_embedded_exact;
  Alcotest.test_case "overview agrees with exact detail" `Quick exact_overview_agrees;
  Alcotest.test_case "instance ownership unique" `Quick repeated_instance;
]]
