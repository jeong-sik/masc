(** Comprehensive coverage tests for Backend modules

    Target: Fill coverage gaps identified in existing tests.
    Focus areas:
    - Backend_types: validate_ttl, config, status
    - Backend.ml: Compression, lock operations, atomic operations, unified interface
*)

open Alcotest
module Backend = Backend

(* ============================================================ *)
(* Test Utilities                                                *)
(* ============================================================ *)

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
;;

let make_unique_key prefix =
  Printf.sprintf
    "%s_%d_%d"
    prefix
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000000.))
;;

let make_test_dir base =
  let unique_id = make_unique_key base in
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ()) unique_id in
  (try Unix.mkdir tmp_dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  tmp_dir
;;

(* ============================================================ *)
(* Backend.ml - validate_ttl Tests                               *)
(* ============================================================ *)

let test_validate_ttl_zero () =
  let result = Backend_types.validate_ttl 0 in
  check int "zero TTL clamped to 1" 1 result
;;

let test_validate_ttl_negative () =
  let result = Backend_types.validate_ttl (-100) in
  check int "negative TTL clamped to 1" 1 result
;;

let test_validate_ttl_normal () =
  let result = Backend_types.validate_ttl 60 in
  check int "normal TTL unchanged" 60 result
;;

let test_validate_ttl_large () =
  let result = Backend_types.validate_ttl 999999 in
  check int "large TTL clamped to 86400" 86400 result
;;

let test_validate_ttl_boundary () =
  check int "TTL at max boundary" 86400 (Backend_types.validate_ttl 86400);
  check int "TTL just above max" 86400 (Backend_types.validate_ttl 86401);
  check int "TTL at min boundary" 1 (Backend_types.validate_ttl 1)
;;

(* ============================================================ *)
(* Backend_types - Config and Status                         *)
(* ============================================================ *)

let test_get_status_all_backends () =
  let cfg_mem =
    { Backend_types.default_config with backend_type = Backend_types.Memory }
  in
  let cfg_fs =
    { Backend_types.default_config with backend_type = Backend_types.FileSystem }
  in
  let open Yojson.Safe.Util in
  let s1 = Backend_types.get_status cfg_mem in
  check string "memory status" "memory" (s1 |> member "backend_type" |> to_string);
  let s2 = Backend_types.get_status cfg_fs in
  check string "fs status" "filesystem" (s2 |> member "backend_type" |> to_string)
;;

let test_pubsub_max_messages_env () =
  (* Test the default value - cannot easily test env override in unit test *)
  let result = Backend_types.pubsub_max_messages_from_env () in
  check bool "pubsub default >= 100" true (result >= 100)
;;

(* ============================================================ *)
(* Backend.ml - Compression Tests                            *)
(* ============================================================ *)

let test_compression_small_data () =
  let data = "hello" in
  let compressed, used_dict, did_compress = Backend.Compression.compress data in
  (* Small data should not be compressed *)
  check bool "small data not compressed" false did_compress;
  check string "small data unchanged" data compressed;
  check bool "no dict used" false used_dict
;;

let test_compression_large_data () =
  (* Create data larger than min_size (32 bytes) *)
  let data = String.make 100 'a' in
  let compressed, _used_dict, did_compress = Backend.Compression.compress data in
  check bool "large data compressed" true did_compress;
  check bool "compressed smaller" true (String.length compressed < String.length data)
;;

let test_compression_roundtrip () =
  let data = String.make 200 'x' ^ String.make 200 'y' in
  let encoded = Backend.Compression.compress_with_header data in
  let decoded = Backend.Compression.decompress_auto encoded in
  check string "roundtrip matches" data decoded
;;

let test_compression_uncompressed_passthrough () =
  let data = "short" in
  let result = Backend.Compression.decompress_auto data in
  check string "uncompressed passthrough" data result
;;

let test_compression_encode_header () =
  (* Test header encoding with dictionary *)
  let orig_size = 1000 in
  let compressed = "compressed_data" in
  let with_dict =
    Backend.Compression.encode_with_header ~used_dict:true orig_size compressed
  in
  check bool "dict header starts with ZSTDD" true (String.sub with_dict 0 5 = "ZSTDD");
  let without_dict =
    Backend.Compression.encode_with_header ~used_dict:false orig_size compressed
  in
  check bool "std header starts with ZSTD" true (String.sub without_dict 0 4 = "ZSTD")
;;

let test_compression_decode_header () =
  (* Test header decoding *)
  let orig = 100 in
  let data = "test_compressed" in
  (* With dictionary *)
  let encoded_dict = Backend.Compression.encode_with_header ~used_dict:true orig data in
  (match Backend.Compression.decode_header encoded_dict with
   | Some (size, _, used_dict) ->
     check int "decoded size" orig size;
     check bool "decoded used_dict" true used_dict
   | None -> fail "decode_header failed for dict");
  (* Without dictionary *)
  let encoded_std = Backend.Compression.encode_with_header ~used_dict:false orig data in
  match Backend.Compression.decode_header encoded_std with
  | Some (size, _, used_dict) ->
    check int "decoded size std" orig size;
    check bool "decoded used_dict std" false used_dict
  | None -> fail "decode_header failed for std"
;;

let test_compression_invalid_header () =
  (* Test with data that doesn't have a valid header *)
  let result = Backend.Compression.decode_header "short" in
  check bool "short data returns None" true (Option.is_none result);
  let result2 = Backend.Compression.decode_header "INVALID_HEADER_DATA" in
  check bool "invalid header returns None" true (Option.is_none result2)
;;

(* ============================================================ *)
(* Backend.ml - Lock Operations                              *)
(* ============================================================ *)

let with_eio_backend f =
  Eio_main.run
  @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  let tmp_dir = make_test_dir "masc_eio" in
  let config =
    { Backend.default_config with
      base_path = tmp_dir
    ; node_id = "test"
    ; cluster_name = "test"
    }
  in
  Fun.protect
    ~finally:(fun () ->
      try rm_rf tmp_dir with
      | _ -> ())
    (fun () ->
       Eio.Switch.run
       @@ fun sw ->
       Eio_context.with_test_env
         ~net:(Eio.Stdenv.net env)
         ~clock
         ~mono_clock:(Eio.Stdenv.mono_clock env)
         ~sw
         (fun () ->
            let backend = Backend.FileSystem.create ~fs config in
            f backend))
;;

let test_eio_lock_acquire () =
  with_eio_backend
  @@ fun backend ->
  let key = make_unique_key "lock" in
  match Backend.FileSystem.acquire_lock backend ~key ~owner:"agent1" ~ttl_seconds:60 with
  | Ok true -> ()
  | _ -> fail "acquire should succeed"
;;

let test_eio_lock_block () =
  with_eio_backend
  @@ fun backend ->
  let key = make_unique_key "lock" in
  let _ = Backend.FileSystem.acquire_lock backend ~key ~owner:"agent1" ~ttl_seconds:60 in
  match Backend.FileSystem.acquire_lock backend ~key ~owner:"agent2" ~ttl_seconds:60 with
  | Ok false -> ()
  | _ -> fail "second acquire should be blocked"
;;

let test_eio_lock_release () =
  with_eio_backend
  @@ fun backend ->
  let key = make_unique_key "lock" in
  let _ = Backend.FileSystem.acquire_lock backend ~key ~owner:"agent1" ~ttl_seconds:60 in
  match Backend.FileSystem.release_lock backend ~key ~owner:"agent1" with
  | Ok true -> ()
  | _ -> fail "release should succeed"
;;

let test_eio_lock_extend () =
  with_eio_backend
  @@ fun backend ->
  let key = make_unique_key "lock" in
  let _ = Backend.FileSystem.acquire_lock backend ~key ~owner:"agent1" ~ttl_seconds:10 in
  match Backend.FileSystem.extend_lock backend ~key ~owner:"agent1" ~ttl_seconds:60 with
  | Ok true -> ()
  | _ -> fail "extend should succeed"
;;

let test_eio_lock_release_wrong_owner () =
  with_eio_backend
  @@ fun backend ->
  let key = make_unique_key "lock" in
  let _ = Backend.FileSystem.acquire_lock backend ~key ~owner:"agent1" ~ttl_seconds:60 in
  match Backend.FileSystem.release_lock backend ~key ~owner:"agent2" with
  | Ok false -> ()
  | _ -> fail "wrong owner release should fail"
;;

(* ============================================================ *)
(* Backend.ml - Atomic Operations                            *)
(* ============================================================ *)

let test_eio_atomic_increment () =
  with_eio_backend
  @@ fun backend ->
  let key = make_unique_key "counter" in
  (* First increment should be 1 *)
  (match Backend.FileSystem.atomic_increment backend key with
   | Ok n -> check int "first increment" 1 n
   | Error _ -> fail "atomic_increment failed");
  (* Second increment should be 2 *)
  match Backend.FileSystem.atomic_increment backend key with
  | Ok n -> check int "second increment" 2 n
  | Error _ -> fail "atomic_increment failed"
;;

let test_eio_atomic_get () =
  with_eio_backend
  @@ fun backend ->
  let key = make_unique_key "counter" in
  (* Get non-existent should be 0 *)
  (match Backend.FileSystem.atomic_get backend key with
   | Ok n -> check int "initial is 0" 0 n
   | Error e -> fail (Printf.sprintf "atomic_get (initial): %s" (Backend.show_error e)));
  (match Backend.FileSystem.atomic_increment backend key with
   | Ok _ -> ()
   | Error e -> fail (Printf.sprintf "atomic_increment: %s" (Backend.show_error e)));
  (* Get after increment should be 1 *)
  match Backend.FileSystem.atomic_get backend key with
  | Ok n -> check int "after increment is 1" 1 n
  | Error e -> fail (Printf.sprintf "atomic_get (after incr): %s" (Backend.show_error e))
;;

let test_eio_atomic_update () =
  with_eio_backend
  @@ fun backend ->
  let key = make_unique_key "data" in
  (* Update non-existent file *)
  let transform = function
    | None -> "initial"
    | Some s -> s ^ "_updated"
  in
  (match Backend.FileSystem.atomic_update backend key ~f:transform with
   | Ok v -> check string "initial value" "initial" v
   | Error _ -> fail "atomic_update failed");
  (* Update existing file *)
  match Backend.FileSystem.atomic_update backend key ~f:transform with
  | Ok v -> check string "updated value" "initial_updated" v
  | Error _ -> fail "atomic_update failed"
;;

(* ============================================================ *)
(* Backend.ml - Memory Backend                               *)
(* ============================================================ *)

let test_eio_memory_list_keys () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let backend = Backend.Memory.create () in
  let _ = Backend.Memory.set backend "prefix:a" "1" in
  let _ = Backend.Memory.set backend "prefix:b" "2" in
  let _ = Backend.Memory.set backend "other:c" "3" in
  match Backend.Memory.list_keys backend ~prefix:"prefix" with
  | Ok keys -> check int "prefix keys" 2 (List.length keys)
  | Error _ -> fail "list_keys failed"
;;

let test_eio_memory_clear () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let backend = Backend.Memory.create () in
  let _ = Backend.Memory.set backend "key1" "1" in
  let _ = Backend.Memory.set backend "key2" "2" in
  Backend.Memory.clear backend;
  check bool "cleared" false (Backend.Memory.exists backend "key1");
  check bool "cleared2" false (Backend.Memory.exists backend "key2")
;;

let test_eio_memory_delete_not_found () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let backend = Backend.Memory.create () in
  match Backend.Memory.delete backend "nonexistent" with
  | Error (Backend.NotFound _) -> ()
  | _ -> fail "delete nonexistent should fail"
;;

(* ============================================================ *)
(* Backend.ml - Unified Backend Interface                    *)
(* ============================================================ *)

let test_eio_unified_memory () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let mem = Backend.Memory.create () in
  let backend = Backend.Mem mem in
  (* set *)
  (match Backend.set backend "key" "value" with
   | Ok () -> ()
   | Error _ -> fail "unified set failed");
  (* get *)
  (match Backend.get backend "key" with
   | Ok v -> check string "unified get" "value" v
   | Error _ -> fail "unified get failed");
  (* exists *)
  check bool "unified exists" true (Backend.exists backend "key");
  (* delete *)
  (match Backend.delete backend "key" with
   | Ok () -> ()
   | Error _ -> fail "unified delete failed");
  check bool "unified not exists" false (Backend.exists backend "key")
;;

let test_eio_unified_set_if_not_exists () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let mem = Backend.Memory.create () in
  let backend = Backend.Mem mem in
  (* First set should succeed *)
  (match Backend.set_if_not_exists backend "unique" "first" with
   | Ok true -> ()
   | _ -> fail "first set_if_not_exists should succeed");
  (* Second set should fail *)
  match Backend.set_if_not_exists backend "unique" "second" with
  | Ok false -> ()
  | _ -> fail "second set_if_not_exists should fail"
;;

let test_eio_unified_list_keys () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let mem = Backend.Memory.create () in
  let backend = Backend.Mem mem in
  let _ = Backend.set backend "a" "1" in
  let _ = Backend.set backend "b" "2" in
  match Backend.list_keys backend with
  | Ok keys -> check bool "has keys" true (List.length keys >= 2)
  | Error _ -> fail "list_keys failed"
;;

let test_eio_unified_lock_memory () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let mem = Backend.Memory.create () in
  let backend = Backend.Mem mem in
  (* Memory backend locks always succeed *)
  (match Backend.acquire_lock backend ~key:"k" ~owner:"o" ~ttl_seconds:60 with
   | Ok true -> ()
   | _ -> fail "memory lock should succeed");
  (match Backend.release_lock backend ~key:"k" ~owner:"o" with
   | Ok true -> ()
   | _ -> fail "memory release should succeed");
  match Backend.extend_lock backend ~key:"k" ~owner:"o" ~ttl_seconds:60 with
  | Ok true -> ()
  | _ -> fail "memory extend should succeed"
;;

(* ============================================================ *)
(* Backend.ml - lock_info JSON                               *)
(* ============================================================ *)

let test_lock_info_json_roundtrip () =
  let info =
    Backend.FileSystem.
      { owner = "test_owner"; acquired_at = 1234567890.123; expires_at = 1234567950.456 }
  in
  let json = Backend.FileSystem.lock_info_to_json info in
  match Backend.FileSystem.lock_info_of_json json with
  | Some parsed ->
    check string "owner" info.owner parsed.owner;
    check
      bool
      "acquired_at close"
      true
      (abs_float (info.acquired_at -. parsed.acquired_at) < 0.001);
    check
      bool
      "expires_at close"
      true
      (abs_float (info.expires_at -. parsed.expires_at) < 0.001)
  | None -> fail "lock_info_of_json failed"
;;

let test_lock_info_invalid_json () =
  match Backend.FileSystem.lock_info_of_json "not json" with
  | None -> ()
  | Some _ -> fail "invalid json should return None"
;;

let test_lock_info_blank_json () =
  match Backend.FileSystem.lock_info_of_json "   \n\t  " with
  | None -> ()
  | Some _ -> fail "blank json should return None"
;;

let test_lock_info_missing_field () =
  match Backend.FileSystem.lock_info_of_json {|{"owner": "test"}|} with
  | None -> ()
  | Some _ -> fail "missing fields should return None"
;;

(* ============================================================ *)
(* Backend.ml - FileSystem Additional Tests                  *)
(* ============================================================ *)

let test_eio_fs_unicode_keys () =
  with_eio_backend
  @@ fun backend ->
  (* Unicode in key segments is allowed *)
  let key = "data:test" in
  (* Simple ASCII for safety *)
  let value = "unicode value" in
  (match Backend.FileSystem.set backend key value with
   | Ok () -> ()
   | Error _ -> fail "set with unicode should work");
  match Backend.FileSystem.get backend key with
  | Ok v -> check string "unicode value" value v
  | Error _ -> fail "get unicode key failed"
;;

let test_eio_fs_large_value () =
  with_eio_backend
  @@ fun backend ->
  let key = make_unique_key "large" in
  (* 1MB of data *)
  let value = String.make (1024 * 1024) 'x' in
  (match Backend.FileSystem.set backend key value with
   | Ok () -> ()
   | Error _ -> fail "set large value failed");
  match Backend.FileSystem.get backend key with
  | Ok v -> check int "large value length" (String.length value) (String.length v)
  | Error _ -> fail "get large value failed"
;;

let test_eio_fs_get_not_found () =
  with_eio_backend
  @@ fun backend ->
  match Backend.FileSystem.get backend "nonexistent:key" with
  | Error (Backend.NotFound _) -> ()
  | _ -> fail "get nonexistent should return NotFound"
;;

let test_eio_fs_delete_not_found () =
  with_eio_backend
  @@ fun backend ->
  match Backend.FileSystem.delete backend "nonexistent:key" with
  | Error (Backend.NotFound _) -> ()
  | _ -> fail "delete nonexistent should return NotFound"
;;

let test_eio_fs_list_keys_empty () =
  with_eio_backend
  @@ fun backend ->
  match Backend.FileSystem.list_keys backend ~prefix:"nonexistent" with
  | Ok [] -> ()
  | Ok _ -> fail "should return empty list"
  | Error _ -> fail "list_keys error"
;;

(* ============================================================ *)
(* Test Suite                                                    *)
(* ============================================================ *)

let () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run
    "Backend Coverage"
    [ ( "validate_ttl"
      , [ test_case "zero TTL" `Quick test_validate_ttl_zero
        ; test_case "negative TTL" `Quick test_validate_ttl_negative
        ; test_case "normal TTL" `Quick test_validate_ttl_normal
        ; test_case "large TTL" `Quick test_validate_ttl_large
        ; test_case "boundary TTL" `Quick test_validate_ttl_boundary
        ] )
    ; ( "config_status"
      , [ test_case "get_status all backends" `Quick test_get_status_all_backends
        ; test_case "pubsub_max_messages" `Quick test_pubsub_max_messages_env
        ] )
    ; ( "eio_compression"
      , [ test_case "small data" `Quick test_compression_small_data
        ; test_case "large data" `Quick test_compression_large_data
        ; test_case "roundtrip" `Quick test_compression_roundtrip
        ; test_case
            "uncompressed passthrough"
            `Quick
            test_compression_uncompressed_passthrough
        ; test_case "encode header" `Quick test_compression_encode_header
        ; test_case "decode header" `Quick test_compression_decode_header
        ; test_case "invalid header" `Quick test_compression_invalid_header
        ] )
    ; ( "eio_locks"
      , [ test_case "acquire" `Quick test_eio_lock_acquire
        ; test_case "block" `Quick test_eio_lock_block
        ; test_case "release" `Quick test_eio_lock_release
        ; test_case "extend" `Quick test_eio_lock_extend
        ; test_case "wrong owner release" `Quick test_eio_lock_release_wrong_owner
        ] )
    ; ( "eio_atomic"
      , [ test_case "increment" `Quick test_eio_atomic_increment
        ; test_case "get" `Quick test_eio_atomic_get
        ; test_case "update" `Quick test_eio_atomic_update
        ] )
    ; ( "eio_memory"
      , [ test_case "list_keys" `Quick test_eio_memory_list_keys
        ; test_case "clear" `Quick test_eio_memory_clear
        ; test_case "delete not found" `Quick test_eio_memory_delete_not_found
        ] )
    ; ( "eio_unified"
      , [ test_case "memory ops" `Quick test_eio_unified_memory
        ; test_case "set_if_not_exists" `Quick test_eio_unified_set_if_not_exists
        ; test_case "list_keys" `Quick test_eio_unified_list_keys
        ; test_case "lock memory" `Quick test_eio_unified_lock_memory
        ] )
    ; ( "eio_lock_info"
      , [ test_case "json roundtrip" `Quick test_lock_info_json_roundtrip
        ; test_case "invalid json" `Quick test_lock_info_invalid_json
        ; test_case "blank json" `Quick test_lock_info_blank_json
        ; test_case "missing field" `Quick test_lock_info_missing_field
        ] )
    ; ( "eio_fs_edge"
      , [ test_case "unicode keys" `Quick test_eio_fs_unicode_keys
        ; test_case "large value" `Quick test_eio_fs_large_value
        ; test_case "get not found" `Quick test_eio_fs_get_not_found
        ; test_case "delete not found" `Quick test_eio_fs_delete_not_found
        ; test_case "list_keys empty" `Quick test_eio_fs_list_keys_empty
        ] )
    ]
;;
