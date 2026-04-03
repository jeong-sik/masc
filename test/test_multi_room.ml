(** Multi-room tests — reduced to flat namespace verification after #4638. *)

open Alcotest
open Masc_mcp

let with_config f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-current-room-%06x" (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm path =
        if Sys.file_exists path then
          if Sys.is_directory path then begin
            Sys.readdir path
            |> Array.iter (fun name -> rm (Filename.concat path name));
            Unix.rmdir path
          end else Unix.unlink path
      in
      rm dir)
    (fun () ->
      let config = Room.default_config dir in
      ignore (Room.init config ~agent_name:None);
      f config)

let select_room config room_id =
  Room.write_current_room config room_id;
  Room.ensure_room_bootstrap config room_id;
  Room.config_with_resolved_scope config

let test_current_room_defaults_to_default () =
  with_config (fun config ->
      check (option string) "default room" (Some "default")
        (Room.read_current_room config))

let test_current_room_write_and_resolve_scope () =
  with_config (fun config ->
      let focused = select_room config "focus-room" in
      check (option string) "compat pointer stays default" (Some "default")
        (Room.read_current_room config);
      check string "resolved scope stays default" "default"
        (Room.activity_room_id focused);
      check bool "focused scope initialized" true (Room.is_initialized focused))

let test_current_room_writes_stay_canonical () =
  with_config (fun config ->
      let focused = select_room config "focus-room" in
      ignore (Room.add_task focused ~title:"focus task" ~priority:1 ~description:"");
      check int "default namespace task count" 1
        (List.length (Room.get_tasks_raw config));
      check int "default room task count" 1
        (List.length (Room.get_tasks_raw_in_room config "default"));
      check int "compat room task count is flattened" 1
        (List.length (Room.get_tasks_raw_in_room config "focus-room")))

let () =
  run "current_room_compat"
    [
      ( "current_room",
        [
          test_case "defaults to default" `Quick test_current_room_defaults_to_default;
          test_case "write and resolve scope" `Quick test_current_room_write_and_resolve_scope;
          test_case "writes stay canonical" `Quick test_current_room_writes_stay_canonical;
        ] );
    ]
