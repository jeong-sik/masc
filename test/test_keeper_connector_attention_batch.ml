(* test_keeper_connector_attention_batch.ml — RFC-0377: conversation-batched
   stimulus intake.

   Live data (2026-08-08..08-13) showed every delivered continuation
   obligation (48/48) bound 1:1 to a single distinct inbound message: a turn
   admitted exactly one Connector_attention stimulus (RFC-0020 Rule 4), so a
   backlog of N pending messages in the same conversation took N turns to
   drain, and inbound-to-reply lag grew monotonically (438s to 4,461s,
   median 1,533s) as live traffic outran the one-per-turn drain rate.

   This suite pins the fix: once [heartbeat_event_intake]'s primary
   selection is a [Connector_attention] stimulus, it drains every OTHER
   pending [Connector_attention] stimulus for the same conversation into the
   same turn, in arrival order (RFC-0377 S3) — and the durable queue
   lifecycle applies to every admitted member, not only the primary: a turn
   completion acknowledges the delivered connector batch and a turn failure
   retains it. HITL cohorts additionally require each input's own continuation
   receipt before its exact queue selection is acknowledged. *)

open Alcotest
open Masc
module Q = Keeper_event_queue
module A = Keeper_external_attention
module Owner = Keeper_owner
module Owner_registry = Keeper_owner_registry

let contains ~needle haystack =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec loop i =
    (i + nl <= hl)
    && (String.equal (String.sub haystack i nl) needle || loop (i + 1))
  in
  nl = 0 || loop 0
;;

let test_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "trace_id", `String ("trace-" ^ name)
         ])
  with
  | Ok meta -> meta
  | Error detail -> failf "meta fixture failed: %s" detail
;;

let enqueue_exn ~base_path keeper_name source =
  match
    Keeper_registry_event_queue.enqueue_durable_result
      ~base_path
      keeper_name
      source
  with
  | Ok () -> ()
  | Error detail -> failf "durable enqueue failed: %s" detail
;;

(* --- cycle_outcome fixtures for Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome ---

   These build the minimum valid [Keeper_heartbeat_loop_cycle.cycle_outcome]
   payload for each branch under test. *)

let completed_outcome meta : Keeper_heartbeat_loop_cycle.cycle_outcome =
  Keeper_heartbeat_loop_cycle.Completed { meta }
;;

let failed_outcome ~source_disposition ~route ~deferred_runtime_lane meta
  : Keeper_heartbeat_loop_cycle.cycle_outcome
  =
  Keeper_heartbeat_loop_cycle.Failed
    { meta
    ; failure =
        { Keeper_unified_turn.error = Agent_core.Error.Internal "test fixture"
        ; runtime_id = "test-runtime"
        ; route
        ; source_disposition
        ; deferred_runtime_lane
        }
    }
;;

let transient_retry_route =
  Keeper_runtime_failure_route.Retry_after_observed
    { retry_class = Keeper_runtime_failure_route.Network_transient
    ; retry_after = None
    }
;;

let deterministic_route =
  Keeper_runtime_failure_route.Exhausted_visible_alive
    { terminal = Keeper_runtime_failure_route.Deterministic_request }
;;

let discord_surface ~channel_id =
  A.Discord
    { guild_id = Some "guild-batch"
    ; channel_id
    ; channel_name = None
    ; parent_channel_id = None
    ; thread_id = None
    }
;;

(* Mirrors [server_discord_in_process_gateway.handle_ambient]: every ambient
   message is recorded as its own [Keeper_external_attention] item and
   enqueued as its own [Connector_attention] stimulus whose channel carries
   [reply_to_message_id = message_id] — the message's OWN id, distinct per
   message. That is exactly why [Keeper_continuation_channel.same_route]
   cannot be the batching predicate: two pending messages from the same
   conversation never share a [same_route] value. [same_conversation]
   (channel_id-only, RFC-0377) is what lets this batch form at all. *)
let connector_attention_stimulus
      ~base_path ~keeper_name ~channel_id ~message_id ~arrived_at ~content
  : Q.stimulus
  =
  let event_id = Printf.sprintf "evt-%s-%s" channel_id message_id in
  let item : A.item =
    { A.event_id
    ; dedupe_key = event_id
    ; keeper_name
    ; conversation =
        { conversation_id = "discord:" ^ channel_id
        ; surface = discord_surface ~channel_id
        }
    ; external_message =
        Some
          { surface = discord_surface ~channel_id
          ; message_id
          ; reply_to_message_id = None
          }
    ; source_label = "discord"
    ; actor =
        { actor_id = Some "user-batch"
        ; display_name = Some "Batch User"
        ; authority = Keeper_chat_store.External
        }
    ; urgency = A.Ambient
    ; content_preview = content
    ; content_ref = None
    ; received_at = arrived_at
    ; metadata = [ "route", "ambient" ]
    }
  in
  (match A.record ~base_path item with
   | `Recorded -> ()
   | `Duplicate _ -> failf "unexpected duplicate external attention: %s" event_id
   | `Error detail -> failf "external attention record failed: %s" detail);
  let channel =
    match
      Keeper_continuation_channel.discord
        ~guild_id:(Some "guild-batch")
        ~channel_id
        ~parent_channel_id:None
        ~thread_id:None
        ~reply_to_message_id:message_id
        ~user_id:"user-batch"
        ()
    with
    | Ok channel -> channel
    | Error detail -> failf "channel fixture failed: %s" detail
  in
  { Q.post_id = event_id
  ; urgency = Q.Low
  ; arrived_at
  ; payload = Q.Connector_attention { event_id; channel }
  }
;;

(* A Board_signal distractor that is never expected to be read: it exists
   only to prove the batch filter skips a non-[Connector_attention] entry
   sitting between two conversation matches instead of taking a naive
   contiguous prefix. It shares the connector entries' [Low] urgency so the
   pending list keeps it between them: a [Normal] entry would sort ahead of
   both and be admitted first, which is urgency order working as designed,
   not the case this fixture isolates. *)
let board_distractor_stimulus ~post_id ~arrived_at : Q.stimulus =
  { Q.post_id
  ; urgency = Q.Low
  ; arrived_at
  ; payload =
      Q.Board_signal
        { kind = Q.Post_created
        ; author = "external-author"
        ; title = "distractor"
        ; content = "never consumed by this suite"
        ; hearth = None
        ; updated_at = None
        ; audience = Keeper_event_queue.Audience_discoverable
        }
  }
;;

let board_attention_stimulus ~label ~arrived_at : Q.stimulus =
  let post =
    match
      Board_dispatch.create_post
        ~author:"external-batch-author"
        ~title:label
        ~content:("content-" ^ label)
        ~post_kind:Board.Human_post
        ~visibility:Board.Internal
        ()
    with
    | Ok post -> post
    | Error error ->
      failf "failed to create Board batch source: %s" (Board.Post_publication_failure.to_string error)
  in
  let post_id = Board.Post_id.to_string post.id in
  { Q.post_id
  ; urgency = Q.Normal
  ; arrived_at
  ; payload =
      Q.Board_attention
        { candidate_id = "candidate-" ^ label
        ; signal =
            { kind = Q.Post_created
            ; author = "external-batch-author"
            ; title = label
            ; content = "content-" ^ label
            ; hearth = None
            ; updated_at = Some post.updated_at
            ; audience = Keeper_event_queue.Audience_discoverable
            }
        }
  }
;;

let scheduled_wake_stimulus ~occurrence ~arrived_at : Q.stimulus =
  let occurrence_id = Printf.sprintf "occurrence-%d" occurrence in
  { Q.post_id = occurrence_id
  ; urgency = Q.Immediate
  ; arrived_at
  ; payload =
      Q.Schedule_due
        { occurrence_id
        ; schedule_instance_id = "instance-batch"
        ; schedule_id = "schedule-batch"
        ; due_at = arrived_at
        ; payload_digest = "digest-batch"
        ; title = Some "batch schedule"
        ; message = "scheduled batch work"
        ; result_delivery = None
        }
  }
;;

let approve_grant_exn ~base_path ~keeper_name ~request =
  let approval_id =
    match
      Keeper_approval_queue.submit_pending ~origin:Keeper_approval_origin.unavailable
        ~keeper_name ~tool_name:"external-effect"
        ~input:(`Assoc [ "request", `String request ])
        ~call_summary:None ~base_path ()
    with
    | Ok submission -> submission.approval_id
    | Error error -> fail (Masc.Keeper_approval_queue_result.storage_error_to_string error)
  in
  (match
     Keeper_approval_queue.resolve_with_policy
       ~base_path ~id:approval_id
       ~decision:Keeper_approval_queue_rules_types.Decision.Approve
       ~source:Keeper_approval_queue_rules_types.Human_operator ()
   with
   | Ok _ -> ()
   | Error error -> fail (Keeper_approval_queue.resolve_error_to_string error));
  approval_id
;;

let connector_event_ids_of_queue queue =
  Q.to_list queue
  |> List.filter_map (fun (s : Q.stimulus) ->
       match s.Q.payload with
       | Q.Connector_attention { event_id; _ } -> Some event_id
       | Q.Board_signal _ | Q.Board_routing_pending _ | Q.Board_attention _ | Q.Bootstrap
       | Q.Fusion_completed _ | Q.Schedule_due _ | Q.Hitl_resolved _
      | Q.Ask_answered _
       | Q.Completion_authority_rejected _
       | Q.Task_outcome _
       | Q.Task_cancelled _ | Q.Workspace_message _
       | Q.Delegate_completed _ | Q.Composition_completed _ | Q.Tool_result_ready _ | Q.Owned_job_completed _ -> None)
  |> List.sort String.compare
;;

let with_ctx keeper_name f =
  Eio_main.run
  @@ fun env ->
  Masc_test_deps.ensure_rng_initialized ();
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  Unix.putenv "MASC_BASE_PATH" base_path;
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ())
  @@ fun () ->
  let config = Workspace.default_config base_path in
  let meta = test_meta keeper_name in
  ignore (Keeper_registry.For_testing.register ~base_path keeper_name meta);
  let ctx : _ Keeper_types_profile.context =
    { config
    ; agent_name = "connector-attention-batch-test"
    ; sw
    ; clock = Eio.Stdenv.clock env
    ; proc_mgr = None
    ; net = None
    ; publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider
    }
  in
  f ~base_path ~keeper_name ~meta ~ctx
;;

(* The Owner a source turn asks about chat readiness. *)
let start_owner ~(ctx : _ Keeper_types_profile.context) ~base_path ~meta
      ~operation_runner ~on_turn_slot_released =
  (match
     Keeper_owner_registry.install_from_store
       ~sw:ctx.sw ~operation_runner ~on_turn_slot_released ctx.config
   with
   | Ok _ -> ()
   | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
  match Keeper_owner_registry.create_meta ~base_path meta with
  | Ok (Some _) -> ()
  | Ok None -> fail "owner fixture metadata disappeared"
  | Error error -> fail (Keeper_owner_registry.command_error_to_string error)
;;

let test_scheduled_work_without_delivery_shares_the_ready_batch () =
  with_ctx "all-ready-batch" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let board =
      List.init 5 (fun index ->
        board_attention_stimulus
          ~label:(Printf.sprintf "board-%d" (index + 1))
          ~arrived_at:(Float.of_int (index + 10)))
    in
    let schedules =
      List.init 3 (fun index ->
        scheduled_wake_stimulus
          ~occurrence:(index + 1)
          ~arrived_at:(Float.of_int (index + 1)))
    in
    let bootstrap : Q.stimulus =
      { post_id = "bootstrap-batch"
      ; urgency = Q.Low
      ; arrived_at = 30.0
      ; payload = Q.Bootstrap
      }
    in
    let sources = schedules @ board @ [ bootstrap ] in
    List.iter (enqueue_exn ~base_path keeper_name) sources;
    let intake =
      Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx
        ~meta_after_triage:meta
        ~pending_board_events:[]
    in
    check int "ready schedules and general sources share one turn" 9
      (Keeper_heartbeat_source_batch.count intake.source_batch);
    check
      (list string)
      "every exact scheduled occurrence and general source is admitted"
      (List.map (fun (source : Q.stimulus) -> source.post_id) sources)
      (List.map (fun (source : Q.stimulus) -> source.post_id) (Keeper_heartbeat_source_batch.stimuli intake.source_batch));
    check int "every scheduled request and Board event reaches the turn" 8
      (List.length intake.pending_board_events);
    check int "intake alone never ACKs actionable sources" 9
      (Keeper_registry_event_queue.snapshot_result ~base_path keeper_name
       |> Result.map Q.length
       |> Result.value ~default:(-1)))
;;

let test_scheduled_batches_preserve_result_delivery () =
  with_ctx "schedule-delivery-batches" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let module Batch = Keeper_heartbeat_source_batch in
    let require = function Ok value -> value | Error detail -> fail detail in
    let route thread_id = Keeper_continuation_channel.slack
      ~team_id:(Some "schedule-team") ~channel_id:"same-slack-channel"
      ~thread_ts:(Some thread_id) ~user_id:"schedule-user" |> require in
    let a = route "schedule-origin-a" and b = route "schedule-origin-b" in
    let scheduled id arrived_at result_delivery : Q.stimulus =
      { post_id = id; urgency = Q.Immediate; arrived_at
      ; payload = Q.Schedule_due
          { occurrence_id = id; schedule_instance_id = "instance-" ^ id
          ; schedule_id = "schedule-" ^ id; due_at = arrived_at
          ; payload_digest = "digest-" ^ id; title = None
          ; message = "independent request " ^ id; result_delivery } } in
    let first = scheduled "no-delivery-1" 1. None in
    let a1 = scheduled "origin-a-1" 2. (Some a) in
    let b1 = scheduled "origin-b-1" 3. (Some b) in
    let a2 = scheduled "origin-a-2" 4. (Some a) in
    let last = scheduled "no-delivery-2" 5. None in
    let board = board_attention_stimulus ~label:"board-between-schedules" ~arrived_at:6. in
    List.iter (enqueue_exn ~base_path keeper_name) [first; a1; b1; a2; last; board];
    let intake () = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    let ids batch = Batch.stimuli batch |> List.map (fun (s : Q.stimulus) -> s.post_id) in
    let complete batch = List.iter (fun selection ->
      Keeper_registry_event_queue.terminalize_pending_turn_completed_result
        ~base_path keeper_name ~applied_at:100. ~selection |> require |> ignore)
      (Batch.selections batch) in
    let general = (intake ()).source_batch in
    check (list string) "unrouted one-shots and Board work share a completed turn"
      [first.post_id; last.post_id; board.post_id] (ids general);
    check bool "general batch has no captured reply route" true
      (Option.is_none (Keeper_unified_turn.continuation_channel_of_wake
        (Batch.for_turn ~reactive:true general |> Batch.wake)));
    complete general;
    let routed_a = (intake ()).source_batch in
    check (list string) "distinct requests to the same exact reply route share a turn"
      [a1.post_id; a2.post_id] (ids routed_a);
    let channel = Keeper_unified_turn.continuation_channel_of_wake
      (Batch.for_turn ~reactive:true routed_a |> Batch.wake) in
    check bool "the origin reply route survives batching" true
      (Option.exists (Keeper_continuation_channel.same_route a) channel);
    (* A checkpoint retains both original requests; it cannot certify their
       completion just because the model reached a tool boundary. *)
    Keeper_heartbeat_loop.For_testing.retain_checkpoint_continuations
      ~base_path ~keeper_name (Batch.selections routed_a) |> require;
    check int "a checkpoint leaves every uncompleted routed request pending" 3
      (Keeper_registry_event_queue.snapshot_result ~base_path keeper_name
       |> require |> Q.length);
    let routed_b = (intake ()).source_batch in
    check (list string) "the other origin is not blocked by a retained batch"
      [b1.post_id] (ids routed_b);
    check bool "another thread in the same Slack channel keeps its own route" true
      (Option.exists (Keeper_continuation_channel.same_route b)
        (Keeper_unified_turn.continuation_channel_of_wake
          (Batch.for_turn ~reactive:true routed_b |> Batch.wake)));
    complete routed_b;
    let resumed_a = (intake ()).source_batch in
    check (list string) "the original requests resume together"
      [a1.post_id; a2.post_id] (ids resumed_a);
    complete resumed_a;
    check int "successful batches drain every exact occurrence" 0
      (Keeper_registry_event_queue.snapshot_result ~base_path keeper_name
       |> require |> Q.length))
;;

let test_unrouted_schedule_does_not_take_a_connector_reply_route () =
  List.iter (fun schedule_first ->
    with_ctx "schedule-connector-routes" (fun ~base_path ~keeper_name ~meta ~ctx ->
      let module Batch = Keeper_heartbeat_source_batch in
      let require = function Ok value -> value | Error detail -> fail detail in
      let schedule = { (scheduled_wake_stimulus ~occurrence:1
        ~arrived_at:(if schedule_first then 1. else 2.)) with urgency = Q.Low } in
      let connector = connector_attention_stimulus ~base_path ~keeper_name
        ~channel_id:"connector-schedule-origin" ~message_id:"connector-schedule-message"
        ~arrived_at:(if schedule_first then 2. else 1.) ~content:"reply to this message" in
      List.iter (enqueue_exn ~base_path keeper_name) [schedule; connector];
      let intake () = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
      let inspect batch =
        let sources = Batch.stimuli batch in
        let expected = match sources with
          | [source] -> Q.continuation_channel_of_payload source.payload
          | [] | _ :: _ :: _ -> fail "a no-delivery schedule swallowed routed input" in
        let actual = Keeper_unified_turn.continuation_channel_of_wake
          (Batch.for_turn ~reactive:true batch |> Batch.wake) in
        check bool "each batch preserves its original reply route" true
          (Option.equal Keeper_continuation_channel.same_route expected actual);
        List.iter (fun selection ->
          Keeper_registry_event_queue.terminalize_pending_turn_completed_result
            ~base_path keeper_name ~applied_at:100. ~selection |> require |> ignore)
          (Batch.selections batch) in
      inspect (intake ()).source_batch;
      inspect (intake ()).source_batch;
      check int "both sources complete without stealing the other's destination" 0
        (Keeper_registry_event_queue.snapshot_result ~base_path keeper_name |> require |> Q.length)))
    [false; true]
;;

let test_scheduled_continuation_withdrawal_and_reinsertion () =
  with_ctx "schedule-continuation-withdraw" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let module Batch = Keeper_heartbeat_source_batch in
    let require = function Ok value -> value | Error detail -> fail detail in
    let original = scheduled_wake_stimulus ~occurrence:1 ~arrived_at:1. in
    enqueue_exn ~base_path keeper_name original;
    let intake () = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    let captured = (intake ()).source_batch in
    Keeper_heartbeat_loop.For_testing.retain_checkpoint_continuations
      ~base_path ~keeper_name (Batch.selections captured) |> require;
    check bool "checkpoint cannot ACK scheduled work" false
      (List.exists (fun (s : Keeper_event_queue_state.pending_selection) ->
         Keeper_heartbeat_loop.For_testing.checkpoint_source_may_ack s.source.payload)
         (Batch.selections captured));
    let cancelled = Keeper_registry_event_queue.cancel_scheduled_wakes_result
      ~base_path keeper_name ~applied_at:20. ~schedule_ids:["schedule-batch"]
      ~reason:"owned fixture cancellation" |> require in
    check int "cancellation withdraws the retained occurrence" 1 cancelled;
    Keeper_heartbeat_loop.For_testing.retain_checkpoint_continuations
      ~base_path ~keeper_name (Batch.selections captured) |> require;
    Keeper_event_queue_persistence.For_testing.reset_snapshot_cache_for_testing ();
    check int "cold intake does not resurrect cancelled work" 0
      (Batch.count (intake ()).source_batch);
    let validate batch = Batch.validate ~diagnostic:None
      ~standing:(fun selection -> Keeper_registry_event_queue.admitted_selection_standing_result
        ~base_path keeper_name ~selection) batch in
    let admitted, withdrawn = validate captured |> require in
    check int "absent cancelled source is no longer admitted" 0 (Batch.count admitted);
    check int "absent cancelled source is explicitly withdrawn" 1 (List.length withdrawn);
    (* Even byte-identical reinsertion has a new durable incarnation. It must
       not inherit the old turn's exclusion or completion authority. *)
    enqueue_exn ~base_path keeper_name original;
    let reinserted = Keeper_registry_event_queue.pending_selections_result
      ~base_path keeper_name |> require in
    check int "reinserted occurrence is pending once" 1 (List.length reinserted);
    (match validate captured with
     | Error detail ->
       check string "replacement strictly rejects old incarnation authority"
         "event queue pending selection incarnation changed" detail
     | Ok _ -> fail "reinserted source accepted old incarnation authority");
    (match Keeper_heartbeat_loop.For_testing.retain_checkpoint_continuations
        ~base_path ~keeper_name (Batch.selections captured) with
     | Error _ -> ()
     | Ok () -> fail "checkpoint retention accepted the replaced incarnation");
    Keeper_event_queue_persistence.For_testing.reset_snapshot_cache_for_testing ();
    let current = Keeper_registry_event_queue.pending_selections_result
      ~base_path keeper_name |> require in
    check bool "stale validation leaves the exact replacement pending" true
      (current = reinserted);
    let replacement = (intake ()).source_batch in
    check bool "next intake owns the current replacement incarnation" true
      (Batch.selections replacement = current);
    let admitted, withdrawn = validate replacement |> require in
    check bool "current replacement retains dispatch authority" true
      (Batch.selections admitted = current && withdrawn = []))
;;

let test_checkpoint_after_schedule_supersession_preserves_live_sources () =
  with_ctx "schedule-superseded-checkpoint" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let module Batch = Keeper_heartbeat_source_batch in
    let module Persistence = Keeper_event_queue_persistence in
    let require = function Ok value -> value | Error detail -> fail detail in
    let original = scheduled_wake_stimulus ~occurrence:1 ~arrived_at:1. in
    let result : Q.stimulus =
      { post_id = "live-result"; urgency = Q.Immediate; arrived_at = 2.
      ; payload = Q.Delegate_completed
          { dc_operation_id = "live-result"; dc_keeper = "delegate"
          ; dc_terminal = Q.Delegate_replied "uncompleted result" } } in
    List.iter (enqueue_exn ~base_path keeper_name) [original; result];
    let captured = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    let admitted = Batch.selections captured.source_batch in
    check int "the running turn admitted the old schedule and live result" 2
      (List.length admitted);
    let cancelled = Keeper_registry_event_queue.cancel_scheduled_wakes_result
      ~base_path keeper_name ~applied_at:3. ~schedule_ids:["schedule-batch"]
      ~reason:"superseded by the next occurrence" |> require in
    check int "the next occurrence withdraws the running schedule source" 1 cancelled;
    let successor = scheduled_wake_stimulus ~occurrence:2 ~arrived_at:4. in
    enqueue_exn ~base_path keeper_name successor;
    Keeper_heartbeat_loop.For_testing.retain_checkpoint_continuations
      ~base_path ~keeper_name admitted |> require;
    Persistence.For_testing.reset_snapshot_cache_for_testing ();
    let pending = Persistence.pending_selections_result ~base_path ~keeper_name |> require in
    check (list string) "the successor runs before the retained live result"
      [successor.post_id; result.post_id]
      (List.map (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id) pending);
    List.iter (fun (s : Keeper_event_queue_state.pending_selection) ->
      let expected = if s.source.post_id = result.post_id then 1 else 0 in
      check int "only the exact live admitted source counts the checkpoint"
        expected s.checkpoint_retentions) pending;
    let next = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    check (list string) "next intake retains both obligations without reviving the old schedule"
      [successor.post_id; result.post_id]
      (List.map (fun (s : Q.stimulus) -> s.post_id) (Batch.stimuli next.source_batch)))
;;

let test_unread_connector_sources_survive_other_completed_work ~failure () =
  List.iter (fun count ->
    with_ctx (Printf.sprintf "connector-unread-%d" count)
      (fun ~base_path ~keeper_name ~meta ~ctx ->
        let messages = List.init count (fun index ->
          connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"restore-channel"
            ~message_id:(string_of_int index) ~arrived_at:(Float.of_int (index + 1))
            ~content:(Printf.sprintf "original message %d" index)) in
        List.iter (enqueue_exn ~base_path keeper_name) messages;
        let path = A.attention_path ~base_path ~keeper_name in
        let original = Fs_compat.load_file path in
        let backup = path ^ ".fixture-backup" in
        (match failure with
         | `Torn_tail -> Fs_compat.save_file path (original ^ "{")
         | `Unreadable -> Sys.rename path backup; Unix.mkdir path 0o700
         | `Missing_file -> Sys.rename path backup
         | `Missing_rows -> Fs_compat.save_file path "");
        let intake () = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
          ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
        let assert_read_failure intake =
          match intake.Keeper_heartbeat_stimulus_intake.event_queue_intake_error with
          | Some (Keeper_heartbeat_stimulus_intake.Connector_read_failed error)
            when failure = `Torn_tail || failure = `Unreadable ->
            check bool "connector read failure is a retry, not a crashed cycle" false
              (Keeper_heartbeat_stimulus_intake.event_queue_intake_error_counts_as_cycle_failure
                 (Keeper_heartbeat_stimulus_intake.Connector_read_failed error))
          | Some (Keeper_heartbeat_stimulus_intake.Connector_item_missing _)
            when failure = `Missing_file || failure = `Missing_rows -> ()
          | _ -> fail "unread connector store was treated as missing content" in
        let first = intake () in
        assert_read_failure first;
        check int "unread connector sources are not admitted" 0
          (Keeper_heartbeat_source_batch.count first.source_batch);
        check bool "unread connector sources add no scheduling trigger" true
          (first.event_queue_triggers = []);
        check bool "independently scheduled work survives unread connector content" true
          (Keeper_heartbeat_loop.should_run_turn_after_event_intake
             ~scheduled:true
             ~event_queue_intake_error:first.event_queue_intake_error);
        check bool "unread content does not create an unscheduled turn" false
          (Keeper_heartbeat_loop.should_run_turn_after_event_intake
             ~scheduled:false
             ~event_queue_intake_error:first.event_queue_intake_error);
        let bootstrap : Q.stimulus =
          { post_id = "readable-other-work"; urgency = Q.Low; arrived_at = 10.; payload = Q.Bootstrap } in
        enqueue_exn ~base_path keeper_name bootstrap;
        let mixed = intake () in
        assert_read_failure mixed;
        check (list string) "only readable work enters the completed turn"
          [ bootstrap.post_id ]
          (Keeper_heartbeat_source_batch.stimuli mixed.source_batch
           |> List.map (fun (source : Q.stimulus) -> source.post_id));
        check bool "unrelated admitted work can still run" true
          (Keeper_heartbeat_loop.should_run_turn_after_event_intake
             ~scheduled:true
             ~event_queue_intake_error:mixed.event_queue_intake_error);
        let complete batch =
          match Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
            (Some (completed_outcome meta)) with
          | Keeper_heartbeat_loop.Batch_ack_completed ->
            List.iter (fun selection ->
              match Keeper_registry_event_queue.terminalize_pending_turn_completed_result
                ~base_path keeper_name ~applied_at:1000. ~selection with
              | Ok (Keeper_registry_event_queue.Turn_source_acked
                  (Keeper_registry_event_queue.Acked _ | Keeper_registry_event_queue.Already_acked _)) -> ()
              | Ok _ -> fail "completion did not settle the admitted source"
              | Error detail -> fail detail)
              (Keeper_heartbeat_source_batch.selections batch)
          | _ -> fail "completed turn did not use normal batch settlement" in
        complete mixed.source_batch;
        let pending_ids () =
          match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
          | Error detail -> fail detail
          | Ok queue -> Q.to_list queue |> List.map (fun (source : Q.stimulus) -> source.post_id) in
        check (list string) "successful other work cannot ACK unread messages"
          (List.map (fun (source : Q.stimulus) -> source.post_id) messages) (pending_ids ());
        (match failure with
         | `Torn_tail | `Missing_rows -> Fs_compat.save_file path original
         | `Unreadable -> Unix.rmdir path; Sys.rename backup path
         | `Missing_file -> Sys.rename backup path);
        let restored = intake () in
        check int "restored original messages enter the next turn" count
          (Keeper_heartbeat_source_batch.count restored.source_batch);
        check (list string) "restoration delivers every original body"
          (List.init count (Printf.sprintf "original message %d"))
          (List.map (fun (event : Keeper_world_observation.pending_board_event) -> (Option.get event.preview))
             restored.pending_board_events);
        complete restored.source_batch;
        check (list string) "only successful restored delivery drains the messages" [] (pending_ids ())))
    [ 1; 2 ]
;;

let test_unavailable_ask_survives_other_completed_work ~failure () =
  with_ctx "ask-source-retained" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let module Intake = Keeper_heartbeat_stimulus_intake in
    let question = match Keeper_ask.question ~question_id:"notes" ~header:"notes"
        ~prompt:"What should happen?" ~choices:[] ~mode:Keeper_ask.Single
        ~free_text:(Keeper_ask.Free_text_allowed { hint = None }) with
      | Ok question -> question
      | Error error -> fail (Keeper_ask.invalid_question_to_string error) in
    let make_ask ask_id = match Keeper_ask.ask ~ask_id ~keeper_name
        ~questions:[question] ~context:"canonical answer delivery"
        ~continuation:(Keeper_continuation_channel.unrouted "fixture")
        ~asked_at:100. () with
      | Ok ask -> ask
      | Error error -> fail (Keeper_ask.invalid_ask_to_string error) in
    let ask = make_ask "retained-answer" in
    (match Keeper_ask_store.record_ask ~base_path ask with
     | Ok () -> () | Error detail -> fail detail);
    let responder : Keeper_ask.responder =
      { surface = Surface_ref.Dashboard { session_id = None }
      ; actor_id = Some "fixture-operator"; display_name = Some "Fixture operator" } in
    (match Keeper_ask_store.answer ~base_path ~keeper_name ~ask_id:ask.ask_id
        ~submissions:["notes", Keeper_ask.Wrote "original canonical answer"]
        ~responder ~now:200. with
     | Ok _ -> () | Error error -> fail (Keeper_ask_store.answer_failure_to_string error));
    let answered : Q.ask_answered =
      { ask_id = ask.ask_id; channel = ask.continuation } in
    let stimulus : Q.stimulus =
      { post_id = Q.ask_answered_post_id answered; urgency = Q.Normal
      ; arrived_at = 201.; payload = Q.Ask_answered answered } in
    let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
    enqueue_exn ~base_path keeper_name stimulus;
    let original_selection = match
        Keeper_registry_event_queue.pending_selections_result ~base_path keeper_name with
      | Ok [selection] -> selection
      | Ok _ -> fail "fixture should have one exact pending Ask"
      | Error detail -> fail detail in
    let path = Keeper_ask_store.log_path ~base_path ~keeper_name in
    let original = Fs_compat.load_file path in
    let backup = path ^ ".fixture-backup" in
    let open_log = Yojson.Safe.to_string (Keeper_ask.event_to_json (Keeper_ask.Asked ask)) ^ "\n" in
    (match failure with
     | `Unreadable -> Sys.rename path backup; Unix.mkdir path 0o700
     | `Malformed -> Fs_compat.save_file path ("{}\n" ^ original)
     | `Missing_file -> Sys.rename path backup
     | `Missing_rows -> Fs_compat.save_file path ""
     | `Open -> Fs_compat.save_file path open_log
     | `Withdrawn ->
       Fs_compat.save_file path open_log;
       (match Keeper_ask_store.withdraw ~base_path ~keeper_name ~ask_id:ask.ask_id
           ~reason:"fixture withdrawal" ~now:202. with
        | Ok () -> ()
        | Error error -> fail (Keeper_ask_store.withdraw_failure_to_string error)));
    let intake () = Intake.heartbeat_event_intake ~ctx ~meta_after_triage:meta
        ~pending_board_events:[] in
    (* A store read/decode failure is transient: the same log can read on a
       later heartbeat. A missing log or row and an Open/Withdrawn resolution
       are terminal — the append-only Ask store can never gain the answer this
       pointer names — so intake acknowledges the exact selection instead of
       retaining it. *)
    let terminal = match failure with
      | `Missing_file | `Missing_rows | `Open | `Withdrawn -> true
      | `Unreadable | `Malformed -> false in
    let assert_retry intake =
      let error = match intake.Intake.event_queue_intake_error, failure with
        | Some (Intake.Ask_read_failed (Keeper_ask_store.Log_read_failed _) as error), `Unreadable
        | Some (Intake.Ask_read_failed (Keeper_ask_store.Log_decode_failed _) as error), `Malformed -> error
        | _ -> fail "unavailable Ask was admitted or misclassified" in
      check bool "unavailable Ask is retry, not crashed cycle" false
        (Intake.event_queue_intake_error_counts_as_cycle_failure error);
      check bool "independent scheduling remains permitted" true
        (Keeper_heartbeat_loop.should_run_turn_after_event_intake ~scheduled:true
           ~event_queue_intake_error:intake.event_queue_intake_error);
      check bool "unavailable Ask alone cannot invent a scheduled turn" false
        (Keeper_heartbeat_loop.should_run_turn_after_event_intake ~scheduled:false
           ~event_queue_intake_error:intake.event_queue_intake_error) in
    let assert_no_delivery () =
      (match Keeper_reaction_ledger.event_queue_delivery_seen_for_source_strict_result
          ~base_path ~keeper_name ~not_before:0. ~post_id:stimulus.post_id
          ~stimulus_kind:Keeper_reaction_ledger.Ask_answered with
       | Ok seen -> check bool "failed canonical source has no positive delivery proof" false seen
       | Error error -> fail (Keeper_reaction_ledger.strict_delivery_evidence_error_to_string error));
      match Keeper_reaction_ledger.event_queue_reaction_evidence_result ~base_path
          ~keeper_name ~stimulus_id with
      | Ok (Keeper_reaction_ledger.Evidence_complete evidence) ->
        check bool "failed canonical source has no Turn_started" false evidence.turn_started_seen;
        check bool "failed canonical source has no ACK" false evidence.event_queue_ack_seen
      | Ok (Keeper_reaction_ledger.Evidence_quarantined _) -> fail "fixture ledger is quarantined"
      | Error error -> fail (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error) in
    let pending_ids () = match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
      | Ok queue -> Q.to_list queue |> List.map (fun (source : Q.stimulus) -> source.post_id)
      | Error detail -> fail detail in
    let assert_terminal_ack intake =
      check bool "terminal ask source is not an intake error" true
        (Option.is_none intake.Intake.event_queue_intake_error);
      check int "terminal ask source contributes no admitted source" 0
        (Keeper_heartbeat_source_batch.count intake.source_batch);
      check int "terminal ask source contributes no observation" 0
        (List.length intake.pending_board_events);
      check bool "terminal ask source contributes no trigger" true
        (intake.event_queue_triggers = []);
      check bool "terminal ack keeps no diagnostic selection" true
        (intake.diagnostic_selection = None);
      check (list string) "terminal ask source leaves the queue" []
        (pending_ids ()) in
    let complete batch =
      Keeper_heartbeat_loop.For_testing.record_replay_owned_turn_started_reactions
        ~ctx ~keeper_name (Keeper_heartbeat_source_batch.stimuli batch);
      match Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
          (Some (completed_outcome meta)) with
      | Keeper_heartbeat_loop.Batch_ack_completed ->
        List.iter (fun selection ->
          match Keeper_registry_event_queue.terminalize_pending_turn_completed_result
              ~base_path keeper_name ~applied_at:1000. ~selection with
          | Ok (Keeper_registry_event_queue.Turn_source_acked
              (Keeper_registry_event_queue.Acked _ | Keeper_registry_event_queue.Already_acked _)) -> ()
          | Ok _ -> fail "completed source was not acknowledged"
          | Error detail -> fail detail)
          (Keeper_heartbeat_source_batch.selections batch)
      | _ -> fail "completed turn did not use normal source settlement" in
    let first = intake () in
    if terminal then assert_terminal_ack first
    else begin
      assert_retry first;
      check int "unavailable Ask contributes no admitted source" 0
        (Keeper_heartbeat_source_batch.count first.source_batch);
      check int "unavailable Ask contributes no observation" 0 (List.length first.pending_board_events);
      check bool "unavailable Ask contributes no trigger" true (first.event_queue_triggers = []);
      check bool "diagnostic keeps the exact original selection" true
        (first.diagnostic_selection = Some original_selection)
    end;
    assert_no_delivery ();
    let sibling : Q.stimulus =
      { post_id = "readable-ask-sibling"; urgency = Q.Low; arrived_at = 202.; payload = Q.Bootstrap } in
    enqueue_exn ~base_path keeper_name sibling;
    let readable_ask_sources = match failure with
      | `Missing_rows | `Open | `Withdrawn ->
        let readable_ask = make_ask "readable-answer" in
        (match Keeper_ask_store.record_ask ~base_path readable_ask with
         | Ok () -> () | Error detail -> fail detail);
        (match Keeper_ask_store.answer ~base_path ~keeper_name ~ask_id:readable_ask.ask_id
            ~submissions:["notes", Keeper_ask.Wrote "independently readable answer"]
            ~responder ~now:203. with
         | Ok _ -> () | Error error -> fail (Keeper_ask_store.answer_failure_to_string error));
        let payload : Q.ask_answered =
          { ask_id = readable_ask.ask_id; channel = readable_ask.continuation } in
        let source : Q.stimulus =
          { post_id = Q.ask_answered_post_id payload; urgency = Q.Normal
          ; arrived_at = 204.; payload = Q.Ask_answered payload } in
        enqueue_exn ~base_path keeper_name source;
        [source]
      | `Unreadable | `Malformed | `Missing_file -> [] in
    let mixed = intake () in
    if terminal then
      check bool "terminal ask source stays settled while siblings dispatch" true
        (Option.is_none mixed.Intake.event_queue_intake_error)
    else assert_retry mixed;
    check (list string) "only readable siblings enter source batch"
      (List.map (fun (source : Q.stimulus) -> source.post_id) (readable_ask_sources @ [sibling]))
      (Keeper_heartbeat_source_batch.stimuli mixed.source_batch
       |> List.map (fun (source : Q.stimulus) -> source.post_id));
    check (list string) "only readable Ask contributes a mixed observation"
      (List.map (fun (source : Q.stimulus) -> source.post_id) readable_ask_sources)
      (List.map (fun (event : Keeper_world_observation.pending_board_event) -> event.post_id)
         mixed.pending_board_events);
    complete mixed.source_batch;
    check (list string) "other completion leaves exact Ask pending"
      (if terminal then [] else [stimulus.post_id]) (pending_ids ());
    assert_no_delivery ();
    (match failure with
     | `Unreadable -> Unix.rmdir path; Sys.rename backup path
     | `Missing_file -> Sys.rename backup path
     | `Malformed | `Missing_rows | `Open | `Withdrawn -> Fs_compat.save_file path original);
    if terminal then begin
      let restored = intake () in
      check bool "restored canonical read has no intake error" true
        (Option.is_none restored.Intake.event_queue_intake_error);
      check (list string) "terminal ack does not resurrect the queue entry" []
        (pending_ids ());
      assert_no_delivery ();
      (* The canonical answer was never lost: answer recovery enqueues a fresh
         pointer for the restored answer, and intake delivers it. Recovery
         delivers only to a Keeper whose meta file is stored. *)
      (match Keeper_meta_store.replace_snapshot (Workspace.default_config base_path) meta with
       | Ok _ -> () | Error error -> fail error);
      let report = match Keeper_ask_answer_wake.reconcile ~base_path with
        | Ok report -> report
        | Error error -> fail (Keeper_ask_store.read_error_to_string error) in
      check int "answer recovery re-enqueues the restored answer" 1 report.enqueued;
      check (list string) "fresh recovery pointer is pending" [stimulus.post_id]
        (pending_ids ());
      let recovered = intake () in
      (match recovered.pending_board_events with
       | [event] ->
         check string "recovered canonical answer reaches model observation"
           "notes: original canonical answer" (Option.get event.preview);
         check string "recovered observation stays bound to the original Ask"
           stimulus.post_id event.post_id
       | _ -> fail "recovered canonical answer produced no single observation");
      (* Recovery enqueued a fresh pointer whose arrived_at is the canonical
         answer time, so its durable identity differs from the withdrawn
         original's; evidence is checked on the fresh identity. *)
      let fresh_stimulus_id =
        match
          List.find_opt
            (fun (source : Q.stimulus) -> String.equal source.post_id stimulus.post_id)
            (Keeper_heartbeat_source_batch.stimuli recovered.source_batch)
        with
        | Some source -> Keeper_reaction_ledger.stimulus_id_of_event_queue source
        | None -> fail "fresh recovery pointer was not admitted" in
      assert_no_delivery ();
      complete recovered.source_batch;
      check (list string) "recovered delivery acknowledges the fresh pointer" []
        (pending_ids ());
      match Keeper_reaction_ledger.event_queue_reaction_evidence_result ~base_path
          ~keeper_name ~stimulus_id:fresh_stimulus_id with
      | Ok (Keeper_reaction_ledger.Evidence_complete evidence) ->
        check bool "recovered delivery records Turn_started" true evidence.turn_started_seen;
        check bool "recovered delivery records exact ACK" true evidence.event_queue_ack_seen
      | Ok (Keeper_reaction_ledger.Evidence_quarantined _) ->
        fail "recovered fixture ledger is quarantined"
      | Error error ->
        fail (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
    end else begin
      let restored = intake () in
      check bool "restored canonical read has no retry error" true
        (Option.is_none restored.event_queue_intake_error);
      check (list string) "restored source has exact Ask identity" [stimulus.post_id]
        (Keeper_heartbeat_source_batch.stimuli restored.source_batch
         |> List.map (fun (source : Q.stimulus) -> source.post_id));
      (match restored.pending_board_events with
       | [event] ->
         check string "canonical answer reaches model observation" "notes: original canonical answer" (Option.get event.preview);
         check string "observation stays bound to the original Ask" stimulus.post_id event.post_id
       | _ -> fail "restored canonical answer produced no single observation");
      assert_no_delivery ();
      complete restored.source_batch;
      check (list string) "only restored delivery acknowledges the Ask" [] (pending_ids ());
      match Keeper_reaction_ledger.event_queue_reaction_evidence_result ~base_path
          ~keeper_name ~stimulus_id with
      | Ok (Keeper_reaction_ledger.Evidence_complete evidence) ->
        check bool "restored delivery records Turn_started" true evidence.turn_started_seen;
        check bool "restored delivery records exact ACK" true evidence.event_queue_ack_seen
      | Ok (Keeper_reaction_ledger.Evidence_quarantined _) -> fail "restored fixture ledger is quarantined"
      | Error error -> fail (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
    end)
;;

let test_missing_prefix_does_not_starve_readable_connector ~cross_conversation () =
  Masc_test_deps.with_file_owned_values
    [ Env_config_keeper.KeeperAdmissionBounds.max_events_env_key, "2" ]
  @@ fun () ->
  with_ctx "connector-missing-prefix" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let messages = List.init 3 (fun index ->
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"same-channel"
        ~message_id:(string_of_int index) ~arrived_at:(Float.of_int (index + 1))
        ~content:(Printf.sprintf "recoverable %d" index)) in
    let path = A.attention_path ~base_path ~keeper_name in
    let original = Fs_compat.load_file path in
    Fs_compat.save_file path "";
    let readable = connector_attention_stimulus ~base_path ~keeper_name
      ~channel_id:(if cross_conversation then "other-channel" else "same-channel") ~message_id:"readable" ~arrived_at:4.
      ~content:"readable after missing prefix" in
    let later = connector_attention_stimulus ~base_path ~keeper_name
      ~channel_id:"later-channel" ~message_id:"later" ~arrived_at:6.
      ~content:"separate conversation" in
    let bootstrap : Q.stimulus =
      { post_id="independent-work"; urgency=Q.Low; arrived_at=5.; payload=Q.Bootstrap } in
    List.iter (enqueue_exn ~base_path keeper_name) (messages @ [readable; bootstrap; later]);
    let intake () = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    let pending_ids () =
      match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
      | Error detail -> fail detail
      | Ok queue -> Q.to_list queue |> List.map (fun (source : Q.stimulus) -> source.post_id) in
    let complete batch =
      match Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
        (Some (completed_outcome meta)) with
      | Keeper_heartbeat_loop.Batch_ack_completed ->
        List.iter (fun selection ->
          match Keeper_registry_event_queue.terminalize_pending_turn_completed_result
            ~base_path keeper_name ~applied_at:1000. ~selection with
          | Ok (Keeper_registry_event_queue.Turn_source_acked
              (Keeper_registry_event_queue.Acked _ | Keeper_registry_event_queue.Already_acked _)) -> ()
          | Ok _ -> fail "completion did not settle the admitted source"
          | Error detail -> fail detail)
          (Keeper_heartbeat_source_batch.selections batch)
      | _ -> fail "completed turn did not use normal batch settlement" in
    let cursor = match Log.Ring.recent ~limit:1 () with
      | entry :: _ -> entry.Log.Ring.seq | [] -> -1 in
    let mixed = intake () in
    let warnings = Log.Ring.recent ~since_seq:cursor ~module_filter:"Keeper" ()
      |> List.filter (fun (entry : Log.Ring.entry) ->
        entry.level = Log.Warn
        && String.starts_with ~prefix:"turn entry: retaining missing connector attention" entry.message) in
    check int "missing backlog produces one aggregate warning" 1 (List.length warnings);
    check (list string) "readable connector and independent work pass a missing prefix"
      [readable.post_id; bootstrap.post_id]
      (Keeper_heartbeat_source_batch.stimuli mixed.source_batch
       |> List.map (fun (source : Q.stimulus) -> source.post_id));
    check (list string) "readable connector body reaches the turn"
      ["readable after missing prefix"]
      (List.map (fun (event : Keeper_world_observation.pending_board_event) -> (Option.get event.preview))
         mixed.pending_board_events);
    complete mixed.source_batch;
    check (list string) "unrelated completion retains all missing pointers"
      (List.map (fun (source : Q.stimulus) -> source.post_id) (messages @ [later])) (pending_ids ());
    Fs_compat.save_file path (original ^ Fs_compat.load_file path);
    let first = intake () in
    check (list string) "restored prefix delivers within the admission bound"
      ["recoverable 0"; "recoverable 1"]
      (List.map (fun (event : Keeper_world_observation.pending_board_event) -> (Option.get event.preview))
         first.pending_board_events);
    complete first.source_batch;
    let last = intake () in
    check (list string) "remaining restored body is delivered"
      ["recoverable 2"]
      (List.map (fun (event : Keeper_world_observation.pending_board_event) -> (Option.get event.preview))
         last.pending_board_events);
    complete last.source_batch;
    check (list string) "another conversation was not mixed with restored messages"
      [later.post_id] (pending_ids ());
    let separate = intake () in
    check (list string) "later conversation gets its own delivery"
      ["separate conversation"]
      (List.map (fun (event : Keeper_world_observation.pending_board_event) -> (Option.get event.preview))
         separate.pending_board_events);
    complete separate.source_batch;
    check (list string) "restored successful deliveries ACK the remaining sources" [] (pending_ids ()))
;;

(* A shared store failure needs one diagnostic, regardless of backlog size.
   The independent source behind that backlog must still reach the next turn. *)
let test_failed_connector_batch_skips_shared_store_without_starving_other_work () =
  Masc_test_deps.with_file_owned_values
    [ Env_config_keeper.KeeperAdmissionBounds.max_events_env_key, "2" ]
  @@ fun () ->
  with_ctx "connector-failed-backlog" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let messages = List.init 5 (fun index ->
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"failed-batch"
        ~message_id:(string_of_int index) ~arrived_at:(Float.of_int (index + 1))
        ~content:(Printf.sprintf "retained body %d" index)) in
    let bootstrap : Q.stimulus =
      { post_id="independent-after-backlog";urgency=Q.Low;arrived_at=10.;payload=Q.Bootstrap } in
    List.iter (enqueue_exn ~base_path keeper_name) (messages @ [bootstrap]);
    let path = A.attention_path ~base_path ~keeper_name in
    Fs_compat.save_file path (Fs_compat.load_file path ^ "{");
    let cursor = match Log.Ring.recent ~limit:1 () with
      | entry :: _ -> entry.Log.Ring.seq | [] -> -1 in
    let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    let warnings = Log.Ring.recent ~since_seq:cursor ~module_filter:"Keeper" ()
      |> List.filter (fun (entry : Log.Ring.entry) -> entry.level = Log.Warn) in
    check int "one shared read failure emits one warning, not one per pending message"
      1 (List.length warnings);
    check (list string) "independent work behind unread backlog is admitted"
      [bootstrap.post_id]
      (Keeper_heartbeat_source_batch.stimuli intake.source_batch
       |> List.map (fun (source : Q.stimulus) -> source.post_id));
    check int "intake preserves every durable source" 6
      (Keeper_registry_event_queue.snapshot_result ~base_path keeper_name
       |> Result.map Q.length |> Result.value ~default:(-1)))
;;

let with_hitl_ctx keeper_name f =
  with_ctx keeper_name (fun ~base_path ~keeper_name ~meta ~ctx ->
    start_owner ~ctx ~base_path ~meta ~operation_runner:None ~on_turn_slot_released:None;
    (match Keeper_approval_queue.install_persistence ~base_path with
     | Ok _ -> ()
     | Error error -> fail (Keeper_approval_queue_result.install_error_to_string error));
    f ~base_path ~keeper_name ~meta ~ctx)
;;

let test_model_issued_hitl_continues_individually () =
  with_hitl_ctx "hitl-model-issued-singleton" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let first_id = approve_grant_exn ~base_path ~keeper_name ~request:"first" in
    let second_id = approve_grant_exn ~base_path ~keeper_name ~request:"second" in
    let first, second =
      match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
      | Ok queue ->
        (match Q.to_list queue with
         | [ first; second ] ->
           let approval_id (source : Q.stimulus) =
             match source.payload with
             | Q.Hitl_resolved resolution -> resolution.approval_id
             | _ -> fail "resolution enqueued a non-HITL source"
           in
           check (list string) "both real grants are queued in resolution order"
             [ first_id; second_id ] [ approval_id first; approval_id second ];
           first, second
         | _ -> fail "two approvals must produce two durable wakes")
      | Error detail -> fail detail
    in
    let intake =
      Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx
        ~meta_after_triage:meta
        ~pending_board_events:[]
    in
    check int "a model-issued operation continues individually" 1 (Keeper_heartbeat_source_batch.count intake.source_batch);
    check
      (list string)
      "the first model-issued operation fences the next approval"
      [ first.post_id ]
      (List.map (fun (source : Q.stimulus) -> source.post_id) (Keeper_heartbeat_source_batch.stimuli intake.source_batch));
    check int "only the admitted source reaches settlement" 1
      (List.length (Keeper_heartbeat_source_batch.selections intake.source_batch));
    (match (Keeper_heartbeat_source_batch.selections intake.source_batch) with
     | [ selection ] ->
       (match
          Keeper_registry_event_queue.terminalize_pending_turn_completed_result
            ~base_path
            keeper_name
            ~applied_at:1000.0
            ~selection
        with
        | Ok
            (Keeper_registry_event_queue.Turn_source_acked
               ( Keeper_registry_event_queue.Acked _
               | Keeper_registry_event_queue.Already_acked _ )) -> ()
        | Ok
            (Keeper_registry_event_queue.Turn_source_acked
               (Keeper_registry_event_queue.Ack_committed_followup_failed { detail; _ })) ->
          failf "first approval ACK follow-up failed: %s" detail
        | Ok Keeper_registry_event_queue.Turn_selection_withdrawn ->
          fail "first approval ACK found its selection withdrawn"
        | Error detail -> failf "first approval ACK failed: %s" detail)
     | _ -> fail "one HITL intake must carry one ACK selection");
    let queued =
      match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
      | Ok queue -> Q.to_list queue
      | Error detail -> failf "queue reload failed: %s" detail
    in
    check
      (list string)
      "ACK removes only the replayed approval; the second remains durable"
      [ second.post_id ]
      (List.map (fun (source : Q.stimulus) -> source.post_id) queued);
    let next =
      Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx
        ~meta_after_triage:meta
        ~pending_board_events:[]
    in
    check
      (list string)
      "the next turn admits the remaining exact approval"
      [ second.post_id ]
      (List.map (fun (source : Q.stimulus) -> source.post_id) (Keeper_heartbeat_source_batch.stimuli next.source_batch)))
;;

let hitl_ok = function Ok value -> value | Error detail -> fail detail

let approve_host_replay ~base_path ~keeper_name ~channel request =
  let tool_name = Keeper_gate.network_read_gate_operation in
  let input = `Assoc
    [ "capability", `String "web_search"
    ; "input", `Assoc [ "query", `String request ] ] in
  ignore (Keeper_tool_in_process_runtime.network_read_replay_of_gate_input input |> hitl_ok);
  let submission = Keeper_approval_queue.submit_pending
    ~origin:Keeper_approval_origin.unavailable ~base_path ~keeper_name ~tool_name ~input
    ~call_summary:None ~continuation_channel:channel ()
    |> Result.map_error Keeper_approval_queue_result.storage_error_to_string |> hitl_ok in
  ignore (Keeper_approval_queue.resolve_with_policy ~base_path ~id:submission.approval_id
    ~decision:Keeper_approval_queue_rules_types.Decision.Approve
    ~source:Keeper_approval_queue_rules_types.Human_operator ()
    |> Result.map_error Keeper_approval_queue.resolve_error_to_string |> hitl_ok);
  submission.approval_id, tool_name, input
;;

let hitl_id (source : Q.stimulus) = match source.payload with
  | Q.Hitl_resolved resolution -> resolution.approval_id
  | _ -> fail "expected an actual HITL queue source"
;;

let hitl_queue ~base_path ~keeper_name =
  Keeper_registry_event_queue.snapshot_result ~base_path keeper_name |> hitl_ok |> Q.to_list
;;

let consume_host_replay_fixture ~base_path ~keeper_name (id, tool_name, input) =
  ignore (Keeper_approval_queue.consume_approved_resolution ~base_path ~id ~keeper_name ~tool_name ~input
    |> Result.map_error Keeper_approval_queue_result.grant_error_to_string |> hitl_ok);
  let artifact = Keeper_gate_replay.For_testing.persist_replay_artifact ~base_path
    ("durable fixture result for " ^ id) |> hitl_ok in
  ignore (Keeper_approval_queue.record_consumed_resolution_replay ~base_path ~id
    ~outcome:(Keeper_approval_queue_result.Replay_applied artifact)
    |> Result.map_error Keeper_approval_queue_result.grant_error_to_string |> hitl_ok)
;;

let poison_only_approval_key ~base_path ~keeper_name approval_id =
  let path = Keeper_chat_store.chat_path ~base_dir:base_path ~keeper_name in
  let contents = In_channel.with_open_bin path In_channel.input_all in
  let duplicate = String.split_on_char '\n' contents |> List.find_map (fun line ->
    if String.equal line "" then None else
    let fields = Yojson.Safe.from_string line |> Yojson.Safe.Util.to_assoc in
    match Keeper_chat_delivery_identity.delivery_provenance_of_fields fields with
    | Ok (Some { delivery_key = Keeper_chat_delivery_identity.Approval_lifecycle id
               ; transcript_slot = Keeper_chat_delivery_identity.Approval_request })
      when String.equal approval_id (Keeper_chat_delivery_identity.Request_id.to_string id) ->
      Some (Yojson.Safe.to_string (`Assoc
        (("id", `String ("duplicate-" ^ approval_id)) :: List.remove_assoc "id" fields)))
    | _ -> None) |> Option.get in
  let channel = open_out_gen [ Open_wronly; Open_append; Open_binary ] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel (duplicate ^ "\n"))
;;

let test_fresh_hitl_cohort_settles_and_acks_each_input () =
  List.iter (fun case ->
    with_hitl_ctx "hitl-fresh-cohort-ack" (fun ~base_path ~keeper_name ~meta ~ctx ->
      let channel = Keeper_continuation_channel.unrouted "cohort fixture" in
      let first = approve_host_replay ~base_path ~keeper_name ~channel "first request" in
      let second = approve_host_replay ~base_path ~keeper_name ~channel "second request" in
      let first_id, _, _ = first and second_id, _, _ = second in
      let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
      let stimuli = Keeper_heartbeat_source_batch.stimuli intake.source_batch in
      check (list string) "one turn admits both fresh exact inputs in queue order"
        [ first_id; second_id ] (List.map hitl_id stimuli);
      let batch = Keeper_heartbeat_loop.For_testing.select_hitl_resolutions
        ~base_path ~keeper_name ~stimuli
        ~peek:(fun () -> fail "a peek must never add to an admitted HITL vector")
        |> Result.map_error Keeper_hitl_resolution_batch.join_error_to_string |> hitl_ok in
      let third_id, _, _ = approve_host_replay ~base_path ~keeper_name ~channel "later request" in
      consume_host_replay_fixture ~base_path ~keeper_name first;
      (match case with
       | `Second_unconsumed -> ()
       | `Both_ready | `First_projection_fails -> consume_host_replay_fixture ~base_path ~keeper_name second);
      (match case with
       | `First_projection_fails -> poison_only_approval_key ~base_path ~keeper_name first_id
       | `Both_ready | `Second_unconsumed -> ());
      let projections = Keeper_heartbeat_loop.For_testing.settle_hitl_continuations
        ~base_path ~keeper_name ~cycle_outcome:(Some (completed_outcome meta))
        ~resolutions:(Keeper_hitl_resolution_batch.resolutions batch) in
      check (list string) "each input keeps its own projection result"
        [ first_id; second_id ]
        (List.map (fun ((resolution : Q.hitl_resolution), _) -> resolution.approval_id) projections);
      let can_ack = Keeper_heartbeat_loop.For_testing.hitl_selection_has_recorded_continuation
        ~projections in
      let selected = Keeper_heartbeat_source_batch.selections intake.source_batch
        |> List.filter can_ack in
      let expected_acked = match case with
        | `Both_ready -> [ first_id; second_id ]
        | `Second_unconsumed -> [ first_id ]
        | `First_projection_fails -> [ second_id ] in
      check (list string) "only each input's recorded continuation authorizes its ACK"
        expected_acked (List.map (fun (selection : Keeper_event_queue_state.pending_selection) ->
          hitl_id selection.source) selected);
      List.iter (fun selection -> match Keeper_registry_event_queue.terminalize_pending_turn_completed_result
          ~base_path keeper_name ~applied_at:1000.0 ~selection with
        | Ok (Keeper_registry_event_queue.Turn_source_acked
            (Keeper_registry_event_queue.Acked _ | Already_acked _)) -> ()
        | Error detail -> fail detail
        | Ok _ -> fail "an exact admitted source failed to ACK") selected;
      let expected_pending = match case with
        | `Both_ready -> [ third_id ]
        | `Second_unconsumed -> [ second_id; third_id ]
        | `First_projection_fails -> [ first_id; third_id ] in
      check (list string) "failed, unconsumed and unselected wakes remain durable"
        expected_pending (hitl_queue ~base_path ~keeper_name |> List.map hitl_id)))
    [ `Both_ready; `Second_unconsumed; `First_projection_fails ]
;;

let test_incompatible_hitl_fences_the_later_ready_suffix () =
  with_hitl_ctx "hitl-route-fence" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let no_reply = Keeper_continuation_channel.unrouted "no reply" in
    let routed = Keeper_continuation_channel.discord ~guild_id:None ~channel_id:"other-room"
      ~parent_channel_id:None ~thread_id:None ~reply_to_message_id:"original-message"
      ~user_id:"operator" () |> hitl_ok in
    let first, _, _ = approve_host_replay ~base_path ~keeper_name ~channel:no_reply "first" in
    ignore (approve_host_replay ~base_path ~keeper_name ~channel:routed "incompatible second");
    ignore (approve_host_replay ~base_path ~keeper_name ~channel:no_reply "compatible third");
    let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    check (list string) "a later matching route cannot pass an incompatible ready input"
      [ first ] (Keeper_heartbeat_source_batch.stimuli intake.source_batch |> List.map hitl_id);
    check int "intake alone consumes no exact grant wake" 3
      (List.length (hitl_queue ~base_path ~keeper_name)))
;;

let test_changed_admitted_hitl_vector_is_not_replaced_by_a_peek () =
  with_hitl_ctx "hitl-vector-revalidation" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let channel = Keeper_continuation_channel.unrouted "revalidation fixture" in
    let first = approve_host_replay ~base_path ~keeper_name ~channel "first" in
    let second_id, _, _ = approve_host_replay ~base_path ~keeper_name ~channel "second" in
    let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    check int "both fresh inputs were actually admitted" 2
      (Keeper_heartbeat_source_batch.count intake.source_batch);
    consume_host_replay_fixture ~base_path ~keeper_name first;
    (match Keeper_heartbeat_loop.For_testing.select_hitl_resolutions ~base_path ~keeper_name
      ~stimuli:(Keeper_heartbeat_source_batch.stimuli intake.source_batch)
      ~peek:(fun () -> fail "a peek must not repair an incompatible actual vector") with
     | Error _ -> () | Ok _ -> fail "changed actual input vector bypassed revalidation");
    let delivery = Keeper_approval_queue.approved_resolution_delivery ~base_path ~id:second_id
      |> Result.map_error Keeper_approval_queue_result.grant_error_to_string |> hitl_ok in
    check bool "the unstarted sibling grant remains untouched" true
      (delivery.state = Keeper_approval_queue_result.Resolution_unconsumed && delivery.replay_outcome = None);
    check int "revalidation acknowledges neither wake" 2
      (List.length (hitl_queue ~base_path ~keeper_name)))
;;

(* Adversarial review P1-2: the turn-completion/failure batch disposition
   was inline in keeper_heartbeat_loop.ml's closure, reachable only through
   the full Eio ctx + durable registry harness — a regression from
   per-selection disposition back to primary-only would still pass every
   selection/consumption test in this file, because none of them drove the
   actual decision function. Now that the decision is the pure
   [Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome], pin its
   branches directly: no queue, no Eio, no registry. *)
let test_batch_disposition_of_cycle_outcome_pure_branches () =
  let meta = test_meta "batch-disposition-pure" in
  (match
     Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
       (Some (completed_outcome meta))
   with
   | Keeper_heartbeat_loop.Batch_ack_completed
     -> ()
   | _ ->
     fail "Completed must drive Batch_ack_completed");
  (match
     Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
       (Some
          (Keeper_heartbeat_loop_cycle.Checkpointed { meta }))
   with
   | Keeper_heartbeat_loop.Batch_ack_attention_only -> ()
   | _ ->
     fail
       "durable-stimulus checkpoint must advance attention-only sources before the newer source");
  List.iter
    (fun (outcome : Keeper_heartbeat_loop_cycle.cycle_outcome option) ->
       match Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome outcome with
       | Keeper_heartbeat_loop.Batch_no_action -> ()
       | _ -> fail "a non-terminal or absent cycle outcome must drive Batch_no_action")
    [ None
    ; Some
        (failed_outcome
           ~source_disposition:Keeper_unified_turn.Follow_failure_route
           ~route:transient_retry_route
           ~deferred_runtime_lane:None
           meta)
    ; Some
        (failed_outcome
           ~source_disposition:Keeper_unified_turn.Follow_failure_route
           ~route:deterministic_route
           ~deferred_runtime_lane:None
           meta)
    ; Some (Keeper_heartbeat_loop_cycle.Input_required meta)
    ; Some (Keeper_heartbeat_loop_cycle.Cancelled meta)
    ; Some (Keeper_heartbeat_loop_cycle.Skipped meta)
    ]
;;

(* RFC-0377 S5.1: channel A has 3 pending Connector_attention + channel B
   has 2, interleaved on the queue (A1, B1, A2, B2, A3) so the batch filter
   must select past channel B's entries, not just take a prefix. One intake
   admits A's 3 in arrival order; B's 2 stay queued untouched. *)
let test_batch_admits_same_conversation_in_arrival_order_leaves_other_channel_queued
      ()
  =
  with_ctx "connector-batch-channels" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let a1 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-A"
        ~message_id:"a1" ~arrived_at:1.0 ~content:"MARK-CHAN-A-1"
    in
    let b1 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-B"
        ~message_id:"b1" ~arrived_at:1.5 ~content:"MARK-CHAN-B-1"
    in
    let a2 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-A"
        ~message_id:"a2" ~arrived_at:2.0 ~content:"MARK-CHAN-A-2"
    in
    let b2 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-B"
        ~message_id:"b2" ~arrived_at:2.5 ~content:"MARK-CHAN-B-2"
    in
    let a3 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-A"
        ~message_id:"a3" ~arrived_at:3.0 ~content:"MARK-CHAN-A-3"
    in
    List.iter (enqueue_exn ~base_path keeper_name) [ a1; b1; a2; b2; a3 ];
    let intake =
      Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx
        ~meta_after_triage:meta
        ~pending_board_events:[]
    in
    check int "channel A's 3 pending messages are all admitted in one turn" 3
      (Keeper_heartbeat_source_batch.count intake.source_batch);
    check
      (list string)
      "consumed_stimuli are exactly channel A's, in arrival order"
      [ a1.Q.post_id; a2.Q.post_id; a3.Q.post_id ]
      (List.map (fun (s : Q.stimulus) -> s.Q.post_id) (Keeper_heartbeat_source_batch.stimuli intake.source_batch));
    check int "consumed_selections mirrors the same batch" 3
      (List.length (Keeper_heartbeat_source_batch.selections intake.source_batch));
    check
      (list string)
      "consumed_selections carries channel A's sources, in arrival order"
      [ a1.Q.post_id; a2.Q.post_id; a3.Q.post_id ]
      (List.map
         (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.Q.post_id)
         (Keeper_heartbeat_source_batch.selections intake.source_batch));
    check int "the turn context carries all 3 observations" 3
      (List.length intake.pending_board_events);
    List.iteri
      (fun i marker ->
         match List.nth_opt intake.pending_board_events i with
         | None -> failf "missing pending_board_event at index %d" i
         | Some (ev : Keeper_world_observation.pending_board_event) ->
           check bool
             (Printf.sprintf "observation %d carries %s in arrival order" i marker)
             true
             (contains ~needle:marker (Option.get ev.preview)))
      [ "MARK-CHAN-A-1"; "MARK-CHAN-A-2"; "MARK-CHAN-A-3" ];
    let queued =
      match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
      | Ok queue -> queue
      | Error detail -> failf "queue reload failed: %s" detail
    in
    check int
      "intake alone never acks: all 5 durable entries are still pending" 5
      (Q.length queued);
    check
      (list string)
      "channel B's 2 messages remain queued, untouched by A's batch"
      [ b1.Q.post_id; b2.Q.post_id ]
      (connector_event_ids_of_queue queued
       |> List.filter (fun id -> List.mem id [ b1.Q.post_id; b2.Q.post_id ])
       |> List.sort String.compare))
;;

(* A permanently unavailable Board source sitting between two
   same-conversation Connector_attention entries must be retired without
   blocking the connector batch or appearing as actionable turn input. *)
let test_batch_retires_permanent_board_poison_between_connector_matches () =
  with_ctx "connector-batch-mixed" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let a1 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-A"
        ~message_id:"a1" ~arrived_at:1.0 ~content:"MARK-MIXED-1"
    in
    let board = board_distractor_stimulus ~post_id:"board-distractor" ~arrived_at:2.0 in
    let a2 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-A"
        ~message_id:"a2" ~arrived_at:3.0 ~content:"MARK-MIXED-2"
    in
    List.iter (enqueue_exn ~base_path keeper_name) [ a1; board; a2 ];
    let intake =
      Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx
        ~meta_after_triage:meta
        ~pending_board_events:[]
    in
    check int "only the two connector entries are admitted, not the board signal"
      2 (Keeper_heartbeat_source_batch.count intake.source_batch);
    check
      (list string)
      "batch is exactly the two connector entries, in arrival order"
      [ a1.Q.post_id; a2.Q.post_id ]
      (List.map (fun (s : Q.stimulus) -> s.Q.post_id) (Keeper_heartbeat_source_batch.stimuli intake.source_batch));
    let queued =
      match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
      | Ok queue -> queue
      | Error detail -> failf "queue reload failed: %s" detail
    in
    check int "permanently missing board source is acked; connectors stay pending" 2
      (Q.length queued);
    check bool "the permanently missing board source is no longer pending" false
      (List.exists
         (fun (s : Q.stimulus) -> String.equal s.Q.post_id "board-distractor")
         (Q.to_list queued)))
;;

(* RFC-0377 S5.2: batch admitted, then the turn fails with a transient
   provider failure. Unlike the earlier version of this test (which
   assumed [Defer_to_queue_tail] and mutated the queue), the disposition here
   comes from a REAL
   [Keeper_heartbeat_loop_cycle.cycle_outcome] fixture through
   [Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome] — the exact
   function [keeper_heartbeat_loop.ml] now calls. Provider/runtime failure is
   not authority to rewrite any input row, so the whole batch must remain
   byte-for-byte pending. *)
let test_batch_turn_failure_leaves_every_member_queued () =
  with_ctx "connector-batch-failure" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let a1 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-A"
        ~message_id:"a1" ~arrived_at:1.0 ~content:"MARK-FAIL-1"
    in
    let a2 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-A"
        ~message_id:"a2" ~arrived_at:2.0 ~content:"MARK-FAIL-2"
    in
    let a3 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-A"
        ~message_id:"a3" ~arrived_at:3.0 ~content:"MARK-FAIL-3"
    in
    List.iter (enqueue_exn ~base_path keeper_name) [ a1; a2; a3 ];
    let intake =
      Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx
        ~meta_after_triage:meta
        ~pending_board_events:[]
    in
    check int "all 3 admitted as one batch" 3 (Keeper_heartbeat_source_batch.count intake.source_batch);
    check int "consumed_selections mirrors the batch" 3
      (List.length (Keeper_heartbeat_source_batch.selections intake.source_batch));
    let failed_cycle_outcome =
      failed_outcome
        ~source_disposition:Keeper_unified_turn.Follow_failure_route
        ~route:transient_retry_route
        ~deferred_runtime_lane:None
        meta
    in
    (match
       Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
         (Some failed_cycle_outcome)
     with
     | Keeper_heartbeat_loop.Batch_no_action -> ()
     | Keeper_heartbeat_loop.Batch_ack_completed
     | Keeper_heartbeat_loop.Batch_ack_attention_only ->
       fail "a failed turn must leave every admitted source pending");
    let queued =
      match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
      | Ok queue -> queue
      | Error detail -> failf "queue reload failed: %s" detail
    in
    check int "turn failure loses nothing: all 3 batch members remain queued" 3
      (Q.length queued);
    check
      (list string)
      "no partial ack: the exact same 3 events remain, none dropped"
      (List.sort String.compare [ a1.Q.post_id; a2.Q.post_id; a3.Q.post_id ])
      (connector_event_ids_of_queue queued))
;;

let test_checkpoint_retention_preserves_unsettled_sources () =
  with_ctx "connector-retention-settlement" (fun ~base_path ~keeper_name ~meta:_ ~ctx:_ ->
    let module Persistence = Keeper_event_queue_persistence in
    let require label = function
      | Ok value -> value
      | Error detail -> failf "%s: %s" label detail
    in
    let first = connector_attention_stimulus
      ~base_path ~keeper_name ~channel_id:"chan-retained"
      ~message_id:"first" ~arrived_at:1.0 ~content:"Still needs a reply" in
    let second = connector_attention_stimulus
      ~base_path ~keeper_name ~channel_id:"chan-retained"
      ~message_id:"second" ~arrived_at:2.0 ~content:"Independent pending reply" in
    let board = { (board_distractor_stimulus ~post_id:"board-retained" ~arrived_at:3.0)
                  with urgency=Q.Normal } in
    List.iter (enqueue_exn ~base_path keeper_name) [first; second; board];
    let pending () =
      Persistence.For_testing.reset_snapshot_cache_for_testing ();
      Persistence.pending_selections_result ~base_path ~keeper_name
      |> require "reload exact durable sources"
    in
    let original = pending () in
    let identities selections = List.map
      (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id)
      selections in
    (* The first yield and a run longer than the former count boundary must
       preserve the same requests. These are fixture observations, not gates. *)
    for cycle = 1 to 12 do
      Keeper_heartbeat_loop.For_testing.retain_checkpoint_continuations
        ~base_path ~keeper_name (pending ())
      |> require "retain checkpointed conversation";
      let retained = pending () in
      check (list string) "yield retains every exact input identity"
        (identities original) (identities retained);
      List.iter (fun (selection : Keeper_event_queue_state.pending_selection) ->
        let expected = match selection.source.payload with
          | Q.Connector_attention _ -> cycle
          | _ -> 0 in
        check int "retention count survives a cold durable reload"
          expected selection.checkpoint_retentions)
        retained
    done;
    let retained = pending () in
    let selected = List.find
      (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id = first.post_id)
      retained in
    let (_ : Keeper_registry_event_queue.turn_ack_result) =
      Keeper_registry_event_queue.terminalize_pending_turn_completed_result
        ~base_path keeper_name ~applied_at:1000.0 ~selection:selected
      |> require "explicit completion settles the exact source" in
    check (list string) "completion leaves other outstanding inputs intact"
      [board.post_id; second.post_id] (identities (pending ())))
;;

let test_checkpoint_rotates_whole_connector_conversation_after_boundary () =
  Masc_test_deps.with_file_owned_values
    [ Env_config_keeper.KeeperAdmissionBounds.max_events_env_key, "2" ]
  @@ fun () ->
  with_ctx "checkpoint-conversation-rotation" (fun ~base_path ~keeper_name ~meta ~ctx ->
    (match Keeper_owner_registry.install_from_store
        ~sw:ctx.sw ~operation_runner:None ~on_turn_slot_released:None ctx.config with
     | Ok _ -> ()
     | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
    (match Keeper_owner_registry.create_meta ~base_path meta with
     | Ok (Some _) -> ()
     | Ok None -> fail "conversation rotation fixture metadata disappeared"
     | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
    let require = function Ok value -> value | Error detail -> fail detail in
    let make channel message arrived_at = connector_attention_stimulus
      ~base_path ~keeper_name ~channel_id:channel ~message_id:message ~arrived_at
      ~content:("Original content " ^ message) in
    let a1 = make "conversation-A" "a1" 1.
    and a2 = make "conversation-A" "a2" 2.
    and a3 = make "conversation-A" "a3" 3. in
    List.iter (enqueue_exn ~base_path keeper_name) [a1;a2;a3];
    let intake () = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    let module Batch = Keeper_heartbeat_source_batch in
    let original = (intake ()).source_batch in
    let ids selections = List.map (fun (s : Keeper_event_queue_state.pending_selection) ->
      s.source.post_id) selections in
    check (list string) "bounded intake admits A's prefix in FIFO order"
      [a1.post_id;a2.post_id] (ids (Batch.selections original));
    let admitted = Batch.selections original in
    let b1 = make "conversation-B" "b1" 4. in
    enqueue_exn ~base_path keeper_name b1;
    let pending () =
      Keeper_event_queue_persistence.For_testing.reset_snapshot_cache_for_testing ();
      Keeper_event_queue_persistence.pending_selections_result ~base_path ~keeper_name |> require in
    let before_rotation = pending () in
    Keeper_heartbeat_loop.For_testing.retain_checkpoint_continuations
      ~base_path ~keeper_name admitted |> require;
    let rotated = pending () in
    check (list string) "whole A conversation moves behind B without reversing its suffix"
      [b1.post_id;a1.post_id;a2.post_id;a3.post_id] (ids rotated);
    List.iter (fun (s : Keeper_event_queue_state.pending_selection) ->
      let admitted = s.source.post_id=a1.post_id || s.source.post_id=a2.post_id in
      check int "only exact admitted sources count the checkpoint" (if admitted then 1 else 0)
        s.checkpoint_retentions;
      let original = List.find (fun (source : Q.stimulus) -> source.post_id=s.source.post_id)
        [a1;a2;a3;b1] in
      check bool "conversation rotation retains the exact original payload" true
        (original=s.source);
      let previous = List.find (fun (p : Keeper_event_queue_state.pending_selection) ->
        p.source.post_id=s.source.post_id) before_rotation in
      check (option (float 0.)) "first admission survives whole-conversation rotation"
        previous.first_admitted_at s.first_admitted_at;
      check bool "unselected B keeps its incarnation while A receives new queue authority"
        (s.source.post_id=b1.post_id)
        (Int64.equal previous.admitted_revision s.admitted_revision)) rotated;
    let selected_b = (intake ()).source_batch |> Batch.selections in
    check (list string) "actual next intake selects B instead of checkpointed A"
      [b1.post_id] (ids selected_b);
    let complete selections = List.iter (fun selection ->
      Keeper_registry_event_queue.terminalize_pending_turn_completed_result
        ~base_path keeper_name ~applied_at:10. ~selection |> require |> ignore) selections in
    complete selected_b;
    let resumed_a = (intake ()).source_batch |> Batch.selections in
    check (list string) "A resumes its original prefix after B completes"
      [a1.post_id;a2.post_id] (ids resumed_a);
    complete resumed_a;
    check (list string) "A's original unadmitted suffix remains next"
      [a3.post_id] (ids ((intake ()).source_batch |> Batch.selections)))
;;

let test_stale_connector_member_preserves_fifo_and_independent_progress () =
  with_ctx "checkpoint-stale-conversation" (fun ~base_path ~keeper_name ~meta:_ ~ctx:_ ->
    let require = function Ok value -> value | Error detail -> fail detail in
    let make channel message arrived_at = connector_attention_stimulus
      ~base_path ~keeper_name ~channel_id:channel ~message_id:message ~arrived_at
      ~content:("Original " ^ message) in
    let a1 = make "conversation-A" "a1" 1.
    and a2 = make "conversation-A" "a2" 2.
    and b1 = make "conversation-B" "b1" 3. in
    List.iter (enqueue_exn ~base_path keeper_name) [a1;a2;b1];
    let pending () =
      Keeper_event_queue_persistence.For_testing.reset_snapshot_cache_for_testing ();
      Keeper_event_queue_persistence.pending_selections_result ~base_path ~keeper_name |> require in
    let admitted = pending () in
    Keeper_event_queue_persistence.retain_checkpoint_batch_result
      ~base_path ~keeper_name ~selections:[ List.hd admitted ] () |> require |> ignore;
    (* Retaining one member retains its whole conversation, so both A rows
       now carry a newer incarnation than the [admitted] snapshot. *)
    let entry_of post_id = List.find
      (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id = post_id) in
    let stale_current = entry_of a1.post_id (pending ()) in
    let c1 = make "conversation-C" "c1" 4. in
    enqueue_exn ~base_path keeper_name c1;
    let failures = Keeper_registry_event_queue.retain_checkpoint_batch_result
      ~base_path keeper_name ~selections:admitted |> require in
    check (list string) "stale exact sources are reported, never silently accepted"
      [a1.post_id;a2.post_id] (List.map (fun ((s : Keeper_event_queue_state.pending_selection), _) ->
        s.source.post_id) failures);
    let current = pending () in
    check (list string) "stale A stays ordered while independent B moves behind C"
      [a1.post_id;a2.post_id;c1.post_id;b1.post_id]
      (List.map (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id) current);
    check bool "stale source's current state remains exactly unchanged" true
      (entry_of a1.post_id current=stale_current);
    (* Only the selected a1 was counted by the first retention; a2 moved with
       its conversation, and C was never admitted. *)
    List.iter (fun (s : Keeper_event_queue_state.pending_selection) ->
      check int "retention counts only admitted, valid selections"
        (if s.source.post_id=c1.post_id || s.source.post_id=a2.post_id then 0 else 1)
        s.checkpoint_retentions) current)
;;

(* A completed, addressed turn settles the entire admitted batch through the
   existing exact-source terminalization path. *)
let test_checkpoint_preserves_results_and_services_successors () =
  with_ctx "result-checkpoint-retention" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let module Persistence = Keeper_event_queue_persistence in
    let require label = function
      | Ok value -> value | Error detail -> failf "%s: %s" label detail in
    let channel = Keeper_continuation_channel.unrouted "checkpoint fixture" in
    let trace_id = Random_id.uuid_v7 () in
    let source : Keeper_owned_job_identity.source =
      {task_id=Some "original-task";
       turn_ref=Some (Ids.Turn_ref.make ~trace_id ~absolute_turn:7);
       tool_use_id=Some "original-call";trace_id=Some trace_id;keeper_turn_id=Some 7} in
    let authority = Masc_domain.System_llm_agent {agent_run_id="original-verifier"} in
    let payloads =
      [ Q.Delegate_completed {dc_operation_id="original-delegate";dc_keeper="delegate";
                              dc_terminal=Delegate_replied "complete original answer"}
      ; Q.Fusion_completed {run_id="original-fusion";terminal=Fusion_succeeded "original decision";
                            board_post_id="";channel}
      ; Q.Composition_completed {cc_request_id="original-composition";cc_tool="keeper_compose_original";
                                 cc_terminal=Composition_succeeded}
      ; Q.Owned_job_completed {oj_job_id=Keeper_owned_job_identity.Job_id.fresh ();
                               oj_source=source;oj_channel=channel}
      ; Q.Workspace_message {wmsg_request_id="original-message";wmsg_from="another-keeper"}
      ; Q.Ask_answered {ask_id="original-ask";channel}
      ; Q.Completion_authority_rejected {car_task_id="original-task";car_verification_id="rejected";
                                         car_reason="original reason";car_authority=authority}
      ; Q.Task_cancelled {tc_task_id="cancelled-task";tc_cancelled_by="original-owner";tc_reason=Some "cancelled"}
      ; Q.Task_outcome {to_task_id="approved-task";to_verification_id="approved";
                        to_producer=keeper_name;to_authority=authority} ] in
    let originals = List.mapi (fun index payload ->
      let post_id = Printf.sprintf "original-%d" index in
      let source : Q.stimulus = {post_id;urgency=Immediate;arrived_at=1.;payload} in
      Q.stimulus_to_yojson source |> Q.stimulus_of_yojson
      |> require "validate original source coordinates before enqueue") payloads in
    List.iter (enqueue_exn ~base_path keeper_name) originals;
    let selections () =
      Persistence.For_testing.reset_snapshot_cache_for_testing ();
      Persistence.pending_selections_result ~base_path ~keeper_name |> require "cold queue reload" in
    let admitted = selections () in
    let successor : Q.stimulus =
      {post_id="independent-successor";urgency=Immediate;arrived_at=2.;
       payload=Delegate_completed {dc_operation_id="independent-operation";dc_keeper="another-delegate";
                                    dc_terminal=Delegate_replied "independent answer"}} in
    enqueue_exn ~base_path keeper_name successor;
    Keeper_heartbeat_loop.For_testing.retain_checkpoint_continuations
      ~base_path ~keeper_name admitted |> require "checkpoint retains and rotates original results";
    let retained = selections () in
    check (list string) "independent successor precedes retained original results"
      (successor.post_id::List.map (fun (s : Q.stimulus) -> s.post_id) originals)
      (List.map (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id) retained);
    List.iter (fun (selection : Keeper_event_queue_state.pending_selection) ->
      if selection.source.post_id<>successor.post_id then (
        let original = List.find (fun (s : Q.stimulus) -> s.post_id=selection.source.post_id) originals in
        check bool "original complete payload and source identity survive cold reload" true
          (Q.stimulus_identity_equal original selection.source);
        check int "checkpoint retention is durable" 1 selection.checkpoint_retentions;
        check bool "post-checkpoint ACK policy cannot discard the result" false
          (Keeper_heartbeat_loop.For_testing.checkpoint_source_may_ack selection.source.payload))) retained;
    let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    (match Keeper_heartbeat_source_batch.first intake.source_batch with
     | Some first -> check string "actual next intake services independent successor"
         successor.post_id first.source.post_id
     | None -> fail "checkpoint retention blocked the independent successor");
    let final = List.find
      (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id=(List.hd originals).post_id)
      (selections ()) in
    Keeper_registry_event_queue.terminalize_pending_turn_completed_result
      ~base_path keeper_name ~applied_at:3. ~selection:final
    |> require "completed consumer can settle its exact original result" |> ignore;
    check bool "explicit completion removes only its original result" false
      (List.exists (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id=final.source.post_id)
         (selections ())))
;;

let test_checkpoint_stale_source_does_not_discard_healthy_sibling () =
  with_ctx "stale-checkpoint-retention" (fun ~base_path ~keeper_name ~meta:_ ~ctx:_ ->
    let module Persistence = Keeper_event_queue_persistence in
    let require = function Ok value -> value | Error detail -> fail detail in
    let make post_id : Q.stimulus =
      {post_id;urgency=Immediate;arrived_at=1.;
       payload=Delegate_completed {dc_operation_id=post_id;dc_keeper="delegate";
                                    dc_terminal=Delegate_replied "original result"}} in
    List.iter (enqueue_exn ~base_path keeper_name) [make "stale";make "healthy"];
    let pending () =
      Persistence.For_testing.reset_snapshot_cache_for_testing ();
      Persistence.pending_selections_result ~base_path ~keeper_name |> require in
    let admitted = pending () in
    let first = List.hd admitted in
    Persistence.retain_checkpoint_batch_result ~base_path ~keeper_name ~selections:[ first ] ()
      |> require |> ignore;
    enqueue_exn ~base_path keeper_name (make "independent");
    (match Keeper_heartbeat_loop.For_testing.retain_checkpoint_continuations
        ~base_path ~keeper_name admitted with
     | Error _ -> () | Ok () -> fail "stale checkpoint authority was silently accepted");
    let current = pending () in
    check (list string) "healthy sibling commits rotation despite stale peer"
      ["stale";"independent";"healthy"]
      (List.map (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id) current);
    List.iter (fun (s : Keeper_event_queue_state.pending_selection) ->
      let expected = if s.source.post_id="independent" then 0 else 1 in
      check int "stale source unchanged and healthy retention committed" expected s.checkpoint_retentions)
      current)
;;

let test_batch_completion_acks_every_member () =
  with_ctx "connector-batch-completion" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let a1 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-A"
        ~message_id:"a1" ~arrived_at:1.0 ~content:"MARK-DONE-1"
    in
    let a2 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-A"
        ~message_id:"a2" ~arrived_at:2.0 ~content:"MARK-DONE-2"
    in
    let a3 =
      connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"chan-A"
        ~message_id:"a3" ~arrived_at:3.0 ~content:"MARK-DONE-3"
    in
    List.iter (enqueue_exn ~base_path keeper_name) [ a1; a2; a3 ];
    let intake =
      Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx
        ~meta_after_triage:meta
        ~pending_board_events:[]
    in
    check int "all 3 admitted as one batch" 3 (Keeper_heartbeat_source_batch.count intake.source_batch);
    check int "consumed_selections mirrors the batch" 3
      (List.length (Keeper_heartbeat_source_batch.selections intake.source_batch));
    (match
       Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
         (Some (completed_outcome meta))
     with
     | Keeper_heartbeat_loop.Batch_ack_completed ->
       let acked =
         List.for_all
           (fun (selection : Keeper_event_queue_state.pending_selection) ->
              match
                Keeper_registry_event_queue.terminalize_pending_turn_completed_result
                  ~base_path
                  keeper_name
                  ~applied_at:1000.0
                  ~selection
              with
              | Ok
                  (Keeper_registry_event_queue.Turn_source_acked
                     ( Keeper_registry_event_queue.Acked _
                     | Keeper_registry_event_queue.Already_acked _ )) -> true
              | Ok
                  (Keeper_registry_event_queue.Turn_source_acked
                     (Keeper_registry_event_queue.Ack_committed_followup_failed
                        { detail; _ })) ->
                failf "ack follow-up failed for %s: %s" selection.source.Q.post_id detail
              | Ok Keeper_registry_event_queue.Turn_selection_withdrawn ->
                failf "ack found %s withdrawn" selection.source.Q.post_id
              | Error detail ->
                failf "ack failed for %s: %s" selection.source.Q.post_id detail)
           (Keeper_heartbeat_source_batch.selections intake.source_batch)
       in
       check bool "every batch member acks cleanly" true acked
     | Keeper_heartbeat_loop.Batch_ack_attention_only ->
       fail "a completed turn was classified as a checkpoint yield"
     | Keeper_heartbeat_loop.Batch_no_action ->
       fail "a completed, addressed outcome must drive Batch_ack_completed");
    let queued =
      match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
      | Ok queue -> queue
      | Error detail -> failf "queue reload failed: %s" detail
    in
    check int "turn completion acks all 3 batch members: none remain queued" 0
      (Q.length queued))
;;

let test_exact_batch_reaches_dispatch_and_settlement () =
  with_ctx "exact-batch-transport" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let module Batch = Keeper_heartbeat_source_batch in
    let module Persistence = Keeper_event_queue_persistence in
    let require label = function
      | Ok value -> value
      | Error detail -> failf "%s: %s" label detail
    in
    let sources = List.init 3 (fun index ->
      { Q.post_id = "mixed-" ^ string_of_int index
      ; urgency = Q.Normal
      ; arrived_at = Float.of_int index
      ; payload = Q.Bootstrap }) in
    List.iter (enqueue_exn ~base_path keeper_name) sources;
    let expected = Persistence.pending_selections_result ~base_path ~keeper_name
      |> require "pending selections" in
    check int "fixture enqueued three sources" 3 (List.length expected);
    let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    check bool "successful intake has no diagnostic authority" true
      (Option.is_none intake.diagnostic_selection);
    let input = Batch.for_turn ~reactive:false intake.source_batch in
    let batch = Batch.sources input in
    check bool "all exact identities reach turn input" true
      (Batch.selections batch = expected);
    (match Batch.wake input with
     | Keeper_registry.Woken payloads ->
       check int "cadence-discovered batch retains reactive payload view" 3 (List.length payloads)
     | _ -> fail "selected sources became a source-free cadence tick");
    let checked = ref [] in
    Keeper_turn_dispatch_authority.run (fun token ->
      Keeper_turn_dispatch_authority.install token (fun () ->
        Batch.validate ~diagnostic:intake.diagnostic_selection
          ~standing:(fun selection ->
            checked := selection :: !checked;
            Keeper_registry_event_queue.admitted_selection_standing_result
              ~base_path keeper_name ~selection)
          batch
        |> Result.map (fun (admitted, withdrawn) ->
          check bool "dispatch keeps the whole batch when nothing was withdrawn" true
            (Batch.selections admitted = expected && withdrawn = [])))
      |> require "install dispatch authority";
      Keeper_turn_dispatch_authority.validate token |> require "dispatch validation");
    check bool "dispatch validates the same complete exact batch" true
      (List.rev !checked = expected);
    List.iter (fun selection ->
      let (_ : Keeper_registry_event_queue.turn_ack_result) =
        Keeper_registry_event_queue.terminalize_pending_turn_completed_result
          ~base_path keeper_name ~applied_at:1000. ~selection
        |> require "settle exact source" in
      ()) (Batch.selections batch);
    let remaining = Persistence.pending_selections_result ~base_path ~keeper_name
      |> require "settled queue" in
    check int "every transported selection was durably settled" 0 (List.length remaining))
;;

(* A batch wake is one conversation's backlog, so it continues on that
   conversation. *)
let wake_channel ~channel_id ~message_id =
  match
    Keeper_continuation_channel.discord
      ~guild_id:(Some "guild-batch")
      ~channel_id
      ~parent_channel_id:None
      ~thread_id:None
      ~reply_to_message_id:message_id
      ~user_id:"user-batch"
      ()
  with
  | Ok channel -> channel
  | Error detail -> failf "channel fixture failed: %s" detail
;;

let wake_payload ~channel_id ~message_id : Q.stimulus_payload =
  Q.Connector_attention
    { event_id = Printf.sprintf "evt-%s-%s" channel_id message_id
    ; channel = wake_channel ~channel_id ~message_id
    }
;;

let test_batch_wake_continues_on_its_newest_member () =
  let wake =
    Keeper_registry.Woken
      [ wake_payload ~channel_id:"C-batch" ~message_id:"m1"
      ; wake_payload ~channel_id:"C-batch" ~message_id:"m2"
      ]
  in
  match Keeper_unified_turn.continuation_channel_of_wake wake with
  | None -> fail "a batched conversation wake must continue on its conversation"
  | Some channel ->
    check bool "the newest member's route" true
      (Keeper_continuation_channel.same_route channel
         (wake_channel ~channel_id:"C-batch" ~message_id:"m2"));
    check bool "the conversation every member shares" true
      (Keeper_continuation_channel.same_conversation channel
         (wake_channel ~channel_id:"C-batch" ~message_id:"m1"))
;;

let test_single_payload_wake_keeps_its_channel () =
  match
    Keeper_unified_turn.continuation_channel_of_wake
      (Keeper_registry.Woken [ wake_payload ~channel_id:"C-one" ~message_id:"m1" ])
  with
  | None -> fail "a single connector payload must continue on its channel"
  | Some channel ->
    check bool "same route as the payload" true
      (Keeper_continuation_channel.same_route channel
         (wake_channel ~channel_id:"C-one" ~message_id:"m1"))
;;

let test_batch_spanning_conversations_routes_nowhere () =
  let none label wake =
    match Keeper_unified_turn.continuation_channel_of_wake wake with
    | None -> ()
    | Some _ -> failf "%s must not route" label
  in
  none "two conversations"
    (Keeper_registry.Woken
       [ wake_payload ~channel_id:"C-a" ~message_id:"m1"
       ; wake_payload ~channel_id:"C-b" ~message_id:"m1"
       ]);
  none "empty wake" (Keeper_registry.Woken []);
  none "proactive tick" Keeper_registry.Proactive_tick
;;

(* Intake admits every ready non-connector payload into a connector batch, so
   a batch may mix kinds. Kinds that carry the same conversation are one
   continuation; a member without a channel is not part of any conversation
   and takes the route away from the whole batch. *)
let test_batch_of_mixed_kinds_in_one_conversation_routes_there () =
  let wake =
    Keeper_registry.Woken
      [ Q.Ask_answered
          { ask_id = "ask-1"; channel = wake_channel ~channel_id:"C-mixed" ~message_id:"m0" }
      ; wake_payload ~channel_id:"C-mixed" ~message_id:"m1"
      ]
  in
  match Keeper_unified_turn.continuation_channel_of_wake wake with
  | None -> fail "mixed kinds in one conversation must continue on it"
  | Some channel ->
    check bool "the last member's route" true
      (Keeper_continuation_channel.same_route channel
         (wake_channel ~channel_id:"C-mixed" ~message_id:"m1"));
    check bool "the conversation the answered ask shares" true
      (Keeper_continuation_channel.same_conversation channel
         (wake_channel ~channel_id:"C-mixed" ~message_id:"m0"))
;;

let test_batch_with_a_channel_less_member_routes_nowhere () =
  match
    Keeper_unified_turn.continuation_channel_of_wake
      (Keeper_registry.Woken
         [ wake_payload ~channel_id:"C-batch" ~message_id:"m1"
         ; Q.Bootstrap
         ; wake_payload ~channel_id:"C-batch" ~message_id:"m2"
         ])
  with
  | None -> ()
  | Some _ -> fail "a channel-less member must take the route from the batch"
;;

let () =
  run
    "keeper_connector_attention_batch"
    [ ( "all-ready Event Queue intake"
      , [ test_case "scheduled continuation cancellation and reinsertion remain exact" `Quick
            test_scheduled_continuation_withdrawal_and_reinsertion
        ; test_case "checkpoint survives schedule supersession and preserves live sources" `Quick
            test_checkpoint_after_schedule_supersession_preserves_live_sources
        ; test_case "checkpoint yields preserve requests until exact settlement" `Quick
            test_checkpoint_retention_preserves_unsettled_sources
        ; test_case "checkpoint retains the entire old conversation in FIFO order" `Quick
            test_checkpoint_rotates_whole_connector_conversation_after_boundary
        ; test_case "stale connector member preserves FIFO and independent progress" `Quick
            test_stale_connector_member_preserves_fifo_and_independent_progress
        ; test_case "checkpoint retains original results and admits independent successors" `Quick
            test_checkpoint_preserves_results_and_services_successors
        ; test_case "stale checkpoint source preserves healthy sibling progress" `Quick
            test_checkpoint_stale_source_does_not_discard_healthy_sibling
        ; test_case "exact batch reaches dispatch and settlement" `Quick
            test_exact_batch_reaches_dispatch_and_settlement
        ; test_case
            "scheduled work without result delivery shares the ready batch"
            `Quick
            test_scheduled_work_without_delivery_shares_the_ready_batch
        ; test_case "scheduled batches keep reply routes and resume uncompleted requests" `Quick
            test_scheduled_batches_preserve_result_delivery
        ; test_case "no-delivery schedules preserve connector reply routes in either queue order" `Quick
            test_unrouted_schedule_does_not_take_a_connector_reply_route
        ; test_case
            "model-issued HITL resolutions continue individually"
            `Quick
            test_model_issued_hitl_continues_individually
        ; test_case "fresh HITL cohorts settle and acknowledge each exact input" `Quick
            test_fresh_hitl_cohort_settles_and_acks_each_input
        ; test_case "incompatible HITL input fences its ready suffix" `Quick
            test_incompatible_hitl_fences_the_later_ready_suffix
        ; test_case "changed admitted HITL vector cannot fall back to a peek" `Quick
            test_changed_admitted_hitl_vector_is_not_replaced_by_a_peek
        ; test_case "missing connector file survives other completion and restoration" `Quick
            (test_unread_connector_sources_survive_other_completed_work ~failure:`Missing_file)
        ; test_case "missing connector rows survive other completion and restoration" `Quick
            (test_unread_connector_sources_survive_other_completed_work ~failure:`Missing_rows)
        ; test_case "missing prefix does not starve a readable connector" `Quick
            (test_missing_prefix_does_not_starve_readable_connector ~cross_conversation:false)
        ; test_case "missing conversation does not starve another readable conversation" `Quick
            (test_missing_prefix_does_not_starve_readable_connector ~cross_conversation:true)
        ; test_case "shared connector read failure skips backlog and admits independent work" `Quick
            test_failed_connector_batch_skips_shared_store_without_starving_other_work
        ; test_case "torn connector store survives other completed work and restoration" `Quick
            (test_unread_connector_sources_survive_other_completed_work ~failure:`Torn_tail)
        ; test_case "unreadable connector store survives other completed work and restoration" `Quick
            (test_unread_connector_sources_survive_other_completed_work ~failure:`Unreadable)
        ; test_case "unreadable Ask stays pending through sibling completion and canonical restoration" `Quick
            (test_unavailable_ask_survives_other_completed_work ~failure:`Unreadable)
        ; test_case "malformed Ask stays pending through sibling completion and canonical restoration" `Quick
            (test_unavailable_ask_survives_other_completed_work ~failure:`Malformed)
        ; test_case "missing Ask log is terminally acknowledged and canonically recoverable" `Quick
            (test_unavailable_ask_survives_other_completed_work ~failure:`Missing_file)
        ; test_case "missing Ask row is terminally acknowledged and canonically recoverable" `Quick
            (test_unavailable_ask_survives_other_completed_work ~failure:`Missing_rows)
        ; test_case "open Ask is terminally acknowledged and canonically recoverable" `Quick
            (test_unavailable_ask_survives_other_completed_work ~failure:`Open)
        ; test_case "withdrawn Ask is terminally acknowledged and canonically recoverable" `Quick
            (test_unavailable_ask_survives_other_completed_work ~failure:`Withdrawn)
        ; test_case
            "admits a channel's whole backlog in arrival order, leaves other \
             channels queued"
            `Quick
            test_batch_admits_same_conversation_in_arrival_order_leaves_other_channel_queued
        ; test_case
            "retires permanent Board poison between connector matches"
            `Quick
            test_batch_retires_permanent_board_poison_between_connector_matches
        ; test_case
            "turn failure leaves the whole batch pending: no partial ack"
            `Quick
            test_batch_turn_failure_leaves_every_member_queued
        ; test_case
            "turn completion acks every batch member, not only the primary"
            `Quick
            test_batch_completion_acks_every_member
        ] )
    ; ( "batch_disposition_of_cycle_outcome (P1-2)"
      , [ test_case
            "pins every branch of the pure disposition function"
            `Quick
            test_batch_disposition_of_cycle_outcome_pure_branches
        ] )
    ; ( "continuation_channel_of_wake"
      , [ test_case
            "a batched conversation wake continues on its newest member"
            `Quick
            test_batch_wake_continues_on_its_newest_member
        ; test_case
            "a single payload wake keeps its channel"
            `Quick
            test_single_payload_wake_keeps_its_channel
        ; test_case
            "a batch spanning conversations routes nowhere"
            `Quick
            test_batch_spanning_conversations_routes_nowhere
        ; test_case
            "mixed kinds in one conversation continue on it"
            `Quick
            test_batch_of_mixed_kinds_in_one_conversation_routes_there
        ; test_case
            "a channel-less member takes the route from the batch"
            `Quick
            test_batch_with_a_channel_less_member_routes_nowhere
        ] )
    ]
;;
