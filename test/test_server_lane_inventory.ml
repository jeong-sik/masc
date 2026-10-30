open Alcotest
open Masc
module Inventory = Server_lane_inventory
module Addon = Lane_addon_runtime
module Config = Lane_addon_config
let member = Yojson.Safe.Util.member
let values name json = member name json |> Yojson.Safe.Util.to_list
let text name json = member name json |> Yojson.Safe.Util.to_string
let write path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | _ -> Sys.remove path
let rec files path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Sys.readdir path |> Array.to_list |> List.sort String.compare
      |> List.concat_map (fun name -> files (Filename.concat path name))
  | _ -> [path, In_channel.with_open_bin path In_channel.input_all]
let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () -> match previous with
    | Some value -> Unix.putenv name value | None -> Unix.unsetenv name) f
let with_fixture f =
  let root = Filename.temp_dir "lane-inventory-" "" in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let config_root = Filename.concat root "configuration" in Unix.mkdir config_root 0o700;
    let directory = Filename.concat config_root "lane-addons" in Unix.mkdir directory 0o700;
    let config = Workspace.default_config root in
    with_env "MASC_CONFIG_DIR" config_root (fun () ->
      with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true" (fun () ->
        Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
          Fs_compat.set_fs (Eio.Stdenv.fs env);
          Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
            ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
              Addon.For_testing.reset (); f env sw config root directory))))))
let package root =
  let path = Filename.concat root "package.toml" in
  write path {|id = "observer"
revision = "1"
title = "Observation package"
ui_category = "analysis"
image = "fixture/observer"
command = ["observer"]
contributions = ["observe"]
[resources]
cpus = 0.5
memory_bytes = 67108864
pids = 16
max_reply_bytes = 4096
|}; path
let declaration manifest id = Printf.sprintf
  "id = %S\nrun_id = \"world\"\nmanifest_path = %S\n[binding]\nsources = []\n" id manifest

let before_reconcile () = with_fixture (fun _env _sw config root directory ->
  let manifest = package root in
  let good = Filename.concat directory "good.toml" and broken = Filename.concat directory "broken.toml" in
  let first = Filename.concat directory "duplicate-a.toml" and second = Filename.concat directory "duplicate-b.toml" in
  write good (declaration manifest "good"); write broken "id = \"";
  write first (declaration manifest "duplicate"); write second (declaration manifest "duplicate");
  let before = files root in
  let json = Inventory.snapshot ~config |> Inventory.to_json in
  let rows = values "rows" json in
  let decoded = match Tui_decode_lane_inventory.decode json with
    | Ok value -> value | Error detail -> fail detail in
  List.iter (fun (row : Tui_decode_lane_inventory.row) ->
    match row.selection with
    | Exact _ | Browser _ | Machine _ ->
        let encoded = List.find (fun value -> text "id" value=row.id) rows in
        let expected = match Lane_addon_category.of_json (member "ui_category" encoded) with
          | Ok value -> value | Error detail -> fail detail in
        check bool "actual server role reaches the TUI category consumer" true
          (Masc_tui_lane_inventory.row_category row=Some expected)
    | Declaration _ | Manual_instance _ -> ()) decoded.rows;
  let builtin = rows |> List.filter (fun row -> match text "kind" (member "selection" row) with
    | "exact" | "browser" | "machine" -> true | _ -> false) |> List.map (text "id") in
  check (list string) "every derived builtin, in its own order"
    (List.map (fun id -> Lane_id.to_wire (Lane_id.Builtin id)) Lane_id.all_of_builtin) builtin;
  List.iter (fun (path,expected) ->
    let row = List.find (fun row -> member "source_path" (member "selection" row)=`String path) rows in
    check string "file is discoverable before reconcile" expected
      (text "kind" (member "declaration" (member "state" row))))
    [good,"valid";broken,"invalid";first,"invalid";second,"invalid"];
  let good_row = List.find (fun row -> member "source_path" (member "selection" row)=`String good) rows in
  check string "unreconciled file is not applied by reading it" "unknown"
    (text "kind" (member "application" (member "declaration" (member "state" good_row))));
  check string "read-only inventory carries the current parsed category" "analysis"
    (text "ui_category" (member "declaration" (member "state" good_row)));
  check bool "reading did not create a runtime manager" false
    (member "owner_present" (member "package_read" json) |> Yojson.Safe.Util.to_bool);
  check bool "no file bytes changed" true (before=files root);
  check bool "no runtime store directory was created" false
    (Sys.file_exists (Filename.concat (Workspace.masc_dir config) "lane-addons"));
  let again = Addon.inventory ~config in
  check bool "repeated read still has no manager" false again.owner_present;
  check int "same capture includes every exact detail" (List.length Standalone_lane.all)
    (List.length (values "lanes" (member "exact_snapshot" json))))

(* A package row lists the exact outputs the package declares, in manifest
   order, then the runtime.toml tables for outputs it does not declare, each
   with the lane state the exact registry reads (RFC operator-quiz §4.8). *)
let exact_outputs_follow_the_manifest_then_the_tables () = with_fixture (fun _env _sw _config root directory ->
  write (Filename.concat root "out.json") {|{"type":"object","properties":{},"additionalProperties":false}|};
  let manifest = Filename.concat root "quiz.toml" in
  write manifest {|id = "quiz"
revision = "1"
title = "Quiz package"
image = "fixture/quiz"
command = ["quiz"]
contributions = ["observe"]
[resources]
cpus = 0.5
memory_bytes = 67108864
pids = 16
max_reply_bytes = 4096
[world.exact_outputs.author]
schema = "out.json"
[world.exact_outputs.grade]
schema = "out.json"
|};
  write (Filename.concat directory "quiz.toml") (declaration manifest "quiz");
  let declarations = Config.load ~directory in
  let d = match declarations.declarations with
    | [d] -> d
    | _ -> fail (String.concat "; " (List.map (fun (issue : Config.issue) -> issue.message) declarations.issues)) in
  let configured = Server_standalone_lane_projection.Configured {admitted_slots=["a.m"];cli_slots=[];
    declared_slots=["a.m"];declared_cli_slots=[];dropped_slots=[];admission_error=None} in
  let configuration (addon : Runtime_schema.addon_lane) = match addon.output with
    | "author" when addon.declaration_id = "quiz" -> configured
    | "grade" -> Server_standalone_lane_projection.Unconfigured "no table"
    | _ -> Server_standalone_lane_projection.Disabled {declared_slots=[];declared_cli_slots=[]} in
  let tables ~declaration_id = if declaration_id = "quiz" then ["author"; "old"] else ["other"] in
  let outputs = Inventory.For_testing.exact_outputs ~configuration ~tables d in
  check (list string) "declared outputs, then a table the package does not declare"
    ["author/declared/configured"; "grade/declared/unconfigured"; "old/table_only/off"]
    (List.map (fun (o : Inventory.exact_output) -> Printf.sprintf "%s/%s/%s" o.output
       (match o.source with Inventory.Declared -> "declared" | Table_only -> "table_only")
       (match o.configuration with
        | Server_standalone_lane_projection.Configured _ -> "configured" | Disabled _ -> "off"
        | Unconfigured _ -> "unconfigured" | Registry_unavailable _ -> "unavailable")) outputs);
  match Inventory.For_testing.package_rows ~applications:[] ~declarations ~instances:[]
          ~exact_outputs:(Inventory.For_testing.exact_outputs ~configuration ~tables) with
  | [row] ->
      let listed = values "exact_outputs" (member "declaration" (member "state" (Inventory.For_testing.row_to_json row))) in
      check (list string) "the row carries them on the wire"
        ["author:declared:configured"; "grade:declared:unconfigured"; "old:table_only:off"]
        (List.map (fun entry -> String.concat ":" [text "output" entry; text "source" entry;
           text "kind" (member "configuration" entry)]) listed)
  | _ -> fail "one declaration row")

let application_is_bound_to_the_observed_declaration () = with_fixture (fun _env _sw _config root directory ->
  let manifest = package root in
  write (Filename.concat directory "off.toml") ("enabled = false\n" ^ declaration manifest "off");
  let declarations = Config.load ~directory in
  let d = match declarations.declarations with [d] -> d | _ -> fail "one valid declaration" in
  let observed application : Addon.configuration_application =
    {owner={id=d.id;source_path=d.source_path;revision=d.revision};
     source_revision=d.source_revision;enabled=d.enabled;application} in
  let read declarations applications =
    match Inventory.For_testing.package_rows ~declarations ~applications ~instances:[] ~exact_outputs:(fun _ -> []) with
    | [{state=Inventory.Package_state {declaration=Some (Valid value);instances=[]};_}] -> value.application
    | _ -> fail "one declaration remains without any worker records" in
  List.iter (fun application ->
    check bool "empty worker rows do not replace the host application" true
      (read declarations [observed application] = application))
    [Lane_addon_application.Inactive;Cleaning_workers;Failed ["cleanup refused"];Unknown ["not read"]];
  let unknown applications = match read declarations applications with
    | Lane_addon_application.Unknown (_ :: _) -> ()
    | Starting_worker | Cleaning_workers | Applied _ | Inactive | Failed _ | Unknown [] ->
        fail "a missing or mismatched host observation must remain unknown" in
  unknown [];
  let current = observed Lane_addon_application.Inactive in
  List.iter (fun stale -> unknown [stale])
    [{current with owner={current.owner with id="other"}};
     {current with owner={current.owner with source_path="/other.toml"}};
     {current with source_revision="old-file"};
     {current with owner={current.owner with revision="old-binding"}};
     {current with enabled=true}];
  unknown [current;current];
  match read {declarations with complete=false} [current] with
  | Lane_addon_application.Unknown (_ :: _) -> ()
  | Starting_worker | Cleaning_workers | Applied _ | Inactive | Failed _ | Unknown [] ->
      fail "an incomplete current directory cannot confirm application")

let retained_metadata () = with_fixture (fun _env _sw config root directory ->
  let masc = Workspace.masc_dir config in Unix.mkdir masc 0o700;
  let store_root = Filename.concat masc "lane-addons" in
  let store = Lane_addon_store.create ~root:store_root in
  let put id configuration =
    let json = `Assoc ["instance_id",`String id;"incarnation",`String id;"run_id",`String "world";
      "addon_id",`String "observer";"title",`String "Retained observer";"revision",`String "1";
      "phase",Lane_addon_types.phase_to_json (Failed "cleanup incomplete: refused");
      "lifecycle",Lane_addon_lifecycle.state_to_json (Lane_addon_lifecycle.Failed (Lane_addon_lifecycle.failed (Lane_addon_lifecycle.Cleanup_unconfirmed "refused")));"configuration",configuration;
      "visibility",`Assoc ["kind",`String "shared"];
      "source_access",Lane_addon_sources.access_to_json Lane_addon_sources.Unauthenticated] in
    match Lane_addon_store.save_binding store ~instance_id:id json with Ok () -> () | Error e -> fail e in
  let path = Filename.concat directory "removed.toml" in
  put "manual" `Null;
  put "managed" (`Assoc ["id",`String "removed";"source_path",`String path;"revision",`String "applied"]);
  write (Filename.concat (Filename.concat store_root "bindings") "broken.json") "{";
  let before = files root in
  let owner = Addon.inventory ~config in
  check bool "retained files do not create a manager" false owner.owner_present;
  check bool "bad sibling is partial" false owner.complete;
  check int "readable sibling metadata remains" 2 (List.length owner.instances);
  let rows = Inventory.For_testing.package_rows ~applications:[] ~declarations:(Config.load ~directory) ~instances:owner.instances
    ~exact_outputs:(fun _ -> []) in
  check bool "manual selection keeps exact incarnation" true
    (List.exists (fun (row : Inventory.row) -> row.selection=Inventory.Manual_instance {instance_id="manual";incarnation="manual"}) rows);
  let removed = List.find (fun (row : Inventory.row) -> row.selection=Inventory.Declaration path) rows in
  (match removed.state with
   | Inventory.Package_state {declaration=Some Absent;instances=[i]} ->
       check bool "cleanup failure is retained" true (i.phase=Lane_addon_types.Failed "cleanup incomplete: refused")
   | _ -> fail "retained declaration owner disappeared");
  let incomplete : Config.snapshot = {declarations=[];paths=[];issues=[];complete=false} in
  let rows = Inventory.For_testing.package_rows ~applications:[] ~declarations:incomplete ~instances:owner.instances
    ~exact_outputs:(fun _ -> []) in
  check bool "partial read cannot claim declaration deletion" true
    (List.exists (fun (r : Inventory.row) -> match r.state with
      | Inventory.Package_state {declaration=Some Unobserved;_} -> true | _ -> false) rows);
  check bool "metadata read did not change evidence bytes" true (before=files root))

let detached_history () =
  let path = "/fixture/completed.toml" in
  let detached : Addon.inventory_instance = {instance_id="old";incarnation="old";run_id="world";
    package_id="observer";title="Old observer";package_revision="1";ui_category=None;
    configuration=Some {id="completed";source_path=path;revision="1"};
    presence=Retained;phase=Detached} in
  let manual = {detached with instance_id="manual-old";incarnation="manual-old";configuration=None} in
  let empty : Config.snapshot = {declarations=[];paths=[];issues=[];complete=true} in
  let rows declarations = Inventory.For_testing.package_rows ~applications:[] ~declarations ~instances:[detached;manual]
    ~exact_outputs:(fun _ -> []) in
  check int "completed manual and absent declaration leave the active inventory" 0 (List.length (rows empty));
  (match rows {empty with complete=false} with
   | [{state=Inventory.Package_state {declaration=Some Unobserved;instances=[]};_}] -> ()
   | _ -> fail "incomplete declaration read must preserve the known path without active worker count");
  let present = {empty with paths=[path];issues=[{source_path=path;id=None;message="invalid TOML"}]} in
  (match rows present with
   | [{state=Inventory.Package_state {declaration=Some (Invalid _);instances=[]};_}] -> ()
   | _ -> fail "existing declaration remains while detached history is not an active worker")

let http_read ~sw ~clock ~state token =
  let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
    | Ok value -> value | Error `Malformed -> fail "fixture authority" in
  Server_request_authority.with_current authority (fun () ->
    let router = Server_routes_http_routes_dashboard.add_routes ~sw ~clock (Http_server_eio.Router.create ()) in
    Server_auth.publish_server_state state;
    Fun.protect ~finally:Server_auth.clear_server_state (fun () ->
      let output = Buffer.create 1024 in
      let connection = Httpun.Server_connection.create (fun reqd ->
        Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
      let request = Printf.sprintf
        "GET /api/v1/lanes HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nOrigin: http://127.0.0.1:8935\r\n%s\r\n"
        (match token with None -> "" | Some token -> "Authorization: Bearer " ^ token ^ "\r\n") in
      let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
      ignore (Httpun.Server_connection.read_eof connection bytes ~off:0 ~len:(Bigstringaf.length bytes));
      let rec flush () = match Httpun.Server_connection.next_write_operation connection with
        | `Write iovecs ->
            let written = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
              Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
              total+iov.len) 0 iovecs in
            Httpun.Server_connection.report_write_result connection (`Ok written); flush ()
        | `Yield | `Close _ -> () in
      flush (); Buffer.contents output))
let operator_route () = with_fixture (fun env sw config root _directory ->
  Auth.save_auth_config root {Masc_domain.default_auth_config with enabled=true; require_token=true};
  let token name role = match Auth.create_token root ~agent_name:name ~role with
    | Ok (token,_) -> token | Error e -> fail (Masc_domain.masc_error_to_string e) in
  let admin = token "inventory-operator" Masc_domain.Admin in
  let worker = token "inventory-reader" Masc_domain.Worker in
  let state = Mcp_server.For_testing.create_state ~base_path:root in
  let get token = http_read ~sw ~clock:(Eio.Stdenv.clock env) ~state token in
  let status response = match String.split_on_char ' ' response with
    | _::code::_ -> int_of_string code | _ -> fail "missing HTTP status" in
  check int "anonymous inventory refused" 401 (status (get None));
  check int "read-only worker cannot read operator paths" 403 (status (get (Some worker)));
  let before = files root in
  let response = get (Some admin) in
  check int "operator inventory available" 200 (status response);
  check bool "admin GET does not construct the package manager" false (Addon.inventory ~config).owner_present;
  check bool "HTTP inventory leaves workspace bytes unchanged" true (before=files root))

let machine_publication_reads_worker_observation () =
  let row : Lane_addon_types.row = {id="worker/screen";lane_id="worker/dos/screen";
    kind=Value;title="DOS";observed_at=1.;subject_id="load-1";clock=None;actor=None;
    fields=["machine_loaded",`Bool true];evidence=[];related_ids=[]} in
  let snapshot : Addon.export_observation = {instance_id="worker";observation_seq=1;
    max_bytes=4096;refreshing=false;output={rows=[row];coverage=[]}} in
  let project = Inventory.For_testing.machine_publication in
  check bool "worker frame is visible without a host machine" true (project (Ok (Some snapshot)) = Inventory.Stable);
  check bool "worker refresh is visible" true
    (project (Ok (Some {snapshot with refreshing=true})) = Inventory.Running);
  let failed : Lane_addon_unready.t = {installation="worker";instance_id="worker";package_id="dos";
    declared_tools=["masc_dos_screen"];service=Lane_addon_types.Mcp_tools;reason=Failed {Lane_addon_lifecycle.cause=Worker_failed "worker failed";first=None}} in
  check bool "worker failure is not an empty machine" true
    (project (Error (Addon.Unready_installations (failed, []))) = Inventory.Publication_unavailable);
  check bool "missing installation has no current screen" true (project (Ok None) = Inventory.No_screen);
  let unloaded = {snapshot with output={rows=[{row with fields=["machine_loaded",`Bool false]}];coverage=[]}} in
  check bool "unloaded worker reports no screen" true (project (Ok (Some unloaded)) = Inventory.No_screen);
  check bool "missing loaded status cannot claim no screen" true
    (project (Ok (Some {snapshot with output={rows=[];coverage=[]}})) = Inventory.Publication_unavailable)

let machine_wire_preserves_both_readings () =
  List.iter (fun machine ->
    List.iter (fun (activity,wire) -> List.iter (fun (publication,published) ->
      let row : Inventory.row = {id="machine/" ^ Machine_lane.to_wire machine; label="fixture";purpose="fixture";
        selection=Inventory.Machine machine;state=Inventory.Machine_state (activity,publication)} in
      let state = member "state" (Inventory.For_testing.row_to_json row) in
      check string "activity" wire (text "activity" state);
      check string "publication retained" published (text "publication" state))
      [Inventory.No_screen,"no_screen";Stable,"stable";Running,"running";Publication_unavailable,"unavailable"])
      [Machine_configuration.Enabled,"on";Disabled,"off";Unobserved,"unobserved"])
    [Machine_lane.Msx;Dos]

let h2_read ~sw ~clock ~state token =
  let trust_policy = match Server_request_authority.make_trust_policy
    ~bind_host:"127.0.0.1" ~bind_port:8935 ~explicit_base_url:None with
    | Ok value -> value | Error error -> fail (Server_request_authority.trust_policy_error_to_string error) in
  let previous = Server_auth.For_testing.snapshot_server_state () in
  Server_auth.publish_server_state state;
  Fun.protect ~finally:(fun () -> Server_auth.For_testing.restore_server_state previous) (fun () ->
    let server_flow,client_flow = Eio_unix.Net.socketpair_stream ~sw () in
    let gateway = Server_h2_gateway.make_request_handler ~routes:(Server_routes_http.make_routes ~port:0 ~host:"127.0.0.1" ~sw ~clock:clock) ~trust_policy ~sw ~clock ~server_start_time:0. in
    let server = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Switch.run (fun conn_sw ->
      Server_bootstrap_http.serve_h2_connection ~sw:conn_sw ~h2_request_handler:gateway
        ~h2_error_handler:(Server_h2_gateway.make_error_handler ())
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)) server_flow)) in
    let reply,resolve = Eio.Promise.create () in
    let client = H2_eio.Client.create_connection ~sw
      ~error_handler:(fun _ -> if not (Eio.Promise.is_resolved reply) then
        Eio.Promise.resolve resolve (Error "H2 connection failed")) client_flow in
    Fun.protect ~finally:(fun () -> Eio.Flow.shutdown client_flow `All; Eio.Promise.await_exn server) (fun () ->
      let headers = [":authority","127.0.0.1:8935";"origin","http://127.0.0.1:8935"]
        @ (match token with None -> [] | Some token -> ["authorization","Bearer " ^ token]) in
      let request = H2.Request.create ~scheme:"http" ~headers:(H2.Headers.of_list headers) `GET "/api/v1/lanes" in
      let writer = H2_eio.Client.request client ~flush_headers_immediately:true request
        ~error_handler:(fun _ -> if not (Eio.Promise.is_resolved reply) then
          Eio.Promise.resolve resolve (Error "H2 stream failed"))
        ~response_handler:(fun response reader ->
          let body = Buffer.create 1024 in
          let rec read () = H2.Body.Reader.schedule_read reader
            ~on_eof:(fun () -> Eio.Promise.resolve resolve (Ok (H2.Status.to_code response.status,Buffer.contents body)))
            ~on_read:(fun bytes ~off ~len -> Buffer.add_string body (Bigstringaf.substring bytes ~off ~len);read ()) in
          read ()) in
      H2.Body.Writer.close writer;
      match Eio.Time.with_timeout_exn clock 10. (fun () -> Eio.Promise.await reply) with
      | Ok response -> response | Error error -> fail error))

let h2_operator_route () = with_fixture (fun env sw config root _directory ->
  Auth.save_auth_config root {Masc_domain.default_auth_config with enabled=true; require_token=true};
  let token name role = match Auth.create_token root ~agent_name:name ~role with
    | Ok (token,_) -> token | Error e -> fail (Masc_domain.masc_error_to_string e) in
  let admin = token "h2-inventory-admin" Masc_domain.Admin in
  let worker = token "h2-inventory-worker" Masc_domain.Worker in
  let state = Mcp_server.For_testing.create_state ~base_path:root in
  let get token = h2_read ~sw ~clock:(Eio.Stdenv.clock env) ~state token in
  let before = files root in
  let status,body = get (Some admin) in
  check int "H2 admin inventory is registered" 200 status;
  let json = Yojson.Safe.from_string body in
  check string "same common projection schema" "masc.lane-inventory/v1" (text "schema" json);
  check (list string) "H2 projects all builtin rows"
    (List.map (fun id -> Lane_id.to_wire (Lane_id.Builtin id)) Lane_id.all_of_builtin)
    (List.map (text "id") (values "rows" json));
  check int "H2 anonymous refused" 401 (fst (get None));
  check int "H2 worker cannot read operator inventory" 403 (fst (get (Some worker)));
  check bool "H2 read leaves package manager unconstructed" false (Addon.inventory ~config).owner_present;
  check bool "H2 read leaves workspace bytes unchanged" true (before=files root))

let retained_binding config id incarnation configuration =
  let masc = Workspace.masc_dir config in
  if not (Sys.file_exists masc) then Unix.mkdir masc 0o700;
  let store = Lane_addon_store.create ~root:(Filename.concat masc "lane-addons") in
  let json = `Assoc ["instance_id",`String id;"incarnation",`String incarnation;"run_id",`String "world";
    "addon_id",`String "observer";"title",`String "Retained observer";"revision",`String "1";
    "phase",Lane_addon_types.phase_to_json (Failed "cleanup incomplete: refused");
      "lifecycle",Lane_addon_lifecycle.state_to_json (Lane_addon_lifecycle.Failed (Lane_addon_lifecycle.failed (Lane_addon_lifecycle.Cleanup_unconfirmed "refused")));"configuration",configuration;
    "visibility",`Assoc ["kind",`String "shared"];
    "source_access",Lane_addon_sources.access_to_json Lane_addon_sources.Unauthenticated] in
  match Lane_addon_store.save_binding store ~instance_id:id json with Ok () -> () | Error e -> fail e

let invalid_config_root () = with_fixture (fun _ _ config root directory ->
  let owned = Filename.concat directory "owned.toml" in
  retained_binding config "managed" "managed"
    (`Assoc ["id",`String "owned";"source_path",`String owned;"revision",`String "r1"]);
  let not_directory = Filename.concat root "ordinary-file" in write not_directory "not a directory";
  List.iter (fun invalid -> with_env "MASC_CONFIG_DIR" invalid (fun () ->
    let observation = Inventory.snapshot ~config |> Inventory.to_json in
    let reading = member "package_read" observation in
    check bool "invalid explicit root is incomplete" false (member "complete" reading |> Yojson.Safe.Util.to_bool);
    check bool "resolver warning is visible" true (values "issues" reading <> []);
    let row = List.find (fun row -> member "source_path" (member "selection" row)=`String owned) (values "rows" observation) in
    check string "retained owner is unobserved, not absent" "unobserved"
      (text "kind" (member "declaration" (member "state" row)))))
    [Filename.concat root "missing-explicit-root";not_directory])

let mismatched_retained_incarnation () = with_fixture (fun _ _ config _ _ ->
  retained_binding config "good" "good" `Null;
  retained_binding config "bad" "another-incarnation" `Null;
  let observed = Addon.inventory ~config in
  check (list string) "valid sibling survives corrupt identity" ["good"]
    (List.map (fun (i : Addon.inventory_instance) -> i.instance_id) observed.instances);
  check bool "bad record is reported" true (observed.issues <> []);
  check bool "bad record makes retained inventory partial" false observed.complete)

let suffix_only_declaration_is_editable () = with_fixture (fun _ _ config root directory ->
  let source_path = Filename.concat directory ".toml" in
  write source_path (declaration (package root) "suffix-only");
  let observed = Inventory.snapshot ~config |> Inventory.to_json in
  check bool "loader exposes suffix-only direct child" true
    (List.exists (fun row -> member "source_path" (member "selection" row)=`String source_path) (values "rows" observed));
  match Lane_addon_declaration.read ~directory ~source_path with
  | Ok document -> check string "same enumerated source can be opened" ".toml" document.file_name
  | Error e -> fail e.message)

(* The server process holds no browser clients since #44295; the built-in
   browser rows read the browser Add-on's cached observation, and say why
   when there is none. *)
let browser_rows_read_the_addon_observation () =
  let work registered = `Assoc ["activity",`String "enabled";"registered",`Bool registered;
    "session",`String "closed";"locate",`Bool false] in
  let client id = `Assoc ["clientId",`String id;"browser",`String "firefox";"version",`String "158.0.1";
    "engineVersion",`String "158.0.1";"transport",`String "web_extension";"space",`Null;"interactions",`List [];"lastActivities",`List [];"spaceObservation",`Null] in
  let output = match Browser_addon_observation.of_snapshot ~observed_at:1.
      (`Assoc ["state",`String "serving";
        "clients",`List [client "01a16363-ef67-7000-ad62-05bcd0320d99"; client "01a16363-ef68-7000-aee1-37e1be230202"];
        "owned_backends",`Assoc ["automation",work true;"stagehand",work false]]) with
    | Ok output -> output | Error detail -> fail detail in
  let snapshot : Addon.export_observation = {instance_id="browser-worker";observation_seq=2;
    max_bytes=4096;refreshing=false;output} in
  let declarations : Config.snapshot = {declarations=[];issues=[];paths=[];complete=true} in
  (* With no browser declaration on, the application status is never asked. *)
  let reading observations = Browser_addon_presence.of_observations ~declarations
      ~applications:(fun () -> fail "only an Add-on declared on and not running asks how it was applied")
      observations in
  (* The automation, Stagehand and external host workers each publish this
     observation; each lane reads its own source's. *)
  let every observation = List.map (fun backend -> {Addon.backend;observation})
      Browser_lane.Backend.[Automation; Stagehand; External_host] in
  let read observation lane = Browser_addon_presence.lane (reading (every observation)) lane in
  let state observation lane = Inventory.For_testing.browser_state
      (read observation lane) lane in
  let observed = Ok (Some snapshot) in
  check bool "the live row counts the clients the Add-on published" true
    (state observed Browser_lane.Lane_name.Live = Inventory.Browser_clients (Inventory.Browser_observed 2));
  check bool "the automation row reads its registration from the Add-on" true
    (state observed Browser_lane.Lane_name.Automation = Inventory.Browser_executor (Inventory.Browser_observed true));
  check bool "the Stagehand row reads its registration from the Add-on" true
    (state observed Browser_lane.Lane_name.Stagehand = Inventory.Browser_executor (Inventory.Browser_observed false));
  check bool "no browser Add-on is not zero connected clients" true
    (state (Ok None) Browser_lane.Lane_name.Live
     = Inventory.Browser_clients (Inventory.Browser_addon_absent));
  let failed : Lane_addon_unready.t = {installation="browser-work";instance_id="browser-worker";package_id="browser";
    declared_tools=[];service=Lane_addon_types.Browser_service Browser_lane.Backend.External_host;reason=Failed {Lane_addon_lifecycle.cause=Cleanup_unconfirmed "cleanup incomplete";first=None}} in
  let refusal = Addon.Unready_installations (failed, []) in
  check bool "a failed browser Add-on shows the operator its failure" true
    (state (Error refusal) Browser_lane.Lane_name.Live
     = Inventory.Browser_clients (
         Inventory.Browser_addon_unavailable (Addon.export_refusal_operator_message refusal)));
  (* The browser lane check reads the same observation: the clients the
     Add-on published are the hosts that poll this server. *)
  check bool "the published clients are the polling hosts" true
    (let observed = read observed Browser_lane.Lane_name.Live in
     match Browser_addon_presence.polling observed, observed with
     | Browser_lane_launcher.Polling clients, Browser_addon_presence.Observed published ->
         clients = published.clients && List.length clients = 2
     | Browser_lane_launcher.(Polling _ | Unlisted _ | Not_observed),
       Browser_addon_presence.(Observed _ | Absent | Off | Not_running _ | Unavailable _) -> false);
  List.iter (fun (name, presence, unlisted) ->
      check bool name true (Browser_addon_presence.polling presence = Browser_lane_launcher.Unlisted unlisted))
    [ "no Add-on lists no host", Browser_addon_presence.Absent, Browser_lane_launcher.No_browser_addon
    ; "an Add-on switched off lists no host", Browser_addon_presence.Off, Browser_lane_launcher.Browser_addon_off
    ; "an Add-on not running lists no host, with what is known of why",
      Browser_addon_presence.Not_running Browser_lane_launcher.Attach_failed,
      Browser_lane_launcher.Browser_addon_not_running Browser_lane_launcher.Attach_failed
    ; "a refused observation is said as any caller may read it",
      Browser_addon_presence.Unavailable (Browser_addon_presence.Refused refusal),
      Browser_lane_launcher.Browser_addon_unreadable (Addon.export_refusal_message refusal) ]

(* Several browser installations, each serving the sources its package
   names: a lane reads only the installations that answer for it, as the
   host uses them, and is unreadable only when none of them published. *)
let browser_lanes_read_their_own_sources () =
  let work registered = `Assoc ["activity",`String "enabled";"registered",`Bool registered;
    "session",`String "closed";"locate",`Bool false] in
  let client id transport =
    let client_id=match Browser_lane.client_id_of_string id with
      | Ok id -> id | Error detail -> fail detail in
    let browser,space=match transport with
      | Browser_lane.Ego_task_space -> Browser_lane.Ego_lite,Some {Browser_lane.id=51;name="Inventory fixture"}
      | Web_extension | Webdriver_bidi -> Browser_lane.Firefox,None in
    let client : Browser_lane.client_info =
      {client_id;browser;version="158.0.1";engine_version="158.0.1";transport;space} in
    Browser_addon_observation.publish_client client ~space_observation:None in
  (* A worker answers its snapshot whatever its package serves; the host
     reads only the sources the package names. *)
  let published clients = match Browser_addon_observation.of_snapshot ~observed_at:1.
      (`Assoc ["state",`String "serving";"clients",`List clients;
        "owned_backends",`Assoc ["automation",work true;"stagehand",work true]]) with
    | Ok output -> Ok (Some ({instance_id="worker";observation_seq=1;max_bytes=4096;refreshing=false;output}
                             : Addon.export_observation))
    | Error detail -> fail detail in
  let serving backend observation = {Addon.backend;observation} in
  let declarations : Config.snapshot = {declarations=[];issues=[];paths=[];complete=true} in
  let state observations lane = Inventory.For_testing.browser_state
      (Browser_addon_presence.lane (Browser_addon_presence.of_observations ~declarations
         ~applications:(fun () -> fail "no browser Add-on is declared") observations) lane) lane in
  (* An automation worker that reports a client: it serves no live source,
     so the live row does not count it. *)
  let automation = serving Browser_lane.Backend.Automation
      (published [client "01a16363-ef6a-7000-aee1-37e1be230204" Browser_lane.Webdriver_bidi])
  and ego = serving Browser_lane.Backend.Ego
      (published [client "01a16363-ef67-7000-ad62-05bcd0320d99" Browser_lane.Ego_task_space])
  and extension = serving Browser_lane.Backend.External_host
      (published [client "01a16363-ef68-7000-aee1-37e1be230202" Browser_lane.Web_extension;
                  client "01a16363-ef69-7000-aee1-37e1be230203" Browser_lane.Web_extension]) in
  let workers = [automation; ego; extension] in
  check bool "the live row counts the clients of every live installation" true
    (state workers Browser_lane.Lane_name.Live = Inventory.Browser_clients (Inventory.Browser_observed 3));
  check bool "the automation row reads the installation that serves automation" true
    (state workers Browser_lane.Lane_name.Automation
     = Inventory.Browser_executor (Inventory.Browser_observed true));
  check bool "a source no installation serves reads as no Add-on, though another worker reported it" true
    (state workers Browser_lane.Lane_name.Stagehand
     = Inventory.Browser_executor (Inventory.Browser_addon_absent));
  (* Two installations of one source reach presence as one ambiguous
     observation: that source's lane cannot be read, and the others read as
     usual. *)
  let ambiguous = Error (Addon.Ambiguous_installations ["first"; "second"]) in
  let is_ambiguous = function
    | Browser_addon_presence.Unavailable (Refused (Addon.Ambiguous_installations _)) -> true
    | Browser_addon_presence.(Unavailable (Refused (Addon.(Unready_installations _ | Not_yet_observed _))
                                           | Observation_unreadable _ | Declarations_incomplete)
                              | Observed _ | Absent | Off | Not_running _) -> false in
  let lane_of observations lane = Browser_addon_presence.lane
      (Browser_addon_presence.of_observations ~declarations ~applications:(fun () -> []) observations) lane in
  let doubled_automation = serving Browser_lane.Backend.Automation ambiguous :: [ego; extension] in
  check bool "a source two installations serve leaves its lane unreadable" true
    (is_ambiguous (lane_of doubled_automation Browser_lane.Lane_name.Automation));
  check bool "the other lanes read as before" true
    (state doubled_automation Browser_lane.Lane_name.Live
     = Inventory.Browser_clients (Inventory.Browser_observed 3));
  (* Two installations of ego beside one of external hosts: the host uses
     no ego client and every external one, and the live row says the same. *)
  let ego_twice = [automation; serving Browser_lane.Backend.Ego ambiguous; extension] in
  check bool "a doubled live source leaves out only its own clients" true
    (state ego_twice Browser_lane.Lane_name.Live
     = Inventory.Browser_clients (Inventory.Browser_observed 2));
  check bool "the browser lane check lists the hosts of the source that still answers" true
    (match Browser_addon_presence.polling (lane_of ego_twice Browser_lane.Lane_name.Live) with
     | Browser_lane_launcher.Polling clients -> List.length clients = 2
     | Browser_lane_launcher.(Unlisted _ | Not_observed) -> false);
  check bool "a live lane whose only source is doubled says so" true
    (is_ambiguous (lane_of [automation; serving Browser_lane.Backend.Ego ambiguous]
                     Browser_lane.Lane_name.Live));
  (* A live installation that withholds its observation has no client the
     host can reach, so the live row counts the others. *)
  let failed : Lane_addon_unready.t = {installation="ego-work";instance_id="ego-worker";package_id="ego";
    declared_tools=[];service=Lane_addon_types.Browser_service Browser_lane.Backend.Ego;
    reason=Failed {Lane_addon_lifecycle.cause=Cleanup_unconfirmed "cleanup incomplete";first=None}} in
  let refusal = Addon.Unready_installations (failed, []) in
  let withheld = [automation; serving Browser_lane.Backend.Ego (Error refusal); extension] in
  check bool "a withheld live installation leaves out only its own clients" true
    (state withheld Browser_lane.Lane_name.Live
     = Inventory.Browser_clients (Inventory.Browser_observed 2));
  check bool "a live lane whose only installation withholds says why" true
    (state [automation; serving Browser_lane.Backend.Ego (Error refusal)] Browser_lane.Lane_name.Live
     = Inventory.Browser_clients (
         Inventory.Browser_addon_unavailable (Addon.export_refusal_operator_message refusal)));
  check bool "and leaves automation as it was" true
    (state withheld Browser_lane.Lane_name.Automation
     = Inventory.Browser_executor (Inventory.Browser_observed true))

(* The live lane with no browser installation running: the declarations
   alone say which absence it is. *)
let live_presence ~declarations ~applications =
  Browser_addon_presence.lane (Browser_addon_presence.of_observations ~declarations ~applications [])
    Browser_lane.Lane_name.Live

(* With no observation, the declarations tell an Add-on nobody declared from
   one switched off and one declared on that is not running. A declaration
   of another kind of package is not a browser Add-on. *)
let browser_absence_reads_the_declarations () = with_fixture (fun _env _sw _config root directory ->
  let browser = Filename.concat root "browser.toml" in
  write browser {|id = "browser"
revision = "1"
title = "Browser"
runtime = "host_process"
service = "browser"
browser_backend = "external_host"
command = ["masc-browser-addon-worker"]
contributions = ["observe"]
[resources]
max_reply_bytes = 4096
|};
  let observer = package root in
  let path = Filename.concat directory "work.toml" in
  let read text =
    write path text;
    let loaded = Config.load ~directory in
    if loaded.issues <> [] then
      fail (String.concat "; " (List.map (fun (issue : Config.issue) -> issue.message) loaded.issues));
    live_presence ~declarations:loaded ~applications:(fun () -> []) in
  check bool "an MCP tools package is not a browser Add-on" true
    (read (declaration observer "observer") = Browser_addon_presence.Absent);
  check bool "a browser Add-on switched off reads as off" true
    (read ("enabled = false\n" ^ declaration browser "browser-work") = Browser_addon_presence.Off);
  check bool "a browser Add-on declared on with no observation is not running" true
    (read (declaration browser "browser-work")
     = Browser_addon_presence.Not_running Browser_lane_launcher.Not_known);
  (* How the maintenance pass applied that declaration says why it is not
     running; an observation of another revision says nothing. *)
  let on = Config.load ~directory in
  let applied ?(revision=fun (d : Config.declaration) -> d.revision) application =
    List.map (fun (d : Config.declaration) ->
      ({owner={id=d.id;source_path=d.source_path;revision=revision d};source_revision=d.source_revision;
        enabled=d.enabled;application} : Addon.configuration_application)) on.declarations in
  let not_running applications =
    live_presence ~declarations:on ~applications:(fun () -> applications) in
  List.iter (fun (name, applications, reason) ->
      check bool name true (not_running applications = Browser_addon_presence.Not_running reason))
    [ "a failed application is a failed attach",
      applied (Lane_addon_application.Failed ["package image missing"]), Browser_lane_launcher.Attach_failed
    ; "a worker being started is attaching", applied Lane_addon_application.Starting_worker,
      Browser_lane_launcher.Attaching
    ; "a worker being replaced is attaching", applied Lane_addon_application.Cleaning_workers,
      Browser_lane_launcher.Attaching
    ; "no application yet is not known", [], Browser_lane_launcher.Not_known
    ; "a failure of an older revision is not this declaration's",
      applied ~revision:(fun _ -> "older") (Lane_addon_application.Failed ["package image missing"]),
      Browser_lane_launcher.Not_known ];
  check bool "a failed application in an incomplete read is not taken for a failed attach" true
    (live_presence ~declarations:{on with complete=false}
       ~applications:(fun () -> applied (Lane_addon_application.Failed ["package image missing"]))
     = Browser_addon_presence.Not_running Browser_lane_launcher.Not_known);
  (* A switched-off browser Add-on beside a declaration that could not be read
     is not proof that none is on: the unread one may be a browser switched on. *)
  write path ("enabled = false\n" ^ declaration browser "browser-work");
  let switched_off = Config.load ~directory in
  check bool "a switched-off browser Add-on in an incomplete read is not taken for off" true
    (match live_presence ~declarations:{switched_off with complete=false}
             ~applications:(fun () -> []) with
     | Browser_addon_presence.Unavailable Browser_addon_presence.Declarations_incomplete -> true
     | Browser_addon_presence.(Unavailable (Refused _ | Observation_unreadable _)
       | Observed _ | Absent | Off | Not_running _) -> false);
  (* Declarations that could not all be read prove no absence. *)
  check bool "an incomplete declaration read is not taken for no Add-on" true
    (match live_presence
             ~declarations:({declarations=[];issues=[];paths=[];complete=false} : Config.snapshot)
             ~applications:(fun () -> []) with
     | Browser_addon_presence.Unavailable Browser_addon_presence.Declarations_incomplete -> true
     | Browser_addon_presence.(Unavailable (Refused _ | Observation_unreadable _)
       | Observed _ | Absent | Off | Not_running _) -> false))

(* With no worker running, each browser Lanes row reads the declarations of
   its own sources. *)
let browser_rows_follow_the_declarations () = with_fixture (fun _env _sw config root directory ->
  let browser = Filename.concat root "browser.toml" in
  write browser {|id = "browser-external"
revision = "1"
title = "Browser"
runtime = "host_process"
service = "browser"
browser_backend = "external_host"
command = ["masc-browser-addon-worker"]
contributions = ["observe"]
[resources]
max_reply_bytes = 4096
|};
  let path = Filename.concat directory "browser-external.toml" in
  let reading lane =
    let id = Lane_id.to_wire (Lane_id.Builtin (Lane_id.Browser lane)) in
    match List.find_opt (fun row -> text "id" row = id)
            (values "rows" (Inventory.snapshot ~config |> Inventory.to_json)) with
    | Some row -> text "kind" (member "addon" (member "state" row))
    | None -> failf "no %s row" id in
  write path (declaration browser "browser-external");
  check string "a live source declared on waits for its worker" "not_running" (reading Browser_lane.Lane_name.Live);
  check string "a lane none of whose sources is declared needs one set up" "absent"
    (reading Browser_lane.Lane_name.Automation);
  write path ("enabled = false\n" ^ declaration browser "browser-external");
  check string "switching its declaration off turns the lane off" "off" (reading Browser_lane.Lane_name.Live))

let () = run "operator lane inventory" ["read boundaries",[
  test_case "machine publication reads worker observations" `Quick machine_publication_reads_worker_observation;
  test_case "machine activity and publication serialize independently" `Quick machine_wire_preserves_both_readings;
  test_case "browser rows follow the declarations" `Quick browser_rows_follow_the_declarations;
  test_case "Browser absence reads the declarations" `Quick browser_absence_reads_the_declarations;
  test_case "browser rows read the Add-on observation" `Quick browser_rows_read_the_addon_observation;
  test_case "browser lanes read their own sources" `Quick browser_lanes_read_their_own_sources;
  test_case "invalid explicit root remains unobserved" `Quick invalid_config_root;
  test_case "retained mismatched incarnation is a per-record issue" `Quick mismatched_retained_incarnation;
  test_case "suffix-only declaration stays editable" `Quick suffix_only_declaration_is_editable;
  test_case "all builtin and invalid/duplicate declarations before reconcile" `Quick before_reconcile;
  test_case "application is bound to exact declaration identity" `Quick application_is_bound_to_the_observed_declaration;
  test_case "retained manual/managed owners survive partial metadata" `Quick retained_metadata;
  test_case "confirmed cleanup leaves history without crowding active inventory" `Quick detached_history;
  test_case "exact outputs follow the manifest, then the tables" `Quick exact_outputs_follow_the_manifest_then_the_tables;
  test_case "HTTP inventory requires operator authority and preserves files" `Quick operator_route;
  test_case "H2 inventory has the same admin gate and projection" `Quick h2_operator_route]]
