open Alcotest
open Masc
let require label = function Ok value -> value | Error _ -> fail label
let rejected = function Error _ -> () | Ok _ -> fail "unauthorized decision accepted"
let () = Mirage_crypto_rng_unix.use_default ()
let rec remove path =
  if Sys.is_directory path then (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path)
  else Unix.unlink path
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
      let task = Task_goal_assignment.add_task_with_result config ~goal_id:goal.id
        ~title:"Evaluate alternatives" ~priority:2 ~description:"Choose and explain" |> require "task" in
      Workspace.claim_task_r config ~agent_name:"fusion-keeper" ~task_id:task.task_id () |> require "claim" |> ignore;
      let origin : Board.post_origin = {turn_ref=None; source=Some "fusion"; fusion_run_id=Some "run-advice"} in
      Board_dispatch.create_post_once_by_fusion_run_id ~fusion_run_id:"run-advice" ~author:"fusion-keeper"
        ~content:"Judge recommends A" ~post_kind:Board.System_post ~visibility:Board.Unlisted ~ttl_hours:0 ~origin ()
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
  let changed = Fusion_decision.parse (args task_id "rejected" "different choice in same turn") |> require "parse" in
  rejected (Fusion_decision.record ~config ~keeper:meta.name ~turn_ref changed);
  rejected (Fusion_decision.record ~config ~keeper:"foreign" ~turn_ref changed);
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
  rejected (Fusion_decision.record ~config ~keeper:"fusion-keeper" ~turn_ref proposal))

let () = run "Fusion decision attribution" ["behavior", [
  test_case "model dispatch persists distinct choice and task/goal/turn readback" `Quick test_runtime_record_and_read;
  test_case "unknown or foreign source and unreadable history refuse writes" `Quick test_bad_source_and_storage]]
