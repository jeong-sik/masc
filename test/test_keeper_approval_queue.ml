(** Tests for the typed pending_phase HITL state machine (RFC-0304).

    Proves:
    1. Fresh pending approvals start in [Awaiting_operator].
    2. The phase is included in pending-entry JSON/SSE payloads.
    3. Critical approvals transition to [Escalated] when the escalation timer
       fires, and the updated phase is reflected in-memory and in JSON. *)

module AQ = Masc.Keeper_approval_queue
module Chat_queue = Masc.Keeper_chat_queue

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
     [models.summary]\n\
     api-name = \"summary\"\n\
     max-context = 1024\n\
     \n\
     [local.chat]\n\
     \n\
     [local.judge]\n\
     \n\
     [local.summary]\n\
     \n\
     [runtime]\n\
     default = \"local.chat\"\n\
     structured_judge = \"local.judge\"\n"
  in
  if with_hitl_summary then base ^ "hitl_summary = \"local.summary\"\n" else base
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
      | Ok () -> AQ.provider_config_for_summary ~keeper_name:"no-such-keeper")
  in
  (match load_and_resolve ~with_hitl_summary:true with
   | None -> Alcotest.fail "expected a provider config for the hitl_summary lane"
   | Some cfg ->
     Alcotest.(check string)
       "hitl_summary lane model is used"
       "summary"
       cfg.Llm_provider.Provider_config.model_id);
  match load_and_resolve ~with_hitl_summary:false with
  | None -> Alcotest.fail "expected structured_judge fallback config"
  | Some cfg ->
    Alcotest.(check string)
      "structured_judge fallback model is used"
      "judge"
      cfg.Llm_provider.Provider_config.model_id
;;

let pending_id_for_keeper ~keeper_name =
  match AQ.list_pending_json () with
  | `List entries ->
    List.find_map
      (function
        | `Assoc kvs ->
          (match List.assoc_opt "keeper_name" kvs, List.assoc_opt "id" kvs with
           | Some (`String name), Some (`String id) when String.equal name keeper_name ->
             Some id
           | _ -> None)
        | _ -> None)
      entries
  | _ -> None
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
      woke := Some (keeper_name, approval_id, decision));
  Fun.protect
    ~finally:(fun () ->
      (* Reset to the default no-op so the recording closure does not leak into
         later tests that share this module-level hook. *)
      AQ.set_approval_resolution_wake_hook
        (fun
          ~base_path:_
          ~keeper_name:_
          ~approval_id:_
          ~decision:_
          ~channel:_ ->
          ());
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
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path:_
      ~keeper_name
      ~approval_id
      ~decision
      ~channel:_ ->
      woke := Some (keeper_name, approval_id, decision));
  Fun.protect
    ~finally:(fun () ->
      AQ.set_approval_resolution_wake_hook
        (fun
          ~base_path:_
          ~keeper_name:_
          ~approval_id:_
          ~decision:_
          ~channel:_ ->
          ());
      cleanup_dir base_path)
    (fun () ->
       let keeper_name = "pending-resolve-wake-test" in
       let callback_decision = ref None in
       let input = `Assoc [ "kind", `String "critical_gate" ] in
       let id =
         AQ.submit_pending
           ~keeper_name
           ~tool_name:"keeper_continue_after_reconcile"
           ~input
           ~risk_level:AQ.Critical
           ~base_path
           ~on_resolution:(fun decision -> callback_decision := Some decision)
           ()
       in
       (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
        | Ok () -> ()
        | Error err ->
          Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
       Alcotest.(check bool)
         "on_resolution callback ran"
         true
         (Option.is_some !callback_decision);
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

let test_blocking_callback_policy_owns_lane_without_resolver () =
  let base_path = temp_dir () in
  let woke = ref false in
  let callback_decision = ref None in
  AQ.set_approval_resolution_wake_hook
    (fun
      ~base_path:_ ~keeper_name:_ ~approval_id:_ ~decision:_ ~channel:_ ->
      woke := true);
  Fun.protect
    ~finally:(fun () ->
      AQ.set_approval_resolution_wake_hook
        (fun
          ~base_path:_ ~keeper_name:_ ~approval_id:_ ~decision:_ ~channel:_ ->
          ());
      cleanup_dir base_path)
    (fun () ->
       let keeper_name = "blocking-callback-policy-test" in
       let id =
         AQ.submit_pending
           ~keeper_name
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "lifecycle_gate" ])
           ~risk_level:AQ.Critical
           ~base_path
           ~lane_policy:AQ.Blocking
           ~on_resolution:(fun decision -> callback_decision := Some decision)
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
      captured :=
        Some
          Keeper_event_queue.
            { approval_id;
              decision;
              channel =
                Option.value channel
                  ~default:(Keeper_continuation_channel.unrouted "test: no channel") });
  let reset_hook () =
    AQ.set_approval_resolution_wake_hook
        (fun
          ~base_path:_
          ~keeper_name:_
          ~approval_id:_
          ~decision:_
          ~channel:_ ->
          ())
  in
  let submit_resolve_capture ?continuation_channel ~keeper_name () =
    captured := None;
    let id =
      AQ.submit_pending
        ~keeper_name
        ~tool_name:"keeper_continue_after_reconcile"
        ~input:(`Assoc [ "kind", `String "medium_gate" ])
        ~risk_level:AQ.Medium
        ~base_path
        ?continuation_channel
        ~on_resolution:(fun _decision -> ())
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
      reset_hook ();
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
      woke := true);
  Fun.protect
    ~finally:(fun () ->
      AQ.set_approval_resolution_wake_hook
        (fun
          ~base_path:_
          ~keeper_name:_
          ~approval_id:_
          ~decision:_
          ~channel:_ ->
          ())
      ; cleanup_dir base_path)
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
      woke := Some (keeper_name, approval_id, decision, channel));
  Fun.protect
    ~finally:(fun () ->
      AQ.set_approval_resolution_wake_hook
        (fun
          ~base_path:_
          ~keeper_name:_
          ~approval_id:_
          ~decision:_
          ~channel:_ ->
          ())
      ; cleanup_dir base_path)
    (fun () ->
       let keeper_name = "expire-stale-pending-wake-test" in
       let id =
         AQ.submit_pending
           ~keeper_name
           ~tool_name:"keeper_continue_after_reconcile"
           ~input:(`Assoc [ "kind", `String "medium_gate" ])
           ~risk_level:AQ.Medium
           ~base_path
           ~continuation_channel
           ~on_resolution:(fun decision -> resolved := Some decision)
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
               (Option.value wake_channel
                  ~default:
                    (Keeper_continuation_channel.unrouted "test: no wake channel")))
        | None -> Alcotest.fail "submit_pending stale expiry must fire wake hook")
       )
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
           entry_json_for_keeper ~keeper_name (AQ.list_pending_dashboard_json ())
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
         match entry_json_for_keeper ~keeper_name (AQ.list_pending_json ()) with
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
           AQ.submit_pending
             ~keeper_name
             ~tool_name:"keeper_continue_after_reconcile"
             ~input:(`Assoc [ "kind", `String "medium_gate" ])
             ~risk_level:AQ.Medium
             ~base_path
             ~on_resolution:(fun _decision -> ())
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
            "provider_config_for_summary routes the hitl_summary lane"
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
