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
   completion acks the whole batch, a turn failure leaves the whole batch
   queued (no partial ack). *)

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

let completed_outcome ~route meta : Keeper_heartbeat_loop_cycle.cycle_outcome =
  Keeper_heartbeat_loop_cycle.Completed { meta; continuation_route = route }
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
      failf "failed to create Board batch source: %s" (Board.show_board_error error)
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

(* What someone else sent this Keeper, as the queue holds it. Intake consumes
   it without reading another store. *)
let workspace_message_stimulus ~id ~arrived_at : Q.stimulus =
  let message : Q.workspace_message =
    { wmsg_request_id = id; wmsg_from = "peer-keeper" }
  in
  { Q.post_id = Q.workspace_message_post_id message
  ; urgency = Q.Immediate
  ; arrived_at
  ; payload = Q.Workspace_message message
  }
;;

(* The answer to a request this Keeper made itself. *)
let delegate_completed_stimulus ~id ~arrived_at : Q.stimulus =
  { Q.post_id = id
  ; urgency = Q.Immediate
  ; arrived_at
  ; payload =
      Q.Delegate_completed
        { dc_operation_id = id
        ; dc_keeper = "original-delegate"
        ; dc_terminal = Q.Delegate_replied "delegate result"
        }
  }
;;

(* The receipt is a SHA256 pointer into the Keeper's tool outbox. *)
let tool_result_stimulus ~receipt ~arrived_at : Q.stimulus =
  { Q.post_id = "keeper-tool-result:" ^ receipt
  ; urgency = Q.Immediate
  ; arrived_at
  ; payload = Q.Tool_result_ready receipt
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
       | Q.Board_signal _ | Q.Board_attention _ | Q.Bootstrap
       | Q.Fusion_completed _ | Q.Schedule_due _ | Q.Hitl_resolved _
      | Q.Ask_answered _
       | Q.Completion_authority_rejected _
       | Q.Task_outcome _
       | Q.Task_cancelled _ | Q.Workspace_message _
       | Q.Delegate_completed _ | Q.Composition_completed _ | Q.Tool_result_ready _ | Q.Owned_job_completed _ | Q.Addon_operation_changed _ -> None)
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
  Board_dispatch.init_jsonl ~recipient_lookup:Recipient_lookup.none_declared ();
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

(* A free-slot listener, so an Owner is able to reserve the next slot. *)
let slot_released ~keeper_name:_ = ()

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

let test_scheduled_work_is_not_batched_with_other_requests () =
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
    check int "one scheduled occurrence owns the turn" 1
      (Keeper_heartbeat_source_batch.count intake.source_batch);
    check
      (list string)
      "only the first exact scheduled occurrence is admitted"
      [ (List.hd schedules).post_id ]
      (List.map (fun (source : Q.stimulus) -> source.post_id) (Keeper_heartbeat_source_batch.stimuli intake.source_batch));
    check int "only the owning scheduled request reaches the turn" 1
      (List.length intake.pending_board_events);
    check int "intake alone never ACKs actionable sources" 9
      (Keeper_registry_event_queue.snapshot_result ~base_path keeper_name
       |> Result.map Q.length
       |> Result.value ~default:(-1)))
;;

(* Exercise the actual durable queue, intake and checkpoint/terminal
   settlement boundaries. No provider or model is simulated: these decisions
   are assertions about source ownership, not tool effects. *)
let test_scheduled_checkpoint_successor_and_resume () =
  with_ctx "schedule-continuation" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let module Batch = Keeper_heartbeat_source_batch in
    let require = function Ok value -> value | Error detail -> fail detail in
    let first = scheduled_wake_stimulus ~occurrence:1 ~arrived_at:1. in
    let second = scheduled_wake_stimulus ~occurrence:2 ~arrived_at:2. in
    let cold_pending () =
      Keeper_event_queue_persistence.For_testing.reset_snapshot_cache_for_testing ();
      Keeper_event_queue_persistence.pending_selections_result ~base_path ~keeper_name
      |> require in
    let ids selections = List.map
      (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id) selections in
    let intake priority_sources =
      Keeper_heartbeat_stimulus_intake.heartbeat_event_intake_with_priority
        ~priority_sources ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    let complete selection =
      match Keeper_registry_event_queue.terminalize_pending_turn_completed_result
        ~base_path keeper_name ~applied_at:100. ~selection |> require with
      | Keeper_registry_event_queue.Turn_source_acked _ -> true
      | Turn_selection_withdrawn -> fail "completion lost its exact pending source" in
    let checkpoint batch =
      let outcome = Keeper_heartbeat_loop_cycle.Checkpointed
        { meta; checkpoint_reason = Keeper_unified_turn.Durable_stimulus_arrived
        ; continuation_route = Keeper_unified_turn.Continuation_no_terminal_effect_receipt } in
      match Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome (Some outcome) with
      | Keeper_heartbeat_loop.Batch_ack_attention_only ->
        let selections = Batch.selections batch in
        Keeper_heartbeat_loop.For_testing.retain_checkpoint_continuations
          ~base_path ~keeper_name selections |> require;
        check (list string) "checkpoint leaves scheduled work unfinished" []
          (ids (List.filter (fun (s : Keeper_event_queue_state.pending_selection) ->
             Keeper_heartbeat_loop.For_testing.checkpoint_source_may_ack s.source.payload)
             selections))
      | Batch_ack_completed | Batch_no_action -> fail "unexpected checkpoint disposition" in
    enqueue_exn ~base_path keeper_name first;
    let first_batch = (intake []).source_batch in
    enqueue_exn ~base_path keeper_name second;
    (* The Owner reserves the next slot for the occurrence that came due while
       the first one ran, and intake admits that exact occurrence ahead of
       queue order. *)
    let handoff = Keeper_scheduled_turn_handoff.pending ~base_path ~keeper_name
      |> require
      |> List.filter (fun (s : Keeper_event_queue_state.pending_selection) ->
           s.source.post_id = second.post_id) in
    checkpoint first_batch;
    check (list string) "cold durable reload retains both exact requests behind the successor"
      [second.post_id; first.post_id] (ids (cold_pending ()));
    let second_batch = (intake handoff).source_batch in
    check (list string) "successor owns only its occurrence"
      [second.post_id] (ids (Batch.selections second_batch));
    let validated, withdrawn = Batch.validate ~diagnostic:None
      ~standing:(fun selection -> Keeper_registry_event_queue.admitted_selection_standing_result
        ~base_path keeper_name ~selection) second_batch |> require in
    check int "dispatch did not withdraw successor" 0 (List.length withdrawn);
    List.iter (fun selection -> ignore (complete selection)) (Batch.selections validated);
    check (list string) "successor terminal leaves original work pending"
      [first.post_id] (ids (cold_pending ()));
    let resumed = intake [] in
    check (list string) "next intake reprojects the original exact request"
      [first.post_id] (ids (Batch.selections resumed.source_batch));
    (match resumed.pending_board_events with
     | [{Keeper_world_observation.event_kind = Keeper_world_observation.Schedule_due wake; _}] ->
       check string "resumed request retains the exact schedule instance"
         "instance-batch" wake.schedule_instance_id;
       check string "resumed request retains its original body"
         "scheduled batch work" wake.message
     | _ -> fail "resumed work has no exact scheduled prompt observation");
    checkpoint resumed.source_batch;
    check (list string) "another checkpoint cannot complete the original"
      [first.post_id] (ids (cold_pending ()));
    List.iter (fun selection -> ignore (complete selection))
      (Batch.selections (intake []).source_batch);
    check int "only explicit completion consumes original work" 0
      (List.length (cold_pending ())))
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
    let reinserted = Keeper_scheduled_turn_handoff.pending ~base_path ~keeper_name
      |> require in
    check int "reinserted occurrence is pending once" 1 (List.length reinserted);
    check bool "reinserted occurrence is new work for the active turn" true
      (List.for_all (Batch.arrived_since_intake captured) reinserted);
    (match validate captured with
     | Error detail ->
       check string "replacement strictly rejects old incarnation authority"
         "event queue pending selection incarnation changed" detail
     | Ok _ -> fail "reinserted source accepted old incarnation authority");
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
            (Some (completed_outcome ~route:Keeper_unified_turn.Continuation_route_not_applicable meta)) with
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
          (List.map (fun (event : Keeper_world_observation.pending_board_event) -> event.preview)
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
          (Some (completed_outcome ~route:Keeper_unified_turn.Continuation_route_not_applicable meta)) with
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
         pointer for the restored answer, and intake delivers it. *)
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
           "notes: original canonical answer" event.preview;
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
         check string "canonical answer reaches model observation" "notes: original canonical answer" event.preview;
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
  Masc_test_deps.with_process_env "MASC_KEEPER_ADMISSION_MAX_EVENTS" (Some "2")
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
        (Some (completed_outcome ~route:Keeper_unified_turn.Continuation_route_not_applicable meta)) with
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
      (List.map (fun (event : Keeper_world_observation.pending_board_event) -> event.preview)
         mixed.pending_board_events);
    complete mixed.source_batch;
    check (list string) "unrelated completion retains all missing pointers"
      (List.map (fun (source : Q.stimulus) -> source.post_id) (messages @ [later])) (pending_ids ());
    Fs_compat.save_file path (original ^ Fs_compat.load_file path);
    let first = intake () in
    check (list string) "restored prefix delivers within the admission bound"
      ["recoverable 0"; "recoverable 1"]
      (List.map (fun (event : Keeper_world_observation.pending_board_event) -> event.preview)
         first.pending_board_events);
    complete first.source_batch;
    let last = intake () in
    check (list string) "remaining restored body is delivered"
      ["recoverable 2"]
      (List.map (fun (event : Keeper_world_observation.pending_board_event) -> event.preview)
         last.pending_board_events);
    complete last.source_batch;
    check (list string) "another conversation was not mixed with restored messages"
      [later.post_id] (pending_ids ());
    let separate = intake () in
    check (list string) "later conversation gets its own delivery"
      ["separate conversation"]
      (List.map (fun (event : Keeper_world_observation.pending_board_event) -> event.preview)
         separate.pending_board_events);
    complete separate.source_batch;
    check (list string) "restored successful deliveries ACK the remaining sources" [] (pending_ids ()))
;;

(* A shared store failure needs one diagnostic, regardless of backlog size.
   The independent source behind that backlog must still reach the next turn. *)
let test_failed_connector_batch_skips_shared_store_without_starving_other_work () =
  Masc_test_deps.with_process_env "MASC_KEEPER_ADMISSION_MAX_EVENTS" (Some "2")
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

(* A proactive turn has no source of its own. What it finds in the queue, a
   pending approval and a ready source included, waits for the next intake,
   with or without a readable chat store. Only a row that arrives after that
   intake and may preempt stops it. *)
let test_backlog_never_interrupts_proactive_progress () =
  with_ctx "proactive-backlog" (fun ~base_path ~keeper_name ~meta ~ctx ->
    start_owner ~ctx ~base_path ~meta ~operation_runner:None
      ~on_turn_slot_released:None;
    (match Keeper_approval_queue.install_persistence ~base_path with
     | Ok _ -> ()
     | Error error -> fail (Masc.Keeper_approval_queue_result.install_error_to_string error));
    let approval_id =
      match Keeper_approval_queue.submit_pending ~origin:Keeper_approval_origin.unavailable ~keeper_name
          ~tool_name:"external-effect" ~input:(`Assoc []) ~call_summary:None ~base_path () with
      | Ok submission -> submission.approval_id
      | Error error -> fail (Masc.Keeper_approval_queue_result.storage_error_to_string error)
    in
    (* Model a resolution wake observed before the approval leaves pending. *)
    let waiting : Q.stimulus =
      { post_id = "pending-resolution-wake"; urgency = Q.Immediate; arrived_at = 1.0
      ; payload = Q.Hitl_resolved
          { approval_id; decision = Q.Hitl_approved
          ; channel = Keeper_continuation_channel.unrouted "readiness fixture" } }
    in
    enqueue_exn ~base_path keeper_name waiting;
    let yield_request turn_input =
      let probe, _ = Keeper_unified_turn.For_testing.autonomous_yield_probe
        ~turn_input ~base_path ~keeper_name in
      match probe () with
      | Ok request -> request
      | Error detail -> fail detail
    in
    let proactive = Keeper_heartbeat_source_batch.for_turn ~reactive:false
      Keeper_heartbeat_source_batch.empty in
    check bool "pending approval does not interrupt proactive progress" true
      (Option.is_none (yield_request proactive));
    let ready : Q.stimulus =
      { post_id = "ready-bootstrap"; urgency = Q.Normal; arrived_at = 2.0
      ; payload = Q.Bootstrap }
    in
    enqueue_exn ~base_path keeper_name ready;
    check bool "a ready source does not interrupt proactive progress either" true
      (Option.is_none (yield_request proactive));
    let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    check (list string) "the next intake admits it" [ready.post_id]
      (List.map (fun (source : Q.stimulus) -> source.post_id)
         (Keeper_heartbeat_source_batch.stimuli intake.source_batch));
    check int "observation and selection preserve both durable sources" 2
      (Keeper_registry_event_queue.snapshot_result ~base_path keeper_name
       |> Result.map Q.length |> Result.value ~default:(-1));
    let owner = match Keeper_owner_registry.get ~base_path ~keeper_name with
      | Ok owner -> owner
      | Error error -> fail (Keeper_owner_registry.lookup_error_to_string error) in
    let path = Keeper_chat_operation_store.path_for_keeper
        ~keepers_runtime_dir:(Workspace.keepers_runtime_dir ctx.config) ~keeper_name in
    let db = Sqlite3.db_open path in
    let dropped = Sqlite3.exec db "DROP TABLE operations" in
    ignore (Sqlite3.db_close db);
    check bool "fixture removes chat inventory authority" true (dropped = Sqlite3.Rc.OK);
    (match Keeper_owner.wake_operation_drain owner with
     | Error (Keeper_owner.Store_unavailable _) -> ()
     | Error error -> fail (Keeper_owner.error_to_string error)
     | Ok () -> fail "broken chat store appeared readable");
    check bool "chat outage is explicitly projected" true
      (Keeper_owner.operation_projection owner).store_unavailable;
    let after_intake = Keeper_heartbeat_source_batch.for_turn ~reactive:false
      intake.source_batch in
    check bool "chat outage does not make backlog interrupt the turn" true
      (Option.is_none (yield_request after_intake));
    let message = workspace_message_stimulus ~id:"peer-after-intake" ~arrived_at:3.0 in
    enqueue_exn ~base_path keeper_name message;
    (match yield_request after_intake with
     | Some {Keeper_agent_run.reason = Durable_stimulus_waiting summary} ->
       check int "chat outage still allows a new message to be reported alone" 1
         summary.pending_count;
       check (option string) "the new message owns the yield" (Some message.post_id)
         (Option.map (fun (source : Q.stimulus) -> source.post_id) summary.head)
     | Some {Keeper_agent_run.reason = Operation_queued} | None ->
       fail "a message arriving after intake did not request the next intake"))
;;

let test_one_intake_admits_only_one_hitl_resolution () =
  with_ctx "hitl-exact-replay-batch" (fun ~base_path ~keeper_name ~meta ~ctx ->
    (* Intake reconciles approved wakes against the authoritative Gate store.
       Exercise the real submit/resolve path, including its durable enqueue. *)
    (match
       Keeper_owner_registry.install_from_store
         ~sw:ctx.sw ~operation_runner:None ~on_turn_slot_released:None ctx.config
     with
     | Ok _ -> ()
     | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
    (match Keeper_owner_registry.create_meta ~base_path meta with
     | Ok (Some _) -> ()
     | Ok None -> fail "HITL fixture metadata disappeared"
     | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
    (match Keeper_approval_queue.install_persistence ~base_path with
     | Ok _ -> ()
     | Error error -> fail (Masc.Keeper_approval_queue_result.install_error_to_string error));
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
    check int "one turn owns one exact HITL grant" 1 (Keeper_heartbeat_source_batch.count intake.source_batch);
    check
      (list string)
      "the oldest ready approval is the only admitted source"
      [ first.post_id ]
      (List.map (fun (source : Q.stimulus) -> source.post_id) (Keeper_heartbeat_source_batch.stimuli intake.source_batch));
    check int "turn completion can ACK only that exact approval" 1
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
       (Some (completed_outcome ~route:Keeper_unified_turn.Continuation_route_addressed meta))
   with
   | Keeper_heartbeat_loop.Batch_ack_completed
     -> ()
   | _ ->
     fail "Completed + addressed route must drive Batch_ack_completed/Attention_resolved");
  (match
     Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
       (Some
          (Keeper_heartbeat_loop_cycle.Checkpointed
             { meta
             ; checkpoint_reason = Keeper_unified_turn.Durable_stimulus_arrived
             ; continuation_route = Keeper_unified_turn.Continuation_route_addressed
             }))
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

(* #34655: a completed turn acks its connector attention whether or not it
   produced a reply/ignore receipt. Holding the rows back until an exact
   receipt existed (#32096) made "read but not answered" a wake reason, and
   the same Discord rows were re-promoted on every wake (17 rows for a day;
   3,711 consumption lines on 2026-09-08, 36 turns in thirty minutes on
   2026-09-09). The turn's disposition stays on the reaction ledger's
   turn_finished row; the message stays in the external-attention store.
   #32277 is the same rule for board rows. *)
let test_batch_disposition_acks_a_completed_turn_without_a_reply_receipt () =
  let meta = test_meta "batch-disposition-no-receipt" in
  List.iter
    (fun route ->
       match
         Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
           (Some (completed_outcome ~route meta))
       with
       | Keeper_heartbeat_loop.Batch_ack_completed -> ()
       | Keeper_heartbeat_loop.Batch_ack_attention_only ->
         fail
           "a completed turn without a reply receipt retained its connector \
            attention — the rows come back on every wake (#34655)"
       | Keeper_heartbeat_loop.Batch_no_action ->
         fail
           "a completed turn must consume its admitted batch — leaving it \
            pending replays the same rows every turn (#32277)")
    [ Keeper_unified_turn.Continuation_route_mismatch
    ; Keeper_unified_turn.Continuation_no_terminal_effect_receipt
    ; Keeper_unified_turn.Continuation_route_not_applicable
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
             (contains ~needle:marker ev.preview))
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
  Masc_test_deps.with_process_env "MASC_KEEPER_ADMISSION_MAX_EVENTS" (Some "2")
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
    let input = Batch.for_turn ~reactive:true original in
    let probe = fst (Keeper_unified_turn.For_testing.autonomous_yield_probe
      ~turn_input:input ~base_path ~keeper_name) in
    check bool "the unadmitted A suffix is not a new arrival" true
      (Option.is_none (probe () |> require));
    let scope = Keeper_chat_operation.Operation_id.of_string "original-A-consumer"
      |> require |> Keeper_execution_scope_id.direct_operation in
    let admitted = Keeper_event_queue_persistence.bind_pending_repetition_scope_result
      ~base_path ~keeper_name ~selections:(Batch.selections original) ~scope () |> require in
    let b1 = make "conversation-B" "b1" 4. in
    enqueue_exn ~base_path keeper_name b1;
    (match probe () |> require with
     | Some {Keeper_agent_run.reason=Durable_stimulus_waiting summary} ->
       check (option string) "B causes the boundary checkpoint" (Some b1.post_id)
         (Option.map (fun (s : Q.stimulus) -> s.post_id) summary.head)
     | Some {reason=Operation_queued} | None -> fail "new conversation B did not request a yield");
    (match Keeper_agent_run.For_testing.native_tool_boundary
        ~repetition_execution:None
        ~terminal_effect_state:Keeper_tools_agent_core.Terminal_effect_open
        ~yield_requested:(Some probe) with
     | Ok (Runtime_agent.Yield Runtime_agent.Durable_stimulus_waiting) -> ()
     | Ok (Runtime_agent.Yield _ | Runtime_agent.Continue) | Error _ ->
       fail "the production settled-tool boundary did not yield to B");
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
      check bool "only admitted sources retain the original consumer binding" true
        (Option.equal Keeper_execution_scope_id.equal
           (if admitted then Some scope else None) s.repetition_scope);
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
    Keeper_event_queue_persistence.note_checkpoint_retention_result
      ~base_path ~keeper_name ~selection:(List.hd admitted) () |> require |> ignore;
    let stale_current = List.hd (pending ()) in
    let c1 = make "conversation-C" "c1" 4. in
    enqueue_exn ~base_path keeper_name c1;
    let failures = Keeper_registry_event_queue.retain_checkpoint_batch_result
      ~base_path keeper_name ~selections:admitted |> require in
    check (list string) "stale exact source is reported, never silently accepted"
      [a1.post_id] (List.map (fun ((s : Keeper_event_queue_state.pending_selection), _) ->
        s.source.post_id) failures);
    let current = pending () in
    check (list string) "stale A stays ordered while independent B moves behind C"
      [a1.post_id;a2.post_id;c1.post_id;b1.post_id]
      (List.map (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id) current);
    check bool "stale source's current state remains exactly unchanged" true
      (List.hd current=stale_current);
    List.iter (fun (s : Keeper_event_queue_state.pending_selection) ->
      check int "healthy admitted siblings retain counts without counting C"
        (if s.source.post_id=c1.post_id then 0 else 1) s.checkpoint_retentions) current)
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
      ; Q.Addon_operation_changed {ao_origin_id=String.make 64 'a';ao_publication_id=Random_id.uuid_v7 ();
                                   ao_source=source;ao_channel=channel}
      ; Q.Workspace_message {wmsg_request_id="original-message";wmsg_from="another-keeper"}
      ; Q.Ask_answered {ask_id="original-ask";channel}
      ; Q.Completion_authority_rejected {car_task_id="original-task";car_verification_id="rejected";
                                         car_reason="original reason";car_authority=authority}
      ; Q.Task_cancelled {tc_task_id="cancelled-task";tc_cancelled_by="original-owner";tc_reason=Some "cancelled"}
      ; Q.Task_outcome {to_task_id="approved-task";to_verification_id="approved";
                        to_producer=keeper_name;to_authority=authority} ] in
    let originals = List.mapi (fun index payload ->
      let post_id = match payload with
        | Q.Addon_operation_changed change -> Q.addon_operation_change_post_id change
        | Q.Bootstrap | Q.Board_signal _ | Q.Board_attention _ | Q.Schedule_due _
        | Q.Connector_attention _ | Q.Hitl_resolved _ | Q.Fusion_completed _
        | Q.Delegate_completed _ | Q.Composition_completed _ | Q.Tool_result_ready _
        | Q.Owned_job_completed _ | Q.Workspace_message _ | Q.Ask_answered _
        | Q.Completion_authority_rejected _ | Q.Task_cancelled _ | Q.Task_outcome _ ->
          Printf.sprintf "original-%d" index in
      let source : Q.stimulus = {post_id;urgency=Immediate;arrived_at=1.;payload} in
      Q.stimulus_to_yojson source |> Q.stimulus_of_yojson
      |> require "validate original source coordinates before enqueue") payloads in
    List.iter (enqueue_exn ~base_path keeper_name) originals;
    let selections () =
      Persistence.For_testing.reset_snapshot_cache_for_testing ();
      Persistence.pending_selections_result ~base_path ~keeper_name |> require "cold queue reload" in
    let scope = Keeper_chat_operation.Operation_id.of_string "original-consumer"
      |> require "consumer operation" |> Keeper_execution_scope_id.direct_operation in
    let admitted = Persistence.bind_pending_repetition_scope_result
      ~base_path ~keeper_name ~selections:(selections ()) ~scope () |> require "bind original consumer" in
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
        check bool "original consumer execution scope survives rotation" true
          (Option.equal Keeper_execution_scope_id.equal (Some scope) selection.repetition_scope);
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
    Persistence.note_checkpoint_retention_result ~base_path ~keeper_name ~selection:first ()
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
         (Some (completed_outcome ~route:Keeper_unified_turn.Continuation_route_addressed meta))
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

let test_exact_mixed_bindings_reach_dispatch_and_settlement () =
  with_ctx "mixed-scope-transport" (fun ~base_path ~keeper_name ~meta ~ctx ->
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
    let initial = Persistence.pending_selections_result ~base_path ~keeper_name
      |> require "initial selections" in
    let first, second = match initial with
      | first :: second :: _ -> first, second
      | _ -> fail "fixture did not enqueue three sources"
    in
    let direct = Keeper_chat_operation.Operation_id.of_string "originating-direct"
      |> require "operation ID" |> Keeper_execution_scope_id.direct_operation in
    let autonomous =
      match Uuidm.of_string "fde5c983-7a6f-4d87-bdad-53a51316f40d" with
      | Some id -> Keeper_execution_scope_id.autonomous_admission id
      | None -> fail "fixture UUID is invalid"
    in
    List.iter (fun (selection, scope) ->
      let (_ : Keeper_event_queue_state.pending_selection list) =
        Persistence.bind_pending_repetition_scope_result
          ~base_path ~keeper_name ~selections:[selection] ~scope ()
        |> require "bind distinct scopes" in
      ()) [first, direct; second, autonomous];
    let expected = Persistence.pending_selections_result ~base_path ~keeper_name
      |> require "bound selections" in
    let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    check bool "successful intake has no diagnostic authority" true
      (Option.is_none intake.diagnostic_selection);
    let input = Batch.for_turn ~reactive:false intake.source_batch in
    let batch = Batch.sources input in
    check bool "all exact identities and mixed bindings reach turn input" true
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
   conversation. Routing a batch as "not a continuation wake" made
   [Continuation_route_addressed] unreachable for any batched conversation,
   and under the rule #34662 removed such rows could never settle. *)
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

(* A chat may arrive after an autonomous official-client turn starts.
   Official clients own their resume history, so a settled host tool result
   alone does not permit terminating that provider turn. The waiting chat
   claims after the admitted turn completes. *)
let test_official_turn_keeps_tool_result_until_completion () =
  Eio_main.run
  @@ fun env ->
  Masc_test_deps.ensure_rng_initialized ();
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  Unix.putenv "MASC_BASE_PATH" base_path;
  let keeper_name = "official-chat-handoff" in
  let meta = test_meta keeper_name in
  Keeper_registry.For_testing.clear ();
  Fun.protect ~finally:(fun () -> Keeper_registry.For_testing.clear ()) @@ fun () ->
  ignore (Keeper_registry.For_testing.register ~base_path keeper_name meta);
  (* The chat child runs on another Eio domain. *)
  let chat_turns = Atomic.make 0 in
  let post_turn_chat, mark_post_turn_chat = Eio.Promise.create () in
  let operation_id =
    match
      Owner.Chat_operation.Operation_id.of_string "kmsg-official-chat-handoff"
    with
    | Ok operation_id -> operation_id
    | Error detail -> fail detail
  in
  let submit owner =
    match
      Owner.submit_operation owner ~operation_id
        ~source:(`Assoc [ "kind", `String "dashboard" ])
        ~input:(`Assoc [ "message", `String "answer after this tool" ])
    with
    | Ok _ -> ()
    | Error error -> fail (Owner.error_to_string error)
  in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    match claim () with
    | Ok (Some (operation : Owner.Chat_operation.t)) ->
      ignore (Atomic.fetch_and_add chat_turns 1);
      Eio.Promise.resolve mark_post_turn_chat operation.operation_id;
      Owner.Operation_succeeded { outcome_ref = "turn:official-chat-handoff" }
    | Ok None -> fail "the chat runner found an empty queue"
    | Error Owner.Owner_closed ->
      Owner.Operation_failed
        { kind = Owner.Chat_operation.Turn_cancelled
        ; detail = "keeper owner closed before the queued chat claimed"
        ; outcome_ref = None
        }
    | Error error -> fail (Owner.error_to_string error)
  in
  let noop_execution_settled ~keeper_name:_ ~claimed_operation_id:_ ~operations:_ ~execution:_ = () in
  (match
     Owner_registry.install_from_store
       ~sw
       ~operation_runner:
         (Some
            Owner.
              { ready = (fun ~keeper_name:_ -> true)
              ; execute
              ; on_execution_settled = noop_execution_settled
              })
       ~on_turn_slot_released:None
       (Workspace.default_config base_path)
   with
   | Ok _ -> ()
   | Error error -> fail (Owner_registry.install_error_to_string error));
  (* install_from_store materialises persisted keepers only; create_meta
     starts this one inside the pool, inheriting the runner above. *)
  (match Owner_registry.create_meta ~base_path meta with
   | Ok _ -> ()
   | Error error -> fail (Owner_registry.command_error_to_string error));
  let owner =
    match Owner_registry.get ~base_path ~keeper_name with
    | Ok owner -> owner
    | Error error -> fail (Owner_registry.lookup_error_to_string error)
  in
  (match
     Owner_registry.run_autonomous_if_idle ~base_path ~keeper_name (fun () ->
       let handed_off = ref false in
       let terminal_error = ref None in
       let tool =
         Agent_core.Tool.create ~name:"official-chat-probe" ~description:"settle work"
           ~parameters:[] (fun _ ->
             submit owner;
             Ok { Agent_core.Types.content = "settled result"
                ; content_blocks = None; _meta = None })
       in
       let projected =
         Keeper_official_client_host.dynamic_tools ~result_scope:None
           ~content_transport:Runtime_official_client_tool.Codex
           ~accepts_image_input:true ~tool_approval:None
           ~runtime_label:"official-chat-fixture" ~keeper_name ~turn_count:1
           ~tools:[tool] ~loading_plan:Keeper_official_client_host.All_on_demand
           ~hooks:Agent_core.Hooks.empty ~event_bus:None
           ~context_injector:None
           ~context:(Some (Agent_core.Context.create_sync ()))
           ~terminal_effect_state:(fun () ->
             Keeper_tools_agent_core.Terminal_effect_open)
           ~terminal_error ~pre_tool_rejects:(ref [])
           ~on_result_handoff:(fun ~invocation:_ ~content:_ -> handed_off := true)
           ~on_tool_boundary:(fun ~tool_name ->
             check bool "tool result handed off before boundary advice" true
               !handed_off;
             Keeper_agent_run.For_testing.official_client_tool_boundary
               ~repetition_execution:None ~yield_requested:None ~tool_name)
           ~raw_trace_run:None ()
       in
       let tool =
         match projected with
         | Ok ([tool], _) -> tool
         | Ok _ -> fail "expected one official-client tool"
         | Error error -> fail (Agent_core.Error.to_string error)
       in
       let result = tool.call ~call_id:"official-chat-settled-tool" (`Assoc []) in
       check bool "autonomous tool completed" true result.success;
       check string "settled tool result preserved" "settled result" result.content;
       check (option string) "boundary was not a tool error" None !terminal_error;
       check bool "the tool queued a claimable chat" true
         (Owner.operation_projection owner).has_claimable_queued;
       check int "queued chat did not claim during the official turn" 0
         (Atomic.get chat_turns);
       (* This direct probe establishes the AGENT_CORE advisory decision
          when a chat arrives during an autonomous turn. It does not run
          Agent_core.Agent.Advanced and therefore does not prove that a
          checkpoint was persisted. *)
       (match
          Keeper_agent_run.For_testing.native_tool_boundary
            ~repetition_execution:None
            ~terminal_effect_state:Keeper_tools_agent_core.Terminal_effect_open
            ~yield_requested:(Some (fst (
              Keeper_unified_turn.For_testing.autonomous_yield_probe
                ~turn_input:(Keeper_heartbeat_source_batch.for_turn ~reactive:false
                               Keeper_heartbeat_source_batch.empty)
                ~base_path ~keeper_name)))
        with
        | Ok (Runtime_agent.Yield Runtime_agent.Operation_queued) -> ()
        | Ok (Runtime_agent.Yield _ | Runtime_agent.Continue) | Error _ ->
          fail "the AGENT_CORE advisory ignored the newly queued chat");
       match result.abort_turn with
       | None -> ()
       | Some (Keeper_official_client_host.Repeated_tool_call _
               | Keeper_official_client_host.Terminal_tool_boundary _) ->
         fail "the official client stopped before its turn completed")
   with
   | Ok (`Ran ()) -> ()
   | Ok (`Busy _) -> fail "the empty owner did not admit the autonomous turn"
   | Ok `Interrupted -> fail "nothing interrupted the autonomous lane"
   | Error error -> fail (Owner_registry.command_error_to_string error));
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 3.0 (fun () ->
    let claimed_operation_id = Eio.Promise.await post_turn_chat in
    check bool "the waiting message claimed after the official turn" true
      (Owner.Chat_operation.Operation_id.equal operation_id claimed_operation_id);
    let rec await_settlement () =
      match Owner.exact_operation owner operation_id with
      | Error error -> fail (Owner.error_to_string error)
      | Ok None -> fail "the claimed follower disappeared"
      | Ok (Some operation) ->
        (match operation.state with
         | Owner.Chat_operation.Succeeded { outcome_ref; _ } ->
           check string "the follower completed after the official turn"
             "turn:official-chat-handoff" outcome_ref
         | Owner.Chat_operation.Queued | Owner.Chat_operation.Running _ ->
           Eio.Fiber.yield ();
           await_settlement ()
         | Owner.Chat_operation.Failed _ | Owner.Chat_operation.Cancelled _ ->
           fail "the follower did not settle successfully")
    in
    await_settlement ())
;;

let test_running_source_observes_new_completion_after_intake () =
  List.iter (fun backlog_size ->
    Masc_test_deps.with_process_env "MASC_KEEPER_ADMISSION_MAX_EVENTS" (Some "2")
    @@ fun () ->
    with_ctx (Printf.sprintf "successor-frontier-%d" backlog_size)
      (fun ~base_path ~keeper_name ~meta ~ctx ->
        (match Keeper_owner_registry.install_from_store
            ~sw:ctx.sw ~operation_runner:None ~on_turn_slot_released:None ctx.config with
         | Ok _ -> ()
         | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
        (match Keeper_owner_registry.create_meta ~base_path meta with
         | Ok (Some _) -> ()
         | Ok None -> fail "successor frontier fixture metadata disappeared"
         | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
        let require = function Ok value -> value | Error detail -> fail detail in
        let delegate id terminal : Q.stimulus =
          {post_id=id;urgency=Immediate;arrived_at=1.;
           payload=Delegate_completed {dc_operation_id=id;dc_keeper="original-delegate";
                                      dc_terminal=terminal}} in
        let initial = List.init backlog_size (fun i ->
          delegate (Printf.sprintf "existing-%d" i) (Delegate_replied "existing result")) in
        List.iter (enqueue_exn ~base_path keeper_name) initial;
        let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
          ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
        let module Batch = Keeper_heartbeat_source_batch in
        check int "admission respects the configured bound" 2 (Batch.count intake.source_batch);
        let backlog = Keeper_event_queue_persistence.pending_selections_result
          ~base_path ~keeper_name |> require in
        check int "the queue holds the whole backlog, admitted or not" backlog_size
          (List.length backlog);
        check bool "intake saw every backlog entry and none counts as a later arrival" true
          (List.for_all (fun s -> not (Batch.arrived_since_intake intake.source_batch s))
             backlog);
        let input = Batch.for_turn ~reactive:true intake.source_batch in
        let make_probe () = fst (Keeper_unified_turn.For_testing.autonomous_yield_probe
          ~turn_input:input ~base_path ~keeper_name) in
        let probe = make_probe () in
        check bool "neither own selections nor bounded existing backlog cause checkpoint exchange" true
          (Option.is_none (probe () |> require));
        let selected = Batch.selections intake.source_batch in
        let scope = Keeper_chat_operation.Operation_id.of_string "same-original-consumer"
          |> require |> Keeper_execution_scope_id.direct_operation in
        Keeper_event_queue_persistence.bind_pending_repetition_scope_result
          ~base_path ~keeper_name ~selections:selected ~scope () |> require |> ignore;
        check bool "scope binding does not make one's own source a new arrival" true
          (Option.is_none (probe () |> require));
        let successor = delegate "arrived-after-intake" (Delegate_failed "original producer failure") in
        enqueue_exn ~base_path keeper_name successor;
        (* Constructing the callback after enqueue must not hide the arrival.
           Its frontier comes from intake, before any provider preparation. *)
        let late_probe = make_probe () in
        List.iter (fun probe ->
          (match probe () |> require with
           | Some {Keeper_agent_run.reason=Durable_stimulus_waiting summary} ->
             check (option string) "the exact new completion owns the checkpoint"
               (Some successor.post_id)
               (Option.map (fun (s : Q.stimulus) -> s.post_id) summary.head)
           | Some {reason=Operation_queued} | None -> fail "new completion did not preempt");
          match Keeper_agent_run.For_testing.native_tool_boundary
              ~repetition_execution:None
              ~terminal_effect_state:Keeper_tools_agent_core.Terminal_effect_open
              ~yield_requested:(Some probe) with
          | Ok (Runtime_agent.Yield Runtime_agent.Durable_stimulus_waiting) -> ()
          | Ok (Runtime_agent.Yield _ | Runtime_agent.Continue) | Error _ ->
            fail "the real settled tool boundary ignored a new async completion")
          [probe;late_probe];
        let pending () = Keeper_event_queue_persistence.pending_selections_result
          ~base_path ~keeper_name |> require in
        check int "repeated boundary probes do not consume or duplicate results"
          (backlog_size+1) (List.length (pending ()));
        let successor_selection = List.find
          (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.post_id=successor.post_id)
          (pending ()) in
        Keeper_registry_event_queue.ack_pending_result ~base_path keeper_name
          ~selection:successor_selection |> require;
        check bool "withdrawn successor cannot cause another yield" true
          (Option.is_none (probe () |> require));
        let original = List.find (fun (s : Keeper_event_queue_state.pending_selection) ->
          s.source.post_id=(List.hd initial).post_id) (pending ()) in
        Keeper_registry_event_queue.ack_pending_result ~base_path keeper_name ~selection:original |> require;
        enqueue_exn ~base_path keeper_name original.source;
        match probe () |> require with
        | Some {Keeper_agent_run.reason=Durable_stimulus_waiting summary} ->
          check (option string) "reinserting identical content has a distinct incarnation"
            (Some original.source.post_id)
            (Option.map (fun (s : Q.stimulus) -> s.post_id) summary.head)
        | Some {reason=Operation_queued} | None -> fail "original snapshot hid a later incarnation"))
    [10;100;300]
;;

let test_running_source_does_not_preempt_after_queue_edit ~case ~edit () =
  with_ctx ("running-source-" ^ case) (fun ~base_path ~keeper_name ~meta ~ctx ->
    (match Keeper_owner_registry.install_from_store
        ~sw:ctx.sw ~operation_runner:None ~on_turn_slot_released:None ctx.config with
     | Ok _ -> ()
     | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
    (match Keeper_owner_registry.create_meta ~base_path meta with
     | Ok (Some _) -> ()
     | Ok None -> fail "running source fixture metadata disappeared"
     | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
    let require = function Ok value -> value | Error detail -> fail detail in
    let source : Q.stimulus =
      { post_id = "running-" ^ case; urgency = Q.Immediate; arrived_at = 1.
      ; payload = Q.Delegate_completed
          { dc_operation_id = "running-" ^ case; dc_keeper = "original-delegate"
          ; dc_terminal = Q.Delegate_replied "running result" } }
    in
    enqueue_exn ~base_path keeper_name source;
    let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    let module Batch = Keeper_heartbeat_source_batch in
    check int "one running source admitted" 1 (Batch.count intake.source_batch);
    let input = Batch.for_turn ~reactive:true intake.source_batch in
    let probe = fst (Keeper_unified_turn.For_testing.autonomous_yield_probe
      ~turn_input:input ~base_path ~keeper_name) in
    check bool (case ^ " intake does not preempt itself") true
      (Option.is_none (probe () |> require));
    let selection = match Batch.selections intake.source_batch with
      | [ selection ] -> selection
      | _ -> fail "expected exactly one running source selection" in
    edit ~base_path ~keeper_name ~selection |> require |> ignore;
    check bool (case ^ " does not turn the running source into a successor") true
      (Option.is_none (probe () |> require));
    let successor : Q.stimulus =
      { post_id = "after-" ^ case; urgency = Q.Immediate; arrived_at = 2.
      ; payload = Q.Delegate_completed
          { dc_operation_id = "after-" ^ case; dc_keeper = "original-delegate"
          ; dc_terminal = Q.Delegate_replied "arrived after the edit" } }
    in
    enqueue_exn ~base_path keeper_name successor;
    match probe () |> require with
    | Some {Keeper_agent_run.reason = Durable_stimulus_waiting summary} ->
      check (option string) (case ^ " a source admitted after the edit still preempts")
        (Some successor.post_id)
        (Option.map (fun (s : Q.stimulus) -> s.post_id) summary.head)
    | Some {reason = Operation_queued} | None ->
      fail (case ^ " edit hid a source admitted after it"))
;;

let test_running_source_does_not_preempt_after_reprioritize () =
  test_running_source_does_not_preempt_after_queue_edit
    ~case:"reprioritize"
    ~edit:(fun ~base_path ~keeper_name ~selection ->
      Keeper_registry_event_queue.reprioritize_pending_result
        ~base_path keeper_name ~selection ~urgency:Q.Low)
    ()
;;

let test_running_source_does_not_preempt_after_defer () =
  test_running_source_does_not_preempt_after_queue_edit
    ~case:"defer"
    ~edit:(fun ~base_path ~keeper_name ~selection ->
      Keeper_registry_event_queue.defer_pending_result
        ~base_path keeper_name ~selection)
    ()
;;

(* The payload kinds that stop a running turn when they reach the queue after
   its intake read it. *)
let stops_a_running_turn : Q.stimulus_payload -> bool = function
  | Q.Connector_attention _ | Q.Workspace_message _ | Q.Ask_answered _
  | Q.Completion_authority_rejected _ | Q.Task_cancelled _ | Q.Fusion_completed _
  | Q.Delegate_completed _ | Q.Composition_completed _ | Q.Owned_job_completed _
  | Q.Addon_operation_changed _ | Q.Task_outcome _ -> true
  | Q.Bootstrap | Q.Board_signal _ | Q.Board_attention _ | Q.Schedule_due _
  | Q.Hitl_resolved _ | Q.Tool_result_ready _ -> false
;;

(* One queue row of every payload kind, in the same order for every [case].
   [case] keeps ids and pointers apart between rows. The Hitl_resolved row is
   a rejection, which carries no grant to starve, so it never stops a turn. *)
let one_row_of_every_kind ~base_path ~keeper_name ~case ~arrived_at : Q.stimulus list =
  let tag = string_of_int case in
  let channel = Keeper_continuation_channel.unrouted "preempt-table" in
  let row post_id payload : Q.stimulus =
    { Q.post_id; urgency = Q.Low; arrived_at; payload } in
  let trace_id = Random_id.uuid_v7 () in
  let job_source : Keeper_owned_job_identity.source =
    { task_id = Some "table-task"
    ; turn_ref = Some (Ids.Turn_ref.make ~trace_id ~absolute_turn:7)
    ; tool_use_id = Some "table-call"; trace_id = Some trace_id; keeper_turn_id = Some 7 } in
  let authority = Masc_domain.System_llm_agent { agent_run_id = "judge-" ^ tag } in
  (* A SHA256-shaped pointer, as a tool receipt and an add-on origin carry. *)
  let receipt =
    Digest.to_hex (Digest.string (tag ^ "-a")) ^ Digest.to_hex (Digest.string (tag ^ "-b")) in
  let hitl : Q.hitl_resolution =
    { approval_id = "approval-" ^ tag; decision = Q.Hitl_rejected "fixture"; channel } in
  let ask : Q.ask_answered = { ask_id = "ask-" ^ tag; channel } in
  let rejection : Q.completion_authority_rejection =
    { car_task_id = "task-" ^ tag; car_verification_id = "verification-" ^ tag
    ; car_reason = "fixture"; car_authority = authority } in
  let cancellation : Q.task_cancellation =
    { tc_task_id = "cancelled-" ^ tag; tc_cancelled_by = "peer-keeper"; tc_reason = None } in
  let fusion : Q.fusion_completion =
    { run_id = "fusion-" ^ tag; terminal = Q.Fusion_cancelled; board_post_id = ""; channel } in
  let composition : Q.composition_completion =
    { cc_request_id = "composition-" ^ tag; cc_tool = "fixture-tool"
    ; cc_terminal = Q.Composition_succeeded } in
  let job : Q.owned_job_completion =
    { oj_job_id = Keeper_owned_job_identity.Job_id.fresh ()
    ; oj_source = job_source; oj_channel = channel } in
  let addon : Q.addon_operation_change =
    { ao_origin_id = receipt; ao_publication_id = Random_id.uuid_v7 ()
    ; ao_source = job_source; ao_channel = channel } in
  let outcome : Q.task_outcome =
    { to_task_id = "approved-" ^ tag; to_verification_id = "verification-" ^ tag
    ; to_producer = "fixture-keeper"; to_authority = authority } in
  [ board_distractor_stimulus ~post_id:("board-signal-" ^ tag) ~arrived_at
  ; board_attention_stimulus ~label:("board-attention-" ^ tag) ~arrived_at
  ; row ("bootstrap-" ^ tag) Q.Bootstrap
  ; tool_result_stimulus ~receipt ~arrived_at
  ; row (Q.fusion_completion_post_id fusion) (Q.Fusion_completed fusion)
  ; scheduled_wake_stimulus ~occurrence:case ~arrived_at
  ; connector_attention_stimulus ~base_path ~keeper_name ~channel_id:"preempt-table"
      ~message_id:tag ~arrived_at ~content:"table fixture"
  ; row (Q.hitl_resolution_post_id hitl) (Q.Hitl_resolved hitl)
  ; row (Q.ask_answered_post_id ask) (Q.Ask_answered ask)
  ; row (Q.completion_authority_rejection_post_id rejection)
      (Q.Completion_authority_rejected rejection)
  ; row (Q.task_cancellation_post_id cancellation) (Q.Task_cancelled cancellation)
  ; workspace_message_stimulus ~id:tag ~arrived_at
  ; delegate_completed_stimulus ~id:("delegate-" ^ tag) ~arrived_at
  ; row (Q.composition_completion_post_id composition) (Q.Composition_completed composition)
  ; row (Q.owned_job_completion_post_id job) (Q.Owned_job_completed job)
  ; row (Q.addon_operation_change_post_id addon) (Q.Addon_operation_changed addon)
  ; row (Q.task_outcome_post_id outcome) (Q.Task_outcome outcome)
  ]
;;

(* A running turn stops for a message to the Keeper, a result it asked for or
   input that voids its work, and only when that row reached the queue after
   its intake read it. Every kind is tried both ways, for a turn whose intake
   admitted nothing and for one whose intake admitted the row it saw. *)
let test_only_new_input_of_the_right_kind_preempts () =
  with_ctx "preempt-table" (fun ~base_path ~keeper_name ~meta ~ctx ->
    start_owner ~ctx ~base_path ~meta ~operation_runner:None
      ~on_turn_slot_released:None;
    let require = function Ok value -> value | Error detail -> fail detail in
    let module Batch = Keeper_heartbeat_source_batch in
    let pending () = Keeper_event_queue_persistence.pending_selections_result
      ~base_path ~keeper_name |> require in
    let clear () = List.iter (fun selection ->
      Keeper_registry_event_queue.ack_pending_result ~base_path keeper_name ~selection
      |> require) (pending ()) in
    let run_shape ~admit_source ~case =
      let seen_rows = one_row_of_every_kind ~base_path ~keeper_name ~case ~arrived_at:1. in
      let arrived_rows =
        one_row_of_every_kind ~base_path ~keeper_name ~case:(case + 1) ~arrived_at:2. in
      List.iter2 (fun (seen : Q.stimulus) (arrived : Q.stimulus) ->
        let kind = Q.payload_kind_label arrived.payload in
        if stops_a_running_turn arrived.payload then
          check bool (kind ^ " stops a turn only if intake can admit it") true
            (Keeper_heartbeat_stimulus_intake.stimulus_ready_for_intake ~base_path arrived);
        clear ();
        enqueue_exn ~base_path keeper_name seen;
        let frontier, read = Keeper_event_queue_persistence.pending_frontier_result
          ~base_path ~keeper_name |> require in
        let batch = Batch.of_intake ~frontier ~admitted:(if admit_source then read else []) in
        check bool (kind ^ ": the row intake read is no later arrival") true
          (List.for_all (fun row -> not (Batch.arrived_since_intake batch row)) read);
        let probe = fst (Keeper_unified_turn.For_testing.autonomous_yield_probe
          ~turn_input:(Batch.for_turn ~reactive:admit_source batch) ~base_path ~keeper_name) in
        check bool (kind ^ " seen by intake never preempts") true
          (Option.is_none (probe () |> require));
        enqueue_exn ~base_path keeper_name arrived;
        match probe () |> require with
        | Some {Keeper_agent_run.reason = Durable_stimulus_waiting summary} ->
          check bool (kind ^ " arriving after intake preempts") true
            (stops_a_running_turn arrived.payload);
          check (option string) (kind ^ " names the row that arrived") (Some arrived.post_id)
            (Option.map (fun (source : Q.stimulus) -> source.post_id) summary.head)
        | Some {reason = Operation_queued} -> fail (kind ^ " was mislabeled as chat")
        | None ->
          check bool (kind ^ " arriving after intake does not preempt") false
            (stops_a_running_turn arrived.payload))
        seen_rows arrived_rows
    in
    run_shape ~admit_source:false ~case:0;
    run_shape ~admit_source:true ~case:2)
;;

(* A queue the probe cannot read fails the probe, and the turn with it, instead
   of running on past rows it could not see. A proactive turn and a turn that
   was admitted a source read the same queue. *)
let test_unreadable_queue_fails_the_probe () =
  with_ctx "queue-read-failure" (fun ~base_path ~keeper_name ~meta ~ctx ->
    start_owner ~ctx ~base_path ~meta ~operation_runner:None
      ~on_turn_slot_released:None;
    let module Batch = Keeper_heartbeat_source_batch in
    enqueue_exn ~base_path keeper_name
      (workspace_message_stimulus ~id:"admitted" ~arrived_at:1.);
    let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    check int "intake admitted a source" 1 (Batch.count intake.source_batch);
    let turns =
      [ "a proactive turn", Batch.for_turn ~reactive:false Batch.empty
      ; "a source turn", Batch.for_turn ~reactive:true intake.source_batch ] in
    let reads_the_queue turn_input =
      let probe, _ = Keeper_unified_turn.For_testing.autonomous_yield_probe
        ~turn_input ~base_path ~keeper_name in
      Result.is_ok (probe ()) in
    List.iter (fun (label, turn_input) ->
      check bool (label ^ " reads a healthy queue") true (reads_the_queue turn_input))
      turns;
    Fs_compat.save_file
      (Filename.concat
         (Filename.concat (Workspace.keepers_runtime_dir ctx.config) keeper_name)
         Keeper_event_queue_persistence.snapshot_filename)
      "{";
    List.iter (fun (label, turn_input) ->
      check bool (label ^ " fails when the queue cannot be read") false
        (reads_the_queue turn_input))
      turns)
;;

(* The chat check's error reaches the caller: a turn that cannot tell whether a
   person is waiting does not go on as if nobody were. *)
let test_failed_chat_check_fails_the_probe () =
  with_ctx "chat-check-failure" (fun ~base_path ~keeper_name:_ ~meta:_ ~ctx:_ ->
    let probe, _ = Keeper_unified_turn.For_testing.autonomous_yield_probe
      ~turn_input:(Keeper_heartbeat_source_batch.for_turn ~reactive:false
                     Keeper_heartbeat_source_batch.empty)
      ~base_path ~keeper_name:"never-registered" in
    check bool "a Keeper the registry does not know fails the probe" true
      (Result.is_error (probe ())))
;;

(* The receipt a tool call leaves for its own result does not end the turn at
   the boundary after that call, on either runtime. A message that arrived
   after intake does. *)
let test_tool_receipt_does_not_end_a_turn_at_a_tool_boundary () =
  with_ctx "receipt-at-boundary" (fun ~base_path ~keeper_name ~meta ~ctx ->
    start_owner ~ctx ~base_path ~meta ~operation_runner:None
      ~on_turn_slot_released:None;
    let require = function Ok value -> value | Error detail -> fail detail in
    let module Batch = Keeper_heartbeat_source_batch in
    let frontier, _ = Keeper_event_queue_persistence.pending_frontier_result
      ~base_path ~keeper_name |> require in
    let probe = fst (Keeper_unified_turn.For_testing.autonomous_yield_probe
      ~turn_input:(Batch.for_turn ~reactive:false (Batch.of_intake ~frontier ~admitted:[]))
      ~base_path ~keeper_name) in
    let agent_core () = Keeper_agent_run.For_testing.native_tool_boundary
      ~repetition_execution:None
      ~terminal_effect_state:Keeper_tools_agent_core.Terminal_effect_open
      ~yield_requested:(Some probe) in
    let official_client () = Keeper_agent_run.For_testing.official_client_tool_boundary
      ~repetition_execution:None ~yield_requested:(Some probe) ~tool_name:"keeper_tool" in
    enqueue_exn ~base_path keeper_name
      (tool_result_stimulus ~receipt:(String.make 64 'a') ~arrived_at:1.);
    (match agent_core () with
     | Ok Runtime_agent.Continue -> ()
     | Ok (Runtime_agent.Yield _) | Error _ ->
       fail "a tool receipt ended an AGENT_CORE turn at its tool boundary");
    (match official_client () with
     | Ok None -> ()
     | Ok (Some _) | Error _ ->
       fail "a tool receipt ended an official-client turn at its tool boundary");
    enqueue_exn ~base_path keeper_name (workspace_message_stimulus ~id:"peer" ~arrived_at:2.);
    (match agent_core () with
     | Ok (Runtime_agent.Yield Runtime_agent.Durable_stimulus_waiting) -> ()
     | Ok (Runtime_agent.Yield _ | Runtime_agent.Continue) | Error _ ->
       fail "a message from a peer did not end an AGENT_CORE turn");
    match official_client () with
    | Ok (Some _) -> ()
    | Ok None | Error _ -> fail "a message from a peer did not end an official-client turn")
;;

(* An approved Gate resolution whose grant is unspent stops a turn even when
   its intake already read the resolution: the grant is spent by the turn
   itself, so the intake frontier says nothing about it. *)
let test_unspent_grant_stops_a_turn_whose_intake_read_it () =
  with_ctx "grant-read-at-intake" (fun ~base_path ~keeper_name ~meta ~ctx ->
    start_owner ~ctx ~base_path ~meta ~operation_runner:None
      ~on_turn_slot_released:None;
    (match Keeper_approval_queue.install_persistence ~base_path with
     | Ok _ -> ()
     | Error error -> fail (Masc.Keeper_approval_queue_result.install_error_to_string error));
    ignore (approve_grant_exn ~base_path ~keeper_name ~request:"read-at-intake");
    let module Batch = Keeper_heartbeat_source_batch in
    let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    let pending = Keeper_event_queue_persistence.pending_selections_result
      ~base_path ~keeper_name |> function Ok rows -> rows | Error detail -> fail detail in
    check int "intake admitted the resolution" 1 (Batch.count intake.source_batch);
    check bool "the resolution is no later arrival" true
      (List.for_all (fun row -> not (Batch.arrived_since_intake intake.source_batch row))
         pending);
    let probe = fst (Keeper_unified_turn.For_testing.autonomous_yield_probe
      ~turn_input:(Batch.for_turn ~reactive:true intake.source_batch)
      ~base_path ~keeper_name) in
    match probe () with
    | Ok (Some {Keeper_agent_run.reason = Durable_stimulus_waiting summary}) ->
      check (list string) "the resolution owns the yield"
        (List.map (fun (source : Q.stimulus) -> source.post_id) (Batch.stimuli intake.source_batch))
        (Option.to_list
           (Option.map (fun (source : Q.stimulus) -> source.post_id) summary.head))
    | Ok (Some {reason = Operation_queued}) -> fail "the Gate yield was mislabeled as chat"
    | Ok None -> fail "an unspent grant read at intake did not stop the turn"
    | Error detail -> fail detail)
;;

(* A schedule that comes due while an autonomous turn runs waits for the next
   intake and does not stop the turn. A heartbeat consumer is registered and
   the Owner can release a slot, so a reservation request from the boundary
   would be accepted. *)
let test_due_schedule_does_not_preempt_an_autonomous_turn () =
  with_ctx "schedule-after-intake" (fun ~base_path ~keeper_name ~meta ~ctx ->
    start_owner ~ctx ~base_path ~meta ~operation_runner:None
      ~on_turn_slot_released:(Some slot_released);
    let require = function Ok value -> value | Error detail -> fail detail in
    (match Owner_registry.begin_scheduled_turn_consumer ~base_path ~keeper_name with
     | Ok _ -> ()
     | Error error -> fail (Owner_registry.command_error_to_string error));
    let intake = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
    match
      Owner_registry.run_autonomous_if_idle ~base_path ~keeper_name (fun () ->
        let probe = fst (Keeper_unified_turn.For_testing.autonomous_yield_probe
          ~turn_input:(Keeper_heartbeat_source_batch.for_turn ~reactive:false
                         intake.source_batch)
          ~base_path ~keeper_name) in
        enqueue_exn ~base_path keeper_name
          (scheduled_wake_stimulus ~occurrence:1 ~arrived_at:1.);
        check bool "a schedule that came due after intake does not stop the turn" true
          (Option.is_none (probe () |> require)))
    with
    | Ok (`Ran ()) -> ()
    | Ok (`Busy _) -> fail "the idle owner did not admit the autonomous turn"
    | Ok `Interrupted -> fail "nothing interrupted the autonomous lane"
    | Error error -> fail (Owner_registry.command_error_to_string error))
;;

(* A direct chat turn does not yield to a schedule that is due. A chat
   admitted after it that waits for the slot still makes it yield. *)
let test_direct_turn_does_not_yield_to_a_due_schedule () =
  Eio_main.run
  @@ fun env ->
  Masc_test_deps.ensure_rng_initialized ();
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  Unix.putenv "MASC_BASE_PATH" base_path;
  let keeper_name = "direct-schedule-yield" in
  let meta = test_meta keeper_name in
  Keeper_registry.For_testing.clear ();
  Fun.protect ~finally:(fun () -> Keeper_registry.For_testing.clear ()) @@ fun () ->
  ignore (Keeper_registry.For_testing.register ~base_path keeper_name meta);
  let operation_id name =
    match Owner.Chat_operation.Operation_id.of_string name with
    | Ok operation_id -> operation_id
    | Error detail -> fail detail
  in
  let first_id = operation_id "kmsg-direct-schedule-first" in
  let second_id = operation_id "kmsg-direct-schedule-second" in
  let request_from_first () =
    Keeper_chat_yield_request.request
      ~turn:(Keeper_chat_yield_request.Direct first_id) ~base_path ~keeper_name
  in
  let alone, resolve_alone = Eio.Promise.create () in
  let second_queued, resolve_second_queued = Eio.Promise.create () in
  let later, resolve_later = Eio.Promise.create () in
  (* The chat child runs on another Eio domain, so it reports what the yield
     request answered and the test body judges it. *)
  let execute ~sw:_ ~keeper_name:_ ~claim =
    match claim () with
    | Ok (Some (operation : Owner.Chat_operation.t)) ->
      if Owner.Chat_operation.Operation_id.equal operation.operation_id first_id
      then begin
        Eio.Promise.resolve resolve_alone (request_from_first ());
        Eio.Promise.await second_queued;
        Eio.Promise.resolve resolve_later (request_from_first ())
      end;
      Owner.Operation_succeeded
        { outcome_ref =
            "turn:" ^ Owner.Chat_operation.Operation_id.to_string operation.operation_id }
    | Ok None -> fail "the chat runner found an empty queue"
    | Error Owner.Owner_closed ->
      Owner.Operation_failed
        { kind = Owner.Chat_operation.Turn_cancelled
        ; detail = "keeper owner closed before the queued chat claimed"
        ; outcome_ref = None
        }
    | Error error -> fail (Owner.error_to_string error)
  in
  let noop_execution_settled ~keeper_name:_ ~claimed_operation_id:_ ~operations:_ ~execution:_ = () in
  (match
     Owner_registry.install_from_store
       ~sw
       ~operation_runner:
         (Some
            Owner.
              { ready = (fun ~keeper_name:_ -> true)
              ; execute
              ; on_execution_settled = noop_execution_settled
              })
       ~on_turn_slot_released:(Some slot_released)
       (Workspace.default_config base_path)
   with
   | Ok _ -> ()
   | Error error -> fail (Owner_registry.install_error_to_string error));
  (match Owner_registry.create_meta ~base_path meta with
   | Ok _ -> ()
   | Error error -> fail (Owner_registry.command_error_to_string error));
  let owner =
    match Owner_registry.get ~base_path ~keeper_name with
    | Ok owner -> owner
    | Error error -> fail (Owner_registry.lookup_error_to_string error)
  in
  (match Owner_registry.begin_scheduled_turn_consumer ~base_path ~keeper_name with
   | Ok _ -> ()
   | Error error -> fail (Owner_registry.command_error_to_string error));
  enqueue_exn ~base_path keeper_name (scheduled_wake_stimulus ~occurrence:1 ~arrived_at:1.);
  let submit operation_id =
    match
      Owner.submit_operation owner ~operation_id
        ~source:(`Assoc [ "kind", `String "dashboard" ])
        ~input:(`Assoc [ "message", `String "answer this" ])
    with
    | Ok _ -> ()
    | Error error -> fail (Owner.error_to_string error)
  in
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () ->
    submit first_id;
    (match Eio.Promise.await alone with
     | Ok None -> ()
     | Ok (Some _) -> fail "the direct turn yielded to a schedule that is due"
     | Error detail -> fail detail);
    submit second_id;
    Eio.Promise.resolve resolve_second_queued ();
    (match Eio.Promise.await later with
     | Ok (Some {Keeper_agent_run.reason = Operation_queued}) -> ()
     | Ok (Some _) | Ok None -> fail "the direct turn ignored a chat admitted after it"
     | Error detail -> fail detail);
    List.iter (fun operation_id ->
      let rec await_settlement () =
        match Owner.exact_operation owner operation_id with
        | Error error -> fail (Owner.error_to_string error)
        | Ok None -> fail "a submitted chat disappeared"
        | Ok (Some operation) ->
          (match operation.state with
           | Owner.Chat_operation.Succeeded _ -> ()
           | Owner.Chat_operation.Queued | Owner.Chat_operation.Running _ ->
             Eio.Fiber.yield ();
             await_settlement ()
           | Owner.Chat_operation.Failed _ | Owner.Chat_operation.Cancelled _ ->
             fail "a submitted chat did not settle successfully")
      in
      await_settlement ())
      [ first_id; second_id ])
;;

let () =
  run
    "keeper_connector_attention_batch"
    [ ( "all-ready Event Queue intake"
      , [ test_case "scheduled checkpoint yields to successor then resumes exact work" `Quick
            test_scheduled_checkpoint_successor_and_resume
        ; test_case "scheduled continuation cancellation and reinsertion remain exact" `Quick
            test_scheduled_continuation_withdrawal_and_reinsertion
        ; test_case "backlog never interrupts proactive progress" `Quick
            test_backlog_never_interrupts_proactive_progress
        ; test_case "only new input of the right kind preempts a running turn" `Quick
            test_only_new_input_of_the_right_kind_preempts
        ; test_case "a tool receipt does not end a turn at its tool boundary" `Quick
            test_tool_receipt_does_not_end_a_turn_at_a_tool_boundary
        ; test_case "an unspent grant read at intake still stops the turn" `Quick
            test_unspent_grant_stops_a_turn_whose_intake_read_it
        ; test_case "an unreadable queue fails the probe" `Quick
            test_unreadable_queue_fails_the_probe
        ; test_case "a failed chat check fails the probe" `Quick
            test_failed_chat_check_fails_the_probe
        ; test_case "a due schedule does not preempt an autonomous turn" `Quick
            test_due_schedule_does_not_preempt_an_autonomous_turn
        ; test_case "a direct turn does not yield to a due schedule" `Quick
            test_direct_turn_does_not_yield_to_a_due_schedule
        ; test_case "new completions preempt after exact bounded intake frontier" `Quick
            test_running_source_observes_new_completion_after_intake
        ; test_case "reprioritized running source does not preempt itself" `Quick
            test_running_source_does_not_preempt_after_reprioritize
        ; test_case "deferred running source does not preempt itself" `Quick
            test_running_source_does_not_preempt_after_defer
        ; test_case "checkpoint yields preserve requests until exact settlement" `Quick
            test_checkpoint_retention_preserves_unsettled_sources
        ; test_case "new connector preempts and retains the entire old conversation in FIFO order" `Quick
            test_checkpoint_rotates_whole_connector_conversation_after_boundary
        ; test_case "stale connector member preserves FIFO and independent progress" `Quick
            test_stale_connector_member_preserves_fifo_and_independent_progress
        ; test_case "checkpoint retains original results and admits independent successors" `Quick
            test_checkpoint_preserves_results_and_services_successors
        ; test_case "stale checkpoint source preserves healthy sibling progress" `Quick
            test_checkpoint_stale_source_does_not_discard_healthy_sibling
        ; test_case "exact mixed bindings reach dispatch and settlement" `Quick
            test_exact_mixed_bindings_reach_dispatch_and_settlement
        ; test_case
            "scheduled work owns one occurrence, separate from attention"
            `Quick
            test_scheduled_work_is_not_batched_with_other_requests
        ; test_case
            "admits only one exact HITL resolution per turn"
            `Quick
            test_one_intake_admits_only_one_hitl_resolution
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
        ; test_case
            "an official turn keeps a settled tool until completion with chat queued"
            `Quick
            test_official_turn_keeps_tool_result_until_completion
        ] )
    ; ( "batch_disposition_of_cycle_outcome (P1-2)"
      , [ test_case
            "pins every branch of the pure disposition function"
            `Quick
            test_batch_disposition_of_cycle_outcome_pure_branches
        ; test_case
            "a completed turn without a reply receipt acks its connector attention"
            `Quick
            test_batch_disposition_acks_a_completed_turn_without_a_reply_receipt
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
