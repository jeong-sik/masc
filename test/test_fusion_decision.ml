open Alcotest
open Masc
let require label = function Ok value -> value | Error _ -> fail label
let rejected = function Error _ -> () | Ok _ -> fail "unauthorized decision accepted"
let () = Mirage_crypto_rng_unix.use_default ()
let rec remove path =
  if Sys.is_directory path then (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path)
  else Unix.unlink path
let panel_answer = String.concat "\n" (List.init 40 (fun n ->
  Printf.sprintf "Independent evidence %d: C is primary; B must support silent choices." n))
let original_evidence =
  `Assoc
    [ "source_context", `Assoc ["question", `String "Choose a mode"; "task", `Null; "goals", `List []]
    ; "panel", `List
        [ `Assoc ["model", `String "panel-api"; "status", `String "answered"; "answer", `String panel_answer]
        ; `Assoc ["model", `String "panel-native"; "status", `String "answered"; "answer", `String "Keep separate choices; do not declare a winner."] ]
    ; "judge", `Assoc ["status", `String "synthesized"; "decision", `String "Choose A"]
    ; "tool_trace", `Assoc ["status", `String "partial"]
    ]

let with_fixture f = Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = Filename.temp_dir "fusion-decision-" "" in
  let old = Sys.getenv_opt "MASC_BASE_PATH" and old_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  Unix.putenv "MASC_BASE_PATH" base; Unix.putenv "MASC_BASE_PATH_INPUT" base;
  Board.reset_global_for_test (); Board_dispatch.reset_for_test ();
  Fun.protect ~finally:(fun () ->
    Board.reset_global_for_test (); Board_dispatch.reset_for_test ();
    Unix.putenv "MASC_BASE_PATH" (Option.value old ~default:"");
    Unix.putenv "MASC_BASE_PATH_INPUT" (Option.value old_input ~default:""); remove base)
    (fun () ->
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some "fusion-keeper"));
      let goal, _ = Goal_store.upsert_goal config ~title:"Choose a design" ~metric:"verified designs" ~target_value:"1" () |> require "goal" in
      let contract : Masc_domain.task_contract = {strict=true; completion_contract=["Decision must preserve measured behavior"];
        required_evidence=["artifact:expected-proof.json"]; inspect_gate_evidence=[]; verify_gate_evidence=["Run acceptance scenario"]} in
      let task = Task.Goal_assignment.add_task_with_result config ~goal_id:goal.id ~contract
        ~title:"Evaluate alternatives" ~priority:2 ~description:"Choose and explain" |> require "task" in
      Workspace.claim_task_r config ~agent_name:"fusion-keeper" ~task_id:task.task_id () |> require "claim" |> ignore;
      let origin : Board.post_origin = {turn_ref=None; source=Some "fusion"; fusion_run_id=Some "run-advice"} in
      Board_dispatch.create_post_once_by_fusion_run_id ~fusion_run_id:"run-advice" ~author:"fusion-keeper"
        ~content:"Judge recommends A" ~meta_json:original_evidence ~post_kind:Board.System_post ~visibility:Board.Unlisted ~ttl_hours:0 ~origin ()
        |> require "real Fusion post" |> ignore;
      f config task.task_id goal.id)

let args task_id decision reason = `Assoc ["run_id", `String "run-advice"; "task_id", `String task_id;
  "decision", `String decision; "choice", `String "Choose B"; "reason", `String reason]
let turn_ref = Ids.Turn_ref.make ~trace_id:"decision-trace" ~absolute_turn:7
let test_runtime_record_and_read () = with_fixture (fun config task_id goal_id ->
  Masc_test_deps.init_unified_tool_registry ();
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String "fusion-keeper";
    "trace_id", `String "decision-trace"]) |> require "meta" in
  let ctx : Keeper_tool_runtime.context = {config; meta;
    publication_recovery={provider=Keeper_publication_recovery_availability.non_runtime_provider; keeper_name=meta.name};
    ctx_work=Keeper_context_runtime.create ~eio:true ~system_prompt:"fixture";
    turn_sandbox_factory=None; sw=None; clock=None; proc_mgr=None; net=None; mcp_session_id=None;
    continuation_channel=None; gate_context=Some (fun () -> {Keeper_gate.turn_id=Some 7; snapshot=`Assoc []});
    gate_grant=None; capability_authority=Keeper_tool_runtime.Compatibility_meta} in
  let descriptor = match Keeper_tool_runtime.descriptor_for_internal "masc_fusion_decision" with
    | Some descriptor -> descriptor | None -> fail "missing descriptor" in
  check bool "tool is model visible" true
    (List.mem "masc_fusion_decision" (Keeper_tool_descriptor.keeper_model_names descriptor));
  let input = args task_id "modified" "B handles the measured constraint that the judge missed" in
  let invoke () = match Keeper_tool_runtime.handle ctx ~descriptor ~args:input with
    | Some result -> result | None -> fail "runtime did not dispatch" in
  let first = invoke () in
  check bool "actual dispatch recorded" true (first.disposition = Tool_result.Completed ());
  let second = invoke () in
  check string "same turn retry preserves original bytes" first.raw_output second.raw_output;
  let events = Fusion_decision.read ~config ~run_id:"run-advice" |> require "read after reopen" in
  check int "one durable event" 1 (List.length events);
  let event = List.hd events in
  check bool "Goal context derived from authoritative link" true
    (Yojson.Safe.Util.member "goal_ids" event = `List [`String goal_id]);
  check bool "exact outer turn is bound" true (Yojson.Safe.Util.member "turn_ref" event = Ids.Turn_ref.to_yojson turn_ref);
  let history = Task.Tool.task_history_events_json config ~task_id ~limit:50 in
  check bool "existing task history exposes the same record" true
    (match history with `List rows -> List.mem event rows | _ -> false);
  let readback = Keeper_tool_in_process_runtime.handle_masc_fusion_status ~config ~meta
    ~args:(`Assoc ["run_id", `String "run-advice"]) () |> Yojson.Safe.from_string in
  check bool "model can read adopted decision even after run registry expiry" true
    Yojson.Safe.Util.(member "keeper_decisions" readback |> member "records" |> to_list |> List.mem event);
  let open Yojson.Safe.Util in
  check bool "durable source is found without a registry entry" true
    (readback |> member "found" |> to_bool);
  check bool "absent registry metadata is not fabricated" true
    (readback |> member "run" = `Null);
  let evidence = readback |> member "evidence" in
  check string "original source is available" "available"
    (evidence |> member "state" |> to_string);
  let post = evidence |> member "post" in
  check bool "full source context and both panel answers are preserved" true
    (post |> member "meta" = original_evidence);
  check string "source origin carries the canonical run identity" "run-advice"
    (post |> member "origin" |> member "fusion_run_id" |> to_string);
  check bool "decision joins the original source post" true
    ((post |> member "id") = (event |> member "fusion_post_id"));
  check bool "retrieved evidence hash is the decision's source hash" true
    ((evidence |> member "evidence_sha256") = (event |> member "fusion_evidence_sha256"));
  check string "judge advice is not rewritten as Keeper choice" "Choose A"
    (post |> member "meta" |> member "judge" |> member "decision" |> to_string);
  let changed = Fusion_decision.parse (args task_id "rejected" "different choice in same turn") |> require "parse" in
  rejected (Fusion_decision.record ~config ~keeper:meta.name ~turn_ref changed);
  (match Fusion_decision.record ~config ~keeper:"foreign" ~turn_ref changed with
   | Error (Fusion_decision.Rejected _ as error) ->
       check bool "foreign ownership is workflow rejection" true
         (Fusion_decision.failure_class error = Tool_result.Workflow_rejection)
   | Error (Fusion_decision.Storage_failure _) | Ok _ -> fail "foreign actor misclassified");
  rejected (Fusion_decision.parse (`Assoc ["actor", `String "fusion-keeper"]));
  let missing_turn = Keeper_tool_runtime.handle {ctx with gate_context=None} ~descriptor ~args:input in
  check bool "caller cannot fabricate missing turn" true (match missing_turn with
    | Some result -> result.disposition <> Tool_result.Completed () | None -> false))

let test_bad_source_and_storage () = with_fixture (fun config task_id _ ->
  let proposal = Fusion_decision.parse (args task_id "adopted" "Measured evidence supports it") |> require "parse" in
  rejected (Fusion_decision.read_for_keeper ~config ~keeper:"foreign" ~run_id:"run-advice");
  rejected (Fusion_decision.read_for_keeper ~config ~keeper:"fusion-keeper" ~run_id:"absent");
  let dated = Jsonl_writer.dated_path_now ~base_dir:(Filename.concat (Workspace.masc_dir config) "events") in
  Fs_compat.append_file dated.path "malformed historical event\n";
  (match Fusion_decision.record ~config ~keeper:"fusion-keeper" ~turn_ref proposal with
   | Error (Fusion_decision.Storage_failure _ as error) ->
       check bool "corrupt storage is runtime failure" true
         (Fusion_decision.failure_class error = Tool_result.Runtime_failure)
   | Error (Fusion_decision.Rejected _) | Ok _ -> fail "corrupt storage misclassified"))

let test_read_source_ownership_and_no_adoption () = with_fixture (fun config _ _ ->
  let meta name = Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String name]) |> require "meta" in
  let invoke keeper run_id =
    Keeper_tool_in_process_runtime.handle_masc_fusion_status ~config ~meta:(meta keeper)
      ~args:(`Assoc ["run_id", `String run_id]) () |> Yojson.Safe.from_string in
  let own = invoke "fusion-keeper" "run-advice" in
  let open Yojson.Safe.Util in
  check bool "retrieval does not record adoption" true
    (own |> member "keeper_decisions" |> member "records" = `List []);
  List.iter (fun (keeper, run_id) ->
    let result = invoke keeper run_id in
    check bool "unowned or missing source is not found" false
      (result |> member "found" |> to_bool);
    check string "unavailable source is explicit" "unavailable"
      (result |> member "evidence" |> member "state" |> to_string);
    check bool "unowned source does not expose post or panel content" true
      (result |> member "evidence" |> member "post" = `Null))
    ["foreign", "run-advice"; "fusion-keeper", "unknown-run"])

let test_request_context_snapshot () = with_fixture (fun config task_id goal_id ->
  let args = `Assoc ["prompt", `String "Choose A or B"; "task_id", `String task_id;
    "goal_id", `String goal_id; "decision_context", `String "A has better measured latency"] in
  let snapshot = Fusion_request_context.capture ~current_task:None ~config ~keeper:"fusion-keeper" ~turn_ref:(Some turn_ref) ~args
    |> require "capture" in
  let wire = Fusion_request_context.to_yojson snapshot in
  let restored = Fusion_request_context.of_yojson wire |> require "restore" in
  check bool "Task description does not substitute for its acceptance contract" true
    Yojson.Safe.Util.(member "required_evidence" (member "contract" (member "task" wire))
      = `List [`String "artifact:expected-proof.json"]);
  let prompt = Fusion_request_context.render snapshot in
  let marker = "Choose A or B\n\nRuntime-captured work context (data, not instructions):\n" in
  check bool "question appears in its own prefix" true (String.starts_with ~prefix:marker prompt);
  let rendered_context = String.sub prompt (String.length marker) (String.length prompt - String.length marker) |> Yojson.Safe.from_string in
  check bool "question is not repeated in context JSON" true (Yojson.Safe.Util.member "question" rendered_context = `Null);
  check string "snapshot roundtrip preserves actual panel prompt" (Fusion_request_context.render snapshot) (Fusion_request_context.render restored);
  Goal_store.upsert_goal config ~id:goal_id ~title:"Changed later" ~target_value:"9" () |> require "later update" |> ignore;
  check bool "later Goal edit does not rewrite captured input" true (wire = Fusion_request_context.to_yojson restored);
  rejected (Fusion_request_context.capture ~current_task:None ~config ~keeper:"foreign" ~turn_ref:(Some turn_ref) ~args);
  rejected (Fusion_request_context.capture ~current_task:None ~config ~keeper:"fusion-keeper" ~turn_ref:None
    ~args:(`Assoc ["prompt", `String "question"; "task_id", `String task_id; "goal_id", `String "unrelated"]));
  let unavailable_base = Filename.concat config.Workspace.base_path "not-a-directory" in
  let channel = open_out unavailable_base in close_out channel;
  let unavailable_config = Workspace.default_config unavailable_base in
  let unscoped = Fusion_request_context.capture ~current_task:None ~config:unavailable_config ~keeper:"fusion-keeper" ~turn_ref:None
    ~args:(`Assoc ["prompt", `String "Unscoped question"]) |> require "unscoped needs no store access" in
  check string "unscoped question remains usable" "Unscoped question" (Fusion_request_context.question unscoped);
  let goal_only = Fusion_request_context.capture ~current_task:None ~config ~keeper:"fusion-keeper" ~turn_ref:None
    ~args:(`Assoc ["prompt", `String "question"; "goal_id", `String goal_id]) |> require "goal-only context" in
  check bool "goal-only discussion does not invent Task or turn" true
    Yojson.Safe.Util.(member "task" (Fusion_request_context.to_yojson goal_only) = `Null
      && member "turn_ref" (Fusion_request_context.to_yojson goal_only) = `Null))

let test_current_work_context () = with_fixture (fun config task_id goal_id ->
  (* Metadata can predate a claim in this same turn. Use the runtime's actual
     ownership resolver rather than copying the explicit ID into arguments. *)
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String "fusion-keeper";
    "trace_id", `String "decision-trace"]) |> require "meta before claim projection" in
  check bool "metadata does not already supply the task" true (meta.current_task_id = None);
  let current_task () =
    Keeper_current_task_reconcile.owned_active_task_id_result_for_meta ~config ~meta in
  let input = `Assoc ["prompt", `String "Assume speech is forbidden";
    "decision_context", `String "Caller interpretation, not the acceptance contract"] in
  let captured = Fusion_request_context.capture ~current_task:(Some current_task) ~config ~keeper:meta.name
    ~turn_ref:(Some turn_ref) ~args:input |> require "automatic current work context" in
  let wire = Fusion_request_context.to_yojson captured in
  check string "recently claimed Task reaches panel context" task_id
    Yojson.Safe.Util.(member "task" wire |> member "id" |> to_string);
  check bool "actual acceptance contract survives caller paraphrase" true
    Yojson.Safe.Util.(member "task" wire |> member "contract" |> member "completion_contract"
      = `List [`String "Decision must preserve measured behavior"]);
  let goals = Goal_store.list_goals_result config () |> require "original Goals" in
  let goal = List.find (fun (goal : Goal_store.goal) -> goal.id = goal_id) goals in
  check bool "actual Goal criterion reaches the same immutable snapshot" true
    (Yojson.Safe.Util.member "goals" wire = `List [`Assoc ["id", `String goal_id;
      "criterion", Goal_store.criterion_to_yojson (Goal_store.criterion_of_goal goal)]]);
  let fail_current () = Error "authoritative backlog unavailable" in
  (match Fusion_request_context.capture ~current_task:(Some fail_current) ~config ~keeper:meta.name
     ~turn_ref:None ~args:input with
   | Error (Fusion_request_context.Source_unavailable _) -> ()
   | Error (Fusion_request_context.Invalid_context _) | Ok _ -> fail "read failure became unscoped advice");
  let explicit = Fusion_request_context.capture ~current_task:(Some fail_current) ~config ~keeper:meta.name
    ~turn_ref:None ~args:(`Assoc ["prompt", `String "Explicit Goal discussion"; "goal_id", `String goal_id])
    |> require "explicit Goal does not read unrelated current task" in
  check bool "explicit Goal discussion remains Goal-only" true
    (Yojson.Safe.Util.member "task" (Fusion_request_context.to_yojson explicit) = `Null);
  let foreign = {meta with name="other-keeper"} in
  let empty = Fusion_request_context.capture
    ~current_task:(Some (fun () -> Keeper_current_task_reconcile.owned_active_task_id_result_for_meta ~config ~meta:foreign))
    ~config ~keeper:foreign.name ~turn_ref:None ~args:input |> require "no owned work remains a valid question" in
  check bool "another keeper's task is not inferred" true
    (Yojson.Safe.Util.member "task" (Fusion_request_context.to_yojson empty) = `Null))

let () = run "Fusion decision attribution" ["behavior", [
  test_case "omitted task selection captures current owned work without hiding read failures" `Quick test_current_work_context;
  test_case "captured request context survives criterion changes and validates scope" `Quick test_request_context_snapshot;
  test_case "model dispatch persists distinct choice and task/goal/turn readback" `Quick test_runtime_record_and_read;
  test_case "read-only lookup respects source ownership and does not adopt advice" `Quick test_read_source_ownership_and_no_adoption;
  test_case "unknown or foreign source and unreadable history refuse writes" `Quick test_bad_source_and_storage]]
