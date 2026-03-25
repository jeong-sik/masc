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

(* Helper: create Backend_eio.FileSystem using Fs_compat global *)
let make_eio_fs_backend label =
  let fs = Option.get (Fs_compat.get_fs_opt ()) in
  let tmp_dir = "/tmp/masc-test-" ^ label in
  let config = Backend_eio.{ base_path = tmp_dir; node_id = "test"; cluster_name = "test" } in
  Backend_eio.FileSystem.create ~fs config

(* Test: FileSystem backend - create *)
let test_filesystem_backend_create () =
  let _backend = make_eio_fs_backend "fs" in
  ()

(* Test: FileSystem backend - basic ops *)
let test_filesystem_backend_basic () =
  let backend = make_eio_fs_backend "fs" in
  (* Set *)
  (match Backend_eio.FileSystem.set backend "test:fs:key" "fsvalue" with
  | Ok () -> ()
  | Error e -> fail (Printf.sprintf "set failed: %s" (match e with Backend_eio.IOError m -> m | _ -> "unknown")));

  (* Get *)
  (match Backend_eio.FileSystem.get backend "test:fs:key" with
  | Ok v -> check string "fs value" "fsvalue" v
  | Error (Backend_eio.NotFound _) -> fail "key not found"
  | Error _ -> fail "get failed");

  (* Delete *)
  (match Backend_eio.FileSystem.delete backend "test:fs:key" with
  | Ok () -> ()
  | Error _ -> fail "delete failed")

let test_filesystem_backend_recursive_prefix_get_all () =
  let backend = make_eio_fs_backend "fs-prefix" in
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
      match Backend_eio.FileSystem.set backend key value with
      | Ok () -> ()
      | Error _ -> fail "set failed")
    writes;
  (match Backend_eio.FileSystem.list_keys backend ~prefix:"team-sessions:" with
  | Ok keys ->
      check int "recursive session keys" 3 (List.length keys);
      check bool "session key present" true
        (List.mem "team-sessions:ts-1:session.json" keys)
  | Error _ -> fail "list_keys failed");
  (match Backend_eio.FileSystem.get_all backend ~prefix:"team-sessions:" with
  | Ok pairs ->
      check int "recursive session rows" 3 (List.length pairs)
  | Error _ -> fail "get_all failed")

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
  let backend = make_eio_fs_backend "security" in
  (* Test: keys with .. should be rejected *)
  let path_traversal_blocked =
    match Backend_eio.FileSystem.set backend "..:..:etc:passwd" "hacked" with
    | Error (Backend_eio.InvalidKey _) -> true
    | _ -> false
  in
  check bool "path traversal blocked" true path_traversal_blocked;

  (* Test: keys starting with / should be rejected *)
  let absolute_path_blocked =
    match Backend_eio.FileSystem.set backend "/etc/passwd" "hacked" with
    | Error (Backend_eio.InvalidKey _) -> true
    | _ -> false
  in
  check bool "absolute path blocked" true absolute_path_blocked;

  (* Test: valid keys should still work *)
  (match Backend_eio.FileSystem.set backend "valid:key:name" "ok" with
  | Ok () ->
      (match Backend_eio.FileSystem.get backend "valid:key:name" with
      | Ok v -> check string "valid key value" "ok" v
      | Error _ -> fail "valid key get failed")
  | Error _ -> fail "valid key should work")

(* Test: FileSystem backend - atomic set_if_not_exists *)
let test_filesystem_atomic_set () =
  let backend = make_eio_fs_backend "atomic" in
  let key = "atomic:key:" ^ Printf.sprintf "%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.)) in
  (* First set should succeed *)
  (match Backend_eio.FileSystem.set_if_not_exists backend key "first" with
  | Ok true -> ()
  | _ -> fail "first atomic set failed");

  (* Second set should fail atomically *)
  (match Backend_eio.FileSystem.set_if_not_exists backend key "second" with
  | Ok false | Error (Backend_eio.AlreadyExists _) -> ()
  | _ -> fail "second atomic set should return false");

  (* Value should be first *)
  (match Backend_eio.FileSystem.get backend key with
  | Ok v -> check string "atomic value" "first" v
  | _ -> fail "get after atomic set failed");

  (* Cleanup *)
  let _ = Backend_eio.FileSystem.delete backend key in
  ()

(* Test: FileSystem backend - locking *)
let test_filesystem_locking () =
  let backend = make_eio_fs_backend "lock" in
  let key = "locktest:" ^ Printf.sprintf "%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.)) in

  (* Acquire *)
  (match Backend_eio.FileSystem.acquire_lock backend ~key ~owner:"agent1" ~ttl_seconds:60 with
  | Ok true -> ()
  | _ -> fail "acquire should succeed");

  (* Second agent blocked *)
  (match Backend_eio.FileSystem.acquire_lock backend ~key ~owner:"agent2" ~ttl_seconds:60 with
  | Ok false -> ()
  | _ -> fail "second acquire should fail");

  (* Release *)
  (match Backend_eio.FileSystem.release_lock backend ~key ~owner:"agent1" with
  | Ok true -> ()
  | _ -> fail "release should succeed")

(* Test: TTL boundary validation — validates Backend_core.validate_ttl *)
let test_ttl_boundary_validation () =
  check int "TTL zero clamped to 1" 1 (Backend.validate_ttl 0);
  check int "TTL negative clamped to 1" 1 (Backend.validate_ttl (-100));
  check int "TTL capped to 86400" 86400 (Backend.validate_ttl 999999);
  check int "TTL normal passthrough" 60 (Backend.validate_ttl 60)

(* All tests *)
let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
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
    ];
    "errors", [
      test_case "error messages" `Quick test_error_messages;
    ];
  ]
