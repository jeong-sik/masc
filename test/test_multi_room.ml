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

let select_room config room_id =
  Room.write_current_room config room_id;
  Room.ensure_room_bootstrap config room_id;
  config

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

(* Find the most recent .jsonl event file under .masc/events/ rather than
   computing the path from wall-clock time, which is racy around UTC
   day/month boundaries (#4792 review). *)
let find_latest_event_log config =
  let events_dir = Filename.concat (Room.masc_dir config) "events" in
  let rec collect_jsonl dir =
    if not (Sys.file_exists dir) then []
    else
      Sys.readdir dir |> Array.to_list
      |> List.concat_map (fun name ->
           let path = Filename.concat dir name in
           if Sys.is_directory path then collect_jsonl path
           else if Filename.check_suffix name ".jsonl" then [ path ]
           else [])
  in
  let files = collect_jsonl events_dir in
  match List.sort (fun a b -> compare b a) files with
  | latest :: _ -> Some latest
  | [] -> None

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
          check bool "result uses sanitized namespace label" true
            (str_contains result "namespace default");
          check bool "result omits legacy room label" false
            (str_contains result "room default");
          check (option string) "hook sees sanitized room label" (Some "default")
            !captured_room_id;
          let event_log =
            match find_latest_event_log config with
            | Some path -> path
            | None -> fail "expected event log file under .masc/events/"
          in
          let last_event =
            match read_lines event_log |> List.rev with
            | last_event :: _ -> last_event
            | [] -> fail "expected agent join event in log"
          in
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
          test_case "write and resolve scope" `Quick
            test_current_room_write_and_resolve_scope;
          test_case "writes stay canonical" `Quick
            test_current_room_writes_stay_canonical;
          test_case "join_in_room sanitizes invalid room id" `Quick
            test_join_in_room_sanitizes_invalid_room_id;
        ] );
    ]
