open Alcotest
open Masc_mcp

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-current-room-%06x" (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end else
        Unix.unlink path
  in
  rm dir

let with_config f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Room.default_config dir in
      ignore (Room.init config ~agent_name:None);
      f config)

let select_room config room_id =
  Room.write_current_room config room_id;
  Room.ensure_room_bootstrap config room_id;
  Room.with_scope config (Room.Named room_id)

let test_current_room_defaults_to_default () =
  with_config (fun config ->
      check (option string) "default room" (Some "default")
        (Room.read_current_room config))

let test_current_room_write_and_resolve_scope () =
  with_config (fun config ->
      let focused = select_room config "focus-room" in
      check (option string) "compat pointer stays default" (Some "default")
        (Room.read_current_room config);
      check string "named scope remains explicit" "focus-room"
        (Room.activity_room_id focused);
      check bool "focused scope initialized" true (Room.is_initialized focused))

let test_current_room_tasks_are_isolated () =
  with_config (fun config ->
      ignore (Room.add_task config ~title:"default task" ~priority:2 ~description:"");
      let focused = select_room config "focus-room" in
      ignore (Room.add_task focused ~title:"focus task" ~priority:1 ~description:"");
      check int "default room task count" 1
        (List.length (Room.get_tasks_raw_in_room config "default"));
      check int "focus room task count" 1
        (List.length (Room.get_tasks_raw_in_room config "focus-room"));
      check int "default namespace task count remains canonical" 1
        (List.length (Room.get_tasks_raw config)))

let test_current_room_agents_are_isolated () =
  with_config (fun config ->
      ignore (Room.join config ~agent_name:"default-agent" ~capabilities:[] ());
      let focused = select_room config "focus-room" in
      ignore (Room.join focused ~agent_name:"focus-agent" ~capabilities:[] ());
      check (option string) "compat pointer still default" (Some "default")
        (Room.read_current_room config);
      check int "default room agent count" 1
        (List.length (Room.get_agents_raw_in_room config "default"));
      check int "focus room agent count" 1
        (List.length (Room.get_agents_raw_in_room config "focus-room")))

let () =
  run "current_room_compat"
    [
      ( "current_room",
        [
          test_case "defaults to default" `Quick test_current_room_defaults_to_default;
          test_case "write and resolve scope" `Quick test_current_room_write_and_resolve_scope;
          test_case "tasks are isolated" `Quick test_current_room_tasks_are_isolated;
          test_case "agents are isolated" `Quick test_current_room_agents_are_isolated;
        ] );
    ]
