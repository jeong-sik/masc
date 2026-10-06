(* test_keeper_connector_attention_wake.ml —
   RFC-connector-ambient-attention-wake P1.

   Pins the durable Connector event and wake-decision plumbing. Every accepted
   ambient event is queued by its producer identity before the wake hint; the
   event-queue trigger then yields a Run { Connector_attention_pending }
   reactive decision. *)

open Alcotest
module WO = Masc.Keeper_world_observation
module A = Masc.Keeper_external_attention
module Event_queue_persistence_source = Keeper_event_queue_persistence
module Keeper_event_queue_persistence = struct
  include Event_queue_persistence_source

  let load ~base_path ~keeper_name =
    match load_result ~base_path ~keeper_name with
    | Ok queue -> queue
    | Error detail -> fail detail
  ;;
end

(* The keeper.world event-row prose this suite asserts (the external
   attention title) moved out of the .ml sources into
   config/prompts/keeper.md as world.* keys, rendered through the prompt
   registry at observation time. This executable never pinned a markdown
   dir, so prompt resolution depended on whatever the host/dune context
   happened to expose — green on developer machines, bare-data fallbacks
   inside the CI dune sandbox. *)
let () =
  Masc.Prompt_defaults.init ()
;;

let contains ~needle haystack =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec loop i =
    i + nl <= hl
    && (String.equal (String.sub haystack i nl) needle || loop (i + 1))
  in
  nl = 0 || loop 0

(* keeper_cycle_decision resolves a runtime id unconditionally (RFC-0206 §2.1),
   so a minimal default runtime must exist — same setup the other cycle-decision
   unit tests use. *)
let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "connector_attention_runtime_" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc runtime_toml);
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e

let make_meta name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("trace_id", `String ("trace-conn-" ^ name))
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path

let discord_surface =
  A.Discord
    {
      guild_id = Some "guild-1";
      channel_id = "chan-1";
      channel_name = None;
      parent_channel_id = None;
      thread_id = None;
    }

let external_attention_item ?(urgency = A.Ambient) ?(preview = "ambient TOKEN-123")
    () : A.item =
  let dedupe_key = "discord:discord:guild-1:channel:chan-1:msg-1" in
  {
    A.event_id = A.event_id_of_dedupe_key dedupe_key;
    dedupe_key;
    keeper_name = "conn-keeper";
    conversation =
      {
        conversation_id = "discord:guild-1:channel:chan-1";
        surface = discord_surface;
      };
    external_message =
      Some
        {
          surface = discord_surface;
          message_id = "msg-1";
          reply_to_message_id = None;
        };
    source_label = "discord";
    actor =
      {
        actor_id = Some "user-1";
        display_name = Some "Alex";
        authority = Masc.Keeper_chat_store.External;
      };
    urgency;
    content_preview = preview;
    content_ref = None;
    received_at = 123.0;
    metadata = [ ("route", "ambient") ];
  }

(* Quiet observation: no mention / board / scope trigger and no task backlog, so
   the ONLY reactive trigger is the injected event-queue one. *)
let quiet_obs : WO.world_observation =
  { pending_messages = []
  ; pending_board_events = []
  ; idle_seconds = 0
  ; active_goals = Ok []
  ; unclaimed_task_count = 0
  ; claimable_tasks = []
  ; held_task_skills = []
  ; failed_task_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; approval_authority =
      { revision = 1; state = WO.Approval_authority_complete; pending = [] }
  ; backlog_revision = Some 1
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  ; connected_surface_failures = []
  ; own_recent_board_posts = []
  ; fleet_messages = []
  ; own_recent_actions = Ok []
  }

let reasons_of_verdict = function
  | WO.Run { reasons = first, rest } -> first :: rest
  | WO.Skip _ -> []

let decide ?(event_queue_triggers = []) () =
  WO.keeper_cycle_decision
    ~event_queue_triggers
    ~meta:(make_meta "conn-keeper")
    quiet_obs

let test_connector_attention_stimulus_drives_run () =
  let d = decide ~event_queue_triggers:[ WO.Connector_attention_stimulus ] () in
  check bool "connector attention stimulus drives a turn" true d.should_run;
  check bool "channel is Reactive" true (d.channel = WO.Reactive);
  check bool "verdict carries Connector_attention_pending" true
    (List.mem WO.Connector_attention_pending (reasons_of_verdict d.verdict))

(* Dormancy guard: with no stimulus and a quiet observation, the keeper does NOT
   reactively run on connector attention — the trigger is the only thing that
   introduces it. *)
let test_no_stimulus_no_connector_reason () =
  let d = decide () in
  check bool "no Connector_attention_pending without the stimulus" false
    (List.mem WO.Connector_attention_pending (reasons_of_verdict d.verdict))

(* The Connector_attention payload persists to / replays from the per-keeper
   event-queue snapshot, so its JSON codec must round-trip the event_id pointer. *)
let test_connector_attention_codec_roundtrips () =
  let module Q = Keeper_event_queue in
  let s =
    { Q.post_id = "evt-77"
    ; urgency = Q.Normal
    ; arrived_at = 1.0
    ; payload =
        Q.Connector_attention
          { event_id = "evt-77"
          ; channel =
              (Keeper_continuation_channel.discord
                 ~guild_id:(Some "guild-77")
                 ~channel_id:"chan-77"
                 ~parent_channel_id:(Some "parent-77")
                 ~thread_id:(Some "thread-77")
                 ~user_id:"user-77"
                 ()
               |> Result.get_ok)
          }
    }
  in
  match Q.stimulus_of_yojson (Q.stimulus_to_yojson s) with
  | Ok s' -> (
    match s'.Q.payload with
    | Q.Connector_attention { event_id; channel } ->
      check string "event_id survives the JSON round-trip" "evt-77" event_id;
      check bool "connector coordinates survive the JSON round-trip" true
        (Keeper_continuation_channel.same_route
           channel
           (Keeper_continuation_channel.discord
              ~guild_id:(Some "guild-77")
              ~channel_id:"chan-77"
              ~parent_channel_id:(Some "parent-77")
              ~thread_id:(Some "thread-77")
              ~user_id:"user-77"
              ()
            |> Result.get_ok))
    | _ -> check bool "round-trip payload stays Connector_attention" true false)
  | Error e -> check bool ("round-trip decode failed: " ^ e) true false

let connector_stimulus ~event_id ~arrived_at =
  let module Q = Keeper_event_queue in
  { Q.post_id = event_id
  ; urgency = Q.Low
  ; arrived_at
  ; payload =
      Q.Connector_attention
        { event_id
        ; channel =
            (Keeper_continuation_channel.discord
               ~guild_id:(Some "guild-durable")
               ~channel_id:"channel-durable"
               ~parent_channel_id:None
               ~thread_id:None
               ~user_id:"user-durable"
               ()
             |> Result.get_ok)
        }
  }

let test_distinct_connector_events_are_not_collapsed () =
  let base_path = Filename.temp_dir "connector-attention-durable" "" in
  let keeper_name = "connector-attention-durable-keeper" in
  let first = connector_stimulus ~event_id:"event-1" ~arrived_at:1.0 in
  let second = connector_stimulus ~event_id:"event-2" ~arrived_at:2.0 in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let enqueue expected stimulus =
        match
          Masc.Keeper_registry_event_queue.enqueue_stimulus_durable_result
            ~base_path
            keeper_name
            stimulus
        with
        | actual when actual = expected -> ()
        | Masc.Keeper_registry_event_queue.Stimulus_storage_error detail ->
          Alcotest.failf "durable Connector delivery failed: %s" detail
        | Masc.Keeper_registry_event_queue.Stimulus_enqueued
        | Masc.Keeper_registry_event_queue.Stimulus_already_present ->
          Alcotest.fail "unexpected durable Connector delivery result"
      in
      enqueue Masc.Keeper_registry_event_queue.Stimulus_enqueued first;
      enqueue Masc.Keeper_registry_event_queue.Stimulus_enqueued second;
      enqueue Masc.Keeper_registry_event_queue.Stimulus_already_present first;
      let event_ids =
        Keeper_event_queue_persistence.load ~base_path ~keeper_name
        |> Keeper_event_queue.to_list
        |> List.filter_map (fun (stimulus : Keeper_event_queue.stimulus) ->
          match stimulus.payload with
          | Keeper_event_queue.Connector_attention { event_id; _ } -> Some event_id
          | _ -> None)
        |> List.sort String.compare
      in
      check (list string) "each producer event has one durable row"
        [ "event-1"; "event-2" ] event_ids)

(* #41157: a retained Connector pointer whose attention row is unreadable
   was classified missing by the heartbeat intake but stayed pending, and
   the yield paths treated every pending Connector as actionable -- so the
   same unreadable pointer re-yielded at each tool boundary and the source
   never completed. The yield paths now drop pointers the attention store
   does not know, asking the same batched question the intake asks. A
   pointer whose row exists still preempts; a store that cannot be read
   keeps every pointer rather than silencing newly arrived readable
   messages. *)
let test_missing_connector_pointer_does_not_preempt () =
  let base_path = Filename.temp_dir "connector-attention-missing" "" in
  let keeper_name = "conn-keeper" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let item =
        { (external_attention_item ()) with
          A.event_id = "evt-present"
        ; keeper_name
        }
      in
      (match A.record ~base_path item with
      | `Recorded -> ()
      | `Duplicate _ -> Alcotest.fail "fixture attention row duplicated"
      | `Error detail -> Alcotest.failf "fixture attention row failed: %s" detail);
      let enqueue stimuli keeper =
        List.iter
          (fun stimulus ->
             match
               Masc.Keeper_registry_event_queue.enqueue_stimulus_durable_result
                 ~base_path keeper stimulus
             with
             | Masc.Keeper_registry_event_queue.Stimulus_enqueued -> ()
             | other ->
               Alcotest.failf "durable Connector delivery failed: %s"
                 (match other with
                  | Masc.Keeper_registry_event_queue.Stimulus_storage_error detail ->
                    detail
                  | _ -> "unexpected result"))
          stimuli
      in
      (* A keeper whose only pending pointer is unreadable: no preemption. *)
      enqueue [ connector_stimulus ~event_id:"evt-missing" ~arrived_at:1.0 ]
        "conn-missing-only";
      check bool
        "a missing pointer alone does not preempt the source"
        true
        (Option.is_none
           (Masc.Keeper_unified_turn.connector_attention_waiting
              ~base_path ~keeper_name:"conn-missing-only"
            |> Result.get_ok));
      (* The readable pointer's queue lives under the recorded row's keeper. *)
      enqueue
        [ connector_stimulus ~event_id:"evt-missing" ~arrived_at:1.0
        ; connector_stimulus ~event_id:"evt-present" ~arrived_at:2.0
        ]
        keeper_name;
      (match
         Masc.Keeper_unified_turn.connector_attention_waiting
           ~base_path ~keeper_name
         |> Result.get_ok
       with
      | Some
          { Masc.Keeper_agent_run.reason =
              Masc.Keeper_agent_run.Durable_stimulus_waiting summary } ->
        (match summary.head with
         | Some selected ->
           check string "the readable pointer preempts" "evt-present"
             selected.Keeper_event_queue.post_id
         | None -> Alcotest.fail "readable connector lost its preemption head")
      | Some { Masc.Keeper_agent_run.reason = Masc.Keeper_agent_run.Operation_queued } ->
        Alcotest.fail "connector preemption was mislabeled as chat"
      | None -> Alcotest.fail "readable connector did not preempt"));
;;

let record_attention ~base_path ~keeper_name event_id =
  (match Masc.Keeper_registry.get ~base_path keeper_name with
   | Some _ -> ()
   | None ->
     let meta = make_meta keeper_name in
     (match Masc.Keeper_owner_registry.create_meta ~base_path meta with
      | Ok _ -> ()
      | Error error -> fail (Masc.Keeper_owner_registry.command_error_to_string error));
     ignore (Masc.Keeper_registry.For_testing.register ~base_path keeper_name meta));
  let item = { (external_attention_item ()) with A.event_id; keeper_name } in
  match A.record ~base_path item with
  | `Recorded -> ()
  | `Duplicate _ -> fail "duplicate fixture attention"
  | `Error detail -> fail detail

let enqueue_attention ~base_path ~keeper_name event_id =
  match Masc.Keeper_registry_event_queue.enqueue_stimulus_durable_result
          ~base_path keeper_name (connector_stimulus ~event_id ~arrived_at:1.0) with
  | Masc.Keeper_registry_event_queue.Stimulus_enqueued -> ()
  | _ -> fail "fixture stimulus was not durably enqueued"

let probe_head probe =
  match probe () with
  | Error detail -> fail detail
  | Ok None -> None
  | Ok (Some { Masc.Keeper_agent_run.reason = Durable_stimulus_waiting summary }) ->
    Option.map (fun (s : Keeper_event_queue.stimulus) -> s.post_id) summary.head
  | Ok (Some { Masc.Keeper_agent_run.reason = Operation_queued }) ->
    fail "fixture has no Owner chat operation"

let pending_ids ~base_path ~keeper_name =
  Keeper_event_queue_persistence.load ~base_path ~keeper_name
  |> Keeper_event_queue.to_list
  |> List.map (fun (s : Keeper_event_queue.stimulus) -> s.post_id)
  |> List.sort String.compare

let with_attention_workspace f =
  let base_path = Filename.temp_dir "connector-turn-probe" "" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.all ~base_path ()
      |> List.iter (fun entry -> ignore (Masc.Keeper_registry.unregister_exact entry));
      rm_rf base_path)
    (fun () ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Eio.Switch.run (fun sw ->
          let config = Masc.Workspace.default_config base_path in
          (match Masc.Keeper_owner_registry.install_from_store ~sw
                   ~operation_runner:None ~on_turn_slot_released:None config with
           | Ok _ -> ()
           | Error error -> fail (Masc.Keeper_owner_registry.install_error_to_string error));
          f base_path)))

let test_late_enqueue_invalidates_subset wake () =
  with_attention_workspace (fun base_path ->
    let keeper_name = "late-enqueue" in
    (* Ingress has recorded the new body but has not enqueued its pointer. *)
    record_attention ~base_path ~keeper_name "present";
    enqueue_attention ~base_path ~keeper_name "missing";
    let probe, reads = Masc.Keeper_unified_turn.For_testing.autonomous_yield_probe
        ~wake ~base_path ~keeper_name in
    check (option string) "missing does not preempt" None (probe_head probe);
    check (option string) "unchanged negative result is reusable" None (probe_head probe);
    check int "one history scan" 1 (reads ());
    let path = A.attention_path ~base_path ~keeper_name in
    let before = Unix.stat path in
    enqueue_attention ~base_path ~keeper_name "present";
    let after = Unix.stat path in
    check bool "enqueue did not change attention version" true
      (before.st_ino = after.st_ino && before.st_mtime = after.st_mtime
       && before.st_ctime = after.st_ctime && before.st_size = after.st_size);
    check (option string) "new pointer to already recorded body preempts"
      (Some "present") (probe_head probe);
    check int "new queried set rescans" 2 (reads ());
    check (list string) "probe neither ACKs nor deletes either durable pointer"
      ["missing"; "present"] (pending_ids ~base_path ~keeper_name))

let test_interleaved_turn_caches () =
  with_attention_workspace (fun base_path ->
    let make keeper_name =
      record_attention ~base_path ~keeper_name "seed-not-queued";
      enqueue_attention ~base_path ~keeper_name "missing";
      Masc.Keeper_unified_turn.For_testing.autonomous_yield_probe
        ~wake:(Masc.Keeper_registry.Woken [Keeper_event_queue.Bootstrap])
        ~base_path ~keeper_name
    in
    let a, reads_a = make "keeper-a" in
    let b, reads_b = make "keeper-b" in
    List.iter (fun probe ->
      check (option string) "missing pointer stays non-preempting" None (probe_head probe))
      [a; b; a; b];
    check int "A retains its memo across B's probe" 1 (reads_a ());
    check int "B retains its memo across A's probe" 1 (reads_b ());
    record_attention ~base_path ~keeper_name:"keeper-a" "missing";
    check (option string) "restored body invalidates A's store version"
      (Some "missing") (probe_head a);
    check int "A rereads restored store" 2 (reads_a ());
    check (option string) "B remains unaffected" None (probe_head b);
    check int "B did not rescan" 1 (reads_b ());
    check (list string) "restoration probe does not ACK" ["missing"]
      (pending_ids ~base_path ~keeper_name:"keeper-a");
    let a_next, reads_next = Masc.Keeper_unified_turn.For_testing.autonomous_yield_probe
        ~wake:(Masc.Keeper_registry.Woken [Keeper_event_queue.Bootstrap])
        ~base_path ~keeper_name:"keeper-a" in
    check (option string) "next turn sees the same restored body"
      (Some "missing") (probe_head a_next);
    check int "next turn of A owns a fresh memo" 1 (reads_next ()))

let test_attention_read_failure_stays_open wake () =
  with_attention_workspace (fun base_path ->
    let keeper_name = "read-failure" in
    record_attention ~base_path ~keeper_name "seed-not-queued";
    enqueue_attention ~base_path ~keeper_name "missing";
    let probe, reads = Masc.Keeper_unified_turn.For_testing.autonomous_yield_probe
        ~wake ~base_path ~keeper_name in
    check (option string) "initial readable store excludes missing" None (probe_head probe);
    let path = A.attention_path ~base_path ~keeper_name in
    let size = (Unix.stat path).st_size in
    let oc = open_out_gen [Open_wronly; Open_append; Open_binary] 0o600 path in
    Fun.protect ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc "{torn");
    check (option string) "torn store fails open" (Some "missing") (probe_head probe);
    check (option string) "read error is not cached" (Some "missing") (probe_head probe);
    check int "each failed read remains retryable" 3 (reads ());
    Unix.truncate path size;
    check (option string) "repaired readable store excludes missing again"
      None (probe_head probe);
    check int "recovery performs a fresh read" 4 (reads ());
    check (list string) "read failure leaves durable pointer pending" ["missing"]
      (pending_ids ~base_path ~keeper_name))

let test_external_attention_projects_to_prompt_event () =
  let meta = make_meta "conn-keeper" in
  let item = external_attention_item () in
  let ev = WO.pending_board_event_of_external_attention ~meta item in
  check string "post id carries event id"
    ("connector-attention:" ^ item.A.event_id)
    ev.WO.post_id;
  check bool "title carries typed surface" true
    (contains ~needle:"External discord attention" ev.WO.title);
  check bool "preview carries connector message" true
    (contains ~needle:"TOKEN-123" ev.WO.preview);
  check bool "ambient is not an explicit mention" false ev.WO.explicit_mention;
  check string "connector actor remains context" "Alex" ev.WO.author;
  check bool "post kind remains context" true
    (ev.WO.post_kind = Masc.Board.Human_post);
  let prompt_fields = Masc.Keeper_unified_prompt.For_testing.board_event_fields ev in
  check string "world prompt carries typed workspace" "guild-1"
    (List.assoc "external_workspace_id" prompt_fields);
  check string "world prompt carries typed actor" "user-1"
    (List.assoc "external_user_id" prompt_fields);
  check string "world prompt keeps external authority" "external"
    (List.assoc "external_authority" prompt_fields);
  (match ev.WO.event_kind with
   | WO.External_attention observation ->
     check string "typed connector channel survives" "discord" observation.channel;
     check (option string) "typed workspace survives" (Some "guild-1")
       observation.workspace_id;
     check (option string) "typed actor id survives" (Some "user-1")
       observation.user_id;
     check (option string) "typed display name survives" (Some "Alex")
       observation.user_name;
     check string "typed content survives the world projection"
       item.A.content_preview observation.content
   | WO.Board_post_created
   | WO.Board_post_updated
   | WO.Board_comment_added _
   | WO.Board_reaction_changed _
   | WO.Board_vote_cast _
   | WO.Fusion_completed
   | WO.Schedule_due _
   | WO.Completion_authority_rejected _
   | WO.Task_outcome _
   | WO.Task_cancelled _
   | WO.Delegate_completed
   | WO.Ask_answered_row _
   | WO.Composition_completed ->
     fail "connector attention must retain its typed counterpart projection")

let () =
  init_runtime_default_for_tests ();
  run "connector_attention_wake"
    [ ( "decision",
        [ test_case "stimulus drives Run { Connector_attention_pending }" `Quick
            test_connector_attention_stimulus_drives_run
        ; test_case "dormant without the stimulus" `Quick
            test_no_stimulus_no_connector_reason
        ] )
    ; ( "codec",
        [ test_case "Connector_attention payload JSON round-trips" `Quick
            test_connector_attention_codec_roundtrips
        ; test_case "distinct events are durable without channel debounce" `Quick
            test_distinct_connector_events_are_not_collapsed
        ; test_case "missing pointer does not preempt; readable still does"
            `Quick test_missing_connector_pointer_does_not_preempt
        ] )
    ; ( "source-turn cache",
        [ test_case "late enqueue during proactive turn" `Quick
            (test_late_enqueue_invalidates_subset Masc.Keeper_registry.Proactive_tick)
        ; test_case "late enqueue during selected-source turn" `Quick
            (test_late_enqueue_invalidates_subset
               (Masc.Keeper_registry.Woken [Keeper_event_queue.Bootstrap]))
        ; test_case "interleaved Keepers retain independent caches" `Quick
            test_interleaved_turn_caches
        ; test_case "proactive read failure and recovery" `Quick
            (test_attention_read_failure_stays_open Masc.Keeper_registry.Proactive_tick)
        ; test_case "selected-source read failure and recovery" `Quick
            (test_attention_read_failure_stays_open
               (Masc.Keeper_registry.Woken [Keeper_event_queue.Bootstrap]))
        ] )
    ; ( "projection",
        [ test_case "external attention becomes prompt event" `Quick
            test_external_attention_projects_to_prompt_event
        ] )
    ]
