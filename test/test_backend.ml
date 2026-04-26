(** Tests for Backend: OCaml 5.x Eio-native storage backend *)

(** Recursive directory cleanup *)
let rec rm_rf path =
  if Sys.is_directory path
  then (
    Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path
;;

(** Generate unique test directory - deterministic using PID + timestamp *)
let make_test_dir () =
  let unique_id =
    Printf.sprintf
      "masc_eio_test_%d_%d"
      (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1000000.))
  in
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ()) unique_id in
  (try Unix.mkdir tmp_dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  tmp_dir
;;

let unique_suffix () =
  Printf.sprintf "%d-%.0f" (Unix.getpid ()) (Unix.gettimeofday () *. 1_000_000.)
;;

let bool_to_int = function
  | true -> 1
  | false -> 0
;;

(** Run test with Eio environment *)
let with_eio_env f =
  Eio_main.run
  @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let tmp_dir = make_test_dir () in
  let config =
    { Backend.default_config with
      base_path = tmp_dir
    ; node_id = "test_node"
    ; cluster_name = "test"
    }
  in
  let backend = Backend.FileSystem.create ~fs config in
  Fun.protect
    ~finally:(fun () ->
      try rm_rf tmp_dir with
      | _ -> ())
    (fun () -> f backend)
;;

(** Test basic set/get operations *)
let test_set_get () =
  with_eio_env
  @@ fun backend ->
  let key = "test:key" in
  let value = "hello world" in
  (* Set value *)
  (match Backend.FileSystem.set backend key value with
   | Ok () -> ()
   | Error e -> Alcotest.failf "set failed: %s" (Backend.show_error e));
  (* Get value *)
  match Backend.FileSystem.get backend key with
  | Ok v -> Alcotest.(check string) "value matches" value v
  | Error e -> Alcotest.failf "get failed: %s" (Backend.show_error e)
;;

(** Test exists function *)
let test_exists () =
  with_eio_env
  @@ fun backend ->
  let key = "exists:test" in
  (* Should not exist initially *)
  Alcotest.(check bool)
    "not exists initially"
    false
    (Backend.FileSystem.exists backend key);
  (* Set value *)
  let _ = Backend.FileSystem.set backend key "value" in
  (* Should exist now *)
  Alcotest.(check bool) "exists after set" true (Backend.FileSystem.exists backend key)
;;

(** Test delete operation *)
let test_delete () =
  with_eio_env
  @@ fun backend ->
  let key = "delete:test" in
  (* Set then delete *)
  let _ = Backend.FileSystem.set backend key "to be deleted" in
  Alcotest.(check bool)
    "exists before delete"
    true
    (Backend.FileSystem.exists backend key);
  (match Backend.FileSystem.delete backend key with
   | Ok () -> ()
   | Error _ -> Alcotest.fail "delete failed");
  Alcotest.(check bool)
    "not exists after delete"
    false
    (Backend.FileSystem.exists backend key)
;;

(** Test key validation *)
let test_key_validation () =
  with_eio_env
  @@ fun backend ->
  (* Empty key should fail *)
  (match Backend.FileSystem.set backend "" "value" with
   | Error (Backend.InvalidKey _) -> ()
   | _ -> Alcotest.fail "empty key should fail");
  (* Key with slash should fail *)
  (match Backend.FileSystem.set backend "test/key" "value" with
   | Error (Backend.InvalidKey _) -> ()
   | _ -> Alcotest.fail "key with slash should fail");
  (* Key starting with colon should fail *)
  (match Backend.FileSystem.set backend ":test" "value" with
   | Error (Backend.InvalidKey _) -> ()
   | _ -> Alcotest.fail "key starting with colon should fail");
  (* Consecutive colons should fail *)
  (match Backend.FileSystem.set backend "test::key" "value" with
   | Error (Backend.InvalidKey _) -> ()
   | _ -> Alcotest.fail "consecutive colons should fail");
  (* Path traversal should fail *)
  match Backend.FileSystem.set backend "..:..:etc:passwd" "value" with
  | Error (Backend.InvalidKey _) -> ()
  | _ -> Alcotest.fail "path traversal should fail"
;;

(** Test nested keys *)
let test_nested_keys () =
  with_eio_env
  @@ fun backend ->
  let key = "rooms:room1:messages:msg001" in
  let value = "nested value" in
  (* Set nested key *)
  (match Backend.FileSystem.set backend key value with
   | Ok () -> ()
   | Error _ -> Alcotest.fail "set nested key failed");
  (* Get nested key *)
  match Backend.FileSystem.get backend key with
  | Ok v -> Alcotest.(check string) "nested value matches" value v
  | Error _ -> Alcotest.fail "get nested key failed"
;;

let test_recursive_prefix_get_all () =
  with_eio_env
  @@ fun backend ->
  let writes =
    [ "team-sessions:ts-1:session.json", "s1"
    ; "team-sessions:ts-1:events.jsonl", "e1"
    ; "team-sessions:ts-2:session.json", "s2"
    ; "relay:node-1", "m1"
    ]
  in
  List.iter
    (fun (key, value) ->
       match Backend.FileSystem.set backend key value with
       | Ok () -> ()
       | Error _ -> Alcotest.fail "set for recursive prefix test failed")
    writes;
  match Backend.FileSystem.list_keys backend ~prefix:"team-sessions:" with
  | Ok keys ->
    Alcotest.(check int) "recursive keys" 3 (List.length keys);
    Alcotest.(check bool)
      "session key present"
      true
      (List.mem "team-sessions:ts-2:session.json" keys)
  | Error _ -> Alcotest.fail "recursive list_keys failed"
;;

(** Test set_if_not_exists *)
let test_set_if_not_exists () =
  with_eio_env
  @@ fun backend ->
  let key = "exclusive:key" in
  (* First set should succeed *)
  (match Backend.FileSystem.set_if_not_exists backend key "first" with
   | Ok true -> ()
   | _ -> Alcotest.fail "first set_if_not_exists should succeed");
  (* Second set should fail with AlreadyExists *)
  match Backend.FileSystem.set_if_not_exists backend key "second" with
  | Error (Backend.AlreadyExists _) -> ()
  | _ -> Alcotest.fail "second set_if_not_exists should fail"
;;

(** Test Memory backend basic operations *)
let test_memory_backend () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let backend = Backend.Memory.create () in
  (* Set value *)
  (match Backend.Memory.set backend "key1" "value1" with
   | Ok () -> ()
   | Error _ -> Alcotest.fail "memory set failed");
  (* Get value *)
  (match Backend.Memory.get backend "key1" with
   | Ok v -> Alcotest.(check string) "memory get" "value1" v
   | Error _ -> Alcotest.fail "memory get failed");
  (* Exists check *)
  Alcotest.(check bool) "memory exists" true (Backend.Memory.exists backend "key1");
  (* Delete *)
  (match Backend.Memory.delete backend "key1" with
   | Ok () -> ()
   | Error _ -> Alcotest.fail "memory delete failed");
  Alcotest.(check bool)
    "memory not exists after delete"
    false
    (Backend.Memory.exists backend "key1")
;;

(** Test health check *)
let test_health_check () =
  with_eio_env
  @@ fun backend ->
  match Backend.FileSystem.health_check backend with
  | Ok result -> Alcotest.(check bool) "is healthy" true result.is_healthy
  | Error _ -> Alcotest.fail "health check failed"
;;

(** Test unified backend interface *)
let test_unified_backend () =
  Eio_main.run
  @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let tmp_dir = make_test_dir () in
  let config =
    { Backend.default_config with
      base_path = tmp_dir
    ; node_id = "unified_test"
    ; cluster_name = "test"
    }
  in
  let fs_backend = Backend.FileSystem.create ~fs config in
  let backend = Backend.FS fs_backend in
  Fun.protect
    ~finally:(fun () ->
      try rm_rf tmp_dir with
      | _ -> ())
    (fun () ->
       (* Test through unified interface *)
       (match Backend.set backend "unified:key" "unified value" with
        | Ok () -> ()
        | Error _ -> Alcotest.fail "unified set failed");
       match Backend.get backend "unified:key" with
       | Ok v -> Alcotest.(check string) "unified get" "unified value" v
       | Error _ -> Alcotest.fail "unified get failed")
;;

let () =
  Alcotest.run
    "Backend"
    [ ( "basic"
      , [ Alcotest.test_case "set and get" `Quick test_set_get
        ; Alcotest.test_case "exists" `Quick test_exists
        ; Alcotest.test_case "delete" `Quick test_delete
        ] )
    ; ( "validation"
      , [ Alcotest.test_case "key validation" `Quick test_key_validation
        ; Alcotest.test_case "nested keys" `Quick test_nested_keys
        ; Alcotest.test_case
            "recursive prefix get_all"
            `Quick
            test_recursive_prefix_get_all
        ] )
    ; "atomic", [ Alcotest.test_case "set_if_not_exists" `Quick test_set_if_not_exists ]
    ; "memory", [ Alcotest.test_case "memory backend" `Quick test_memory_backend ]
    ; "health", [ Alcotest.test_case "health check" `Quick test_health_check ]
    ; "unified", [ Alcotest.test_case "unified backend" `Quick test_unified_backend ]
    ]
;;
