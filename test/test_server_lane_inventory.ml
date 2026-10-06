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
  let builtin = rows |> List.filter (fun row -> match text "kind" (member "selection" row) with
    | "exact" | "browser" | "machine" -> true | _ -> false) |> List.map (text "id") in
  check (list string) "every derived builtin, in its own order"
    (List.map (fun id -> Lane_id.to_wire (Lane_id.Builtin id)) Lane_id.all_of_builtin) builtin;
  List.iter (fun (path,expected) ->
    let row = List.find (fun row -> member "source_path" (member "selection" row)=`String path) rows in
    check string "file is discoverable before reconcile" expected
      (text "kind" (member "declaration" (member "state" row))))
    [good,"valid";broken,"invalid";first,"invalid";second,"invalid"];
  check bool "reading did not create a runtime manager" false
    (member "owner_present" (member "package_read" json) |> Yojson.Safe.Util.to_bool);
  check bool "no file bytes changed" true (before=files root);
  check bool "no runtime store directory was created" false
    (Sys.file_exists (Filename.concat (Workspace.masc_dir config) "lane-addons"));
  let again = Addon.inventory ~config in
  check bool "repeated read still has no manager" false again.owner_present;
  check int "same capture includes every exact detail" (List.length Standalone_lane.all)
    (List.length (values "lanes" (member "exact_snapshot" json))))

let retained_metadata () = with_fixture (fun _env _sw config root directory ->
  let masc = Workspace.masc_dir config in Unix.mkdir masc 0o700;
  let store_root = Filename.concat masc "lane-addons" in
  let store = Lane_addon_store.create ~root:store_root in
  let put id configuration =
    let json = `Assoc ["instance_id",`String id;"incarnation",`String id;"run_id",`String "world";
      "addon_id",`String "observer";"title",`String "Retained observer";"revision",`String "1";
      "phase",Lane_addon_types.phase_to_json (Failed "cleanup incomplete");"configuration",configuration;
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
  let rows = Inventory.For_testing.package_rows ~declarations:(Config.load ~directory) ~instances:owner.instances in
  check bool "manual selection keeps exact incarnation" true
    (List.exists (fun (row : Inventory.row) -> row.selection=Inventory.Manual_instance {instance_id="manual";incarnation="manual"}) rows);
  let removed = List.find (fun (row : Inventory.row) -> row.selection=Inventory.Declaration path) rows in
  (match removed.state with
   | Inventory.Package_state {declaration=Some Absent;instances=[i]} ->
       check bool "cleanup failure is retained" true (i.phase=Lane_addon_types.Failed "cleanup incomplete")
   | _ -> fail "retained declaration owner disappeared");
  let incomplete : Config.snapshot = {declarations=[];paths=[];issues=[];complete=false} in
  let rows = Inventory.For_testing.package_rows ~declarations:incomplete ~instances:owner.instances in
  check bool "partial read cannot claim declaration deletion" true
    (List.exists (fun (r : Inventory.row) -> match r.state with
      | Inventory.Package_state {declaration=Some Unobserved;_} -> true | _ -> false) rows);
  check bool "metadata read did not change evidence bytes" true (before=files root))

let detached_history () =
  let path = "/fixture/completed.toml" in
  let detached : Addon.inventory_instance = {instance_id="old";incarnation="old";run_id="world";
    package_id="observer";title="Old observer";package_revision="1";
    configuration=Some {id="completed";source_path=path;revision="1"};
    presence=Retained;phase=Detached} in
  let manual = {detached with instance_id="manual-old";incarnation="manual-old";configuration=None} in
  let empty : Config.snapshot = {declarations=[];paths=[];issues=[];complete=true} in
  let rows declarations = Inventory.For_testing.package_rows ~declarations ~instances:[detached;manual] in
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

let h2_read ~sw ~clock ~state token =
  let trust_policy = match Server_request_authority.make_trust_policy
    ~bind_host:"127.0.0.1" ~bind_port:8935 ~explicit_base_url:None with
    | Ok value -> value | Error error -> fail (Server_request_authority.trust_policy_error_to_string error) in
  let previous = Server_auth.For_testing.snapshot_server_state () in
  Server_auth.publish_server_state state;
  Fun.protect ~finally:(fun () -> Server_auth.For_testing.restore_server_state previous) (fun () ->
    let server_flow,client_flow = Eio_unix.Net.socketpair_stream ~sw () in
    let gateway = Server_h2_gateway.make_request_handler ~trust_policy ~sw ~clock ~server_start_time:0. in
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
    "phase",Lane_addon_types.phase_to_json (Failed "cleanup incomplete");"configuration",configuration;
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

let () = run "operator lane inventory" ["read boundaries",[
  test_case "invalid explicit root remains unobserved" `Quick invalid_config_root;
  test_case "retained mismatched incarnation is a per-record issue" `Quick mismatched_retained_incarnation;
  test_case "suffix-only declaration stays editable" `Quick suffix_only_declaration_is_editable;
  test_case "all builtin and invalid/duplicate declarations before reconcile" `Quick before_reconcile;
  test_case "retained manual/managed owners survive partial metadata" `Quick retained_metadata;
  test_case "confirmed cleanup leaves history without crowding active inventory" `Quick detached_history;
  test_case "HTTP inventory requires operator authority and preserves files" `Quick operator_route;
  test_case "H2 inventory has the same admin gate and projection" `Quick h2_operator_route]]
