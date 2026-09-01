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

let deterministic_route ~detail =
  Keeper_runtime_failure_route.Exhausted_visible_alive
    { terminal = Keeper_runtime_failure_route.Deterministic_request
    ; provenance = Keeper_runtime_failure_route.Agent_core_api_error
    ; detail
    }
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

let hitl_resolution_stimulus ~approval_id ~arrived_at : Q.stimulus =
  let resolution : Q.hitl_resolution =
    { approval_id
    ; decision = Q.Hitl_approved
    ; channel = Keeper_continuation_channel.unrouted "test"
    }
  in
  { Q.post_id = Q.hitl_resolution_post_id resolution
  ; urgency = Q.Immediate
  ; arrived_at
  ; payload = Q.Hitl_resolved resolution
  }
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
       | Q.Task_cancelled _ | Q.Workspace_message _
       | Q.Delegate_completed _ | Q.Composition_completed _ -> None)
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
  Board_dispatch.init_jsonl ();
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

let test_one_intake_admits_every_ready_non_connector_in_queue_order () =
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
    check int "all nine ready sources are admitted in one turn" 9
      intake.consumed_stimulus_count;
    check
      (list string)
      "admission preserves durable urgency then arrival order"
      (List.map (fun (source : Q.stimulus) -> source.post_id) sources)
      (List.map (fun (source : Q.stimulus) -> source.post_id) intake.consumed_stimuli);
    check int "five Board and three Schedule observations reach the turn" 8
      (List.length intake.pending_board_events);
    check int "intake alone never ACKs actionable sources" 9
      (Keeper_registry_event_queue.snapshot_result ~base_path keeper_name
       |> Result.map Q.length
       |> Result.value ~default:(-1)))
;;

let test_one_intake_admits_only_one_hitl_resolution () =
  with_ctx "hitl-exact-replay-batch" (fun ~base_path ~keeper_name ~meta ~ctx ->
    let first =
      hitl_resolution_stimulus ~approval_id:"appr-first" ~arrived_at:1.0
    in
    let second =
      hitl_resolution_stimulus ~approval_id:"appr-second" ~arrived_at:2.0
    in
    List.iter (enqueue_exn ~base_path keeper_name) [ first; second ];
    let intake =
      Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
        ~ctx
        ~meta_after_triage:meta
        ~pending_board_events:[]
    in
    check int "one turn owns one exact HITL grant" 1 intake.consumed_stimulus_count;
    check
      (list string)
      "the oldest ready approval is the only admitted source"
      [ first.post_id ]
      (List.map (fun (source : Q.stimulus) -> source.post_id) intake.consumed_stimuli);
    check int "turn completion can ACK only that exact approval" 1
      (List.length intake.consumed_selections);
    (match intake.consumed_selections with
     | [ selection ] ->
       (match
          Keeper_registry_event_queue.terminalize_pending_turn_completed_result
            ~base_path
            keeper_name
            ~applied_at:1000.0
            ~selection
        with
        | Ok _ -> ()
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
      (List.map (fun (source : Q.stimulus) -> source.post_id) next.consumed_stimuli))
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
       { connector_attention_outcome = Keeper_heartbeat_loop.Attention_resolved }
     -> ()
   | _ ->
     fail "Completed + addressed route must drive Batch_ack_completed/Attention_resolved");
  (match
     Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
       (Some
          (completed_outcome
             ~route:Keeper_unified_turn.Continuation_memory_write_completed
             meta))
   with
   | Keeper_heartbeat_loop.Batch_ack_completed
       { connector_attention_outcome = Keeper_heartbeat_loop.Attention_ignored }
     -> ()
   | _ ->
     fail
       "Completed + memory-write receipt must drive Batch_ack_completed/Attention_ignored");
  (match
     Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
       (Some
          (Keeper_heartbeat_loop_cycle.Checkpointed
             { meta
             ; checkpoint_reason = Keeper_unified_turn.Durable_stimulus_arrived
             ; continuation_route = Keeper_unified_turn.Continuation_route_addressed
             }))
   with
   | Keeper_heartbeat_loop.Batch_ack_durable_stimulus_yield -> ()
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
           ~route:(deterministic_route ~detail:"deterministic rejection")
           ~deferred_runtime_lane:None
           meta)
    ; Some
        (Keeper_heartbeat_loop_cycle.Checkpointed
           { meta
           ; checkpoint_reason = Keeper_unified_turn.Awaiting_external_effect
           ; continuation_route =
               Keeper_unified_turn.Continuation_no_terminal_effect_receipt
           })
    ; Some (Keeper_heartbeat_loop_cycle.Input_required meta)
    ; Some (Keeper_heartbeat_loop_cycle.Cancelled meta)
    ; Some (Keeper_heartbeat_loop_cycle.Skipped meta)
    ]
;;

(* #32096: mismatch and missing/inapplicable receipt evidence say nothing
   about model intent. They must NOT be recorded as Ignored. *)
let test_batch_disposition_keeps_unsettled_evidence_pending () =
  let meta = test_meta "batch-disposition-pending" in
  List.iter
    (fun route ->
       match
         Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
           (Some (completed_outcome ~route meta))
       with
       | Keeper_heartbeat_loop.Batch_no_action -> ()
       | Keeper_heartbeat_loop.Batch_ack_completed _
       | Keeper_heartbeat_loop.Batch_ack_durable_stimulus_yield ->
         fail
           "unsettled route evidence must not ACK (no judgement was made)")
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
      intake.consumed_stimulus_count;
    check
      (list string)
      "consumed_stimuli are exactly channel A's, in arrival order"
      [ a1.Q.post_id; a2.Q.post_id; a3.Q.post_id ]
      (List.map (fun (s : Q.stimulus) -> s.Q.post_id) intake.consumed_stimuli);
    check int "consumed_selections mirrors the same batch" 3
      (List.length intake.consumed_selections);
    check
      (list string)
      "consumed_selections carries channel A's sources, in arrival order"
      [ a1.Q.post_id; a2.Q.post_id; a3.Q.post_id ]
      (List.map
         (fun (s : Keeper_event_queue_state.pending_selection) -> s.source.Q.post_id)
         intake.consumed_selections);
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
      2 intake.consumed_stimulus_count;
    check
      (list string)
      "batch is exactly the two connector entries, in arrival order"
      [ a1.Q.post_id; a2.Q.post_id ]
      (List.map (fun (s : Q.stimulus) -> s.Q.post_id) intake.consumed_stimuli);
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
    check int "all 3 admitted as one batch" 3 intake.consumed_stimulus_count;
    check int "consumed_selections mirrors the batch" 3
      (List.length intake.consumed_selections);
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
     | Keeper_heartbeat_loop.Batch_ack_completed _
     | Keeper_heartbeat_loop.Batch_ack_durable_stimulus_yield ->
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

(* RFC-0377: the completion counterpart to the failure test above — batch
   admitted, then the turn completes. This is genuinely new coverage: no
   prior test in this suite exercised the completion-ack path at all.
   Drives the same real [batch_disposition_of_cycle_outcome] function,
   then applies its [Batch_ack_completed] action to every
   [consumed_selections] member the way [remove_completed_selections]
   does (List.for_all over terminalize_completed_selection), proving a
   turn completion acks the WHOLE admitted batch, not only the primary. *)
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
    check int "all 3 admitted as one batch" 3 intake.consumed_stimulus_count;
    check int "consumed_selections mirrors the batch" 3
      (List.length intake.consumed_selections);
    (match
       Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome
         (Some (completed_outcome ~route:Keeper_unified_turn.Continuation_route_addressed meta))
     with
     | Keeper_heartbeat_loop.Batch_ack_completed _ ->
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
              | Ok _ -> true
              | Error detail ->
                failf "ack failed for %s: %s" selection.source.Q.post_id detail)
           intake.consumed_selections
       in
       check bool "every batch member acks cleanly" true acked
     | Keeper_heartbeat_loop.Batch_ack_durable_stimulus_yield ->
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

(* The queue entry and the external-attention row are separate writes. Only a
   completed turn terminalizes the entry, so only completed dispositions may
   settle the attention row. *)
let test_every_terminalizing_disposition_settles_its_attention_rows () =
  (match
     Keeper_heartbeat_loop.connector_attention_settlement_of_disposition
       (Keeper_heartbeat_loop.Batch_ack_completed
          { connector_attention_outcome = Keeper_heartbeat_loop.Attention_resolved })
   with
   | Keeper_heartbeat_loop.Settle_resolved -> ()
   | _ -> fail "a completed addressed turn must settle as Settle_resolved");
  (match
     Keeper_heartbeat_loop.connector_attention_settlement_of_disposition
       (Keeper_heartbeat_loop.Batch_ack_completed
          { connector_attention_outcome = Keeper_heartbeat_loop.Attention_ignored })
   with
   | Keeper_heartbeat_loop.Settle_ignored -> ()
   | _ -> fail "a completed unaddressed turn must settle as Settle_ignored");
  (match
     Keeper_heartbeat_loop.connector_attention_settlement_of_disposition
       Keeper_heartbeat_loop.Batch_no_action
   with
   | Keeper_heartbeat_loop.Settle_pending_in_queue -> ()
   | _ -> fail "an unfinished turn must not settle a still-pending row");
  (match
     Keeper_heartbeat_loop.connector_attention_settlement_of_disposition
       Keeper_heartbeat_loop.Batch_ack_durable_stimulus_yield
   with
   | Keeper_heartbeat_loop.Settle_pending_in_queue -> ()
   | _ -> fail "a checkpoint yield must not settle connector attention")
;;

let () =
  run
    "keeper_connector_attention_batch"
    [ ( "all-ready Event Queue intake"
      , [ test_case
            "admits all ready Board, Schedule, and Bootstrap sources in one turn"
            `Quick
            test_one_intake_admits_every_ready_non_connector_in_queue_order
        ; test_case
            "admits only one exact HITL resolution per turn"
            `Quick
            test_one_intake_admits_only_one_hitl_resolution
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
        ; test_case
            "unsettled route evidence stays pending, never Ignored"
            `Quick
            test_batch_disposition_keeps_unsettled_evidence_pending
        ; test_case
            "every terminalizing disposition settles its attention rows"
            `Quick
            test_every_terminalizing_disposition_settles_its_attention_rows
        ] )
    ]
;;
