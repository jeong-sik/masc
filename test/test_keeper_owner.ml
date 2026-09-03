open Alcotest
open Masc

module Reducer = Keeper_owner_reducer
module Owner = Keeper_owner
module Owner_registry = Keeper_owner_registry
module Chat_operation = Owner.Chat_operation

let json = testable Yojson.Safe.pretty_print Yojson.Safe.equal

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
;;

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "keeper_owner_runtime_" ".toml" in
  let channel = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel runtime_toml);
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error detail -> failf "Runtime.init_default failed: %s" detail
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String ("trace-" ^ name)
        ; "autoboot_enabled", `Bool false
        ])
  with
  | Ok meta -> meta
  | Error detail -> fail ("meta fixture failed: " ^ detail)
;;

let usage_delta ?(turns = 1) () : Reducer.usage_delta =
  { turns
  ; input_tokens = 2
  ; output_tokens = 3
  ; total_tokens = 5
  ; cost_usd = 0.25
  ; last_turn_ts = 42.0
  ; last_input_tokens = 2
  ; last_output_tokens = 3
  ; last_total_tokens = 5
  ; last_usage_reported_at = Some 42.0
  ; last_latency_ms = 7
  }
;;

let reducer_ok = function
  | Ok transition -> transition.Reducer.state
  | Error error -> fail (Reducer.error_to_string error)
;;

let owner_ok = function
  | Ok value -> value
  | Error error -> fail (Owner.error_to_string error)
;;

let noop_execution_settled ~keeper_name:_ ~claimed_operation_id:_ ~execution:_ =
  ()
;;

let start_owner_with_executor_ready
      ?(on_execution_settled = noop_execution_settled)
      ~operation_ready
      ~sw
      ~store
      ~operation_executor
      ~keeper_name
      ~initial_meta
      ()
  =
  let path = Filename.temp_file "keeper-owner-operations-" ".sqlite3" in
  Unix.unlink path;
  Eio.Switch.on_release sw (fun () ->
    if Sys.file_exists path then Unix.unlink path);
  Owner.start
    ~sw
    ~store
    ~operation_store_path:path
    ~now:(fun () -> 42.0)
    ~operation_runner:
      (Option.map
         (fun execute ->
            Owner.{ ready = operation_ready; execute; on_execution_settled })
         operation_executor)
    ~on_turn_slot_released:None
    ~keeper_name
    ~initial_meta
;;

let start_owner_with_executor
      ?on_execution_settled
      ~sw
      ~store
      ~operation_executor
      ~keeper_name
      ~initial_meta
      ()
  =
  start_owner_with_executor_ready
    ?on_execution_settled
    ~operation_ready:(fun ~keeper_name:_ -> true)
    ~sw
    ~store
    ~operation_executor
    ~keeper_name
    ~initial_meta
    ()
;;

let start_owner ~sw ~store ~keeper_name ~initial_meta =
  start_owner_with_executor
    ~sw
    ~store
    ~operation_executor:None
    ~keeper_name
    ~initial_meta
    ()
;;

let operation_id value =
  match Chat_operation.Operation_id.of_string value with
  | Ok operation_id -> operation_id
  | Error detail -> fail detail
;;

let operation_source = `Assoc [ "kind", `String "dashboard" ]
let operation_input text = `Assoc [ "message", `String text ]

let with_state_change_observer observer f =
  Owner.install_state_change_observer observer;
  Fun.protect
    ~finally:(fun () -> Owner.install_state_change_observer ignore)
    f
;;

let test_operation_payload_preserves_connector_route () =
  let continuation =
    match
      Keeper_continuation_channel.discord
        ~guild_id:(Some "guild-1")
        ~channel_id:"thread-7"
        ~parent_channel_id:(Some "channel-3")
        ~thread_id:(Some "thread-7")
        ~user_id:"user-9"
        ()
    with
    | Ok continuation -> continuation
    | Error detail -> fail detail
  in
  let surface =
    Surface_ref.Discord
      { guild_id = Some "guild-1"
      ; channel_id = "thread-7"
      ; channel_name = None
      ; parent_channel_id = Some "channel-3"
      ; thread_id = Some "thread-7"
      }
  in
  let encoded =
    match
      Keeper_chat_operation_payload.source_to_json
        ~submitted_by:"gate:discord:guild-1:user-9"
        ~thread_id:"keeper:route"
        ~continuation_channel:continuation
        ~surface
        ~channel:"discord"
        ~channel_user_id:"user-9"
        ~channel_user_name:"User"
        ~channel_workspace_id:"guild-1"
        ~conversation_id:(Some "discord:guild-1:channel:thread-7")
        ~external_message_id:(Some "message-1")
        ~workspace_id:(Some "guild-1")
        ~extra_mentions:[]
        ~user_row_origin:Keeper_chat_store.Needs_append
    with
    | Ok encoded -> encoded
    | Error detail -> fail detail
  in
  let decoded =
    match Keeper_chat_operation_payload.source_of_json encoded with
    | Ok decoded -> decoded
    | Error detail -> fail detail
  in
  check bool "surface round-trips exactly" true (Surface_ref.equal surface decoded.surface);
  check string "speaker round-trips" "user-9" decoded.channel_user_id;
  let mismatched =
    match encoded with
    | `Assoc fields ->
      `Assoc
        (("channel_workspace_id", `String "wrong-guild")
         :: List.remove_assoc "channel_workspace_id" fields)
    | _ -> fail "source encoder returned a non-object"
  in
  check bool
    "mismatched route is rejected"
    true
    (Result.is_error (Keeper_chat_operation_payload.source_of_json mismatched));
  let unknown =
    match encoded with
    | `Assoc fields -> `Assoc (("obsolete_identity", `String "old-id") :: fields)
    | _ -> fail "source encoder returned a non-object"
  in
  check bool
    "unknown field is rejected"
    true
    (Result.is_error (Keeper_chat_operation_payload.source_of_json unknown))
;;

let rec await_terminal owner operation_id remaining =
  if remaining = 0
  then fail "operation did not become terminal"
  else
    match owner_ok (Owner.exact_operation owner operation_id) with
    | Some operation when Chat_operation.is_terminal operation.state -> operation
    | Some _ | None ->
      Eio.Fiber.yield ();
      await_terminal owner operation_id (remaining - 1)
;;

let test_pure_reducer_adds_deltas_and_preserves_pause () =
  let state =
    ref
      (match Reducer.create ~keeper_name:"pure" (Some (make_meta "pure")) with
       | Ok state -> state
       | Error error -> fail (Reducer.error_to_string error))
  in
  for index = 1 to 1_000 do
    state := reducer_ok (Reducer.apply_meta !state (Add_usage (usage_delta ())));
    if index = 500
    then
      state :=
        reducer_ok
          (Reducer.apply_meta
             !state
             (Pause
                { reason =
                    Keeper_latched_reason.Operator_paused
                      { operator_actor = Keeper_latched_reason.Grpc_directive }
                ; updated_at = "paused-at-500"
                }))
  done;
  let projection = Reducer.projection !state in
  let meta = Option.get projection.meta in
  check int "all turn deltas retained" 1_000 meta.runtime.usage.total_turns;
  check int "all input deltas retained" 2_000 meta.runtime.usage.total_input_tokens;
  check int "all output deltas retained" 3_000 meta.runtime.usage.total_output_tokens;
  check int "all total deltas retained" 5_000 meta.runtime.usage.total_tokens;
  check (float 0.000_001) "all cost deltas retained" 250.0 meta.runtime.usage.total_cost_usd;
  check bool "pause bit retained" true meta.paused;
  check bool "pause latch retained" true (Option.is_some meta.latched_reason)
;;

let test_profile_update_preserves_owner_runtime_state () =
  let original = make_meta "profile" in
  let state =
    match Reducer.create ~keeper_name:original.name (Some original) with
    | Ok state -> reducer_ok (Reducer.apply_meta state (Add_usage (usage_delta ())))
    | Error error -> fail (Reducer.error_to_string error)
  in
  let current = Option.get (Reducer.projection state).meta in
  let update : Reducer.profile_update =
    { instructions = "updated instructions"
    ; sandbox_profile = current.sandbox_profile
    ; sandbox_image = current.sandbox_image
    ; network_mode = current.network_mode
    ; mention_targets = [ "profile-target" ]
    ; proactive_enabled = true
    ; max_context_override = Some 32_000
    ; autoboot_enabled = true
    ; telemetry_feedback_enabled = Some true
    ; telemetry_feedback_window_hours = Some 24
    ; always_allow = Some false
    ; agent_core_env = [ "PROFILE_TEST", "1" ]
    ; updated_at = "profile-updated"
    }
  in
  let state = reducer_ok (Reducer.apply_meta state (Update_profile update)) in
  let committed = Option.get (Reducer.projection state).meta in
  check string "profile instructions updated" update.instructions committed.instructions;
  check int
    "profile update preserves additive turns"
    current.runtime.usage.total_turns
    committed.runtime.usage.total_turns;
  check bool "profile update changes autoboot" true committed.autoboot_enabled
;;

let test_actor_concurrent_commands_are_exact () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    owner_ok
      (start_owner
      ~sw
      ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
      ~keeper_name:"concurrent"
      ~initial_meta:(Some (make_meta "concurrent")))
  in
  let commands =
    List.init 1_000 (fun _ () ->
      ignore (owner_ok (Owner.apply_meta owner (Add_usage (usage_delta ())))))
  in
  let pause () =
    ignore
      (owner_ok
         (Owner.apply_meta
            owner
            (Pause
               { reason =
                   Keeper_latched_reason.Operator_paused
                     { operator_actor = Keeper_latched_reason.Keeper_down }
               ; updated_at = "concurrent-pause"
               })))
  in
  Eio.Fiber.all (pause :: commands);
  let projection = owner_ok (Owner.exact_projection owner) in
  let meta = Option.get projection.meta in
  check int "concurrent deltas are exact" 1_000 meta.runtime.usage.total_turns;
  check bool "concurrent pause is preserved" true meta.paused
;;

let test_mailbox_backpressures_without_drop () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let replace_entered, resolve_replace_entered = Eio.Promise.create () in
  let release_replace, resolve_release_replace = Eio.Promise.create () in
  let first_replace = Atomic.make true in
  let store =
    { Owner.replace =
        (fun _ ->
           if Atomic.compare_and_set first_replace true false
           then (
             Eio.Promise.resolve resolve_replace_entered ();
             Eio.Promise.await release_replace);
           Ok ())
    ; remove = (fun _ -> Ok ())
    }
  in
  let owner =
    owner_ok
      (start_owner
         ~sw
         ~store
         ~keeper_name:"mailbox"
         ~initial_meta:(Some (make_meta "mailbox")))
  in
  let completed = Atomic.make 0 in
  let all_completed, resolve_all_completed = Eio.Promise.create () in
  let mark_completed () =
    if Atomic.fetch_and_add completed 1 = 129
    then Eio.Promise.resolve resolve_all_completed ()
  in
  let submit index () =
    ignore
      (owner_ok
         (Owner.apply_meta
            owner
            (Set_autoboot
               { enabled = index mod 2 = 0
               ; updated_at = string_of_int index
               })));
    mark_completed ()
  in
  Eio.Fiber.fork ~sw (submit 0);
  Eio.Promise.await replace_entered;
  for index = 1 to 129 do
    Eio.Fiber.fork ~sw (submit index)
  done;
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  check int
    "bounded mailbox reaches its exact capacity"
    Owner.mailbox_capacity
    (Owner.For_testing.mailbox_depth owner);
  check int "no blocked command was dropped" 0 (Atomic.get completed);
  Eio.Promise.resolve resolve_release_replace ();
  Eio.Promise.await all_completed;
  check int "all producers completed after capacity released" 130 (Atomic.get completed);
  check int "mailbox drained" 0 (Owner.For_testing.mailbox_depth owner)
;;

let test_enqueued_request_settles_before_cancellation_unwinds () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let replace_entered, resolve_replace_entered = Eio.Promise.create () in
  let release_replace, resolve_release_replace = Eio.Promise.create () in
  let cancel_context, resolve_cancel_context = Eio.Promise.create () in
  let caller_done, resolve_caller_done = Eio.Promise.create () in
  let caller_unwound = Atomic.make false in
  let owner =
    owner_ok
      (start_owner
         ~sw
         ~store:
           { replace =
               (fun _ ->
                  Eio.Promise.resolve resolve_replace_entered ();
                  Eio.Promise.await release_replace;
                  Ok ())
           ; remove = (fun _ -> Ok ())
           }
         ~keeper_name:"cancel-after-enqueue"
         ~initial_meta:(Some (make_meta "cancel-after-enqueue")))
  in
  Eio.Fiber.fork ~sw (fun () ->
    (try
       Eio.Cancel.sub (fun context ->
         Eio.Promise.resolve resolve_cancel_context context;
         ignore
           (Owner.apply_meta
              owner
              (Set_autoboot { enabled = true; updated_at = "committed" })))
     with
     | Eio.Cancel.Cancelled _ -> Atomic.set caller_unwound true);
    Eio.Promise.resolve resolve_caller_done ());
  let context = Eio.Promise.await cancel_context in
  Eio.Promise.await replace_entered;
  Eio.Cancel.cancel context (Failure "cancel after owner enqueue");
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  check bool "caller remains inside committed request" false (Atomic.get caller_unwound);
  Eio.Promise.resolve resolve_release_replace ();
  Eio.Promise.await caller_done;
  check bool "protected request returns after settlement" false (Atomic.get caller_unwound);
  check
    bool
    "enqueued mutation committed before authority scope unwound"
    true
    (Option.get (Owner.projection owner).meta).autoboot_enabled
;;

let test_store_failure_fences_mutations () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    owner_ok
      (start_owner
      ~sw
      ~store:
        { replace = (fun _ -> Error "disk unavailable")
        ; remove = (fun _ -> Error "disk unavailable")
        }
      ~keeper_name:"store-failure"
      ~initial_meta:(Some (make_meta "store-failure")))
  in
  (match
     Owner.apply_meta
       owner
       (Set_autoboot { enabled = true; updated_at = "must-not-publish" })
   with
   | Error (Owner.Store_unavailable "disk unavailable") -> ()
   | Error error -> fail ("wrong store error: " ^ Owner.error_to_string error)
   | Ok _ -> fail "store failure was reported as success");
  check bool
    "failed persistence leaves projection unchanged"
    false
    (Option.get (Owner.projection owner).meta).autoboot_enabled;
  (match
     Owner.apply_meta
       owner
       (Set_autoboot { enabled = true; updated_at = "must-remain-fenced" })
   with
   | Error (Owner.Store_unavailable "disk unavailable") -> ()
   | Error error -> fail ("wrong fenced store error: " ^ Owner.error_to_string error)
   | Ok _ -> fail "store-fenced owner accepted another mutation");
  match Owner.exact_projection owner with
  | Ok projection ->
    check bool
      "store fence keeps exact projection readable"
      false
      (Option.get projection.meta).autoboot_enabled
  | Error error -> fail ("store fence blocked exact projection: " ^ Owner.error_to_string error)
;;

let test_visible_post_publish_failure_is_not_durable_success () =
  let write_error : Keeper_fs.durable_write_error =
    { renamed = true
    ; stage = Parent_directory_fsync_after_rename
    ; failure = Operation_failed "injected parent directory fsync failure"
    }
  in
  (match
     Keeper_meta_store.For_testing.settle_durable_replace
       "/owned/keeper.json"
       (Error write_error)
   with
   | Error _ -> ()
   | Ok () -> fail "visible rename was mistaken for a durable metadata commit");
  let remove_error : Keeper_fs.durable_remove_error =
    { removed = true
    ; failure = Parent_directory_fsync, "injected parent directory fsync failure"
    }
  in
  match
    Keeper_meta_store.For_testing.settle_durable_remove
      "/owned/keeper.json"
      (Error remove_error)
  with
  | Error _ -> ()
  | Ok () -> fail "visible unlink was mistaken for a durable metadata removal"
;;

let test_identity_and_delete_guards () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let store = { Owner.replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) } in
  let empty =
    owner_ok (start_owner ~sw ~store ~keeper_name:"empty" ~initial_meta:None)
  in
  (match Owner.apply_meta empty (Create (make_meta "other")) with
   | Error (Owner.Reducer_rejected (Reducer.Keeper_identity_mismatch _)) -> ()
  | Error error -> fail ("wrong identity error: " ^ Owner.error_to_string error)
  | Ok _ -> fail "owner accepted metadata for another Keeper");
  ignore (owner_ok (Owner.apply_meta empty (Create (make_meta "empty"))));
  let stale_digest =
    Keeper_meta_json.Snapshot_digest.of_meta (Option.get (Owner.projection empty).meta)
  in
  ignore
    (owner_ok
       (Owner.apply_meta
          empty
          (Set_autoboot { enabled = true; updated_at = "changed-before-delete" })));
  (match Owner.apply_meta empty (Delete_if_snapshot stale_digest) with
   | Error (Owner.Reducer_rejected Reducer.Snapshot_changed) -> ()
   | Error error -> fail ("wrong stale delete error: " ^ Owner.error_to_string error)
   | Ok _ -> fail "stale snapshot authority deleted newer metadata");
  let expected_digest =
    Keeper_meta_json.Snapshot_digest.of_meta (Option.get (Owner.projection empty).meta)
  in
  ignore (owner_ok (Owner.apply_meta empty (Delete_if_snapshot expected_digest)));
  check bool "delete clears metadata" true (Option.is_none (Owner.projection empty).meta)
;;

let test_shutdown_releases_full_mailbox_requests () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun test_sw ->
  let owner_ready, resolve_owner_ready = Eio.Promise.create () in
  let close_owner_scope, resolve_close_owner_scope = Eio.Promise.create () in
  let owner_scope_done, resolve_owner_scope_done = Eio.Promise.create () in
  let replace_entered, resolve_replace_entered = Eio.Promise.create () in
  let never_release, _resolve_never_release = Eio.Promise.create () in
  Eio.Fiber.fork ~sw:test_sw (fun () ->
    Eio.Switch.run (fun owner_sw ->
      let owner =
        owner_ok
          (start_owner
             ~sw:owner_sw
             ~store:
               { replace =
                   (fun _ ->
                      Eio.Promise.resolve resolve_replace_entered ();
                      Eio.Promise.await never_release;
                      Ok ())
               ; remove = (fun _ -> Ok ())
               }
             ~keeper_name:"shutdown-race"
             ~initial_meta:(Some (make_meta "shutdown-race")))
      in
      Eio.Promise.resolve resolve_owner_ready owner;
      Eio.Promise.await close_owner_scope);
    Eio.Promise.resolve resolve_owner_scope_done ());
  let owner = Eio.Promise.await owner_ready in
  let results = Eio.Stream.create max_int in
  let submit index () =
    let result =
      Owner.apply_meta
        owner
        (Set_autoboot { enabled = true; updated_at = string_of_int index })
    in
    Eio.Stream.add results result
  in
  Eio.Fiber.fork ~sw:test_sw (submit 0);
  Eio.Promise.await replace_entered;
  for index = 1 to 129 do
    Eio.Fiber.fork ~sw:test_sw (submit index)
  done;
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  check int
    "mailbox is full before shutdown"
    Owner.mailbox_capacity
    (Owner.For_testing.mailbox_depth owner);
  Eio.Promise.resolve resolve_close_owner_scope ();
  for _ = 1 to 130 do
    match Eio.Stream.take results with
    | Error Owner.Owner_closed -> ()
    | Error error -> fail ("wrong shutdown error: " ^ Owner.error_to_string error)
    | Ok _ -> fail "shutdown race reported an uncommitted command as successful"
  done;
  Eio.Promise.await owner_scope_done
;;

let test_stopping_rejects_new_commands () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    owner_ok
      (start_owner
      ~sw
      ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
      ~keeper_name:"stopping"
      ~initial_meta:(Some (make_meta "stopping")))
  in
  ignore (owner_ok (Owner.begin_stopping owner));
  (match
     Owner.apply_meta
       owner
       (Set_autoboot { enabled = true; updated_at = "rejected" })
   with
   | Error (Owner.Reducer_rejected Reducer.Owner_stopping) -> ()
   | Error error -> fail ("wrong stopping error: " ^ Owner.error_to_string error)
   | Ok _ -> fail "stopping owner accepted metadata mutation");
  match
    Owner.submit_operation
      owner
      ~operation_id:(operation_id "kmsg-stopping")
      ~source:operation_source
      ~input:(operation_input "rejected")
  with
  | Error Owner.Owner_stopping -> ()
  | Error error -> fail ("wrong operation stopping error: " ^ Owner.error_to_string error)
  | Ok _ -> fail "stopping owner accepted a chat operation"
;;

let test_stopping_cancels_and_joins_active_child () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let child_started, resolve_child_started = Eio.Promise.create () in
  let child_released, resolve_child_released = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  let settled = ref None in
  let record_settled ~keeper_name ~claimed_operation_id ~execution =
    settled := Some (keeper_name, claimed_operation_id, execution)
  in
  let operation_executor ~sw:child_sw ~keeper_name:_ ~claim =
    match claim () with
    | Error error -> fail (Owner.error_to_string error)
    | Ok None -> fail "active-child test did not claim its operation"
    | Ok (Some _) ->
      Eio.Switch.on_release child_sw (fun () ->
        Eio.Promise.resolve resolve_child_released ());
      Eio.Promise.resolve resolve_child_started ();
      Eio.Promise.await never;
      fail "stopped child resumed after its cancellation point"
  in
  let owner =
    owner_ok
      (start_owner_with_executor
         ~on_execution_settled:record_settled
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some operation_executor)
         ~keeper_name:"stopping-active-child"
         ~initial_meta:(Some (make_meta "stopping-active-child"))
         ())
  in
  let operation_id = operation_id "kmsg-stopping-active-child" in
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id
          ~source:operation_source
          ~input:(operation_input "cancel me")));
  Eio.Promise.await child_started;
  ignore (owner_ok (Owner.begin_stopping owner));
  Eio.Promise.await child_released;
  let operation = Option.get (owner_ok (Owner.exact_operation owner operation_id)) in
  (match operation.state with
   | Chat_operation.Failed { failure = { kind; _ }; _ } ->
     check string
       "stopped active child is terminal"
       "Turn_cancelled"
       (Chat_operation.failure_kind_to_string kind)
   | state ->
     fail
       ("stopping returned before terminal persistence: "
        ^ Chat_operation.state_to_string state));
  match !settled with
  | Some (settled_keeper, Some claimed_id, Owner.Operation_failed { kind; detail; _ })
    ->
    check string "settle hook keeper" "stopping-active-child" settled_keeper;
    check
      string
      "settle hook operation id"
      (Chat_operation.Operation_id.to_string operation_id)
      (Chat_operation.Operation_id.to_string claimed_id);
    check
      string
      "settle hook failure kind"
      "Turn_cancelled"
      (Chat_operation.failure_kind_to_string kind);
    check
      string
      "settle hook detail"
      "Keeper owner stopped the active turn"
      detail
  | Some (_, None, _) -> fail "settle hook fired without a claimed operation id"
  | Some (_, _, Owner.Operation_succeeded _) -> fail "cancelled turn settled as success"
  | None -> fail "settle hook did not fire before stop completed"
;;

let test_stopping_cancels_and_joins_autonomous_child () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let child_started, resolve_child_started = Eio.Promise.create () in
  let caller_result = Eio.Stream.create 1 in
  let never, _resolve_never = Eio.Promise.create () in
  let owner =
    owner_ok
      (start_owner
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~keeper_name:"stopping-autonomous-child"
         ~initial_meta:(Some (make_meta "stopping-autonomous-child")))
  in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      Owner.run_autonomous_if_idle owner (fun () ->
        Eio.Promise.resolve resolve_child_started ();
        Eio.Promise.await never)
    in
    Eio.Stream.add caller_result result);
  Eio.Promise.await child_started;
  ignore (owner_ok (Owner.begin_stopping owner));
  (match Eio.Stream.take caller_result with
   | Error Owner.Owner_stopping -> ()
   | Error error -> fail ("wrong stopped-child error: " ^ Owner.error_to_string error)
   | Ok (`Ran _) -> fail "stopped autonomous child reported success"
   | Ok (`Busy _) -> fail "admitted autonomous child became busy");
  check bool
    "stopping clears autonomous projection"
    true
    (Option.is_none (Owner.turn_in_flight owner))
;;

(* Cross-lane exclusion. The autonomous-vs-autonomous case is pinned above;
   this is the pair that actually occurs in production, where a chat operation
   holds the turn and the keepalive cycle finds it taken.

   What the exclusion protects is a single-writer invariant, not a preference:
   a turn drives the per-Keeper turn FSM through
   [Keeper_registry.set_turn_phase], which resolves each transition against the
   current phase and raises [Turn_phase_transition_violation] for a forbidden
   one. Two turns on one Keeper would each transition from whatever the other
   left behind, so interleaving does not corrupt state quietly — it raises.
   Measured over 2026-08-10..12 on the live fleet: 162,813 turn-phase
   transitions, 0 violations.

   The test states the blocked lane, not just the fact of blocking, because the
   holder's identity is what a fairness change would alter (RFC-0373). *)
(* The release signal states availability, not completion. A listener woken by
   "a turn ended" would find the slot already taken whenever a chat operation
   was queued behind it, defer, and wait out its own cadence again — the exact
   loop the notification exists to end. So the Owner fires it only after the
   queued chat operation, if any, has been offered the slot and declined to
   exist. Both directions are asserted here; only the negative one can tell the
   two meanings apart. *)
let test_turn_slot_release_signals_availability () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let released = ref 0 in
  let path = Filename.temp_file "keeper-owner-slot-release-" ".sqlite3" in
  Unix.unlink path;
  Eio.Switch.on_release sw (fun () ->
    if Sys.file_exists path then Unix.unlink path);
  let chat_started, resolve_chat_started = Eio.Promise.create () in
  let release_chat, resolve_release_chat = Eio.Promise.create () in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    (match claim () with
     | Error error -> fail (Owner.error_to_string error)
     | Ok None -> fail "chat runner did not find its FIFO head"
     | Ok (Some _) -> ());
    Eio.Promise.resolve resolve_chat_started ();
    Eio.Promise.await release_chat;
    Owner.Operation_succeeded { outcome_ref = "turn:slot-release" }
  in
  let owner =
    owner_ok
      (Owner.start
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_store_path:path
         ~now:(fun () -> 42.0)
         ~operation_runner:
           (Some
              Owner.
                { ready = (fun ~keeper_name:_ -> true)
                ; execute
                ; on_execution_settled = noop_execution_settled
                })
         ~on_turn_slot_released:(Some (fun () -> incr released))
         ~keeper_name:"slot-release"
         ~initial_meta:(Some (make_meta "slot-release")))
  in
  let autonomous_started, resolve_autonomous_started = Eio.Promise.create () in
  let release_autonomous, resolve_release_autonomous = Eio.Promise.create () in
  let autonomous_result = Eio.Stream.create 1 in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Stream.add
      autonomous_result
      (Owner.run_autonomous_if_idle owner (fun () ->
         Eio.Promise.resolve resolve_autonomous_started ();
         Eio.Promise.await release_autonomous)));
  Eio.Promise.await autonomous_started;
  (* Queue the chat operation while the slot is held, so releasing it produces
     the contested handoff: [Child_finished] frees the slot and offers it to the
     queued operation in the same step. *)
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id:(operation_id "kmsg-slot-release")
          ~source:operation_source
          ~input:(operation_input "queued behind autonomous")));
  check int "a held slot signals nothing" 0 !released;
  Eio.Promise.resolve resolve_release_autonomous ();
  ignore (Eio.Stream.take autonomous_result);
  Eio.Promise.await chat_started;
  (* The chat operation took the slot in that handoff, so no turn can start and
     no availability is owed. A signal here would mean "a turn ended", and its
     listener would wake only to be told the slot is busy. *)
  check
    int
    "a handoff claimed by chat owes no availability signal"
    0
    !released;
  (* Only a lane that asked and was refused is owed the signal. Nothing has
     been refused yet, so make the autonomous lane lose the slot to the chat
     turn now holding it. *)
  (match Owner.run_autonomous_if_idle owner (fun () -> ()) with
   | Ok (`Busy (Owner.Turn_busy _)) -> ()
   | Ok (`Busy other) ->
     fail ("autonomous lost the slot for the wrong reason: "
           ^ Owner.autonomous_block_to_string other)
   | Ok (`Ran ()) -> fail "autonomous ran while the chat lane held the slot"
   | Error error -> fail (Owner.error_to_string error));
  Eio.Promise.resolve resolve_release_chat ();
  ignore (await_terminal owner (operation_id "kmsg-slot-release") 1_000);
  check int "the slot left unclaimed signals the refused lane once" 1 !released
;;

(* Regression guard for the wake storm of 2026-08-12: the notification used to
   fire on every turn end, and a woken keeper starts its next turn at once, so
   each turn scheduled the next one and the fleet ran 13x its measured turn
   rate. A turn that nobody was waiting behind owes no signal. *)
let test_uncontested_turn_end_signals_nothing () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let released = ref 0 in
  let path = Filename.temp_file "keeper-owner-uncontested-" ".sqlite3" in
  Unix.unlink path;
  Eio.Switch.on_release sw (fun () ->
    if Sys.file_exists path then Unix.unlink path);
  let owner =
    owner_ok
      (Owner.start
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_store_path:path
         ~now:(fun () -> 42.0)
         ~operation_runner:None
         ~on_turn_slot_released:(Some (fun () -> incr released))
         ~keeper_name:"uncontested"
         ~initial_meta:(Some (make_meta "uncontested")))
  in
  List.iter
    (fun turn ->
      match Owner.run_autonomous_if_idle owner (fun () -> ()) with
      | Ok (`Ran ()) -> ()
      | Ok (`Busy block) ->
        fail
          (Printf.sprintf
             "turn %d found the slot busy on an idle owner: %s"
             turn
             (Owner.autonomous_block_to_string block))
      | Error error -> fail (Owner.error_to_string error))
    [ 1; 2; 3 ];
  check int "an uncontested turn end signals nothing" 0 !released
;;

let test_chat_lane_holder_blocks_autonomous_admission () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let chat_started, resolve_chat_started = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    (match claim () with
     | Error error -> fail (Owner.error_to_string error)
     | Ok None -> fail "chat runner did not find its FIFO head"
     | Ok (Some _) -> ());
    Eio.Promise.resolve resolve_chat_started ();
    Eio.Promise.await release;
    Owner.Operation_succeeded { outcome_ref = "turn:cross-lane" }
  in
  let owner =
    owner_ok
      (start_owner_with_executor
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some execute)
         ~keeper_name:"cross-lane-exclusion"
         ~initial_meta:(Some (make_meta "cross-lane-exclusion"))
         ())
  in
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id:(operation_id "kmsg-cross-lane")
          ~source:operation_source
          ~input:(operation_input "held")));
  Eio.Promise.await chat_started;
  (match Owner.turn_in_flight owner with
   | Some { lane = Owner.Chat_operation; _ } -> ()
   | Some { lane = _; _ } -> fail "chat operation did not take the turn lane"
   | None -> fail "no turn in flight while the chat runner was executing");
  (match
     Owner.run_autonomous_if_idle owner (fun () ->
       fail "autonomous child ran while a chat operation held the turn")
   with
   | Ok (`Busy (Owner.Turn_busy (Some { lane = Owner.Chat_operation; _ }))) -> ()
   | Ok (`Busy (Owner.Turn_busy (Some { lane = _; _ }))) ->
     fail "autonomous admission blamed the wrong lane"
   | Ok (`Busy (Owner.Turn_busy None)) ->
     fail "autonomous admission reported an unpublished holder"
   | Ok (`Busy (Owner.Shutdown_requested _)) ->
     fail "autonomous admission reported shutdown instead of the chat holder"
   | Ok (`Ran _) -> fail "autonomous admission ignored the chat holder"
   | Error error -> fail ("autonomous admission failed: " ^ Owner.error_to_string error));
  Eio.Promise.resolve resolve_release ()
;;

let test_operation_lifecycle_is_durable_and_projected () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    owner_ok
      (start_owner
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~keeper_name:"operation-lifecycle"
         ~initial_meta:(Some (make_meta "operation-lifecycle")))
  in
  let operation_id = operation_id "kmsg-operation-lifecycle" in
  let accepted =
    owner_ok
      (Owner.submit_operation
         owner
         ~operation_id
         ~source:operation_source
         ~input:(operation_input "first"))
  in
  check bool "first submission is new" false accepted.existing;
  check int "acceptance includes exact queued count" 1 accepted.queued_count;
  let queued_projection = Owner.operation_projection owner in
  check int "queued projection publishes after commit" 1 queued_projection.queued_count;
  check bool
    "queued projection has no running operation"
    true
    (Option.is_none queued_projection.running_operation_id);
  let exact = Option.get (owner_ok (Owner.exact_operation owner operation_id)) in
  (match exact.state with
   | Chat_operation.Queued -> ()
   | state -> fail ("wrong accepted state: " ^ Chat_operation.state_to_string state));
  let running = Option.get (owner_ok (Owner.claim_next_operation owner)) in
  (match running.state with
   | Chat_operation.Running _ -> ()
   | state -> fail ("wrong claimed state: " ^ Chat_operation.state_to_string state));
  check bool
    "only one operation can be running"
    true
    (Option.is_none (owner_ok (Owner.claim_next_operation owner)));
  let running_projection = Owner.operation_projection owner in
  check int "claim drains queued projection" 0 running_projection.queued_count;
  check bool
    "claim publishes running identity"
    true
    (Option.fold
       ~none:false
       ~some:(Chat_operation.Operation_id.equal operation_id)
       running_projection.running_operation_id);
  let succeeded =
    owner_ok
      (Owner.succeed_running_operation owner ~operation_id ~outcome_ref:"turn:42")
  in
  (match succeeded.state with
   | Chat_operation.Succeeded { outcome_ref; _ } ->
     check string "outcome reference retained" "turn:42" outcome_ref
   | state -> fail ("wrong terminal state: " ^ Chat_operation.state_to_string state));
  check bool "terminal input is scrubbed" true (Option.is_none succeeded.input);
  let terminal_projection = Owner.operation_projection owner in
  check int "terminal projection is durable" 1 terminal_projection.terminal_count;
  check bool
    "terminal projection clears running identity"
    true
    (Option.is_none terminal_projection.running_operation_id);
  let replay =
    owner_ok
      (Owner.submit_operation
         owner
         ~operation_id
         ~source:operation_source
         ~input:(operation_input "first"))
  in
  check bool "terminal idempotency replay is permanent" true replay.existing;
  match replay.operation.state with
  | Chat_operation.Succeeded _ -> ()
  | state -> fail ("terminal replay changed state: " ^ Chat_operation.state_to_string state)
;;

let test_health_state_change_observer_tracks_owner_projections () =
  let notifications = ref 0 in
  with_state_change_observer
    (fun () -> incr notifications)
    (fun () ->
       Eio_main.run @@ fun _env ->
       Eio.Switch.run @@ fun sw ->
       let owner =
         owner_ok
           (start_owner
              ~sw
              ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
              ~keeper_name:"health-state-change"
              ~initial_meta:(Some (make_meta "health-state-change")))
       in
       let operation_id = operation_id "kmsg-health-state-change" in
       let accepted =
         owner_ok
           (Owner.submit_operation
              owner
              ~operation_id
              ~source:operation_source
              ~input:(operation_input "observe me"))
       in
       check bool "new submission is accepted" false accepted.existing;
       check int "queued projection notifies once" 1 !notifications;
       let replay =
         owner_ok
           (Owner.submit_operation
              owner
              ~operation_id
              ~source:operation_source
              ~input:(operation_input "observe me"))
       in
       check bool "same submission is an idempotent replay" true replay.existing;
       check int "idempotent replay does not notify" 1 !notifications;
       (match
          Owner.submit_operation
            owner
            ~operation_id
            ~source:operation_source
            ~input:(operation_input "different input")
        with
        | Error (Owner.Operation_rejected _) -> ()
        | Error error -> fail (Owner.error_to_string error)
        | Ok _ -> fail "conflicting submission was accepted");
       check int "rejected submission does not notify" 1 !notifications;
       ignore (Option.get (owner_ok (Owner.claim_next_operation owner)));
       check int "running projection notifies once" 2 !notifications;
       check bool
         "second claim is a no-op"
         true
         (Option.is_none (owner_ok (Owner.claim_next_operation owner)));
       check int "no-op claim does not notify" 2 !notifications;
       ignore
         (owner_ok
            (Owner.succeed_running_operation owner ~operation_id ~outcome_ref:"turn:health"));
       check int "terminal projection notifies once" 3 !notifications;
       let turn_result = Owner.run_autonomous_if_idle owner (fun () -> ()) in
       (match turn_result with
        | Ok (`Ran ()) -> ()
        | Ok (`Busy block) -> fail (Owner.autonomous_block_to_string block)
        | Error error -> fail (Owner.error_to_string error));
       check int "turn start and finish each notify" 5 !notifications;
       let first = Keeper_shutdown_types.Operation_id.generate () in
       let successor = Keeper_shutdown_types.Operation_id.generate () in
       ignore (owner_ok (Owner.begin_shutdown owner ~operation_id:first));
       check int "shutdown reservation notifies" 6 !notifications;
       ignore (owner_ok (Owner.begin_shutdown owner ~operation_id:first));
       check int "shutdown replay does not notify" 6 !notifications;
       ignore
         (owner_ok
            (Owner.transition_shutdown
               owner
               ~from_operation_id:first
               ~to_operation_id:(Some successor)));
       check int "shutdown successor notifies" 7 !notifications;
       ignore
         (owner_ok
            (Owner.transition_shutdown
               owner
               ~from_operation_id:first
               ~to_operation_id:(Some successor)));
       check int "shutdown transition replay does not notify" 7 !notifications;
       ignore
         (owner_ok
            (Owner.transition_shutdown
               owner
               ~from_operation_id:successor
               ~to_operation_id:None));
       check int "shutdown release notifies" 8 !notifications)
;;

let test_health_state_change_observer_failure_is_isolated () =
  with_state_change_observer
    (fun () -> failwith "observer fault")
    (fun () ->
       Eio_main.run @@ fun _env ->
       Eio.Switch.run @@ fun sw ->
       let owner =
         owner_ok
           (start_owner
              ~sw
              ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
              ~keeper_name:"health-observer-failure"
              ~initial_meta:(Some (make_meta "health-observer-failure")))
       in
       let operation_id = operation_id "kmsg-health-observer-failure" in
       let accepted =
         owner_ok
           (Owner.submit_operation
              owner
              ~operation_id
              ~source:operation_source
              ~input:(operation_input "observer must not alter result"))
       in
       check bool "observer failure preserves acceptance" false accepted.existing;
       ignore (Option.get (owner_ok (Owner.claim_next_operation owner)));
       let terminal =
         owner_ok
           (Owner.succeed_running_operation owner ~operation_id ~outcome_ref:"turn:ok")
       in
       match terminal.state with
       | Chat_operation.Succeeded _ -> ()
       | state ->
         fail
           ("observer failure altered terminal result: "
            ^ Chat_operation.state_to_string state))
;;

let test_operation_executor_claims_latest_input_and_drains_fifo () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let executor_started, resolve_executor_started = Eio.Promise.create () in
  let allow_first_claim, resolve_first_claim = Eio.Promise.create () in
  let seen_inputs = ref [] in
  let execution_count = ref 0 in
  let operation_executor ~sw:_ ~keeper_name:_ ~claim =
    incr execution_count;
    if !execution_count = 1
    then (
      Eio.Promise.resolve resolve_executor_started ();
      Eio.Promise.await allow_first_claim);
    match claim () with
    | Error error ->
      Owner.Operation_failed
        { kind = Chat_operation.Store_unavailable
        ; detail = Owner.error_to_string error
        ; outcome_ref = None
        }
    | Ok None ->
      Owner.Operation_failed
        { kind = Chat_operation.No_queued_operation
        ; detail = "missing FIFO head"
        ; outcome_ref = None
        }
    | Ok (Some (operation : Chat_operation.t)) ->
      seen_inputs := operation.input :: !seen_inputs;
      Owner.Operation_succeeded
        { outcome_ref =
            "turn:" ^ Chat_operation.Operation_id.to_string operation.operation_id
        }
  in
  let owner =
    owner_ok
      (start_owner_with_executor
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some operation_executor)
         ~keeper_name:"operation-executor"
         ~initial_meta:(Some (make_meta "operation-executor"))
         ())
  in
  let first_id = operation_id "kmsg-operation-executor-first" in
  let second_id = operation_id "kmsg-operation-executor-second" in
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id:first_id
          ~source:operation_source
          ~input:(operation_input "stale")));
  Eio.Promise.await executor_started;
  ignore
    (owner_ok
       (Owner.edit_queued_operation
          owner
          ~operation_id:first_id
          ~input:(operation_input "latest")));
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id:second_id
          ~source:operation_source
          ~input:(operation_input "second")));
  Eio.Promise.resolve resolve_first_claim ();
  let first = await_terminal owner first_id 1_000 in
  let second = await_terminal owner second_id 1_000 in
  (match first.state, second.state with
   | Chat_operation.Succeeded _, Chat_operation.Succeeded _ -> ()
   | _ -> fail "Owner executor did not terminalize both FIFO operations");
  check
    (list (option json))
    "claim observes edited input and then the next FIFO body"
    [ Some (operation_input "latest"); Some (operation_input "second") ]
    (List.rev !seen_inputs);
  check int "one child drains one operation at a time" 2 !execution_count
;;

let test_operation_executor_exception_is_terminal_and_next_runs () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let execution_count = ref 0 in
  let operation_executor ~sw:_ ~keeper_name:_ ~claim =
    incr execution_count;
    match claim () with
    | Error error ->
      Owner.Operation_failed
        { kind = Chat_operation.Store_unavailable
        ; detail = Owner.error_to_string error
        ; outcome_ref = None
        }
    | Ok None -> failwith "missing FIFO head"
    | Ok (Some (operation : Chat_operation.t)) ->
      if !execution_count = 1
      then failwith "synthetic child exception"
      else
        Owner.Operation_succeeded
          { outcome_ref =
              "turn:" ^ Chat_operation.Operation_id.to_string operation.operation_id
          }
  in
  let owner =
    owner_ok
      (start_owner_with_executor
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some operation_executor)
         ~keeper_name:"operation-exception"
         ~initial_meta:(Some (make_meta "operation-exception"))
         ())
  in
  let first_id = operation_id "kmsg-operation-exception-first" in
  let second_id = operation_id "kmsg-operation-exception-second" in
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id:first_id
          ~source:operation_source
          ~input:(operation_input "first")));
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id:second_id
          ~source:operation_source
          ~input:(operation_input "second")));
  let first = await_terminal owner first_id 1_000 in
  let second = await_terminal owner second_id 1_000 in
  (match first.state with
   | Chat_operation.Failed { failure = { kind; detail; _ }; _ } ->
     check string
       "exception failure kind"
       "Turn_exception"
       (Chat_operation.failure_kind_to_string kind);
     check bool "exception detail is retained" true (String.length detail > 0)
   | _ -> fail "child exception did not fail the first operation");
  (match second.state with
   | Chat_operation.Succeeded _ -> ()
   | _ -> fail "child exception stopped the Owner FIFO drain");
  check int "child exception does not stop the actor" 2 !execution_count
;;

let test_operator_interrupt_settles_as_typed_cancel () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let operation_executor ~sw:_ ~keeper_name:_ ~claim =
    match claim () with
    | Error error ->
      Owner.Operation_failed
        { kind = Chat_operation.Store_unavailable
        ; detail = Owner.error_to_string error
        ; outcome_ref = None
        }
    | Ok None -> failwith "missing FIFO head"
    | Ok (Some (_ : Chat_operation.t)) ->
      (* The interrupt route fails the turn switch with this exception; at
         the executor boundary it surfaces bare (#28810). It must settle as
         a typed operator cancellation, never as Turn_exception. *)
      raise Keeper_registry_types.Operator_interrupt
  in
  let owner =
    owner_ok
      (start_owner_with_executor
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some operation_executor)
         ~keeper_name:"operator-interrupt"
         ~initial_meta:(Some (make_meta "operator-interrupt"))
         ())
  in
  let operation_id = operation_id "kmsg-operator-interrupt" in
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id
          ~source:operation_source
          ~input:(operation_input "interrupt me")));
  let terminal = await_terminal owner operation_id 1_000 in
  match terminal.state with
  | Chat_operation.Failed { failure = { kind; detail; _ }; _ } ->
    check string
      "operator interrupt failure kind"
      "Turn_cancelled"
      (Chat_operation.failure_kind_to_string kind);
    check string
      "operator interrupt detail"
      Keeper_registry_types.operator_interrupt_detail
      detail
  | _ -> fail "operator interrupt did not settle the operation as failed"
;;

let test_exact_operation_interrupt_cannot_cancel_its_replacement () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let started = Eio.Stream.create 2 in
  let release_first, resolve_first = Eio.Promise.create () in
  let first_id = operation_id "kmsg-exact-interrupt-first" in
  let second_id = operation_id "kmsg-exact-interrupt-second" in
  let operation_executor ~sw:_ ~keeper_name:_ ~claim =
    match claim () with
    | Error error -> fail (Owner.error_to_string error)
    | Ok None -> fail "exact-interrupt runner did not claim an operation"
    | Ok (Some operation) ->
        Eio.Stream.add started operation.Chat_operation.operation_id;
        if Chat_operation.Operation_id.equal operation.operation_id first_id
        then Eio.Promise.await release_first
        else Eio.Fiber.await_cancel ();
        Owner.Operation_succeeded { outcome_ref = "done" }
  in
  let owner =
    owner_ok
      (start_owner_with_executor
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some operation_executor)
         ~keeper_name:"exact-interrupt"
         ~initial_meta:(Some (make_meta "exact-interrupt"))
         ())
  in
  List.iter
    (fun operation_id ->
      ignore
        (owner_ok
           (Owner.submit_operation owner ~operation_id ~source:operation_source
              ~input:(operation_input "wait"))))
    [ first_id; second_id ];
  check bool "first operation started" true
    (Chat_operation.Operation_id.equal (Eio.Stream.take started) first_id);
  Eio.Promise.resolve resolve_first ();
  ignore (await_terminal owner first_id 1_000);
  check bool "replacement operation started" true
    (Chat_operation.Operation_id.equal (Eio.Stream.take started) second_id);
  (match Owner.interrupt_running_operation owner first_id with
   | Ok
       (Owner.Operation_not_current
          { running_operation_id = Some running }) ->
       check bool "stale interrupt observes replacement identity" true
         (Chat_operation.Operation_id.equal running second_id)
   | Ok Owner.Operation_interrupt_signalled ->
       fail "stale interrupt signalled the replacement operation"
   | Ok (Owner.Operation_not_current { running_operation_id = None }) ->
       fail "replacement lost its running identity"
   | Ok (Owner.Operation_interrupt_failed detail) -> fail detail
   | Error error -> fail (Owner.error_to_string error));
  (match Owner.interrupt_running_operation owner second_id with
   | Ok Owner.Operation_interrupt_signalled -> ()
   | Ok (Owner.Operation_not_current _) -> fail "exact replacement was not current"
   | Ok (Owner.Operation_interrupt_failed detail) -> fail detail
   | Error error -> fail (Owner.error_to_string error));
  let terminal = await_terminal owner second_id 1_000 in
  match terminal.state with
  | Chat_operation.Failed { failure = { kind; _ }; _ } ->
      check string "exact interrupt is a typed cancellation" "Turn_cancelled"
        (Chat_operation.failure_kind_to_string kind)
  | _ -> fail "exact interrupt did not settle the replacement as cancelled"
;;

let test_is_operator_interrupt_unwraps_every_shape () =
  let interrupt = Keeper_registry_types.Operator_interrupt in
  let bt = Printexc.get_callstack 0 in
  let is = Keeper_registry_types.is_operator_interrupt in
  check bool "bare" true (is interrupt);
  check bool "cancelled-wrapped" true (is (Eio.Cancel.Cancelled interrupt));
  check bool "finally over cancelled" true
    (is (Stdlib.Fun.Finally_raised (Eio.Cancel.Cancelled interrupt)));
  check bool "multiple of interrupt shapes" true
    (is
       (Eio.Exn.Multiple
          [ (interrupt, bt); (Eio.Cancel.Cancelled interrupt, bt) ]));
  check bool "multiple with a real error keeps crash classification" false
    (is (Eio.Exn.Multiple [ (interrupt, bt); (Failure "real crash", bt) ]));
  check bool "empty multiple is not an interrupt" false
    (is (Eio.Exn.Multiple []));
  check bool "unrelated exception" false (is (Failure "boom"))
;;

let test_operator_interrupt_combined_shape_settles_as_typed_cancel () =
  (* #28868 review P1: Eio combines the switch failure with what cancelled
     fibers raise into [Multiple] (finalizers add [Finally_raised]). The
     wrapper ladder must classify the combined shape too. *)
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let operation_executor ~sw:_ ~keeper_name:_ ~claim =
    match claim () with
    | Error error ->
      Owner.Operation_failed
        { kind = Chat_operation.Store_unavailable
        ; detail = Owner.error_to_string error
        ; outcome_ref = None
        }
    | Ok None -> failwith "missing FIFO head"
    | Ok (Some (_ : Chat_operation.t)) ->
      let bt = Printexc.get_callstack 0 in
      raise
        (Eio.Exn.Multiple
           [ (Eio.Cancel.Cancelled Keeper_registry_types.Operator_interrupt, bt)
           ; ( Stdlib.Fun.Finally_raised
                 (Eio.Cancel.Cancelled Keeper_registry_types.Operator_interrupt)
             , bt )
           ])
  in
  let owner =
    owner_ok
      (start_owner_with_executor
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some operation_executor)
         ~keeper_name:"operator-interrupt-combined"
         ~initial_meta:(Some (make_meta "operator-interrupt-combined"))
         ())
  in
  let operation_id = operation_id "kmsg-operator-interrupt-combined" in
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id
          ~source:operation_source
          ~input:(operation_input "interrupt me, combined")));
  let terminal = await_terminal owner operation_id 1_000 in
  match terminal.state with
  | Chat_operation.Failed { failure = { kind; detail; _ }; _ } ->
    check string
      "combined-shape failure kind"
      "Turn_cancelled"
      (Chat_operation.failure_kind_to_string kind);
    check string
      "combined-shape detail"
      Keeper_registry_types.operator_interrupt_detail
      detail
  | _ -> fail "combined-shape interrupt did not settle the operation as failed"
;;

let test_paused_owner_preserves_queue_until_resume () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let execution_count = ref 0 in
  let operation_executor ~sw:_ ~keeper_name:_ ~claim =
    incr execution_count;
    match claim () with
    | Error error -> fail (Owner.error_to_string error)
    | Ok None -> fail "resumed owner did not claim its queued operation"
    | Ok (Some (operation : Chat_operation.t)) ->
      Owner.Operation_succeeded
        { outcome_ref =
            "turn:" ^ Chat_operation.Operation_id.to_string operation.operation_id
        }
  in
  let owner =
    owner_ok
      (start_owner_with_executor
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some operation_executor)
         ~keeper_name:"paused-operation"
         ~initial_meta:(Some (make_meta "paused-operation"))
         ())
  in
  ignore
    (owner_ok
       (Owner.apply_meta
          owner
          (Pause
             { reason =
                 Keeper_latched_reason.Operator_paused
                   { operator_actor = Keeper_latched_reason.Grpc_directive }
             ; updated_at = "paused"
             })));
  let operation_id = operation_id "kmsg-paused-operation" in
  let accepted =
    owner_ok
      (Owner.submit_operation
         owner
         ~operation_id
         ~source:operation_source
         ~input:(operation_input "wait for resume"))
  in
  (match accepted.operation.state with
   | Chat_operation.Queued -> ()
   | state ->
     fail
       ("paused owner did not preserve Queued: "
        ^ Chat_operation.state_to_string state));
  Eio.Fiber.yield ();
  check int "paused owner starts no chat child" 0 !execution_count;
  ignore (owner_ok (Owner.apply_meta owner (Resume { updated_at = "resumed" })));
  let terminal = await_terminal owner operation_id 1_000 in
  (match terminal.state with
   | Chat_operation.Succeeded _ -> ()
   | state ->
     fail
       ("resume did not drain queued operation: "
        ^ Chat_operation.state_to_string state));
  check int "resume starts exactly one chat child" 1 !execution_count
;;

let test_pause_rechecks_pending_claim_admission () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let executor_started, resolve_executor_started = Eio.Promise.create () in
  let allow_claim, resolve_allow_claim = Eio.Promise.create () in
  let claim_returned, resolve_claim_returned = Eio.Promise.create () in
  let execution_count = ref 0 in
  let operation_executor ~sw:_ ~keeper_name:_ ~claim =
    incr execution_count;
    Eio.Promise.resolve resolve_executor_started ();
    Eio.Promise.await allow_claim;
    let result = claim () in
    Eio.Promise.resolve resolve_claim_returned ();
    match result with
    | Ok None ->
      Owner.Operation_failed
        { kind = Chat_operation.No_queued_operation
        ; detail = "pause closed chat-operation admission"
        ; outcome_ref = None
        }
    | Ok (Some (operation : Chat_operation.t)) ->
      Owner.Operation_failed
        { kind = Chat_operation.Turn_exception
        ; detail =
            "paused owner incorrectly claimed "
            ^ Chat_operation.Operation_id.to_string operation.operation_id
        ; outcome_ref = None
        }
    | Error error ->
      Owner.Operation_failed
        { kind = Chat_operation.Store_unavailable
        ; detail = Owner.error_to_string error
        ; outcome_ref = None
        }
  in
  let owner =
    owner_ok
      (start_owner_with_executor
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some operation_executor)
         ~keeper_name:"pause-pending-claim"
         ~initial_meta:(Some (make_meta "pause-pending-claim"))
         ())
  in
  let operation_id = operation_id "kmsg-pause-pending-claim" in
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id
          ~source:operation_source
          ~input:(operation_input "must remain queued")));
  Eio.Promise.await executor_started;
  ignore
    (owner_ok
       (Owner.apply_meta
          owner
          (Pause
             { reason =
                 Keeper_latched_reason.Operator_paused
                   { operator_actor = Keeper_latched_reason.Grpc_directive }
             ; updated_at = "paused-before-claim"
             })));
  Eio.Promise.resolve resolve_allow_claim ();
  Eio.Promise.await claim_returned;
  let observed = Option.get (owner_ok (Owner.exact_operation owner operation_id)) in
  (match observed.state with
   | Chat_operation.Queued -> ()
   | state ->
     fail
       ("pause allowed a pending child to claim: "
        ^ Chat_operation.state_to_string state));
  check int "pending child was admitted once before pause" 1 !execution_count
;;

let test_startup_interrupts_running_without_requeue () =
  Eio_main.run @@ fun _env ->
  let path = Filename.temp_file "keeper-owner-restart-" ".sqlite3" in
  Unix.unlink path;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Unix.unlink path)
    (fun () ->
       let operation_id = operation_id "kmsg-interrupted-restart" in
       let seed =
         Keeper_chat_operation_store.open_or_create ~path
         |> Result.map_error Keeper_chat_operation_store.error_to_string
         |> Result.get_ok
       in
       Keeper_chat_operation_store.submit
         seed
         ~now:10.0
         ~operation_id
         ~source:operation_source
         ~input:(operation_input "running at crash")
       |> Result.get_ok
       |> ignore;
       Keeper_chat_operation_store.claim_next seed ~now:11.0
       |> Result.get_ok
       |> ignore;
       Keeper_chat_operation_store.close seed |> Result.get_ok;
       Eio.Switch.run @@ fun sw ->
       let owner =
         owner_ok
           (Owner.start
              ~sw
              ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
              ~operation_store_path:path
              ~now:(fun () -> 20.0)
              ~operation_runner:None
           ~on_turn_slot_released:None
              ~keeper_name:"interrupted-restart"
              ~initial_meta:(Some (make_meta "interrupted-restart")))
       in
       let settled = Option.get (owner_ok (Owner.exact_operation owner operation_id)) in
       (match settled.state with
        | Chat_operation.Failed { failure = { kind; _ }; _ } ->
          check string
            "restart failure kind"
            "Interrupted_by_restart"
            (Chat_operation.failure_kind_to_string kind)
        | state -> fail ("restart did not interrupt Running: " ^ Chat_operation.state_to_string state));
       check bool "interrupted input is scrubbed" true (Option.is_none settled.input);
       check bool
         "restart never requeues Running"
         true
         (Option.is_none (owner_ok (Owner.claim_next_operation owner))))
;;

let test_startup_queued_waits_for_runner_readiness () =
  Eio_main.run @@ fun _env ->
  let path = Filename.temp_file "keeper-owner-ready-" ".sqlite3" in
  Unix.unlink path;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Unix.unlink path)
    (fun () ->
       let first_id = operation_id "kmsg-ready-first" in
       let second_id = operation_id "kmsg-ready-second" in
       let seed =
         Keeper_chat_operation_store.open_or_create ~path
         |> Result.map_error Keeper_chat_operation_store.error_to_string
         |> Result.get_ok
       in
       List.iter
         (fun (operation_id, input) ->
            Keeper_chat_operation_store.submit
              seed
              ~now:10.0
              ~operation_id
              ~source:operation_source
              ~input
            |> Result.get_ok
            |> ignore)
         [ first_id, operation_input "first"
         ; second_id, operation_input "second"
         ];
       Keeper_chat_operation_store.close seed |> Result.get_ok;
       let ready = ref false in
       let executed = ref [] in
       let execute ~sw:_ ~keeper_name:_ ~claim =
         match claim () with
         | Error error -> fail (Owner.error_to_string error)
         | Ok None -> fail "ready operation runner did not find its FIFO head"
         | Ok (Some (operation : Chat_operation.t)) ->
           executed := operation.operation_id :: !executed;
           Owner.Operation_succeeded
             { outcome_ref =
                 "turn:"
                 ^ Chat_operation.Operation_id.to_string operation.operation_id
             }
       in
       Eio.Switch.run @@ fun sw ->
       let owner =
         owner_ok
           (Owner.start
              ~sw
              ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
              ~operation_store_path:path
              ~now:(fun () -> 20.0)
              ~operation_runner:
                (Some
                   Owner.
                     { ready = (fun ~keeper_name:_ -> !ready)
                     ; execute
                     ; on_execution_settled = noop_execution_settled
                     })
              ~on_turn_slot_released:None
              ~keeper_name:"ready-after-registration"
              ~initial_meta:(Some (make_meta "ready-after-registration")))
       in
       let first_before =
         Option.get (owner_ok (Owner.exact_operation owner first_id))
       in
       let second_before =
         Option.get (owner_ok (Owner.exact_operation owner second_id))
       in
       (match first_before.state, second_before.state with
        | Chat_operation.Queued, Chat_operation.Queued -> ()
        | _ -> fail "startup claimed Queued operations before runner readiness");
       check int "executor did not run before readiness" 0 (List.length !executed);
       ready := true;
       ignore (owner_ok (Owner.wake_operation_drain owner));
       let first = await_terminal owner first_id 1_000 in
       let second = await_terminal owner second_id 1_000 in
       (match first.state, second.state with
        | Chat_operation.Succeeded _, Chat_operation.Succeeded _ -> ()
        | _ -> fail "ready wake did not drain both Queued operations");
       check
         (list string)
         "registration wake preserves FIFO"
         [ Chat_operation.Operation_id.to_string first_id
         ; Chat_operation.Operation_id.to_string second_id
         ]
         (List.rev_map Chat_operation.Operation_id.to_string !executed))
;;

let test_operation_store_failure_fences_owner_mutations () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    owner_ok
      (start_owner
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~keeper_name:"operation-store-failure"
         ~initial_meta:(Some (make_meta "operation-store-failure")))
  in
  let operation_id = operation_id "kmsg-operation-store-failure" in
  Fun.protect
    ~finally:Keeper_chat_operation_store.For_testing.clear_commit_fault
    (fun () ->
       Keeper_chat_operation_store.For_testing.fail_next_commit
         Keeper_chat_operation_store.For_testing.Fail_before_commit;
       (match
          Owner.submit_operation
            owner
            ~operation_id
            ~source:operation_source
            ~input:(operation_input "must rollback")
        with
        | Error (Owner.Store_unavailable _) -> ()
        | Error error -> fail ("wrong operation store error: " ^ Owner.error_to_string error)
        | Ok _ -> fail "operation commit failure was acknowledged");
       check bool
         "pre-commit failure leaves no operation"
         true
         (Option.is_none (owner_ok (Owner.exact_operation owner operation_id)));
       match
         Owner.apply_meta
           owner
           (Set_autoboot { enabled = true; updated_at = "must-remain-fenced" })
       with
       | Error (Owner.Store_unavailable _) -> ()
       | Error error -> fail ("wrong global fence error: " ^ Owner.error_to_string error)
       | Ok _ -> fail "operation store failure did not fence metadata mutation")
;;

let test_keeper_owners_do_not_cross_block () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let blocked, resolve_blocked = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let first =
    owner_ok
      (start_owner
         ~sw
         ~store:
           { replace =
               (fun _ ->
                  Eio.Promise.resolve resolve_blocked ();
                  Eio.Promise.await release;
                  Ok ())
           ; remove = (fun _ -> Ok ())
           }
         ~keeper_name:"independent-first"
         ~initial_meta:(Some (make_meta "independent-first")))
  in
  let second =
    owner_ok
      (start_owner
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~keeper_name:"independent-second"
         ~initial_meta:(Some (make_meta "independent-second")))
  in
  Eio.Fiber.fork ~sw (fun () ->
    ignore
      (Owner.apply_meta
         first
         (Set_autoboot { enabled = true; updated_at = "blocked" })));
  Eio.Promise.await blocked;
  let accepted =
    owner_ok
      (Owner.submit_operation
         second
         ~operation_id:(operation_id "kmsg-independent-second")
         ~source:operation_source
         ~input:(operation_input "must not cross-block"))
  in
  check bool "second Keeper accepts while first is blocked" false accepted.existing;
  Eio.Promise.resolve resolve_release ()
;;

let test_owner_linearizes_autonomous_and_chat_children () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let autonomous_started, resolve_autonomous_started = Eio.Promise.create () in
  let release_autonomous, resolve_release_autonomous = Eio.Promise.create () in
  let operation_started, resolve_operation_started = Eio.Promise.create () in
  let operation_executor ~sw:_ ~keeper_name:_ ~claim =
    match claim () with
    | Error error -> fail (Owner.error_to_string error)
    | Ok None -> fail "chat operation disappeared before Owner claim"
    | Ok (Some (operation : Chat_operation.t)) ->
      Eio.Promise.resolve resolve_operation_started ();
      Owner.Operation_succeeded
        { outcome_ref =
            "turn:" ^ Chat_operation.Operation_id.to_string operation.operation_id
        }
  in
  let owner =
    owner_ok
      (start_owner_with_executor
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some operation_executor)
         ~keeper_name:"single-turn-owner"
         ~initial_meta:(Some (make_meta "single-turn-owner"))
         ())
  in
  let autonomous_result = Eio.Stream.create 1 in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      Owner.run_autonomous_if_idle owner (fun () ->
        Eio.Promise.resolve resolve_autonomous_started ();
        Eio.Promise.await release_autonomous;
        42)
    in
    Eio.Stream.add autonomous_result result);
  Eio.Promise.await autonomous_started;
  (match Owner.turn_in_flight owner with
   | Some { lane = Owner.Autonomous; _ } -> ()
   | Some _ -> fail "Owner projected the wrong active turn lane"
   | None -> fail "Owner did not project the autonomous child");
  let operation_id = operation_id "kmsg-single-turn-owner" in
  let accepted =
    owner_ok
      (Owner.submit_operation
         owner
         ~operation_id
         ~source:operation_source
         ~input:(operation_input "wait behind autonomous"))
  in
  (match accepted.operation.state with
   | Chat_operation.Queued -> ()
   | state ->
     fail
       ("chat operation started beside autonomous child: "
        ^ Chat_operation.state_to_string state));
  (match Owner.run_autonomous_if_idle owner (fun () -> fail "busy child ran") with
   | Ok (`Busy (Owner.Turn_busy (Some { lane = Owner.Autonomous; _ }))) -> ()
   | Ok (`Busy _) -> fail "busy result projected the wrong lane"
   | Ok (`Ran _) -> fail "Owner admitted two autonomous children"
   | Error error -> fail (Owner.error_to_string error));
  (match Owner.run_maintenance_if_idle owner (fun () -> fail "busy maintenance ran") with
   | Ok (`Busy (Owner.Turn_busy (Some { lane = Owner.Autonomous; _ }))) -> ()
   | Ok (`Busy _) -> fail "maintenance busy result projected the wrong lane"
   | Ok (`Ran _) -> fail "Owner admitted maintenance beside autonomous"
   | Error error -> fail (Owner.error_to_string error));
  Eio.Promise.resolve resolve_release_autonomous ();
  (match Eio.Stream.take autonomous_result with
   | Ok (`Ran 42) -> ()
   | Ok (`Ran value) -> failf "wrong autonomous result: %d" value
   | Ok (`Busy _) -> fail "first autonomous child was reported busy"
   | Error error -> fail (Owner.error_to_string error));
  Eio.Promise.await operation_started;
  let terminal = await_terminal owner operation_id 1_000 in
  (match terminal.state with
   | Chat_operation.Succeeded _ -> ()
   | state ->
     fail
       ("queued operation did not run after autonomous release: "
        ^ Chat_operation.state_to_string state));
  check bool "Owner clears active turn projection" true (Option.is_none (Owner.turn_in_flight owner))
;;

let test_unready_chat_queue_does_not_block_autonomous () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let operation_executor ~sw:_ ~keeper_name:_ ~claim:_ =
    fail "unready operation runner must not start"
  in
  let owner =
    owner_ok
      (start_owner_with_executor_ready
         ~operation_ready:(fun ~keeper_name:_ -> false)
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some operation_executor)
         ~keeper_name:"unready-chat-owner"
         ~initial_meta:(Some (make_meta "unready-chat-owner"))
         ())
  in
  let operation_id = operation_id "kmsg-unready-chat-owner" in
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id
          ~source:operation_source
          ~input:(operation_input "remain queued")));
  (match Owner.run_autonomous_if_idle owner (fun () -> 7) with
   | Ok (`Ran value) -> check int "autonomous callback ran" 7 value
   | Ok (`Busy block) ->
     fail
       ("unclaimable chat queue blocked autonomous work: "
        ^ Owner.autonomous_block_to_string block)
   | Error error -> fail (Owner.error_to_string error));
  let observed = Option.get (owner_ok (Owner.exact_operation owner operation_id)) in
  match observed.state with
  | Chat_operation.Queued -> ()
  | state ->
    fail
      ("autonomous work mutated the unready chat operation: "
       ^ Chat_operation.state_to_string state)
;;

let test_owner_shutdown_linearizes_and_awaits_child () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    owner_ok
      (start_owner
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~keeper_name:"shutdown-owner"
         ~initial_meta:(Some (make_meta "shutdown-owner")))
  in
  let child_started, resolve_child_started = Eio.Promise.create () in
  let release_child, resolve_release_child = Eio.Promise.create () in
  let child_result = Eio.Stream.create 1 in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Stream.add
      child_result
      (Owner.run_autonomous_if_idle owner (fun () ->
         Eio.Promise.resolve resolve_child_started ();
         Eio.Promise.await release_child)));
  Eio.Promise.await child_started;
  let shutdown_id = Keeper_shutdown_types.Operation_id.generate () in
  (match owner_ok (Owner.begin_shutdown owner ~operation_id:shutdown_id) with
   | Owner.Shutdown_reserved
       { operation_id = reserved
       ; in_flight = Some { lane = Owner.Autonomous; _ }
       } ->
     check bool
       "shutdown reserves the requested operation"
       true
       (Keeper_shutdown_types.Operation_id.equal reserved shutdown_id)
   | Owner.Shutdown_reserved _ -> fail "shutdown lost the active Owner child"
   | Owner.Shutdown_already_reserved _ -> fail "fresh Owner was already reserved");
  check bool
    "shutdown projection publishes the reservation"
    true
    (Option.exists
       (Keeper_shutdown_types.Operation_id.equal shutdown_id)
       (Owner.shutdown_operation_id owner));
  (match Owner.run_maintenance_if_idle owner (fun () -> fail "shutdown admitted turn") with
   | Ok (`Busy (Owner.Shutdown_requested reserved)) ->
     check bool
       "new turn sees typed shutdown owner"
       true
       (Keeper_shutdown_types.Operation_id.equal reserved shutdown_id)
   | Ok (`Busy (Owner.Turn_busy _)) -> fail "shutdown was reported as ordinary busy"
   | Ok (`Ran _) -> fail "shutdown admitted a new turn"
   | Error error -> fail (Owner.error_to_string error));
  (match
     Owner.submit_operation
       owner
       ~operation_id:(operation_id "kmsg-shutdown-rejected")
       ~source:operation_source
       ~input:(operation_input "must reject")
   with
   | Error Owner.Owner_stopping -> ()
   | Error error -> fail (Owner.error_to_string error)
   | Ok _ -> fail "shutdown accepted a new operation");
  let idle_joined = Atomic.make false in
  Eio.Fiber.fork ~sw (fun () ->
    owner_ok (Owner.await_idle_after_shutdown owner);
    Atomic.set idle_joined true);
  Eio.Fiber.yield ();
  check bool "shutdown join waits for the preceding child" false (Atomic.get idle_joined);
  Eio.Promise.resolve resolve_release_child ();
  (match Eio.Stream.take child_result with
   | Ok (`Ran ()) -> ()
   | Ok (`Busy _) -> fail "admitted child became busy"
   | Error error -> fail (Owner.error_to_string error));
  while not (Atomic.get idle_joined) do
    Eio.Fiber.yield ()
  done;
  (match owner_ok (Owner.rollback_shutdown owner ~operation_id:shutdown_id) with
   | Owner.Shutdown_rolled_back -> ()
   | Owner.Shutdown_not_reserved -> fail "shutdown reservation disappeared"
   | Owner.Shutdown_reserved_by_other _ -> fail "shutdown owner changed");
  match Owner.run_maintenance_if_idle owner (fun () -> 7) with
  | Ok (`Ran 7) -> ()
  | Ok (`Ran _) -> fail "wrong post-rollback value"
  | Ok (`Busy _) -> fail "rollback did not reopen Owner turns"
  | Error error -> fail (Owner.error_to_string error)
;;

let test_owner_shutdown_restore_and_transition_are_typed () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    owner_ok
      (start_owner
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~keeper_name:"shutdown-restore-owner"
         ~initial_meta:(Some (make_meta "shutdown-restore-owner")))
  in
  let first = Keeper_shutdown_types.Operation_id.generate () in
  let successor = Keeper_shutdown_types.Operation_id.generate () in
  (match owner_ok (Owner.restore_shutdown owner ~operation_id:first) with
   | Owner.Shutdown_restored -> ()
   | Owner.Shutdown_already_restored | Owner.Shutdown_restore_conflict _ ->
     fail "fresh shutdown restore failed");
  (match owner_ok (Owner.restore_shutdown owner ~operation_id:successor) with
   | Owner.Shutdown_restore_conflict existing ->
     check bool
       "restore conflict preserves existing owner"
       true
       (Keeper_shutdown_types.Operation_id.equal existing first)
   | Owner.Shutdown_restored | Owner.Shutdown_already_restored ->
     fail "restore overwrote a different shutdown owner");
  (match
     owner_ok
       (Owner.transition_shutdown
          owner
          ~from_operation_id:first
          ~to_operation_id:(Some successor))
   with
   | Owner.Shutdown_transition_applied -> ()
   | Owner.Shutdown_transition_already_applied
   | Owner.Shutdown_transition_reserved_by_other _ ->
     fail "shutdown successor transition failed");
  (match
     owner_ok
       (Owner.transition_shutdown
          owner
          ~from_operation_id:first
          ~to_operation_id:(Some successor))
   with
   | Owner.Shutdown_transition_already_applied -> ()
   | Owner.Shutdown_transition_applied
   | Owner.Shutdown_transition_reserved_by_other _ ->
     fail "shutdown successor replay was not idempotent");
  match
    owner_ok
      (Owner.transition_shutdown
         owner
         ~from_operation_id:successor
         ~to_operation_id:None)
  with
  | Owner.Shutdown_transition_applied ->
    check bool
      "terminal transition clears shutdown projection"
      true
      (Option.is_none (Owner.shutdown_operation_id owner))
  | Owner.Shutdown_transition_already_applied
  | Owner.Shutdown_transition_reserved_by_other _ ->
    fail "terminal shutdown transition failed"
;;

let test_autonomous_children_of_distinct_owners_do_not_cross_block () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let first_started, resolve_first_started = Eio.Promise.create () in
  let release_first, resolve_release_first = Eio.Promise.create () in
  let start keeper_name =
    owner_ok
      (start_owner
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~keeper_name
         ~initial_meta:(Some (make_meta keeper_name)))
  in
  let first = start "turn-owner-first" in
  let second = start "turn-owner-second" in
  Eio.Fiber.fork ~sw (fun () ->
    ignore
      (Owner.run_autonomous_if_idle first (fun () ->
         Eio.Promise.resolve resolve_first_started ();
         Eio.Promise.await release_first)));
  Eio.Promise.await first_started;
  (match Owner.run_autonomous_if_idle second (fun () -> 7) with
   | Ok (`Ran 7) -> ()
   | Ok (`Ran value) -> failf "wrong second Owner result: %d" value
   | Ok (`Busy _) -> fail "one Keeper blocked another Keeper's autonomous child"
   | Error error -> fail (Owner.error_to_string error));
  Eio.Promise.resolve resolve_release_first ()
;;

let temp_dir () =
  let path = Filename.temp_file "keeper-owner-registry-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Array.iter
        (fun child -> remove_tree (Filename.concat path child))
        (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)
;;

let write_file path content =
  Out_channel.with_open_bin path (fun channel -> output_string channel content)
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

let latest_log_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> entry.seq
  | [] -> -1
;;

let test_same_process_recreate_reopens_purged_operation_store () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let keeper_name = "same-process-recreate" in
       let keeper_dir = Filename.concat base_path keeper_name in
       mkdir_p keeper_dir;
       let operation_store_path =
         Filename.concat keeper_dir Keeper_chat_operation_store.database_file
       in
       let persisted = ref None in
       let store : Owner.store =
         { replace = (fun meta -> persisted := Some meta; Ok ())
         ; remove = (fun _meta -> persisted := None; Ok ())
         }
       in
       let meta = make_meta keeper_name in
       let owner =
         owner_ok
           (Owner.start
              ~sw
              ~store
              ~operation_store_path
              ~now:(fun () -> 42.0)
              ~operation_runner:None
              ~on_turn_slot_released:None
              ~keeper_name
              ~initial_meta:(Some meta))
       in
       let digest = Keeper_meta_json.Snapshot_digest.of_meta meta in
       (match
          owner_ok
            (Owner.apply_meta owner (Reducer.Delete_if_snapshot digest))
        with
        | None -> ()
        | Some _ -> fail "purge fixture retained Keeper metadata");
       remove_tree keeper_dir;
       (match owner_ok (Owner.apply_meta owner (Reducer.Create meta)) with
        | Some recreated -> check string "recreated Keeper" keeper_name recreated.name
        | None -> fail "same-process recreation did not restore Keeper metadata");
       let operation_id = operation_id "kmsg-same-process-recreate" in
       ignore
         (owner_ok
            (Owner.submit_operation
               owner
               ~operation_id
               ~source:operation_source
               ~input:(operation_input "fresh request")));
       check bool
         "recreated operation store exists"
         true
         (Sys.file_exists operation_store_path);
       check bool
         "fresh operation is readable"
         true
         (Option.is_some (owner_ok (Owner.exact_operation owner operation_id))))
;;

let test_root_inventory_loads_and_extends_exactly_once () =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "owner-test"));
       let first = make_meta "inventory-first" in
       (match Keeper_meta_store.replace_snapshot config first with
        | Ok () -> ()
        | Error detail -> fail ("failed to seed owner meta: " ^ detail));
       (match Owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
        | Ok count -> check int "strict startup owner count" 1 count
        | Error error -> fail (Owner_registry.install_error_to_string error));
       let loaded =
         match Owner_registry.get ~base_path ~keeper_name:first.name with
         | Ok owner -> owner
         | Error error -> fail (Owner_registry.lookup_error_to_string error)
       in
       check bool
         "installed owner owns the v1 operation database"
         true
         (Sys.file_exists
            (Filename.concat
               (Filename.concat (Workspace.keepers_runtime_dir config) first.name)
               Keeper_chat_operation_store.database_file));
       let second = make_meta "inventory-second" in
       (match Owner_registry.create_meta ~base_path second with
        | Ok (Some committed) -> check string "dynamic owner identity" second.name committed.name
        | Ok None -> fail "dynamic owner create removed metadata"
        | Error error -> fail (Owner_registry.command_error_to_string error));
       let ensured =
         match Owner_registry.get ~base_path ~keeper_name:second.name with
         | Ok owner -> owner
         | Error error -> fail (Owner_registry.lookup_error_to_string error)
       in
       check bool
         "dynamically created owner owns the v1 operation database"
         true
         (Sys.file_exists
            (Filename.concat
               (Filename.concat (Workspace.keepers_runtime_dir config) second.name)
               Keeper_chat_operation_store.database_file));
       let loaded_again =
         match Owner_registry.get ~base_path ~keeper_name:first.name with
         | Ok owner -> owner
         | Error error -> fail (Owner_registry.lookup_error_to_string error)
       in
       check bool "lookup preserves the existing actor" true (loaded == loaded_again);
       check bool "different keeper receives a different actor" false (loaded == ensured);
       (match Owner_registry.create_meta ~base_path first with
        | Error
            (Owner_registry.Command_rejected
              (Owner.Reducer_rejected Reducer.Meta_already_exists)) ->
          ()
        | Error error -> fail ("wrong duplicate create error: " ^ Owner_registry.command_error_to_string error)
        | Ok _ -> fail "duplicate create replaced existing owner metadata");
       check int
         "dynamic owner extends inventory once"
         2
         (Owner_registry.For_testing.installed_owner_count ~base_path);
       (match Owner_registry.all_projections ~base_path with
        | Ok projections -> check int "fleet projection count" 2 (List.length projections)
       | Error error -> fail (Owner_registry.lookup_error_to_string error)))
;;

let test_agent_delegate_submits_owner_operation_without_waiting () =
  init_runtime_default_for_tests ();
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let previous_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" previous_config_dir;
      Config_dir_resolver.reset ();
      Keeper_registry.For_testing.clear ();
      remove_tree base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "owner-tool-test"));
       (* Delegate preflight reads the keeper's declared lane from its TOML;
          since #32078 a keeper without one is refused ("sandbox_profile is
          required"), so the fixture declares the lane the way an operator's
          keeper TOML does. *)
       let config_dir = Filename.concat base_path ".masc/config" in
       mkdir_p (Filename.concat config_dir "keepers");
       Unix.putenv "MASC_CONFIG_DIR" config_dir;
       Config_dir_resolver.reset ();
       let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
       write_file
         (Filename.concat keepers_dir "agent-operation-target.toml")
         "[keeper]\nname = \"agent-operation-target\"\ninstructions = \"test keeper\"\nsandbox_profile = \"docker\"\n";
       let meta = make_meta "agent-operation-target" in
       Keeper_meta_store.replace_snapshot config meta |> Result.get_ok;
       ignore
         (Keeper_registry.For_testing.register
            ~base_path
            meta.name
            meta);
       Owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config
       |> Result.get_ok
       |> ignore;
       let ctx : _ Keeper_tool_surface.context =
         { config
         ; agent_name = "agent-operation-caller"
         ; sw
         ; clock = Eio.Stdenv.clock env
         ; proc_mgr = None
         ; net = None
         ; publication_recovery_provider =
             Keeper_publication_recovery_availability.non_runtime_provider
         }
       in
       let invocation_ref =
         let request_id =
           Mcp_transport_protocol.request_id_of_yojson (`String "delegate-1")
           |> Result.get_ok
         in
         Tool_invocation_ref.external_mcp
           ~request_id
           ~session_id:"owner-tool-session"
         |> Result.get_ok
       in
       let args =
         `Assoc
           [ "target",
             `Assoc
               [ "kind", `String "keeper"
               ; "name", `String meta.name
               ]
           ; "prompt", `String "inspect owner state"
           ]
       in
       let result =
         Keeper_tool_surface_ops.handle_keeper_delegate
           ~invocation_ref
           ~submitted_by:"agent-operation-caller"
           ctx
           args
       in
       check bool "agent submit returns acceptance" true (Tool_result.is_success result);
       let data = Tool_result.data result in
       let operation_id_raw =
         Yojson.Safe.Util.(data |> member "operation_id" |> to_string)
       in
       check string "agent operation is queued" "queued"
         Yojson.Safe.Util.(data |> member "state" |> to_string);
       check bool "first agent operation is new" false
         Yojson.Safe.Util.(data |> member "existing" |> to_bool);
       let repeated =
         Keeper_tool_surface_ops.handle_keeper_delegate
           ~invocation_ref
           ~submitted_by:"agent-operation-caller"
           ctx
           args
       in
       check bool "agent retry is accepted" true (Tool_result.is_success repeated);
       let repeated_data = Tool_result.data repeated in
       check string "agent retry reuses operation id" operation_id_raw
         Yojson.Safe.Util.(repeated_data |> member "operation_id" |> to_string);
       check bool "agent retry returns existing operation" true
         Yojson.Safe.Util.(repeated_data |> member "existing" |> to_bool);
       let operation_id = operation_id operation_id_raw in
       let target =
         `Assoc
           [ "kind", `String "keeper"
           ; "name", `String meta.name
           ]
       in
       let reference =
         `Assoc
           [ "target", target
           ; "operation_id", `String operation_id_raw
           ]
       in
       let status =
         Keeper_tool_surface_ops.keeper_delegate_status_body
           ~config
           ~caller:"agent-operation-caller"
           reference
       in
       check bool "agent status reads operation" true (Tool_result.is_success status);
       check string "agent status is queued" "Queued"
         Yojson.Safe.Util.(Tool_result.data status |> member "state" |> to_string);
       let listed =
         Keeper_tool_surface_ops.keeper_delegate_list_body
           ~config
           ~caller:"agent-operation-caller"
           (`Assoc [ "target", target ])
       in
       check bool "agent list reads queued operations" true
         (Tool_result.is_success listed);
       check int "agent list has one operation" 1
         Yojson.Safe.Util.(Tool_result.data listed |> to_list |> List.length);
       let operation =
         match
           Owner_registry.exact_operation
             ~base_path
             ~keeper_name:meta.name
             operation_id
         with
         | Ok (Some operation) -> operation
         | Ok None -> fail "accepted agent operation is missing"
         | Error error -> fail (Owner_registry.command_error_to_string error)
       in
       let source =
         match Keeper_chat_operation_payload.source_of_json operation.source with
         | Ok source -> source
         | Error detail -> fail detail
       in
       check bool "agent operation keeps agent surface" true
         (match source.surface with Surface_ref.Agent -> true | _ -> false);
       let input =
         match operation.input with
         | None -> fail "queued agent operation lost its input"
         | Some input ->
           (match Keeper_chat_operation_payload.input_of_json input with
            | Ok input -> input
            | Error detail -> fail detail)
       in
       check string "agent operation keeps prompt" "inspect owner state" input.message;
       let cancelled =
         Keeper_tool_surface_ops.keeper_delegate_cancel_body
           ~config
           ~caller:"agent-operation-caller"
           reference
       in
       check bool "agent cancel settles queued operation" true
         (Tool_result.is_success cancelled);
       check string "agent cancel is terminal" "Cancelled"
         Yojson.Safe.Util.(Tool_result.data cancelled |> member "state" |> to_string);
       let listed_after_cancel =
         Keeper_tool_surface_ops.keeper_delegate_list_body
           ~config
           ~caller:"agent-operation-caller"
           (`Assoc [ "target", target ])
       in
       check int "cancelled operation leaves queued list" 0
         Yojson.Safe.Util.(Tool_result.data listed_after_cancel |> to_list |> List.length))
;;

let test_connector_submit_uses_owner_operation_idempotency () =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let clock = Eio.Stdenv.clock env in
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "connector-owner-test"));
       let meta = make_meta "connector-owner" in
       (match Keeper_meta_store.replace_snapshot config meta with
        | Ok () -> ()
        | Error detail -> fail detail);
       (match Owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
        | Ok 1 -> ()
        | Ok count -> failf "unexpected owner count %d" count
        | Error error -> fail (Owner_registry.install_error_to_string error));
       let continuation =
         match
           Keeper_continuation_channel.discord
             ~guild_id:(Some "guild-1")
             ~channel_id:"channel-1"
             ~parent_channel_id:None
             ~thread_id:None
             ~user_id:"user-1"
             ()
         with
         | Ok continuation -> continuation
         | Error detail -> fail detail
       in
       let delivery : Gate_keeper_backend.connector_delivery =
         { continuation_channel = continuation
         ; surface =
             Surface_ref.Discord
               { guild_id = Some "guild-1"
               ; channel_id = "channel-1"
               ; channel_name = None
               ; parent_channel_id = None
               ; thread_id = None
               }
         ; conversation_id = Some "discord:guild-1:channel:channel-1"
         ; external_message_id = Some "message-1"
         ; workspace_id = Some "guild-1"
         }
       in
       let submit content =
         Gate_keeper_backend.accept_connector
           ~delivery
           ~clock
           ~config
           ~channel:"discord"
           ~channel_user_id:"user-1"
           ~channel_user_name:"User One"
           ~channel_workspace_id:"guild-1"
           ~keeper_name:meta.name
           ~idempotency_key:"discord-msg-message-1"
           ~metadata:[]
           ~content
       in
       let accepted_request_id = function
         | Gate_protocol.Reply { message_request = Some request; _ } -> request.request_id
         | Gate_protocol.Reply { message_request = None; _ } -> fail "missing operation ACK"
         | Keeper_error_result detail -> fail detail
         | Unavailable_result -> fail "owner unexpectedly unavailable"
       in
       check string
         "connector request id is operation id"
         "discord-msg-message-1"
         (accepted_request_id (submit "hello"));
       check string
         "same connector retry deduplicates"
         "discord-msg-message-1"
         (accepted_request_id (submit "hello"));
       (match submit "different" with
        | Gate_protocol.Keeper_error_result _ -> ()
        | Reply _ | Unavailable_result -> fail "different payload reused operation id");
       let id = operation_id "discord-msg-message-1" in
       match Owner_registry.exact_operation ~base_path ~keeper_name:meta.name id with
       | Ok (Some operation) ->
         check bool "connector operation remains queued" true
           (match operation.state with Chat_operation.Queued -> true | _ -> false)
       | Ok None -> fail "connector operation disappeared"
       | Error error -> fail (Owner_registry.command_error_to_string error))
;;

let test_root_inventory_isolates_invalid_owner_snapshots () =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "owner-isolation-test"));
       let valid = make_meta "inventory-valid" in
       Keeper_meta_store.replace_snapshot config valid |> Result.get_ok;
       let keepers_dir = Workspace.keepers_runtime_dir config in
       let operation_corrupt = make_meta "inventory-operation-corrupt" in
       Keeper_meta_store.replace_snapshot config operation_corrupt |> Result.get_ok;
       let operation_corrupt_dir =
         Filename.concat keepers_dir operation_corrupt.name
       in
       Unix.mkdir operation_corrupt_dir 0o755;
       Unix.mkdir
         (Filename.concat
            operation_corrupt_dir
            Keeper_chat_operation_store.database_file)
         0o755;
       (* Decodes to nothing: the store reads it as absent (#29610). *)
       Yojson.Safe.to_file
         (Filename.concat keepers_dir "inventory-corrupt.json")
         (`Assoc []);
       (* Cannot be read at all: a directory where the file should be. *)
       let unreadable_path = Filename.concat keepers_dir "inventory-unreadable.json" in
       Unix.mkdir unreadable_path 0o755;
       Yojson.Safe.to_file
         (Filename.concat keepers_dir "inventory-path-name.json")
         (Keeper_meta_json.meta_to_json (make_meta "inventory-payload-name"));
       (match Owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
        | Ok count -> check int "only valid owner starts" 1 count
        | Error error -> fail (Owner_registry.install_error_to_string error));
       (match Owner_registry.get ~base_path ~keeper_name:valid.name with
        | Ok _ -> ()
        | Error error -> fail (Owner_registry.lookup_error_to_string error));
       List.iter
         (fun keeper_name ->
            match Owner_registry.get ~base_path ~keeper_name with
            | Error (Owner_registry.Owner_unavailable _) -> ()
            | Error error -> fail (Owner_registry.lookup_error_to_string error)
            | Ok _ -> fail ("invalid owner started: " ^ keeper_name))
         [ "inventory-unreadable"
         ; "inventory-path-name"
         ; "inventory-operation-corrupt"
         ];
       List.iter
         (fun keeper_name ->
            match Owner_registry.get ~base_path ~keeper_name with
            | Error (Owner_registry.Owner_not_found _) -> ()
            | Error error ->
              fail
                ("absent name was fenced: "
                 ^ Owner_registry.lookup_error_to_string error)
            | Ok _ -> fail ("absent name gained an owner: " ^ keeper_name))
         [ "inventory-corrupt"; "inventory-payload-name" ];
       (match
          Owner_registry.create_meta
            ~base_path
            (make_meta "inventory-unreadable")
        with
        | Error
            (Owner_registry.Command_lookup_failed
              (Owner_registry.Owner_unavailable _)) ->
          ()
        | Error error -> fail (Owner_registry.command_error_to_string error)
        | Ok _ -> fail "unreadable durable owner was overwritten as a new Keeper");
       check bool
         "the unreadable path is left as it was"
         true
         (Sys.is_directory unreadable_path);
       (match
          Owner_registry.create_meta
            ~base_path
            (make_meta "inventory-corrupt")
        with
        | Ok (Some committed) ->
          check string "absent name is created in place" "inventory-corrupt" committed.name
        | Ok None -> fail "create of an absent name removed metadata"
        | Error error -> fail (Owner_registry.command_error_to_string error));
       (match Keeper_meta_store.read_meta config "inventory-corrupt" with
        | Ok (Some persisted) ->
          check string
            "the undecodable file is replaced by the created snapshot"
            "inventory-corrupt"
            persisted.name
        | Ok None -> fail "created snapshot was not persisted"
        | Error detail -> fail detail);
       check int
         "invalid snapshots do not split owner identity"
         2
         (Owner_registry.For_testing.installed_owner_count ~base_path))
;;

(* #29708: the inventory is installed before declared keepers are
   materialised. A persisted meta this binary cannot decode reads as absent
   (#29610); fencing that name made [create_meta] refuse the materialisation
   with [Owner_unavailable] until the file was stripped by hand and the
   process restarted. *)
let test_root_inventory_reads_undecodable_meta_as_absent_and_boot_rematerializes () =
  init_runtime_default_for_tests ();
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let name = "inventory-undecodable-declared" in
  let previous_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" previous_config_dir;
      Config_dir_resolver.reset ();
      Keeper_registry.For_testing.clear ();
      Keeper_runtime.reset_test_state base_path;
      remove_tree base_path)
    (fun () ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "owner-boot-test"));
       let config_dir = Filename.concat base_path ".masc/config" in
       mkdir_p (Filename.concat config_dir "keepers");
       Unix.putenv "MASC_CONFIG_DIR" config_dir;
       Config_dir_resolver.reset ();
       let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
       write_file
         (Filename.concat keepers_dir (name ^ ".toml"))
         (Printf.sprintf
            "[keeper]\nname = \"%s\"\ninstructions = \"test keeper\"\nsandbox_profile = \"docker\"\n"
            name);
       Keeper_meta_store.replace_snapshot config (make_meta name) |> Result.get_ok;
       let meta_path = Keeper_types_profile.keeper_meta_path config name in
       let undecodable =
         `Assoc
           (Yojson.Safe.Util.to_assoc (Yojson.Safe.from_file meta_path)
            @ [ "last_compaction_check_ts", `Float 0. ])
       in
       Yojson.Safe.to_file meta_path undecodable;
       let expected_warn =
         Printf.sprintf
           "keeper meta unreadable at %s, treating as absent (accumulated \
            counters in it are lost; the declaration re-materialises the \
            keeper): invalid current keeper meta: fields outside the current \
            schema: last_compaction_check_ts; runtime reset required"
           meta_path
       in
       let baseline = latest_log_seq () in
       Eio.Switch.run @@ fun sw ->
       (match Owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
        | Ok count -> check int "an undecodable meta installs no owner" 0 count
        | Error error -> fail (Owner_registry.install_error_to_string error));
       (match Owner_registry.get ~base_path ~keeper_name:name with
        | Error (Owner_registry.Owner_not_found _) -> ()
        | Error error ->
          fail
            ("undecodable meta was fenced: "
             ^ Owner_registry.lookup_error_to_string error)
        | Ok _ -> fail "undecodable meta started an owner");
       let ctx : _ Keeper_types_profile.context =
         { config
         ; agent_name = "owner-boot-test"
         ; sw
         ; clock = Eio.Stdenv.clock env
         ; proc_mgr = None
         ; net = None
         ; publication_recovery_provider =
             Masc_test_deps.non_runtime_publication_recovery_provider
         }
       in
       Fun.protect
         ~finally:(fun () -> Keeper_runtime.stop_keepalive ~base_path name)
         (fun () ->
            (match Keeper_runtime.load_or_materialize_boot_meta ctx name with
             | Error detail ->
               fail ("boot did not re-materialise the declared keeper: " ^ detail)
             | Ok resolution ->
               check bool
                 "declared keeper is re-materialised at boot"
                 true
                 resolution.Keeper_runtime.materialized;
               check string
                 "the re-materialised keeper is the declared one"
                 name
                 resolution.Keeper_runtime.meta.name);
            (match Owner_registry.get ~base_path ~keeper_name:name with
             | Ok _ -> ()
             | Error error ->
               fail
                 ("re-materialised keeper has no owner: "
                  ^ Owner_registry.lookup_error_to_string error));
            let warns =
              Log.Ring.recent
                ~limit:1000
                ~module_filter:"Keeper"
                ~since_seq:baseline
                ~order:`Oldest_first
                ()
              |> List.filter (fun (entry : Log.Ring.entry) ->
                   entry.level = Log.Warn && String.equal entry.message expected_warn)
            in
            check int "the loss is named once, in the store's WARN" 1 (List.length warns);
            (match Keeper_meta_store.read_meta config name with
             | Ok (Some persisted) ->
               check bool
                 "the re-materialised snapshot replaced the undecodable file"
                 false
                 (Keeper_id.Trace_id.equal
                    persisted.runtime.trace_id
                    (make_meta name).runtime.trace_id)
             | Ok None -> fail "re-materialised meta was not persisted"
             | Error detail -> fail detail);
            check bool
              "no boot failure is recorded"
              true
              (Option.is_none (Keeper_runtime.boot_meta_failure_for ~base_path ~name))))
;;

let test_registry_reads_owner_atomic_projection () =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      remove_tree base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "owner-projection-test"));
       let initial = make_meta "atomic-projection" in
       Keeper_meta_store.replace_snapshot config initial |> Result.get_ok;
       Owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config
       |> Result.get_ok
       |> ignore;
       let stale_entry =
         Keeper_registry.For_testing.register ~base_path initial.name initial
       in
       (match
          Owner_registry.apply_meta
            ~base_path
            ~keeper_name:initial.name
            (Add_usage (usage_delta ()))
        with
        | Ok (Some _) -> ()
        | Ok None -> fail "owner usage commit removed metadata"
        | Error error -> fail (Owner_registry.command_error_to_string error));
       Keeper_registry.For_testing.unsafe_put_entry
         ~base_path
         initial.name
         stale_entry;
       match Keeper_registry.get ~base_path initial.name with
       | Some entry ->
         check
           int
           "registry read overlays owner Atomic projection"
           1
           entry.meta.runtime.usage.total_turns
       | None -> fail "owner-backed registry entry disappeared")
;;

let test_lifecycle_reservation_remains_owner_admission_authority () =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "owner-reservation-test"));
       let meta = make_meta "inventory-reserved" in
       (match Keeper_meta_store.replace_snapshot config meta with
        | Ok () -> ()
        | Error detail -> fail ("failed to seed reserved owner meta: " ^ detail));
       (match Owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
        | Ok count -> check int "reserved owner count" 1 count
        | Error error -> fail (Owner_registry.install_error_to_string error));
       let token =
         match
           Keeper_lifecycle_reservation.acquire
             ~base_path
             ~keeper_name:meta.name
             ~purpose:Keeper_lifecycle_reservation.Paused_work_disposition
         with
         | Ok token -> token
         | Error _ -> fail "failed to acquire lifecycle reservation"
       in
       let command =
         Reducer.Set_autoboot { enabled = true; updated_at = "reserved-command" }
       in
       (match Owner_registry.apply_meta ~base_path ~keeper_name:meta.name command with
        | Error (Owner_registry.Command_lifecycle_reserved _) -> ()
        | Error error ->
          fail
            ("wrong reservation rejection: "
             ^ Owner_registry.command_error_to_string error)
        | Ok _ -> fail "unowned command crossed lifecycle reservation");
       (match
          Owner_registry.apply_meta
            ~lifecycle_token:token
            ~base_path
            ~keeper_name:meta.name
            command
        with
        | Ok (Some updated) -> check bool "reservation owner committed" true updated.autoboot_enabled
        | Ok None -> fail "reservation owner removed metadata"
        | Error error -> fail (Owner_registry.command_error_to_string error));
       match Keeper_lifecycle_reservation.release token with
       | Keeper_lifecycle_reservation.Released -> ()
       | outcome ->
         fail
           ("failed to release lifecycle reservation: "
            ^ Keeper_lifecycle_reservation.release_outcome_to_string outcome))
;;

let test_create_waits_for_lifecycle_admission_before_installing_owner () =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "owner-create-reservation-test"));
       (match Owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
        | Ok count -> check int "empty owner inventory" 0 count
        | Error error -> fail (Owner_registry.install_error_to_string error));
       let meta = make_meta "create-reserved" in
       let token =
         match
           Keeper_lifecycle_reservation.acquire
             ~base_path
             ~keeper_name:meta.name
             ~purpose:Keeper_lifecycle_reservation.Paused_work_disposition
         with
         | Ok token -> token
         | Error _ -> fail "failed to reserve create identity"
       in
       (match Owner_registry.create_meta ~base_path meta with
        | Error (Owner_registry.Command_lifecycle_reserved _) -> ()
        | Error error -> fail (Owner_registry.command_error_to_string error)
        | Ok _ -> fail "create crossed lifecycle reservation");
       check int
         "rejected create installs no empty owner"
         0
         (Owner_registry.For_testing.installed_owner_count ~base_path);
       (match Keeper_lifecycle_reservation.release token with
        | Keeper_lifecycle_reservation.Released -> ()
        | outcome ->
          fail
            ("failed to release create reservation: "
             ^ Keeper_lifecycle_reservation.release_outcome_to_string outcome));
       (match Owner_registry.create_meta ~base_path meta with
        | Ok (Some committed) -> check string "admitted create" meta.name committed.name
        | Ok None -> fail "admitted create removed metadata"
        | Error error -> fail (Owner_registry.command_error_to_string error));
       check int
         "admitted create installs one owner"
         1
         (Owner_registry.For_testing.installed_owner_count ~base_path))
;;

let () =
  run
    "keeper owner"
    [ ( "reducer"
      , [ test_case
            "additive usage and pause are exact"
            `Quick
            test_pure_reducer_adds_deltas_and_preserves_pause
        ; test_case
            "profile update preserves runtime state"
            `Quick
            test_profile_update_preserves_owner_runtime_state
        ] )
    ; ( "payload"
      , [ test_case
            "connector route is exact and strict"
            `Quick
            test_operation_payload_preserves_connector_route
        ] )
    ; ( "actor"
      , [ test_case
            "concurrent commands are exact"
            `Quick
            test_actor_concurrent_commands_are_exact
        ; test_case
            "mailbox backpressures without drop"
            `Quick
            test_mailbox_backpressures_without_drop
        ; test_case
            "enqueued request settles before cancellation"
            `Quick
            test_enqueued_request_settles_before_cancellation_unwinds
        ; test_case
            "store failure fences mutations"
            `Quick
            test_store_failure_fences_mutations
        ; test_case
            "visible publication is not durable success"
            `Quick
            test_visible_post_publish_failure_is_not_durable_success
        ; test_case
            "identity and delete guards"
            `Quick
            test_identity_and_delete_guards
        ; test_case
            "shutdown releases full mailbox requests"
            `Quick
            test_shutdown_releases_full_mailbox_requests
        ; test_case
            "stopping rejects new commands"
            `Quick
            test_stopping_rejects_new_commands
        ; test_case
            "stopping cancels and joins active child"
            `Quick
            test_stopping_cancels_and_joins_active_child
        ; test_case
            "stopping cancels and joins autonomous child"
            `Quick
            test_stopping_cancels_and_joins_autonomous_child
        ; test_case
            "chat lane holder blocks autonomous admission"
            `Quick
            test_chat_lane_holder_blocks_autonomous_admission
        ; test_case
            "turn slot release signals availability"
            `Quick
            test_turn_slot_release_signals_availability
        ; test_case
            "uncontested turn end signals nothing"
            `Quick
            test_uncontested_turn_end_signals_nothing
        ; test_case
            "operation lifecycle is durable and projected"
            `Quick
            test_operation_lifecycle_is_durable_and_projected
        ; test_case
            "health observer tracks Owner projection mutations"
            `Quick
            test_health_state_change_observer_tracks_owner_projections
        ; test_case
            "health observer failure is isolated"
            `Quick
            test_health_state_change_observer_failure_is_isolated
        ; test_case
            "operation executor claims latest input and drains FIFO"
            `Quick
            test_operation_executor_claims_latest_input_and_drains_fifo
        ; test_case
            "operation executor exception is terminal and next runs"
            `Quick
            test_operation_executor_exception_is_terminal_and_next_runs
        ; test_case
            "operator interrupt settles as typed cancel"
            `Quick
            test_operator_interrupt_settles_as_typed_cancel
        ; test_case
            "stale exact interrupt cannot cancel replacement"
            `Quick
            test_exact_operation_interrupt_cannot_cancel_its_replacement
        ; test_case
            "is_operator_interrupt unwraps every shape"
            `Quick
            test_is_operator_interrupt_unwraps_every_shape
        ; test_case
            "combined-shape operator interrupt settles as typed cancel"
            `Quick
            test_operator_interrupt_combined_shape_settles_as_typed_cancel
        ; test_case
            "paused owner preserves queue until resume"
            `Quick
            test_paused_owner_preserves_queue_until_resume
        ; test_case
            "pause rechecks pending claim admission"
            `Quick
            test_pause_rechecks_pending_claim_admission
        ; test_case
            "startup interrupts Running without requeue"
            `Quick
            test_startup_interrupts_running_without_requeue
        ; test_case
            "startup Queued waits for runner readiness"
            `Quick
            test_startup_queued_waits_for_runner_readiness
        ; test_case
            "operation store failure fences owner mutations"
            `Quick
            test_operation_store_failure_fences_owner_mutations
        ; test_case
            "Keeper owners do not cross-block"
            `Quick
            test_keeper_owners_do_not_cross_block
        ; test_case
            "Owner linearizes autonomous and chat children"
            `Quick
            test_owner_linearizes_autonomous_and_chat_children
        ; test_case
            "unready chat queue does not block autonomous"
            `Quick
            test_unready_chat_queue_does_not_block_autonomous
        ; test_case
            "Owner shutdown linearizes and awaits child"
            `Quick
            test_owner_shutdown_linearizes_and_awaits_child
        ; test_case
            "Owner shutdown restore and transition are typed"
            `Quick
            test_owner_shutdown_restore_and_transition_are_typed
        ; test_case
            "distinct Owner autonomous children do not cross-block"
            `Quick
            test_autonomous_children_of_distinct_owners_do_not_cross_block
        ; test_case
            "root inventory loads and extends exactly once"
            `Quick
            test_root_inventory_loads_and_extends_exactly_once
        ; test_case
            "same-process recreate reopens purged operation store"
            `Quick
            test_same_process_recreate_reopens_purged_operation_store
        ; test_case
            "agent delegate submits owner operation without waiting"
            `Quick
            test_agent_delegate_submits_owner_operation_without_waiting
        ; test_case
            "connector submit is owner-idempotent"
            `Quick
            test_connector_submit_uses_owner_operation_idempotency
        ; test_case
            "root inventory isolates invalid owner snapshots"
            `Quick
            test_root_inventory_isolates_invalid_owner_snapshots
        ; test_case
            "root inventory reads an undecodable meta as absent and boot re-materialises it"
            `Quick
            test_root_inventory_reads_undecodable_meta_as_absent_and_boot_rematerializes
        ; test_case
            "registry reads owner Atomic projection"
            `Quick
            test_registry_reads_owner_atomic_projection
        ; test_case
            "lifecycle reservation gates owner commands"
            `Quick
            test_lifecycle_reservation_remains_owner_admission_authority
        ; test_case
            "create authorizes before owner installation"
            `Quick
            test_create_waits_for_lifecycle_admission_before_installing_owner
        ] )
    ]
;;
