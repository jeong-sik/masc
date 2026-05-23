let temp_dir () =
  let path = Filename.temp_file "masc_log_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  try rm dir with _ -> ()

let today_log_path dir =
  let tm = Unix.localtime (Unix.gettimeofday ()) in
  Filename.concat dir
    (Printf.sprintf "system_log_%04d-%02d-%02d.jsonl"
       (tm.Unix.tm_year + 1900)
       (tm.Unix.tm_mon + 1)
       tm.Unix.tm_mday)

let read_log_messages path =
  if not (Sys.file_exists path) then
    []
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let messages = ref [] in
      (try
         while true do
           let message =
             Yojson.Safe.from_string (input_line ic)
             |> Yojson.Safe.Util.member "message"
             |> Yojson.Safe.Util.to_string
           in
           messages := message :: !messages
         done
       with End_of_file -> ());
      List.rev !messages)

let find_entry ~module_name ~message =
  Log.Ring.recent ~limit:50 ~module_filter:module_name ()
  |> List.find_opt (fun (entry : Log.Ring.entry) -> String.equal entry.message message)

let latest_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> entry.seq
  | [] -> -1

let test_legacy_traceln_records_metadata () =
  let module_name = "TestLogLegacy" in
  let message =
    Printf.sprintf "[WARN] legacy warning %f" (Unix.gettimeofday ())
  in
  Log.legacy_traceln ~level:Log.Warn ~module_name message;
  match find_entry ~module_name ~message with
  | None -> Alcotest.fail "legacy traceln entry not found"
  | Some (entry : Log.Ring.entry) ->
      Alcotest.(check string)
        "source" "legacy_traceln"
        (Log.source_to_string entry.source);
      Alcotest.(check string)
        "level" "WARN"
        (Log.level_to_string entry.level)

let test_recent_since_seq_returns_only_new_entries () =
  let module_name = "TestLogDelta" in
  let baseline = latest_seq () in
  let info_message =
    Printf.sprintf "delta info %f" (Unix.gettimeofday ())
  in
  let warn_message =
    Printf.sprintf "delta warn %f" (Unix.gettimeofday ())
  in
  Log.info ~ctx:module_name "%s" info_message;
  Log.warn ~ctx:module_name "%s" warn_message;
  let entries =
    Log.Ring.recent ~limit:10 ~module_filter:module_name ~since_seq:baseline ()
  in
  Alcotest.(check (list string)) "delta messages"
    [ warn_message; info_message ]
    (List.map (fun (entry : Log.Ring.entry) -> entry.message) entries)

let oas_record ?(level = Agent_sdk.Log.Info) ~module_name ~message fields =
  Agent_sdk.Log.
    {
      ts = Unix.gettimeofday ();
      level;
      module_name;
      message;
      fields;
      trace_id = None;
      span_id = None;
    }

(* The four [test_oas_bridge_*] cases below exercised
   [Agent_sdk_log_bridge.effective_level], which was removed from the
   public mli during the dead-export sweep — the level-promotion logic
   is now internal to [install ()]. The level-promotion contracts
   (MCP server failure → ERROR; context_injector → ERROR; missing
   approval callback → ERROR; tool_choice relaxation → DEBUG) still
   live in the bridge implementation; cover them through integration
   log assertions on the installed handler rather than through the
   removed accessor. *)

let test_file_sink_reopens_when_log_path_is_deleted () =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    let log_path = today_log_path dir in
    let first_message =
      Printf.sprintf "file sink first %f" (Unix.gettimeofday ())
    in
    let second_message =
      Printf.sprintf "file sink second %f" (Unix.gettimeofday ())
    in
    Log.Ring.init_file_sink dir;
    Log.emit Log.Info ~module_name:"TestLogFileSink" first_message;
    Alcotest.(check bool) "initial log file created" true
      (Sys.file_exists log_path);
    Sys.remove log_path;
    Alcotest.(check bool) "log file removed" false
      (Sys.file_exists log_path);
    Log.emit Log.Info ~module_name:"TestLogFileSink" second_message;
    Alcotest.(check bool) "log file recreated" true
      (Sys.file_exists log_path);
    let messages = read_log_messages log_path in
    Alcotest.(check bool) "recreated log contains latest entry" true
      (List.exists (String.equal second_message) messages))

let () =
  Alcotest.run "Masc_log" [
    ( "ring",
      [
        Alcotest.test_case "legacy traceln records metadata" `Quick
          test_legacy_traceln_records_metadata;
        Alcotest.test_case "recent since_seq returns only new entries" `Quick
          test_recent_since_seq_returns_only_new_entries;
        Alcotest.test_case
          "file sink reopens when current log path is deleted"
          `Quick test_file_sink_reopens_when_log_path_is_deleted;
      ] );
  ]
