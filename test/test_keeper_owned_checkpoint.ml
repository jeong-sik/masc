open Alcotest
open Masc
module Store = Keeper_checkpoint_store

let () = Server_startup_state.mark_state_ready () |> Result.get_ok

let make_checkpoint ~session_id ~turn_count ~marker =
  let messages = [
    Agent_core.Types.{ role = User; content = [Text "hello"]; name = None;
                      tool_call_id = None; metadata = [] };
    Agent_core.Types.{ role = Assistant; content = [Text marker]; name = None;
                      tool_call_id = None; metadata = [] };
  ] in
  Agent_core.Checkpoint.{
    version = checkpoint_version;
    session_id;
    agent_name = "test-agent";
    model = "test-model";
    system_prompt = None;
    messages;
    usage = Agent_core.Types.empty_usage;
    turn_count;
    created_at = 1000.0;
    tools = [];
    tool_choice = None;
    disable_parallel_tool_use = false;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    reasoning_effort = None;
    enable_thinking = None;
    preserve_thinking = None;
    response_format = Agent_core.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;

    context = Agent_core.Context.create_sync ();
    mcp_sessions = [];
    working_context = None;
  }

let with_session f =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let root = Filename.temp_file "keeper-owned-checkpoint" "" in
    Unix.unlink root;
    Unix.mkdir root 0o700;
    let session_dir = Filename.concat root "session" in
    Unix.mkdir session_dir 0o700;
    let rec remove path = match Unix.lstat path with
      | { Unix.st_kind = Unix.S_DIR; _ } ->
          Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
          Unix.rmdir path
      | _ -> Unix.unlink path
    in
    Fun.protect ~finally:(fun () -> remove root) (fun () -> f session_dir))

let accepted marker =
  let checkpoint = make_checkpoint ~session_id:"session" ~turn_count:1 ~marker in
  let bytes = Yojson.Safe.pretty_to_string (Agent_core.Checkpoint.to_json checkpoint) in
  let trace_id = Keeper_id.Trace_id.of_string "session" |> Result.get_ok in
  match Store.exact_snapshot_of_canonical_bytes ~expected_session_id:trace_id bytes with
  | Ok snapshot -> checkpoint, snapshot
  | Error _ -> fail "fixture checkpoint was refused"

let require_installed = function
  | Store.Installed {auxiliary=[]; _} -> ()
  | Store.Installed _ -> fail "unexpected installation uncertainty"
  | Store.Not_installed _ -> fail "checkpoint retention failed"
let load session_dir reference =
  match Store.load_retained_exact_snapshot ~session_dir ~reference with
  | Ok snapshot -> snapshot | Error _ -> fail "retained checkpoint unavailable"
let assert_snapshot label expected actual =
  check string (label ^ " exact immutable bytes")
    (Store.exact_snapshot_canonical_bytes expected)
    (Store.exact_snapshot_canonical_bytes actual);
  check bool (label ^ " exact reference") true
    (Keeper_checkpoint_ref.equal (Store.exact_snapshot_reference expected)
       (Store.exact_snapshot_reference actual))
let artifact_path session_dir snapshot =
  Filename.concat (Filename.concat session_dir "accepted-checkpoints")
    ((Store.exact_snapshot_reference snapshot).sha256 ^ ".json")
let write path bytes = Out_channel.with_open_bin path (fun ch -> output_string ch bytes)
let read path = In_channel.with_open_bin path In_channel.input_all

let test_survives_canonical_and_history () = with_session (fun session_dir ->
  let a, snapshot = accepted "A retained" in
  Store.retain_exact_snapshot ~session_dir snapshot |> require_installed;
  for turn_count = 2 to 21 do
    let b = {a with Agent_core.Checkpoint.turn_count; created_at=float_of_int turn_count;
                    messages=(make_checkpoint ~session_id:"session" ~turn_count ~marker:"B active").messages} in
    (match Store.save_agent_core_classified ~session_dir b with Ok _ -> () | Error e -> fail e)
  done;
  check int "rolling archive actually pruned" 12
    (List.length (Store.list_agent_core_history_files ~session_dir));
  assert_snapshot "A after twenty B saves" snapshot
    (load session_dir (Store.exact_snapshot_reference snapshot));
  match Store.load_agent_core ~session_dir ~session_id:"session" with
  | Ok latest -> check int "B remains current" 21 latest.turn_count
  | Error _ -> fail "B canonical unavailable")

let test_same_reference_retry () = with_session (fun session_dir ->
  let _a, snapshot = accepted "immutable A" in
  Store.retain_exact_snapshot ~session_dir snapshot |> require_installed;
  Store.retain_exact_snapshot ~session_dir snapshot |> require_installed;
  check int "same address has one artifact" 1
    (Array.length (Sys.readdir (Filename.dirname (artifact_path session_dir snapshot))));
  assert_snapshot "retry" snapshot (load session_dir (Store.exact_snapshot_reference snapshot)))

let test_missing_never_uses_canonical () = with_session (fun session_dir ->
  let a, snapshot = accepted "canonical only" in
  (match Store.save_agent_core_classified ~session_dir a with Ok _ -> () | Error e -> fail e);
  match Store.load_retained_exact_snapshot ~session_dir ~reference:(Store.exact_snapshot_reference snapshot) with
  | Error (Store.Source_unavailable Store.Ref_not_found) -> ()
  | _ -> fail "missing retained artifact fell back to canonical")

let test_corruption_is_never_repaired () =
  List.iter (fun corrupt -> with_session (fun session_dir ->
    let a, snapshot = accepted "A" in
    let _b, other = accepted "different valid checkpoint" in
    Store.retain_exact_snapshot ~session_dir snapshot |> require_installed;
    let bytes = if corrupt then "{broken checkpoint" else Store.exact_snapshot_canonical_bytes other in
    let path = artifact_path session_dir snapshot in write path bytes;
    (match Store.load_retained_exact_snapshot ~session_dir ~reference:(Store.exact_snapshot_reference snapshot) with
     | Error _ -> () | Ok _ -> fail "corrupt addressed content accepted");
    (match Store.retain_exact_snapshot ~session_dir snapshot with
     | Store.Not_installed _ -> () | Store.Installed _ -> fail "corrupt evidence was silently repaired");
    check string "corrupt bytes retained" bytes (read path);
    (match Store.save_agent_core_classified ~session_dir {a with turn_count=2} with Ok _ -> () | Error e -> fail e);
    match Store.load_agent_core ~session_dir ~session_id:"session" with
    | Ok b -> check int "unrelated canonical remains usable" 2 b.turn_count
    | Error _ -> fail "corruption poisoned unrelated canonical")) [false;true]

let test_reference_checks_all_fields () = with_session (fun session_dir ->
  let _a, snapshot = accepted "A" in
  Store.retain_exact_snapshot ~session_dir snapshot |> require_installed;
  let original = Store.exact_snapshot_reference snapshot in
  let other_trace = Keeper_id.Trace_id.of_string "another-session" |> Result.get_ok in
  List.iter (fun (trace_id, turn_count) ->
    let reference = Keeper_checkpoint_ref.of_persisted ~trace_id ~turn_count ~sha256:original.sha256 |> Result.get_ok in
    match Store.load_retained_exact_snapshot ~session_dir ~reference with
    | Error _ -> () | Ok _ -> fail "reference trace or turn mismatch accepted")
    [original.trace_id, original.turn_count+1; other_trace,original.turn_count])

let fault_writer stage ~on_durable_commit ~ownership_root ~path ~bytes =
  Keeper_fs.For_testing.save_bytes_durable_atomic_observed
    ~on_durable_commit ~ownership_root
    ~before_stage:(fun actual -> if actual=stage then raise (Sys_error "injected checkpoint I/O failure")) path bytes

let test_write_failure_preserves_previous () = with_session (fun session_dir ->
  let _a, a = accepted "A" in let _b, b = accepted "B" in
  Store.retain_exact_snapshot ~session_dir a |> require_installed;
  List.iter (fun snapshot ->
    match Store.For_testing.retain_exact_snapshot_with_writer
       ~write_checkpoint_bytes:(fault_writer Keeper_fs.Payload_write) ~session_dir snapshot with
    | Store.Not_installed {cause=Store.Commit_not_installed {renamed=false; _}; _} -> ()
    | _ -> fail "prepublication write failure misclassified") [a;b];
  assert_snapshot "A after B write failure" a (load session_dir (Store.exact_snapshot_reference a));
  match Store.load_retained_exact_snapshot ~session_dir ~reference:(Store.exact_snapshot_reference b) with
  | Error (Store.Source_unavailable Store.Ref_not_found) -> () | _ -> fail "failed B was published")

let test_uncertain_publication_reload_and_reconfirm () = with_session (fun session_dir ->
  let _a, snapshot = accepted "A" in
  (match Store.For_testing.retain_exact_snapshot_with_writer
     ~write_checkpoint_bytes:(fault_writer Keeper_fs.Parent_directory_fsync_after_rename) ~session_dir snapshot with
   | Store.Installed {auxiliary=[Store.Commit_durability_unknown {renamed=true; _}]; _} -> ()
   | _ -> fail "visible uncertain publication lost its exact installed fact");
  let restored = load session_dir (Store.exact_snapshot_reference snapshot) in
  assert_snapshot "uncertain reload" snapshot restored;
  Store.retain_exact_snapshot ~session_dir restored |> require_installed;
  assert_snapshot "durability reconfirmed" snapshot (load session_dir (Store.exact_snapshot_reference snapshot)))

let test_prepublication_cancellation_propagates () = with_session (fun session_dir ->
  let _a, snapshot = accepted "A" in
  let writer ~on_durable_commit:_ ~ownership_root:_ ~path:_ ~bytes:_ =
    raise (Eio.Cancel.Cancelled Exit) in
  (match Store.For_testing.retain_exact_snapshot_with_writer ~write_checkpoint_bytes:writer ~session_dir snapshot with
   | exception Eio.Cancel.Cancelled _ -> ()
   | _ -> fail "prepublication cancellation was swallowed");
  match Store.load_retained_exact_snapshot ~session_dir ~reference:(Store.exact_snapshot_reference snapshot) with
  | Error (Store.Source_unavailable Store.Ref_not_found) -> ()
  | _ -> fail "cancelled publication invented an artifact")

let test_post_commit_cancellation_keeps_installation () = with_session (fun session_dir ->
  let _a, snapshot = accepted "A" in
  let writer ~on_durable_commit ~ownership_root ~path ~bytes =
    match Keeper_fs.save_bytes_durable_atomic_observed ~on_durable_commit ~ownership_root path bytes with
    | Ok Keeper_fs.Committed -> raise (Eio.Cancel.Cancelled Exit)
    | (Ok (Keeper_fs.Committed_but_observer_failed _) | Error _) as result -> result in
  (match Store.For_testing.retain_exact_snapshot_with_writer ~write_checkpoint_bytes:writer ~session_dir snapshot with
   | Store.Installed {auxiliary=[Store.Post_commit_unwind_interrupted (Eio.Cancel.Cancelled _, _)]; _} -> ()
   | _ -> fail "post-commit cancellation erased durable publication");
  assert_snapshot "post-cancel" snapshot (load session_dir (Store.exact_snapshot_reference snapshot)))

let test_owned_paths_and_history_deletion () = with_session (fun session_dir ->
  let _a, snapshot = accepted "A" in
  Store.retain_exact_snapshot ~session_dir snapshot |> require_installed;
  let reference = Store.exact_snapshot_reference snapshot in
  let names = ["accepted-checkpoints"; "accepted-checkpoints/" ^ reference.sha256 ^ ".json";
               "../accepted-checkpoints/" ^ reference.sha256 ^ ".json"] in
  let deleted, missing = Store.delete_agent_core_history_files ~session_dir ~snapshot_ids:names in
  check (list string) "history endpoint cannot delete owned snapshots" [] deleted;
  check int "all invalid history targets refused" 3 (List.length missing);
  assert_snapshot "after history deletion attempt" snapshot (load session_dir reference);
  let path = artifact_path session_dir snapshot in
  Unix.unlink path;
  Unix.symlink (Filename.concat session_dir "missing-outside-target") path;
  (match Store.load_retained_exact_snapshot ~session_dir ~reference with Error _ -> () | Ok _ -> fail "symlink accepted");
  (match Store.retain_exact_snapshot ~session_dir snapshot with Store.Not_installed _ -> () | _ -> fail "symlink replaced");
  check bool "dangling symlink evidence retained" true ((Unix.lstat path).Unix.st_kind=Unix.S_LNK))

let () = run "keeper owned exact checkpoints" ["retention", [
  test_case "A survives B canonical and rolling history" `Quick test_survives_canonical_and_history;
  test_case "same reference retry keeps exact bytes" `Quick test_same_reference_retry;
  test_case "missing retained checkpoint never uses latest" `Quick test_missing_never_uses_canonical;
  test_case "malformed and mismatched bytes remain evidence" `Quick test_corruption_is_never_repaired;
  test_case "all reference fields are verified" `Quick test_reference_checks_all_fields;
  test_case "failed B publication preserves A" `Quick test_write_failure_preserves_previous;
  test_case "uncertain publication requires exact reload and sync" `Quick test_uncertain_publication_reload_and_reconfirm;
  test_case "prepublication cancellation propagates" `Quick test_prepublication_cancellation_propagates;
  test_case "post-commit cancellation retains installation" `Quick test_post_commit_cancellation_keeps_installation;
  test_case "owned path and history deletion boundaries" `Quick test_owned_paths_and_history_deletion ]]
