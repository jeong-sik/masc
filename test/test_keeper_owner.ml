open Alcotest
open Masc

module Reducer = Keeper_owner_reducer
module Owner = Keeper_owner
module Owner_registry = Keeper_owner_registry

exception Synthetic_child_cancel

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

let test_actor_concurrent_commands_are_exact () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    owner_ok
      (Owner.start
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
      (Owner.start
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

let rec await_idle clock owner remaining =
  if remaining = 0
  then fail "owner did not return to idle"
  else
    match (Owner.projection owner).running_operation_id with
    | None -> ()
    | Some _ ->
      Eio.Time.sleep clock 0.001;
      await_idle clock owner (remaining - 1)
;;

let test_child_isolation_and_per_keeper_parallelism () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let store = { Owner.replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) } in
  let owner_a =
    owner_ok
      (Owner.start ~sw ~store ~keeper_name:"a" ~initial_meta:(Some (make_meta "a")))
  in
  let owner_b =
    owner_ok
      (Owner.start ~sw ~store ~keeper_name:"b" ~initial_meta:(Some (make_meta "b")))
  in
  let child_a_started, resolve_child_a_started = Eio.Promise.create () in
  let release_child_a, resolve_release_child_a = Eio.Promise.create () in
  (match
     owner_ok
       (Owner.start_turn owner_a ~operation_id:"op-a" ~run:(fun _turn_sw ->
          Eio.Promise.resolve resolve_child_a_started ();
          Eio.Promise.await release_child_a))
   with
   | Owner.Started _ -> ()
   | Busy _ -> fail "owner a unexpectedly busy");
  Eio.Promise.await child_a_started;
  (match
     owner_ok
       (Owner.start_turn owner_a ~operation_id:"op-a-2" ~run:(fun _ -> ()))
   with
   | Busy { running_operation_id } ->
     check string "busy identifies current operation" "op-a" running_operation_id
   | Started _ -> fail "second turn started concurrently on owner a");
  let child_b_ran = Atomic.make false in
  (match
     owner_ok
       (Owner.start_turn owner_b ~operation_id:"op-b" ~run:(fun _ ->
          Atomic.set child_b_ran true))
   with
   | Started _ -> ()
   | Busy _ -> fail "independent owner b was blocked by owner a");
  await_idle (Eio.Stdenv.clock env) owner_b 1_000;
  check bool "independent keeper ran concurrently" true (Atomic.get child_b_ran);
  ignore
    (owner_ok
       (Owner.apply_meta
          owner_a
          (Set_autoboot { enabled = true; updated_at = "while-running" })));
  check bool
    "actor processed metadata while child was running"
    true
    (Option.get (Owner.projection owner_a).meta).autoboot_enabled;
  Eio.Promise.resolve resolve_release_child_a ();
  await_idle (Eio.Stdenv.clock env) owner_a 1_000;
  let failed_handle =
    match
     owner_ok
       (Owner.start_turn owner_a ~operation_id:"op-exn" ~run:(fun _ ->
          raise (Failure "synthetic child failure")))
    with
    | Started handle -> handle
    | Busy _ -> fail "owner remained busy after first child"
  in
  (match Owner.await_turn failed_handle with
   | Owner.Turn_failed detail ->
     check bool
       "typed terminal includes child failure"
       true
       (String.length detail > 0)
   | Turn_succeeded | Turn_cancelled -> fail "child exception lost typed failure");
  await_idle (Eio.Stdenv.clock env) owner_a 1_000;
  ignore (owner_ok (Owner.exact_projection owner_a))
;;

let test_store_failure_is_precommit () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    owner_ok
      (Owner.start
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
    (Option.get (Owner.projection owner).meta).autoboot_enabled
;;

let test_identity_and_running_lifecycle_guards () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let store = { Owner.replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) } in
  let empty =
    owner_ok (Owner.start ~sw ~store ~keeper_name:"empty" ~initial_meta:None)
  in
  (match Owner.start_turn empty ~operation_id:"missing" ~run:(fun _ -> ()) with
   | Error (Owner.Reducer_rejected Reducer.Meta_missing) -> ()
   | Error error -> fail ("wrong missing-meta error: " ^ Owner.error_to_string error)
   | Ok _ -> fail "metadata-free owner admitted a turn");
  (match Owner.apply_meta empty (Create (make_meta "other")) with
   | Error (Owner.Reducer_rejected (Reducer.Keeper_identity_mismatch _)) -> ()
   | Error error -> fail ("wrong identity error: " ^ Owner.error_to_string error)
   | Ok _ -> fail "owner accepted metadata for another Keeper");
  ignore (owner_ok (Owner.apply_meta empty (Create (make_meta "empty"))));
  let started, resolve_started = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let handle =
    match
      owner_ok
        (Owner.start_turn empty ~operation_id:"running" ~run:(fun _ ->
           Eio.Promise.resolve resolve_started ();
           Eio.Promise.await release))
    with
    | Started handle -> handle
    | Busy _ -> fail "newly created owner was busy"
  in
  Eio.Promise.await started;
  (match Owner.apply_meta empty Delete with
   | Error (Owner.Reducer_rejected (Reducer.Delete_while_running "running")) -> ()
   | Error error -> fail ("wrong delete guard error: " ^ Owner.error_to_string error)
   | Ok _ -> fail "running owner allowed metadata deletion");
  Eio.Promise.resolve resolve_release ();
  (match Owner.await_turn handle with
   | Owner.Turn_succeeded -> ()
   | Turn_failed _ | Turn_cancelled -> fail "successful child did not settle successfully");
  ignore (owner_ok (Owner.apply_meta empty Delete));
  check bool "delete clears metadata" true (Option.is_none (Owner.projection empty).meta)
;;

let test_child_cancellation_releases_slot () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    owner_ok
      (Owner.start
         ~sw
         ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
         ~keeper_name:"cancel"
         ~initial_meta:(Some (make_meta "cancel")))
  in
  let handle =
    match
      owner_ok
        (Owner.start_turn owner ~operation_id:"cancelled" ~run:(fun turn_sw ->
           Eio.Switch.fail turn_sw Synthetic_child_cancel))
    with
    | Started handle -> handle
    | Busy _ -> fail "cancellation test owner was busy"
  in
  (match Owner.await_turn handle with
   | Owner.Turn_cancelled -> ()
   | Turn_succeeded | Turn_failed _ -> fail "child cancellation lost typed terminal");
  await_idle (Eio.Stdenv.clock env) owner 1_000;
  match
    owner_ok
      (Owner.start_turn owner ~operation_id:"after-cancel" ~run:(fun _ -> ()))
  with
  | Started handle ->
    (match Owner.await_turn handle with
     | Turn_succeeded -> ()
     | Turn_failed _ | Turn_cancelled -> fail "owner did not recover after cancellation")
  | Busy _ -> fail "child cancellation leaked the running slot"
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
          (Owner.start
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
      (Owner.start
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
   | Ok _ -> fail "stopping owner accepted metadata mutation")
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
       (match Keeper_meta_store.persist_meta config first.name first with
        | Ok () -> ()
        | Error detail -> fail ("failed to seed owner meta: " ^ detail));
       (match Owner_registry.install_from_store ~sw config with
        | Ok count -> check int "strict startup owner count" 1 count
        | Error error -> fail (Owner_registry.install_error_to_string error));
       let loaded =
         match Owner_registry.get ~base_path ~keeper_name:first.name with
         | Ok owner -> owner
         | Error error -> fail (Owner_registry.lookup_error_to_string error)
       in
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
       (match Keeper_meta_store.persist_meta config meta.name meta with
        | Ok () -> ()
        | Error detail -> fail ("failed to seed reserved owner meta: " ^ detail));
       (match Owner_registry.install_from_store ~sw config with
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
        ] )
    ; ( "actor"
      , [ test_case
            "concurrent commands are exact"
            `Quick
            test_actor_concurrent_commands_are_exact
        ; test_case
            "child isolation and per-keeper parallelism"
            `Quick
            test_child_isolation_and_per_keeper_parallelism
        ; test_case
            "mailbox backpressures without drop"
            `Quick
            test_mailbox_backpressures_without_drop
        ; test_case "store failure is precommit" `Quick test_store_failure_is_precommit
        ; test_case
            "identity and running lifecycle guards"
            `Quick
            test_identity_and_running_lifecycle_guards
        ; test_case
            "child cancellation releases slot"
            `Quick
            test_child_cancellation_releases_slot
        ; test_case
            "shutdown releases full mailbox requests"
            `Quick
            test_shutdown_releases_full_mailbox_requests
        ; test_case
            "stopping rejects new commands"
            `Quick
            test_stopping_rejects_new_commands
        ; test_case
            "root inventory loads and extends exactly once"
            `Quick
            test_root_inventory_loads_and_extends_exactly_once
        ; test_case
            "lifecycle reservation gates owner commands"
            `Quick
            test_lifecycle_reservation_remains_owner_admission_authority
        ] )
    ]
;;
