open Alcotest
open Masc
module Work = Keeper_recovery_work
module Checkpoint = Keeper_checkpoint_store
let () = Mirage_crypto_rng_unix.use_default ()
let () = Server_startup_state.mark_state_ready () |> Result.get_ok
let ok = function Ok x -> x | Error e -> fail (Work.error_to_string e)
let changed = function
  | { Work.value; lock_release_error = None } -> value
  | _ -> fail "unexpected lock release failure"
let read config id = match Work.load ~config ~id |> ok with
  | Some t -> t | None -> fail "durable recovery disappeared"
let reject label expected = function
  | Error actual -> check bool label true (expected actual)
  | Ok _ -> fail (label ^ " unexpectedly succeeded")
let checkpoint marker =
  let open Agent_core.Types in
  let message role content = {role; content; name=None; tool_call_id=None; metadata=[]} in
  let messages =
    [message User [Text "Keep the required task and its source"];
     message Assistant [ToolUse {id="exact-call-1"; name="keeper_artifact_read"; input=`Assoc []}];
     message Tool [ToolResult {tool_use_id="exact-call-1"; content=marker;
       outcome=Tool_succeeded; json=None; content_blocks=None}]] in
  Agent_core.Checkpoint.{
    version=checkpoint_version; session_id="recovery-trace"; agent_name="recovery";
    model="fixture"; system_prompt=None; messages; usage=empty_usage; turn_count=1;
    created_at=1000.; tools=[]; tool_choice=None; disable_parallel_tool_use=false;
    temperature=None; top_p=None; top_k=None; min_p=None; reasoning_effort=None;
    enable_thinking=None; preserve_thinking=None; response_format=Off;
    thinking_budget=None; cache_system_prompt=false; context=Agent_core.Context.create_sync ();
    mcp_sessions=[]; working_context=None}
let with_fixture f =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Fs_compat.set_fs env#fs;
    let root = Filename.temp_file "recovery-work" "" in
    Unix.unlink root; Unix.mkdir root 0o700;
    Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree root);
    let config = Workspace.default_config root in
    ignore (Keeper_fs.ensure_dir (Workspace.masc_root_dir config));
    let session_dir = Filename.concat root "session" in
    let save marker =
      (match Checkpoint.save_agent_core_classified ~session_dir (checkpoint marker) with
       | Ok _ -> () | Error e -> fail e);
      match Checkpoint.load_agent_core_exact_snapshot ~session_dir ~session_id:"recovery-trace" with
      | Ok snapshot -> snapshot | Error _ -> fail "source checkpoint unavailable"
    in
    let source = save "original tool bytes" in
    let canonical_path = Checkpoint.agent_core_checkpoint_path ~session_dir ~session_id:"recovery-trace" in
    f config canonical_path source save))
let create config source admission =
  Work.create ~config ~keeper_name:(Keeper_id.Keeper_name.of_string "recovery" |> Result.get_ok)
    ~admission_id:admission ~source
    ~failures:["fixture.one", Agent_core.Error.Api
      (Agent_core.Retry.ContextOverflow {message="observed provider refusal";limit=Some 8192})]
    ~pending_stimulus_ids:["stimulus-a";"stimulus-b"]
    ~required_source_refs:["task:required";"user:direct"] ~source_watermark:"queue-revision-1"
  |> ok |> changed
let claim config t instance =
  Work.claim ~config ~id:(Work.id t) ~expected_revision:(Work.revision t) ~instance_id:instance
  |> ok |> changed
let test_resume_publish_preserves_source () = with_fixture (fun config path source _ ->
  let canonical_before = Fs_compat.load_file path in
  let first = create config source "admission-a" in
  let id = Work.id first in
  let duplicate = create config source "admission-a" in
  check string "duplicate admission keeps exact work" id (Work.id duplicate);
  let running, old_owner = claim config first "process-a" in
  let progress = Work.record_progress ~config ~id ~owner:old_owner
    ~expected_revision:(Work.revision running) ~next_offset:17 |> ok |> changed in
  let restored = read (Workspace.default_config config.base_path) id in
  check string "reload reads durable revision" (Work.revision progress) (Work.revision restored);
  check int "reload preserves source cursor" 17 (Work.cursor restored);
  check string "owner source watermark survives reload" "queue-revision-1" (Work.source_watermark restored);
  check (list string) "pending stimulus coverage survives reload" ["stimulus-a";"stimulus-b"]
    (Work.pending_stimulus_ids restored);
  let resumed, owner = claim config restored "process-b" in
  check bool "new owner fences previous token" false
    (Work.owner_claim_id old_owner = Work.owner_claim_id owner);
  Work.record_progress ~config ~id ~owner:old_owner ~expected_revision:(Work.revision resumed) ~next_offset:18
  |> reject "stale owner" (function Work.Stale_owner -> true | _ -> false);
  Work.record_progress ~config ~id ~owner ~expected_revision:(Work.revision restored) ~next_offset:18
  |> reject "stale revision" (function Work.Stale_revision -> true | _ -> false);
  let publish required = Work.record_proposal ~config ~id ~owner
    ~expected_revision:(Work.revision resumed) ~current_source:source
    ~claimed_required_refs:required ~claimed_stimulus_ids:["stimulus-b";"stimulus-a"]
    ~proposal_bytes:"Opaque proposal: retain the task. Source remains directly readable." in
  publish ["task:required"]
  |> reject "proposal cannot weaken owner requirements" (function Work.Invalid_input _ -> true | _ -> false);
  let _proposed = publish ["user:direct";"task:required"] |> ok |> changed in
  let proposed = read config id in
  (match Work.status proposed with
   | Work.Proposal_recorded projection ->
     let artifact = Tool_blob_store.fetch (Tool_blob_store.create ~base_path:config.base_path)
       ~sha256:(Work.projection_artifact_sha256 projection) in
     (match artifact with Ok (Some body) -> check bool "proposal bytes retained" true (String.length body > 0)
      | _ -> fail "proposal artifact unavailable")
   | _ -> fail "proposal status was invented or lost");
  Work.verify_artifacts config proposed |> ok;
  check string "terminal evidence keeps publishing owner" "process-b"
    (Work.last_owner proposed |> Option.get |> Work.owner_instance_id);
  Work.cancel ~config ~id ~owner ~expected_revision:(Work.revision proposed) ~reason:"too late"
  |> reject "late terminal publication" (function Work.Terminal_state -> true | _ -> false);
  check string "canonical file and exact Tool pair bytes unchanged" canonical_before (Fs_compat.load_file path))
let test_changed_source_does_not_publish () = with_fixture (fun config path source save ->
  let first = create config source "source-change" in
  let running, owner = claim config first "process-a" in
  let different = save "changed tool bytes" in
  let canonical = Fs_compat.load_file path in
  Work.record_proposal ~config ~id:(Work.id first) ~owner
    ~expected_revision:(Work.revision running) ~current_source:different
    ~claimed_required_refs:["task:required";"user:direct"]
    ~claimed_stimulus_ids:["stimulus-a";"stimulus-b"] ~proposal_bytes:"stale text"
  |> reject "changed exact source" (function Work.Source_changed -> true | _ -> false);
  check string "rejected proposal does not mutate work" (Work.revision running)
    (read config (Work.id first) |> Work.revision);
  check string "rejected proposal does not overwrite current source" canonical (Fs_compat.load_file path))
let artifact_path config work =
  let sha = Work.source_artifact_sha256 work in
  Filename.concat (Filename.concat (Tool_blob_store.root_dir
    (Tool_blob_store.create ~base_path:config.Workspace.base_path)) (String.sub sha 0 2)) sha
let test_missing_source_keeps_terminal_evidence () = with_fixture (fun config path source _ ->
  let canonical = Fs_compat.load_file path in
  let first = create config source "missing-source" in
  Unix.unlink (artifact_path config first);
  let running, owner = claim config (read config (Work.id first)) "process-a" in
  Work.verify_artifacts config running
  |> reject "missing source is explicit" (function Work.Artifact_missing _ -> true | _ -> false);
  Work.record_proposal ~config ~id:(Work.id running) ~owner
    ~expected_revision:(Work.revision running) ~current_source:source
    ~claimed_required_refs:["task:required";"user:direct"]
    ~claimed_stimulus_ids:["stimulus-a";"stimulus-b"] ~proposal_bytes:"unavailable source proposal"
  |> reject "claim is not permission to publish without source" (function Work.Artifact_missing _ -> true | _ -> false);
  let failed = Work.fail ~config ~id:(Work.id running) ~owner ~expected_revision:(Work.revision running)
    (Work.Source_access_unavailable "immutable source artifact is missing") |> ok |> changed in
  (match Work.status (read config (Work.id failed)) with
   | Work.Failed (Work.Source_access_unavailable _) -> () | _ -> fail "source failure was hidden");
  check string "missing artifact does not delete canonical bytes" canonical (Fs_compat.load_file path))
let test_corrupt_source_can_be_cancelled () = with_fixture (fun config path source _ ->
  let canonical = Fs_compat.load_file path in
  let first = create config source "corrupt-source" in
  let running, owner = claim config first "process-a" in
  (match Fs_compat.save_file_atomic (artifact_path config running) "corrupt source" with
   | Ok () -> () | Error e -> fail e);
  Work.verify_artifacts config running
  |> reject "corrupt source is explicit" (function Work.Artifact_read_failed _ -> true | _ -> false);
  let cancelled = Work.cancel ~config ~id:(Work.id running) ~owner
    ~expected_revision:(Work.revision running) ~reason:"operator cancelled unavailable recovery" |> ok |> changed in
  (match Work.status (read config (Work.id cancelled)) with Work.Cancelled _ -> () | _ -> fail "cancel was hidden");
  check string "cancellation preserves canonical bytes" canonical (Fs_compat.load_file path))
let () = Alcotest.run "Keeper recovery durable work"
  ["lifecycle",[
    test_case "reload and fenced proposal preserve canonical history" `Quick test_resume_publish_preserves_source;
    test_case "changed source rejects publication" `Quick test_changed_source_does_not_publish;
    test_case "missing artifact permits typed failure" `Quick test_missing_source_keeps_terminal_evidence;
    test_case "corrupt artifact permits cancellation" `Quick test_corrupt_source_can_be_cancelled]]
