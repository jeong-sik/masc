(* test_keeper_connector_attention_batch.ml — RFC-0377: conversation-batched
   stimulus intake.

   sangsu live data (2026-08-08..08-13) showed every delivered continuation
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
         ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
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

let discord_surface ~channel_id =
  A.Discord
    { guild_id = Some "guild-batch"
    ; channel_id
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
   contiguous prefix. *)
let board_distractor_stimulus ~post_id ~arrived_at : Q.stimulus =
  { Q.post_id
  ; urgency = Q.Normal
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

let connector_event_ids_of_queue queue =
  Q.to_list queue
  |> List.filter_map (fun (s : Q.stimulus) ->
       match s.Q.payload with
       | Q.Connector_attention { event_id; _ } -> Some event_id
       | Q.Board_signal _ | Q.Board_attention _ | Q.Bootstrap
       | Q.Fusion_completed _ | Q.Schedule_due _ | Q.Hitl_resolved _
       | Q.Manual_compaction_requested | Q.Goal_assigned _
       | Q.Goal_reconciliation_ready _ | Q.Completion_authority_rejected _
       | Q.Task_cancelled _ -> None)
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
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.clear ())
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

(* RFC-0377 S3: "Non-Connector_attention payloads keep single-stimulus
   behavior." A board signal sitting between two same-conversation
   Connector_attention entries must not be admitted into the batch and must
   not block the batch filter from finding the connector entry behind it. *)
let test_batch_skips_a_non_connector_entry_between_matches () =
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
    check int "the board distractor is still durably queued, never consumed" 3
      (Q.length queued);
    check bool "the board distractor's own identity is unchanged" true
      (List.exists
         (fun (s : Q.stimulus) -> String.equal s.Q.post_id "board-distractor")
         (Q.to_list queued)))
;;

(* RFC-0377 S5.2: batch admitted, then the turn fails. The disposition
   [keeper_heartbeat_loop.ml] applies on a transient turn failure
   ([Defer_to_queue_tail]) must run over every entry in
   [consumed_selections], not only the primary, or a companion is silently
   stranded — acked by nobody, deferred by nobody, yet also never retried
   because it no longer looks "new". This pins: applying that exact
   disposition to the whole batch loses nothing (no partial ack) and every
   member is independently re-selectable afterward. *)
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
    (* Simulate the [Defer_to_queue_tail] failure disposition
       [keeper_heartbeat_loop.ml] now applies to every [consumed_selections]
       member on a transient turn failure (RFC-0377): nothing is acked,
       every member is deferred to the tail of its urgency lane. *)
    List.iter
      (fun (selection : Keeper_event_queue_state.pending_selection) ->
         match
           Keeper_registry_event_queue.defer_pending_result
             ~base_path
             keeper_name
             ~selection
         with
         | Ok _ -> ()
         | Error detail ->
           failf "defer failed for %s: %s" selection.source.Q.post_id detail)
      intake.consumed_selections;
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

let () =
  run
    "keeper_connector_attention_batch"
    [ ( "RFC-0377 conversation-batched intake"
      , [ test_case
            "admits a channel's whole backlog in arrival order, leaves other \
             channels queued"
            `Quick
            test_batch_admits_same_conversation_in_arrival_order_leaves_other_channel_queued
        ; test_case
            "skips a non-connector entry sitting between two matches"
            `Quick
            test_batch_skips_a_non_connector_entry_between_matches
        ; test_case
            "turn failure defers the whole batch: no partial ack"
            `Quick
            test_batch_turn_failure_leaves_every_member_queued
        ] )
    ]
;;
