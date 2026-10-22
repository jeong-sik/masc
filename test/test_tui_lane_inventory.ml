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
        (match id with Browser_lane.Lane_name.Live -> object_ ["kind",str "browser_clients";"activity",str "on";"addon",object_ ["kind",str "observed";"connected_clients",`Int 0]]
        | Automation | Stagehand -> object_ ["kind",str "browser_executor";"activity",str "on";"addon",object_ ["kind",str "observed";"registered",`Bool true]])
    | Lane_id.Machine id -> object_ ["kind",str "machine";"machine",str (Machine_lane.to_wire id)],
        object_ ["kind",str "machine";"activity",str "on";"publication",str "stable"] in
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
  Alcotest.(check string) "registration is not session health" "on; executor registered"
    (Display.row_summary (find "browser/automation" snapshot))

let browser_activity_and_backend_are_independent () =
  let make activity = snapshot [] |> set "rows" (`List (List.map (fun row ->
    match get "id" row with
    | `String ("browser/live" | "browser/automation" | "browser/stagehand") ->
        set "state" (set "activity" (str activity) (get "state" row)) row
    | _ -> row) builtin_rows)) in
  let off = ok (Decode.decode (make "off")) in
  Alcotest.(check string) "off keeps executor observation"
    "off; configuration retained; executor registered"
    (Display.row_summary (find "browser/automation" off));
  Alcotest.(check string) "live off does not imply disconnect"
    "off; configuration retained; 0 connected clients"
    (Display.row_summary (find "browser/live" off));
  let unavailable = ok (Decode.decode (make "unobserved")) in
  Alcotest.(check string) "unknown activity is not inferred from registration"
    "activity unavailable; executor registered"
    (Display.row_summary (find "browser/stagehand" unavailable));
  rejects "unknown activity is not enabled" (make "enabled");
  let missing = make "on" |> fun payload -> set "rows" (`List (List.map (fun row ->
    if get "id" row = str "browser/live" then
      set "state" (object_ ["kind",str "browser_clients";"addon",object_ ["kind",str "observed";"connected_clients",`Int 0]]) row
    else row) builtin_rows)) payload in
  rejects "missing activity is not enabled" missing
let browser_addon_reading_wire () =
  let with_live addon = snapshot [] |> set "rows" (`List (List.map (fun row ->
    if get "id" row = str "browser/live"
    then set "state" (object_ ["kind",str "browser_clients";"activity",str "on";"addon",addon]) row
    else row) builtin_rows)) in
  let read addon = (find "browser/live" (ok (Decode.decode (with_live addon)))).state in
  Alcotest.(check bool) "no browser Add-on decodes as absent" true
    (read (object_ ["kind",str "absent"]) = Decode.Browser_clients (Decode.Browser_enabled, Decode.Browser_addon_absent));
  Alcotest.(check bool) "a switched-off Add-on decodes as off" true
    (read (object_ ["kind",str "off"]) = Decode.Browser_clients (Decode.Browser_enabled, Decode.Browser_addon_off));
  Alcotest.(check bool) "an Add-on declared on and not running decodes as not running" true
    (read (object_ ["kind",str "not_running"])
     = Decode.Browser_clients (Decode.Browser_enabled, Decode.Browser_addon_not_running));
  Alcotest.(check bool) "an unreadable Add-on keeps its reason" true
    (read (object_ ["kind",str "unavailable";"detail",str "worker failed"])
     = Decode.Browser_clients (Decode.Browser_enabled, Decode.Browser_addon_unavailable "worker failed"));
  rejects "an unknown Add-on reading" (with_live (object_ ["kind",str "maybe"]));
  rejects "an observed reading without its value" (with_live (object_ ["kind",str "observed"]))
let machine_activity_and_publication_are_independent () =
  let make id state = snapshot [] |> set "rows" (`List (List.map (fun row ->
    if get "id" row = str id then set "state" state row else row) builtin_rows)) in
  List.iter (fun id ->
    List.iter (fun (activity,expected,label) ->
      List.iter (fun (publication,published,screen) ->
        let state = object_ ["kind",str "machine";"activity",str activity;"publication",str publication] in
        let row = find id (ok (Decode.decode (make id state))) in
        Alcotest.(check bool) "activity does not replace publication" true
          (row.state = Decode.Machine_state (expected,published));
        Alcotest.(check string) "activity and publication both visible" (label ^ "; " ^ screen) (Display.row_summary row))
        ["no_screen",Decode.No_screen,"no screen published";"stable",Decode.Stable,"screen stable";"running",Decode.Running,"machine running";"unavailable",Decode.Publication_unavailable,"worker observation unavailable"])
      ["on",Decode.Machine_enabled,"on";"off",Decode.Machine_disabled,"off; machine state retained";
       "unobserved",Decode.Machine_unobserved,"activity unavailable"];
    List.iter (fun activity -> rejects "invalid machine activity cannot infer on" (make id
      (object_ ["kind",str "machine";"activity",activity;"publication",str "stable"])))
      [`Null;`Bool true;str "enabled";str "";`Int 1];
    rejects "missing machine activity cannot infer on" (make id (object_ ["kind",str "machine";"publication",str "stable"])))
    ["machine/msx";"machine/dos"]
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
  rejects "wrong family state" (replace_first (set "state" (object_ ["kind",str "browser_clients";"activity",str "on";"addon",object_ ["kind",str "observed";"connected_clients",`Int 1]])) (snapshot []));
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
let disabled_is_desired_not_cleanup_proof () =
  let declaration enabled = object_ ["kind",str "valid";"enabled",`Bool enabled;
    "installation_id",str "observer";"run_id",str "run";"package_id",str "custom-package";
    "title",str "Observer";"desired_revision",str "same-payload";"source_revision",str "source";
    "application",`Assoc ["kind",str "cleaning"];"exact_outputs",`List []] in
  let payload = snapshot [declared ~instances:[instance ~phase:"failed" "worker"] (declaration false)] in
  let observed = ok (Decode.decode payload) in
  let row = find "declaration//config/broken.toml" observed in
  (match row.state with
   | Decode.Package_state {declaration=Some (Valid value);instances=[worker]} ->
       Alcotest.(check bool) "host cleanup and retained failure survive decoding" true
         (not value.enabled && value.application=Lane_addon_application.Cleaning_workers
          && worker.phase=Lane_addon_types.Failed "cleanup unconfirmed")
   | _ -> Alcotest.fail "declared worker disappeared");
  let off application = declared (set "application" (Lane_addon_application.to_json application) (declaration false)) in
  List.iter (fun application ->
    let observed = ok (Decode.decode (snapshot [off application])) in
    match (find "declaration//config/broken.toml" observed).state with
    | Decode.Package_state {declaration=Some (Valid value);instances=[]} ->
        Alcotest.(check bool) "empty worker inventory retains host application" true (value.application=application)
    | _ -> Alcotest.fail "application reading disappeared")
    [Lane_addon_application.Inactive;Cleaning_workers;Failed ["cleanup refused"];Unknown ["not read"]];
  rejects "off cannot claim an applied worker"
    (snapshot [off (Lane_addon_application.Applied "other")]);
  rejects "on cannot claim inactive application"
    (snapshot [declared (set "application" (Lane_addon_application.to_json Lane_addon_application.Inactive) (declaration true))]);
  rejects "unknown requires diagnostic evidence"
    (snapshot [off (Lane_addon_application.Unknown [])]);
  rejects "application is required, not inferred from missing workers"
    (snapshot [declared (match declaration false with
      | `Assoc fields -> `Assoc (List.remove_assoc "application" fields)
      | value -> value)]);
  let invalid = set "enabled" (str "false") (declaration false) in
  rejects "nonboolean desired activity is not coerced" (snapshot [declared invalid])

let disabled_exact_keeps_candidates_and_finishing_work () =
  let off = exact_lane Standalone_lane.Librarian
    |> set "configuration_state" (str "off") |> set "status" (str "off")
    |> set "admitted_slots" (strings []) |> set "cli_slots" (strings [])
    |> set "declared_slots" (strings ["first";"second"])
    |> set "declared_cli_slots" (strings ["cli"]) |> set "running_count" (`Int 1) in
  let make off =
    let observed = exact_snapshot |> set "lanes" (`List (List.map (fun lane ->
      if Standalone_lane.equal lane Librarian then off else exact_lane lane) Standalone_lane.all)) in
    snapshot [] |> set "exact_snapshot" observed |> set "rows" (`List (List.map (fun row ->
      if get "id" row = str "exact/librarian_exact" then
        set "state" (object_ ["kind",str "exact";"configuration",object_
          ["kind",str "off";"declared_slots",strings ["first";"second"];"declared_cli_slots",strings ["cli"]]]) row
      else row) builtin_rows)) in
  let observed = ok (Decode.decode (make off)) in
  let row = find "exact/librarian_exact" observed in
  Alcotest.(check string) "off preserves observation of accepted work"
    "off · 1 finishing · off; candidates retained" (Display.row_summary_in observed row);
  Alcotest.(check bool) "candidate order available in detail" true
    (List.mem "Declared HTTP slots: first, second" (Display.detail_lines row));
  rejects "off must not admit new candidates" (make (off |> set "admitted_slots" (strings ["first"])));
  rejects "off and running status contradict" (make (off |> set "status" (str "running")));
  rejects "off declarations must agree" (make (off |> set "declared_slots" (strings ["other"])))

(* A package row's exact outputs (RFC operator-quiz §4.8): what the wire
   carries, which one [ / ] chooses, and the runtime.toml table e opens. *)
let quiz_declaration outputs = object_ ["kind",str "valid";"enabled",`Bool true;
  "installation_id",str "operator-quiz";"run_id",str "operator-quiz";"package_id",str "operator-quiz";
  "title",str "Operator quiz";"desired_revision",str "r1";"source_revision",str "source";
  "application",`Assoc ["kind",str "starting"];"exact_outputs",`List outputs]
let output name source configuration = object_ ["output",str name;"source",str source;"configuration",configuration]
let quiz_outputs = [output "author" "declared" configuration;
  output "grade" "declared" (object_ ["kind",str "unconfigured";"detail",str "no table"]);
  output "legacy" "table_only" (object_ ["kind",str "off";"declared_slots",strings [];"declared_cli_slots",strings []])]

let exact_outputs_are_chosen_by_name_and_open_their_table () =
  let row = find "declaration//config/broken.toml" (ok (Decode.decode (snapshot [declared (quiz_declaration quiz_outputs)]))) in
  let chosen selected = Option.map (fun (_, (o : Decode.exact_output)) -> o.output)
      (Display.selected_exact_output ~selected row) in
  Alcotest.(check (option string)) "nothing chosen is the first" (Some "author") (chosen None);
  Alcotest.(check (option string)) "a name the row no longer lists is the first" (Some "author") (chosen (Some "gone"));
  let step selected direction = Option.map snd (Display.step_exact_output ~selected ~direction row) in
  Alcotest.(check (list (option string))) "steps move by one and stay at the ends"
    [Some "grade"; Some "legacy"; Some "legacy"; Some "author"]
    [step None 1; step (Some "grade") 1; step (Some "legacy") 1; step (Some "author") (-1)];
  (match Display.selected_exact_output ~selected:(Some "grade") row with
   | Some (installation_id, (grade : Decode.exact_output)) ->
       Alcotest.(check bool) "the wire keeps source and lane state" true
         (grade.source = Decode.Declared && (match grade.configuration with Decode.Unconfigured _ -> true | _ -> false));
       Alcotest.(check (list string)) "e opens the output's own table"
         ["runtime"; "addon_exact_lanes"; "operator-quiz"; "grade"]
         (ok (Display.exact_output_table_path ~installation_id grade))
   | None -> Alcotest.fail "the row lists exact outputs");
  let empty = find "declaration//config/broken.toml" (ok (Decode.decode (snapshot [declared (quiz_declaration [])]))) in
  Alcotest.(check bool) "a package with no exact output offers none" true
    (Option.is_none (Display.selected_exact_output ~selected:None empty))

let exact_outputs_wire_is_strict () =
  let with_outputs outputs = snapshot [declared (quiz_declaration outputs)] in
  rejects "an output listed twice" (with_outputs [output "author" "declared" configuration; output "author" "table_only" configuration]);
  rejects "an unknown source" (with_outputs [output "author" "guessed" configuration]);
  rejects "an unknown lane state" (with_outputs [output "author" "declared" (object_ ["kind",str "maybe"])]);
  rejects "a valid declaration without the list"
    (snapshot [declared (match quiz_declaration [] with
       | `Assoc fields -> `Assoc (List.remove_assoc "exact_outputs" fields) | other -> other)])

(* The mark each Lanes row draws comes from this one decision: a working
   installation, a failed one and a lane nobody set up must not read alike. *)
let standing_reads_what_the_row_says () =
  let module S = Masc_tui_lane_standing in
  let standing = Alcotest.testable (fun f value -> Format.pp_print_string f (S.word value)) ( = ) in
  let row_of state = { Decode.id = "row"; label = "row"; purpose = "fixture purpose";
    selection = Decode.Declaration "/config/lane-addons/browser-work.toml"; state } in
  let worker ?(presence = Decode.Live) phase = { Decode.instance_id = "worker"; incarnation = "worker"; run_id = "browser-work";
    package_id = "browser"; title = "Browser connections"; package_revision = "0.1.0";
    presence; phase; applied_revision = None } in
  let declared ?(enabled = true) application = Decode.Valid { installation_id = "browser-work"; enabled;
    run_id = "browser-work"; package_id = "browser"; title = "Browser connections";
    desired_revision = "1"; source_revision = "1"; application; exact_outputs = [] } in
  let package declaration instances = Decode.Package_state { declaration; instances } in
  let check name expected state = Alcotest.check standing name expected (Display.row_standing (row_of state)) in
  check "a declared worker that runs is ready" S.Ready
    (package (Some (declared (Lane_addon_application.Applied "worker"))) [ worker Decode.Attached ]);
  check "a failed worker is failing even beside an applied declaration" S.Failing
    (package (Some (declared (Lane_addon_application.Applied "worker"))) [ worker (Decode.Failed "cleanup incomplete") ]);
  check "a declaration whose application failed is failing" S.Failing
    (package (Some (declared (Lane_addon_application.Failed [ "refused" ]))) []);
  check "a worker that is starting is changing" S.Changing
    (package (Some (declared Lane_addon_application.Starting_worker)) []);
  check "a declaration switched off and cleaned up is off" S.Off
    (package (Some (declared ~enabled:false Lane_addon_application.Inactive)) []);
  check "a worker whose declaration was removed is changing while it detaches" S.Changing
    (package (Some Decode.Absent) [ worker Decode.Attached ]);
  check "a manual attachment that runs is ready" S.Ready (package None [ worker Decode.Attached ]);
  check "a retained worker still cleaning up is changing" S.Changing
    (package None [ worker ~presence:Decode.Retained Decode.Detaching ]);
  check "a removed declaration with no worker left is not set up" S.Not_set_up (package (Some Decode.Absent) []);
  check "a declaration the server did not read is unknown" S.Unobserved (package (Some Decode.Unobserved) []);
  check "a browser lane with no browser connected waits" S.Waiting (Decode.Browser_clients (Decode.Browser_enabled, Decode.Browser_observed 0));
  check "a browser lane with a browser connected is ready" S.Ready (Decode.Browser_clients (Decode.Browser_enabled, Decode.Browser_observed 1));
  check "a browser lane switched off is off" S.Off (Decode.Browser_executor (Decode.Browser_disabled, Decode.Browser_observed true));
  check "a browser lane switched off that still has browsers is changing" S.Changing
    (Decode.Browser_clients (Decode.Browser_disabled, Decode.Browser_observed 2));
  check "a browser lane with no browser Add-on is not set up" S.Not_set_up
    (Decode.Browser_clients (Decode.Browser_enabled, Decode.Browser_addon_absent));
  check "a browser lane whose Add-on is switched off is off" S.Off
    (Decode.Browser_clients (Decode.Browser_enabled, Decode.Browser_addon_off));
  check "a browser lane whose Add-on is declared on and not running waits" S.Waiting
    (Decode.Browser_executor (Decode.Browser_enabled, Decode.Browser_addon_not_running));
  check "a browser lane whose Add-on cannot be read is failing" S.Failing
    (Decode.Browser_executor (Decode.Browser_enabled, Decode.Browser_addon_unavailable "cleanup incomplete"));
  check "a browser lane the server did not read is unknown" S.Unobserved
    (Decode.Browser_clients (Decode.Browser_unobserved, Decode.Browser_observed 0));
  check "an exact lane switched off is off" S.Off
    (Decode.Exact_state (Decode.Disabled { declared_slots = []; declared_cli_slots = [] }));
  check "an exact lane without its registry is unknown" S.Unobserved
    (Decode.Exact_state (Decode.Registry_unavailable "registry unreadable"));
  check "a machine with no screen yet waits" S.Waiting (Decode.Machine_state (Decode.Machine_enabled, Decode.No_screen));
  check "a machine switched off that still runs is changing" S.Changing
    (Decode.Machine_state (Decode.Machine_disabled, Decode.Running));
  check "an exact lane with no configuration is not set up" S.Not_set_up
    (Decode.Exact_state (Decode.Unconfigured "no candidates"));
  check "a machine switched off is off" S.Off (Decode.Machine_state (Decode.Machine_disabled, Decode.Stable));
  check "a machine whose worker cannot be read is failing" S.Failing
    (Decode.Machine_state (Decode.Machine_enabled, Decode.Publication_unavailable))

(* An exact row's mark reads the run observation of the same capture, as its
   STATE text does. *)
let exact_standing_reads_the_run_observation () =
  let module S = Masc_tui_lane_standing in
  let standing = Alcotest.testable (fun f value -> Format.pp_print_string f (S.word value)) ( = ) in
  let decoded = ok (Decode.decode (snapshot [])) in
  let lane = List.hd decoded.exact_snapshot.sls_lanes in
  let row = List.find (fun (row : Decode.row) -> match row.selection with
    | Decode.Exact target -> Standalone_lane.equal target lane.sl_lane
    | _ -> false) decoded.rows in
  let with_status sl_status sl_running_count =
    { decoded with exact_snapshot = { decoded.exact_snapshot with sls_lanes =
        List.map (fun (other : Tui_decode.standalone_lane) ->
          if Standalone_lane.equal other.sl_lane lane.sl_lane then { other with sl_status; sl_running_count }
          else other) decoded.exact_snapshot.sls_lanes } } in
  Alcotest.check standing "a configured lane with no runs yet is ready" S.Ready (Display.row_standing_in decoded row);
  Alcotest.check standing "a lane whose latest runs fail is failing" S.Failing
    (Display.row_standing_in (with_status Tui_decode.Standalone_degraded 0) row);
  Alcotest.check standing "a lane switched off that still finishes runs is changing" S.Changing
    (Display.row_standing_in (with_status Tui_decode.Standalone_off 1) row)

let () = Alcotest.run "TUI Lane inventory" ["wire and display",[
  Alcotest.test_case "machine activity and publication remain independent" `Quick machine_activity_and_publication_are_independent;
  Alcotest.test_case "standing reads what the row says" `Quick standing_reads_what_the_row_says;
  Alcotest.test_case "exact standing reads the run observation" `Quick exact_standing_reads_the_run_observation;
  Alcotest.test_case "browser activity and registration remain independent" `Quick browser_activity_and_backend_are_independent;
  Alcotest.test_case "browser Add-on reading wire" `Quick browser_addon_reading_wire;
  Alcotest.test_case "exact off retains candidates and finishing work" `Quick disabled_exact_keeps_candidates_and_finishing_work;
  Alcotest.test_case "disabled intent keeps unfinished cleanup visible" `Quick disabled_is_desired_not_cleanup_proof;
  Alcotest.test_case "all builtins and manual identity" `Quick complete_inventory;
  Alcotest.test_case "unknown wire rejected" `Quick unknown_wire;
  Alcotest.test_case "missing and duplicate rejected" `Quick missing_and_duplicate;
  Alcotest.test_case "targets remain coherent" `Quick invalid_targets;
  Alcotest.test_case "embedded exact decoder retained" `Quick malformed_embedded_exact;
  Alcotest.test_case "overview agrees with exact detail" `Quick exact_overview_agrees;
  Alcotest.test_case "instance ownership unique" `Quick repeated_instance;
  Alcotest.test_case "exact outputs are chosen by name and open their table" `Quick
    exact_outputs_are_chosen_by_name_and_open_their_table;
  Alcotest.test_case "exact outputs wire is strict" `Quick exact_outputs_wire_is_strict;
]]
