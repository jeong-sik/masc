open Alcotest
module B = Masc.Keeper_turn_boundaries
module Store = Masc.Keeper_checkpoint_store
module U = Yojson.Safe.Util

let trace_id = "continuity-cli-trace"
let keeper_id = "continuity-cli-keeper"
let read path = In_channel.with_open_bin path In_channel.input_all
let write path bytes = Out_channel.with_open_bin path (fun oc -> output_string oc bytes)

let checkpoint messages : Agent_core.Checkpoint.t =
  { version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = trace_id; agent_name = keeper_id; model = "fixture-model"
  ; system_prompt = None; messages; usage = Agent_core.Types.empty_usage
  ; turn_count = List.length messages / 2; created_at = 1000.; tools = []
  ; tool_choice = None; disable_parallel_tool_use = false
  ; temperature = None; top_p = None; top_k = None; min_p = None
  ; reasoning_effort = None; enable_thinking = None; preserve_thinking = None
  ; response_format = Agent_core.Types.Off; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync (); mcp_sessions = []; working_context = None
  }

let save session_dir messages =
  match Store.save_agent_core_classified ~session_dir ~history_retained:0 (checkpoint messages) with
  | Ok (Store.Saved _) -> ()
  | Ok (Store.Stale_noop _) -> fail "fixture checkpoint was stale"
  | Error error -> failf "fixture checkpoint: %s" error

let append keepers_dir event =
  match B.append ~keepers_dir ~keeper_id { B.recorded_at = 1000.; event } with
  | Ok () -> ()
  | Error error -> failf "fixture boundary: %s" (B.append_error_to_string error)

let turn keepers_dir number messages =
  let position = match B.position_of_messages messages with
    | Ok value -> value | Error detail -> fail detail in
  append keepers_dir (B.Turn_ended
    { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:number
    ; history_at_start = (if number = 1 then B.Fresh_history else B.Continued_history)
    ; position })

let rec files dir =
  Sys.readdir dir |> Array.to_list |> List.sort String.compare
  |> List.concat_map (fun name ->
    let path = Filename.concat dir name in
    if Sys.is_directory path then files path else [path, read path])

let invoke exe root args =
  let stdout_path = Filename.concat root "stdout" in
  let stderr_path = Filename.concat root "stderr" in
  let out = Unix.openfile stdout_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let err = Unix.openfile stderr_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let status = Fun.protect ~finally:(fun () -> Unix.close out; Unix.close err) (fun () ->
    let pid = Unix.create_process exe (Array.of_list (exe :: args)) Unix.stdin out err in
    snd (Unix.waitpid [] pid)) in
  status, read stdout_path, read stderr_path

let test_roundtrip exe () =
  Eio_main.run @@ fun _env ->
  let root = Filename.temp_dir "continuity-cli-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) @@ fun () ->
  let source = Filename.concat root "source" in
  let session_dir = Filename.concat source "session" in
  let keepers_dir = Filename.concat source "keepers" in
  Fs_compat.mkdir_p session_dir;
  Fs_compat.mkdir_p keepers_dir;
  let working_state = "Candidate state: next verify the synthetic deployment." in
  let state_path = Filename.concat source "state.txt" in
  write state_path working_state;
  let messages = List.init 4 (fun index -> Agent_core.Types.make_message
    ~role:(if index mod 2 = 0 then Agent_core.Types.User else Agent_core.Types.Assistant)
    [Agent_core.Types.Text (Printf.sprintf "synthetic-context-%d" index)]) in
  let prefix = List.filteri (fun index _ -> index < 2) messages in
  save session_dir prefix;
  append keepers_dir (B.History_restarted {trace_id});
  turn keepers_dir 1 prefix;
  let common trace = ["--session-dir"; session_dir; "--trace"; trace;
    "--keepers-dir"; keepers_dir; "--keeper"; keeper_id] in
  let snapshot_path = Filename.concat root "snapshot.json" in
  let run_success mode specific output =
    let before = files source in
    let status, stdout, stderr = invoke exe root
      (mode :: common trace_id @ specific @ ["--output"; output]) in
    (match status with Unix.WEXITED 0 -> () | _ -> failf "CLI failed: %s" stderr);
    check (list (pair string string)) "source files unchanged" before (files source);
    let metadata = Yojson.Safe.from_string stdout in
    check (list string) "stdout contains metadata fields only"
      ["operation"; "output_path"; "semantic_continuity_evaluated"; "sha256"]
      (U.to_assoc metadata |> List.map fst |> List.sort String.compare);
    check bool "storage experiment does not claim semantic validation" false
      U.(metadata |> member "semantic_continuity_evaluated" |> to_bool);
    check string "stdout contains only metadata" "null"
      (Yojson.Safe.to_string (U.member "working_state" metadata));
    check string "stdout has no conversation" "null"
      (Yojson.Safe.to_string (U.member "messages" metadata));
    Yojson.Safe.from_file output
  in
  let captured = run_success "capture" ["--working-state"; state_path] snapshot_path in
  check string "working state persisted with front" working_state
    U.(captured |> member "working_state" |> to_string);
  check int "front persisted in same artifact" 2 U.(captured |> member "end_atom" |> to_int);
  save session_dir messages;
  turn keepers_dir 2 messages;
  let restored = run_success "restore" ["--snapshot"; snapshot_path]
    (Filename.concat root "restored.json") in
  check string "restore leaves snapshot input unchanged"
    (Yojson.Safe.to_string captured) (Yojson.Safe.to_string (Yojson.Safe.from_file snapshot_path));
  check string "restored state" working_state U.(restored |> member "working_state" |> to_string);
  check string "restored artifact carries its exact snapshot"
    (Yojson.Safe.to_string captured) (Yojson.Safe.to_string (U.member "snapshot" restored));
  let expected = List.filteri (fun index _ -> index >= 2) messages
    |> List.map Agent_core.Checkpoint.message_to_json in
  check string "only appended suffix restored; covered prefix absent"
    (Yojson.Safe.to_string (`List expected))
    (Yojson.Safe.to_string (U.member "messages" restored));
  let reject trace name =
    let output = Filename.concat root name in
    let before = files source in
    let status, stdout, _ = invoke exe root
      ("restore" :: common trace @ ["--snapshot"; snapshot_path; "--output"; output]) in
    check bool "invalid restoration fails" true (status = Unix.WEXITED 2);
    check string "failure prints no successful metadata" "" stdout;
    check bool "failure creates no output artifact" false (Sys.file_exists output);
    check (list (pair string string)) "rejection leaves sources unchanged" before (files source)
  in
  reject "different-trace" "wrong-trace.json";
  append keepers_dir (B.History_restarted {trace_id});
  turn keepers_dir 1 messages;
  reject trace_id "restarted.json"

let () =
  (* The targeted CI runner preserves stanza environment/dependencies but
     invokes the test binary without the custom Dune action's arguments. *)
  let exe = Sys.getenv "MASC_TEST_LIBRARIAN_CONTINUITY_EXE" in
  let exe = if Filename.is_relative exe then Filename.concat (Sys.getcwd ()) exe else exe in
  run ~argv:[|Sys.argv.(0)|] "continuity snapshot CLI"
    ["artifact", [test_case "capture, suffix restore, and identity refusal" `Quick (test_roundtrip exe)]]
