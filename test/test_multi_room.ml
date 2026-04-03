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

let test_current_room_defaults_to_default () =
  with_config (fun config ->
      check (option string) "default room" (Some "default")
        (Room.read_current_room config))

let test_write_current_room_updates_label () =
  with_config (fun config ->
      Room.write_current_room config "focus-room";
      check (option string) "current room label updated" (Some "focus-room")
        (Room.read_current_room config))

let () =
  run "current_room_compat"
    [
      ( "current_room",
        [
          test_case "defaults to default" `Quick
            test_current_room_defaults_to_default;
          test_case "write updates label" `Quick
            test_write_current_room_updates_label;
        ] );
    ]
