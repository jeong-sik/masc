(** #9733 keeper_msg turn migration: pin the contract that
    [Keeper_types.write_meta_with_merge ~merge:heartbeat_fields_from_disk]
    actually retains the disk-owned heartbeat fields after a CAS
    retry, while letting the caller's payload win at the cycle-owned
    fields.

    The 2026-04-25 audit identified [keeper_turn.ml:470] (the
    keeper_msg turn-completion path) as the last bare [write_meta]
    call in turn-completion code.  The fix migrates it to
    [write_meta_with_merge] using the same [heartbeat_fields_from_disk]
    merge that [keeper_unified_turn.ml:1683] already uses.  This test
    pins both halves of that merge so a future refactor of
    [Keeper_meta_merge.heartbeat_fields_from_disk] cannot silently
    regress either side.

    The existing [test_keeper_meta_cas_retry.ml] verifies retry
    succeeds; this test additionally verifies field ownership. *)

open Alcotest
open Masc_mcp

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_meta_hb_" "" in
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

let make_meta ~name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("goal", `String "test keeper");
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Ok m -> m
  | Error e -> fail ("meta_of_json failed: " ^ e)

let read_meta_exn config name =
  match Keeper_types.read_meta config name with
  | Ok (Some meta) -> meta
  | Ok None -> fail ("read_meta returned None for " ^ name)
  | Error err -> fail ("read_meta failed: " ^ err)

let room_cursor meta room_id =
  meta.Keeper_types.last_seen_seq_by_room
  |> List.find_map (fun (rid, seq) ->
       if String.equal rid room_id then Some seq else None)
  |> Option.value ~default:0

(* The race we model:

   - cycle fiber reads meta at version N (joined_room_ids=[r1])
   - heartbeat fiber bumps disk to version N+1 with
     joined_room_ids=[r1; r2]
   - cycle fiber writes its payload (goal="cycle done") with the
     stale joined_room_ids=[r1]

   After [write_meta_with_merge ~merge:heartbeat_fields_from_disk]:

   - on-disk goal must be "cycle done"  (caller wins)
   - on-disk joined_room_ids must be [r1; r2]  (disk wins)
   - on-disk meta_version must be > N+1       (we wrote past it) *)
let test_caller_wins_cycle_disk_wins_heartbeat () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Coord.default_config base_dir in
    ignore (Coord.init config ~agent_name:(Some "operator"));
    let name = "race9733" in
    let m0 =
      let m = make_meta ~name in
      { m with joined_room_ids = ["r1"] }
    in
    (match Keeper_types.write_meta ~force:true config m0 with
     | Ok () -> ()
     | Error e -> fail ("seed write failed: " ^ e));
    let caller_view = match Keeper_types.read_meta config name with
      | Ok (Some m) -> m
      | _ -> fail "seed read failed"
    in
    (* Heartbeat fiber: bumps version, adds room. *)
    let heartbeat_payload =
      { caller_view with joined_room_ids = ["r1"; "r2"] }
    in
    (match Keeper_types.write_meta config heartbeat_payload with
     | Ok () -> ()
     | Error e -> fail ("heartbeat write failed: " ^ e));
    (* Cycle fiber: had stale joined_room_ids; writes its own
       cycle payload. *)
    let cycle_payload =
      { caller_view with goal = "cycle done" }
    in
    let before_retry_metric =
      Prometheus.metric_value_or_zero
        Prometheus.metric_write_meta_cas_retry_total
        ~labels:[("keeper_name", name)]
        ()
    in
    (match
       Keeper_types.write_meta_with_merge
         ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
         config cycle_payload
     with
     | Ok () -> ()
     | Error e -> fail ("merged retry failed: " ^ e));
    let after_retry_metric =
      Prometheus.metric_value_or_zero
        Prometheus.metric_write_meta_cas_retry_total
        ~labels:[("keeper_name", name)]
        ()
    in
    let final = match Keeper_types.read_meta config name with
      | Ok (Some m) -> m
      | _ -> fail "final read failed"
    in
    check string "caller wins: goal" "cycle done" final.goal;
    check (list string)
      "disk wins: joined_room_ids preserved heartbeat update"
      ["r1"; "r2"] final.joined_room_ids;
    check bool "version moved past heartbeat write" true
      (final.meta_version > heartbeat_payload.meta_version);
    check (float 0.001) "CAS retry metric increments for merge" 1.0
      (after_retry_metric -. before_retry_metric))

(* Sanity: when no concurrent writer interferes, the merge function
   is never called and behaviour matches plain
   [write_meta_with_retry]. *)
let test_no_race_writes_first_attempt () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Coord.default_config base_dir in
    ignore (Coord.init config ~agent_name:(Some "operator"));
    let m0 = make_meta ~name:"smooth9733" in
    (match
       Keeper_types.write_meta_with_merge
         ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
         config m0
     with
     | Ok () -> ()
     | Error e -> fail ("first write failed: " ^ e));
    let on_disk = match Keeper_types.read_meta config "smooth9733" with
      | Ok (Some m) -> m
      | _ -> fail "read failed"
    in
    check string "goal landed" "test keeper" on_disk.goal)

let test_message_cursor_updates_persist_before_turn () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Coord.default_config base_dir in
    ignore (Coord.init config ~agent_name:(Some "operator"));
    let name = "cursor-preturn" in
    let seed =
      let m = make_meta ~name in
      {
        m with
        joined_room_ids = [ "default" ];
        last_seen_seq_by_room = [ ("default", 0) ];
      }
    in
    (match Keeper_types.write_meta ~force:true config seed with
     | Ok () -> ()
     | Error e -> fail ("seed write failed: " ^ e));
    let before = read_meta_exn config name in
    let returned =
      Keeper_heartbeat_loop.persist_message_cursor_updates
        ~config before [ ("default", 42) ]
    in
    let final = read_meta_exn config name in
    check int "returned cursor advanced" 42 (room_cursor returned "default");
    check int "disk cursor advanced before turn" 42 (room_cursor final "default");
    check int "returned version follows disk" final.meta_version returned.meta_version;
    check bool "version bumped" true (final.meta_version > before.meta_version))

let test_message_cursor_updates_merge_after_cas_race () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Coord.default_config base_dir in
    ignore (Coord.init config ~agent_name:(Some "operator"));
    let name = "cursor-cas-race" in
    let seed =
      let m = make_meta ~name in
      {
        m with
        joined_room_ids = [ "default" ];
        last_seen_seq_by_room = [ ("default", 0) ];
        goal = "seed";
      }
    in
    (match Keeper_types.write_meta ~force:true config seed with
     | Ok () -> ()
     | Error e -> fail ("seed write failed: " ^ e));
    let observer_view = read_meta_exn config name in
    let racing_payload =
      { observer_view with goal = "concurrent writer wins other fields" }
    in
    (match Keeper_types.write_meta config racing_payload with
     | Ok () -> ()
     | Error e -> fail ("racing write failed: " ^ e));
    let returned =
      Keeper_heartbeat_loop.persist_message_cursor_updates
        ~config observer_view [ ("default", 99) ]
    in
    let final = read_meta_exn config name in
    check string "concurrent field retained"
      "concurrent writer wins other fields" final.goal;
    check int "disk cursor advanced after CAS retry" 99
      (room_cursor final "default");
    check int "returned cursor advanced after CAS retry" 99
      (room_cursor returned "default");
    check bool "version moved past racing write" true
      (final.meta_version > racing_payload.meta_version))

let () =
  run "Keeper meta heartbeat-retain merge (#9733)"
    [
      ( "merge-contract",
        [
          test_case "caller wins cycle, disk wins heartbeat" `Quick
            test_caller_wins_cycle_disk_wins_heartbeat;
          test_case "no race: first attempt succeeds" `Quick
            test_no_race_writes_first_attempt;
          test_case "message cursor persists before turn" `Quick
            test_message_cursor_updates_persist_before_turn;
          test_case "message cursor merge survives CAS race" `Quick
            test_message_cursor_updates_merge_after_cas_race;
        ] );
    ]
