open Alcotest
open Masc

module Inventory = Server_lane_inventory
module Addon = Lane_addon_runtime

let empty_inventory : Addon.inventory =
  { owner_present = true; instances = []; issues = []; complete = true; applications = [] }

let declarations : Lane_addon_config.snapshot =
  { declarations = []; paths = []; issues = []; complete = true }

let work registered = `Assoc
  [ "activity", `String "enabled"; "registered", `Bool registered
  ; "session", `String "closed"; "locate", `Bool false ]

let client id = `Assoc
  [ "clientId", `String id; "browser", `String "ego_lite"
  ; "version", `String "0.6.2.7"; "engineVersion", `String "154.0.8037.44"
  ; "transport", `String "ego_task_space"
  ; "space", `Assoc [ "id", `Int (Hashtbl.hash id mod 1000); "name", `String "fixture Space" ]
  ; "interactions", `List []; "lastActivities", `List []
  ; "spaceObservation", `Null; "spacePresence", `Null ]

let client_a = "01a16363-ef67-7000-ad62-05bcd0320d99"
let client_b = "01a16363-ef68-7000-aee1-37e1be230202"

let browser clients =
  let output = match Browser_addon_observation.of_snapshot ~observed_at:1.
      (`Assoc
        [ "state", `String "serving"
        ; "clients", `List (List.map client clients)
        ; "owned_backends", `Assoc [ "automation", work true ] ])
  with Ok output -> output | Error detail -> fail detail in
  { Addon.backend = Browser_lane.Backend.Ego
  ; observation = Ok (Some { instance_id = "worker"; observation_seq = 1
      ; max_bytes = 4096; refreshing = false; output }) }

let runtime_snapshot config observations =
  Inventory.For_testing.runtime_snapshot ~config ~declarations
    ~inventory:empty_inventory ~browser_observations:observations

let with_workspace f =
  let base = Filename.temp_dir "lane-notifications" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () -> f base))))

let test_merged_browser_clients_drive_the_notification () = with_workspace (fun base ->
  let config = Workspace.default_config base in
  let before = runtime_snapshot config [browser [client_a; client_b]] in
  let after = runtime_snapshot config [browser [client_b]; browser [client_b]] in
  let heard = ref 0 in
  let id = "merged-browser-projection" in
  Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path:base)
    ~id ~callback:(fun (_ : Sse.external_event) -> incr heard) ();
  Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
    check bool "duplicate client identities change the displayed count" true
      (Inventory.For_testing.publish_if_changed ~base_path:base (Some before) after);
    check int "the changed projection announces once" 1 !heard;
    check bool "an unchanged projection stays quiet" false
      (Inventory.For_testing.publish_if_changed ~base_path:base (Some after) after);
    check int "no redundant Lanes notification" 1 !heard))

let retained phase : Addon.inventory_instance =
  { instance_id = "old"; incarnation = "old"; run_id = "world"
  ; package_id = "observer"; title = "Old observer"; package_revision = "1"
  ; ui_category = None; configuration = None; presence = Addon.Retained; phase }

let test_retained_removal_drives_the_notification () = with_workspace (fun base ->
  let config = Workspace.default_config base in
  let before = Inventory.For_testing.runtime_snapshot ~config ~declarations
      ~inventory:{ empty_inventory with instances = [retained (Lane_addon_types.Failed "cleanup")] }
      ~browser_observations:[] in
  let after = Inventory.For_testing.runtime_snapshot ~config ~declarations
      ~inventory:{ empty_inventory with instances = [retained Lane_addon_types.Detached] }
      ~browser_observations:[] in
  check bool "a retained failure becoming confirmed detached changes the rows" true
    (Inventory.For_testing.publish_if_changed ~base_path:base (Some before) after))

let test_declaration_addition_drives_the_notification () = with_workspace (fun base ->
  let config = Workspace.default_config base in
  let manifest = Filename.concat base "observer.toml" in
  Out_channel.with_open_bin manifest (fun channel -> output_string channel
    "id = \"observer\"\nrevision = \"1\"\ntitle = \"Observer\"\nimage = \"fixture\"\ncommand = [\"worker\"]\ncontributions = [\"observe\"]\n[resources]\nmax_reply_bytes = 4096\n");
  let source_path = Filename.concat base "declaration.toml" in
  Out_channel.with_open_bin source_path (fun channel -> output_string channel
    (Printf.sprintf "id = \"observer\"\nrun_id = \"world\"\nmanifest_path = %S\n[binding]\nsources = []\n" manifest));
  let directory = Filename.concat base "lane-addons" in
  Unix.mkdir directory 0o700;
  Unix.rename source_path (Filename.concat directory "observer.toml");
  let declarations = Lane_addon_config.load ~directory in
  let before = runtime_snapshot config [] in
  let after = Inventory.For_testing.runtime_snapshot ~config ~declarations
      ~inventory:empty_inventory ~browser_observations:[] in
  check bool "a declaration-only row changes the served projection" true
    (Inventory.For_testing.publish_if_changed ~base_path:base (Some before) after))

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Config_dir_resolver.reset ();
  Fun.protect ~finally:(fun () ->
    (match previous with Some value -> Unix.putenv name value | None -> Unix.unsetenv name);
    Config_dir_resolver.reset ()) f

let write_declaration base =
  let config_root = Filename.concat base ".masc/config" in
  Fs_compat.mkdir_p (Filename.concat config_root "lane-addons");
  let manifest = Filename.concat base "observer.toml" in
  Out_channel.with_open_bin manifest (fun channel -> output_string channel
    "id = \"observer\"\nrevision = \"1\"\ntitle = \"Observer\"\nimage = \"fixture\"\ncommand = [\"worker\"]\ncontributions = [\"observe\"]\n[resources]\nmax_reply_bytes = 4096\n");
  Out_channel.with_open_bin (Filename.concat config_root "lane-addons/observer.toml")
    (fun channel -> output_string channel
      (Printf.sprintf "id = \"observer\"\nrun_id = \"world\"\nmanifest_path = %S\n[binding]\nsources = []\n" manifest))

let with_config base f =
  with_env "MASC_CONFIG_DIR" (Filename.concat base ".masc/config") (fun () ->
    with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true" f)

let test_configuration_passes_do_not_publish_fresh_clocks () = with_workspace (fun base ->
  with_config base (fun () ->
    let config = Workspace.default_config base in
    ignore (Inventory.snapshot ~config);
    let heard = ref 0 in
    let id = "configuration-clocks" in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path:base)
      ~id ~callback:(fun (_ : Sse.external_event) -> incr heard) ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      Inventory.refresh ~base_path:base Addon.Configuration_changed;
      Inventory.refresh ~base_path:base Addon.Configuration_changed;
      check int "fresh observation clocks do not produce a redundant event" 0 !heard)))

let test_snapshot_does_not_consume_an_unannounced_change () = with_workspace (fun base ->
  with_config base (fun () ->
    let config = Workspace.default_config base in
    ignore (Inventory.snapshot ~config);
    write_declaration base;
    ignore (Inventory.snapshot ~config);
    let heard = ref 0 in
    let id = "snapshot-pending-change" in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path:base)
      ~id ~callback:(fun (_ : Sse.external_event) -> incr heard) ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      Inventory.refresh ~base_path:base Addon.Observation_commit;
      check int "the observer still publishes the pending projection change" 1 !heard)))

let test_live_and_retained_identity_matches_the_full_inventory () =
  let failed = retained (Lane_addon_types.Failed "cleanup") in
  let live = { failed with presence = Addon.Live; phase = Lane_addon_types.Attached } in
  let merged = Inventory.For_testing.merge_inventory
      ~live:{ empty_inventory with instances = [live] }
      ~retained:{ empty_inventory with instances = [failed] } in
  check int "a retained instance becoming live appears once" 1
    (List.length merged.instances);
  match merged.instances with
  | [item] ->
      check bool "the live identity wins and remains ordered" true
        (item.instance_id = "old" && item.phase = Lane_addon_types.Attached)
  | [] | _ :: _ :: _ -> fail "expected one live instance"

let () =
  run "Lane inventory notifications"
    [ "served projection",
      [ test_case "merged browser clients decide Lanes freshness" `Quick
          test_merged_browser_clients_drive_the_notification
      ; test_case "retained removal decides Lanes freshness" `Quick
          test_retained_removal_drives_the_notification
      ; test_case "declaration changes decide Lanes freshness" `Quick
          test_declaration_addition_drives_the_notification
      ; test_case "configuration timestamps do not announce unchanged state" `Quick
          test_configuration_passes_do_not_publish_fresh_clocks
      ; test_case "snapshots preserve unannounced changes" `Quick
          test_snapshot_does_not_consume_an_unannounced_change
      ; test_case "live and retained instances share full identity semantics" `Quick
          test_live_and_retained_identity_matches_the_full_inventory ] ]
