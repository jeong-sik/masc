open Alcotest
open Masc
module T = Agent_core.Types
module Contract = Agent_core.Tool_contract
module Projection = Agent_core.Agent.Execution_projection
module Snapshot = Keeper_repetition_snapshot
module Recovery = Keeper_native_repetition_recovery

let require render = function Ok value -> value | Error error -> fail (render error)
let frame result = require Snapshot.error_to_string result
let recover result = require Recovery.error_to_string result
let scope name = Keeper_chat_operation.Operation_id.of_string name
  |> require Fun.id |> Keeper_execution_scope_id.direct_operation
let current_scope = scope "native-repetition-current"
let other_scope = scope "native-repetition-other"
let empty = Snapshot.admit Snapshot.empty (Snapshot.Fresh current_scope) |> frame

let settled ?(attempt_admitted=true) ?(outcome=T.Tool_succeeded) ~sequence content =
  let tool_name = "keeper_note_set" and id = "provider-reused-id" in
  let input = `Assoc ["content", `String content] in
  let invocation = Contract.Invocation.create ~tool_use_id:id ~turn:sequence
      ~schedule:{Contract.planned_index=0; batch_index=0; batch_size=1;
                 execution_mode=Contract.Serial}
      ~completion:Contract.Continue_after_success in
  {Projection.invocation; tool_name; input;
   result=T.ToolResult {tool_use_id=id; content; outcome; json=None; content_blocks=None};
   attempt_admitted; settlement_seq=sequence}

let observation ?base_path (call : Projection.settled_tool_invocation) =
  let output_text = match call.result with
    | T.ToolResult {content; _} -> content
    | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
    | ToolUse _ | Image _ | Document _ | Audio _ -> fail "fixture result must be a ToolResult" in
  let io = match Keeper_tool_progress_identity.digest_tool_io ?base_path
      ~tool_name:call.tool_name ~input:call.input ~output_text () with
    | Some io -> io | None -> fail "fixture I/O has no fingerprint" in
  Snapshot.observation ~tool_name:call.tool_name
    ~input_fingerprint:(Some io.input_fingerprint)
    ~output_fingerprint:(Some io.output_fingerprint) |> frame

let record ?(scope=current_scope) state call =
  Snapshot.record state ~scope (observation call) |> frame
let reconcile ~seed ~checkpoint settled =
  Recovery.reconcile ~scope:current_scope ~seed ~checkpoint ~settled ()
let observations state = Snapshot.observations state ~scope:current_scope |> frame
let same label expected actual = check bool label true (Snapshot.equal expected actual)

let test_seed_and_occurrence_multiplicity () =
  let prior = settled ~sequence:1 "same" in
  let first = settled ~sequence:2 "same" and second = settled ~sequence:3 "same" in
  let seed = record empty prior in
  let recovered = reconcile ~seed ~checkpoint:seed [first; second] |> recover in
  check int "identical seed observation cannot discharge current occurrences" 3
    (List.length (observations recovered));
  let checkpoint = record seed first in
  let recovered_again = reconcile ~seed ~checkpoint [first; second] |> recover in
  same "one checkpoint observation discharges only one occurrence" recovered recovered_again;
  same "repeated recovery is idempotent" recovered
    (reconcile ~seed ~checkpoint:recovered [first; second] |> recover)

let test_checkpoint_order_and_other_scopes () =
  let prior = settled ~sequence:1 "prior" in
  let seed = record empty prior in
  let first = settled ~sequence:2 "first" and second = settled ~sequence:3 "second" in
  let missing = settled ~sequence:4 "missing" in
  (* An overlapping batch may finish observers in a different order from
     journal settlement. Preserve exactly the order already checkpointed. *)
  let checkpoint = record (record seed second) first in
  let checkpoint = Snapshot.admit checkpoint (Snapshot.Fresh other_scope) |> frame in
  let checkpoint = record ~scope:other_scope checkpoint (settled ~sequence:5 "unrelated") in
  let checkpoint = Snapshot.admit checkpoint (Snapshot.Fresh current_scope) |> frame in
  let recovered = reconcile ~seed ~checkpoint [first; second; missing] |> recover in
  same "stored order and unrelated scope stay intact" (record checkpoint missing) recovered;
  same "already observed canonical results add nothing" checkpoint
    (reconcile ~seed ~checkpoint [first; second] |> recover)

let failed failure_kind = T.Tool_failed {failure_kind; error_class=Some T.Deterministic}

let test_actual_handler_provenance () =
  let blocked = settled ~sequence:1 ~attempt_admitted:false
      ~outcome:(failed T.Non_retryable_tool_error) "gate denied" in
  let invalid = settled ~sequence:2 ~outcome:(failed T.Validation_error) "schema invalid" in
  let handled = settled ~sequence:3 ~outcome:(failed T.Recoverable_tool_error) "handler failed" in
  let nonretryable = settled ~sequence:4 ~outcome:(failed T.Non_retryable_tool_error) "handler raised" in
  let recovered = reconcile ~seed:empty ~checkpoint:empty
      [blocked; invalid; handled; nonretryable] |> recover in
  same "only admitted handler outcomes become observations"
    (record (record empty handled) nonretryable) recovered;
  List.iter (fun kind ->
    match reconcile ~seed:empty ~checkpoint:empty
        [settled ~sequence:1 ~outcome:(failed kind) "unproven"] with
    | Error Recovery.Unsupported_result_provenance -> ()
    | Ok _ | Error _ -> fail "unproven native handler provenance was accepted")
    [T.Reported_tool_error; T.Unattributed_tool_error]

let test_observer_failure_and_conflicts () =
  let call = settled ~sequence:1 "settled before observer failed" in
  (* A ToolResult checkpoint is written even when a post-tool observer failed.
     Result presence alone cannot prove its repetition observation was saved. *)
  same "settlement restores an observation absent from its checkpoint"
    (record empty call) (reconcile ~seed:empty ~checkpoint:empty [call] |> recover);
  let seeded = record empty (settled ~sequence:1 "seed") in
  (match reconcile ~seed:seeded ~checkpoint:empty [call] with
   | Error Recovery.Seed_observations_changed -> ()
   | Ok _ | Error _ -> fail "missing seed suffix was accepted");
  (match reconcile ~seed:empty ~checkpoint:(record empty (settled ~sequence:2 "foreign")) [call] with
   | Error Recovery.Checkpoint_observation_not_settled -> ()
   | Ok _ | Error _ -> fail "foreign observation was silently discarded");
  let other = Snapshot.admit empty (Snapshot.Fresh other_scope) |> frame in
  match reconcile ~seed:empty ~checkpoint:other [call] with
  | Error Recovery.Scope_mismatch -> ()
  | Ok _ | Error _ -> fail "another execution scope was accepted"

let test_stored_answer_recovery_requires_original_evidence () =
  let base_path = Filename.temp_file "native-answer-recovery" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  let rec remove path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else Unix.unlink path in
  Fun.protect ~finally:(fun () -> remove base_path) @@ fun () ->
  let module Memory = Keeper_memory_os_types in
  let claim = String.make (Tool_output.inline_ceiling_bytes Tool_output.default_model_projection + 1) 'x' in
  let fact = Memory.observed ~claim ~category:Memory.Fact ~now:100.
      ~origin:{kind=Memory.Authored; trace_id="native-recovery-fixture"} in
  let id = Memory.memory_id fact in
  let value = `Assoc ["status",`String "completed";"purpose",`String "current release policy";
      "selection_id",`String "retained-audit-receipt";
      "selected",`List [`Assoc ["id",`String id;"use",`String "current_decision";
        "current",`Assoc ["store",`String "current_memory_snapshot";"memory_id",`String id;
          "current_fact",Memory.fact_to_json fact;"direct_admission_witness_count",`Int 1;
          "successor_witness_count",`Int 0]]];
      "deferred",`List [];"unavailable",`List [];"assessed_count",`Int 1;
      "selected_count",`Int 1;"not_needed_count",`Int 0;"truncated_count",`Int 0;
      "incomplete",`Bool false;"snapshot_revision",`Int 7;"guidance",`String "Current evidence"] in
  let raw = Yojson.Safe.to_string value in
  let tool_name = "keeper_memory_select" in
  let result = Tool_result.make_ok ~tool_name ~start_time:(Tool_timing.start ()) ~data:value () in
  let content = match Tool_bridge.to_agent_core_typed_result ~base_path
      ~answer_reader:(fun output_text -> Keeper_tool_answer.answer ~tool_name ~output_text) result with
    | Ok result -> result.T.content
    | Error error -> fail error.T.message in
  let reference = match Tool_output.decode_from_agent_core content with
    | Tool_output.Decoded reference -> reference
    | _ -> fail "oversized producer result must become a stored marker" in
  let store = Tool_blob_store.create ~base_path in
  check (option string) "exact audit receipt remains in owned store" (Some raw)
    (Tool_blob_store.fetch store ~sha256:reference.sha256 |> require Tool_blob_store.fetch_error_to_string);
  let call = { (settled ~sequence:1 content) with Projection.tool_name;
      input=`Assoc ["purpose",`String "current release policy"] } in
  let checkpoint = Snapshot.record empty ~scope:current_scope
      (observation ~base_path call) |> frame in
  let restore () = Recovery.reconcile ~base_path ~scope:current_scope
      ~seed:empty ~checkpoint ~settled:[call] () in
  same "verified original joins existing checkpoint without repeating occurrence"
    checkpoint (restore () |> recover);
  check bool "original evidence removed for recovery fault" true
    (Tool_blob_store.delete store ~sha256:reference.sha256
     |> require (fun (error : Tool_blob_store.delete_error) -> error.reason));
  match restore () with
  | Error Recovery.Checkpoint_observation_not_settled -> ()
  | Ok _ | Error _ -> fail "lost original must refuse the previously verified checkpoint"

let () = Alcotest.run "native repetition recovery"
  ["canonical observations",
   [test_case "seed and occurrence multiplicity" `Quick test_seed_and_occurrence_multiplicity;
    test_case "checkpoint order and unrelated scope" `Quick test_checkpoint_order_and_other_scopes;
    test_case "handler provenance" `Quick test_actual_handler_provenance;
    test_case "observer failure and conflicts" `Quick test_observer_failure_and_conflicts;
    test_case "stored answer recovery requires original evidence" `Quick test_stored_answer_recovery_requires_original_evidence]]
