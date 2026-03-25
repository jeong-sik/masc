(** Tests for Backend module *)

module Backend = Backend
open Alcotest

(* Helper to create test config *)
let test_config () = {
  Backend.backend_type = Backend.Memory;
  base_path = "/tmp/masc-test";
  postgres_url = None;
  node_id = "test-node-1";
  cluster_name = "test-cluster";
  pubsub_max_messages = 1000;
}

let unique_suffix () =
  Printf.sprintf "%d-%.0f" (Unix.getpid ()) (Unix.gettimeofday () *. 1_000_000.)

let bool_to_int = function
  | true -> 1
  | false -> 0

(* Test: generate unique node IDs *)
let test_node_id_generation () =
  let id1 = Backend.generate_node_id () in
  let id2 = Backend.generate_node_id () in
  check bool "IDs contain hostname" true (String.length id1 > 5);
  check bool "IDs are unique" true (id1 <> id2)

(* Test: default config values *)
let test_default_config () =
  let cfg = Backend.default_config in
  check bool "default is FileSystem" true
    (match cfg.backend_type with Backend.FileSystem -> true | _ -> false);
  check string "default base_path" ".masc" cfg.base_path

(* Test: backend status JSON *)
let test_backend_status_json () =
  let cfg = test_config () in
  let status = Backend.get_status cfg in
  let open Yojson.Safe.Util in

  check string "backend_type" "memory" (status |> member "backend_type" |> to_string);
  check string "node_id" "test-node-1" (status |> member "node_id" |> to_string);
  check string "cluster_name" "test-cluster" (status |> member "cluster_name" |> to_string)

(* Test: Memory backend - basic operations *)
let test_memory_backend_basic () =
  let cfg = test_config () in
  match Backend.MemoryBackend.create cfg with
  | Error _ -> fail "Failed to create memory backend"
  | Ok backend ->
      (* Set and get *)
      (match Backend.MemoryBackend.set backend ~key:"test:key1" ~value:"value1" with
      | Error _ -> fail "set failed"
      | Ok () ->
          match Backend.MemoryBackend.get backend ~key:"test:key1" with
          | Error _ -> fail "get failed"
          | Ok None -> fail "key not found"
          | Ok (Some v) -> check string "value" "value1" v);

      (* Delete *)
      (match Backend.MemoryBackend.delete backend ~key:"test:key1" with
      | Error _ -> fail "delete failed"
      | Ok deleted -> check bool "deleted" true deleted);

      (* Get after delete *)
      (match Backend.MemoryBackend.get backend ~key:"test:key1" with
      | Ok None -> ()
      | _ -> fail "should be None after delete")

(* Test: Memory backend - exists *)
let test_memory_backend_exists () =
  let cfg = test_config () in
  match Backend.MemoryBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      check bool "not exists initially" false (Backend.MemoryBackend.exists backend ~key:"nonexistent");

      let _ = Backend.MemoryBackend.set backend ~key:"exists:test" ~value:"v" in
      check bool "exists after set" true (Backend.MemoryBackend.exists backend ~key:"exists:test")

(* Test: Memory backend - set_if_not_exists *)
let test_memory_backend_set_if_not_exists () =
  let cfg = test_config () in
  match Backend.MemoryBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      (* First set should succeed *)
      (match Backend.MemoryBackend.set_if_not_exists backend ~key:"unique" ~value:"first" with
      | Error _ -> fail "first set_if_not_exists failed"
      | Ok success -> check bool "first set" true success);

      (* Second set should fail *)
      (match Backend.MemoryBackend.set_if_not_exists backend ~key:"unique" ~value:"second" with
      | Error _ -> fail "second set_if_not_exists error"
      | Ok success -> check bool "second set" false success);

      (* Value should be first *)
      (match Backend.MemoryBackend.get backend ~key:"unique" with
      | Ok (Some v) -> check string "value is first" "first" v
      | _ -> fail "get failed")

(* Test: Memory backend - compare_and_swap *)
let test_memory_backend_cas () =
  let cfg = test_config () in
  match Backend.MemoryBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      let _ = Backend.MemoryBackend.set backend ~key:"cas:key" ~value:"initial" in

      (* CAS with wrong expected should fail *)
      (match Backend.MemoryBackend.compare_and_swap backend ~key:"cas:key" ~expected:"wrong" ~value:"new" with
      | Ok false -> ()
      | _ -> fail "CAS should fail with wrong expected");

      (* CAS with correct expected should succeed *)
      (match Backend.MemoryBackend.compare_and_swap backend ~key:"cas:key" ~expected:"initial" ~value:"updated" with
      | Ok true -> ()
      | _ -> fail "CAS should succeed");

      (* Value should be updated *)
      (match Backend.MemoryBackend.get backend ~key:"cas:key" with
      | Ok (Some v) -> check string "updated value" "updated" v
      | _ -> fail "get failed")

(* Test: Memory backend - locking *)
let test_memory_backend_locking () =
  let cfg = test_config () in
  match Backend.MemoryBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      (* Acquire lock *)
      (match Backend.MemoryBackend.acquire_lock backend ~key:"resource1" ~ttl_seconds:60 ~owner:"agent1" with
      | Ok true -> ()
      | _ -> fail "acquire should succeed");

      (* Second agent can't acquire *)
      (match Backend.MemoryBackend.acquire_lock backend ~key:"resource1" ~ttl_seconds:60 ~owner:"agent2" with
      | Ok false -> ()
      | _ -> fail "second acquire should fail");

      (* Owner can release *)
      (match Backend.MemoryBackend.release_lock backend ~key:"resource1" ~owner:"agent1" with
      | Ok true -> ()
      | _ -> fail "release should succeed");

      (* Now second agent can acquire *)
      (match Backend.MemoryBackend.acquire_lock backend ~key:"resource1" ~ttl_seconds:60 ~owner:"agent2" with
      | Ok true -> ()
      | _ -> fail "acquire after release should succeed")

(* Test: Memory backend - lock extend *)
let test_memory_backend_lock_extend () =
  let cfg = test_config () in
  match Backend.MemoryBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      let _ = Backend.MemoryBackend.acquire_lock backend ~key:"ext" ~ttl_seconds:10 ~owner:"owner" in

      (* Owner can extend *)
      (match Backend.MemoryBackend.extend_lock backend ~key:"ext" ~ttl_seconds:60 ~owner:"owner" with
      | Ok true -> ()
      | _ -> fail "extend should succeed");

      (* Non-owner can't extend *)
      (match Backend.MemoryBackend.extend_lock backend ~key:"ext" ~ttl_seconds:60 ~owner:"other" with
      | Ok false -> ()
      | _ -> fail "non-owner extend should fail")

let test_postgres_native_expired_lock_reacquire () =
  match Sys.getenv_opt "MASC_POSTGRES_URL" with
  | None | Some "" -> ()
  | Some url ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let suffix = unique_suffix () in
      let cfg = {
        Backend.default_config with
        backend_type = Backend.PostgresNative;
        cluster_name = "test-pg-native-" ^ suffix;
        postgres_url = Some url;
      } in
      match Backend.PostgresNative.create_eio ~sw ~env:(env :> Caqti_eio.stdenv) cfg with
      | Error e -> fail (Backend.show_error e)
      | Ok backend ->
          let key = "expired-lock-" ^ suffix in
          (match Backend.PostgresNative.acquire_lock backend ~key ~ttl_seconds:0 ~owner:"owner-a" with
           | Ok true -> ()
           | Ok false -> fail "initial expired lock acquire should succeed"
           | Error e -> fail (Backend.show_error e));
          Eio.Time.sleep env#clock 0.01;
          match Backend.PostgresNative.acquire_lock backend ~key ~ttl_seconds:60 ~owner:"owner-b" with
          | Ok true -> ()
          | Ok false -> fail "expired postgres-native lock should be reacquired"
          | Error e -> fail (Backend.show_error e)

let test_postgres_native_lock_blocks_other_owner () =
  match Sys.getenv_opt "MASC_POSTGRES_URL" with
  | None | Some "" -> ()
  | Some url ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let suffix = unique_suffix () in
      let cfg = {
        Backend.default_config with
        backend_type = Backend.PostgresNative;
        cluster_name = "test-pg-native-block-" ^ suffix;
        postgres_url = Some url;
      } in
      match Backend.PostgresNative.create_eio ~sw ~env:(env :> Caqti_eio.stdenv) cfg with
      | Error e -> fail (Backend.show_error e)
      | Ok backend ->
          let key = "held-lock-" ^ suffix in
          (match Backend.PostgresNative.acquire_lock backend ~key ~ttl_seconds:60 ~owner:"owner-a" with
           | Ok true -> ()
           | Ok false -> fail "initial lock acquire should succeed"
           | Error e -> fail (Backend.show_error e));
          match Backend.PostgresNative.acquire_lock backend ~key ~ttl_seconds:60 ~owner:"owner-b" with
          | Ok false -> ()
          | Ok true -> fail "non-expired postgres-native lock should block other owners"
          | Error e -> fail (Backend.show_error e)

let test_postgres_native_expired_lock_concurrent_reacquire () =
  match Sys.getenv_opt "MASC_POSTGRES_URL" with
  | None | Some "" -> ()
  | Some url ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let suffix = unique_suffix () in
      let cfg = {
        Backend.default_config with
        backend_type = Backend.PostgresNative;
        cluster_name = "test-pg-native-race-" ^ suffix;
        postgres_url = Some url;
      } in
      match Backend.PostgresNative.create_eio ~sw ~env:(env :> Caqti_eio.stdenv) cfg with
      | Error e -> fail (Backend.show_error e)
      | Ok backend ->
          let key = "expired-race-" ^ suffix in
          (match Backend.PostgresNative.acquire_lock backend ~key ~ttl_seconds:0 ~owner:"seed-owner" with
           | Ok true -> ()
           | Ok false -> fail "seed expired lock acquire should succeed"
           | Error e -> fail (Backend.show_error e));
          Eio.Time.sleep env#clock 0.01;
          let attempt owner () =
            match Backend.PostgresNative.acquire_lock backend ~key ~ttl_seconds:60 ~owner with
            | Ok acquired -> acquired
            | Error e -> fail (Backend.show_error e)
          in
          let promise_a, resolver_a = Eio.Promise.create () in
          let promise_b, resolver_b = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolver_a (attempt "owner-a" ()));
          Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolver_b (attempt "owner-b" ()));
          let acquired_a = Eio.Promise.await promise_a in
          let acquired_b = Eio.Promise.await promise_b in
          check int "exactly one owner acquires expired lock" 1
            (bool_to_int acquired_a + bool_to_int acquired_b)

let test_postgres_native_old_owner_cannot_release_reclaimed_lock () =
  match Sys.getenv_opt "MASC_POSTGRES_URL" with
  | None | Some "" -> ()
  | Some url ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let suffix = unique_suffix () in
      let cfg = {
        Backend.default_config with
        backend_type = Backend.PostgresNative;
        cluster_name = "test-pg-native-release-" ^ suffix;
        postgres_url = Some url;
      } in
      match Backend.PostgresNative.create_eio ~sw ~env:(env :> Caqti_eio.stdenv) cfg with
      | Error e -> fail (Backend.show_error e)
      | Ok backend ->
          let key = "reclaimed-lock-" ^ suffix in
          (match Backend.PostgresNative.acquire_lock backend ~key ~ttl_seconds:0 ~owner:"owner-a" with
           | Ok true -> ()
           | Ok false -> fail "seed expired lock acquire should succeed"
           | Error e -> fail (Backend.show_error e));
          Eio.Time.sleep env#clock 0.01;
          (match Backend.PostgresNative.acquire_lock backend ~key ~ttl_seconds:60 ~owner:"owner-b" with
           | Ok true -> ()
           | Ok false -> fail "reclaimed lock acquire should succeed"
           | Error e -> fail (Backend.show_error e));
          (match Backend.PostgresNative.release_lock backend ~key ~owner:"owner-a" with
           | Ok true -> ()
           | Ok false -> fail "release_lock should not fail"
           | Error e -> fail (Backend.show_error e));
          match Backend.PostgresNative.acquire_lock backend ~key ~ttl_seconds:60 ~owner:"owner-c" with
          | Ok false -> ()
          | Ok true -> fail "old owner must not release reclaimed lock"
          | Error e -> fail (Backend.show_error e)

(* Test: Memory backend - list and get_all *)
let test_memory_backend_list () =
  let cfg = test_config () in
  match Backend.MemoryBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      let _ = Backend.MemoryBackend.set backend ~key:"prefix:a" ~value:"1" in
      let _ = Backend.MemoryBackend.set backend ~key:"prefix:b" ~value:"2" in
      let _ = Backend.MemoryBackend.set backend ~key:"other:c" ~value:"3" in

      (match Backend.MemoryBackend.list_keys backend ~prefix:"prefix" with
      | Ok keys ->
          check int "prefix keys count" 2 (List.length keys)
      | Error _ -> fail "list_keys failed");

      (match Backend.MemoryBackend.get_all backend ~prefix:"prefix" with
      | Ok pairs ->
          check int "pairs count" 2 (List.length pairs)
      | Error _ -> fail "get_all failed")

(* Test: Memory backend - health check *)
let test_memory_backend_health () =
  let cfg = test_config () in
  match Backend.MemoryBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      match Backend.MemoryBackend.health_check backend with
      | Ok true -> ()
      | _ -> fail "health check should pass"

(* Test: FileSystem backend - create *)
let test_filesystem_backend_create () =
  let cfg = { Backend.default_config with base_path = "/tmp/masc-test-fs" } in
  match Backend.FileSystemBackend.create cfg with
  | Ok _ -> ()
  | Error e -> fail (Backend.show_error e)

(* Test: FileSystem backend - basic ops *)
let test_filesystem_backend_basic () =
  let cfg = { Backend.default_config with base_path = "/tmp/masc-test-fs" } in
  match Backend.FileSystemBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      (* Set *)
      (match Backend.FileSystemBackend.set backend ~key:"test:fs:key" ~value:"fsvalue" with
      | Ok () -> ()
      | Error e -> fail (Backend.show_error e));

      (* Get *)
      (match Backend.FileSystemBackend.get backend ~key:"test:fs:key" with
      | Ok (Some v) -> check string "fs value" "fsvalue" v
      | Ok None -> fail "key not found"
      | Error e -> fail (Backend.show_error e));

      (* Delete *)
      (match Backend.FileSystemBackend.delete backend ~key:"test:fs:key" with
      | Ok _ -> ()
      | Error e -> fail (Backend.show_error e))

let test_filesystem_backend_recursive_prefix_get_all () =
  let cfg = { Backend.default_config with base_path = "/tmp/masc-test-fs-prefix" } in
  match Backend.FileSystemBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      let writes =
        [
          ("team-sessions:ts-1:session.json", "s1");
          ("team-sessions:ts-1:events.jsonl", "e1");
          ("team-sessions:ts-2:session.json", "s2");
          ("mitosis:node-1", "m1");
        ]
      in
      List.iter
        (fun (key, value) ->
          match Backend.FileSystemBackend.set backend ~key ~value with
          | Ok () -> ()
          | Error e -> fail (Backend.show_error e))
        writes;
      (match Backend.FileSystemBackend.list_keys backend ~prefix:"team-sessions:" with
      | Ok keys ->
          check int "recursive session keys" 3 (List.length keys);
          check bool "session key present" true
            (List.mem "team-sessions:ts-1:session.json" keys)
      | Error e -> fail (Backend.show_error e));
      (match Backend.FileSystemBackend.get_all backend ~prefix:"team-sessions:" with
      | Ok pairs ->
          check int "recursive session rows" 3 (List.length pairs);
          check bool "events row present" true
            (List.mem ("team-sessions:ts-1:events.jsonl", "e1") pairs)
      | Error e -> fail (Backend.show_error e))

(* Test: error messages *)
let test_error_messages () =
  check bool "ConnectionFailed" true
    (String.length (Backend.show_error (Backend.ConnectionFailed "test")) > 10);
  check bool "KeyNotFound" true
    (String.length (Backend.show_error (Backend.KeyNotFound "key")) > 5);
  check bool "BackendNotSupported" true
    (String.length (Backend.show_error (Backend.BackendNotSupported "unknown")) > 5)

(* Security tests: Path traversal prevention *)
let test_path_traversal_prevention () =
  let cfg = { Backend.default_config with base_path = "/tmp/masc-test-security" } in
  match Backend.FileSystemBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      (* Test: keys with .. should be rejected *)
      let path_traversal_blocked =
        match Backend.FileSystemBackend.set backend ~key:"..:..:etc:passwd" ~value:"hacked" with
        | Error (Backend.InvalidKey _) -> true
        | _ -> false
      in
      check bool "path traversal blocked" true path_traversal_blocked;

      (* Test: keys starting with / should be rejected *)
      let absolute_path_blocked =
        match Backend.FileSystemBackend.set backend ~key:"/etc/passwd" ~value:"hacked" with
        | Error (Backend.InvalidKey _) -> true
        | _ -> false
      in
      check bool "absolute path blocked" true absolute_path_blocked;

      (* Test: valid keys should still work *)
      (match Backend.FileSystemBackend.set backend ~key:"valid:key:name" ~value:"ok" with
      | Ok () ->
          (* Verify the value was actually stored *)
          (match Backend.FileSystemBackend.get backend ~key:"valid:key:name" with
          | Ok (Some v) -> check string "valid key value" "ok" v
          | Ok None -> fail "valid key not found after set"
          | Error _ -> fail "valid key get failed")
      | Error _ -> fail "valid key should work")

(* Test: FileSystem backend - atomic set_if_not_exists *)
let test_filesystem_atomic_set () =
  let cfg = { Backend.default_config with base_path = "/tmp/masc-test-atomic" } in
  match Backend.FileSystemBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      let key = "atomic:key:" ^ Printf.sprintf "%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.)) in
      (* First set should succeed *)
      (match Backend.FileSystemBackend.set_if_not_exists backend ~key ~value:"first" with
      | Ok true -> ()
      | _ -> fail "first atomic set failed");

      (* Second set should fail atomically *)
      (match Backend.FileSystemBackend.set_if_not_exists backend ~key ~value:"second" with
      | Ok false -> ()
      | _ -> fail "second atomic set should return false");

      (* Value should be first *)
      (match Backend.FileSystemBackend.get backend ~key with
      | Ok (Some v) -> check string "atomic value" "first" v
      | _ -> fail "get after atomic set failed");

      (* Cleanup *)
      let _ = Backend.FileSystemBackend.delete backend ~key in
      ()

(* Test: FileSystem backend - locking *)
let test_filesystem_locking () =
  let cfg = { Backend.default_config with base_path = "/tmp/masc-test-lock" } in
  match Backend.FileSystemBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      let key = "locktest:" ^ Printf.sprintf "%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.)) in

      (* Acquire *)
      (match Backend.FileSystemBackend.acquire_lock backend ~key ~ttl_seconds:60 ~owner:"agent1" with
      | Ok true -> ()
      | _ -> fail "acquire should succeed");

      (* Second agent blocked *)
      (match Backend.FileSystemBackend.acquire_lock backend ~key ~ttl_seconds:60 ~owner:"agent2" with
      | Ok false -> ()
      | _ -> fail "second acquire should fail");

      (* Release *)
      (match Backend.FileSystemBackend.release_lock backend ~key ~owner:"agent1" with
      | Ok true -> ()
      | _ -> fail "release should succeed")

(* Test: TTL boundary validation *)
let test_ttl_boundary_validation () =
  let cfg = { Backend.default_config with base_path = "/tmp/masc-test-ttl" } in
  match Backend.FileSystemBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      (* Test 1: Zero TTL should work (internally clamped to 1) *)
      let key1 = "ttl:zero:" ^ Printf.sprintf "%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.)) in
      (match Backend.FileSystemBackend.acquire_lock backend ~key:key1 ~ttl_seconds:0 ~owner:"agent1" with
      | Ok true -> ()
      | Ok false -> fail "zero TTL lock should succeed"
      | Error _ -> fail "zero TTL lock error");
      let _ = Backend.FileSystemBackend.release_lock backend ~key:key1 ~owner:"agent1" in

      (* Test 2: Negative TTL should work (internally clamped to 1) *)
      let key2 = "ttl:negative:" ^ Printf.sprintf "%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.)) in
      (match Backend.FileSystemBackend.acquire_lock backend ~key:key2 ~ttl_seconds:(-100) ~owner:"agent1" with
      | Ok true -> ()
      | Ok false -> fail "negative TTL lock should succeed"
      | Error _ -> fail "negative TTL lock error");
      let _ = Backend.FileSystemBackend.release_lock backend ~key:key2 ~owner:"agent1" in

      (* Test 3: Very large TTL should be capped to 86400 (24h) *)
      let key3 = "ttl:large:" ^ Printf.sprintf "%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.)) in
      (match Backend.FileSystemBackend.acquire_lock backend ~key:key3 ~ttl_seconds:999999 ~owner:"agent1" with
      | Ok true -> ()
      | Ok false -> fail "large TTL lock should succeed"
      | Error _ -> fail "large TTL lock error");
      let _ = Backend.FileSystemBackend.release_lock backend ~key:key3 ~owner:"agent1" in
      ()

(* Test: Corrupted JSON lock file recovery *)
let test_corrupted_lock_recovery () =
  let cfg = { Backend.default_config with base_path = "/tmp/masc-test-corrupt" } in
  match Backend.FileSystemBackend.create cfg with
  | Error _ -> fail "Failed to create"
  | Ok backend ->
      (* Use simple key without colons for easier path construction *)
      let key = "corrupttest" ^ Printf.sprintf "%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.)) in
      (* First, create a valid lock *)
      (match Backend.FileSystemBackend.acquire_lock backend ~key ~ttl_seconds:60 ~owner:"agent1" with
      | Ok true -> ()
      | _ -> fail "initial lock should succeed");

      (* Corrupt the lock file by writing invalid JSON *)
      (* Lock file path: base_path/locks/key (key_to_path converts "locks:key" -> "locks/key") *)
      let lock_path = "/tmp/masc-test-corrupt/locks/" ^ key in
      (try
        let oc = open_out lock_path in
        output_string oc "{invalid json";
        close_out oc
      with _ -> ());

      (* Now try to acquire - should succeed because corrupted file is removed *)
      (match Backend.FileSystemBackend.acquire_lock backend ~key ~ttl_seconds:60 ~owner:"agent2" with
      | Ok true -> ()
      | Ok false -> fail "lock after corruption should succeed (corrupted file removed)"
      | Error _ -> fail "lock after corruption error")

(* All tests *)
let () =
  Eio_main.run @@ fun _env ->
  run "Backend" [
    "config", [
      test_case "node ID generation" `Quick test_node_id_generation;
      test_case "default config" `Quick test_default_config;
      test_case "status JSON" `Quick test_backend_status_json;
    ];
    "memory_basic", [
      test_case "basic operations" `Quick test_memory_backend_basic;
      test_case "exists" `Quick test_memory_backend_exists;
      test_case "set_if_not_exists" `Quick test_memory_backend_set_if_not_exists;
      test_case "compare_and_swap" `Quick test_memory_backend_cas;
    ];
    "memory_locking", [
      test_case "basic locking" `Quick test_memory_backend_locking;
      test_case "lock extend" `Quick test_memory_backend_lock_extend;
    ];
    "memory_list", [
      test_case "list and get_all" `Quick test_memory_backend_list;
      test_case "health check" `Quick test_memory_backend_health;
    ];
    "filesystem", [
      test_case "create" `Quick test_filesystem_backend_create;
      test_case "basic ops" `Quick test_filesystem_backend_basic;
      test_case "recursive prefix get_all" `Quick
        test_filesystem_backend_recursive_prefix_get_all;
      test_case "atomic set_if_not_exists" `Quick test_filesystem_atomic_set;
      test_case "locking" `Quick test_filesystem_locking;
    ];
    "security", [
      test_case "path traversal prevention" `Quick test_path_traversal_prevention;
      test_case "TTL boundary validation" `Quick test_ttl_boundary_validation;
      test_case "corrupted lock recovery" `Quick test_corrupted_lock_recovery;
    ];
    "errors", [
      test_case "error messages" `Quick test_error_messages;
    ];
    "postgres", [
      test_case "expired lock can be reacquired" `Quick
        test_postgres_native_expired_lock_reacquire;
      test_case "non-expired lock blocks other owner" `Quick
        test_postgres_native_lock_blocks_other_owner;
      test_case "expired lock concurrent reacquire is single-winner" `Quick
        test_postgres_native_expired_lock_concurrent_reacquire;
      test_case "old owner cannot release reclaimed lock" `Quick
        test_postgres_native_old_owner_cannot_release_reclaimed_lock;
    ];
  ]
