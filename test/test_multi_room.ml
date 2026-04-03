(** Multi-room tests — reduced to flat namespace verification after #4638. *)

open Alcotest
open Masc_mcp

let str_contains s substring =
  let len_s = String.length s in
  let len_sub = String.length substring in
  if len_sub > len_s then false
  else
    let rec loop i =
      if i > len_s - len_sub then false
      else if String.sub s i len_sub = substring then true
      else loop (i + 1)
    in
    loop 0

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

let read_lines path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let rec loop acc =
        match input_line ic with
        | line -> loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])

let current_event_log_path config =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Filename.concat
    (Filename.concat
       (Filename.concat (Room.masc_dir config) "events")
       (Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)))
    (Printf.sprintf "%02d.jsonl" tm.tm_mday)

let test_join_in_room_sanitizes_invalid_room_id () =
  with_config (fun config ->
      let captured_room_id = ref None in
      let previous_hook = !Room_hooks.observe_agent_lifecycle_fn in
      Fun.protect
        ~finally:(fun () -> Room_hooks.observe_agent_lifecycle_fn := previous_hook)
        (fun () ->
          Room_hooks.observe_agent_lifecycle_fn :=
            (fun _config ~agent_id:_ ~room_id ~event_kind:_ ~details:_ ->
              captured_room_id := Some room_id);
          let result =
            Room.join_in_room config ~room_id:"bad\"\nroom" ~agent_name:"claude"
              ~capabilities:[ "debug" ] ()
          in
          check bool "result uses sanitized room label" true
            (str_contains result "room default");
          check (option string) "hook sees sanitized room label" (Some "default")
            !captured_room_id;
          let event_log = current_event_log_path config in
          let last_event = read_lines event_log |> List.rev |> List.hd in
          let room_id =
            Yojson.Safe.from_string last_event
            |> Yojson.Safe.Util.member "room_id"
            |> Yojson.Safe.Util.to_string
          in
          check string "event room_id sanitized" "default" room_id))

let () =
  run "current_room_compat"
    [
      ( "current_room",
        [
          test_case "defaults to default" `Quick
            test_current_room_defaults_to_default;
          test_case "write updates label" `Quick
            test_write_current_room_updates_label;
          test_case "join_in_room sanitizes invalid room id" `Quick
            test_join_in_room_sanitizes_invalid_room_id;
        ] );
    ]
