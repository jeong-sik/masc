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

let test_recent_before_seq_returns_only_older_entries () =
  (* Backward "load older" paging: [before_seq] must return entries strictly
     older than the cursor, newest-first, respecting [limit], and compose with
     [since_seq] into a bounded window. *)
  let module_name = "TestLogBefore" in
  let baseline = latest_seq () in
  let messages =
    List.init 3 (fun i ->
      Printf.sprintf "before page msg %d %f" i (Unix.gettimeofday ()))
  in
  List.iter (fun m -> Log.info ~ctx:module_name "%s" m) messages;
  (* Newest-first within this module: [m2; m1; m0]. *)
  let scoped () =
    Log.Ring.recent ~limit:10 ~module_filter:module_name ~since_seq:baseline ()
  in
  let seqs =
    List.map (fun (entry : Log.Ring.entry) -> entry.seq, entry.message) (scoped ())
  in
  let seq_of message =
    match List.find_opt (fun (_, m) -> String.equal m message) seqs with
    | Some (seq, _) -> seq
    | None -> Alcotest.fail (Printf.sprintf "seq not found for %s" message)
  in
  let m0 = List.nth messages 0 in
  let m1 = List.nth messages 1 in
  let m2 = List.nth messages 2 in
  let names entries =
    List.map (fun (entry : Log.Ring.entry) -> entry.message) entries
  in
  (* Strictly older than m2 → m1, m0 (newest-first). *)
  Alcotest.(check (list string)) "before_seq excludes the cursor entry"
    [ m1; m0 ]
    (names
       (Log.Ring.recent ~limit:10 ~module_filter:module_name
          ~before_seq:(seq_of m2) ()));
  (* limit caps the page, keeping the newest of the older slice. *)
  Alcotest.(check (list string)) "before_seq respects limit"
    [ m1 ]
    (names
       (Log.Ring.recent ~limit:1 ~module_filter:module_name
          ~before_seq:(seq_of m2) ()));
  (* since_seq lower bound + before_seq upper bound → bounded window {m1}. *)
  Alcotest.(check (list string)) "before_seq composes with since_seq"
    [ m1 ]
    (names
       (Log.Ring.recent ~limit:10 ~module_filter:module_name
          ~since_seq:(seq_of m0) ~before_seq:(seq_of m2) ()))

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

let test_oas_bridge_promotes_mcp_server_failures_to_error () =
  let level =
    Masc.Agent_sdk_log_bridge.effective_level
      (oas_record
         ~level:Agent_sdk.Log.Warn
         ~module_name:"agent_config"
         ~message:"MCP server failed"
         [ Agent_sdk.Log.S ("server", "demo");
           Agent_sdk.Log.S ("error", "connection refused") ])
  in
  Alcotest.(check string) "mcp server failure promoted" "ERROR"
    (Log.level_to_string level)

let test_oas_bridge_promotes_context_injector_failures_to_error () =
  let level =
    Masc.Agent_sdk_log_bridge.effective_level
      (oas_record
         ~level:Agent_sdk.Log.Warn
         ~module_name:"agent_turn"
         ~message:"context_injector raised"
         [ Agent_sdk.Log.S ("tool", "tool_read_file");
           Agent_sdk.Log.S ("error", "boom") ])
  in
  Alcotest.(check string) "context injector failure promoted" "ERROR"
    (Log.level_to_string level)

let test_oas_bridge_demotes_tool_choice_relaxation_to_debug () =
  let level =
    Masc.Agent_sdk_log_bridge.effective_level
      (oas_record
         ~level:Agent_sdk.Log.Info
         ~module_name:"completion_contract"
         ~message:"tool_choice contract relaxed (provider does not support tool_choice)"
         [ Agent_sdk.Log.S ("provider", "glm") ])
  in
  Alcotest.(check string) "tool_choice fallback demoted" "DEBUG"
    (Log.level_to_string level)

let test_entry_to_json_keeper_name_none_serializes_system () =
  (* #18465: keeper_name=None must serialize as "system", not null *)
  let entry : Log.Ring.entry = {
    seq = 1;
    ts = "2026-05-26T00:00:00Z";
    level = Log.Info;
    source = Log.Structured;
    module_name = "test";
    keeper_name = None;
    turn_id = None;
    message = "test message";
    details = `Null;
    category = None;
  } in
  let json = Log.Ring.entry_to_json entry in
  let keeper_name_val =
    Yojson.Safe.Util.member "keeper_name" json
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "keeper_name None → \"system\"" "system" keeper_name_val

let test_entry_to_json_keeper_name_some_preserves () =
  let entry : Log.Ring.entry = {
    seq = 2;
    ts = "2026-05-26T00:00:00Z";
    level = Log.Info;
    source = Log.Structured;
    module_name = "test";
    keeper_name = Some "my-keeper";
    turn_id = None;
    message = "test message";
    details = `Null;
    category = None;
  } in
  let json = Log.Ring.entry_to_json entry in
  let keeper_name_val =
    Yojson.Safe.Util.member "keeper_name" json
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "keeper_name Some preserved" "my-keeper" keeper_name_val

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
        Alcotest.test_case "recent before_seq returns only older entries" `Quick
          test_recent_before_seq_returns_only_older_entries;
        Alcotest.test_case
          "oas bridge promotes MCP server failures"
          `Quick test_oas_bridge_promotes_mcp_server_failures_to_error;
        Alcotest.test_case
          "oas bridge promotes context injector failures"
          `Quick test_oas_bridge_promotes_context_injector_failures_to_error;
        Alcotest.test_case
          "oas bridge demotes normal tool_choice relaxation"
          `Quick test_oas_bridge_demotes_tool_choice_relaxation_to_debug;
        Alcotest.test_case
          "file sink reopens when current log path is deleted"
          `Quick test_file_sink_reopens_when_log_path_is_deleted;
        Alcotest.test_case
          "entry_to_json: keeper_name=None serializes as \"system\" (#18465)"
          `Quick test_entry_to_json_keeper_name_none_serializes_system;
        Alcotest.test_case
          "entry_to_json: keeper_name=Some preserves value"
          `Quick test_entry_to_json_keeper_name_some_preserves;
      ] );
  ]
