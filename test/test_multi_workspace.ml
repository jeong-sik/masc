(** Multi-workspace tests — reduced to flat namespace verification after #4638. *)

open Alcotest
open Masc

let with_config f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-current-workspace-%06x" (Random.bits ()))
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
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:None);
      f config)

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
  let events_dir = Filename.concat (Workspace.masc_dir config) "events" in
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
      let previous_hook = (Atomic.get Workspace_hooks.observe_agent_lifecycle_fn) in
      Fun.protect
        ~finally:(fun () -> Atomic.set Workspace_hooks.observe_agent_lifecycle_fn previous_hook)
        (fun () ->
          Atomic.set Workspace_hooks.observe_agent_lifecycle_fn (fun _config ~agent_id:_ ~event ~details:_ ->
              captured_event_kind := Some (Workspace_hooks.agent_lifecycle_event_to_string event));
          let result =
            Workspace.bind_session config ~agent_name:"claude"
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
          check string "event type is agent_session_bound" "agent_session_bound" event_type))

let () =
  run "flat_namespace"
    [
      ( "agent_lifecycle",
        [
          test_case "join uses default namespace" `Quick
            test_join_uses_default_namespace;
        ] );
    ]
