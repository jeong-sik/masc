open Alcotest
open Masc

module Reducer = Keeper_owner_reducer
module Owner = Keeper_owner
module Owner_registry = Keeper_owner_registry

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
  let state = ref (Reducer.create (Some (make_meta "pure"))) in
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

let test_actor_concurrent_commands_are_exact () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    Owner.start
      ~sw
      ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
      ~initial_meta:(Some (make_meta "concurrent"))
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
  let owner = Owner.start ~sw ~store ~initial_meta:(Some (make_meta "mailbox")) in
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
  let owner_a = Owner.start ~sw ~store ~initial_meta:(Some (make_meta "a")) in
  let owner_b = Owner.start ~sw ~store ~initial_meta:(Some (make_meta "b")) in
  let child_a_started, resolve_child_a_started = Eio.Promise.create () in
  let release_child_a, resolve_release_child_a = Eio.Promise.create () in
  (match
     owner_ok
       (Owner.start_turn owner_a ~operation_id:"op-a" ~run:(fun _turn_sw ->
          Eio.Promise.resolve resolve_child_a_started ();
          Eio.Promise.await release_child_a))
   with
   | Owner.Started -> ()
   | Busy _ -> fail "owner a unexpectedly busy");
  Eio.Promise.await child_a_started;
  (match
     owner_ok
       (Owner.start_turn owner_a ~operation_id:"op-a-2" ~run:(fun _ -> ()))
   with
   | Busy { running_operation_id } ->
     check string "busy identifies current operation" "op-a" running_operation_id
   | Started -> fail "second turn started concurrently on owner a");
  let child_b_ran = Atomic.make false in
  (match
     owner_ok
       (Owner.start_turn owner_b ~operation_id:"op-b" ~run:(fun _ ->
          Atomic.set child_b_ran true))
   with
   | Started -> ()
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
  (match
     owner_ok
       (Owner.start_turn owner_a ~operation_id:"op-exn" ~run:(fun _ ->
          raise (Failure "synthetic child failure")))
   with
   | Started -> ()
   | Busy _ -> fail "owner remained busy after first child");
  await_idle (Eio.Stdenv.clock env) owner_a 1_000;
  ignore (owner_ok (Owner.exact_projection owner_a))
;;

let test_store_failure_is_precommit () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    Owner.start
      ~sw
      ~store:
        { replace = (fun _ -> Error "disk unavailable")
        ; remove = (fun _ -> Error "disk unavailable")
        }
      ~initial_meta:(Some (make_meta "store-failure"))
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

let test_stopping_rejects_new_commands () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let owner =
    Owner.start
      ~sw
      ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
      ~initial_meta:(Some (make_meta "stopping"))
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
       let ensured =
         match Owner_registry.ensure ~base_path (make_meta "inventory-second") with
         | Ok owner -> owner
         | Error error -> fail (Owner_registry.lookup_error_to_string error)
       in
       let loaded_again =
         match Owner_registry.ensure ~base_path first with
         | Ok owner -> owner
         | Error error -> fail (Owner_registry.lookup_error_to_string error)
       in
       check bool "ensure preserves the existing actor" true (loaded == loaded_again);
       check bool "different keeper receives a different actor" false (loaded == ensured);
       check int
         "dynamic owner extends inventory once"
         2
         (Owner_registry.For_testing.installed_owner_count ~base_path);
       (match Owner_registry.all_projections ~base_path with
        | Ok projections -> check int "fleet projection count" 2 (List.length projections)
        | Error error -> fail (Owner_registry.lookup_error_to_string error)))
;;

let () =
  run
    "keeper owner"
    [ ( "reducer"
      , [ test_case
            "additive usage and pause are exact"
            `Quick
            test_pure_reducer_adds_deltas_and_preserves_pause
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
            "stopping rejects new commands"
            `Quick
            test_stopping_rejects_new_commands
        ; test_case
            "root inventory loads and extends exactly once"
            `Quick
            test_root_inventory_loads_and_extends_exactly_once
        ] )
    ]
;;
