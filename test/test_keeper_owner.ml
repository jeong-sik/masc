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

let start_owner_with_executor
      ~sw
      ~store
      ~operation_executor
      ~keeper_name
      ~initial_meta
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
    ~operation_executor
    ~keeper_name
    ~initial_meta
;;

let start_owner ~sw ~store ~keeper_name ~initial_meta =
  start_owner_with_executor
    ~sw
    ~store
    ~operation_executor:None
    ~keeper_name
    ~initial_meta
;;

let operation_id value =
  match Chat_operation.Operation_id.of_string value with
  | Ok operation_id -> operation_id
  | Error detail -> fail detail
;;

let operation_source = `Assoc [ "kind", `String "dashboard" ]
let operation_input text = `Assoc [ "message", `String text ]

let test_operation_payload_preserves_connector_route () =
  let continuation =
    match
      Keeper_continuation_channel.discord
        ~guild_id:(Some "guild-1")
        ~channel_id:"thread-7"
        ~parent_channel_id:(Some "channel-3")
        ~thread_id:(Some "thread-7")
        ~user_id:"user-9"
    with
    | Ok continuation -> continuation
    | Error detail -> fail detail
  in
  let surface =
    Surface_ref.Discord
      { guild_id = Some "guild-1"
      ; channel_id = "thread-7"
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

let test_reducer_rejects_invalid_compaction_numbers () =
  let state =
    match Reducer.create ~keeper_name:"numbers" (Some (make_meta "numbers")) with
    | Ok state -> state
    | Error error -> fail (Reducer.error_to_string error)
  in
  let command =
    Reducer.Record_compaction
      { count_delta = 1
      ; at = Float.nan
      ; before_tokens = -1
      ; after_tokens = 0
      ; checked_at = 42.0
      ; decision = Keeper_meta_contract.Compaction_runtime_decision "test"
      ; updated_at = "invalid"
      }
  in
  match Reducer.apply_meta state command with
  | Error (Reducer.Invalid_delta _) -> ()
  | Error error -> fail ("wrong numeric error: " ^ Reducer.error_to_string error)
  | Ok _ -> fail "invalid compaction numbers were accepted"
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
    ; allowed_paths = [ "/tmp/profile" ]
    ; mention_targets = [ "profile-target" ]
    ; proactive_enabled = true
    ; max_context_override = Some 32_000
    ; active_goal_ids = [ "goal-profile" ]
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
  check int
    "profile update preserves generation"
    current.runtime.nonce
    committed.runtime.nonce;
  check bool "profile update changes autoboot" true committed.autoboot_enabled
;;

let test_turn_delta_preserves_concurrent_compaction_observation () =
  let before = make_meta "turn-delta-compaction" in
  let before_usage = before.runtime.usage in
  let after =
    { before with
      runtime =
        { before.runtime with
          usage =
            ({ total_turns = before_usage.total_turns + 1
            ; total_input_tokens = before_usage.total_input_tokens + 2
            ; total_output_tokens = before_usage.total_output_tokens + 3
            ; total_tokens = before_usage.total_tokens + 5
            ; total_cost_usd = before_usage.total_cost_usd +. 0.25
            ; last_turn_ts = 42.0
            ; last_input_tokens = 2
            ; last_output_tokens = 3
            ; last_total_tokens = 5
            ; last_usage_reported_at = Some 42.0
            ; last_latency_ms = 7
            } : Keeper_meta_contract.usage_metrics)
        }
    ; updated_at = "turn-finished"
    }
  in
  let delta =
    match Reducer.turn_runtime_delta_of_snapshots ~before ~after with
    | Ok delta -> delta
    | Error error -> fail (Reducer.error_to_string error)
  in
  let state =
    match Reducer.create ~keeper_name:before.name (Some before) with
    | Ok state -> state
    | Error error -> fail (Reducer.error_to_string error)
  in
  let state =
    reducer_ok
      (Reducer.apply_meta
         state
         (Record_compaction
            { count_delta = 1
            ; at = 99.0
            ; before_tokens = 1_000
            ; after_tokens = 500
            ; checked_at = 99.0
            ; decision = Keeper_meta_contract.Compaction_runtime_decision "committed"
            ; updated_at = "compacted"
            }))
  in
  let state = reducer_ok (Reducer.apply_meta state (Commit_turn_runtime delta)) in
  let committed = Option.get (Reducer.projection state).meta in
  check int "turn delta still commits usage" 1 committed.runtime.usage.total_turns;
  check int "concurrent compaction count is retained" 1 committed.runtime.compaction_rt.count;
  check
    (float 0.0)
    "stale turn snapshot cannot rewind compaction observation"
    99.0
    committed.runtime.compaction_rt.last_ts
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
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~operation_executor:(Some operation_executor)
         ~keeper_name:"stopping-active-child"
         ~initial_meta:(Some (make_meta "stopping-active-child")))
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
  match operation.state with
  | Chat_operation.Failed { failure = { kind; _ }; _ } ->
    check string
      "stopped active child is terminal"
      "Turn_cancelled"
      (Chat_operation.failure_kind_to_string kind)
  | state ->
    fail
      ("stopping returned before terminal persistence: "
       ^ Chat_operation.state_to_string state)
;;

let test_stopping_cancels_and_joins_autonomous_child () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let child_started, resolve_child_started = Eio.Promise.create () in
  let caller_done, resolve_caller_done = Eio.Promise.create () in
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
    (try
       ignore
         (Owner.run_autonomous_if_idle owner (fun () ->
            Eio.Promise.resolve resolve_child_started ();
            Eio.Promise.await never))
     with
     | _ -> ());
    Eio.Promise.resolve resolve_caller_done ());
  Eio.Promise.await child_started;
  ignore (owner_ok (Owner.begin_stopping owner));
  Eio.Promise.await caller_done;
  check bool
    "stopping clears autonomous projection"
    true
    (Option.is_none (Owner.turn_in_flight owner))
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
         ~initial_meta:(Some (make_meta "operation-executor")))
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
         ~initial_meta:(Some (make_meta "operation-exception")))
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
              ~operation_executor:None
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
         ~initial_meta:(Some (make_meta "single-turn-owner")))
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
       (match Owner_registry.install_from_store ~sw ~operation_executor:None config with
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
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "owner-tool-test"));
       let meta = make_meta "agent-operation-target" in
       Keeper_meta_store.replace_snapshot config meta |> Result.get_ok;
       Owner_registry.install_from_store ~sw ~operation_executor:None config
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
       (match Owner_registry.install_from_store ~sw ~operation_executor:None config with
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
       Yojson.Safe.to_file
         (Filename.concat keepers_dir "inventory-corrupt.json")
         (`Assoc []);
       Yojson.Safe.to_file
         (Filename.concat keepers_dir "inventory-path-name.json")
         (Keeper_meta_json.meta_to_json (make_meta "inventory-payload-name"));
       (match Owner_registry.install_from_store ~sw ~operation_executor:None config with
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
         [ "inventory-corrupt"
         ; "inventory-path-name"
         ; "inventory-operation-corrupt"
         ];
       (match
          Owner_registry.get ~base_path ~keeper_name:"inventory-payload-name"
        with
        | Error (Owner_registry.Owner_not_found _) -> ()
        | Error error -> fail (Owner_registry.lookup_error_to_string error)
        | Ok _ -> fail "payload-only identity unexpectedly gained an owner");
       (match
          Owner_registry.create_meta
            ~base_path
            (make_meta "inventory-corrupt")
        with
        | Error
            (Owner_registry.Command_lookup_failed
              (Owner_registry.Owner_unavailable _)) ->
          ()
        | Error error -> fail (Owner_registry.command_error_to_string error)
        | Ok _ -> fail "corrupt durable owner was overwritten as a new Keeper");
       check int
         "invalid snapshots do not split owner identity"
         1
         (Owner_registry.For_testing.installed_owner_count ~base_path))
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
       Owner_registry.install_from_store ~sw ~operation_executor:None config
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
       (match Owner_registry.install_from_store ~sw ~operation_executor:None config with
        | Ok count -> check int "reserved owner count" 1 count
        | Error error -> fail (Owner_registry.install_error_to_string error));
       let token =
         match
           Keeper_lifecycle_reservation.acquire
             ~base_path
             ~keeper_name:meta.name
             ~expected_generation:meta.runtime.nonce
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
       (match Owner_registry.install_from_store ~sw ~operation_executor:None config with
        | Ok count -> check int "empty owner inventory" 0 count
        | Error error -> fail (Owner_registry.install_error_to_string error));
       let meta = make_meta "create-reserved" in
       let token =
         match
           Keeper_lifecycle_reservation.acquire
             ~base_path
             ~keeper_name:meta.name
             ~expected_generation:0
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
            "invalid compaction numbers are rejected"
            `Quick
            test_reducer_rejects_invalid_compaction_numbers
          ; test_case
            "profile update preserves runtime state"
            `Quick
            test_profile_update_preserves_owner_runtime_state
          ; test_case
              "turn delta preserves concurrent observations"
              `Quick
              test_turn_delta_preserves_concurrent_compaction_observation
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
            "operation lifecycle is durable and projected"
            `Quick
            test_operation_lifecycle_is_durable_and_projected
        ; test_case
            "operation executor claims latest input and drains FIFO"
            `Quick
            test_operation_executor_claims_latest_input_and_drains_fifo
        ; test_case
            "operation executor exception is terminal and next runs"
            `Quick
            test_operation_executor_exception_is_terminal_and_next_runs
        ; test_case
            "startup interrupts Running without requeue"
            `Quick
            test_startup_interrupts_running_without_requeue
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
