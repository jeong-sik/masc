open Alcotest
open Masc_mcp

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_meta_listing_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then
    Fs_compat.set_fs (Eio.Stdenv.fs env)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let write_json path json =
  Out_channel.with_open_bin path (fun oc ->
      output_string oc (Yojson.Safe.pretty_to_string json))

let write_keeper_meta_exn config ~name ~trace_id =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
        ("trace_id", `String trace_id);
        ("goal", `String "test keeper");
      ]
  in
  let meta =
    match Keeper_types.meta_of_json json with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  match Keeper_types.write_meta ~force:true config meta with
  | Ok () -> ()
  | Error e -> fail ("write_meta failed: " ^ e)

let parse_json_exn body =
  try Yojson.Safe.from_string body
  with Yojson.Json_error err -> failwith ("invalid json: " ^ err)

let keeper_ctx env sw config agent_name : _ Tool_keeper.context =
  {
    config;
    agent_name;
    sw;
    clock = Eio.Stdenv.clock env;
    proc_mgr = Some (Eio.Stdenv.process_mgr env);
    net = None;
  }

let test_keeper_listing_ignores_sidecar_json_files () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      write_keeper_meta_exn config ~name:"sangsu" ~trace_id:"trace-sangsu";
      write_keeper_meta_exn config ~name:"dot.name" ~trace_id:"trace-dot-name";
      ignore
        (Keeper_manual_reconcile.open_pending
           config
           ~keeper_name:"sangsu"
           ~blocker_class:"ambiguous_post_commit_failure"
           ~summary:"turn outcome ambiguous"
           ~failure_reason:(Some "manual reconcile required")
           ~trace_id:(Some "trace-sangsu")
           ~generation:(Some 1)
           ~committed_tools:["keeper_bash"]);
      let dataset_path =
        Filename.concat (Keeper_fs.keeper_dir config) "sangsu.dataset.json"
      in
      write_json dataset_path (`Assoc [ ("kind", `String "dataset") ]);
      let names = Keeper_types.keeper_names config in
      check (list string) "keeper_names filters sidecars"
        [ "dot.name"; "sangsu" ] names;
      let keepalive_names = Keeper_types.keepalive_keeper_names config in
      check (list string) "keepalive_keeper_names filters sidecars"
        [ "dot.name"; "sangsu" ] keepalive_names;
      let ctx = keeper_ctx env sw config "operator" in
      let ok, body =
        Keeper_status.handle_keeper_list ctx (`Assoc [ ("limit", `Int 10) ])
      in
      check bool "keeper status list ok" true ok;
      let json = parse_json_exn body in
      let listed =
        Yojson.Safe.Util.(json |> member "keepers" |> to_list |> filter_string)
      in
      check (list string) "status handler filters sidecars"
        [ "dot.name"; "sangsu" ] listed;
      check int "status handler count filters sidecars" 2
        Yojson.Safe.Util.(json |> member "count" |> to_int))

(** bootable_keeper_names excludes JSON-only keepers with total_turns=0
    (phantom keepers from old test runs) but keeps JSON-only keepers
    that have actually run (total_turns > 0). *)
let test_bootable_keeper_names_filters_phantom_keepers () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      (* Create a phantom keeper: JSON only, total_turns=0 *)
      write_keeper_meta_exn config ~name:"phantom-test" ~trace_id:"trace-phantom";
      (* Create a real keeper: JSON only, total_turns > 0 *)
      write_keeper_meta_exn config ~name:"real-test" ~trace_id:"trace-real";
      (match Keeper_types.read_meta config "real-test" with
       | Ok (Some meta) ->
         let updated =
           Keeper_types.map_usage
             (fun u -> { u with total_turns = 5 })
             meta
         in
         (match Keeper_types.write_meta ~force:true config updated with
          | Ok () -> ()
          | Error e -> fail ("write_meta for real-test failed: " ^ e))
       | Ok None -> fail "real-test meta not found"
       | Error e -> fail ("read_meta for real-test failed: " ^ e));
      (* keeper_names should list both (it scans all JSON files in keepers dir) *)
      let all_names = Keeper_types.keeper_names config in
      check bool "keeper_names includes phantom-test" true
        (List.mem "phantom-test" all_names);
      check bool "keeper_names includes real-test" true
        (List.mem "real-test" all_names);
      (* bootable_keeper_names should exclude the phantom but keep real-test *)
      let bootable = Keeper_runtime.bootable_keeper_names config in
      check bool "bootable excludes phantom-test (total_turns=0, no TOML)" false
        (List.mem "phantom-test" bootable);
      check bool "bootable includes real-test (total_turns>0)" true
        (List.mem "real-test" bootable))

let () =
  run "keeper_meta_listing"
    [
      ( "listing",
        [
          test_case "keeper_names and keeper_list ignore sidecar json" `Quick
            test_keeper_listing_ignores_sidecar_json_files;
          test_case "bootable_keeper_names filters phantom keepers" `Quick
            test_bootable_keeper_names_filters_phantom_keepers;
        ] );
    ]
