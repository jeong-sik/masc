open Alcotest
open Masc

module Broadcast_wakeup = Server_bootstrap_loops.For_testing

let test_mention_wakes_target () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action (Some "beta") with
  | `Wake_keeper "beta" -> ()
  | `Wake_keeper other -> failf "unexpected wake target: %s" other
  | `Suppress_no_target -> fail "expected explicit mention to wake target"

let test_none_is_passive () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action None with
  | `Suppress_no_target -> ()
  | `Wake_keeper target -> failf "unexpected no-target wake: %s" target

let test_blank_is_passive () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action (Some "  ") with
  | `Suppress_no_target -> ()
  | `Wake_keeper target -> failf "unexpected blank-target wake: %s" target

let make_meta name =
  match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]) with
  | Ok meta -> meta
  | Error detail -> failf "keeper meta fixture failed: %s" detail
;;

let delivery ~target ~request_id ~seq ~content : Workspace_broadcast.broadcast_delivery =
  { request_id
  ; seq
  ; rendered = content
  ; from_agent = "external-agent"
  ; content
  ; mention = Some target
  ; msg_type = "broadcast"
  ; mention_delivery = Workspace_broadcast.Pending
  ; audience = Workspace_broadcast.Fleet_conversation
  }
;;

let with_workspace f =
  let root = Filename.temp_file "broadcast-wakeup-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      Unix.rmdir root)
    (fun () -> f config)
;;

let persist_meta config name =
  match Keeper_meta_store.replace_snapshot config (make_meta name) with
  | Ok () -> ()
  | Error detail -> failf "keeper meta persistence failed: %s" detail
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)
;;

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let configure_mention_targets config name mention_targets =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  mkdir_p keepers_dir;
  let path = Filename.concat keepers_dir (name ^ ".toml") in
  let rendered_targets =
    mention_targets
    |> List.map (Printf.sprintf "%S")
    |> String.concat ", "
  in
  write_file
    path
    (Printf.sprintf
       "[keeper]\ninstructions = \"You are a focused test Keeper.\"\nsandbox_profile = \"local\"\nmention_targets = [%s]\n"
       rendered_targets)
;;

let check_effective_mention_targets config name expected =
  match Keeper_meta_store.read_effective_meta config name with
  | Error detail -> failf "effective metadata read failed: %s" detail
  | Ok None -> fail "effective metadata disappeared"
  | Ok (Some meta) ->
    check
      (list string)
      "effective mention targets"
      expected
      meta.Keeper_meta_contract.mention_targets
;;

let count_delivery_rows ~base_path ~keeper_name ~request_id =
  Keeper_chat_store.load_all ~base_dir:base_path ~keeper_name
  |> List.filter (fun (message : Keeper_chat_store.chat_message) ->
    message.external_message_id = Some request_id)
  |> List.length
;;

let test_delivery_appends_once_before_wake () =
  with_workspace @@ fun config ->
  let target = "beta" in
  let request_id = "wmsg-0011223344556677" in
  persist_meta config target;
  let wakes = ref 0 in
  let delivery = delivery ~target ~request_id ~seq:1 ~content:"review this" in
  let deliver () =
    Broadcast_wakeup.deliver_broadcast_mention
      ~config
      ~base_path:config.base_path
      ~is_running:(fun _ -> true)
      ~wakeup:(fun _ -> incr wakes)
      delivery
  in
  (match deliver () with
   | Workspace_broadcast.Accepted -> ()
   | _ -> fail "committed delivery did not wake the running keeper");
  (match deliver () with
   | Workspace_broadcast.Already_accepted -> ()
   | _ -> fail "idempotent replay did not preserve wake eligibility");
  check int "one accepted-user row" 1
    (count_delivery_rows ~base_path:config.base_path ~keeper_name:target ~request_id);
  check int "wake only follows successful append outcomes" 2 !wakes
;;

let test_stopped_keeper_persists_without_wake () =
  with_workspace @@ fun config ->
  let target = "stopped-keeper" in
  let request_id = "wmsg-8899aabbccddeeff" in
  persist_meta config target;
  let wakes = ref 0 in
  let outcome =
    Broadcast_wakeup.deliver_broadcast_mention
      ~config
      ~base_path:config.base_path
      ~is_running:(fun _ -> false)
      ~wakeup:(fun _ -> incr wakes)
      (delivery ~target ~request_id ~seq:2 ~content:"persist while stopped")
  in
  (match outcome with
   | Workspace_broadcast.Accepted -> ()
   | _ -> fail "stopped Keeper delivery was not durably deferred");
  check int "stopped delivery persisted" 1
    (count_delivery_rows ~base_path:config.base_path ~keeper_name:target ~request_id);
  check int "stopped Keeper not woken" 0 !wakes
;;

let delivery_message ~base_path ~keeper_name ~request_id =
  Keeper_chat_store.load_all ~base_dir:base_path ~keeper_name
  |> List.find_opt (fun (message : Keeper_chat_store.chat_message) ->
    message.external_message_id = Some request_id)
;;

let test_configured_mention_alias_resolves_and_stamps_feed_target () =
  with_workspace @@ fun config ->
  let keeper_name = "beta" in
  let configured_alias = "Alpha" in
  let delivery_target = "alpha" in
  let request_id = "wmsg-1122334455667788" in
  persist_meta config keeper_name;
  configure_mention_targets config keeper_name [ configured_alias ];
  check_effective_mention_targets config keeper_name [ configured_alias ];
  let outcome =
    Broadcast_wakeup.deliver_broadcast_mention
      ~config
      ~base_path:config.base_path
      ~is_running:(String.equal keeper_name)
      ~wakeup:(fun _ -> ())
      (delivery
         ~target:delivery_target
         ~request_id
         ~seq:4
         ~content:"alias delivery")
  in
  (match outcome with
   | Workspace_broadcast.Accepted -> ()
   | _ -> fail "configured mention alias did not resolve");
  match delivery_message ~base_path:config.base_path ~keeper_name ~request_id with
  | None -> fail "configured alias delivery was not persisted"
  | Some message ->
    let mentions =
      List.map Keeper_identity.Keeper_id.to_string message.mentions
    in
    check bool "persisted row carries configured feed target" true
      (List.mem delivery_target mentions)
;;

let test_canonical_delivery_stamps_configured_feed_target () =
  with_workspace @@ fun config ->
  let keeper_name = "beta" in
  let alias = "alpha" in
  let request_id = "wmsg-8877665544332211" in
  persist_meta config keeper_name;
  configure_mention_targets config keeper_name [ alias ];
  check_effective_mention_targets config keeper_name [ alias ];
  ignore
    (Broadcast_wakeup.deliver_broadcast_mention
       ~config
       ~base_path:config.base_path
       ~is_running:(fun _ -> false)
       ~wakeup:(fun _ -> ())
       (delivery ~target:keeper_name ~request_id ~seq:5 ~content:"canonical delivery"));
  match delivery_message ~base_path:config.base_path ~keeper_name ~request_id with
  | None -> fail "canonical delivery was not persisted"
  | Some message ->
    let mentions =
      List.map Keeper_identity.Keeper_id.to_string message.mentions
    in
    check bool "canonical row carries configured feed target" true
      (List.mem alias mentions)
;;

let queued_workspace_messages ~base_path ~keeper_name =
  match Keeper_event_queue_persistence.load_result ~base_path ~keeper_name with
  | Error detail -> failf "event queue load failed: %s" detail
  | Ok queue ->
    Keeper_event_queue.to_list queue
    |> List.filter_map (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Keeper_event_queue.Workspace_message message ->
        Some (stimulus.post_id, stimulus.urgency, message)
      | Keeper_event_queue.Board_signal _
      | Keeper_event_queue.Board_attention _
      | Keeper_event_queue.Bootstrap
      | Keeper_event_queue.Fusion_completed _
      | Keeper_event_queue.Schedule_due _
      | Keeper_event_queue.Connector_attention _
      | Keeper_event_queue.Hitl_resolved _
      | Keeper_event_queue.Ask_answered _
      | Keeper_event_queue.Completion_authority_rejected _
      | Keeper_event_queue.Task_cancelled _
      | Keeper_event_queue.Delegate_completed _
      | Keeper_event_queue.Composition_completed _ -> None)
;;

(* A workspace message that names a Keeper has to reach the same linear drain
   every other stimulus arrives on. Before this, the delivery boundary wrote a
   transcript row and flipped a wake flag, so the message existed for the
   transcript scan and for nothing else: it had no queue identity, no ordering
   against other stimuli, and nothing for the operator queue view to show. *)
let test_delivery_enqueues_linear_queue_entry () =
  with_workspace @@ fun config ->
  let target = "beta" in
  let request_id = "wmsg-1234567890abcdef" in
  persist_meta config target;
  let deliver () =
    Broadcast_wakeup.deliver_broadcast_mention
      ~config
      ~base_path:config.base_path
      ~is_running:(fun _ -> true)
      ~wakeup:(fun _ -> ())
      (delivery ~target ~request_id ~seq:6 ~content:"drain me")
  in
  ignore (deliver ());
  (match queued_workspace_messages ~base_path:config.base_path ~keeper_name:target with
   | [ (post_id, urgency, message) ] ->
     check string "queue entry keys on the workspace request"
       ("workspace-message:" ^ request_id) post_id;
     check bool "an addressed message is immediate" true
       (urgency = Keeper_event_queue.Immediate);
     check string "queue entry names its sender" "external-agent"
       message.Keeper_event_queue.wmsg_from
   | entries ->
     failf "expected one queued keeper message, got %d" (List.length entries));
  (* Redelivery of the same committed message is the same durable event. *)
  ignore (deliver ());
  check int "redelivery does not duplicate the queue entry" 1
    (List.length
       (queued_workspace_messages ~base_path:config.base_path ~keeper_name:target))
;;

(* The wake is a hint; the delivery is durable. A Keeper that is not running
   when the message commits still finds it in its queue on the next cycle. *)
let test_stopped_keeper_keeps_queue_entry () =
  with_workspace @@ fun config ->
  let target = "stopped-drain-keeper" in
  let request_id = "wmsg-fedcba0987654321" in
  persist_meta config target;
  ignore
    (Broadcast_wakeup.deliver_broadcast_mention
       ~config
       ~base_path:config.base_path
       ~is_running:(fun _ -> false)
       ~wakeup:(fun _ -> fail "a stopped Keeper must not be woken")
       (delivery ~target ~request_id ~seq:7 ~content:"queued while stopped"));
  check int "stopped Keeper still holds the queue entry" 1
    (List.length
       (queued_workspace_messages ~base_path:config.base_path ~keeper_name:target))
;;

let fleet_delivery ~request_id ~from_agent ~content
  : Workspace_broadcast.broadcast_delivery
  =
  { request_id
  ; seq = 40
  ; rendered = content
  ; from_agent
  ; content
  ; mention = None
  ; msg_type = "broadcast"
  ; mention_delivery = Workspace_broadcast.Passive
  ; audience = Workspace_broadcast.Fleet_conversation
  }
;;

(* A Keeper broadcast reached no other Keeper's conversation window: without a
   mention the delivery was passive SSE plus a workspace row, and the chat
   scan's Scope lane admits only Owner-authored lines, so an External Keeper
   line could not arrive that way either. On the reference workspace 17 of 18
   retained messages were exactly this shape. *)
let test_fleet_projection_reaches_other_keepers () =
  with_workspace @@ fun config ->
  let request_id = "wmsg-00fleet0000000001" in
  List.iter (persist_meta config) [ "beta"; "alpha"; "fixture-keeper" ];
  Broadcast_wakeup.project_workspace_message_to_fleet
    ~base_path:config.base_path
    ~registered_keepers:(fun () ->
       [ "beta", "beta"; "alpha", "alpha"; "fixture-keeper", "fixture-keeper" ])
    (fleet_delivery
       ~request_id
       ~from_agent:("beta")
       ~content:"task-209 is mine, do not claim it");
  let rows keeper_name =
    count_delivery_rows ~base_path:config.base_path ~keeper_name ~request_id
  in
  check int "listener sees the broadcast" 1 (rows "alpha");
  check int "second listener sees the broadcast" 1 (rows "fixture-keeper");
  (* The author already knows what it said; echoing it back would put the
     Keeper's own speech in front of it as someone else's line. *)
  check int "author does not receive its own broadcast" 0 (rows "beta")
;;

(* Visibility, not a request: the fanout must not put an entry in anyone's
   linear drain, or one status announcement opens a turn on every Keeper. *)
let test_fleet_projection_adds_no_queue_entry () =
  with_workspace @@ fun config ->
  let request_id = "wmsg-00fleet0000000002" in
  List.iter (persist_meta config) [ "beta"; "alpha" ];
  Broadcast_wakeup.project_workspace_message_to_fleet
    ~base_path:config.base_path
    ~registered_keepers:(fun () ->
       [ "beta", "beta"; "alpha", "alpha" ])
    (fleet_delivery
       ~request_id
       ~from_agent:("beta")
       ~content:"status ping");
  check int "listener row is visibility only" 1
    (count_delivery_rows ~base_path:config.base_path ~keeper_name:"alpha" ~request_id);
  check int "no queue entry for a fleet broadcast" 0
    (List.length
       (queued_workspace_messages ~base_path:config.base_path ~keeper_name:"alpha"))
;;

(* The named target's row is written by the mention path with its mention ids.
   The fanout runs afterwards over the same delivery key, so it must find that
   row already present and leave the stamp — not overwrite it with an
   unmentioned copy or append a second row. *)
let test_fleet_projection_preserves_the_mention_row () =
  with_workspace @@ fun config ->
  let target = "alpha" in
  let request_id = "wmsg-00fleet0000000003" in
  List.iter (persist_meta config) [ "beta"; target ];
  ignore
    (Broadcast_wakeup.deliver_broadcast_mention
       ~config
       ~base_path:config.base_path
       ~is_running:(fun _ -> true)
       ~wakeup:(fun _ -> ())
       (delivery ~target ~request_id ~seq:41 ~content:"@alpha please review"));
  Broadcast_wakeup.project_workspace_message_to_fleet
    ~base_path:config.base_path
    ~registered_keepers:(fun () ->
       [ "beta", "beta"
       ; target, target
       ])
    (fleet_delivery
       ~request_id
       ~from_agent:"external-agent"
       ~content:"@alpha please review");
  check int "target keeps exactly one row" 1
    (count_delivery_rows ~base_path:config.base_path ~keeper_name:target ~request_id);
  (* Without this the case passes with no fanout at all: both assertions above
     read only the row the mention path already wrote. *)
  check int "the bystander received the fanout row" 1
    (count_delivery_rows ~base_path:config.base_path ~keeper_name:"beta" ~request_id);
  match delivery_message ~base_path:config.base_path ~keeper_name:target ~request_id with
  | None -> fail "mention row disappeared after the fleet pass"
  | Some message ->
    check bool "mention stamp survived the fleet pass" true (message.mentions <> [])
;;

(* The task FSM announces every claim/start/release through the same
   broadcast entry point. Those are a record of what the system did, not
   conversation, and projecting them would cost one full transcript
   read-and-scan per registered Keeper for 17 of every 18 messages. A
   producer that declares no audience gets none of that. *)
let test_system_record_is_not_projected () =
  with_workspace @@ fun config ->
  let request_id = "wmsg-00fleet0000000004" in
  List.iter (persist_meta config) [ "beta"; "alpha" ];
  let record =
    { (fleet_delivery
         ~request_id
         ~from_agent:("beta")
         ~content:"Claimed task-209")
      with Workspace_broadcast.audience = Workspace_broadcast.System_record
    }
  in
  Broadcast_wakeup.project_workspace_message_to_fleet
    ~base_path:config.base_path
    ~registered_keepers:(fun () ->
       [ "beta", "beta"; "alpha", "alpha" ])
    record;
  check int "a system record reaches no conversation window" 0
    (count_delivery_rows ~base_path:config.base_path ~keeper_name:"alpha" ~request_id)
;;

(* The default is the record, so a producer added later cannot silently fan a
   machine announcement out to every Keeper. *)
let test_undeclared_broadcast_is_a_system_record () =
  with_workspace @@ fun config ->
  match
    Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Claimed task-1"
  with
  | Error _ -> fail "broadcast was not persisted"
  | Ok delivery ->
    check bool "an undeclared producer is a system record" true
      (delivery.Workspace_broadcast.audience = Workspace_broadcast.System_record)
;;

(* Author exclusion has to compare the identities the registry holds. Minting a
   [Keeper_id] does not round-trip a name of three or more hyphenated parts:
   with the minted comparison this case fails on the second assertion —
   `Expected: 0 / Received: 1` — because the author is not recognised and gets
   its own speech back. Both names exist in the reference workspace. *)
let test_hyphenated_names_do_not_collide_on_the_author () =
  with_workspace @@ fun config ->
  let author = "adm-race-cf-000" in
  let listener = "adm-race-sf-000" in
  let request_id = "wmsg-00fleet0000000005" in
  List.iter (persist_meta config) [ author; listener ];
  Broadcast_wakeup.project_workspace_message_to_fleet
    ~base_path:config.base_path
    ~registered_keepers:(fun () ->
      [ author, author
      ; listener, listener
      ])
    (fleet_delivery
       ~request_id
       ~from_agent:(author)
       ~content:"a name-shaped collision must not eat this");
  check int "the listener is not mistaken for the author" 1
    (count_delivery_rows ~base_path:config.base_path ~keeper_name:listener ~request_id);
  check int "the author still gets nothing back" 0
    (count_delivery_rows ~base_path:config.base_path ~keeper_name:author ~request_id)
;;

(* The projection writes under the delivery key the mention path uses, and the
   chat store is first-write-wins on it. An outcome that left the mention path
   still owing a stamped row must hold the projection back, or the unstamped
   copy claims the key and the retry can never stamp it. Exhaustive on the
   closed sum so a new outcome has to state its answer. *)
let test_projection_waits_for_the_mention_transcript () =
  let settled = Broadcast_wakeup.mention_transcript_settled in
  check bool "no mention: no row is owed" true
    (settled Workspace_broadcast.Passive);
  check bool "accepted: the stamped row is committed" true
    (settled Workspace_broadcast.Accepted);
  check bool "already accepted: the stamped row is committed" true
    (settled Workspace_broadcast.Already_accepted);
  check bool "pending: a stamped row is still owed" false
    (settled Workspace_broadcast.Pending);
  check bool "deferred: the retry still owes a stamped row" false
    (settled
       (Workspace_broadcast.Deferred Workspace_broadcast.Target_state_unavailable));
  check bool "rejected: the transcript is not the projection's to claim" false
    (settled (Workspace_broadcast.Rejected Workspace_broadcast.Invalid_target))
;;

let test_workspace_message_mutation_invalidates_workspace_and_health () =
  with_workspace @@ fun config ->
  let workspace_projection = ref 0 in
  let dashboard_projection = ref 0 in
  let unrelated_projection = ref 0 in
  let full_health_invalidations = ref 0 in
  let read key counter =
    Dashboard_cache.get_or_compute key ~ttl:120.0 (fun () ->
      incr counter;
      `Int !counter)
  in
  let dashboard_key =
    Printf.sprintf "dashboard.workspace:%s;probe" config.Workspace.base_path
  in
  let workspace_key = Printf.sprintf "workspace:%s:probe" config.base_path in
  ignore (read dashboard_key dashboard_projection);
  ignore (read workspace_key workspace_projection);
  ignore (read "unrelated:message-mutation" unrelated_projection);
  let previous = Atomic.get Workspace_hooks.on_workspace_message_mutation_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.on_workspace_message_mutation_fn previous;
      Dashboard_cache.invalidate_all ())
    (fun () ->
      Broadcast_wakeup.install_workspace_message_mutation_invalidation
        ~invalidate_full_health_snapshot:(fun () ->
          incr full_health_invalidations)
        ();
      (Atomic.get Workspace_hooks.on_workspace_message_mutation_fn)
        config
        ~request_id:"wmsg-00health00000001"
        ~mention_delivery:Masc_domain.Mention_accepted;
      ignore (read dashboard_key dashboard_projection);
      ignore (read workspace_key workspace_projection);
      ignore (read "unrelated:message-mutation" unrelated_projection);
      check int "dashboard workspace projection recomputed" 2 !dashboard_projection;
      check int "workspace projection recomputed" 2 !workspace_projection;
      check int "unrelated projection preserved" 1 !unrelated_projection;
      check int "full health invalidated once" 1 !full_health_invalidations)
;;

let () =
  run
    "broadcast_wakeup_policy"
    [
      ( "mention_policy"
      , [
          test_case "explicit mention wakes target" `Quick test_mention_wakes_target
        ; test_case "no mention is passive" `Quick test_none_is_passive
        ; test_case "blank mention is passive" `Quick test_blank_is_passive
        ; test_case "delivery appends once before wake" `Quick
            test_delivery_appends_once_before_wake
        ; test_case "stopped Keeper persists without wake" `Quick
            test_stopped_keeper_persists_without_wake
        ; test_case "configured mention alias resolves and stamps feed target" `Quick
            test_configured_mention_alias_resolves_and_stamps_feed_target
        ; test_case "canonical delivery stamps configured feed target" `Quick
            test_canonical_delivery_stamps_configured_feed_target
        ; test_case "delivery enqueues a linear queue entry" `Quick
            test_delivery_enqueues_linear_queue_entry
        ; test_case "stopped Keeper keeps the queue entry" `Quick
            test_stopped_keeper_keeps_queue_entry
        ] )
    ; ( "fleet_projection"
      , [
          test_case "broadcast reaches other Keepers' windows" `Quick
            test_fleet_projection_reaches_other_keepers
        ; test_case "fleet projection adds no queue entry" `Quick
            test_fleet_projection_adds_no_queue_entry
        ; test_case "fleet projection preserves the mention row" `Quick
            test_fleet_projection_preserves_the_mention_row
        ; test_case "a system record is not projected" `Quick
            test_system_record_is_not_projected
        ; test_case "an undeclared broadcast is a system record" `Quick
            test_undeclared_broadcast_is_a_system_record
        ; test_case "hyphenated names do not collide on the author" `Quick
            test_hyphenated_names_do_not_collide_on_the_author
        ; test_case "projection waits for the mention transcript" `Quick
            test_projection_waits_for_the_mention_transcript
        ; test_case "message mutation invalidates workspace and health" `Quick
            test_workspace_message_mutation_invalidates_workspace_and_health
        ] )
    ]
