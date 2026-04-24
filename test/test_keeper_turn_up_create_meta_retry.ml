(* #9749: keeper bootstrap metadata writes must survive a concurrent
   heartbeat/supervisor version bump. *)

open Alcotest
open Masc_mcp

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_bootstrap_meta_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let rec cleanup_dir path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter
        (fun name -> cleanup_dir (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then
    Fs_compat.set_fs (Eio.Stdenv.fs env)

let make_meta ~name =
  match
    Keeper_types.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("goal", `String "bootstrap seed");
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let read_meta_exn config name =
  match Keeper_types.read_meta config name with
  | Ok (Some meta) -> meta
  | Ok None -> fail ("missing meta for " ^ name)
  | Error err -> fail ("read_meta failed: " ^ err)

let write_meta_exn config meta =
  match Keeper_types.write_meta config meta with
  | Ok () -> ()
  | Error err -> fail ("write_meta failed: " ^ err)

let test_bootstrap_write_retries_and_preserves_heartbeat_fields () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let seed = make_meta ~name:"bootstrap-race" in
      write_meta_exn config seed;
      let bootstrap_view = read_meta_exn config "bootstrap-race" in

      let heartbeat_write =
        {
          bootstrap_view with
          joined_room_ids = [ "live-room" ];
          last_seen_seq_by_room = [ ("live-room", 42) ];
        }
      in
      write_meta_exn config heartbeat_write;

      let bootstrap_payload =
        {
          bootstrap_view with
          goal = "bootstrap payload wins";
          joined_room_ids = [];
          last_seen_seq_by_room = [];
        }
      in
      (match
         Keeper_turn_up_create.write_initial_meta config bootstrap_payload
       with
       | Ok () -> ()
       | Error err -> fail ("write_initial_meta failed: " ^ err));

      let final = read_meta_exn config "bootstrap-race" in
      check string "bootstrap-owned field wins"
        "bootstrap payload wins" final.goal;
      check (list string) "heartbeat rooms preserved"
        [ "live-room" ] final.joined_room_ids;
      check (list (pair string int)) "heartbeat cursors preserved"
        [ ("live-room", 42) ] final.last_seen_seq_by_room;
      check bool "version advanced past heartbeat write" true
        (final.meta_version > heartbeat_write.meta_version))

let () =
  run "keeper_turn_up_create bootstrap meta CAS retry"
    [
      ( "write_initial_meta",
        [
          test_case
            "retries stale bootstrap write and keeps heartbeat fields"
            `Quick
            test_bootstrap_write_retries_and_preserves_heartbeat_fields;
        ] );
    ]
