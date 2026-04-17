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
      let config = Coord.default_config dir in
      ignore (Coord.init config ~agent_name:None);
      f config)

let select_room config _room_id =
  Coord.ensure_room_bootstrap config;
  config

let test_current_room_defaults_to_default () =
  with_config (fun config ->
      check (option string) "default room" (Some "default")
        (Coord.read_current_room config))

let test_current_room_write_and_resolve_scope () =
  with_config (fun config ->
      let focused = select_room config "focus-room" in
      check (option string) "compat pointer stays default" (Some "default")
        (Coord.read_current_room focused);
      check string "resolved scope stays default" "default"
        focused.backend_config.Backend_types.cluster_name;
      check bool "focused scope initialized" true (Coord.is_initialized focused))

let test_current_room_writes_stay_canonical () =
  with_config (fun config ->
      let focused = select_room config "focus-room" in
      ignore (Coord.add_task focused ~title:"focus task" ~priority:1 ~description:"");
      check int "default namespace task count" 1
        (List.length (Coord.get_tasks_raw config));
      (* All rooms are flattened to default — get_tasks_safe is the single path *)
      check int "same tasks regardless of former room" 1
        (List.length (Coord.get_tasks_safe config)))

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
  let events_dir = Filename.concat (Coord.masc_dir config) "events" in
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

let test_join_uses_default_namespace () =
  with_config (fun config ->
      let captured_event_kind = ref None in
      let previous_hook = (Atomic.get Coord_hooks.observe_agent_lifecycle_fn) in
      Fun.protect
        ~finally:(fun () -> Atomic.set Coord_hooks.observe_agent_lifecycle_fn previous_hook)
        (fun () ->
          Atomic.set Coord_hooks.observe_agent_lifecycle_fn (fun _config ~agent_id:_ ~event_kind ~details:_ ->
              captured_event_kind := Some event_kind);
          let result =
            Coord.join config ~agent_name:"claude"
              ~capabilities:[ "debug" ] ()
          in
          check bool "join succeeds" true
            (String.length result > 0);
          check (option string) "hook sees join event" (Some "join")
            !captured_event_kind;
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
          let event_json = Yojson.Safe.from_string last_event in
          let event_type =
            event_json
            |> Yojson.Safe.Util.member "type"
            |> Yojson.Safe.Util.to_string
          in
          check string "event type is agent_join" "agent_join" event_type))

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
          test_case "join uses default namespace" `Quick
            test_join_uses_default_namespace;
        ] );
    ]
