let discord channel_id =
  Keeper_continuation_channel.discord
    ~guild_id:(Some "guild-1")
    ~channel_id
    ~parent_channel_id:None
    ~thread_id:None
    ~user_id:"user-1"
    ()
  |> Result.get_ok
;;

let test_wake_origin_requires_exact_route_and_source () =
  let source_channel = discord "channel-1" in
  let payload : Keeper_event_queue.stimulus_payload =
    Connector_attention { event_id = "event-1"; channel = source_channel }
  in
  let matching =
    Masc.Keeper_unified_turn.continuation_delivery_origin_of_wake
      ~admitted_channel:(Some source_channel)
      (Masc.Keeper_registry.Woken [ payload ])
  in
  assert (Result.fold ~ok:Option.is_some ~error:(fun _ -> false) matching);
  let origin = Result.get_ok matching |> Option.get in
  let visible_intent =
    Masc.Keeper_agent_result.continuation_delivery_intent_for_result
      ~keeper_name:"keeper-one"
      ~keeper_turn_id:1
      ~origin:(Some origin)
      ~response_text:"final answer"
      ~turn_outcome:Masc.Keeper_turn_outcome.Visible_reply
  in
  assert (Result.fold ~ok:Option.is_some ~error:(fun _ -> false) visible_intent);
  let visible_intent = Result.get_ok visible_intent |> Option.get in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = "connector:event-1"
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = 1.0
    ; payload
    }
  in
  assert
    (Masc.Keeper_heartbeat_loop.source_requires_continuation_delivery
       [ stimulus ]);
  assert
    (Result.fold
       ~ok:Option.is_some
       ~error:(fun _ -> false)
       (Masc.Keeper_heartbeat_loop.continuation_delivery_origin_for_stimuli
          [ stimulus ]));
  assert
    (not
       (Masc.Keeper_heartbeat_loop.continuation_delivery_authorizes_source_ack
          ~source_requires:true
          Masc.Keeper_unified_turn.Continuation_delivery_not_required));
  assert
    (Masc.Keeper_heartbeat_loop.continuation_delivery_authorizes_source_ack
       ~source_requires:false
       Masc.Keeper_unified_turn.Continuation_delivery_not_required);
  assert
    (Masc.Keeper_heartbeat_loop.continuation_delivery_authorizes_source_ack
       ~source_requires:true
       Masc.Keeper_unified_turn.Continuation_delivery_settled_by_terminal_surface_post);
  assert
    (not
       (Masc.Keeper_heartbeat_loop.continuation_delivery_authorizes_source_ack
          ~source_requires:true
          (Masc.Keeper_unified_turn.Continuation_delivery_committed
             { intent_id = visible_intent.intent_id
             ; delivery_state = Masc.Keeper_unified_turn.Delivery_recovery_pending
             })));
  assert
    (Masc.Keeper_heartbeat_loop.continuation_source_disposition
       ~source_requires:true
       (Masc.Keeper_unified_turn.Continuation_delivery_committed
          { intent_id = visible_intent.intent_id
          ; delivery_state = Masc.Keeper_unified_turn.Delivery_recovery_pending
          })
     = Masc.Keeper_heartbeat_loop.Defer_continuation_source);
  assert
    (not
       (Masc.Keeper_heartbeat_loop.continuation_delivery_authorizes_source_ack
          ~source_requires:true
          (Masc.Keeper_unified_turn.Continuation_delivery_quarantined
             { detail = "outbox unavailable" })));
  assert
    (Masc.Keeper_agent_result.continuation_delivery_intent_for_result
       ~keeper_name:"keeper-one"
       ~keeper_turn_id:1
       ~origin:(Some origin)
       ~response_text:""
       ~turn_outcome:Masc.Keeper_turn_outcome.Continuation_checkpoint
     = Ok None);
  assert
    (Result.is_error
       (Masc.Keeper_unified_turn.continuation_delivery_origin_of_wake
          ~admitted_channel:(Some (discord "channel-2"))
          (Masc.Keeper_registry.Woken [ payload ])));
  assert
    (Result.is_error
       (Masc.Keeper_unified_turn.continuation_delivery_origin_of_wake
          ~admitted_channel:(Some source_channel)
          (Masc.Keeper_registry.Woken [ Keeper_event_queue.Bootstrap ])));
  assert
    (Result.is_error
       (Masc.Keeper_unified_turn.continuation_delivery_origin_of_wake
          ~admitted_channel:(Some source_channel)
          Masc.Keeper_registry.Proactive_tick));
  assert
    (Masc.Keeper_unified_turn.continuation_delivery_origin_of_wake
       ~admitted_channel:None
       Masc.Keeper_registry.Proactive_tick
     = Ok None)
  ;
  let unrouted_payload : Keeper_event_queue.stimulus_payload =
    Connector_attention
      { event_id = "event-unrouted"
      ; channel = Keeper_continuation_channel.unrouted "legacy"
      }
  in
  let unrouted_stimulus : Keeper_event_queue.stimulus =
    { post_id = "connector:event-unrouted"
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = 2.0
    ; payload = unrouted_payload
    }
  in
  assert
    (not
       (Masc.Keeper_heartbeat_loop.source_requires_continuation_delivery
          [ unrouted_stimulus ]));
  assert
    (Result.fold
       ~ok:Option.is_none
       ~error:(fun _ -> false)
       (Masc.Keeper_heartbeat_loop.continuation_delivery_origin_for_stimuli
          [ unrouted_stimulus ]));
  assert
    (Result.fold
       ~ok:Option.is_none
       ~error:(fun _ -> false)
       (Masc.Keeper_heartbeat_loop.continuation_delivery_origin_for_stimuli
          [ unrouted_stimulus; { unrouted_stimulus with post_id = "other" } ]));
  assert
    (Result.is_error
       (Masc.Keeper_heartbeat_loop.continuation_delivery_origin_for_stimuli
          [ stimulus; unrouted_stimulus ]))
;;

let test_schedule_delivery_requirement_is_persisted_policy () =
  let channel = discord "scheduled-channel" in
  let wake : Keeper_event_queue.scheduled_wake =
    { occurrence_id = "schedule-occurrence-1"
    ; schedule_instance_id = "schedule-instance-1"
    ; schedule_id = "schedule-1"
    ; due_at = 100.0
    ; payload_digest = "digest-1"
    ; title = None
    ; message = "run scheduled work"
    ; result_delivery = None
    }
  in
  let stimulus (wake : Keeper_event_queue.scheduled_wake) : Keeper_event_queue.stimulus =
    { post_id = wake.occurrence_id
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = 100.0
    ; payload = Keeper_event_queue.Schedule_due wake
    }
  in
  assert
    (not
       (Masc.Keeper_heartbeat_loop.source_requires_continuation_delivery
          [ stimulus wake ]));
  assert
    (Keeper_continuation_delivery_intent.origin_of_payload
       (Keeper_event_queue.Schedule_due wake)
     = Ok None);
  let routed = { wake with result_delivery = Some channel } in
  assert
    (Masc.Keeper_heartbeat_loop.source_requires_continuation_delivery
       [ stimulus routed ]);
  let origin =
    Keeper_continuation_delivery_intent.origin_of_payload
      (Keeper_event_queue.Schedule_due routed)
    |> Result.get_ok
    |> Option.get
  in
  assert
    (match origin.source with
     | Keeper_continuation_delivery_intent.Schedule_occurrence
         { occurrence_id } ->
       String.equal occurrence_id wake.occurrence_id
       && Keeper_continuation_channel.same_route channel origin.channel
     | Keeper_continuation_delivery_intent.Fusion_completion _
     | Keeper_continuation_delivery_intent.Hitl_resolution _
     | Keeper_continuation_delivery_intent.Connector_attention _ ->
       false)
;;

let () =
  test_wake_origin_requires_exact_route_and_source ();
  test_schedule_delivery_requirement_is_persisted_policy ();
  print_endline "keeper_continuation_delivery_origin: ok"
