(** Tests for the typed pending_phase HITL state machine (RFC-0304).

    Proves:
    1. Fresh pending approvals start in [Awaiting_operator].
    2. The phase is included in pending-entry JSON/SSE payloads.
    3. Critical approvals transition to [Escalated] when the escalation timer
       fires, and the updated phase is reflected in-memory and in JSON. *)

module Raw_AQ = Masc.Keeper_approval_queue

module AQ = struct
  include Raw_AQ

  let pending_scopes : (string, string) Hashtbl.t = Hashtbl.create 32

  let base_path_for_id_opt id =
    match Hashtbl.find_opt pending_scopes id with
    | Some base_path -> Some base_path
    | None ->
      (match For_testing.pending_base_path ~id with
       | Some base_path ->
         Hashtbl.replace pending_scopes id base_path;
         Some base_path
       | None -> None)
  ;;

  let base_path_for_id id =
    match base_path_for_id_opt id with
    | Some base_path -> base_path
    | None -> Alcotest.failf "pending approval %s has no workspace" id
  ;;

  let resolve ~id ~decision =
    Raw_AQ.resolve ~base_path:(base_path_for_id id) ~id ~decision
  ;;

  let get_pending_entry ~id =
    match base_path_for_id_opt id with
    | Some base_path -> Raw_AQ.get_pending_entry ~base_path ~id
    | None -> None
  ;;

  let get_pending_json ~id =
    match base_path_for_id_opt id with
    | Some base_path -> Raw_AQ.get_pending_json ~base_path ~id
    | None -> None
  ;;

  let list_pending_entries = For_testing.list_pending_entries
  let pending_count = For_testing.pending_count
  let pending_count_for_keeper = For_testing.pending_count_for_keeper
  let blocking_pending_count_for_keeper = For_testing.blocking_pending_count_for_keeper
  let has_blocking_pending_for_keeper = For_testing.has_blocking_pending_for_keeper
  let has_pending_for_keeper = For_testing.has_pending_for_keeper
end
module Chat_queue = Masc.Keeper_chat_queue
module Summary_worker = Masc.Hitl_summary_worker

let install_durable_resolution_delivery_hook () =
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path ~keeper_name ~approval_id ~decision ~channel ->
      let resolution = Keeper_event_queue.{ approval_id; decision; channel } in
      let stimulus : Keeper_event_queue.stimulus =
        { post_id = Keeper_event_queue.hitl_resolution_post_id resolution
        ; urgency = Keeper_event_queue.Immediate
        ; arrived_at = Unix.gettimeofday ()
        ; payload = Keeper_event_queue.Hitl_resolved resolution
        }
      in
      match
        Masc.Keeper_registry_event_queue.enqueue_durable_result
          ~base_path
          keeper_name
          stimulus
      with
      | Error _ as err -> err
      | Ok () -> Ok (fun () -> ()))
;;

let () = install_durable_resolution_delivery_hook ()

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_approval_queue_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec rm_rf path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  try rm_rf dir with
  | _ -> ()
;;

let blocking_callback ?(effect_key = "test-blocking-effect") callback
    ~approval_id decision =
  AQ.blocking_resolution_plan
    ~effect_key:(effect_key ^ ":" ^ approval_id)
    ~commit:(fun () ->
      callback decision;
      fun () -> ())
;;

let rec yield_until ?(attempts = 50) predicate =
  if predicate () || attempts <= 0
  then ()
  else (
    Eio.Fiber.yield ();
    yield_until ~attempts:(attempts - 1) predicate)
;;

let with_temp_runtime_toml content f =
  let path = Filename.temp_file "runtime" ".toml" in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () -> f path)
;;

let summary_routing_runtime_toml ~with_hitl_summary =
  let base =
    "[providers.local]\n\
     display-name = \"Local\"\n\
     protocol = \"ollama-http\"\n\
     endpoint = \"http://localhost:11434\"\n\
     \n\
     [models.chat]\n\
     api-name = \"chat\"\n\
     max-context = 1024\n\
     \n\
     [models.judge]\n\
     api-name = \"judge\"\n\
     max-context = 1024\n\
     \n\
     [models.judge.capabilities]\n\
     supports-structured-output = true\n\
     \n\
     [models.kimi_like]\n\
     api-name = \"kimi-like-summary\"\n\
     max-context = 1024\n\
     temperature = 1.0\n\
     \n\
     [local.chat]\n\
     \n\
     [local.judge]\n\
     \n\
     [local.kimi_like]\n\
     \n\
     [runtime]\n\
     default = \"local.chat\"\n\
     structured_judge = \"local.judge\"\n"
  in
  if with_hitl_summary then base ^ "hitl_summary = \"local.kimi_like\"\n" else base
;;

(* Proves the HITL summary worker consumes the [runtime].hitl_summary lane
   (not the structured-judge lane directly): the operator-selected lane must
   win, and unset deployments must fall back to structured_judge. *)
let test_provider_config_for_summary_routes_hitl_summary_lane () =
  let load_and_resolve ~with_hitl_summary =
    let text = summary_routing_runtime_toml ~with_hitl_summary in
    with_temp_runtime_toml text (fun path ->
      match Runtime.save_config_text ~runtime_config_path:path text with
      | Error msg -> Alcotest.failf "runtime config should load: %s" msg
      | Ok () ->
        (match AQ.provider_config_for_summary ~keeper_name:"no-such-keeper" with
         | None -> None
         | Some selected ->
           let worker_cfg, _mode =
             Summary_worker.For_testing.provider_config_for_summary
               ~runtime_id:selected.runtime_id
               selected.provider_config
           in
           Some (selected, worker_cfg)))
  in
  (match load_and_resolve ~with_hitl_summary:true with
   | None -> Alcotest.fail "expected a provider config for the hitl_summary lane"
   | Some (selected, worker_cfg) ->
     Alcotest.(check string)
       "hitl_summary runtime id is preserved"
       "local.kimi_like"
       selected.runtime_id;
     Alcotest.(check string)
       "hitl_summary lane model is used"
       "kimi-like-summary"
       selected.provider_config.Llm_provider.Provider_config.model_id;
     Alcotest.(check (option (float 0.0001)))
       "HITL worker preserves runtime.toml temperature"
       (Some 1.0)
       worker_cfg.temperature);
  match load_and_resolve ~with_hitl_summary:false with
  | None -> Alcotest.fail "expected structured_judge fallback config"
  | Some (selected, _worker_cfg) ->
    Alcotest.(check string)
      "structured_judge fallback runtime id is preserved"
      "local.judge"
      selected.runtime_id;
    Alcotest.(check string)
      "structured_judge fallback model is used"
      "judge"
      selected.provider_config.Llm_provider.Provider_config.model_id
;;

let pending_id_for_keeper ~keeper_name =
  AQ.list_pending_entries ()
  |> List.find_map (fun (entry : AQ.pending_approval) ->
    if String.equal entry.keeper_name keeper_name then Some entry.id else None)
;;

let phase_in_json json =
  let open Yojson.Safe.Util in
  json |> member "phase" |> to_string
;;

let test_fresh_critical_entry_phase_is_awaiting_operator () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let keeper_name = "fresh-critical-phase-test" in
       let result = ref None in
       Eio.Fiber.fork ~sw (fun () ->
         let decision =
           AQ.submit_and_await
             ~keeper_name
             ~tool_name:"keeper_continue_after_reconcile"
             ~input:(`Assoc [ ("kind", `String "critical_gate") ])
             ~risk_level:AQ.Critical
             ~base_path
             ()
         in
         result := Some decision);
       yield_until (fun () -> Option.is_some (pending_id_for_keeper ~keeper_name));
       let id =
         match pending_id_for_keeper ~keeper_name with
         | Some id -> id
         | None -> Alcotest.fail "Critical approval was not queued"
       in
       let entry =
         match AQ.get_pending_entry ~id with
         | Some entry -> entry
         | None -> Alcotest.fail "in-memory entry not found"
       in
       Alcotest.(check bool)
         "submit_and_await entry owns a blocking lane"
         true
         (AQ.has_blocking_pending_for_keeper ~keeper_name);
       Alcotest.(check bool)
         "fresh Critical entry is Awaiting_operator in-memory"
         true
         (entry.phase = AQ.Awaiting_operator);
       let detail =
         match AQ.get_pending_json ~id with
         | Some json -> json
         | None -> Alcotest.fail "pending detail JSON not found"
       in
       Alcotest.(check string)
         "fresh Critical entry is awaiting_operator in JSON"
         "awaiting_operator"
         (phase_in_json detail);
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err ->
          Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
       yield_until (fun () -> Option.is_some !result);
       match !result with
       | Some Agent_sdk.Hooks.Approve -> ()
       | Some decision ->
         Alcotest.fail
           ("expected Approve, got " ^ AQ.approval_decision_to_string decision)
       | None -> Alcotest.fail "Critical approval did not resume after resolve")
;;

(* Blocking approvals resume through their live resolver. Non-blocking
   approvals have no suspended fiber, so resolving them must fire the wake hook
   that enqueues a [Hitl_resolved] stimulus. Without that wake the keeper only
   resumes on an unrelated stimulus / no-progress recovery / the 30-minute
   janitor (the reported "HITL 됐는데 핑을 못 받음"). *)
let test_resolve_with_live_resolver_does_not_fire_keeper_wake_hook () =
  Eio_main.run
  @@ fun _env ->
  let base_path = temp_dir () in
  let woke = ref None in
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path:_
      ~keeper_name
      ~approval_id
      ~decision
      ~channel:_ ->
      Ok (fun () -> woke := Some (keeper_name, approval_id, decision)));
  Fun.protect
    ~finally:(fun () ->
      install_durable_resolution_delivery_hook ();
      cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run
       @@ fun sw ->
       let keeper_name = "resolve-wake-test" in
       let result = ref None in
       Eio.Fiber.fork ~sw (fun () ->
         let decision =
           AQ.submit_and_await
             ~keeper_name
             ~tool_name:"keeper_continue_after_reconcile"
             ~input:(`Assoc [ "kind", `String "critical_gate" ])
             ~risk_level:AQ.Critical
             ~base_path
             ()
         in
         result := Some decision);
       yield_until (fun () -> Option.is_some (pending_id_for_keeper ~keeper_name));
       let id =
         match pending_id_for_keeper ~keeper_name with
         | Some id -> id
         | None -> Alcotest.fail "Critical approval was not queued"
       in
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err ->
          Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
       (match !woke with
        | Some _ -> Alcotest.fail "live resolver must resume directly without wake hook"
        | None -> ());
       yield_until (fun () -> Option.is_some !result))
;;

let test_submit_pending_resolve_fires_keeper_wake_hook () =
  Eio_main.run
  @@ fun _env ->
  let base_path = temp_dir () in
  let woke = ref None in
  let completion_order = ref [] in
  let observer_saw_pending = ref true in
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path:_
      ~keeper_name
      ~approval_id
      ~decision
      ~channel:_ ->
      Ok
        (fun () ->
           completion_order := "signal" :: !completion_order;
           woke := Some (keeper_name, approval_id, decision)));
  Fun.protect
    ~finally:(fun () ->
      install_durable_resolution_delivery_hook ();
      cleanup_dir base_path)
    (fun () ->
       let keeper_name = "pending-resolve-wake-test" in
       let callback_decision = ref None in
       let input = `Assoc [ "kind", `String "critical_gate" ] in
       let id =
         AQ.submit_pending_observer
           ~keeper_name
           ~tool_name:"keeper_continue_after_reconcile"
           ~input
           ~risk_level:AQ.Critical
           ~base_path
           ~on_resolution_observer:(fun decision ->
             observer_saw_pending := AQ.has_pending_for_keeper ~keeper_name;
             completion_order := "observer" :: !completion_order;
             callback_decision := Some decision)
           ()
       in
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err ->
          Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
       Alcotest.(check bool)
         "nonblocking resolution observer ran"
         true
         (Option.is_some !callback_decision);
       Alcotest.(check (list string))
         "observer runs before wake signal"
         [ "observer"; "signal" ]
         (List.rev !completion_order);
       Alcotest.(check bool)
         "pending id is gone before observer"
         false
         !observer_saw_pending;
       (match !woke with
        | Some (kn, aid, decision) ->
          Alcotest.(check string) "wake targets the waiting keeper" keeper_name kn;
          Alcotest.(check string) "wake carries the resolved approval id" id aid;
          (match decision with
           | Keeper_event_queue.Hitl_approved action ->
             Alcotest.(check bool)
               "wake carries the exact approved action"
               true
               (AQ.approved_action_matches_request
                  action
                  ~keeper_name
                  ~tool_name:"keeper_continue_after_reconcile"
                  ~input)
           | Keeper_event_queue.Hitl_rejected | Keeper_event_queue.Hitl_edited ->
             Alcotest.fail "approved queue entry emitted a non-approved wake")
        | None -> Alcotest.fail "non-blocking resolve did not fire the keeper wake hook"))
;;

let test_delivery_failure_keeps_nonblocking_approval_pending () =
  let base_path = temp_dir () in
  let callback_decision = ref None in
  AQ.For_testing.clear_approval_resolution_wake_hook ();
  Fun.protect
    ~finally:(fun () ->
      install_durable_resolution_delivery_hook ();
      cleanup_dir base_path)
    (fun () ->
       let id =
         AQ.submit_pending_observer
           ~keeper_name:"delivery-failure-pending-test"
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "medium_gate" ])
           ~risk_level:AQ.Medium
           ~base_path
           ~on_resolution_observer:(fun decision -> callback_decision := Some decision)
           ()
       in
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Error (AQ.Delivery_failed { approval_id; reason }) ->
          Alcotest.(check string) "failure identifies approval" id approval_id;
          Alcotest.(check bool) "failure reason is explicit" true
            (String.length reason > 0)
        | Error err ->
          Alcotest.fail
            ("expected Delivery_failed, got " ^ AQ.resolve_error_to_string err)
        | Ok () -> Alcotest.fail "resolve must fail without a delivery hook");
       Alcotest.(check bool) "failed delivery keeps pending entry" true
         (Option.is_some (AQ.get_pending_entry ~id));
       Alcotest.(check bool) "failed delivery does not run callback" true
         (Option.is_none !callback_decision);
       install_durable_resolution_delivery_hook ();
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
       Alcotest.(check bool) "successful retry removes pending entry" true
         (Option.is_none (AQ.get_pending_entry ~id));
       Alcotest.(check bool) "successful retry runs callback" true
         (Option.is_some !callback_decision))
;;

let test_nonblocking_observer_runs_after_durable_commit_and_removal () =
  let base_path = temp_dir () in
  let completion_order = ref [] in
  let observer_saw_pending = ref true in
  let approval_id = ref None in
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path:_ ~keeper_name:_ ~approval_id:_ ~decision:_ ~channel:_ ->
      completion_order := "durable" :: !completion_order;
      Ok (fun () -> completion_order := "signal" :: !completion_order));
  Fun.protect
    ~finally:(fun () ->
      install_durable_resolution_delivery_hook ();
      cleanup_dir base_path)
    (fun () ->
       let id =
         AQ.submit_pending_observer
           ~keeper_name:"observer-after-delivery-test"
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "medium_gate" ])
           ~risk_level:AQ.Medium
           ~base_path
           ~on_resolution_observer:(fun _decision ->
             observer_saw_pending :=
               (match !approval_id with
                | Some id -> Option.is_some (AQ.get_pending_entry ~id)
                | None -> true);
             completion_order := "observer" :: !completion_order)
           ()
       in
       approval_id := Some id;
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
       Alcotest.(check bool)
         "observer runs after pending removal"
         false
         !observer_saw_pending;
       Alcotest.(check (list string))
         "durable commit precedes observer and live signal"
         [ "durable"; "observer"; "signal" ]
         (List.rev !completion_order))
;;

let test_nonblocking_observer_failure_is_non_authoritative () =
  let base_path = temp_dir () in
  let durable_committed = ref false in
  let signal_fired = ref false in
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path:_ ~keeper_name:_ ~approval_id:_ ~decision:_ ~channel:_ ->
      durable_committed := true;
      Ok (fun () -> signal_fired := true));
  Fun.protect
    ~finally:(fun () ->
      install_durable_resolution_delivery_hook ();
      cleanup_dir base_path)
    (fun () ->
       let id =
         AQ.submit_pending_observer
           ~keeper_name:"observer-failure-test"
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "medium_gate" ])
           ~risk_level:AQ.Medium
           ~base_path
           ~on_resolution_observer:(fun _decision ->
             failwith "synthetic observer failure")
           ()
       in
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
       Alcotest.(check bool) "durable decision committed" true !durable_committed;
       Alcotest.(check bool)
         "observer failure cannot restore the pending approval"
         true
         (Option.is_none (AQ.get_pending_entry ~id));
       Alcotest.(check bool)
         "observer failure cannot suppress the committed wake signal"
         true
         !signal_fired)
;;

let test_nonblocking_observer_cancellation_defers_until_after_signal () =
  let base_path = temp_dir () in
  let signal_fired = ref false in
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path:_ ~keeper_name:_ ~approval_id:_ ~decision:_ ~channel:_ ->
      Ok (fun () -> signal_fired := true));
  Fun.protect
    ~finally:(fun () ->
      install_durable_resolution_delivery_hook ();
      cleanup_dir base_path)
    (fun () ->
       let id =
         AQ.submit_pending_observer
           ~keeper_name:"observer-cancellation-test"
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "medium_gate" ])
           ~risk_level:AQ.Medium
           ~base_path
           ~on_resolution_observer:(fun _decision ->
             raise (Eio.Cancel.Cancelled (Failure "synthetic observer cancellation")))
           ()
       in
       let cancellation_propagated =
         match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
         | exception Eio.Cancel.Cancelled _ -> true
         | Ok () | Error _ -> false
       in
       Alcotest.(check bool)
         "observer cancellation propagates after commit"
         true
         cancellation_propagated;
       Alcotest.(check bool)
         "observer cancellation cannot restore the pending approval"
         true
         (Option.is_none (AQ.get_pending_entry ~id));
       Alcotest.(check bool)
         "observer cancellation cannot suppress the committed wake signal"
         true
         !signal_fired)
;;

let test_blocking_callback_failure_and_cancellation_keep_pending () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let submit keeper_name callback =
         AQ.submit_pending_blocking
           ~keeper_name
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String keeper_name ])
           ~risk_level:AQ.Critical
           ~base_path
           ~on_resolution:(blocking_callback callback)
           ()
       in
       let callback_should_fail = ref true in
       let failed_id =
         submit "blocking-callback-exception-test" (fun _ ->
           if !callback_should_fail then failwith "synthetic callback")
       in
       (match AQ.resolve ~id:failed_id ~decision:Agent_sdk.Hooks.Approve with
        | Error (AQ.Delivery_failed _) -> ()
        | Error err -> Alcotest.fail (AQ.resolve_error_to_string err)
        | Ok () -> Alcotest.fail "callback exception must fail resolution");
       Alcotest.(check bool)
         "callback exception keeps blocking entry pending"
         true
         (Option.is_some (AQ.get_pending_entry ~id:failed_id));
       callback_should_fail := false;
       (match AQ.resolve ~id:failed_id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
       let callback_should_cancel = ref true in
       let cancelled_id =
         submit "blocking-callback-cancel-test" (fun _ ->
           if !callback_should_cancel
           then raise (Eio.Cancel.Cancelled (Failure "synthetic callback cancellation")))
       in
       let cancelled_propagated =
         match AQ.resolve ~id:cancelled_id ~decision:Agent_sdk.Hooks.Approve with
         | exception Eio.Cancel.Cancelled _ -> true
         | Ok () | Error _ -> false
       in
       Alcotest.(check bool) "callback cancellation propagates" true cancelled_propagated;
       Alcotest.(check bool)
         "callback cancellation keeps blocking entry pending"
         true
         (Option.is_some (AQ.get_pending_entry ~id:cancelled_id));
       callback_should_cancel := false;
       match AQ.resolve ~id:cancelled_id ~decision:Agent_sdk.Hooks.Approve with
       | Ok () -> ()
       | Error err -> Alcotest.fail (AQ.resolve_error_to_string err))
;;

let test_resolve_with_policy_rejects_wrong_workspace () =
  let owner_base_path = temp_dir () in
  let caller_base_path = temp_dir () in
  let callback_called = ref false in
  let claim_hook_called = ref false in
  Raw_AQ.For_testing.set_resolution_claim_hook (fun _ _ -> claim_hook_called := true);
  Fun.protect
    ~finally:(fun () ->
      Raw_AQ.For_testing.clear_resolution_claim_hook ();
      cleanup_dir owner_base_path;
      cleanup_dir caller_base_path)
    (fun () ->
       let id =
         AQ.submit_pending_observer
           ~keeper_name:"wrong-workspace-test"
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "workspace_gate" ])
           ~risk_level:AQ.Medium
           ~base_path:owner_base_path
           ~on_resolution_observer:(fun _ -> callback_called := true)
           ()
       in
       (match
          AQ.resolve_with_policy
            ~base_path:caller_base_path
            ~id
            ~decision:Agent_sdk.Hooks.Approve
            ()
        with
        | Error (AQ.Delivery_failed { reason; _ }) ->
          Alcotest.(check bool)
            "mismatch reason names the caller contract"
            true
            (String.starts_with ~prefix:"caller workspace mismatch" reason)
        | Error err -> Alcotest.fail (AQ.resolve_error_to_string err)
        | Ok _ -> Alcotest.fail "wrong workspace must not resolve an approval");
       Alcotest.(check bool) "wrong workspace does not run callback" false !callback_called;
       Alcotest.(check bool)
         "wrong workspace is rejected before terminal claim"
         false
         !claim_hook_called;
       Alcotest.(check bool)
         "wrong workspace keeps owner entry pending"
         true
         (Option.is_some (AQ.get_pending_entry ~id));
       match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
       | Ok () -> ()
       | Error err -> Alcotest.fail (AQ.resolve_error_to_string err))
;;

let test_identical_approvals_do_not_dedupe_across_workspaces () =
  let first_base_path = temp_dir () in
  let second_base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir first_base_path;
      cleanup_dir second_base_path)
    (fun () ->
       let submit base_path =
         AQ.submit_pending_observer
           ~keeper_name:"cross-workspace-dedupe-test"
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "identical_gate" ])
           ~risk_level:AQ.Medium
           ~base_path
           ~on_resolution_observer:(fun _ -> ())
           ()
       in
       let first_id = submit first_base_path in
       let second_id = submit second_base_path in
       Alcotest.(check bool)
         "identical approvals in different workspaces get distinct ids"
         true
         (not (String.equal first_id second_id));
       let entry_base_path id =
         match AQ.get_pending_entry ~id with
         | Some entry -> entry.audit_base_path
         | None -> Alcotest.failf "pending approval %s disappeared" id
       in
       Alcotest.(check string)
         "first approval retains its workspace"
         first_base_path
         (entry_base_path first_id);
       Alcotest.(check string)
         "second approval retains its workspace"
         second_base_path
         (entry_base_path second_id);
       List.iter
         (fun id ->
            match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
            | Ok () -> ()
            | Error err -> Alcotest.fail (AQ.resolve_error_to_string err))
         [ first_id; second_id ])
;;

let test_blocking_callback_policy_owns_lane_without_resolver () =
  let base_path = temp_dir () in
  let woke = ref false in
  let callback_decision = ref None in
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path:_ ~keeper_name:_ ~approval_id:_ ~decision:_ ~channel:_ ->
      Ok (fun () -> woke := true));
  Fun.protect
    ~finally:(fun () ->
      install_durable_resolution_delivery_hook ();
      cleanup_dir base_path)
    (fun () ->
       let keeper_name = "blocking-callback-policy-test" in
       let id =
         AQ.submit_pending_blocking
           ~keeper_name
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "lifecycle_gate" ])
           ~risk_level:AQ.Critical
           ~base_path
           ~on_resolution:
             (blocking_callback (fun decision -> callback_decision := Some decision))
           ()
       in
       Alcotest.(check bool)
         "explicit blocking callback owns the lane"
         true
         (AQ.has_blocking_pending_for_keeper ~keeper_name);
       (match AQ.get_pending_entry ~id with
        | Some entry ->
          Alcotest.(check bool) "lane policy is typed as Blocking" true
            (entry.lane_policy = AQ.Blocking)
        | None -> Alcotest.fail "blocking callback entry not found");
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err -> Alcotest.fail (AQ.resolve_error_to_string err));
       Alcotest.(check bool) "blocking callback does not emit duplicate wake" false !woke;
       Alcotest.(check bool)
         "resolved blocking callback releases the lane"
         false
         (AQ.has_blocking_pending_for_keeper ~keeper_name);
       match !callback_decision with
       | Some Agent_sdk.Hooks.Approve -> ()
       | Some decision ->
         Alcotest.fail
           ("unexpected callback decision: "
            ^ AQ.approval_decision_to_string decision)
       | None -> Alcotest.fail "blocking callback did not run")
;;

let test_resolution_wake_carries_originating_continuation_channel () =
  let base_path = temp_dir () in
  let captured = ref None in
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path:_
      ~keeper_name:_
      ~approval_id
      ~decision
      ~channel ->
      Ok
        (fun () ->
           captured :=
             Some
               Keeper_event_queue.
                 { approval_id;
                   decision;
                   channel }));
  let submit_resolve_capture ?continuation_channel ~keeper_name () =
    captured := None;
    let id =
      AQ.submit_pending_observer
        ~keeper_name
        ~tool_name:"keeper_continue_after_reconcile"
        ~input:(`Assoc [ "kind", `String "medium_gate" ])
        ~risk_level:AQ.Medium
        ~base_path
        ?continuation_channel
        ~on_resolution_observer:(fun _decision -> ())
        ()
    in
    (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
     | Ok () -> ()
     | Error err -> Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
    match !captured with
    | Some resolution -> resolution
    | None -> Alcotest.fail "resolve did not publish a wake payload"
  in
  Fun.protect
    ~finally:(fun () ->
      install_durable_resolution_delivery_hook ();
      cleanup_dir base_path)
    (fun () ->
       let dashboard_channel =
         Chat_queue.continuation_channel_of_message_source
           ~dashboard_thread_id:"dashboard-thread-1"
           Chat_queue.Dashboard
       in
       let dashboard_resolution =
         submit_resolve_capture
           ~keeper_name:"wake-dashboard-origin-test"
           ~continuation_channel:dashboard_channel
           ()
       in
       Alcotest.(check bool)
         "dashboard wake payload keeps the originating route"
         true
         (Keeper_continuation_channel.same_route
            dashboard_channel
            dashboard_resolution.channel);
       let discord_channel =
         Chat_queue.continuation_channel_of_message_source
           (Chat_queue.Discord
              { channel_id = "discord-channel-1"; user_id = "discord-user-1" })
       in
       let discord_resolution =
         submit_resolve_capture
           ~keeper_name:"wake-discord-origin-test"
           ~continuation_channel:discord_channel
           ()
       in
       Alcotest.(check bool)
         "discord wake payload keeps the originating route"
         true
         (Keeper_continuation_channel.same_route
            discord_channel
            discord_resolution.channel);
       let unrouted_resolution =
         submit_resolve_capture ~keeper_name:"wake-unrouted-origin-test" ()
       in
       match unrouted_resolution.channel with
       | Keeper_continuation_channel.Unrouted { reason } ->
         Alcotest.(check string) "missing connector fails closed"
           "no originating connector"
           reason
       | Keeper_continuation_channel.Dashboard _
       | Keeper_continuation_channel.Discord _
       | Keeper_continuation_channel.Slack _ ->
        Alcotest.fail "missing connector must not synthesize a routable channel")
;;

let test_expire_stale_submit_and_await_does_not_fire_wake_hook () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  let woke = ref false in
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path:_ ~keeper_name:_ ~approval_id:_ ~decision:_ ~channel:_ ->
      Ok (fun () -> woke := true));
  Fun.protect
    ~finally:(fun () ->
      install_durable_resolution_delivery_hook ();
      cleanup_dir base_path)
    (fun () ->
       let keeper_name = "expire-stale-await-no-wake-test" in
       let result = ref None in
       Eio.Switch.run
       @@ fun sw ->
       Eio.Fiber.fork ~sw (fun () ->
         let decision =
           AQ.submit_and_await
             ~keeper_name
             ~tool_name:"keeper_continue_after_reconcile"
             ~input:(`Assoc [ "kind", `String "medium_gate" ])
             ~risk_level:AQ.Medium
             ~base_path
             ()
         in
         result := Some decision);
       yield_until (fun () -> Option.is_some (pending_id_for_keeper ~keeper_name));
       AQ.expire_stale ~max_wait_s:0.0;
       yield_until (fun () -> Option.is_some !result);
       Alcotest.(check bool) "expire path resolves blocking entry via resolver" true
         (Option.is_some !result);
       (match !result with
        | Some (Agent_sdk.Hooks.Reject _reason) -> ()
        | Some _ -> Alcotest.fail "expire path should reject in stale blocking entry"
        | None -> Alcotest.fail "blocking stale entry should resolve");
       Alcotest.(check bool) "blocking stale resolution does not fire keeper wake hook" true
         (not !woke))
;;

let test_expire_stale_submit_pending_fires_wake_hook () =
  let base_path = temp_dir () in
  let woke = ref None in
  let resolved = ref None in
  let continuation_channel =
    Chat_queue.continuation_channel_of_message_source
      ~dashboard_thread_id:"dashboard-thread-1"
      Chat_queue.Dashboard
  in
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path:_
      ~keeper_name
      ~approval_id
      ~decision
      ~channel ->
      Ok (fun () -> woke := Some (keeper_name, approval_id, decision, channel)));
  Fun.protect
    ~finally:(fun () ->
      install_durable_resolution_delivery_hook ();
      cleanup_dir base_path)
    (fun () ->
       let keeper_name = "expire-stale-pending-wake-test" in
       let id =
         AQ.submit_pending_observer
           ~keeper_name
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "medium_gate" ])
           ~risk_level:AQ.Medium
           ~base_path
           ~continuation_channel
           ~on_resolution_observer:(fun decision -> resolved := Some decision)
           ()
       in
       AQ.expire_stale ~max_wait_s:0.0;
       Alcotest.(check bool) "on_resolution callback runs on stale expiry" true
         (Option.is_some !resolved);
       (match !woke with
        | Some
            (keeper, wake_id, decision, wake_channel) ->
          Alcotest.(check string)
            "wake carries waiting keeper"
            keeper_name
            keeper;
          Alcotest.(check string)
            "wake carries matching approval id"
            id
            wake_id;
          Alcotest.(check bool)
            "wake carries reject decision"
            true
            (decision = Keeper_event_queue.Hitl_rejected);
          Alcotest.(check bool)
            "wake channel is preserved on stale expiry"
            true
            (Keeper_continuation_channel.same_route
               continuation_channel
               wake_channel)
        | None -> Alcotest.fail "submit_pending stale expiry must fire wake hook")
       )
;;

let test_expire_stale_retries_after_delivery_failure () =
  let base_path = temp_dir () in
  let callback_decision = ref None in
  AQ.For_testing.clear_approval_resolution_wake_hook ();
  Fun.protect
    ~finally:(fun () ->
      install_durable_resolution_delivery_hook ();
      cleanup_dir base_path)
    (fun () ->
       let id =
         AQ.submit_pending_observer
           ~keeper_name:"expire-delivery-failure-test"
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "medium_gate" ])
           ~risk_level:AQ.Medium
           ~base_path
           ~on_resolution_observer:(fun decision -> callback_decision := Some decision)
           ()
       in
       AQ.expire_stale ~max_wait_s:0.0;
       Alcotest.(check bool) "failed expiry delivery keeps pending entry" true
         (Option.is_some (AQ.get_pending_entry ~id));
       Alcotest.(check bool) "failed expiry delivery does not run callback" true
         (Option.is_none !callback_decision);
       install_durable_resolution_delivery_hook ();
       AQ.expire_stale ~max_wait_s:0.0;
       Alcotest.(check bool) "retry removes expired entry" true
         (Option.is_none (AQ.get_pending_entry ~id));
       match !callback_decision with
       | Some (Agent_sdk.Hooks.Reject _) -> ()
       | Some decision ->
         Alcotest.fail
           ("expected Reject, got " ^ AQ.approval_decision_to_string decision)
       | None -> Alcotest.fail "successful expiry retry did not run callback")
;;

let test_expire_stale_is_per_entry_and_preserves_callback_failures () =
  let base_path = temp_dir () in
  let healthy_callback = ref false in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let submit keeper_name callback =
         AQ.submit_pending_blocking
           ~keeper_name
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String keeper_name ])
           ~risk_level:AQ.Medium
           ~base_path
           ~on_resolution:(blocking_callback callback)
           ()
       in
       let callback_should_fail = ref true in
       let failed_id =
         submit "expire-callback-exception-test" (fun _ ->
           if !callback_should_fail then failwith "synthetic expiry")
       in
       let healthy_id =
         submit "expire-healthy-neighbor-test" (fun _ -> healthy_callback := true)
       in
       AQ.expire_stale ~max_wait_s:0.0;
       Alcotest.(check bool)
         "failed expiry callback keeps its entry"
         true
         (Option.is_some (AQ.get_pending_entry ~id:failed_id));
       Alcotest.(check bool)
         "one failed entry does not block the next expiry"
         true
         !healthy_callback;
       Alcotest.(check bool)
         "healthy neighboring entry is removed"
         true
         (Option.is_none (AQ.get_pending_entry ~id:healthy_id));
       callback_should_fail := false;
       AQ.expire_stale ~max_wait_s:0.0;
       Alcotest.(check bool)
         "retry removes entry after callback completes"
         true
         (Option.is_none (AQ.get_pending_entry ~id:failed_id));
       let callback_should_cancel = ref true in
       let cancelled_id =
         submit "expire-callback-cancel-test" (fun _ ->
           if !callback_should_cancel
           then raise (Eio.Cancel.Cancelled (Failure "synthetic expiry cancellation")))
       in
       let cancelled_propagated =
         match AQ.expire_stale ~max_wait_s:0.0 with
         | exception Eio.Cancel.Cancelled _ -> true
         | () -> false
       in
       Alcotest.(check bool) "expiry cancellation propagates" true cancelled_propagated;
       Alcotest.(check bool)
         "expiry cancellation keeps the claimed entry pending"
         true
         (Option.is_some (AQ.get_pending_entry ~id:cancelled_id));
       callback_should_cancel := false;
       AQ.expire_stale ~max_wait_s:0.0;
       Alcotest.(check bool)
         "expiry claim is released after cancellation"
         true
         (Option.is_none (AQ.get_pending_entry ~id:cancelled_id)))
;;

let test_critical_entry_phase_becomes_escalated_after_timer () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let base_path = temp_dir () in
  AQ.For_testing.reset_audit_store ();
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_audit_store ();
      cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let keeper_name = "critical-escalated-phase-test" in
       let result = ref None in
       Eio.Fiber.fork ~sw (fun () ->
         let decision =
           AQ.submit_and_await
             ~keeper_name
             ~tool_name:"keeper_continue_after_partial_commit"
             ~input:(`Assoc [ ("kind", `String "critical_gate") ])
             ~risk_level:AQ.Critical
             ~base_path
             ~clock
             ~critical_escalation_after_s:0.01
             ()
         in
         result := Some decision);
       yield_until (fun () -> Option.is_some (pending_id_for_keeper ~keeper_name));
       let id =
         match pending_id_for_keeper ~keeper_name with
         | Some id -> id
         | None -> Alcotest.fail "Critical approval was not queued"
       in
       Eio.Time.sleep clock 0.03;
       yield_until (fun () ->
         match AQ.get_pending_entry ~id with
         | Some entry -> entry.phase = AQ.Escalated
         | None -> false);
       let entry =
         match AQ.get_pending_entry ~id with
         | Some entry -> entry
         | None -> Alcotest.fail "in-memory entry missing after escalation"
       in
       Alcotest.(check bool)
         "Critical entry is Escalated in-memory after timer"
         true
         (entry.phase = AQ.Escalated);
       let detail =
         match AQ.get_pending_json ~id with
         | Some json -> json
         | None -> Alcotest.fail "pending detail JSON missing after escalation"
       in
       Alcotest.(check string)
         "Critical entry is escalated in JSON after timer"
         "escalated"
         (phase_in_json detail);
       Alcotest.(check bool)
         "Critical escalation does not auto-resolve"
         true
         (Option.is_none !result);
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err ->
          Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
       yield_until (fun () -> Option.is_some !result);
       match !result with
       | Some Agent_sdk.Hooks.Approve -> ()
       | Some decision ->
         Alcotest.fail
           ("expected Approve, got " ^ AQ.approval_decision_to_string decision)
       | None -> Alcotest.fail "Critical approval did not resume after escalation")
;;

(* Regression: the HITL context summary must survive every JSON emission path,
   including the [include_input:true] dashboard paths. A previous
   [if include_input then ... else [] @ summary] precedence trap parsed the
   trailing summary fields into the [else] branch, so [include_input:true]
   ([list_pending_dashboard_json], [pending_entry_detail_json],
   [broadcast_pending]) silently dropped the operator-facing summary the HITL
   worker had computed. *)
let sample_summary : AQ.hitl_context_summary =
  { summary_version = 1
  ; generated_at = 1_700_000_000.0
  ; model_run_id = "test-model-run"
  ; context_summary = "HITL-SUMMARY-MARKER"
  ; key_questions = [ "is this action reversible?" ]
  ; suggested_options =
      [ { AQ.label = "approve once"
        ; rationale = "blast radius is bounded to the sandbox"
        ; estimated_risk_delta = Some AQ.Low
        }
      ]
  ; risk_rationale = Some "irreversible write outside sandbox"
  ; uncertainty = 0.25
  }
;;

let entry_json_for_keeper ~keeper_name = function
  | `List entries ->
    List.find_opt
      (function
        | `Assoc kvs ->
          (match List.assoc_opt "keeper_name" kvs with
           | Some (`String name) -> String.equal name keeper_name
           | _ -> false)
        | _ -> false)
      entries
  | _ -> None
;;

let context_summary_text_opt json =
  let open Yojson.Safe.Util in
  match json |> member "context_summary" with
  | `Null -> None
  | summary_obj ->
    (match summary_obj |> member "context_summary" with
     | `String s -> Some s
     | _ -> None)
;;

let summary_status_status json =
  let open Yojson.Safe.Util in
  match json |> member "summary_status" with
  | `Null -> None
  | `Assoc _ as obj -> obj |> member "status" |> to_string_option
  | `String s -> Some s
  | _ -> None
;;

let test_summary_survives_include_input_paths () =
  Eio_main.run
  @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run
       @@ fun sw ->
       let keeper_name = "summary-json-emission-test" in
       let result = ref None in
       Eio.Fiber.fork ~sw (fun () ->
         let decision =
           AQ.submit_and_await
             ~keeper_name
             ~tool_name:"keeper_continue_after_reconcile"
             ~input:(`Assoc [ "kind", `String "critical_gate" ])
             ~risk_level:AQ.Critical
             ~base_path
             ()
         in
         result := Some decision);
       yield_until (fun () -> Option.is_some (pending_id_for_keeper ~keeper_name));
       let id =
         match pending_id_for_keeper ~keeper_name with
         | Some id -> id
         | None -> Alcotest.fail "Critical approval was not queued"
       in
       (* Attach a known summary, then read synchronously (no [yield]) so the
          async summary worker cannot overwrite the entry between write and
          read under Eio's cooperative scheduler. *)
       AQ.update_pending_entry ~id (fun e ->
         { e with
           context_summary = Some sample_summary
         ; summary_status = AQ.Summary_available sample_summary
         });
       let dashboard_entry =
         match
           entry_json_for_keeper
             ~keeper_name
             (AQ.list_pending_dashboard_json ~base_path)
         with
         | Some json -> json
         | None -> Alcotest.fail "entry missing from list_pending_dashboard_json"
       in
       let detail_entry =
         match AQ.get_pending_json ~id with
         | Some json -> json
         | None -> Alcotest.fail "pending detail JSON not found"
       in
       let list_entry =
         match entry_json_for_keeper ~keeper_name (AQ.list_pending_json ~base_path) with
         | Some json -> json
         | None -> Alcotest.fail "entry missing from list_pending_json"
       in
       let expected = Some "HITL-SUMMARY-MARKER" in
       Alcotest.(check (option string))
         "dashboard list (include_input:true) carries context_summary"
         expected
         (context_summary_text_opt dashboard_entry);
       Alcotest.(check (option string))
         "detail view (include_input:true) carries context_summary"
         expected
         (context_summary_text_opt detail_entry);
       Alcotest.(check (option string))
         "plain list (include_input:false) carries context_summary"
         expected
         (context_summary_text_opt list_entry);
       Alcotest.(check (option string))
         "dashboard list exposes summary_status=available"
         (Some "available")
         (summary_status_status dashboard_entry);
       Alcotest.(check (option string))
         "detail view exposes summary_status=available"
         (Some "available")
         (summary_status_status detail_entry);
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
       | Error err ->
          Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
       yield_until (fun () -> Option.is_some !result))
;;

let test_summary_worker_missing_root_switch_is_explicit_failure () =
  Eio_main.run
  @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run
       @@ fun turn_sw ->
       let keeper_name = "summary-root-switch-missing-test" in
       let id =
         Eio_context.with_turn_switch turn_sw (fun () ->
           AQ.submit_pending_observer
             ~keeper_name
             ~tool_name:"keeper_continue_after_reconcile"
             ~input:(`Assoc [ "kind", `String "medium_gate" ])
             ~risk_level:AQ.Medium
             ~base_path
             ~on_resolution_observer:(fun _decision -> ())
             ())
       in
       let entry =
         match AQ.get_pending_entry ~id with
         | Some entry -> entry
         | None -> Alcotest.fail "pending entry missing"
       in
       (match entry.summary_status with
        | AQ.Summary_failed { reason; retryable } ->
          Alcotest.(check string)
            "missing root switch is explicit"
            "HITL summary: server root switch unavailable"
            reason;
          Alcotest.(check bool) "not retryable without a root switch" false retryable
        | other ->
          Alcotest.failf
            "expected Summary_failed, got %s"
            (Yojson.Safe.to_string (AQ.summary_status_to_yojson other)));
       match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
       | Ok () -> ()
       | Error err ->
         Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err))
;;

let test_pending_phase_conversions () =
  Alcotest.(check string)
    "Awaiting_operator string"
    "awaiting_operator"
    (AQ.pending_phase_to_string AQ.Awaiting_operator);
  Alcotest.(check string)
    "Escalated string"
    "escalated"
    (AQ.pending_phase_to_string AQ.Escalated);
  Alcotest.(check bool)
    "parse awaiting_operator"
    true
    (match AQ.pending_phase_of_string "awaiting_operator" with
     | Some AQ.Awaiting_operator -> true
     | _ -> false);
  Alcotest.(check bool)
    "parse escalated"
    true
    (match AQ.pending_phase_of_string "escalated" with
     | Some AQ.Escalated -> true
     | _ -> false);
  Alcotest.(check bool)
    "unknown phase returns None"
    true
    (Option.is_none (AQ.pending_phase_of_string "unknown"))
;;

(* RFC-0320 W3c: the delivery gate is fail-closed and dedups with the W3b
   prompt steer. [gate_decision] is pure, so we assert the decision matrix
   without a live connector. *)
let test_w3c_continuation_delivery_gate () =
  let module D = Masc.Keeper_continuation_delivery in
  let dashboard =
    Keeper_continuation_channel.Dashboard { thread_id = "thread-1" }
  in
  let unrouted = Keeper_continuation_channel.unrouted "no originating connector" in
  let is_skip_empty = function D.Skip D.Skipped_empty -> true | _ -> false in
  let is_skip_replied =
    function D.Skip D.Skipped_already_replied -> true | _ -> false
  in
  let is_skip_unrouted =
    function D.Skip D.Skipped_unrouted -> true | _ -> false
  in
  let is_deliver = function D.Deliver -> true | _ -> false in
  Alcotest.(check bool) "empty content is skipped" true
    (is_skip_empty
       (D.gate_decision ~channel:dashboard ~already_replied:false ~content:"   "));
  Alcotest.(check bool) "already-replied turn is skipped (dedup with W3b)" true
    (is_skip_replied
       (D.gate_decision ~channel:dashboard ~already_replied:true ~content:"hi"));
  Alcotest.(check bool) "unrouted channel is skipped (fail-closed)" true
    (is_skip_unrouted
       (D.gate_decision ~channel:unrouted ~already_replied:false ~content:"hi"));
  Alcotest.(check bool) "routable + fresh + non-empty delivers" true
    (is_deliver
       (D.gate_decision ~channel:dashboard ~already_replied:false ~content:"hi"))
;;

let reply_tool_call ?typed_outcome ~execution_outcome tool_name
  : Masc.Keeper_agent_result.tool_call_detail
  =
  { tool_name
  ; provider = "test"
  ; outcome = Tool_result.string_of_tool_call_outcome execution_outcome
  ; execution_outcome
  ; typed_outcome
  ; latency_ms = 1.0
  ; task_id = None
  ; route_evidence = None
  ; input_fingerprint = None
  ; output_fingerprint = None
  }
;;

let test_w3c_reply_delivery_effect_requires_success () =
  let module F = Masc.Keeper_agent_run_finalize_response in
  let is_delivered detail =
    match F.For_testing.reply_delivery_effect_of_tool_call detail with
    | F.Reply_delivered -> true
    | F.No_reply_delivery -> false
  in
  Alcotest.(check bool) "failed surface post has no delivery effect" false
    (is_delivered
       (reply_tool_call
          ~execution_outcome:Tool_result.Error
          "keeper_surface_post"));
  Alcotest.(check bool) "successful surface post has delivery effect" true
    (is_delivered
       (reply_tool_call
          ~execution_outcome:Tool_result.Ok
          "keeper_surface_post"));
  Alcotest.(check bool) "typed semantic error cannot claim delivery" false
    (is_delivered
       (reply_tool_call
          ~typed_outcome:(Keeper_tool_outcome.Error { reason = "send failed" })
          ~execution_outcome:Tool_result.Ok
          "keeper_surface_post"));
  Alcotest.(check bool) "keeper message is not a surface reply" false
    (is_delivered
       (reply_tool_call
          ~execution_outcome:Tool_result.Ok
          "masc_keeper_msg"));
  Alcotest.(check bool) "MCP-prefixed keeper message is not a surface reply" false
    (is_delivered
       (reply_tool_call
          ~execution_outcome:Tool_result.Ok
          "mcp__masc__masc_keeper_msg"));
  let keeper_message =
    reply_tool_call ~execution_outcome:Tool_result.Ok "masc_keeper_msg"
  in
  let channel = Keeper_continuation_channel.Dashboard { thread_id = "thread-1" } in
  let module D = Masc.Keeper_continuation_delivery in
  Alcotest.(check bool) "keeper message leaves continuation fallback enabled" true
    (match
       F.For_testing.continuation_delivery_gate
         ~channel
         ~tool_calls:[ keeper_message ]
         ~content:"fallback"
     with
     | D.Deliver -> true
     | D.Skip _ -> false);
  Alcotest.(check bool) "failed keeper message has no delivery effect" false
    (is_delivered
       (reply_tool_call
          ~execution_outcome:Tool_result.Error
          "masc_keeper_msg"));
  Alcotest.(check bool) "unrelated successful tool has no delivery effect" false
    (is_delivered
       (reply_tool_call
          ~execution_outcome:Tool_result.Ok
          "keeper_tasks_list"))
;;

let test_workspace_scope_isolates_queries_and_lane_gates () =
  let base_a = temp_dir () in
  let base_b = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir base_a;
      cleanup_dir base_b)
    (fun () ->
       let keeper_name = "same-name-two-workspaces" in
       let id_a =
         Raw_AQ.submit_pending_blocking
           ~keeper_name
           ~tool_name:"workspace-a-gate"
           ~input:(`Assoc [ "scope", `String "a" ])
           ~risk_level:Raw_AQ.Critical
           ~base_path:base_a
           ~on_resolution:(blocking_callback (fun _ -> ()))
           ()
       in
       let id_b =
         Raw_AQ.submit_pending_observer
           ~keeper_name
           ~tool_name:"workspace-b-observer"
           ~input:(`Assoc [ "scope", `String "b" ])
           ~risk_level:Raw_AQ.Low
           ~base_path:base_b
           ~on_resolution_observer:(fun _ -> ())
           ()
       in
       Alcotest.(check int) "workspace A count" 1
         (Raw_AQ.pending_count ~base_path:base_a);
       Alcotest.(check int) "workspace B count" 1
         (Raw_AQ.pending_count ~base_path:base_b);
       Alcotest.(check bool) "workspace A owns blocking lane" true
         (Raw_AQ.has_blocking_pending_for_keeper
            ~base_path:base_a
            ~keeper_name);
       Alcotest.(check bool) "workspace B ignores A blocking lane" false
         (Raw_AQ.has_blocking_pending_for_keeper
            ~base_path:base_b
            ~keeper_name);
       Alcotest.(check bool) "A entry is hidden from B detail" true
         (Option.is_none (Raw_AQ.get_pending_json ~base_path:base_b ~id:id_a));
       Alcotest.(check bool) "B entry is hidden from A detail" true
         (Option.is_none (Raw_AQ.get_pending_json ~base_path:base_a ~id:id_b));
       (match
          Raw_AQ.resolve
            ~base_path:base_b
            ~id:id_a
            ~decision:Agent_sdk.Hooks.Approve
        with
        | Error (Raw_AQ.Delivery_failed _) -> ()
        | Error err ->
          Alcotest.failf
            "wrong-workspace resolve returned %s"
            (Raw_AQ.resolve_error_to_string err)
        | Ok () -> Alcotest.fail "wrong workspace resolved A approval");
       Alcotest.(check bool) "wrong workspace preserves A entry" true
         (Option.is_some (Raw_AQ.get_pending_entry ~base_path:base_a ~id:id_a));
       (match
          Raw_AQ.resolve
            ~base_path:base_a
            ~id:id_a
            ~decision:Agent_sdk.Hooks.Approve
        with
        | Ok () -> ()
        | Error err ->
          Alcotest.failf "A cleanup failed: %s" (Raw_AQ.resolve_error_to_string err));
       match
         Raw_AQ.resolve
           ~base_path:base_b
           ~id:id_b
           ~decision:(Agent_sdk.Hooks.Reject "test cleanup")
       with
       | Ok () -> ()
       | Error err ->
         Alcotest.failf "B cleanup failed: %s" (Raw_AQ.resolve_error_to_string err))
;;

let test_blocking_decision_latches_before_idempotent_commit () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let prepare_calls = ref 0 in
       let commit_calls = ref 0 in
       let after_remove_saw_absent = ref false in
       let id_ref = ref "" in
       let id =
         Raw_AQ.submit_pending_blocking
           ~keeper_name:"decision-latch-test"
           ~tool_name:"decision-latch-effect"
           ~input:(`Assoc [ "kind", `String "decision_latch" ])
           ~risk_level:Raw_AQ.Critical
           ~base_path
           ~on_resolution:(fun ~approval_id decision ->
             incr prepare_calls;
             Raw_AQ.blocking_resolution_plan
               ~effect_key:("decision-latch:" ^ approval_id)
               ~commit:(fun () ->
                 incr commit_calls;
                 if !commit_calls = 1
                 then failwith "synthetic partial commit failure"
                 else (
                   ignore decision;
                   fun () ->
                     after_remove_saw_absent :=
                       Option.is_none
                         (Raw_AQ.get_pending_entry ~base_path ~id:!id_ref))))
           ()
       in
       id_ref := id;
       (match
          Raw_AQ.resolve ~base_path ~id ~decision:Agent_sdk.Hooks.Approve
        with
        | Error (Raw_AQ.Delivery_failed _) -> ()
        | Error err ->
          Alcotest.failf
            "first commit returned %s"
            (Raw_AQ.resolve_error_to_string err)
        | Ok () -> Alcotest.fail "first synthetic commit unexpectedly succeeded");
       Alcotest.(check int) "plan prepared once" 1 !prepare_calls;
       Alcotest.(check int) "commit attempted once" 1 !commit_calls;
       (match
          Raw_AQ.resolve
            ~base_path
            ~id
            ~decision:(Agent_sdk.Hooks.Reject "contradictory retry")
        with
        | Error (Raw_AQ.Delivery_failed _) -> ()
        | Error err ->
          Alcotest.failf
            "contradictory retry returned %s"
            (Raw_AQ.resolve_error_to_string err)
        | Ok () -> Alcotest.fail "contradictory retry bypassed decision latch");
       Alcotest.(check int) "contradiction does not prepare again" 1 !prepare_calls;
       Alcotest.(check int) "contradiction does not commit" 1 !commit_calls;
       (match
          Raw_AQ.resolve ~base_path ~id ~decision:Agent_sdk.Hooks.Approve
        with
        | Ok () -> ()
        | Error err ->
          Alcotest.failf
            "same-decision retry failed: %s"
            (Raw_AQ.resolve_error_to_string err));
       Alcotest.(check int) "same decision reuses prepared plan" 1 !prepare_calls;
       Alcotest.(check int) "same decision retries idempotent commit" 2 !commit_calls;
       Alcotest.(check bool) "post action observes pending removal" true
         !after_remove_saw_absent;
       Alcotest.(check bool) "successful retry removes entry" true
         (Option.is_none (Raw_AQ.get_pending_entry ~base_path ~id)))
;;

let test_timeout_terminal_claim_excludes_operator_rule_commit () =
  Eio_main.run @@ fun env ->
  let base_path = temp_dir () in
  let claimed_p, claimed_u = Eio.Promise.create () in
  let release_p, release_u = Eio.Promise.create () in
  let hook owner id =
    match owner with
    | Raw_AQ.Await_timeout ->
      Eio.Promise.resolve claimed_u id;
      Eio.Promise.await release_p
    | Raw_AQ.Operator_resolution
    | Raw_AQ.Await_cancellation
    | Raw_AQ.Expiration
    | Raw_AQ.Terminal_state_cancellation -> ()
  in
  Raw_AQ.For_testing.set_resolution_claim_hook hook;
  Fun.protect
    ~finally:(fun () ->
      Raw_AQ.For_testing.clear_resolution_claim_hook ();
      cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let result = ref None in
       Eio.Fiber.fork ~sw (fun () ->
         result :=
           Some
             (Raw_AQ.submit_and_await
                ~keeper_name:"timeout-claim-test"
                ~tool_name:"timeout-claim-tool"
                ~input:(`Assoc [ "kind", `String "timeout_claim" ])
                ~risk_level:Raw_AQ.Low
                ~base_path
                ~clock:(Eio.Stdenv.clock env)
                ~timeout_s:0.001
                ())) ;
       let id = Eio.Promise.await claimed_p in
       (match
          Raw_AQ.resolve_with_policy
            ~base_path
            ~id
            ~decision:Agent_sdk.Hooks.Approve
            ~remember_rule:true
            ()
        with
        | Error (Raw_AQ.Already_resolved claimed_id)
          when String.equal claimed_id id -> ()
        | Error err ->
          Alcotest.failf
            "operator race returned %s"
            (Raw_AQ.resolve_error_to_string err)
        | Ok _ -> Alcotest.fail "operator bypassed timeout terminal claim");
       Alcotest.(check int) "timeout winner has not persisted allow rule" 0
         (List.length (Raw_AQ.list_rules ~base_path ()));
       Eio.Promise.resolve release_u ();
       yield_until (fun () -> Option.is_some !result);
       (match !result with
        | Some (Agent_sdk.Hooks.Reject _) -> ()
        | Some Agent_sdk.Hooks.Approve ->
          Alcotest.fail "timeout winner returned operator Approve"
        | Some (Agent_sdk.Hooks.Edit _) ->
          Alcotest.fail "timeout winner returned Edit"
        | None -> Alcotest.fail "timeout result did not complete");
       Alcotest.(check int) "timeout leaves no pending orphan" 0
         (Raw_AQ.pending_count ~base_path);
       Alcotest.(check int) "timeout still leaves no allow rule" 0
         (List.length (Raw_AQ.list_rules ~base_path ()));
       let terminal_events =
         Raw_AQ.read_recent_audit
           ~base_path
           ~keeper_name:"timeout-claim-test"
           ~n:10
           ()
         |> List.filter (fun json ->
           match Json_util.assoc_member_opt "event" json with
           | Some (`String ("approval_timeout" | "resolved" | "cancelled")) -> true
           | Some _ | None -> false)
       in
       Alcotest.(check int) "exactly one terminal audit" 1
         (List.length terminal_events))
;;

let test_timeout_retries_after_competing_operator_failure () =
  Eio_main.run @@ fun env ->
  let base_path = temp_dir () in
  let operator_claimed_p, operator_claimed_u = Eio.Promise.create () in
  let release_operator_p, release_operator_u = Eio.Promise.create () in
  let hook owner id =
    match owner with
    | Raw_AQ.Operator_resolution ->
      Eio.Promise.resolve operator_claimed_u id;
      Eio.Promise.await release_operator_p;
      failwith "synthetic operator failure after terminal claim"
    | Raw_AQ.Await_timeout
    | Raw_AQ.Await_cancellation
    | Raw_AQ.Expiration
    | Raw_AQ.Terminal_state_cancellation -> ()
  in
  Raw_AQ.For_testing.set_resolution_claim_hook hook;
  Fun.protect
    ~finally:(fun () ->
      Raw_AQ.For_testing.clear_resolution_claim_hook ();
      cleanup_dir base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let timeout_result = ref None in
       Eio.Fiber.fork ~sw (fun () ->
         timeout_result :=
           Some
             (Raw_AQ.submit_and_await
                ~keeper_name:"timeout-retry-claim-test"
                ~tool_name:"timeout-retry-claim-tool"
                ~input:(`Assoc [ "kind", `String "timeout_retry_claim" ])
                ~risk_level:Raw_AQ.Low
                ~base_path
                ~clock:(Eio.Stdenv.clock env)
                ~timeout_s:0.001
                ()));
       yield_until (fun () -> Raw_AQ.pending_count ~base_path = 1);
       let id =
         match Raw_AQ.list_pending_entries ~base_path with
         | [ entry ] -> entry.id
         | _ -> Alcotest.fail "expected one resolver-backed approval"
       in
       let operator_failed = ref false in
       Eio.Fiber.fork ~sw (fun () ->
         match
           Raw_AQ.resolve_with_policy
             ~base_path
             ~id
             ~decision:Agent_sdk.Hooks.Approve
             ()
         with
         | exception Failure _ -> operator_failed := true
         | Ok _ | Error _ -> ());
       let claimed_id = Eio.Promise.await operator_claimed_p in
       Alcotest.(check string) "operator claimed expected approval" id claimed_id;
       Eio.Time.sleep (Eio.Stdenv.clock env) 0.01;
       Eio.Promise.resolve release_operator_u ();
       yield_until (fun () -> !operator_failed && Option.is_some !timeout_result);
       (match !timeout_result with
        | Some (Agent_sdk.Hooks.Reject _) -> ()
        | Some Agent_sdk.Hooks.Approve ->
          Alcotest.fail "failed operator claimant leaked Approve"
        | Some (Agent_sdk.Hooks.Edit _) ->
          Alcotest.fail "failed operator claimant leaked Edit"
        | None -> Alcotest.fail "timeout retry did not settle");
       Alcotest.(check int) "timeout retry leaves no pending orphan" 0
         (Raw_AQ.pending_count ~base_path))
;;

let test_post_removal_wake_failure_does_not_restore_committed_approval () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let id =
         Raw_AQ.submit_pending_blocking
           ~keeper_name:"post-removal-failure-test"
           ~tool_name:"post-removal-failure-effect"
           ~input:(`Assoc [ "kind", `String "post_removal_failure" ])
           ~risk_level:Raw_AQ.Critical
           ~base_path
           ~on_resolution:(fun ~approval_id _decision ->
             Raw_AQ.blocking_resolution_plan
               ~effect_key:("post-removal-failure:" ^ approval_id)
               ~commit:(fun () ->
                 fun () -> failwith "synthetic best-effort wake failure"))
           ()
       in
       (match
          Raw_AQ.resolve ~base_path ~id ~decision:Agent_sdk.Hooks.Approve
        with
        | Ok () -> ()
        | Error err ->
          Alcotest.failf
            "best-effort wake failure changed terminal result: %s"
            (Raw_AQ.resolve_error_to_string err));
       Alcotest.(check bool) "committed approval stays removed" true
         (Option.is_none (Raw_AQ.get_pending_entry ~base_path ~id)))
;;

let test_terminal_cancellation_and_operator_resolution_have_one_owner () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  Raw_AQ.For_testing.reset_pending ();
  Raw_AQ.For_testing.reset_audit_store ();
  Fun.protect
    ~finally:(fun () ->
      Raw_AQ.For_testing.reset_pending ();
      Raw_AQ.For_testing.reset_audit_store ();
      cleanup_dir base_path)
    (fun () ->
       let callback_commits = Atomic.make 0 in
       let id =
         Raw_AQ.submit_pending_blocking
           ~keeper_name:"terminal-cancel-race"
           ~tool_name:"keeper_continue_after_partial_commit"
           ~input:
             (`Assoc
                [ "kind", `String "continue_gate_required"
                ; "gate_id", `String "continue-race"
                ])
           ~risk_level:Raw_AQ.Critical
           ~base_path
           ~on_resolution:(fun ~approval_id decision ->
             Raw_AQ.blocking_resolution_plan
               ~effect_key:("terminal-cancel-race:" ^ approval_id)
               ~commit:(fun () ->
                 ignore (Atomic.fetch_and_add callback_commits 1);
                 (match decision with
                  | Agent_sdk.Hooks.Approve
                  | Agent_sdk.Hooks.Reject _
                  | Agent_sdk.Hooks.Edit _ -> ());
                 fun () -> ()))
           ()
       in
       let cancelled = ref None in
       let operator_result = ref None in
       Eio.Fiber.both
         (fun () ->
            Eio.Fiber.yield ();
            cancelled :=
              Some
                (Raw_AQ.cancel_callback_owned_for_terminal_keeper
                   ~base_path
                   ~keeper_name:"terminal-cancel-race"
                   ~reason:"superseded by Dead tombstone"))
         (fun () ->
            Eio.Fiber.yield ();
            operator_result :=
              Some
                (Raw_AQ.resolve
                   ~base_path
                   ~id
                   ~decision:Agent_sdk.Hooks.Approve));
       let cancelled = Option.value ~default:(-1) !cancelled in
       let operator_result =
         Option.value
           ~default:(Error (Raw_AQ.Not_found id))
           !operator_result
       in
       let operator_committed =
         match operator_result with
         | Ok () -> 1
         | Error (Raw_AQ.Not_found _ | Raw_AQ.Already_resolved _) -> 0
         | Error err ->
           Alcotest.failf
             "unexpected operator race result: %s"
             (Raw_AQ.resolve_error_to_string err)
       in
       Alcotest.(check int)
         "exactly one terminal owner commits"
         1
         (cancelled + operator_committed);
       Alcotest.(check int)
         "domain callback runs only when operator owns the claim"
         operator_committed
         (Atomic.get callback_commits);
       Alcotest.(check bool)
         "terminal race leaves no pending approval"
         true
         (Option.is_none (Raw_AQ.get_pending_entry ~base_path ~id)))
;;

let () =
  Alcotest.run
    "Keeper_approval_queue"
    [ ( "phase"
      , [ Alcotest.test_case
            "fresh Critical entry starts in Awaiting_operator"
            `Quick
            test_fresh_critical_entry_phase_is_awaiting_operator
        ; Alcotest.test_case
            "Critical entry becomes Escalated after escalation timer"
            `Quick
            test_critical_entry_phase_becomes_escalated_after_timer
        ] )
      ; ( "wake"
      , [ Alcotest.test_case
            "submit_and_await resolve resumes directly without wake hook"
            `Quick
            test_resolve_with_live_resolver_does_not_fire_keeper_wake_hook
        ; Alcotest.test_case
            "submit_pending resolve fires the keeper wake hook"
            `Quick
            test_submit_pending_resolve_fires_keeper_wake_hook
        ; Alcotest.test_case
            "delivery failure keeps nonblocking approval pending"
            `Quick
            test_delivery_failure_keeps_nonblocking_approval_pending
        ; Alcotest.test_case
            "nonblocking observer runs after durable commit and removal"
            `Quick
            test_nonblocking_observer_runs_after_durable_commit_and_removal
        ; Alcotest.test_case
            "nonblocking observer failure is non-authoritative"
            `Quick
            test_nonblocking_observer_failure_is_non_authoritative
        ; Alcotest.test_case
            "nonblocking observer cancellation signals before propagating"
            `Quick
            test_nonblocking_observer_cancellation_defers_until_after_signal
        ; Alcotest.test_case
            "blocking callback failure and cancellation keep pending"
            `Quick
            test_blocking_callback_failure_and_cancellation_keep_pending
        ; Alcotest.test_case
            "resolve_with_policy rejects a wrong workspace"
            `Quick
            test_resolve_with_policy_rejects_wrong_workspace
        ; Alcotest.test_case
            "identical approvals do not dedupe across workspaces"
            `Quick
            test_identical_approvals_do_not_dedupe_across_workspaces
        ; Alcotest.test_case
            "workspace scope isolates queries and blocking lane gates"
            `Quick
            test_workspace_scope_isolates_queries_and_lane_gates
        ; Alcotest.test_case
            "blocking decision latches before idempotent commit"
            `Quick
            test_blocking_decision_latches_before_idempotent_commit
        ; Alcotest.test_case
            "timeout terminal claim excludes operator rule commit"
            `Quick
            test_timeout_terminal_claim_excludes_operator_rule_commit
        ; Alcotest.test_case
            "timeout retries after a competing operator claim fails"
            `Quick
            test_timeout_retries_after_competing_operator_failure
        ; Alcotest.test_case
            "post-removal wake failure cannot restore committed approval"
            `Quick
            test_post_removal_wake_failure_does_not_restore_committed_approval
        ; Alcotest.test_case
            "terminal cancellation and operator resolution have one owner"
            `Quick
            test_terminal_cancellation_and_operator_resolution_have_one_owner
        ; Alcotest.test_case
            "explicit blocking callback owns a lane without resolver"
            `Quick
            test_blocking_callback_policy_owns_lane_without_resolver
        ; Alcotest.test_case
            "expire_stale does not fire wake for blocking submit_and_await"
            `Quick
            test_expire_stale_submit_and_await_does_not_fire_wake_hook
        ; Alcotest.test_case
            "expire_stale fires wake for non-blocking submit_pending"
            `Quick
            test_expire_stale_submit_pending_fires_wake_hook
        ; Alcotest.test_case
            "expire_stale retries after delivery failure"
            `Quick
            test_expire_stale_retries_after_delivery_failure
        ; Alcotest.test_case
            "expire_stale is per-entry and preserves callback failures"
            `Quick
            test_expire_stale_is_per_entry_and_preserves_callback_failures
        ; Alcotest.test_case
            "resolution wake carries originating continuation channel"
            `Quick
            test_resolution_wake_carries_originating_continuation_channel
        ; Alcotest.test_case
            "W3c continuation delivery gate is fail-closed"
            `Quick
            test_w3c_continuation_delivery_gate
        ; Alcotest.test_case
            "W3c reply delivery effect requires success"
            `Quick
            test_w3c_reply_delivery_effect_requires_success
        ] )
    ; ( "summary"
      , [ Alcotest.test_case
            "provider_config_for_summary preserves HITL runtime identity and temperature"
            `Quick
            test_provider_config_for_summary_routes_hitl_summary_lane
        ; Alcotest.test_case
            "context summary survives include_input:true JSON paths"
            `Quick
            test_summary_survives_include_input_paths
        ; Alcotest.test_case
            "missing root switch marks summary failed"
            `Quick
            test_summary_worker_missing_root_switch_is_explicit_failure
        ] )
    ; ( "conversions"
      , [ Alcotest.test_case
            "pending_phase string conversions round-trip"
            `Quick
            test_pending_phase_conversions
        ] )
    ]
;;
